import AppKit
import SwiftUI

/// Tracks the anchor block for Shift+click cross-block copy.
/// Entirely AppKit-driven — no SwiftUI reactivity. Registered text views
/// are asked to redraw their selection tint imperatively.
@MainActor
final class BlockSelectionCoordinator {
    private(set) var selectedRange: ClosedRange<Int>?
    private var anchorIndex: Int?
    var blockTextProvider: ((_ from: Int, _ to: Int) -> String)?

    private var registeredViews: [Int: WeakTextView] = [:]
    var onSelectionChange: (() -> Void)?

    func register(_ view: ANSIOutputTextView, at index: Int) {
        registeredViews[index] = WeakTextView(view)
    }

    func recordAnchor(_ index: Int) {
        let oldRange = selectedRange
        anchorIndex = index
        selectedRange = index...index
        refreshViews(oldRange: oldRange)
    }

    func handleShiftClick(at targetIndex: Int) {
        guard let anchor = anchorIndex, anchor != targetIndex else { return }
        let oldRange = selectedRange
        let lo = min(anchor, targetIndex)
        let hi = max(anchor, targetIndex)
        selectedRange = lo...hi
        refreshViews(oldRange: oldRange)
        guard let text = blockTextProvider?(lo, hi), !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func clearSelection() {
        let oldRange = selectedRange
        selectedRange = nil
        anchorIndex = nil
        refreshViews(oldRange: oldRange)
    }

    func isSelected(_ index: Int) -> Bool {
        selectedRange?.contains(index) ?? false
    }

    var hasMultiBlockSelection: Bool {
        guard let range = selectedRange else { return false }
        return range.upperBound > range.lowerBound
    }

    func copySelectedBlocksToClipboard() {
        guard let range = selectedRange,
              let text = blockTextProvider?(range.lowerBound, range.upperBound),
              !text.isEmpty
        else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func refreshViews(oldRange: ClosedRange<Int>?) {
        registeredViews = registeredViews.filter { $0.value.view != nil }
        var indicesToRefresh = Set<Int>()
        if let old = oldRange {
            for i in old { indicesToRefresh.insert(i) }
        }
        if let new = selectedRange {
            for i in new { indicesToRefresh.insert(i) }
        }
        for idx in indicesToRefresh {
            guard let view = registeredViews[idx]?.view else { continue }
            view.updateSelectionTint()
            view.needsDisplay = true
        }
        onSelectionChange?()
    }
}

private struct WeakTextView {
    weak var view: ANSIOutputTextView?
    init(_ view: ANSIOutputTextView) { self.view = view }
}

/// Extends temporary selection background to the full width of each affected line fragment so row
/// selection matches terminal-style highlights without widening ANSI background colors from storage.
final class FullWidthSelectionTextLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let textContainer = textContainers.first,
              glyphsToShow.length > 0
        else { return }
        let containerWidth = textContainer.size.width
        guard containerWidth.isFinite, containerWidth > 0 else { return }

        enumerateLineFragments(forGlyphRange: glyphsToShow) { lineRect, _, _, lineGlyphRange, _ in
            let charRange = self.characterRange(forGlyphRange: lineGlyphRange, actualGlyphRange: nil)
            guard charRange.length > 0 else { return }
            guard self.rangeHasTemporarySelectionBackground(charRange) else { return }
            var full = lineRect
            full.origin.x = lineRect.minX
            full.size.width = max(0, containerWidth - lineRect.minX)
            guard let color = self.selectionBackgroundColor(forCharacterRange: charRange) else { return }
            let rect = NSOffsetRect(full, origin.x, origin.y)
            NSGraphicsContext.saveGraphicsState()
            color.setFill()
            NSBezierPath(rect: rect).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func rangeHasTemporarySelectionBackground(_ charRange: NSRange) -> Bool {
        var idx = charRange.location
        let end = NSMaxRange(charRange)
        while idx < end {
            var eff = NSRange()
            let attrs = temporaryAttributes(atCharacterIndex: idx, effectiveRange: &eff)
            if attrs[.backgroundColor] != nil {
                return true
            }
            if eff.length > 0 {
                idx = NSMaxRange(eff)
            } else {
                idx += 1
            }
        }
        return false
    }

    private func selectionBackgroundColor(forCharacterRange charRange: NSRange) -> NSColor? {
        var idx = charRange.location
        let end = NSMaxRange(charRange)
        while idx < end {
            var eff = NSRange()
            let attrs = temporaryAttributes(atCharacterIndex: idx, effectiveRange: &eff)
            if let bg = attrs[.backgroundColor] as? NSColor {
                return bg
            }
            if eff.length > 0 {
                idx = NSMaxRange(eff)
            } else {
                idx += 1
            }
        }
        return nil
    }
}

/// Selectable ANSI-colored output with full-width row selection and horizontal scrolling for long lines.
final class ANSIOutputTextView: NSTextView {
    var blockIndex: Int = -1 {
        didSet {
            if blockIndex >= 0, let coordinator = selectionCoordinator {
                coordinator.register(self, at: blockIndex)
            }
        }
    }
    weak var selectionCoordinator: BlockSelectionCoordinator? {
        didSet {
            if blockIndex >= 0, let coordinator = selectionCoordinator {
                coordinator.register(self, at: blockIndex)
            }
        }
    }
    var onPaneFocus: (() -> Void)?
    private var lastViewportWidth: CGFloat = -1
    private var lastAppliedContainerWidth: CGFloat = -1
    private var isInLayout = false
    private var cachedContentSize: NSSize = NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        if let container {
            super.init(frame: frameRect, textContainer: container)
        } else {
            let textStorage = NSTextStorage()
            let layoutManager = FullWidthSelectionTextLayoutManager()
            textStorage.addLayoutManager(layoutManager)
            let textContainer = NSTextContainer()
            layoutManager.addTextContainer(textContainer)
            super.init(frame: frameRect, textContainer: textContainer)
        }
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        minSize = NSSize(width: 0, height: 0)
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = false
        textContainer?.lineBreakMode = .byCharWrapping
        autoresizingMask = [.width]
        usesFontPanel = false
        allowsUndo = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
    }

    override var acceptsFirstResponder: Bool { true }

    func updateSelectionTint() {
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        onPaneFocus?()
        if blockIndex >= 0, let coordinator = selectionCoordinator {
            if event.modifierFlags.contains(.shift) {
                coordinator.handleShiftClick(at: blockIndex)
                return
            }
        }
        super.mouseDown(with: event)
        if blockIndex >= 0, let coordinator = selectionCoordinator {
            coordinator.recordAnchor(blockIndex)
        }
    }

    override func copy(_ sender: Any?) {
        if let coordinator = selectionCoordinator, coordinator.hasMultiBlockSelection {
            coordinator.copySelectedBlocksToClipboard()
            return
        }
        super.copy(sender)
    }

    override func layout() {
        guard !isInLayout else { return }
        isInLayout = true
        defer { isInLayout = false }
        super.layout()
        let viewport = enclosingScrollView.map { $0.contentView.bounds.width } ?? bounds.width
        applyViewportWidth(viewport)
    }

    func setOutputAttributedString(_ attributed: NSAttributedString) {
        textStorage?.setAttributedString(attributed)
        lastViewportWidth = -1
        lastAppliedContainerWidth = -1
        let viewport = enclosingScrollView.map { $0.contentView.bounds.width } ?? bounds.width
        applyViewportWidth(viewport)
    }

    func viewportDidChange(to newWidth: CGFloat) {
        applyViewportWidth(newWidth)
    }

    private func recomputeContentSize() -> NSSize {
        guard let layoutManager = layoutManager,
              let textContainer = textContainer,
              let textStorage = textStorage,
              textStorage.length > 0
        else {
            return NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }
        let fullRange = NSRange(location: 0, length: textStorage.length)
        layoutManager.ensureLayout(forCharacterRange: fullRange)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: fullRange, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let w = ceil(rect.width) + textContainerInset.width * 2
        let h = ceil(rect.height) + textContainerInset.height * 2
        return NSSize(width: w, height: h)
    }

    private func applyViewportWidth(_ viewportWidth: CGFloat) {
        guard let layoutManager = layoutManager,
              let textContainer = textContainer,
              let textStorage = textStorage
        else {
            return
        }
        if textStorage.length == 0 {
            lastViewportWidth = viewportWidth
            lastAppliedContainerWidth = -1
            self.frame = .zero
            let newSize = NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
            if cachedContentSize != newSize {
                cachedContentSize = newSize
                invalidateIntrinsicContentSize()
            }
            return
        }
        let inset = textContainerInset.width * 2
        let containerW = max(viewportWidth - inset, 1)

        if abs(containerW - lastAppliedContainerWidth) < 0.5,
           abs(viewportWidth - lastViewportWidth) < 0.5,
           abs(textContainer.size.width - containerW) < 0.5 {
            let newSize = recomputeContentSize()
            if cachedContentSize != newSize {
                cachedContentSize = newSize
                invalidateIntrinsicContentSize()
            }
            return
        }
        lastViewportWidth = viewportWidth
        lastAppliedContainerWidth = containerW

        let fullRange = NSRange(location: 0, length: textStorage.length)
        textContainer.containerSize = NSSize(width: containerW, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(forCharacterRange: fullRange)

        let glyphRange = layoutManager.glyphRange(forCharacterRange: fullRange, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let height = ceil(rect.height) + textContainerInset.height * 2
        let newFrame = NSRect(x: 0, y: 0, width: containerW, height: height)
        if self.frame != newFrame {
            self.frame = newFrame
        }

        let newSize = recomputeContentSize()
        if cachedContentSize != newSize {
            cachedContentSize = newSize
            invalidateIntrinsicContentSize()
        }
    }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        if !isInLayout {
            enclosingScrollView?.invalidateIntrinsicContentSize()
        }
    }

    /// Pure getter — returns the cached value computed during layout().
    /// No layout work here to avoid constraint feedback loops.
    override var intrinsicContentSize: NSSize {
        return cachedContentSize
    }
}

/// Forwards the document view's cached intrinsic size so SwiftUI does not
/// collapse the scroll view to zero height.
private final class HorizontalANSIOutputScrollView: NSScrollView {
    private var cachedSize: NSSize = NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    private var lastKnownContentWidth: CGFloat = -1

    /// Pure getter — no layout work, no side effects.
    override var intrinsicContentSize: NSSize {
        return cachedSize
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let newWidth = contentView.bounds.width
        if abs(newWidth - lastKnownContentWidth) > 0.5 {
            lastKnownContentWidth = newWidth
            if let textView = documentView as? ANSIOutputTextView {
                textView.viewportDidChange(to: newWidth)
            }
        }
    }

    override func layout() {
        super.layout()
        let newWidth = contentView.bounds.width
        if abs(newWidth - lastKnownContentWidth) > 0.5 {
            lastKnownContentWidth = newWidth
            if let textView = documentView as? ANSIOutputTextView {
                textView.viewportDidChange(to: newWidth)
            }
        }
        guard let doc = documentView else { return }
        let s = doc.intrinsicContentSize
        let newSize: NSSize
        if s.width != NSView.noIntrinsicMetric, s.height != NSView.noIntrinsicMetric {
            newSize = s
        } else {
            newSize = NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }
        if abs(newSize.width - cachedSize.width) > 0.5 ||
           abs(newSize.height - cachedSize.height) > 0.5 ||
           (newSize.width == NSView.noIntrinsicMetric) != (cachedSize.width == NSView.noIntrinsicMetric) {
            cachedSize = newSize
            invalidateIntrinsicContentSize()
        }
    }
}

/// Wraps `ANSIOutputTextView` in a horizontal `NSScrollView` so clip width drives full-row selection.
struct SelectableANSIOutputTextView: NSViewRepresentable {
    let attributedString: NSAttributedString
    var blockIndex: Int = -1
    var selectionCoordinator: BlockSelectionCoordinator?
    var onPaneFocus: (() -> Void)?

    func makeNSView(context _: Context) -> NSScrollView {
        let scrollView = HorizontalANSIOutputScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textView = ANSIOutputTextView(frame: .zero, textContainer: nil)
        textView.blockIndex = blockIndex
        textView.selectionCoordinator = selectionCoordinator
        textView.onPaneFocus = onPaneFocus
        scrollView.documentView = textView
        textView.setOutputAttributedString(attributedString)
        scrollView.invalidateIntrinsicContentSize()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context _: Context) {
        guard let textView = scrollView.documentView as? ANSIOutputTextView else { return }
        textView.blockIndex = blockIndex
        textView.selectionCoordinator = selectionCoordinator
        textView.onPaneFocus = onPaneFocus
        if textView.textStorage?.string != attributedString.string || fontSizeMismatch(textView) {
            textView.setOutputAttributedString(attributedString)
            scrollView.invalidateIntrinsicContentSize()
        }
    }

    private func fontSizeMismatch(_ textView: ANSIOutputTextView) -> Bool {
        guard attributedString.length > 0,
              let storage = textView.textStorage, storage.length > 0
        else { return false }
        let currentFont = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let newFont = attributedString.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        guard let c = currentFont?.pointSize, let n = newFont?.pointSize else { return false }
        return abs(c - n) > 0.01
    }
}
