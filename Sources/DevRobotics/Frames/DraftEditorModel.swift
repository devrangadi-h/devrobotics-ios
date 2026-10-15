import SwiftUI
import Observation

/// Editing session for one draft. Every change is persisted immediately (offline-safe).
@MainActor @Observable
final class DraftEditorModel {
    var draft: FrameDraft {
        didSet {
            guard ready, !applying, draft != oldValue else { return }
            applying = true
            draft.dirty = true
            draft.updatedAt = Date()
            applying = false
            store.save(draft)
        }
    }
    var error: String?
    var busy = false
    @ObservationIgnored private let store: DraftStore
    @ObservationIgnored private var ready = false
    @ObservationIgnored private var applying = false

    init(draft: FrameDraft, store: DraftStore) {
        self.draft = draft
        self.store = store
        ready = true
    }

    /// `suggestsSlug`: for new entries the slug follows this field until the user edits the slug.
    func binding(_ key: String, suggestsSlug: Bool = false) -> Binding<String> {
        Binding(get: { self.draft.fields[key] ?? "" }, set: { new in
            let old = FrameFormat.suggestSlug(from: self.draft.fields[key] ?? "")
            self.draft.fields[key] = new
            if suggestsSlug, self.draft.isNew, self.draft.slug.isEmpty || self.draft.slug == old {
                self.draft.slug = FrameFormat.suggestSlug(from: new)
            }
        })
    }

    var bodyBinding: Binding<String> {
        Binding(get: { self.draft.body }, set: { self.draft.body = $0 })
    }

    func mediaURL(_ name: String) -> URL { store.mediaURL(draft.id, name) }

    func source(for name: String) -> ThumbSource {
        draft.localFiles.contains(name) ? .local(mediaURL(name))
            : .remote(kind: draft.kind, slug: draft.slug, name: name, version: draft.remoteVersion)
    }

    /// Persist the (possibly brand new) draft even before any edit, so it shows up in the list.
    func touch() { draft.updatedAt = Date() }

    /// Add a picked file. Photos: replaces the single image. Returns the stored file name.
    @discardableResult
    func add(_ media: PickedMedia) -> String? {
        do {
            if draft.kind == .photo, !media.isVideo {
                for n in draft.localFiles { store.removeFile(n, from: draft) }
                draft.deleteFiles += draft.remoteFiles.filter { !draft.deleteFiles.contains($0) }
                draft.remoteFiles = []
                draft.localFiles = []
            }
            let name = try store.importFile(media.url, into: draft, preferredName: media.name)
            draft.localFiles.append(name)
            draft.deleteFiles.removeAll { $0 == name }
            return name
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func remove(_ name: String) {
        if draft.localFiles.contains(name) {
            store.removeFile(name, from: draft)
            draft.localFiles.removeAll { $0 == name }
        } else if draft.remoteFiles.contains(name) {
            draft.remoteFiles.removeAll { $0 == name }
            draft.deleteFiles.append(name)
        }
        if draft.fields["cover"] == name { draft.fields["cover"] = "" }
    }
}
