import UIKit

extension NSAttributedString.Key {
    /// Paragraph block kind ("bullet" / "quote") read by `FormatLayoutManager` to draw bullets and quote bars.
    static let mdBlock = NSAttributedString.Key("devrobotics.mdBlock")
}

/// Live Markdown styling. Inline syntax is invisible except around the caret; block syntax is drawn as styling.
/// Stored text is never modified here: only attributes.
enum MarkdownStyler {
    static let bodyFont = UIFont.systemFont(ofSize: 17)
    static let headingFont = UIFont.systemFont(ofSize: 24, weight: .bold)
    static let tinyFont = UIFont.systemFont(ofSize: 0.1)
    static let accent = UIColor(Theme.accent)

    static var baseAttributes: [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 4
        p.minimumLineHeight = 22
        return [.font: bodyFont, .foregroundColor: UIColor.label, .paragraphStyle: p]
    }

    private static func withTraits(_ f: UIFont, _ t: UIFontDescriptor.SymbolicTraits) -> UIFont {
        let d = f.fontDescriptor
        return UIFont(descriptor: d.withSymbolicTraits(d.symbolicTraits.union(t)) ?? d, size: f.pointSize)
    }

    /// `selection`: the caret / selection; syntax of spans touching it is shown (dimmed).
    static func style(_ storage: NSTextStorage, selection: NSRange? = nil) {
        let text = storage.string
        let s = text as NSString
        let full = NSRange(location: 0, length: s.length)
        let dim = UIColor.tertiaryLabel
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: full)

        func hide(_ r: NSRange) {
            guard r.length > 0 else { return }
            storage.addAttributes([.foregroundColor: UIColor.clear, .font: tinyFont], range: r)
        }
        func addTrait(_ t: UIFontDescriptor.SymbolicTraits, _ r: NSRange) {
            storage.enumerateAttribute(.font, in: r) { v, sub, _ in
                if let f = v as? UIFont { storage.addAttribute(.font, value: withTraits(f, t), range: sub) }
            }
        }

        // Block level
        s.enumerateSubstrings(in: full, options: [.byLines, .substringNotRequired]) { _, r, _, _ in
            let line = s.substring(with: r)
            let info = MarkdownSpans.block(ofLine: line)
            guard info.kind != .none else { return }
            let prefix = NSRange(location: r.location, length: min(info.prefixLength, r.length))
            let p = NSMutableParagraphStyle()
            p.lineSpacing = 4
            p.minimumLineHeight = 22
            switch info.kind {
            case .heading:
                p.minimumLineHeight = 30
                p.paragraphSpacingBefore = 6
                storage.addAttribute(.font, value: headingFont, range: r)
                hide(prefix)
            case .bullet:
                p.firstLineHeadIndent = 24; p.headIndent = 24
                storage.addAttribute(.mdBlock, value: "bullet", range: r)
                hide(prefix)
            case .numbered:
                p.firstLineHeadIndent = 0; p.headIndent = 26
                storage.addAttributes([.foregroundColor: UIColor.secondaryLabel,
                                       .font: UIFont.monospacedDigitSystemFont(ofSize: 17, weight: .semibold)], range: prefix)
            case .quote:
                p.firstLineHeadIndent = 18; p.headIndent = 18
                storage.addAttributes([.font: withTraits(bodyFont, .traitItalic), .foregroundColor: UIColor.secondaryLabel], range: r)
                storage.addAttribute(.mdBlock, value: "quote", range: r)
                hide(prefix)
            case .none: break
            }
            storage.addAttribute(.paragraphStyle, value: p, range: r)
        }

        // Inline
        let spans = MarkdownSpans.spans(in: text)
        let shown: [MDSpan] = selection.map { MarkdownSpans.revealed(spans, selection: $0) } ?? []
        for sp in spans {
            switch sp.kind {
            case .bold: addTrait(.traitBold, sp.content)
            case .italic: addTrait(.traitItalic, sp.content)
            case .link:
                storage.addAttributes([.foregroundColor: accent, .underlineStyle: NSUnderlineStyle.single.rawValue], range: sp.content)
            }
        }
        for sp in spans {
            let reveal = shown.contains(sp)
            for r in [sp.open, sp.close] {
                if reveal { storage.addAttribute(.foregroundColor, value: dim, range: r) } else { hide(r) }
            }
        }
        storage.endEditing()
    }
}

/// Draws bullets and quote bars behind/over text that `MarkdownStyler` marked with `.mdBlock`.
final class FormatLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, storage.length > 0 else { return }
        let ns = storage.string as NSString
        enumerateLineFragments(forGlyphRange: glyphsToShow) { rect, used, _, glyphRange, _ in
            let cr = self.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            guard cr.location < storage.length,
                  let kind = storage.attribute(.mdBlock, at: cr.location, effectiveRange: nil) as? String else { return }
            if kind == "quote" {
                let bar = CGRect(x: origin.x + 4, y: origin.y + rect.minY + 1, width: 3, height: rect.height - 2)
                MarkdownStyler.accent.setFill()
                UIBezierPath(roundedRect: bar, cornerRadius: 1.5).fill()
            } else if kind == "bullet", ns.lineRange(for: NSRange(location: cr.location, length: 0)).location == cr.location {
                let d: CGFloat = 6
                let dot = CGRect(x: origin.x + 8, y: origin.y + used.midY - d / 2, width: d, height: d)
                UIColor.label.setFill()
                UIBezierPath(ovalIn: dot).fill()
            }
        }
    }
}
