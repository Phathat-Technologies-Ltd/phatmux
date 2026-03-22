import AppKit
import SwiftUI

struct CommandBlockView: View {
    let block: Block
    let blockIndex: Int
    @ObservedObject var session: BlockSessionManager
    var selectionCoordinator: BlockSelectionCoordinator?

    var body: some View {
        if let commandBlock = block.commandBlock {
            let failed = commandBlock.exitCode.map { $0 != 0 } ?? false
            HStack(spacing: 0) {
                if failed {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.red.opacity(0.7))
                        .frame(width: 3)
                }
                VStack(alignment: .leading, spacing: 6) {
                    combinedContentView(commandBlock)

                    if commandBlock.isRunning {
                        runningFooter(commandBlock)
                    } else {
                        finishedFooter(commandBlock)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var scaledFontSize: CGFloat {
        NSFont.systemFontSize * session.textScale
    }

    @ViewBuilder
    private func combinedContentView(_ commandBlock: CommandBlock) -> some View {
        if commandBlock.output.isEmpty {
            SelectableANSIOutputTextView(
                attributedString: Self.commandOnlyAttributedString(commandBlock.command, fontSize: scaledFontSize),
                blockIndex: blockIndex,
                selectionCoordinator: selectionCoordinator
            )
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            SelectableANSIOutputTextView(
                attributedString: Self.combinedAttributedString(
                    command: commandBlock.command,
                    output: commandBlock.output,
                    fontSize: scaledFontSize
                ),
                blockIndex: blockIndex,
                selectionCoordinator: selectionCoordinator
            )
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var captionFont: Font {
        .system(size: 10 * session.textScale)
    }

    private func runningFooter(_ commandBlock: CommandBlock) -> some View {
        HStack {
            ProgressView()
                .controlSize(.small)
            Text(commandBlock.cwd)
                .font(captionFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button(action: { session.interruptCurrentCommand() }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "warpblocks.snippet.cancel", defaultValue: "Cancel command"))
        }
    }

    private func finishedFooter(_ commandBlock: CommandBlock) -> some View {
        HStack {
            Text(commandBlock.cwd)
                .font(captionFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let duration = commandBlock.duration {
                Text(Self.formatDuration(duration))
                    .font(captionFont)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return String(format: "%dms", Int(duration * 1000))
        } else if duration < 60 {
            return String(format: "%.1fs", duration)
        } else {
            let mins = Int(duration) / 60
            let secs = Int(duration) % 60
            return String(format: "%dm %ds", mins, secs)
        }
    }

    private static func commandOnlyAttributedString(_ command: String, fontSize: CGFloat) -> NSAttributedString {
        let mono = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: mono,
            .foregroundColor: NSColor.labelColor
        ]
        return NSAttributedString(string: "$ " + command, attributes: attrs)
    }

    private static func combinedAttributedString(
        command: String,
        output: String,
        fontSize: CGFloat
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()

        let cmdFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
        let cmdAttrs: [NSAttributedString.Key: Any] = [
            .font: cmdFont,
            .foregroundColor: NSColor.labelColor
        ]
        result.append(NSAttributedString(string: "$ " + command + "\n", attributes: cmdAttrs))

        let outputAttr = ANSIParser.attributedString(from: output, baseColor: NSColor.labelColor, fontSize: fontSize)
        result.append(outputAttr)

        return result
    }
}
