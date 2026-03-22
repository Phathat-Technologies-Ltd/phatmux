import Combine
import Foundation

@MainActor
final class BlockTextScaleManager: ObservableObject {
    static let shared = BlockTextScaleManager()
    @Published var textScale: CGFloat = 1.0

    func zoomIn() { textScale = min(textScale + 0.1, 3.0) }
    func zoomOut() { textScale = max(textScale - 0.1, 0.5) }
    func resetZoom() { textScale = 1.0 }
}

@MainActor
final class BlockSessionManager: ObservableObject {
    @Published private(set) var visibleBlocks: [Block] = []
    @Published private(set) var currentWorkingDirectory: String
    @Published private(set) var isFullScreenMode = false
    @Published var isHistorySearchVisible = false
    @Published var historySearchQuery = ""

    var textScale: CGFloat { BlockTextScaleManager.shared.textScale }
    func zoomIn() { BlockTextScaleManager.shared.zoomIn() }
    func zoomOut() { BlockTextScaleManager.shared.zoomOut() }
    func resetZoom() { BlockTextScaleManager.shared.resetZoom() }
    @Published private(set) var historySearchResults: [HistoryEntry] = []
    @Published var historySearchSelectedIndex = 0
    @Published var pendingInputText: String?
    @Published var rawOutputChunk = Data()
    @Published var aiKind: WarpBlocksAIKind {
        didSet {
            UserDefaults.standard.set(aiKind.rawValue, forKey: Self.aiKindKey)
        }
    }

    private var allBlocks: [Block] = []
    private static let visibleWindowSize = 200
    private static let evictionThreshold = 500

    private var provider: any AIProvider
    private let ollama: OllamaProvider
    private let llama: LlamaProvider
    private var history: [AIMessage] = []

    private var outputBuffer = ""
    private var outputFlushScheduled = false
    private static let outputFlushInterval: TimeInterval = 0.05

