import Foundation
import Observation

/// Offline drafts: Application Support/FrameDrafts/<uuid>/{draft.json, media/<files>}.
@MainActor @Observable
final class DraftStore {
    private(set) var drafts: [FrameDraft] = []
    private let root: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("FrameDrafts", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        load()
    }

    private func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func mediaURL(_ id: UUID, _ name: String) -> URL {
        folder(id).appendingPathComponent("media", isDirectory: true).appendingPathComponent(name)
    }

    private func load() {
        let dec = JSONDecoder()
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var out: [FrameDraft] = []
        for d in dirs {
            if let data = try? Data(contentsOf: d.appendingPathComponent("draft.json")),
               let draft = try? dec.decode(FrameDraft.self, from: data) { out.append(draft) }
        }
        drafts = out.sorted { $0.updatedAt > $1.updatedAt }
    }

    func draft(kind: FrameKind, slug: String) -> FrameDraft? {
        drafts.first { $0.kind == kind && $0.slug == slug && !$0.isNew } ?? drafts.first { $0.kind == kind && $0.slug == slug }
    }

    func save(_ draft: FrameDraft) {
        let dir = folder(draft.id)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("media"), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(draft) {
            try? data.write(to: dir.appendingPathComponent("draft.json"), options: .atomic)
        }
        if let i = drafts.firstIndex(where: { $0.id == draft.id }) { drafts[i] = draft } else { drafts.insert(draft, at: 0) }
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: folder(id))
        drafts.removeAll { $0.id == id }
    }

    /// Move a temp file into the draft's media folder under a unique, sanitized name. Returns the final name.
    func importFile(_ tmp: URL, into draft: FrameDraft, preferredName: String) throws -> String {
        let dir = folder(draft.id).appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = FrameFormat.uniqueName(FrameFormat.sanitizeFileName(preferredName), among: draft.allFiles)
        let dest = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.moveItem(at: tmp, to: dest) }
        catch { try FileManager.default.copyItem(at: tmp, to: dest); try? FileManager.default.removeItem(at: tmp) }
        return name
    }

    func removeFile(_ name: String, from draft: FrameDraft) {
        try? FileManager.default.removeItem(at: mediaURL(draft.id, name))
    }
}
