import SwiftUI
import UIKit


/// Live Markdown styling: syntax characters stay visible but dimmed.
enum MarkdownStyler {
    static let bodyFont = UIFont.systemFont(ofSize: 17)
    private static let bold = try! NSRegularExpression(pattern: #"\*\*([^*\n]+?)\*\*"#)
    private static let italic = try! NSRegularExpression(pattern: #"(?<!\*)\*(?!\*)([^*\n]+?)(?<!\*)\*(?!\*)"#)
    private static let link = try! NSRegularExpression(pattern: #"\[([^\]\n]+)\](\([^)\n]*\))"#)

    static var baseAttributes: [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 4
        return [.font: bodyFont, .foregroundColor: UIColor.label, .paragraphStyle: p]
    }

    private static func withTraits(_ f: UIFont, _ t: UIFontDescriptor.SymbolicTraits) -> UIFont {
        let d = f.fontDescriptor
        let merged = d.symbolicTraits.union(t)
        return UIFont(descriptor: d.withSymbolicTraits(merged) ?? d, size: f.pointSize)
    }

    static func style(_ storage: NSTextStorage) {
        let s = storage.string as NSString
        let full = NSRange(location: 0, length: s.length)
        let dim = UIColor.tertiaryLabel
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: full)
        // line level
        s.enumerateSubstrings(in: full, options: [.byLines, .substringNotRequired]) { _, r, _, _ in
            let line = s.substring(with: r)
            func marker(_ n: Int, _ color: UIColor) {
                storage.addAttribute(.foregroundColor, value: color, range: NSRange(location: r.location, length: min(n, r.length)))
            }
            if line.hasPrefix("## ") || line.hasPrefix("# ") {
                storage.addAttribute(.font, value: UIFont.systemFont(ofSize: 24, weight: .bold), range: r)
                marker(line.hasPrefix("## ") ? 3 : 2, dim)
            } else if line.hasPrefix("> ") {
                storage.addAttribute(.font, value: withTraits(bodyFont, .traitItalic), range: r)
                storage.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: r)
                marker(2, UIColor(Theme.accent))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                marker(2, UIColor(Theme.accent))
            } else if let m = line.range(of: #"^\d+\. "#, options: .regularExpression) {
                marker(line.distance(from: line.startIndex, to: m.upperBound), UIColor(Theme.accent))
            }
        }
        func each(_ re: NSRegularExpression, _ body: (NSTextCheckingResult) -> Void) {
            re.enumerateMatches(in: storage.string, range: full) { m, _, _ in if let m { body(m) } }
        }
        func addTrait(_ t: UIFontDescriptor.SymbolicTraits, _ r: NSRange) {
            storage.enumerateAttribute(.font, in: r) { v, sub, _ in
                if let f = v as? UIFont { storage.addAttribute(.font, value: withTraits(f, t), range: sub) }
            }
        }
        each(bold) { m in
            addTrait(.traitBold, m.range(at: 1))
            storage.addAttribute(.foregroundColor, value: dim, range: NSRange(location: m.range.location, length: 2))
            storage.addAttribute(.foregroundColor, value: dim, range: NSRange(location: m.range.location + m.range.length - 2, length: 2))
        }
        each(italic) { m in
            addTrait(.traitItalic, m.range(at: 1))
            storage.addAttribute(.foregroundColor, value: dim, range: NSRange(location: m.range.location, length: 1))
            storage.addAttribute(.foregroundColor, value: dim, range: NSRange(location: m.range.location + m.range.length - 1, length: 1))
        }
        each(link) { m in
            let label = m.range(at: 1), url = m.range(at: 2)
            storage.addAttribute(.foregroundColor, value: UIColor(Theme.accent), range: label)
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: label)
            storage.addAttribute(.foregroundColor, value: dim, range: NSRange(location: m.range.location, length: 1))
            storage.addAttribute(.foregroundColor, value: dim, range: NSRange(location: label.location + label.length, length: 1 + url.length))
        }
        storage.endEditing()
    }
}

