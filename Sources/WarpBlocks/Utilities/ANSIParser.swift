import AppKit
import Foundation

enum ANSIParser {
    static func attributedString(
        from raw: String,
        baseColor: NSColor,
        fontSize: CGFloat = NSFont.smallSystemFontSize
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var i = raw.startIndex
        var bold = false
        var italic = false
        var underline = false
        var fg: NSColor = baseColor
        var bg: NSColor? = nil

        func appendRun(_ slice: Substring) {
            guard !slice.isEmpty else { return }
            let font = fontFor(bold: bold, italic: italic, size: fontSize)
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: fg
            ]
            if underline {
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            if let bg {
                attrs[.backgroundColor] = bg
            }
            result.append(NSAttributedString(string: String(slice), attributes: attrs))
        }

        while i < raw.endIndex {
            if raw[i] == "\u{1b}", raw.index(after: i) < raw.endIndex, raw[raw.index(after: i)] == "[" {
                var j = raw.index(i, offsetBy: 2)
                while j < raw.endIndex, raw[j] != "m" {
                    j = raw.index(after: j)
                }
                guard j < raw.endIndex else {
                    break
                }
                let code = String(raw[raw.index(i, offsetBy: 2)..<j])
                applySGR(
                    code,
                    baseColor: baseColor,
                    bold: &bold,
                    italic: &italic,
                    underline: &underline,
                    fg: &fg,
                    bg: &bg
                )
                i = raw.index(after: j)
                continue
            }
            if raw[i] == "\u{1b}" {
                i = raw.index(after: i)
                continue
            }
            let nextEsc = raw[i...].firstIndex(of: "\u{1b}") ?? raw.endIndex
            appendRun(raw[i..<nextEsc])
            i = nextEsc
        }

        if result.length == 0 {
            let mono = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            return NSAttributedString(string: "", attributes: [.font: mono, .foregroundColor: baseColor])
        }
        return result
    }

    private static func fontFor(bold: Bool, italic: Bool, size: CGFloat) -> NSFont {
        let weight: NSFont.Weight = bold ? .semibold : .regular
        let base = NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        if italic {
            let desc = base.fontDescriptor.withSymbolicTraits(.italic)
            return NSFont(descriptor: desc, size: base.pointSize) ?? base
        }
        return base
    }

    private static func applySGR(
        _ code: String,
        baseColor: NSColor,
        bold: inout Bool,
        italic: inout Bool,
        underline: inout Bool,
        fg: inout NSColor,
        bg: inout NSColor?
    ) {
        let parts = code.split(separator: ";", omittingEmptySubsequences: false).map { String($0) }
        guard !parts.isEmpty else { return }
        if parts == [""] || parts == ["0"] {
            bold = false
            italic = false
            underline = false
            fg = baseColor
            bg = nil
            return
        }
        var k = 0
        while k < parts.count {
            let p = parts[k]
            guard let n = Int(p) else { k += 1; continue }
            switch n {
            case 0:
                bold = false
                italic = false
                underline = false
                fg = baseColor
                bg = nil
            case 1:
                bold = true
            case 3:
                italic = true
            case 4:
                underline = true
            case 22:
                bold = false
            case 23:
                italic = false
            case 24:
                underline = false
            case 30: fg = .black
            case 31: fg = .systemRed
            case 32: fg = .systemGreen
            case 33: fg = .systemYellow
            case 34: fg = .systemBlue
            case 35: fg = .systemPurple
            case 36: fg = .systemCyan
            case 37: fg = .labelColor
            case 39:
                fg = baseColor
            case 40: bg = .black
            case 41: bg = .systemRed
            case 42: bg = .systemGreen
            case 43: bg = .systemYellow
            case 44: bg = .systemBlue
            case 45: bg = .systemPurple
            case 46: bg = .systemCyan
            case 47: bg = .labelColor
            case 49:
                bg = nil
            case 38 where k + 2 < parts.count && parts[k + 1] == "5":
                if let idx = Int(parts[k + 2]), let c = ansi256Color(idx) {
                    fg = c
                }
                k += 2
            case 38 where k + 4 < parts.count && parts[k + 1] == "2":
                if let r = Int(parts[k + 2]), let g = Int(parts[k + 3]), let b = Int(parts[k + 4]) {
                    fg = NSColor(calibratedRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
                }
                k += 4
            case 48 where k + 2 < parts.count && parts[k + 1] == "5":
                if let idx = Int(parts[k + 2]), let c = ansi256Color(idx) {
                    bg = c
                }
                k += 2
            case 48 where k + 4 < parts.count && parts[k + 1] == "2":
                if let r = Int(parts[k + 2]), let g = Int(parts[k + 3]), let b = Int(parts[k + 4]) {
                    bg = NSColor(calibratedRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
                }
                k += 4
            default:
                break
            }
            k += 1
        }
    }

    private static func ansi256Color(_ idx: Int) -> NSColor? {
        if idx < 0 { return nil }
        if idx < 16 {
            let basic: [NSColor] = [
                .black, .systemRed, .systemGreen, .systemYellow, .systemBlue, .systemPurple, .systemCyan, .white,
                .darkGray, .systemRed, .systemGreen, .systemYellow, .systemBlue, .systemPurple, .systemCyan, .white
            ]
            return basic[idx]
        }
        if idx >= 232 {
            let level = idx - 232
            let v = CGFloat(level) * 255 / 24
            return NSColor(calibratedRed: v / 255, green: v / 255, blue: v / 255, alpha: 1)
        }
        let i = idx - 16
        let r = i / 36
        let g = (i % 36) / 6
        let b = i % 6
        let rf = CGFloat(r == 0 ? 0 : 55 + r * 40) / 255
        let gf = CGFloat(g == 0 ? 0 : 55 + g * 40) / 255
        let bf = CGFloat(b == 0 ? 0 : 55 + b * 40) / 255
        return NSColor(calibratedRed: rf, green: gf, blue: bf, alpha: 1)
    }
}
