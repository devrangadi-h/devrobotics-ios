import SwiftUI

/// Adapter between the editor and the real-page preview (`DraftPreviewController` / `DraftPreviewView`).
/// Everything the editor needs from the preview goes through here.
@MainActor
final class StoryPreviewBridge {
    let controller = DraftPreviewController()
    private let model: DraftEditorModel
    private let settings: SettingsStore

    init(model: DraftEditorModel, settings: SettingsStore) {
        self.model = model
        self.settings = settings
    }

    /// Body-relative pipeline issues.
    var issues: [PreviewIssue] { controller.issues }
    var isStale: Bool { controller.isStale }

    /// Non-nil when the real preview couldn't be reached: the editor shows the approximate local preview.
    var unavailableReason: String? {
        if case .failed(let m) = controller.phase, controller.needsConnection { return m }
        return nil
    }

    func markChanged() { controller.markChanged() }

    func refresh() {
        Task {
            await controller.refreshIfNeeded(draft: model.draft, settings: settings, force: true,
                                             localFileURL: { [model] in model.mediaURL($0) })
        }
    }

    /// Frees the draft's folder on the Pi. Call when the draft is sent or discarded.
    func discard() {
        let id = model.draft.id
        let s = settings
        Task { await controller.discard(draftID: id, settings: s) }
    }

    func makePreviewView() -> some View {
        DraftPreviewView(controller: controller, draft: model.draft, localFileURL: { [model] in model.mediaURL($0) })
    }
}
