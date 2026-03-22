import SwiftUI

struct HistorySearchView: View {
    @ObservedObject var session: BlockSessionManager

    private let tealHighlight = Color(red: 0.0, green: 0.7, blue: 0.7)

    var body: some View {
        VStack(spacing: 0) {
            dismissBar
            Divider()
            resultsList
            Divider()
            searchBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var dismissBar: some View {
        HStack {
            HStack(spacing: 4) {
                Text("ESC")
                    .font(.system(.caption2, design: .monospaced).weight(.medium))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.3))
                    .cornerRadius(3)
                Text(String(localized: "warpblocks.history.escHint", defaultValue: "for terminal"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var resultsList: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        LazyVStack(spacing: 0) {
                            ForEach(
                                Array(session.historySearchResults.enumerated()),
                                id: \.element.id
                            ) { index, entry in
                                HistoryRow(
                                    entry: entry,
                                    isSelected: session.historySearchSelectedIndex == index,
                                    highlight: tealHighlight
                                )
                                .id("\(session.historySearchQuery)-\(index)")
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    let command = entry.command
                                    session.closeHistorySearch()
                                    DispatchQueue.main.async {
                                        session.pendingInputText = command
                                    }
                                }
                            }
                        }
                        .id(session.historySearchQuery)
                    }
                    .frame(minHeight: geometry.size.height)
                }
                .onAppear {
                    DispatchQueue.main.async {
                        let target = "\(session.historySearchQuery)-\(session.historySearchSelectedIndex)"
                        proxy.scrollTo(target, anchor: .bottom)
                    }
                }
                .onChange(of: session.historySearchSelectedIndex) { newIndex in
                    withAnimation(.easeInOut(duration: 0.1)) {
                        proxy.scrollTo("\(session.historySearchQuery)-\(newIndex)", anchor: .center)
                    }
                }
                .onChange(of: session.historySearchQuery) { query in
                    DispatchQueue.main.async {
                        let target = "\(query)-\(session.historySearchSelectedIndex)"
                        proxy.scrollTo(target, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 0) {
            Text(String(localized: "warpblocks.history.searchLabel", defaultValue: "history: "))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(session.historySearchQuery)
                .font(.system(.body, design: .monospaced))
            BlinkingCursor()
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct BlinkingCursor: View {
    @State private var visible = true

    var body: some View {
        Rectangle()
            .fill(Color.primary)
            .frame(width: 7, height: 16)
            .opacity(visible ? 1 : 0)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 530_000_000)
                    visible.toggle()
                }
            }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let isSelected: Bool
    let highlight: Color

    @State private var isHovered = false

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private var rowBackground: Color {
        if isSelected { return highlight }
        if isHovered { return Color.primary.opacity(0.08) }
        return Color.clear
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.caption)
                .foregroundStyle(isSelected ? .white : .secondary)

            Text(entry.command)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(isSelected ? .white : .primary)

            Spacer(minLength: 4)

            if entry.exitCode != 0 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .yellow)
            }

            Text(Self.relativeFormatter.localizedString(for: entry.timestamp, relativeTo: Date()))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(rowBackground)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
