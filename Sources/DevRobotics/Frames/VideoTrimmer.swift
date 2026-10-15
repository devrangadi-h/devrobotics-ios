import SwiftUI
import UIKit
import AVFoundation

/// System trim UI (UIVideoEditorController). The trim handles are capped at `MediaPicking.maxClipSeconds`,
/// so the saved clip can't exceed the 10 s limit the Frames pipeline enforces.
struct VideoTrimmer: UIViewControllerRepresentable {
    let url: URL
    /// Called exactly once: the trimmed file's URL, or nil if cancelled/failed.
    let onFinish: (URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> UIViewController {
        guard UIVideoEditorController.canEditVideo(atPath: url.path) else {
            // Can't open the system editor for this file; report failure after the view appears.
            DispatchQueue.main.async { context.coordinator.finish(nil) }
            return UIViewController()
        }
        let vc = UIVideoEditorController()
        vc.videoPath = url.path
        vc.videoMaximumDuration = MediaPicking.maxClipSeconds
        vc.videoQuality = .typeHigh
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: UIViewController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIVideoEditorControllerDelegate {
        private var onFinish: ((URL?) -> Void)?
        init(onFinish: @escaping (URL?) -> Void) { self.onFinish = onFinish }

        func finish(_ url: URL?) {
            let cb = onFinish
            onFinish = nil   // one-shot
            cb?(url)
        }

        func videoEditorController(_ editor: UIVideoEditorController, didSaveEditedVideoToPath editedVideoPath: String) {
            finish(URL(fileURLWithPath: editedVideoPath))
        }
        func videoEditorControllerDidCancel(_ editor: UIVideoEditorController) { finish(nil) }
        func videoEditorController(_ editor: UIVideoEditorController, didFailWithError error: Error) { finish(nil) }
    }
}
