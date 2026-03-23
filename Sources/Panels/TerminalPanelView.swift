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
        hosted.fullScreenMountGeneration &+= 1
        hosted.isHidden = false
        hosted.setVisibleInUI(true)
        hosted.setActive(true)
        panel.surface.setFocus(true)
        let expectedGen = hosted.fullScreenMountGeneration
        DispatchQueue.main.async { [weak panel] in
            guard let panel else { return }
            let hosted = panel.hostedView
            guard hosted.fullScreenMountGeneration == expectedGen else { return }
            hosted.isHidden = false
            hosted.setVisibleInUI(true)
            hosted.setActive(true)
            hosted.refreshSurfaceNow(reason: "blockFullScreen.remount")
            panel.surface.forceRefresh(reason: "blockFullScreen.remount")
        }
        return hosted
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let hosted = panel.hostedView
        if hosted.isHidden {
            hosted.isHidden = false
            hosted.setVisibleInUI(true)
            hosted.setActive(true)
            hosted.refreshSurfaceNow(reason: "blockFullScreen.updateNSView")
            panel.surface.forceRefresh(reason: "blockFullScreen.updateNSView")
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        // Hide synchronously instead of deferring removeFromSuperview.
        // Deferred removal races with makeNSView during rapid SwiftUI
        // re-evaluations (split close, tab switch), causing the freshly
        // mounted view to be ripped out of the window.
        nsView.isHidden = true
    }
}
