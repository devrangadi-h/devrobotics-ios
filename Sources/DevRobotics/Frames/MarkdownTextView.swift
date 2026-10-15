import SwiftUI
import UIKit

/// Lets the toolbar edit at the cursor of the wrapped UITextView.
@MainActor
final class MarkdownController {
    fileprivate weak var textView: UITextView?

    var isAttached: Bool { textView != nil }

    func apply(_ edit: (String, NSRange) -> FrameFormat.Edit) {
        guard let tv = textView else { return }
        let r = edit(tv.text ?? "", tv.selectedRange)
        tv.text = r.text
        tv.selectedRange = r.selection
        tv.delegate?.textViewDidChange?(tv)
    }
}

/// Plain UITextView with smart quotes/dashes/autocorrect off so markers stay straight-quoted.
struct MarkdownTextView: UIViewRepresentable {
    @Binding var text: String
    let controller: MarkdownController

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .sentences
        tv.smartQuotesType = .no
        tv.smartDashesType = .no
        tv.smartInsertDeleteType = .no
        tv.spellCheckingType = .no
        tv.alwaysBounceVertical = true
        tv.keyboardDismissMode = .interactive
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        tv.text = text
        controller.textView = tv
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        context.coordinator.parent = self
        controller.textView = tv
        if tv.text != text { tv.text = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownTextView
        init(_ p: MarkdownTextView) { parent = p }
        func textViewDidChange(_ tv: UITextView) { parent.text = tv.text }
    }
}
