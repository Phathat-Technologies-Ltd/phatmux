import Darwin
import Foundation

protocol PTYSessionDelegate: AnyObject {
    func ptySession(_ session: PTYSession, didStartBlock cwd: String)
    func ptySession(_ session: PTYSession, didReceiveOutput text: String)
    func ptySession(_ session: PTYSession, didFinishBlock exitCode: Int32, duration: TimeInterval)
    func ptySession(_ session: PTYSession, didChangeCWD path: String)
    func ptySession(_ session: PTYSession, didEnterFullScreen: Bool)
    func ptySession(_ session: PTYSession, didReceiveRawOutput data: Data)
}

final class PTYSession {
    weak var delegate: PTYSessionDelegate?

    private enum ParseState {
        case normal
        case escape
        case ansi
        case osc
        case oscEscape
    }

    private var parseState: ParseState = .normal
    private var ansiBuffer = ""
    private var oscBuffer = ""
    private var masterFD: Int32 = -1
    private var childPID: pid_t = -1
    private var readSource: DispatchSourceRead?
    private var isRunning = true
    private var isFullScreen = false
    private var commandStartDate = Date()
    private var currentWorkingDirectory: String
    private let readQueue = DispatchQueue(label: "phatmux.warpblocks.pty.read", qos: .userInitiated)
    private let watchingQueue = DispatchQueue(label: "phatmux.warpblocks.pty.watch", qos: .userInitiated)

    /**
     * Starts an interactive zsh process attached to a pseudoterminal.
     * The shell session is configured to emit OSC 133 events for command lifecycle.
     */
    init(initialDirectory: String) {
        currentWorkingDirectory = initialDirectory
        start(initialDirectory: initialDirectory)
    }

    /**
     * Sends a command line to the shell and appends newline.
     * Streaming output is emitted through PTYSessionDelegate callbacks.
     */
    func sendCommand(_ command: String) {
        sendText(command + "\n")
    }

    /**
     * Sends raw text into the shell input stream.
     * Used for copy/paste and interactive follow-up text fragments.
     */
    func sendText(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        data.withUnsafeBytes { pointer in
            guard let address = pointer.bindMemory(to: UInt8.self).baseAddress else { return }
            _ = write(masterFD, address, data.count)
        }
    }

    /**
     * Stops process watchers and terminates the PTY shell process.
     * Call this from deinit paths to prevent zombie or descriptor leaks.
     */
    func stop() {
        isRunning = false
        readSource?.cancel()
        if childPID > 0 {
            kill(childPID, SIGKILL)
        }
        if masterFD >= 0 {
            close(masterFD)
            masterFD = -1
        }
    }

    /**
     * Sends SIGINT to the PTY process group.
     * This mirrors terminal cancel behavior for the current running command.
     */
    func interrupt() {
        if childPID > 0 {
            kill(-childPID, SIGINT)
        }
    }

    private func start(initialDirectory: String) {
        var amaster: Int32 = -1
        var aslave: Int32 = -1
        var terminal = termios()
        _ = tcgetattr(STDIN_FILENO, &terminal)

        if openpty(&amaster, &aslave, nil, &terminal, nil) != 0 {
            return
        }

        masterFD = amaster

        var fileActions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, aslave, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, aslave, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, aslave, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, masterFD)
        posix_spawn_file_actions_addclose(&fileActions, aslave)
        posix_spawn_file_actions_addchdir_np(&fileActions, initialDirectory)

        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

