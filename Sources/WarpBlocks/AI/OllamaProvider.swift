import Foundation

private enum OllamaError: LocalizedError {
    case notRunning(URL)
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case let .notRunning(url):
            return "Cannot connect to Ollama at \(url.host ?? "localhost"). Run \"ollama serve\" first."
        case let .httpError(status, detail):
            return "Ollama returned HTTP \(status). \(detail)"
        }
    }
}

struct OllamaProvider: AIProvider {
    var baseURL: URL
    var model: String

    init(baseURL: URL = URL(string: "http://127.0.0.1:11434")!, model: String = "llama3.2") {
        self.baseURL = baseURL
        self.model = model
    }

    func stream(prompt: String, history: [AIMessage]) -> AsyncThrowingStream<StreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = baseURL.appendingPathComponent("api/chat")
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    let messages = history.map { ["role": $0.role, "content": $0.content] }
                        + [["role": "user", "content": prompt]]
                    let body: [String: Any] = [
                        "model": model,
                        "messages": messages,
                        "stream": true
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
                    let bytes: URLSession.AsyncBytes
                    let response: URLResponse
                    do {
                        (bytes, response) = try await URLSession.shared.bytes(for: request)
                    } catch let urlError as URLError where urlError.code == .cannotConnectToHost
                        || urlError.code == .networkConnectionLost
                        || urlError.code == .timedOut {
                        throw OllamaError.notRunning(self.baseURL)
                    }
                    if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
                        let detail = http.statusCode == 404
                            ? "Model \"\(self.model)\" not found. Run \"ollama pull \(self.model)\"."
                            : "Check Ollama logs for details."
                        throw OllamaError.httpError(http.statusCode, detail)
                    }
                    var parser = OllamaStreamParser(continuation: continuation)
                    var finished = false
                    for try await line in bytes.lines {
                        if Task.isCancelled {
                            continuation.finish()
                            return
                        }
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { continue }
                        let payload: String
                        if trimmed.hasPrefix("data: ") {
                            payload = String(trimmed.dropFirst(6))
                        } else {
                            payload = trimmed
                        }
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            continue
                        }
                        if let msg = json["message"] as? [String: Any],
                           let content = msg["content"] as? String, !content.isEmpty {
                            try parser.consume(content)
                        }
                        if let done = json["done"] as? Bool, done {
                            let pe = json["prompt_eval_count"] as? Int ?? 0
                            let ec = json["eval_count"] as? Int ?? 0
                            try parser.flush()
                            continuation.yield(.done(promptTokens: pe, completionTokens: ec))
                            finished = true
                            break
                        }
                    }
                    if !finished {
                        try parser.flush()
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

private struct OllamaStreamParser {
    enum Mode {
        case text
        case think
    }

    private var buffer = ""
    private var mode = Mode.text
    private var thinkEmittedStart = false
    private let continuation: AsyncThrowingStream<StreamChunk, Error>.Continuation

    init(continuation: AsyncThrowingStream<StreamChunk, Error>.Continuation) {
        self.continuation = continuation
    }

    mutating func consume(_ chunk: String) throws {
        buffer += chunk
        try drain()
    }

    mutating func flush() throws {
        try drain(force: true)
        if mode == .think {
            continuation.yield(.thinkEnd)
        }
        if !buffer.isEmpty {
            continuation.yield(.text(buffer))
            buffer = ""
        }
    }

    private mutating func drain(force: Bool = false) throws {
        let thinkOpen = "\u{003c}think\u{003e}"
        let thinkClose = "\u{003c}/think\u{003e}"
        while true {
            switch mode {
            case .text:
                if let r = buffer.range(of: thinkOpen) {
                    let before = String(buffer[..<r.lowerBound])
                    if !before.isEmpty {
                        continuation.yield(.text(before))
                    }
                    buffer.removeSubrange(buffer.startIndex ..< r.upperBound)
                    mode = .think
                    if !thinkEmittedStart {
                        continuation.yield(.thinkStart)
                        thinkEmittedStart = true
                    }
                    continue
                }
                if let start = buffer.range(of: "```") {
                    let triple = "```"
                    let before = String(buffer[..<start.lowerBound])
                    if !before.isEmpty {
                        continuation.yield(.text(before))
                    }
                    let afterFence = buffer[start.upperBound...]
                    let rest = String(afterFence)
                    let lines = rest.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                    let lang = lines.first.map(String.init)?.trimmingCharacters(in: .whitespaces)
                    let remainder = lines.count > 1 ? String(lines[1]) : ""
                    if let endRange = remainder.range(of: triple) {
                        let code = String(remainder[..<endRange.lowerBound])
                        continuation.yield(.codeBlock(language: lang, code: code))
                        buffer = String(remainder[endRange.upperBound...])
                        continue
                    } else if force {
                        continuation.yield(.codeBlock(language: lang, code: remainder))
                        buffer = ""
                        break
                    } else {
                        buffer = String(buffer[start.lowerBound...])
                        break
                    }
                }
                break
            case .think:
                if let r = buffer.range(of: thinkClose) {
                    let inner = String(buffer[..<r.lowerBound])
                    if !inner.isEmpty {
                        continuation.yield(.thinkContent(inner))
                    }
                    continuation.yield(.thinkEnd)
                    buffer.removeSubrange(buffer.startIndex ..< r.upperBound)
                    mode = .text
                    thinkEmittedStart = false
                    continue
                }
                if force, !buffer.isEmpty {
                    continuation.yield(.thinkContent(buffer))
                    buffer = ""
                    continuation.yield(.thinkEnd)
                    mode = .text
                    thinkEmittedStart = false
                }
                break
            }
        }
    }
}
