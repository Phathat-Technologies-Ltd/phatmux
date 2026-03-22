import SwiftUI

struct AIBlockView: View {
    let block: Block
    @ObservedObject var session: BlockSessionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(blockTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text(block.input)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(block.segments) { row in
                segmentView(row.segment)
            }
            BlockFooterView(block: block, session: session)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var blockTitle: String {
        switch block.kind {
        case .commandExecution:
            return String(localized: "warpblocks.block.title.command", defaultValue: "Command")
        case .command:
            return String(localized: "warpblocks.block.title.command", defaultValue: "Command")
        case .naturalLanguage:
            return String(localized: "warpblocks.block.title.ask", defaultValue: "Ask")
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: Segment) -> some View {
        switch segment {
        case let .thinking(duration, content):
            ThinkingView(duration: duration, content: content)
        case let .text(text):
            Text(text)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .commandSnippet(snippet):
            CommandSnippetView(snippet: snippet, session: session)
        }
    }
}
