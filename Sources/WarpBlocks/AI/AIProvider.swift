import Foundation

struct AIMessage: Equatable, Sendable {
    let role: String
    let content: String
}

enum StreamChunk: Equatable, Sendable {
    case thinkStart
    case thinkContent(String)
    case thinkEnd
    case text(String)
    case codeBlock(language: String?, code: String)
    case done(promptTokens: Int, completionTokens: Int)
}

protocol AIProvider: Sendable {
    func stream(prompt: String, history: [AIMessage]) -> AsyncThrowingStream<StreamChunk, Error>
}
