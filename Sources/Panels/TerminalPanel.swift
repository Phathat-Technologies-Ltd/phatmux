import Foundation
import Combine
import AppKit
import Bonsplit

/// NSWindow subclass that never becomes key or main, used to host
/// offscreen Ghostty surfaces so they can initialize without
/// stealing keyboard focus from the block terminal input.
private class OffscreenSurfaceWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// TerminalPanel wraps an existing TerminalSurface and conforms to the Panel protocol.
/// This allows TerminalSurface to be used within the bonsplit-based layout system.
@MainActor
final class TerminalPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .terminal

    /// The underlying terminal surface
    let surface: TerminalSurface

    /// The workspace ID this panel belongs to
    private(set) var workspaceId: UUID

    /// Published title from the terminal process
    @Published private(set) var title: String = "Terminal"

    /// Published directory from the terminal
    @Published private(set) var directory: String = ""

    /// Persistent PTY-backed session for block-style rendering
    let blockSessionManager: BlockSessionManager

    /// Search state for find functionality
    @Published var searchState: TerminalSurface.SearchState? {
        didSet {
            surface.searchState = searchState
        }
    }

    /// Bump this token to force SwiftUI to call `updateNSView` on `GhosttyTerminalView`,
    /// which re-attaches the hosted view after bonsplit close/reparent operations.
    ///
    /// Without this, certain pane-close sequences can leave terminal views detached
    /// (hostedView.window == nil) until the user switches workspaces.
    @Published var viewReattachToken: UInt64 = 0

    @Published var isBlockFullScreen = false

    private var cancellables = Set<AnyCancellable>()

    var displayTitle: String {
        title.isEmpty ? "Terminal" : title
    }

    var displayIcon: String? {
        "terminal.fill"
    }

    var isDirty: Bool {
        // Bonsplit's "dirty" indicator is a very small dot in the tab strip.
        //
        // For terminals, `ghostty_surface_needs_confirm_quit` is driven by shell integration
        // heuristics and can be transiently (or permanently) wrong, which results in a dot
        // showing on every new terminal. That reads as a notification/alert and is misleading.
        //
        // We still honor `needsConfirmClose()` when actually closing a panel; we just don't
        // surface it as a tab-level dirty indicator.
        false
    }

    /// The hosted NSView for embedding in SwiftUI
    var hostedView: GhosttySurfaceScrollView {
        surface.hostedView
    }

    var requestedWorkingDirectory: String? {
        surface.requestedWorkingDirectory
    }

    init(workspaceId: UUID, surface: TerminalSurface) {
        self.id = surface.id
        self.workspaceId = workspaceId
        self.surface = surface
        self.blockSessionManager = BlockSessionManager(useMockBlocks: false)

        // Wire up block session callbacks
        blockSessionManager.onPasteToTerminal = { [weak self] text in
            self?.surface.sendText(text)
        }
        blockSessionManager.workingDirectoryProvider = { [weak self] in
            self?.directory ?? FileManager.default.homeDirectoryForCurrentUser.path
        }
        blockSessionManager.onFullScreenTransition = { [weak self] entered in
            self?.isBlockFullScreen = entered
        }
        blockSessionManager.onSendEnterKey = { [weak self] in
            guard let surface = self?.surface.surface else { return }
            var key = ghostty_input_key_s()
            key.action = GHOSTTY_ACTION_PRESS
            key.mods = GHOSTTY_MODS_NONE
            key.keycode = 36
            key.composing = false
            key.text = nil
            key.unshifted_codepoint = 0x0D
            _ = ghostty_surface_key(surface, key)
            key.action = GHOSTTY_ACTION_RELEASE
            _ = ghostty_surface_key(surface, key)
        }

        surface.onPtyOutput = { [weak self] data in
            self?.blockSessionManager.handleGhosttyOutput(data)
        }

        // Subscribe to surface's search state changes
        surface.$searchState
            .sink { [weak self] state in
                if self?.searchState !== state {
                    self?.searchState = state
                }
            }
            .store(in: &cancellables)
    }

    /// Create a new terminal panel with a fresh surface
    convenience init(
        workspaceId: UUID,
        context: ghostty_surface_context_e = GHOSTTY_SURFACE_CONTEXT_SPLIT,
        configTemplate: ghostty_surface_config_s? = nil,
        workingDirectory: String? = nil,
        portOrdinal: Int = 0,
        initialCommand: String? = nil,
        initialEnvironmentOverrides: [String: String] = [:],
        additionalEnvironment: [String: String] = [:]
    ) {
        let surface = TerminalSurface(
            tabId: workspaceId,
            context: context,
            configTemplate: configTemplate,
            workingDirectory: workingDirectory,
            initialCommand: initialCommand,
            initialEnvironmentOverrides: initialEnvironmentOverrides,
            additionalEnvironment: additionalEnvironment
        )
        surface.portOrdinal = portOrdinal
        self.init(workspaceId: workspaceId, surface: surface)
    }

    func updateTitle(_ newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && title != trimmed {
            title = trimmed
        }
    }

    func updateDirectory(_ newDirectory: String) {
        let trimmed = newDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && directory != trimmed {
            directory = trimmed
        }
    }

    func updateWorkspaceId(_ newWorkspaceId: UUID) {
        workspaceId = newWorkspaceId
        surface.updateWorkspaceId(newWorkspaceId)
    }

    func focus() {
        if !isBlockFullScreen {
            hostedView.setActive(true)
            blockSessionManager.requestInputFocus()
            return
        }
        surface.setFocus(true)
        hostedView.setActive(true)
        hostedView.ensureFocus(for: workspaceId, surfaceId: id)
    }

    func unfocus() {
        surface.setFocus(false)
        // Cancel any pending focus work items so an inactive terminal can't steal first responder
        // back from another surface (notably WKWebView) during rapid focus changes in tests.
        //
        // Also flip the hosted view's active state immediately: SwiftUI focus propagation can lag
        // by a runloop tick, and `requestFocus` retries that are already executing can otherwise
        // schedule new work items that fire after we navigate away.
        hostedView.setActive(false)
    }

    func close() {
        // The surface will be cleaned up by its deinit
        // Detach from the window portal on real close so stale hosted views
        // cannot remain above browser panes after split close.
        surface.beginPortalCloseLifecycle(reason: "panel.close")
#if DEBUG
        let frame = String(format: "%.1fx%.1f", hostedView.frame.width, hostedView.frame.height)
        let bounds = String(format: "%.1fx%.1f", hostedView.bounds.width, hostedView.bounds.height)
        dlog(
            "surface.panel.close.begin panel=\(id.uuidString.prefix(5)) " +
            "workspace=\(workspaceId.uuidString.prefix(5)) runtimeSurface=\(surface.surface != nil ? 1 : 0) " +
            "inWindow=\(hostedView.window != nil ? 1 : 0) hasSuperview=\(hostedView.superview != nil ? 1 : 0) " +
            "hidden=\(hostedView.isHidden ? 1 : 0) frame=\(frame) bounds=\(bounds)"
        )
#endif
        unfocus()
        hostedView.setVisibleInUI(false)
        TerminalWindowPortalRegistry.detach(hostedView: hostedView)
#if DEBUG
        dlog(
            "surface.panel.close.end panel=\(id.uuidString.prefix(5)) " +
            "inWindow=\(hostedView.window != nil ? 1 : 0) hasSuperview=\(hostedView.superview != nil ? 1 : 0) " +
            "hidden=\(hostedView.isHidden ? 1 : 0)"
        )
#endif
        surface.teardownSurface()
    }

    func requestViewReattach() {
        viewReattachToken &+= 1
    }

    private var offscreenWindow: NSWindow?

    /// Starts the Ghostty surface without mounting it in the visible view hierarchy.
    /// The surface needs a window to initialize, so we use a hidden offscreen window.
    func ensureGhosttySurfaceStarted() {
        guard surface.surface == nil else { return }
        if offscreenWindow != nil { return }
        let window = OffscreenSurfaceWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostedView
        window.orderBack(nil)
        offscreenWindow = window
    }

    func reclaimHostedViewFromOffscreen() {
        if let window = offscreenWindow {
            hostedView.removeFromSuperview()
            window.contentView = nil
            offscreenWindow = nil
        }
    }

    // MARK: - Terminal-specific methods

    func sendText(_ text: String) {
        surface.sendText(text)
    }

    func performBindingAction(_ action: String) -> Bool {
        surface.performBindingAction(action)
    }

    func hasSelection() -> Bool {
        surface.hasSelection()
    }

    func needsConfirmClose() -> Bool {
        surface.needsConfirmClose()
    }

    func shouldPersistScrollbackForSessionSnapshot() -> Bool {
        // Session restore only replays terminal output into a fresh shell. If Ghostty
        // says we are not safely at a prompt, replaying that state later is misleading.
        !surface.needsConfirmClose()
    }

    func triggerFlash() {
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        hostedView.triggerFlash()
    }

    func triggerNotificationDismissFlash() {
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        hostedView.triggerFlash(style: .notificationDismiss)
    }

    func applyWindowBackgroundIfActive() {
        surface.applyWindowBackgroundIfActive()
    }

    func captureFocusIntent(in window: NSWindow?) -> PanelFocusIntent {
        .terminal(hostedView.capturePanelFocusIntent(in: window))
    }

    func preferredFocusIntentForActivation() -> PanelFocusIntent {
        .terminal(hostedView.preferredPanelFocusIntentForActivation())
    }

    func prepareFocusIntentForActivation(_ intent: PanelFocusIntent) {
        guard case .terminal(let target) = intent else { return }
        hostedView.preparePanelFocusIntentForActivation(target)
    }

    @discardableResult
    func restoreFocusIntent(_ intent: PanelFocusIntent) -> Bool {
        switch intent {
        case .panel:
            focus()
            return true
        case .terminal(let target):
            return hostedView.restorePanelFocusIntent(target)
        default:
            return false
        }
    }

    func ownedFocusIntent(for responder: NSResponder, in window: NSWindow) -> PanelFocusIntent? {
        _ = window
        guard let intent = hostedView.ownedPanelFocusIntent(for: responder) else { return nil }
        return .terminal(intent)
    }

    @discardableResult
    func yieldFocusIntent(_ intent: PanelFocusIntent, in window: NSWindow) -> Bool {
        guard case .terminal(let target) = intent else { return false }
        return hostedView.yieldPanelFocusIntent(target, in: window)
    }
}
