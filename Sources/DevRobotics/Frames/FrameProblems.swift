import Foundation

/// One thing wrong (or questionable) about a draft, in plain English, with the actions that fix it.
/// Owned by the "problems core" agent (implementation of `FrameProblemEngine`); consumed by the story editor,
/// photo editor, Frames list and send bar. Contract summary: see docs/problems-contract.md.
struct FrameProblem: Identifiable, Equatable {
    enum Severity: Int, Comparable {
        case warning = 0, error = 1      // errors block sending, warnings never do
        static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }
    enum Kind: Equatable { case noDate, unusedFile, missingFile, invalidMarker, missingField, other }
    enum Fix: Equatable {
        case setDate                      // open the date sheet
        case insertFile(String)           // append the unused file as an image/clip block
        case removeFile(String)           // delete the file from the draft
        case removeBlock(UUID)            // delete a block whose media is missing
        case showText(UUID)               // show an invalid marker as plain text to edit by hand
        case openDetails(field: String)   // open Details focused on a field
    }

    var id: String                        // stable across rebuilds, e.g. "noDate:IMG_1.HEIC"
    var severity: Severity
    var kind: Kind
    var title: String                     // plain English, includes the file name when relevant
    var detail: String? = nil
    var fileName: String? = nil
    var blockID: UUID? = nil              // block to scroll to / badge
    var bodyLine: Int? = nil              // 1-based, body-relative (from the pipeline)
    var fixes: [Fix] = []
}

extension Array where Element == FrameProblem {
    var errors: [FrameProblem] { filter { $0.severity == .error } }
    var warnings: [FrameProblem] { filter { $0.severity == .warning } }
    /// "1 error · 2 warnings" / "2 warnings" / "" when empty.
    var summaryText: String {
        let e = errors.count, w = warnings.count
        var parts: [String] = []
        if e > 0 { parts.append("\(e) \(e == 1 ? "error" : "errors")") }
        if w > 0 { parts.append("\(w) \(w == 1 ? "warning" : "warnings")") }
        return parts.joined(separator: " · ")
    }
}

