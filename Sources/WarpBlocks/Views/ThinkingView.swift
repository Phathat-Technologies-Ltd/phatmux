import SwiftUI

struct ThinkingView: View {
    let duration: TimeInterval?
    let content: String?
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if let content, !content.isEmpty {
                Text(content)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "brain.head.profile")
                Text(labelText)
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        }
    }

    private var labelText: String {
        if let duration {
            return String.localizedStringWithFormat(
                String(localized: "warpblocks.thinking.duration", defaultValue: "Thought for %.1fs"),
                duration
            )
        }
        return String(localized: "warpblocks.thinking", defaultValue: "Thinking")
    }
}
