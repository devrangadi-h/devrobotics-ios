import SwiftUI
import UIKit

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

/// UITextView wrapper: live-styled Markdown (inline syntax hidden around the caret), self-sizing,
/// formatting accessory with active states and Done pinned right, link sheet, undoable programmatic edits.
struct LiveTextView: UIViewRepresentable {
    @Binding var text: String
    var placeholder = ""
    var wantsFocus = false
    var onFocusHandled: () -> Void = {}

    /// Screenshots only: `-demo -fmt-sample` shows sample Markdown in every text view (binding untouched).
    static let sampleOverride: String? = {
        guard DemoMode.isOn, ProcessInfo.processInfo.arguments.contains("-fmt-sample") else { return nil }
        return "## A heading\nPlain text with **bold**, *italic* and a [link](https://example.com) inline.\n- first bullet\n- second with **bold**\n1. one\n2. two\n> A quoted line\n> that wraps onto a second line when it is long enough to need it."
    }()

    func makeUIView(context: Context) -> UITextView {
        let storage = NSTextStorage()
        let lm = FormatLayoutManager()
        storage.addLayoutManager(lm)
        let container = NSTextContainer(size: CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        lm.addTextContainer(container)
        let tv = UITextView(frame: .zero, textContainer: container)
        tv.delegate = context.coordinator
        tv.backgroundColor = .clear
        tv.isScrollEnabled = false
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .sentences
        tv.smartQuotesType = .no
        tv.smartDashesType = .no
        tv.smartInsertDeleteType = .no
        tv.spellCheckingType = .no
        tv.allowsEditingTextAttributes = false
        if let drop = tv.textDropInteraction { tv.removeInteraction(drop) } // block-reorder drags must not insert their payload as text
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        tv.textContainer.lineFragmentPadding = 0
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.inputAccessoryView = context.coordinator.makeAccessory(for: tv)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        tv.addGestureRecognizer(tap)
        tv.text = Self.sampleOverride ?? text
        MarkdownStyler.style(tv.textStorage, selection: nil)
        tv.typingAttributes = MarkdownStyler.baseAttributes
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        context.coordinator.parent = self
        if Self.sampleOverride == nil, tv.text != text, tv.markedTextRange == nil {
            let sel = tv.selectedRange
            tv.text = text
            let loc = min(sel.location, (text as NSString).length)
            tv.selectedRange = NSRange(location: loc, length: 0)
            MarkdownStyler.style(tv.textStorage, selection: tv.isFirstResponder ? tv.selectedRange : nil)
            context.coordinator.refreshActive()
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
        let s = uiView.sizeThatFits(CGSize(width: w, height: CGFloat.greatestFiniteMagnitude))
        return CGSize(width: w, height: max(s.height, 40))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: LiveTextView
        weak var tv: UITextView?
        private var buttons: [String: UIButton] = [:]
        private var programmatic = false
        private var lastCaret = 0
        init(_ p: LiveTextView) { parent = p }

        // MARK: accessory

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

            func formatButton(_ key: String, _ icon: String, _ label: String, _ sel: Selector) -> UIButton {
                var cfg = UIButton.Configuration.plain()
                cfg.image = UIImage(systemName: icon)
                cfg.baseForegroundColor = .label
                cfg.background.cornerRadius = 10
                let b = UIButton(configuration: cfg)
                b.accessibilityLabel = label
                b.configurationUpdateHandler = { btn in
                    var c = btn.configuration
                    c?.baseForegroundColor = btn.isSelected ? MarkdownStyler.accent : .label
                    c?.background.backgroundColor = btn.isSelected ? MarkdownStyler.accent.withAlphaComponent(0.18) : .clear
                    btn.configuration = c
                }
                b.addTarget(self, action: sel, for: .touchUpInside)
                b.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([b.widthAnchor.constraint(equalToConstant: 44),
                                             b.heightAnchor.constraint(equalToConstant: 44)])
                buttons[key] = b
                return b
            }
            let stack = UIStackView(arrangedSubviews: [
                formatButton("bold", "bold", "Bold", #selector(bold)),
                formatButton("italic", "italic", "Italic", #selector(italic)),
                formatButton("link", "link", "Link", #selector(link)),
                formatButton("heading", "textformat.size", "Heading", #selector(heading)),
                formatButton("bullet", "list.bullet", "Bullets", #selector(bullets)),
                formatButton("numbered", "list.number", "Numbered list", #selector(numbered)),
                formatButton("quote", "text.quote", "Quote", #selector(quote)),
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

        /// Highlight the buttons whose format the caret / selection is already in.
        func refreshActive() {
            guard let tv else { return }
            let text = tv.text ?? ""
            let sel = tv.selectedRange
            let spans = MarkdownSpans.spans(in: text)
            let block = MarkdownSpans.blockKind(text, sel)
            buttons["bold"]?.isSelected = MarkdownSpans.span(.bold, containing: sel, in: spans) != nil
            buttons["italic"]?.isSelected = MarkdownSpans.span(.italic, containing: sel, in: spans) != nil
            buttons["link"]?.isSelected = MarkdownSpans.span(.link, containing: sel, in: spans) != nil
            buttons["heading"]?.isSelected = block == .heading
            buttons["bullet"]?.isSelected = block == .bullet
            buttons["numbered"]?.isSelected = block == .numbered
            buttons["quote"]?.isSelected = block == .quote
        }

        // MARK: undoable edits

        /// Replace `range` with `string` through UITextInput so the text view's undo manager records it.
        private func replace(_ range: NSRange, with string: String, selection: NSRange) {
            guard let tv else { return }
            programmatic = true
            defer { programmatic = false }
            if let s = tv.position(from: tv.beginningOfDocument, offset: range.location),
               let e = tv.position(from: s, offset: range.length),
               let r = tv.textRange(from: s, to: e) {
                tv.replace(r, withText: string)
            } else {
                tv.textStorage.replaceCharacters(in: range, with: string)
            }
            tv.selectedRange = selection
            textViewDidChange(tv)
        }

        /// Apply a whole-text edit as one minimal (undoable) replacement.
        private func apply(_ edit: (text: String, selection: NSRange)) {
            guard let tv else { return }
            let old = (tv.text ?? "") as NSString
            let new = edit.text as NSString
            var p = 0
            let minLen = min(old.length, new.length)
            while p < minLen, old.character(at: p) == new.character(at: p) { p += 1 }
            var sfx = 0
            while sfx < minLen - p, old.character(at: old.length - 1 - sfx) == new.character(at: new.length - 1 - sfx) { sfx += 1 }
            // never split a surrogate pair / composed sequence
            if p > 0, p < old.length { p = old.rangeOfComposedCharacterSequence(at: p).location }
            if p > 0, p < new.length { p = min(p, new.rangeOfComposedCharacterSequence(at: p).location) }
            sfx = min(sfx, old.length - p, new.length - p)
            if old.length - sfx > 0, sfx > 0 {
                let b = old.length - sfx
                if old.rangeOfComposedCharacterSequence(at: b).location != b { sfx = 0 }
            }
            let oldR = NSRange(location: p, length: old.length - p - sfx)
            let repl = new.substring(with: NSRange(location: p, length: new.length - p - sfx))
            if oldR.length == 0 && repl.isEmpty { tv.selectedRange = edit.selection; textViewDidChange(tv); return }
            replace(oldR, with: repl, selection: edit.selection)
        }

        // MARK: actions

        @objc func bold() { guard let tv else { return }; apply(MarkdownSpans.toggleInline(tv.text, tv.selectedRange, kind: .bold)) }
        @objc func italic() { guard let tv else { return }; apply(MarkdownSpans.toggleInline(tv.text, tv.selectedRange, kind: .italic)) }
        @objc func heading() { block { LineEdit.toggle($0, $1, prefix: "## ") } }
        @objc func bullets() { block { LineEdit.toggle($0, $1, prefix: "- ") } }
        @objc func numbered() { block { LineEdit.toggle($0, $1, prefix: "1. ", numbered: true) } }
        @objc func quote() { block { LineEdit.toggle($0, $1, prefix: "> ") } }
        @objc func done() { KeyboardDone.dismiss() }
        @objc func link() { presentLinkSheet(at: nil) }

        private func block(_ edit: (String, NSRange) -> FrameFormat.Edit) {
            guard let tv else { return }
            apply(edit(tv.text ?? "", tv.selectedRange))
        }

        // MARK: link sheet

        @objc func tapped(_ g: UITapGestureRecognizer) {
            guard let tv, g.state == .ended else { return }
            var p = g.location(in: tv)
            p.x -= tv.textContainerInset.left; p.y -= tv.textContainerInset.top
            let lm = tv.layoutManager
            guard lm.numberOfGlyphs > 0 else { return }
            let gi = lm.glyphIndex(for: p, in: tv.textContainer)
            let r = lm.boundingRect(forGlyphRange: NSRange(location: gi, length: 1), in: tv.textContainer).insetBy(dx: -2, dy: -4)
            guard r.contains(p) else { return }
            let idx = lm.characterIndexForGlyph(at: gi)
            let text = tv.text ?? ""
            if let sp = MarkdownSpans.spans(in: text).first(where: { $0.kind == .link && idx >= $0.content.location && idx < NSMaxRange($0.content) }) {
                presentLinkSheet(at: sp)
            }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool { true }

        private func presentLinkSheet(at tapped: MDSpan?) {
            guard let tv else { return }
            let text = tv.text ?? ""
            let ns = text as NSString
            let sel = tv.selectedRange
            let existing = tapped ?? MarkdownSpans.span(.link, containing: sel, in: MarkdownSpans.spans(in: text))
            var replace = sel
            var label = ""
            var url = ""
            if let e = existing {
                replace = e.full
                label = ns.substring(with: e.content)
                url = e.url ?? ""
            } else if sel.length > 0 {
                label = ns.substring(with: sel)
            } else if let w = MarkdownSpans.wordRange(in: text, at: sel.location) {
                replace = w
                label = ns.substring(with: w)
            }
            let before = text
            func finish(_ edit: (text: String, selection: NSRange)?) {
                tv.window?.rootViewController?.presentedViewController?.dismiss(animated: true)
                topController(for: tv)?.dismiss(animated: true)
                if let edit, (tv.text ?? "") == before { apply(edit) }
                tv.becomeFirstResponder()
            }
            let sheet = LinkSheet(
                isEditing: existing != nil, initialText: MarkdownSpans.sanitizeLabel(label), initialURL: url,
                onSave: { t, u in finish(MarkdownSpans.applyLink(before, replace: replace, label: t, url: u)) },
                onRemove: { if let e = existing { finish(MarkdownSpans.removeLink(before, span: e)) } },
                onCancel: { finish(nil) })
            let host = UIHostingController(rootView: sheet)
            host.modalPresentationStyle = .pageSheet
            host.sheetPresentationController?.detents = [.medium()]
            guard var presenter = viewController(of: tv) else { return }
            while let n = presenter.presentedViewController { presenter = n }
            presenter.present(host, animated: true)
        }

        private func viewController(of v: UIView) -> UIViewController? {
            var r: UIResponder? = v
            while let n = r?.next {
                if let vc = n as? UIViewController { return vc }
                r = n
            }
            return v.window?.rootViewController
        }

        private func topController(for v: UIView) -> UIViewController? {
            guard var t = v.window?.rootViewController else { return nil }
            var last: UIViewController?
            while let n = t.presentedViewController { last = n; t = n }
            return (last as? UIHostingController<LinkSheet>) ?? nil
        }

        // MARK: delegate

        func textViewDidChange(_ tv: UITextView) {
            if tv.markedTextRange == nil {
                MarkdownStyler.style(tv.textStorage, selection: tv.isFirstResponder ? tv.selectedRange : nil)
                tv.typingAttributes = MarkdownStyler.baseAttributes
            }
            if parent.text != tv.text, LiveTextView.sampleOverride == nil { parent.text = tv.text }
            tv.invalidateIntrinsicContentSize()
            refreshActive()
        }

        func textViewDidChangeSelection(_ tv: UITextView) {
            guard !programmatic else { return }
            var sel = tv.selectedRange
            // keep a bare caret out of hidden block syntax ("## ", "- ", "> ")
            if sel.length == 0, tv.markedTextRange == nil {
                let ns = tv.text as NSString
                if sel.location <= ns.length {
                    let line = ns.lineRange(for: NSRange(location: sel.location, length: 0))
                    let info = MarkdownSpans.block(ofLine: ns.substring(with: line))
                    let hidden = info.kind == .heading || info.kind == .bullet || info.kind == .quote
                    let end = line.location + info.prefixLength
                    if hidden, sel.location < end, end <= ns.length {
                        var target = end
                        if lastCaret >= end, line.location > 0 { target = line.location - 1 }
                        sel = NSRange(location: target, length: 0)
                        tv.selectedRange = sel
                    }
                }
            }
            lastCaret = sel.location
            if tv.markedTextRange == nil {
                MarkdownStyler.style(tv.textStorage, selection: sel)
                tv.typingAttributes = MarkdownStyler.baseAttributes
            }
            refreshActive()
        }

        /// Return inside a list continues it; return on an empty item ends it. Backspace right after a
        /// hidden/visible block prefix removes the whole prefix.
        func textView(_ tv: UITextView, shouldChangeTextIn range: NSRange, replacementText t: String) -> Bool {
            guard !programmatic else { return true }
            let ns = tv.text as NSString
            if t.isEmpty, range.length == 1, range.location < ns.length {
                let line = ns.lineRange(for: NSRange(location: range.location, length: 0))
                var content = ns.substring(with: line)
                if content.hasSuffix("\n") { content.removeLast() }
                let info = MarkdownSpans.block(ofLine: content)
                if info.kind != .none, range.location + 1 == line.location + info.prefixLength {
                    replace(NSRange(location: line.location, length: info.prefixLength), with: "",
                            selection: NSRange(location: line.location, length: 0))
                    return false
                }
                return true
            }
            guard t == "\n", range.length == 0 else { return true }
            let line = ns.lineRange(for: NSRange(location: range.location, length: 0))
            var content = ns.substring(with: line)
            if content.hasSuffix("\n") { content.removeLast() }
            let info = MarkdownSpans.block(ofLine: content)
            var next: String?
            switch info.kind {
            case .bullet: next = (content as NSString).substring(to: info.prefixLength)
            case .quote: next = "> "
            case .numbered:
                let m = (content as NSString).substring(to: info.prefixLength)
                next = "\((Int(m.dropLast(2)) ?? 0) + 1). "
            default: break
            }
            guard let next else { return true }
            let marker = (content as NSString).substring(to: info.prefixLength)
            if content == marker {   // empty item: end the list
                replace(NSRange(location: line.location, length: info.prefixLength), with: "",
                        selection: NSRange(location: line.location, length: 0))
                return false
            }
            replace(range, with: "\n" + next,
                    selection: NSRange(location: range.location + 1 + (next as NSString).length, length: 0))
            return false
        }
    }
}
