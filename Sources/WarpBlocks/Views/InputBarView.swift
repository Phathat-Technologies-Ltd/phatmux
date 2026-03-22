import AppKit
import SwiftUI

struct InputBarView: View {
    @ObservedObject var session: BlockSessionManager
    var workspace: Workspace?
    var panelId: UUID?
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            cwdHeader
            cellEditor
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: session.pendingInputText) { text in
            guard let text else { return }
            draft = text
            session.pendingInputText = nil
        }
    }

    private var cwdHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8 * session.textScale, weight: .bold))
                .foregroundStyle(.blue)
            Text(session.currentWorkingDirectory)
                .font(.system(size: 10 * session.textScale, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            actionButtons
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }

    private var actionButtons: some View {
        HStack(spacing: 4) {
            Picker("", selection: Binding(
                get: { session.aiKind },
                set: { session.setAIKind($0) }
            )) {
                Text("Ollama").tag(WarpBlocksAIKind.ollama)
                Text("Local").tag(WarpBlocksAIKind.localLlama)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 110)
            .controlSize(.mini)
        }
    }

    private var scaledInputFontSize: CGFloat {
        11 * session.textScale
    }

    private var cellEditor: some View {
        InputCellTextView(
            text: $draft,
            cwd: session.currentWorkingDirectory,
            fontSize: scaledInputFontSize,
            onSubmit: { text in
                draft = ""
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                session.submitCommand(trimmed)
            },
            onAskAI: { text in
                draft = ""
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                Task { await session.submitNaturalLanguage(trimmed) }
            },
            onHistorySearch: {
                session.openHistorySearch()
            },
            onFocus: {
                if let workspace, let panelId {
                    workspace.focusPanel(panelId)
                }
            },
            onZoomIn: { session.zoomIn() },
            onZoomOut: { session.zoomOut() },
            onZoomReset: { session.resetZoom() }
        )
        .frame(minHeight: 16, maxHeight: 80)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }
}

struct InputCellTextView: NSViewRepresentable {
    @Binding var text: String
    var cwd: String
    var fontSize: CGFloat = 11
    var onSubmit: (String) -> Void
    var onAskAI: (String) -> Void
    var onHistorySearch: (() -> Void)?
    var onFocus: (() -> Void)?
    var onZoomIn: (() -> Void)?
    var onZoomOut: (() -> Void)?
    var onZoomReset: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        let textView = CellTextView()
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = NSColor.labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 0, height: 1)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineBreakMode = .byWordWrapping
        textView.delegate = context.coordinator
        textView.cellCoordinator = context.coordinator

        let coord = context.coordinator
        textView.onZoomIn = { [weak coord] in coord?.parent.onZoomIn?() }
        textView.onZoomOut = { [weak coord] in coord?.parent.onZoomOut?() }
        textView.onZoomReset = { [weak coord] in coord?.parent.onZoomReset?() }

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.cwd = cwd
        guard let textView = scrollView.documentView as? CellTextView else { return }
        if textView.string != text {
            textView.string = text
            textView.ghostSuggestion = nil
        }
        let scaledFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if textView.font != scaledFont {
            textView.font = scaledFont
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InputCellTextView
        weak var textView: NSTextView?
        var cwd = ""
        private let suggestionProvider = InputSuggestionProvider()
        private var suggestionTimer: Timer?

        init(_ parent: InputCellTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            if let cell = textView as? CellTextView {
                cell.ghostSuggestion = nil
                cell.needsDisplay = true
            }
            suggestionTimer?.invalidate()
            suggestionTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak self] _ in
                self?.applySuggestion()
            }
        }

        private func applySuggestion() {
            guard let textView = textView as? CellTextView else { return }
            let text = textView.string
            if text.isEmpty {
                textView.ghostSuggestion = nil
                textView.needsDisplay = true
                return
            }
            guard let suggestion = suggestionProvider.suggest(text: text, cwd: cwd) else {
                textView.ghostSuggestion = nil
                textView.needsDisplay = true
                return
            }
            guard suggestion != text, suggestion.hasPrefix(text) else {
                textView.ghostSuggestion = nil
                textView.needsDisplay = true
                return
            }
            textView.ghostSuggestion = suggestion
            textView.needsDisplay = true
        }

        func acceptSuggestion() {
            guard let textView = textView as? CellTextView,
                  let ghost = textView.ghostSuggestion
            else { return }
            textView.string = ghost
            parent.text = ghost
            textView.ghostSuggestion = nil
            textView.needsDisplay = true
            applySuggestion()
        }

        func handleReturn() {
            guard let textView else { return }
            let currentText = textView.string
            textView.string = ""
            parent.text = ""
            parent.onSubmit(currentText)
        }

        func handleAskAI() {
            guard let textView else { return }
            let currentText = textView.string
            textView.string = ""
            parent.text = ""
            parent.onAskAI(currentText)
        }

        func handleHistorySearch() {
            parent.onHistorySearch?()
        }

        func handleFocus() {
            parent.onFocus?()
        }
    }
}

