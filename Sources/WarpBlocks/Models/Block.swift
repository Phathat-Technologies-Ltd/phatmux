import Foundation

enum BlockKind: Equatable, Sendable {
    case command
    case commandExecution
    case naturalLanguage
}

enum BlockFeedback: Equatable, Sendable {
    case none
    case thumbsUp
    case thumbsDown
}

enum CommandSnippetState: Equatable, Sendable {
    case pending
    case running
    case succeeded
    case failed
}

struct CommandBlock: Equatable, Sendable {
    let id: UUID
    var command: String
    var output: String
    var cwd: String
    var duration: TimeInterval?
    var exitCode: Int32?
    var isRunning: Bool
    var isOutputExpanded: Bool
    var outputTruncated: Bool

    static let maxOutputLength = 65_536

    init(
        id: UUID = UUID(),
        command: String,
        output: String = "",
        cwd: String,
        duration: TimeInterval? = nil,
        exitCode: Int32? = nil,
        isRunning: Bool = false,
        isOutputExpanded: Bool = false,
        outputTruncated: Bool = false
    ) {
        self.id = id
        self.command = command
        self.output = output
        self.cwd = cwd
        self.duration = duration
        self.exitCode = exitCode
        self.isRunning = isRunning
        self.isOutputExpanded = isOutputExpanded
        self.outputTruncated = outputTruncated
    }

    mutating func appendOutput(_ text: String) {
        output += text
        if output.count > Self.maxOutputLength {
            let keepFrom = output.index(output.endIndex, offsetBy: -Self.maxOutputLength)
            output = String(output[keepFrom...])
            outputTruncated = true
        }
    }
}

struct CommandSnippet: Identifiable, Equatable, Sendable {
    let id: UUID
    var command: String
    var state: CommandSnippetState
    var output: String
    var exitCode: Int32?
    var duration: TimeInterval?

    init(
        id: UUID = UUID(),
        command: String,
        state: CommandSnippetState = .pending,
        output: String = "",
        exitCode: Int32? = nil,
        duration: TimeInterval? = nil
    ) {
        self.id = id
        self.command = command
        self.state = state
        self.output = output
        self.exitCode = exitCode
        self.duration = duration
    }
}

enum Segment: Equatable, Sendable {
    case thinking(duration: TimeInterval?, content: String?)
    case text(String)
    case commandSnippet(CommandSnippet)
}

struct IdentifiedSegment: Identifiable, Equatable, Sendable {
    let id: UUID
    var segment: Segment
}

struct Block: Identifiable, Equatable, Sendable {
    let id: UUID
    var input: String
    var kind: BlockKind
    var segments: [IdentifiedSegment]
    var commandBlock: CommandBlock?
    var feedback: BlockFeedback
    var creditsUsed: Int?

    init(
        id: UUID = UUID(),
        input: String,
        kind: BlockKind,
        segments: [IdentifiedSegment],
        commandBlock: CommandBlock? = nil,
        feedback: BlockFeedback = .none,
        creditsUsed: Int? = nil
    ) {
        self.id = id
        self.input = input
        self.kind = kind
        self.segments = segments
        self.commandBlock = commandBlock
        self.feedback = feedback
        self.creditsUsed = creditsUsed
    }
}

enum WarpBlocksAIKind: String, Sendable {
    case ollama
    case localLlama
}
