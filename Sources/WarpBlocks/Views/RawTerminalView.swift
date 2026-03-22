import AppKit
import SwiftUI

struct RawTerminalView: NSViewRepresentable {
    let ptySession: PTYSession
    @Binding var rawOutput: Data

    func makeCoordinator() -> Coordinator {
        Coordinator(ptySession: ptySession)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true

        let textView = RawTerminalTextView()
        textView.isRichText = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = NSColor.white
        textView.backgroundColor = NSColor.black
        textView.drawsBackground = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineBreakMode = .byCharWrapping
        textView.ptySession = ptySession

        scrollView.documentView = textView
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor.black
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if !rawOutput.isEmpty {
            let text = String(decoding: rawOutput, as: UTF8.self)
            let storage = textView.textStorage!
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor.white
            ]
            storage.append(NSAttributedString(string: text, attributes: attrs))

            let maxChars = 256_000
            if storage.length > maxChars {
                let excess = storage.length - maxChars
                storage.deleteCharacters(in: NSRange(location: 0, length: excess))
            }

            textView.scrollToEndOfDocument(nil)
        }
    }

    class Coordinator {
        let ptySession: PTYSession
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?

        init(ptySession: PTYSession) {
            self.ptySession = ptySession
        }
    }
}

class RawTerminalTextView: NSTextView {
    weak var ptySession: PTYSession?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let ptySession else {
            super.keyDown(with: event)
            return
        }

        if let text = keyEventToTerminalBytes(event) {
            ptySession.sendText(text)
        }
    }

    private func keyEventToTerminalBytes(_ event: NSEvent) -> String? {
        let keyCode = event.keyCode
        let hasCtrl = event.modifierFlags.contains(.control)

        switch keyCode {
        case 126: return "\u{1b}[A"
        case 125: return "\u{1b}[B"
        case 124: return "\u{1b}[C"
        case 123: return "\u{1b}[D"
        case 115: return "\u{1b}[H"
        case 119: return "\u{1b}[F"
        case 116: return "\u{1b}[5~"
        case 121: return "\u{1b}[6~"
        case 117: return "\u{1b}[3~"
        case 36: return "\r"
        case 48: return "\t"
        case 51: return "\u{7f}"
        case 53: return "\u{1b}"
        case 122: return "\u{1b}OP"
        case 120: return "\u{1b}OQ"
        case 99: return "\u{1b}OR"
        case 118: return "\u{1b}OS"
        default: break
        }

        if hasCtrl, let chars = event.charactersIgnoringModifiers, let c = chars.first {
            let val = c.asciiValue ?? 0
            if val >= 0x61 && val <= 0x7a {
                return String(UnicodeScalar(val - 0x60))
            }
        }

        return event.characters
    }
}
