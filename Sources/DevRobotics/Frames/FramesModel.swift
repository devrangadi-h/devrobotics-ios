import Foundation
import Observation

/// One list row: a remote entry, a local draft, or both.
struct FrameRow: Identifiable {
    var kind: FrameKind
    var slug: String
    var remote: RemoteEntry?
    var draft: FrameDraft?
    var id: String { draft.map { "d-\($0.id)" } ?? "r-\(kind.rawValue)/\(slug)" }
    var published: Bool { remote?.published ?? false }
    var title: String {
        if let d = draft { return d.displayTitle }
        let f = remote?.fields ?? [:]
        let t = (kind == .story ? f["title"] : f["place"]) ?? ""
        return t.isEmpty ? slug : t
    }
    var subtitle: String {
        let f = draft?.fields ?? remote?.fields ?? [:]
        return kind == .story ? (f["place"] ?? "") : slug
    }
}

@MainActor @Observable
final class FramesModel {
    let store = DraftStore()
    var entries: [RemoteEntry] = []
    var loading = false
    var loadError: String?
    var sending = false
    var progress: [UUID: Double] = [:]
    var statusText: [UUID: String] = [:]
    var summary: String?

    private var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("frames-entries.json")
    }

    init() {
        if let d = try? Data(contentsOf: cacheURL), let e = try? JSONDecoder().decode(RemoteEntries.self, from: d) {
            entries = e.entries
        }
    }

    var rows: [FrameRow] {
        var out: [FrameRow] = []
        var usedDrafts = Set<UUID>()
        for e in entries {
            let d = store.draft(kind: e.kind, slug: e.slug).flatMap { $0.isNew ? nil : $0 }
            if let d { usedDrafts.insert(d.id) }
            out.append(FrameRow(kind: e.kind, slug: e.slug, remote: e, draft: d))
        }
        for d in store.drafts where !usedDrafts.contains(d.id) {
            out.append(FrameRow(kind: d.kind, slug: d.slug, remote: nil, draft: d))
        }
        return out.sorted { a, b in
            let ta = a.draft?.updatedAt.timeIntervalSince1970 ?? Double(a.remote?.modified ?? 0)
            let tb = b.draft?.updatedAt.timeIntervalSince1970 ?? Double(b.remote?.modified ?? 0)
            return ta > tb
        }
    }

    var pendingDrafts: [FrameDraft] { store.drafts.filter { $0.dirty } }

    func thumbSource(for d: FrameDraft?, remote: RemoteEntry?, kind: FrameKind, slug: String) -> ThumbSource? {
        if let d, let n = d.thumbName {
            if d.localFiles.contains(n) { return .local(store.mediaURL(d.id, n)) }
            return .remote(kind: kind, slug: slug, name: n, version: d.remoteVersion)
        }
        guard let r = remote else { return nil }
        let cover = r.fields["cover"]
        let name = r.files.first(where: { $0.name == cover })?.name ?? r.files.first(where: { FrameFormat.isImage($0.name) })?.name
        return name.map { .remote(kind: kind, slug: slug, name: $0, version: r.modified ?? 0) }
    }

    // MARK: network

    func refresh(_ settings: SettingsStore) async {
        guard settings.isConfigured else { loadError = APIError.notConfigured.errorDescription; return }
        loading = true
        defer { loading = false }
        do {
            let r = try JSONDecoder().decode(RemoteEntries.self, from: try await FramesAuth.data(settings, "v1/frames/entries"))
            entries = r.entries
            loadError = nil
            if let d = try? JSONEncoder().encode(r) { try? d.write(to: cacheURL, options: .atomic) }
        } catch {
            loadError = Self.describe(error)
        }
    }

    func fetchEntry(_ kind: FrameKind, _ slug: String, _ settings: SettingsStore) async throws -> RemoteEntry {
        try JSONDecoder().decode(RemoteEntry.self, from: try await FramesAuth.data(settings, "v1/frames/\(kind.rawValue)/\(slug)"))
    }

    func delete(_ row: FrameRow, _ settings: SettingsStore) async {
        if row.remote != nil {
            do {
                _ = try await FramesAuth.data(settings, "v1/frames/\(row.kind.rawValue)/\(row.slug)", method: "DELETE")
            } catch {
                summary = "Delete failed: \(Self.describe(error))"
                return
            }
        }
        if let d = row.draft { store.delete(d.id) }
        entries.removeAll { $0.kind == row.kind && $0.slug == row.slug }
        await refresh(settings)
    }

    func discardDraft(_ d: FrameDraft) { store.delete(d.id) }

    static func describe(_ error: Error) -> String {
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        if (error as? URLError) != nil { return "Can't reach Polaris (\(error.localizedDescription))." }
        return error.localizedDescription
    }

    // MARK: sending

    func sendAll(_ settings: SettingsStore) async {
        guard !sending else { return }
        sending = true
        summary = nil
        defer { sending = false }
        var okCount = 0, failCount = 0
        for draft in pendingDrafts {
            if await send(draft, settings) { okCount += 1 } else { failCount += 1 }
        }
        summary = failCount == 0 ? "Sent \(okCount) draft\(okCount == 1 ? "" : "s") to Polaris."
                                 : "\(okCount) sent, \(failCount) failed. Failed drafts are kept."
        await refresh(settings)
    }

    private func send(_ draft: FrameDraft, _ settings: SettingsStore) async -> Bool {
        var d = draft
        let id = d.id
        func fail(_ msg: String) -> Bool {
            d.lastError = msg
            store.save(d)
            statusText[id] = nil; progress[id] = nil
            return false
        }
        let v = d.validation
        if !v.isEmpty { return fail(v.joined(separator: " ")) }
        guard settings.isConfigured else { return fail(APIError.notConfigured.errorDescription ?? "Not configured") }

        var fields: [String: String] = [:]
        for (k, val) in d.fields where !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fields[k] = val }
        let metaObj: [String: Any] = ["fields": fields, "body": d.body, "deleteFiles": d.deleteFiles]
        guard let meta = try? JSONSerialization.data(withJSONObject: metaObj) else { return fail("Could not encode draft.") }
        let files = d.localFiles.map { (name: $0, url: store.mediaURL(id, $0)) }
        for f in files where !FileManager.default.fileExists(atPath: f.url.path) { return fail("Missing local file \(f.name).") }

        statusText[id] = "Preparing"
        progress[id] = 0
        let base = "v1/frames/\(d.kind.rawValue)/\(d.slug)"
        do {
            let body = try await Task.detached { try FramesUploader.buildBody(meta: meta, files: files) }.value
            defer { try? FileManager.default.removeItem(at: body.fileURL) }
            statusText[id] = "Uploading"
            var create = d.isNew
            var result: PutResult
            while true {
                guard var req = FramesAuth.authed(settings, base) else { return fail("Not configured.") }
                if create {
                    var c = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
                    c.queryItems = [URLQueryItem(name: "create", value: "1")]
                    req.url = c.url
                }
                do {
                    result = try await FramesUploader.put(req, body: body, progress: { p in
                        Task { @MainActor in self.progress[id] = p }
                    })
                    break
                } catch APIError.http(409, _) where create {
                    // Folder may be left half-written by an earlier interrupted upload (md is written last).
                    let exists = (try? await fetchEntry(d.kind, d.slug, settings)) != nil
                    if exists { throw APIError.http(409, "An entry with that slug already exists. Change the slug.") }
                    create = false
                }
            }
            // success: the server now has everything
            if d.kind == .photo, d.localFiles.contains(where: FrameFormat.isImage) { d.remoteFiles = [] }
            d.remoteFiles = d.remoteFiles.filter { !d.deleteFiles.contains($0) } + d.localFiles
            for n in d.localFiles { store.removeFile(n, from: d) }
            d.localFiles = []; d.deleteFiles = []; d.isNew = false; d.dirty = false; d.lastError = nil
            d.problems = result.valid == false ? (result.problems ?? ["Server reported problems."]) : []
            statusText[id] = nil; progress[id] = nil
            if d.problems.isEmpty { store.delete(id) } else { store.save(d) }
            return true
        } catch {
            return fail(Self.describe(error))
        }
    }
}
