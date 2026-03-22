import SwiftUI
import Foundation
import AppKit
import Bonsplit

/// View for rendering a terminal panel
struct TerminalPanelView: View {
    @ObservedObject var panel: TerminalPanel
    @ObservedObject var workspace: Workspace
    @AppStorage(NotificationPaneRingSettings.enabledKey)
    private var notificationPaneRingEnabled = NotificationPaneRingSettings.defaultEnabled
    let paneId: PaneID
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let isSplit: Bool
    let appearance: PanelAppearance
    let hasUnreadNotification: Bool
    let onFocus: () -> Void
    let onTriggerFlash: () -> Void

    var body: some View {
        Group {
            if panel.isBlockFullScreen {
                GhosttyFullScreenSurfaceView(panel: panel)
            } else {
                BlockTerminalView(session: panel.blockSessionManager, workspace: workspace, paneId: paneId, panelId: panel.id)
                    .onAppear {
                        panel.ensureGhosttySurfaceStarted()
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id(panel.id)
        .background(Color.clear)
    }
}

/// Shared appearance settings for panels
struct PanelAppearance {
    let dividerColor: Color
    let unfocusedOverlayNSColor: NSColor
    let unfocusedOverlayOpacity: Double

    static func fromConfig(_ config: GhosttyConfig) -> PanelAppearance {
        PanelAppearance(
            dividerColor: Color(nsColor: config.resolvedSplitDividerColor),
            unfocusedOverlayNSColor: config.unfocusedSplitOverlayFill,
            unfocusedOverlayOpacity: config.unfocusedSplitOverlayOpacity
        )
    }
}

/// Ghostty surface view shown only when in fullscreen (alt screen) mode.
private struct GhosttyFullScreenSurfaceView: NSViewRepresentable {
    let panel: TerminalPanel

    func makeNSView(context: Context) -> NSView {
        panel.reclaimHostedViewFromOffscreen()
        let hosted = panel.hostedView
        hosted.setVisibleInUI(true)
        hosted.setActive(true)
        panel.surface.setFocus(true)
        return hosted
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        // Defer removeFromSuperview to avoid triggering constraint invalidation
        // during the display cycle, which causes _postWindowNeedsUpdateConstraints
        // to exceed AppKit's per-cycle limit (see bd3ee68e).
        DispatchQueue.main.async {
            nsView.removeFromSuperview()
        }
    }
}
