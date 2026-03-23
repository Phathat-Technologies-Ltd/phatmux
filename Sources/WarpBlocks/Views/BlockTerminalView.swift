import Bonsplit
import SwiftUI

struct BlockTerminalView: View {
    @ObservedObject var session: BlockSessionManager
    @ObservedObject var workspace: Workspace
    let paneId: PaneID
    let panelId: UUID
    @State private var autoScroll = true
    @State private var selectionCoordinator = BlockSelectionCoordinator()
    @State private var selectionVersion: UInt = 0

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    blockScrollArea(width: geometry.size.width)
                    InputBarView(session: session, workspace: workspace, panelId: panelId)
                }
                .background(Color(nsColor: .windowBackgroundColor))

                if session.isHistorySearchVisible {
                    HistorySearchView(session: session)
                        .frame(height: geometry.size.height * 0.5)
                        .transition(.move(edge: .bottom))
                }
            }
        }
    }

    private func blockScrollArea(width: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(session.visibleBlocks.enumerated()), id: \.element.id) { index, block in
                        if index > 0 {
                            Divider()
                        }
                        Group {
                            if block.kind == .commandExecution {
                                CommandBlockView(
                                    block: block,
                                    blockIndex: index,
                                    session: session,
                                    selectionCoordinator: selectionCoordinator,
                                    onPaneFocus: { focusPane() }
                                )
                            } else {
                                AIBlockView(block: block, session: session)
                            }
                        }
                        .frame(width: width, alignment: .leading)
                        .background(blockTint(at: index))
                        .id(block.id)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
            }
            .onAppear { wireSelectionCoordinator() }
            .onDisappear { selectionCoordinator.clearSelection() }
            .onReceive(workspace.objectWillChange) { _ in
                if workspace.focusedPanelId != panelId {
                    selectionCoordinator.clearSelection()
                }
            }
            .onChange(of: session.visibleBlocks.count) { _ in
                selectionCoordinator.clearSelection()
                if autoScroll {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: session.visibleBlocks.last?.commandBlock?.output.count) { _ in
                if autoScroll {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: session.visibleBlocks.last?.segments.count) { _ in
                if autoScroll {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private func wireSelectionCoordinator() {
        selectionCoordinator.blockTextProvider = { from, to in
            let blocks = session.visibleBlocks
            guard from >= 0, to < blocks.count else { return "" }
            return (from...to).compactMap { i in
                Self.plainText(for: blocks[i])
            }.joined(separator: "\n")
        }
        selectionCoordinator.onSelectionChange = { [self] in
            selectionVersion &+= 1
        }
    }

    @ViewBuilder
    private func blockTint(at index: Int) -> some View {
        let _ = selectionVersion
        if selectionCoordinator.isSelected(index) {
            Color.accentColor.opacity(0.08)
        } else {
            Color.clear
        }
    }

    private func focusPane() {
        workspace.bonsplitController.focusPane(paneId)
        workspace.focusPanel(panelId)
    }

    private static func plainText(for block: Block) -> String? {
        guard let cmd = block.commandBlock else { return nil }
        if cmd.output.isEmpty {
            return "$ " + cmd.command
        }
        return "$ " + cmd.command + "\n" + cmd.output
    }
}