class CellTextView: NSTextView {
    weak var cellCoordinator: InputCellTextView.Coordinator?
    var ghostSuggestion: String?
    var onZoomIn: (() -> Void)?
    var onZoomOut: (() -> Void)?
    var onZoomReset: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ghost = ghostSuggestion,
              ghost.count > string.count,
              ghost.hasPrefix(string),
              let layoutManager = layoutManager,
              let textContainer = textContainer
        else { return }
        let suffix = String(ghost.dropFirst(string.count))
        guard !suffix.isEmpty else { return }
        let len = (string as NSString).length
        let f = font ?? NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        let lineHeight = layoutManager.defaultLineHeight(for: f)
        var x = textContainerInset.width
        var y = textContainerInset.height
        if len > 0 {
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: len - 1, length: 1),
                actualCharacterRange: nil
            )
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            rect.origin.x += textContainerInset.width
            rect.origin.y += textContainerInset.height
            x = rect.maxX
            y = rect.origin.y
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: f,
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let drawRect = NSRect(x: x, y: y, width: 10_000, height: lineHeight)
        NSAttributedString(string: suffix, attributes: attrs).draw(
            with: drawRect,
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            cellCoordinator?.handleFocus()
        }
        return result
    }

    override func keyDown(with event: NSEvent) {
        let isTab = event.keyCode == 48
        let isRightArrow = event.keyCode == 124
        let isReturn = event.keyCode == 36
        let isR = event.keyCode == 15
        let hasShift = event.modifierFlags.contains(.shift)
        let hasCmd = event.modifierFlags.contains(.command)
        let hasCtrl = event.modifierFlags.contains(.control)

        if isTab, ghostSuggestion != nil, !hasCmd {
            cellCoordinator?.acceptSuggestion()
            return
        }

        if isRightArrow, ghostSuggestion != nil {
            let len = (string as NSString).length
            let sel = selectedRange()
            if sel.length == 0, sel.location == len {
                cellCoordinator?.acceptSuggestion()
                return
            }
        }

        if isReturn && hasCmd {
            cellCoordinator?.handleAskAI()
            return
        }

        if isReturn && !hasShift {
            cellCoordinator?.handleReturn()
            return
        }

        if isR && hasCtrl && !hasCmd && !hasShift {
            cellCoordinator?.handleHistorySearch()
            return
        }

        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        let chars = event.charactersIgnoringModifiers ?? ""

        if chars == "+" || chars == "=" || event.keyCode == 24 || event.keyCode == 69 {
            onZoomIn?()
            return true
        }
        if chars == "-" || event.keyCode == 27 || event.keyCode == 78 {
            onZoomOut?()
            return true
        }
        if chars == "0" || event.keyCode == 29 || event.keyCode == 82 {
            onZoomReset?()
            return true
        }

        return super.performKeyEquivalent(with: event)
    }
}
