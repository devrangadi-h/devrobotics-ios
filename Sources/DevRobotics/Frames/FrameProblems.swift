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
    static func local(draft: FrameDraft, blocks: [StoryBlock], localFileURL: (String) -> URL?) -> [FrameProblem] { [] } // STUB

    /// Pipeline messages (from a Pi preview/send) rewritten into plain English with fix actions.
    /// Unrecognised messages are kept as written (`kind == .other`).
    static func fromPipeline(_ issues: [PreviewIssue], blocks: [StoryBlock]) -> [FrameProblem] { [] }                 // STUB

    /// Union of local + pipeline problems, de-duplicated by `id`, errors first.
    static func merge(_ lists: [FrameProblem]...) -> [FrameProblem] {
        var seen = Set<String>(), out: [FrameProblem] = []
        for p in lists.joined() where seen.insert(p.id).inserted { out.append(p) }
        return out.sorted { $0.severity > $1.severity }
    }
}