/// Pure line-level edits used by the accessory toolbar.
enum LineEdit {
    /// Toggle `prefix` (or "N. " when `numbered`) on every line touched by the selection.
    static func toggle(_ text: String, _ sel: NSRange, prefix: String, numbered: Bool = false) -> FrameFormat.Edit {
        let ns = text as NSString
        let loc = min(max(sel.location, 0), ns.length)
        let sel = NSRange(location: loc, length: min(max(sel.length, 0), ns.length - loc))
        let range = ns.lineRange(for: sel)
        var body = ns.substring(with: range)
        let trailingNL = body.hasSuffix("\n")
        if trailingNL { body.removeLast() }
        let lines = body.components(separatedBy: "\n")
        func existing(_ l: String) -> Int? {
            if numbered {
                if let r = l.range(of: #"^\d+\. "#, options: .regularExpression) { return l.distance(from: l.startIndex, to: r.upperBound) }
                return nil
            }
            return l.hasPrefix(prefix) ? prefix.count : nil
        }
        let nonEmpty = lines.filter { !$0.isEmpty }
        let removing = !nonEmpty.isEmpty ? nonEmpty.allSatisfy { existing($0) != nil } : lines.allSatisfy { existing($0) != nil }
        var n = 0
        let out = lines.map { l -> String in
            if removing { return existing(l).map { String(l.dropFirst($0)) } ?? l }
            if l.isEmpty && lines.count > 1 { return l }
            n += 1
            // replace a different block prefix rather than stacking
            var core = l
            for p in ["## ", "# ", "> ", "- ", "* "] where core.hasPrefix(p) { core = String(core.dropFirst(p.count)); break }
            if let r = core.range(of: #"^\d+\. "#, options: .regularExpression) { core.removeSubrange(r) }
            return (numbered ? "\(n). " : prefix) + core
        }
        let new = out.joined(separator: "\n") + (trailingNL ? "\n" : "")
        let result = ns.replacingCharacters(in: range, with: new)
        let newLen = (new as NSString).length - (trailingNL ? 1 : 0)
        if lines.count == 1 && sel.length == 0 {
            let delta = (new as NSString).length - (body as NSString).length - (trailingNL ? 1 : 0)
            return (result, NSRange(location: max(range.location, sel.location + delta), length: 0))
        }
        return (result, NSRange(location: range.location, length: max(newLen, 0)))
    }
}

/// UITextView wrapper: live-styled Markdown, self-sizing (no inner scrolling), formatting accessory with Done.
struct LiveTextView: UIViewRepresentable {
    @Binding var text: String
    var placeholder = ""
    var wantsFocus = false
    var onFocusHandled: () -> Void = {}

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.backgroundColor = .clear
        tv.isScrollEnabled = false
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .sentences
        tv.smartQuotesType = .no
        tv.smartDashesType = .no
        tv.smartInsertDeleteType = .no
        tv.spellCheckingType = .no
        if let drop = tv.textDropInteraction { tv.removeInteraction(drop) } // block-reorder drags must not insert their payload as text
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        tv.textContainer.lineFragmentPadding = 0
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.inputAccessoryView = context.coordinator.makeAccessory(for: tv)
        tv.text = text
        MarkdownStyler.style(tv.textStorage)
        tv.typingAttributes = MarkdownStyler.baseAttributes
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        context.coordinator.parent = self
        if tv.text != text, tv.markedTextRange == nil {
            let sel = tv.selectedRange
            tv.text = text
            MarkdownStyler.style(tv.textStorage)
            tv.selectedRange = NSRange(location: min(sel.location, (text as NSString).length), length: 0)
        }
        if wantsFocus, !tv.isFirstResponder {
            DispatchQueue.main.async {
                tv.becomeFirstResponder()
                onFocusHandled()
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let w = proposal.width ?? 320
        let s = uiView.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude))
        return CGSize(width: w, height: max(s.height, 40))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: LiveTextView
        weak var tv: UITextView?
        init(_ p: LiveTextView) { parent = p }

        /// Formatting bar above the keyboard. Formatting buttons scroll horizontally if the screen is narrow;
        /// Done is pinned to the trailing edge so it can never be pushed off-screen.
        func makeAccessory(for tv: UITextView) -> UIView {
            self.tv = tv
            let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 52))
            container.autoresizingMask = [.flexibleWidth]

            let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
            blur.frame = container.bounds
            blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(blur)

            func formatButton(_ icon: String, _ label: String, _ sel: Selector) -> UIButton {
                var cfg = UIButton.Configuration.plain()
                cfg.image = UIImage(systemName: icon)
                cfg.baseForegroundColor = .label
                let b = UIButton(configuration: cfg)
                b.accessibilityLabel = label
                b.addTarget(self, action: sel, for: .touchUpInside)
                b.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([b.widthAnchor.constraint(equalToConstant: 44),
                                             b.heightAnchor.constraint(equalToConstant: 44)])
                return b
            }
            let stack = UIStackView(arrangedSubviews: [
                formatButton("bold", "Bold", #selector(bold)),
                formatButton("italic", "Italic", #selector(italic)),
                formatButton("link", "Link", #selector(link)),
                formatButton("textformat.size", "Heading", #selector(heading)),
                formatButton("list.bullet", "Bullets", #selector(bullets)),
                formatButton("list.number", "Numbered list", #selector(numbered)),
                formatButton("text.quote", "Quote", #selector(quote)),
            ])
            stack.axis = .horizontal
            stack.spacing = 2
            stack.translatesAutoresizingMaskIntoConstraints = false

            let scroll = UIScrollView()
            scroll.showsHorizontalScrollIndicator = false
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.addSubview(stack)

            var doneCfg = UIButton.Configuration.prominentGlass()
            doneCfg.title = "Done"
            doneCfg.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
            let done = UIButton(configuration: doneCfg)
            done.accessibilityLabel = "Done"
            done.addTarget(self, action: #selector(self.done), for: .touchUpInside)
            done.setContentHuggingPriority(.required, for: .horizontal)
            done.setContentCompressionResistancePriority(.required, for: .horizontal)
            done.translatesAutoresizingMaskIntoConstraints = false

            container.addSubview(scroll)
            container.addSubview(done)
            NSLayoutConstraint.activate([
                done.trailingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.trailingAnchor, constant: -12),
                done.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                scroll.leadingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.leadingAnchor, constant: 8),
                scroll.trailingAnchor.constraint(equalTo: done.leadingAnchor, constant: -8),
                scroll.topAnchor.constraint(equalTo: container.topAnchor),
                scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
                stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
                stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
                stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            ])
            return container
        }

        private func apply(_ edit: (String, NSRange) -> FrameFormat.Edit) {
            guard let tv else { return }
            let r = edit(tv.text ?? "", tv.selectedRange)
            tv.text = r.text
            tv.selectedRange = r.selection
            textViewDidChange(tv)
        }

        @objc func bold() { apply { FrameFormat.wrap($0, $1, prefix: "**", suffix: "**", placeholder: "bold") } }
        @objc func italic() { apply { FrameFormat.wrap($0, $1, prefix: "*", suffix: "*", placeholder: "italic") } }
        @objc func link() { apply { FrameFormat.link($0, $1) } }
        @objc func heading() { apply { LineEdit.toggle($0, $1, prefix: "## ") } }
        @objc func bullets() { apply { LineEdit.toggle($0, $1, prefix: "- ") } }
        @objc func numbered() { apply { LineEdit.toggle($0, $1, prefix: "1. ", numbered: true) } }
        @objc func quote() { apply { LineEdit.toggle($0, $1, prefix: "> ") } }
        @objc func done() { KeyboardDone.dismiss() }

        func textViewDidChange(_ tv: UITextView) {
            if tv.markedTextRange == nil {
                MarkdownStyler.style(tv.textStorage)
                tv.typingAttributes = MarkdownStyler.baseAttributes
            }
            if parent.text != tv.text { parent.text = tv.text }
            tv.invalidateIntrinsicContentSize()
        }

        /// Return inside a list continues it; return on an empty item ends it.
        func textView(_ tv: UITextView, shouldChangeTextIn range: NSRange, replacementText t: String) -> Bool {
            guard t == "\n", range.length == 0 else { return true }
            let ns = tv.text as NSString
            let line = ns.lineRange(for: NSRange(location: range.location, length: 0))
            var content = ns.substring(with: line)
            if content.hasSuffix("\n") { content.removeLast() }
            var marker: String?
            var next = ""
            if content.hasPrefix("- ") { marker = "- "; next = "- " }
            else if content.hasPrefix("> ") { marker = nil }
            else if let r = content.range(of: #"^(\d+)\. "#, options: .regularExpression) {
                let m = String(content[r])
                marker = m
                next = "\((Int(m.dropLast(2)) ?? 0) + 1). "
            }
            guard let marker else { return true }
            if content == marker {
                tv.textStorage.replaceCharacters(in: NSRange(location: line.location, length: (marker as NSString).length), with: "")
                tv.selectedRange = NSRange(location: line.location, length: 0)
                textViewDidChange(tv)
                return false
            }
            tv.textStorage.replaceCharacters(in: range, with: "\n" + next)
            tv.selectedRange = NSRange(location: range.location + 1 + (next as NSString).length, length: 0)
            textViewDidChange(tv)
            return false
        }
    }
}
