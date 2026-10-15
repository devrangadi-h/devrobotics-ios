import Foundation

enum FrameKind: String, Codable, CaseIterable, Sendable, Hashable {
    case photo, story
    var label: String { self == .photo ? "Photo" : "Story" }
}

struct RemoteFile: Codable, Hashable, Sendable {
    var name: String
    var type: String
    var size: Int?
}

/// Entry as returned by GET v1/frames/entries (body only in the single-entry GET).
struct RemoteEntry: Codable, Hashable, Identifiable, Sendable {
    var kind: FrameKind
    var slug: String
    var fields: [String: String]
    var files: [RemoteFile]
    var modified: Int?
    var published: Bool?
    var body: String?
    var id: String { "\(kind.rawValue)/\(slug)" }
}

struct RemoteEntries: Codable, Sendable { var entries: [RemoteEntry] }

/// A local, offline-editable version of an entry. Persisted as JSON; new media lives in its folder.
struct FrameDraft: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var kind: FrameKind
    var slug: String
    var isNew: Bool
    var fields: [String: String] = [:]
    var body = ""
    /// Files stored locally in the draft folder, to be uploaded.
    var localFiles: [String] = []
    /// Files already on the Pi (referenced by name only).
    var remoteFiles: [String] = []
    var deleteFiles: [String] = []
    /// Unsent changes exist.
    var dirty = true
    /// Server-side validation problems from the last send.
    var problems: [String] = []
    var lastError: String?
    var updatedAt = Date()
    /// Remote modification stamp, used as the thumbnail cache version.
    var remoteVersion = 0

    var key: String { "\(kind.rawValue)/\(slug)" }
    var allFiles: [String] { remoteFiles + localFiles }

    init(kind: FrameKind, slug: String = "", isNew: Bool) {
        self.kind = kind; self.slug = slug; self.isNew = isNew
        fields["gps"] = "show"
    }

    init(entry: RemoteEntry) {
        self.init(kind: entry.kind, slug: entry.slug, isNew: false)
        fields = entry.fields
        body = entry.body ?? ""
        remoteFiles = entry.files.map(\.name)
        remoteVersion = entry.modified ?? 0
        dirty = false
    }

    func field(_ k: String) -> String { fields[k] ?? "" }

    var displayTitle: String {
        let t = kind == .story ? field("title") : field("place")
        return t.isEmpty ? (slug.isEmpty ? "Untitled \(kind.label.lowercased())" : slug) : t
    }

    /// Problems that stop sending (checked client-side).
    var validation: [String] {
        var p: [String] = []
        if !FrameFormat.isValidSlug(slug) { p.append("Slug must be lowercase words joined by hyphens.") }
        if field("place").trimmingCharacters(in: .whitespaces).isEmpty { p.append("Place is required.") }
        switch kind {
        case .photo:
            if allFiles.isEmpty { p.append("Pick a photo.") }
        case .story:
            if field("title").trimmingCharacters(in: .whitespaces).isEmpty { p.append("Title is required.") }
            let c = field("cover")
            if c.isEmpty { p.append("Pick a cover photo.") }
            else if !allFiles.contains(c) { p.append("Cover file \(c) is missing.") }
        }
        return p
    }

    /// Thumbnail file (cover for stories, the image for photos).
    var thumbName: String? {
        if kind == .story, let c = fields["cover"], allFiles.contains(c) { return c }
        return allFiles.first(where: FrameFormat.isImage)
    }
}