    var onPasteToTerminal: ((String) -> Void)?
    var onSendEnterKey: (() -> Void)?
    var onFullScreenTransition: ((Bool) -> Void)?
    var workingDirectoryProvider: () -> String = {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    private enum OutputParseState {
        case normal, escape, ansi, osc, oscEscape
    }
    private var outputParseState: OutputParseState = .normal
    private var ansiBuffer = ""
    private var oscBuffer = ""
    private var isFullScreen = false
    private var commandStartDate = Date()
    private var suppressingEcho = false
    private var scaleSubscription: AnyCancellable?

    private static let aiKindKey = "warpblocks.aiKind"

    init(useMockBlocks: Bool = true) {
        let stored = UserDefaults.standard.string(forKey: Self.aiKindKey)
        aiKind = WarpBlocksAIKind(rawValue: stored ?? "") ?? .ollama
        ollama = OllamaProvider()
        llama = LlamaProvider()
        provider = ollama
        var initialDir = workingDirectoryProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        if initialDir.isEmpty {
            initialDir = FileManager.default.homeDirectoryForCurrentUser.path
        }
        currentWorkingDirectory = initialDir
        switch aiKind {
        case .ollama:
            provider = ollama
        case .localLlama:
            provider = llama
        }
        if useMockBlocks {
            allBlocks = Self.mockBlocks(initialWorkingDirectory: currentWorkingDirectory)
            syncVisibleWindow()
        }
        scaleSubscription = BlockTextScaleManager.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /** Switches the active AI backend used for natural language prompts.
    Applies all configured options from the current selection and keeps future prompts
    routed to the selected backend.
    */
    func setAIKind(_ kind: WarpBlocksAIKind) {
        aiKind = kind
        switch kind {
        case .ollama:
            provider = ollama
        case .localLlama:
            provider = llama
        }
    }

    /** Submits a command to the persistent shell and opens a new command execution block.
    Streaming output from the PTY is appended in real time while the command runs.
    */
    func submitCommand(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var safeCwd = currentWorkingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if safeCwd.isEmpty {
            let fallback = workingDirectoryProvider().trimmingCharacters(in: .whitespacesAndNewlines)
            safeCwd = fallback.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : fallback
        }
        currentWorkingDirectory = safeCwd
        let blockId = UUID()
        let commandBlock = CommandBlock(
            id: UUID(),
            command: trimmed,
            cwd: safeCwd,
            isRunning: true,
            isOutputExpanded: true
        )
        appendBlock(
            Block(
                id: blockId,
                input: trimmed,
                kind: .commandExecution,
                segments: [],
                commandBlock: commandBlock
            )
        )
        suppressingEcho = true
        onPasteToTerminal?(trimmed)
        onSendEnterKey?()
    }

    func sendPasteToTerminal(_ command: String) {
        let commandToPaste = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commandToPaste.isEmpty else { return }
        onPasteToTerminal?(commandToPaste)
    }

    func submitNaturalLanguage(_ line: String) async {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        history.append(AIMessage(role: "user", content: trimmed))
        let start = Date()
        let blockId = UUID()
        appendBlock(
            Block(
                id: blockId,
                input: trimmed,
                kind: .naturalLanguage,
                segments: [IdentifiedSegment(id: UUID(), segment: .thinking(duration: nil, content: nil))]
            )
        )
        var segments: [IdentifiedSegment] = []
        var inThink = false
        var thinkAccum = ""
        var textAccum = ""
        var promptTok = 0
        var completionTok = 0

        func flushText() {
            guard !textAccum.isEmpty else { return }
            segments.append(IdentifiedSegment(id: UUID(), segment: .text(textAccum)))
            textAccum = ""
        }

        do {
            let stream = provider.stream(prompt: trimmed, history: Array(history.dropLast()))
            for try await chunk in stream {
                switch chunk {
                case .thinkStart:
                    flushText()
                    inThink = true
                    thinkAccum = ""
                case let .thinkContent(value):
                    thinkAccum += value
                case .thinkEnd:
                    inThink = false
                    let duration = Date().timeIntervalSince(start)
                    let content = thinkAccum.isEmpty ? nil : thinkAccum
                    segments.append(
                        IdentifiedSegment(
                            id: UUID(),
                            segment: .thinking(duration: duration, content: content)
                        )
                    )
                    thinkAccum = ""
                case let .text(value):
                    if inThink {
                        thinkAccum += value
                    } else {
                        textAccum += value
                    }
                case let .codeBlock(_, code):
                    flushText()
                    let firstLine = code.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                    if !firstLine.isEmpty {
                        segments.append(
                            IdentifiedSegment(
                                id: UUID(),
                                segment: .commandSnippet(CommandSnippet(command: firstLine, state: .pending))
                            )
                        )
                    }
                case let .done(promptTokens, completionTokens):
                    promptTok = promptTokens
                    completionTok = completionTokens
                }
            }
            flushText()
            if segments.isEmpty {
                segments = [
                    IdentifiedSegment(
                        id: UUID(),
                        segment: .text(String(localized: "warpblocks.ai.empty", defaultValue: "(no response)"))
                    )
                ]
            } else if let first = segments.first, case .thinking(nil, _) = first.segment {
                let duration = Date().timeIntervalSince(start)
                if case let .thinking(_, content) = first.segment {
                    segments[0] = IdentifiedSegment(id: first.id, segment: .thinking(duration: duration, content: content))
                }
            }
            guard let idx = allBlocks.firstIndex(where: { $0.id == blockId }) else { return }
            allBlocks[idx].segments = segments
            allBlocks[idx].creditsUsed = promptTok + completionTok
            syncVisibleWindow()
            let summary = segments.compactMap { row -> String? in
                if case let .text(text) = row.segment { return text }
                return nil
            }.joined()
            history.append(AIMessage(role: "assistant", content: summary))
        } catch {
            guard let idx = allBlocks.firstIndex(where: { $0.id == blockId }) else { return }
            allBlocks[idx].segments = [
                IdentifiedSegment(
                    id: UUID(),
                    segment: .text(
                        String.localizedStringWithFormat(
                            String(localized: "warpblocks.ai.errorFormat", defaultValue: "Error: %@"),
                            error.localizedDescription
                        )
                    )
                )
            ]
            syncVisibleWindow()
        }
    }

    func runCommandSnippet(id: UUID) {
        guard let block = allBlocks.first(where: { block in
            block.segments.contains(where: { segment in
                if case let .commandSnippet(snippet) = segment.segment { return snippet.id == id }
                return false
            })
        }) else {
            return
        }
        guard let snippet = block.segments.compactMap({ segment -> CommandSnippet? in
            if case let .commandSnippet(candidate) = segment.segment, candidate.id == id {
                return candidate
            }
            return nil
        }).first else {
            return
        }
        submitCommand(snippet.command)
    }

    func setCommandOutputExpanded(blockId: UUID, expanded: Bool) {
        guard let blockIndex = allBlocks.firstIndex(where: { $0.id == blockId }) else { return }
        guard var commandBlock = allBlocks[blockIndex].commandBlock else { return }
        commandBlock.isOutputExpanded = expanded
        allBlocks[blockIndex].commandBlock = commandBlock
        syncVisibleWindow()
    }

    func interruptCurrentCommand() {
        onPasteToTerminal?("\u{03}")
    }

    // MARK: - History Search

    private lazy var historyReader = AtuinHistoryReader()

    func openHistorySearch() {
        historySearchQuery = ""
        isHistorySearchVisible = true
        refreshHistorySearch()
    }

    func closeHistorySearch() {
        isHistorySearchVisible = false
        historySearchQuery = ""
        historySearchResults = []
        historySearchSelectedIndex = 0
    }

    func refreshHistorySearch() {
        historySearchResults = historyReader.search(query: historySearchQuery).reversed()
        historySearchSelectedIndex = historySearchResults.isEmpty
            ? 0
            : historySearchResults.count - 1
    }

    func historySearchSelectEntry() {
        guard let entry = historySearchSelectedEntry else { return }
        let command = entry.command
        closeHistorySearch()
        DispatchQueue.main.async { [weak self] in
            self?.pendingInputText = command
        }
    }

    func historySearchMoveSelection(by delta: Int) {
        guard !historySearchResults.isEmpty else { return }
        historySearchSelectedIndex = (
            historySearchSelectedIndex + delta + historySearchResults.count
        ) % historySearchResults.count
    }

    var historySearchSelectedEntry: HistoryEntry? {
        guard !historySearchResults.isEmpty,
              historySearchSelectedIndex < historySearchResults.count
        else { return nil }
        return historySearchResults[historySearchSelectedIndex]
    }

    func setFeedback(blockId: UUID, _ feedback: BlockFeedback) {
        guard let index = allBlocks.firstIndex(where: { $0.id == blockId }) else { return }
        allBlocks[index].feedback = feedback
        syncVisibleWindow()
    }

    var totalBlockCount: Int { allBlocks.count }

    private func appendBlock(_ block: Block) {
        allBlocks.append(block)
        if allBlocks.count > Self.evictionThreshold {
            let excess = allBlocks.count - Self.visibleWindowSize
            if excess > 0 {
                for i in 0..<excess {
                    if var cmd = allBlocks[i].commandBlock, !cmd.isRunning {
                        cmd.output = ""
                        cmd.outputTruncated = true
                        allBlocks[i].commandBlock = cmd
                    }
                    allBlocks[i].segments = []
                }
            }
        }
        syncVisibleWindow()
    }

    private func syncVisibleWindow() {
        let windowStart = max(0, allBlocks.count - Self.visibleWindowSize)
        let window = Array(allBlocks[windowStart...])
        if window != visibleBlocks {
            visibleBlocks = window
        }
    }

    private func activeCommandIndex() -> Int? {
        allBlocks.lastIndex(where: { block in
            block.kind == .commandExecution && block.commandBlock?.isRunning == true
        })
    }

    private func activeCommandId() -> UUID? {
        activeCommandIndex().flatMap { allBlocks[$0].id }
    }

    private func bufferOutput(_ text: String) {
        outputBuffer += text
        guard !outputFlushScheduled else { return }
        outputFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.outputFlushInterval) { [weak self] in
            self?.flushOutputBuffer()
        }
    }

    private func flushOutputBuffer() {
        outputFlushScheduled = false
        guard !outputBuffer.isEmpty else { return }
        let text = outputBuffer
        outputBuffer = ""
        guard let index = activeCommandIndex(), var commandBlock = allBlocks[index].commandBlock else { return }
        commandBlock.appendOutput(text)
        allBlocks[index].commandBlock = commandBlock
        syncVisibleWindow()
    }

    private func finishActiveCommand(exitCode: Int32, duration: TimeInterval) {
        flushOutputBuffer()
        guard let blockId = activeCommandId(),
              let index = allBlocks.firstIndex(where: { $0.id == blockId }),
              var commandBlock = allBlocks[index].commandBlock else {
            return
        }
        commandBlock.isRunning = false
        commandBlock.exitCode = exitCode
        commandBlock.duration = duration
        commandBlock.isOutputExpanded = true
        allBlocks[index].commandBlock = commandBlock
        syncVisibleWindow()
    }

    private func updateActiveCommandCWD(_ path: String) {
        if let index = activeCommandIndex(), var commandBlock = allBlocks[index].commandBlock {
            commandBlock.cwd = path
            allBlocks[index].commandBlock = commandBlock
        }
        currentWorkingDirectory = path
        syncVisibleWindow()
    }

    private static func mockBlocks(initialWorkingDirectory: String) -> [Block] {
        [
            Block(
                input: "List files",
                kind: .commandExecution,
                segments: [],
                commandBlock: CommandBlock(
                    command: "ls -la",
                    output: "\u{1b}[32mok\u{1b}[0m\nfile.txt",
                    cwd: initialWorkingDirectory,
                    duration: 0.02,
                    exitCode: 0,
                    isRunning: false,
                    isOutputExpanded: false
                ),
                creditsUsed: nil
            ),
            Block(
                input: "Explain this repo",
                kind: .naturalLanguage,
                segments: [
                    IdentifiedSegment(id: UUID(), segment: .thinking(duration: 0.4, content: "Analyzing the repo structure...")),
                    IdentifiedSegment(id: UUID(), segment: .text("Here is a command you can run:")),
                    IdentifiedSegment(
                        id: UUID(),
                        segment: .commandSnippet(CommandSnippet(command: "git status", state: .pending))
                    )
                ],
                creditsUsed: 128
            )
        ]
    }
}

// MARK: - Ghostty Output Parsing

extension BlockSessionManager {
    /// Receives raw PTY output bytes from the Ghostty surface's io_output_cb.
    func handleGhosttyOutput(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)