        let argv: [UnsafeMutablePointer<CChar>?] = [
            strdup("/bin/zsh"),
            strdup("-i"),
            nil
        ]

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["PWD"] = initialDirectory
        let envStrings = env.map { "\($0.key)=\($0.value)" }
        var envp: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) }
        envp.append(nil)

        let result = posix_spawn(&childPID, "/bin/zsh", &fileActions, &attr, argv, envp)

        posix_spawn_file_actions_destroy(&fileActions)
        posix_spawnattr_destroy(&attr)

        for ptr in argv { free(ptr) }
        for ptr in envp { free(ptr) }

        if result != 0 {
            close(masterFD)
            close(aslave)
            masterFD = -1
            return
        }

        _ = close(aslave)
        setupWatchers()
        bootstrapShell()
    }

    private func bootstrapShell() {
        let setup = #"""
autoload -Uz add-zsh-hook
function __warp_preexec() {
    print -n $'\e]133;A;\a'
    print -n $'\e]133;C;'"$PWD"$'\a'
}
function __warp_precmd() {
    print -n $'\e]133;B;'"$?"$'\a'
    print -n $'\e]133;C;'"$PWD"$'\a'
}
add-zsh-hook preexec __warp_preexec
add-zsh-hook precmd __warp_precmd
"""#
        sendText(setup + "\n")
    }

    private func setupWatchers() {
        DispatchQueue.main.async {
            self.delegate?.ptySession(self, didStartBlock: self.currentWorkingDirectory)
        }

        readSource = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: readQueue)
        readSource?.setEventHandler { [weak self] in
            self?.pumpOutput()
        }
        readSource?.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.masterFD >= 0 { close(self.masterFD) }
            self.masterFD = -1
        }
        readSource?.resume()
        monitorExit()
    }

    private func monitorExit() {
        watchingQueue.async { [weak self] in
            guard let self else { return }
            while self.isRunning {
                var status: Int32 = 0
                let pid = waitpid(self.childPID, &status, WNOHANG)
                if pid == self.childPID {
                    let code = self.exitCode(from: status)
                    DispatchQueue.main.async {
                        self.delegate?.ptySession(self, didFinishBlock: code, duration: 0)
                    }
                    break
                }
                sleep(1)
            }
        }
    }

    private func pumpOutput() {
        var raw = Array<UInt8>(repeating: 0, count: 4096)
        let count = read(masterFD, &raw, raw.count)
        if count <= 0 { return }
        let chunk = Array(raw.prefix(count))
        let text = String(decoding: chunk, as: UTF8.self)

        if checkAlternateScreen(text) { return }

        if isFullScreen {
            if text.contains("\u{1b}]133;") {
                isFullScreen = false
                DispatchQueue.main.async {
                    self.delegate?.ptySession(self, didEnterFullScreen: false)
                }
                parseAndRoute(text)
            }
            return
        }

        parseAndRoute(text)
    }

    private func checkAlternateScreen(_ text: String) -> Bool {
        if text.contains("\u{1b}[?1049h") || text.contains("\u{1b}[?47h") || text.contains("\u{1b}[?1047h") {
            if !isFullScreen {
                isFullScreen = true
                DispatchQueue.main.async {
                    self.delegate?.ptySession(self, didEnterFullScreen: true)
                }
            }
            return true
        }
        if text.contains("\u{1b}[?1049l") || text.contains("\u{1b}[?47l") || text.contains("\u{1b}[?1047l") {
            if isFullScreen {
                isFullScreen = false
                DispatchQueue.main.async {
                    self.delegate?.ptySession(self, didEnterFullScreen: false)
                }
            }
            return true
        }
        return false
    }

    private func parseAndRoute(_ text: String) {
        var output = ""
        for scalar in text.unicodeScalars {
            switch parseState {
            case .normal:
                if scalar == UnicodeScalar(0x1b) {
                    parseState = .escape
                    ansiBuffer = ""
                    continue
                }
                output.unicodeScalars.append(scalar)

            case .escape:
                if scalar == UnicodeScalar(0x5B) {
                    parseState = .ansi
                    ansiBuffer = "\u{1b}["
                    continue
                }
                if scalar == UnicodeScalar(0x5D) {
                    parseState = .osc
                    oscBuffer = "\u{1b}]"
                    continue
                }
                parseState = .normal
                if let esc = UnicodeScalar(0x1b) {
                    output.unicodeScalars.append(esc)
                }
                output.unicodeScalars.append(scalar)

            case .ansi:
                ansiBuffer.unicodeScalars.append(scalar)
                if scalar.value >= 0x40 && scalar.value <= 0x7E {
                    output += ansiBuffer
                    ansiBuffer = ""
                    parseState = .normal
                }

            case .osc:
                if scalar == UnicodeScalar(0x1b) {
                    parseState = .oscEscape
                    continue
                }
                if scalar == UnicodeScalar(0x07) {
                    handleOSC(oscBuffer)
                    oscBuffer = ""
                    parseState = .normal
                    continue
                }
                oscBuffer.unicodeScalars.append(scalar)

            case .oscEscape:
                if scalar == UnicodeScalar(0x5C) {
                    handleOSC(oscBuffer)
                    oscBuffer = ""
                    parseState = .normal
                } else {
                    parseState = .normal
                    output += oscBuffer
                    if let esc = UnicodeScalar(0x1b) {
                        output.unicodeScalars.append(esc)
                    }
                    output.unicodeScalars.append(scalar)
                }
            }
        }

        if !output.isEmpty {
            DispatchQueue.main.async {
                self.delegate?.ptySession(self, didReceiveOutput: output)
            }
        }
    }

    private func handleOSC(_ value: String) {
        let payload = value.dropFirst(2)
        guard payload.hasPrefix("133;") else { return }
        let parts = payload.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return }
        let marker = parts[1]
        let rawData = String(parts[2])
            .trimmingCharacters(in: .newlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{7}"))

        switch marker {
        case "A":
            commandStartDate = Date()
            DispatchQueue.main.async {
                self.delegate?.ptySession(self, didStartBlock: self.currentWorkingDirectory)
            }

        case "B":
            let code = Int32(rawData) ?? 0
            let duration = Date().timeIntervalSince(commandStartDate)
            DispatchQueue.main.async {
                self.delegate?.ptySession(self, didFinishBlock: code, duration: duration)
            }

        case "C":
            if let path = resolvedWorkingDirectory(from: rawData) {
                currentWorkingDirectory = path
                DispatchQueue.main.async {
                    self.delegate?.ptySession(self, didChangeCWD: path)
                }
            }

        default:
            return
        }
    }

    /// Resolves cwd from OSC 133;C payload: zsh sends plain `$PWD` (absolute path), while
    /// shell-integration URLs may use `file:` / OSC-7-style encodings.
    private func resolvedWorkingDirectory(from rawData: String) -> String? {
        let trimmed = rawData.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed).standardizedFileURL.path
        }
        return parseOSC7Path(trimmed)
    }

    private func parseOSC7Path(_ value: String) -> String? {
        guard let slash = value.firstIndex(of: ":") else { return nil }
        let path = String(value[value.index(after: slash)...])
        if !path.isEmpty { return path }
        return nil
    }

    private func exitCode(from status: Int32) -> Int32 {
        let wtermsig = status & 0x7f
        let wifsignaled = wtermsig != 0 && wtermsig != 0x7f
        let wifexited = wtermsig == 0
        let wexitstatus = (status >> 8) & 0xff

        if wifexited {
            return wexitstatus
        }
        if wifsignaled {
            return 128 + wtermsig
        }
        return -1
    }
}