enum FrameProblemEngine {
    /// Instant, offline checks (no network): missing required fields, cover/photo with no date taken (read from
    /// the file's metadata), files not used by any block or the cover, markers that point at missing files.
    /// `localFileURL` returns the on-device URL of a file, or nil for remote files (those are skipped for dates).
    static func local(draft: FrameDraft, blocks: [StoryBlock], localFileURL: (String) -> URL?) -> [FrameProblem] {
        var out: [FrameProblem] = []
        let isStory = draft.kind == .story
        func blank(_ k: String) -> Bool { draft.field(k).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        func required(_ key: String, _ title: String) {
            if blank(key) {
                out.append(FrameProblem(id: "missingField:\(key)", severity: .error, kind: .missingField, title: title,
                                        fixes: [.openDetails(field: key)]))
            }
        }
        required("place", "Add a place.")
        if isStory { required("title", "Add a title.") }
        if !FrameFormat.isValidSlug(draft.slug) {
            out.append(FrameProblem(id: "missingField:slug", severity: .error, kind: .missingField,
                                    title: draft.slug.isEmpty ? "Add a web address (slug)." : "The web address (slug) isn't valid.",
                                    detail: "Use lowercase words joined by hyphens.", fixes: [.openDetails(field: "slug")]))
        }
        let files = Set(draft.allFiles)
        let cover = draft.field("cover")
        if isStory {
            if cover.isEmpty {
                out.append(FrameProblem(id: "missingField:cover", severity: .error, kind: .missingField,
                                        title: "Pick a cover photo.", fixes: [.openDetails(field: "cover")]))
            } else if !files.contains(cover) {
                out.append(FrameProblem(id: "missingFile:\(cover)", severity: .error, kind: .missingFile,
                                        title: "The cover photo \(cover) is missing from this story.", fileName: cover,
                                        fixes: [.openDetails(field: "cover")]))
            }
        } else if draft.allFiles.isEmpty {
            out.append(FrameProblem(id: "missingField:photo", severity: .error, kind: .missingField,
                                    title: "Pick a photo.", fixes: [.openDetails(field: "photo")]))
        }

        // Markers that point at files the draft doesn't have.
        var reportedMissing = Set<String>()
        for (index, b) in blocks.enumerated() {
            _ = index
            for name in names(in: b.kind) where !files.contains(name) && reportedMissing.insert(name).inserted {
                out.append(FrameProblem(id: "missingFile:\(name)", severity: .error, kind: .missingFile,
                                        title: "\(name) is missing from this story.", fileName: name,
                                        blockID: b.id, fixes: [.removeBlock(b.id)]))
            }
        }

        // Date taken: cover/photos used in the story, unless a story date is set by hand.
        if blank("date") {
            var wanted: [String] = []
            if isStory {
                if !cover.isEmpty { wanted.append(cover) }
                for n in StoryBlocks.referencedFiles(blocks) where !wanted.contains(n) { wanted.append(n) }
            } else {
                wanted = draft.allFiles
            }
            for name in wanted where FrameFormat.isImage(name) && files.contains(name) {
                guard let url = localFileURL(name), FileManager.default.fileExists(atPath: url.path) else { continue }
                if FrameMetadata.dateTaken(of: url) == nil {
                    let what = isStory ? "story" : "photo"
                    let title = name == cover && isStory ? "The cover photo \(name) has no date. Set a date for this \(what)."
                                                         : "\(name) has no date. Set a date for this \(what)."
                    out.append(FrameProblem(id: "noDate:\(name)", severity: .error, kind: .noDate, title: title,
                                            fileName: name, blockID: blockID(using: name, in: blocks), fixes: [.setDate]))
                }
            }
        }

        // Files nothing uses (stories only; a photo entry's file is the entry).
        if isStory {
            let used = Set(StoryBlocks.referencedFiles(blocks) + (cover.isEmpty ? [] : [cover]))
            for name in draft.allFiles where !used.contains(name) { out.append(unused(name)) }
        }
        return merge(out)
    }

    /// Pipeline messages (from a Pi preview/send) rewritten into plain English with fix actions.
    /// Unrecognised messages are kept as written (`kind == .other`).
    static func fromPipeline(_ issues: [PreviewIssue], blocks: [StoryBlock]) -> [FrameProblem] {
        let ranges = StoryBlocks.serialize(blocks).lineRanges
        func block(atLine line: Int?) -> UUID? {
            guard let line else { return nil }
            return blocks.first { ranges[$0.id]?.contains(line) == true }?.id
        }
        var out: [FrameProblem] = []
        for i in issues {
            let sev: FrameProblem.Severity = i.level == .error ? .error : .warning
            let msg = i.message.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = msg.lowercased()
            let name = i.fileName ?? leadingFileName(in: msg)
            let line = block(atLine: i.bodyLine)
            func p(_ id: String, _ kind: FrameProblem.Kind, _ title: String, _ fixes: [FrameProblem.Fix],
                   block b: UUID? = nil) -> FrameProblem {
                FrameProblem(id: id, severity: sev, kind: kind, title: title, detail: nil, fileName: name,
                             blockID: b ?? line, bodyLine: i.bodyLine, fixes: fixes)
            }
            if lower.contains("has no date taken") || i.kind == .noDate {
                let n = name ?? "A photo"
                let cover = lower.hasPrefix("the cover")
                out.append(p("noDate:\(n)", .noDate,
                             cover ? "The cover photo \(n) has no date. Set a date for this story."
                                   : "\(n) has no date. Set a date for this story.", [.setDate],
                             block: name.flatMap { blockID(using: $0, in: blocks) }))
            } else if lower.contains("not used by any") {
                if let n = name {
                    out.append(p("unusedFile:\(n)", .unusedFile, "\(n) isn't used anywhere in the story, so it won't be published.",
                                 [.insertFile(n), .removeFile(n)]))
                } else {
                    out.append(p("other:\(msg)", .other, msg, []))
                }
            } else if lower.contains("is not in this story folder") || i.kind == .missingFile {
                let n = name ?? "A file"
                let b = name.flatMap { blockID(using: $0, in: blocks) }
                out.append(p("missingFile:\(n)", .missingFile, "\(n) is missing from this story.",
                             b.map { [.removeBlock($0)] } ?? [], block: b))
            } else if i.kind == .marker || lower.contains("<insert") || lower.contains("insert marker") || lower.contains("insert line") {
                let key = line?.uuidString ?? "line\(i.bodyLine ?? 0)"
                out.append(p("invalidMarker:\(key)", .invalidMarker, "This block's insert line isn't valid.",
                             line.map { [.showText($0)] } ?? []))
            } else {
                out.append(p("other:\(msg)", .other, msg, []))
            }
        }
        return merge(out)
    }

    /// Union of local + pipeline problems, de-duplicated by `id` (first wins), errors first.
    static func merge(_ lists: [FrameProblem]...) -> [FrameProblem] {
        var seen = Set<String>(), out: [FrameProblem] = []
        for p in lists.joined() where seen.insert(p.id).inserted { out.append(p) }
        return out.enumerated().sorted { a, b in
            a.element.severity != b.element.severity ? a.element.severity > b.element.severity : a.offset < b.offset
        }.map(\.element)
    }

    // MARK: Helpers

    private static func unused(_ name: String) -> FrameProblem {
        FrameProblem(id: "unusedFile:\(name)", severity: .warning, kind: .unusedFile,
                     title: "\(name) isn't used anywhere in the story, so it won't be published.", fileName: name,
                     fixes: [.insertFile(name), .removeFile(name)])
    }

    private static func names(in kind: StoryBlock.Kind) -> [String] {
        StoryBlocks.referencedFiles([StoryBlock(kind: kind)])
    }

    private static func blockID(using name: String, in blocks: [StoryBlock]) -> UUID? {
        blocks.first { names(in: $0.kind).contains(name) }?.id
    }

    /// Pipeline text like "the cover IMG_1.HEIC has no date taken..." -> "IMG_1.HEIC".
    private static func leadingFileName(in msg: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "[A-Za-z0-9._-]+\\.(jpg|jpeg|heic|heif|png|mp4|mov)\\b",
                                                options: .caseInsensitive),
              let m = re.firstMatch(in: msg, range: NSRange(msg.startIndex..., in: msg)),
              let r = Range(m.range, in: msg) else { return nil }
        return String(msg[r])
    }
}
