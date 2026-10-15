import Foundation

/// Wire types for POST /v1/frames/draft-preview and the job it returns (docs/draft-preview-contract.md, section 2).
struct DraftPreviewRawIssue: Decodable, Equatable {
    var level: String?
    var line: Int?
    var file: String?
    var message: String?
    var kind: String?
    var name: String?
}

struct DraftPreviewJobResult: Decodable, Equatable {
    var url: String?
    var draftId: String?
    var builtAt: Int?
    var bodyStartLine: Int?
    var issues: [DraftPreviewRawIssue]?
    var error: String?
}

struct DraftPreviewJobSnapshot: Decodable, Equatable {
    var id: String
    var state: String               // running | done | failed
    var log: [String]?
    var result: DraftPreviewJobResult?
    var isFinished: Bool { state == "done" || state == "failed" }
}

/// Pure mapping from server issues to body-relative `PreviewIssue`s.
enum PreviewIssueMapper {
    static func map(_ raw: [DraftPreviewRawIssue], bodyStartLine: Int?) -> [PreviewIssue] {
        raw.map { r in
            let kind: PreviewIssue.Kind
            switch r.kind {
            case "no-date": kind = .noDate
            case "missing-file": kind = .missingFile
            case "marker": kind = .marker
            default: kind = .other
            }
            var body: Int?
            if let line = r.line, let start = bodyStartLine {
                let rel = line - start + 1
                body = rel >= 1 ? rel : nil      // front-matter lines are about the story as a whole
            }
            var file = r.name
            if file == nil, let f = r.file, f != "story.md" { file = f }
            return PreviewIssue(level: r.level == "error" ? .error : .warning, kind: kind, bodyLine: body,
                                message: r.message ?? "Problem in preview", fileName: file)
        }
    }
}

/// Polls a draft-preview job until it finishes. `fetch` is injected so it's testable without a network.
struct DraftPreviewJobPoller: Sendable {
    var fetch: @Sendable (String) async throws -> DraftPreviewJobSnapshot
    var interval: Duration = .milliseconds(800)
    var maxConsecutiveErrors = 8
    var maxDuration: Duration = .seconds(600)

    func watch(_ id: String) async throws -> DraftPreviewJobSnapshot {
        var errors = 0
        let deadline = ContinuousClock.now + maxDuration
        while true {
            try Task.checkCancellation()
            do {
                let snap = try await fetch(id)
                errors = 0
                if snap.isFinished { return snap }
            } catch is CancellationError {
                throw CancellationError()
            } catch APIError.http(404, _) {
                throw APIError.http(404, "preview job no longer exists on the server")
            } catch {
                errors += 1
                if errors >= maxConsecutiveErrors { throw error }
            }
            if ContinuousClock.now > deadline { throw APIError.http(504, "preview timed out") }
            try await Task.sleep(for: interval)
        }
    }
}
