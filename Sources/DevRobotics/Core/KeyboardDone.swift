import UIKit

/// App-wide "Done" button above the keyboard. Any UITextField / UITextView (so every SwiftUI TextField,
/// SecureField and TextEditor) that has no accessory view of its own gets a toolbar with Done.
/// Views that provide their own accessory (e.g. the story editor's formatting bar) include a Done button themselves
/// and call `KeyboardDone.dismiss()`.
@MainActor
final class KeyboardDone: NSObject {
    private static let shared = KeyboardDone()

    static func install() {
        let nc = NotificationCenter.default
        nc.addObserver(shared, selector: #selector(fieldDidBegin(_:)),
                       name: UITextField.textDidBeginEditingNotification, object: nil)
        nc.addObserver(shared, selector: #selector(viewDidBegin(_:)),
                       name: UITextView.textDidBeginEditingNotification, object: nil)
    }

    static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    @objc private func fieldDidBegin(_ n: Notification) {
        guard let f = n.object as? UITextField, f.inputAccessoryView == nil else { return }
        f.inputAccessoryView = Self.makeBar()
        f.reloadInputViews()
    }

    @objc private func viewDidBegin(_ n: Notification) {
        guard let v = n.object as? UITextView, v.inputAccessoryView == nil else { return }
        v.inputAccessoryView = Self.makeBar()
        v.reloadInputViews()
    }

    private static func makeBar() -> UIToolbar {
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        let done = UIBarButtonItem(title: "Done", image: nil, primaryAction: UIAction { _ in KeyboardDone.dismiss() })
        done.style = .done
        bar.items = [UIBarButtonItem(systemItem: .flexibleSpace), done]
        bar.sizeToFit()
        return bar
    }
}
