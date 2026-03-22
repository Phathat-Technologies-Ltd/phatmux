import AppKit
import SwiftUI

struct CommandSnippetView: View {
    let snippet: CommandSnippet
    @ObservedObject var session: BlockSessionManager
    @State private var outputExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(snippet.command)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                statusBadge
                Button {
                    session.sendPasteToTerminal(snippet.command)
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "warpblocks.snippet.copy", defaultValue: "Insert into terminal"))

                Button {
                    session.runCommandSnippet(id: snippet.id)
                } label: {
                    Image(systemName: "play.circle")
                }
                .buttonStyle(.borderless)
                .disabled(snippet.state == .running)
                .help(String(localized: "warpblocks.snippet.run", defaultValue: "Run command"))
            }
            if snippet.state == .running {
                ProgressView()
                    .controlSize(.small)
            }
            if !snippet.output.isEmpty || snippet.exitCode != nil {
                DisclosureGroup(isExpanded: $outputExpanded) {
                    if snippet.output.isEmpty {
                        Text(String(localized: "warpblocks.snippet.noOutput", defaultValue: "(no output)"))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    } else {
                        SelectableANSIOutputTextView(
                            attributedString: ANSIParser.attributedString(
                                from: snippet.output,
                                baseColor: NSColor.labelColor
                            )
                        )
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } label: {
                    Text(outputLabel)
                        .font(.caption)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
    }

    private var statusBadge: some View {
        let text: String
        switch snippet.state {
        case .pending:
            text = String(localized: "warpblocks.snippet.pending", defaultValue: "pending")
        case .running:
            text = String(localized: "warpblocks.snippet.running", defaultValue: "running")
        case .succeeded:
            text = String(localized: "warpblocks.snippet.ok", defaultValue: "ok")
        case .failed:
            text = String(localized: "warpblocks.snippet.fail", defaultValue: "fail")
        }
        return Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.35)))
    }

    private var outputLabel: String {
        if let code = snippet.exitCode, let d = snippet.duration {
            return String.localizedStringWithFormat(
                String(localized: "warpblocks.snippet.outputMeta", defaultValue: "Output (exit %lld, %.2fs)"),
                Int64(code),
                d
            )
        }
        return String(localized: "warpblocks.snippet.output", defaultValue: "Output")
    }
}