        if checkAltScreen(text) { return }

        if isFullScreen { return }

        parseAndRouteOutput(text)
    }

    private func checkAltScreen(_ text: String) -> Bool {
        if text.contains("\u{1b}[?1049h") || text.contains("\u{1b}[?47h") || text.contains("\u{1b}[?1047h") {
            if !isFullScreen {
                isFullScreen = true
                isFullScreenMode = true
                onFullScreenTransition?(true)
            }
            return true
        }
        if text.contains("\u{1b}[?1049l") || text.contains("\u{1b}[?47l") || text.contains("\u{1b}[?1047l") {
            if isFullScreen {
                isFullScreen = false
                isFullScreenMode = false
                suppressingEcho = true
                onFullScreenTransition?(false)
            }
            return true
        }
        return false
    }

    private func parseAndRouteOutput(_ text: String) {
        var output = ""
        for scalar in text.unicodeScalars {
            switch outputParseState {
            case .normal:
                if scalar == UnicodeScalar(0x1b) {
                    outputParseState = .escape
                    ansiBuffer = ""
                    continue
                }
                if !suppressingEcho {
                    output.unicodeScalars.append(scalar)
                }

            case .escape:
                if scalar == UnicodeScalar(0x5B) {
                    outputParseState = .ansi
                    ansiBuffer = "\u{1b}["
                    continue
                }
                if scalar == UnicodeScalar(0x5D) {
                    outputParseState = .osc
                    oscBuffer = "\u{1b}]"
                    continue
                }
                outputParseState = .normal
                if !suppressingEcho {
                    if let esc = UnicodeScalar(0x1b) {
                        output.unicodeScalars.append(esc)
                    }
                    output.unicodeScalars.append(scalar)
                }

            case .ansi:
                ansiBuffer.unicodeScalars.append(scalar)
                if scalar.value >= 0x40 && scalar.value <= 0x7E {
                    if !suppressingEcho {
                        output += ansiBuffer
                    }
                    ansiBuffer = ""
                    outputParseState = .normal
                }

            case .osc:
                if scalar == UnicodeScalar(0x1b) {
                    outputParseState = .oscEscape
                    continue
                }
                if scalar == UnicodeScalar(0x07) {
                    handleOSC(oscBuffer)
                    oscBuffer = ""
                    outputParseState = .normal
                    continue
                }
                oscBuffer.unicodeScalars.append(scalar)

            case .oscEscape:
                if scalar == UnicodeScalar(0x5C) {
                    handleOSC(oscBuffer)
                    oscBuffer = ""
                    outputParseState = .normal
                } else {
                    outputParseState = .normal
                    if !suppressingEcho {
                        output += oscBuffer
                        if let esc = UnicodeScalar(0x1b) {
                            output.unicodeScalars.append(esc)
                        }
                        output.unicodeScalars.append(scalar)
                    }
                }
            }
        }

        if !output.isEmpty {
            bufferOutput(output)
        }
    }

    private func handleOSC(_ value: String) {
        let payload = value.dropFirst(2)
        guard payload.hasPrefix("133;") else { return }
        let parts = payload.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return }
        let marker = parts[1]
        let rawData = parts.count >= 3
            ? String(parts[2])
                .trimmingCharacters(in: .newlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\u{7}"))
            : ""

        switch marker {
        case "A":
            suppressingEcho = false

        case "B":
            commandStartDate = Date()

        case "C":
            suppressingEcho = false

        case "D":
            suppressingEcho = false
            let code = Int32(rawData) ?? 0
            let duration = Date().timeIntervalSince(commandStartDate)
            finishActiveCommand(exitCode: code, duration: duration)

        case "P":
            break

        default:
            return
        }
    }

    private func resolvedWorkingDirectory(from rawData: String) -> String? {
        let trimmed = rawData.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed).standardizedFileURL.path
        }
        guard let slash = trimmed.firstIndex(of: ":") else { return nil }
        let path = String(trimmed[trimmed.index(after: slash)...])
        return path.isEmpty ? nil : path
    }
}
