import Foundation
import Observation

/// One pipeline message about a draft, mapped to the body. Owned by the "preview client" agent.
struct PreviewIssue: Identifiable, Equatable {
    enum Level { case error, warning }
    enum Kind { case noDate, missingFile, marker, other }
    let id = UUID()
    var level: Level
    var kind: Kind
    var bodyLine: Int?        // 1-based, relative to the body (nil = about the story as a whole)
    var message: String
    var fileName: String?
}

/// Builds the REAL site page for an unsent draft on the Pi (see docs/draft-preview-contract.md) and exposes state.
@MainActor @Observable
final class DraftPreviewController {
    enum Phase: Equatable {
        case idle
        case uploading(done: Int, total: Int)
        case building
        case ready(URL)
        case failed(String)
    }
    var phase: Phase = .idle
    var issues: [PreviewIssue] = []
    var isStale = true           // content changed since the last successful build
    var lastBuiltAt: Date?

    func markChanged() { isStale = true }

    /// Build if `isStale` (or `force`). Uploads only blobs the Pi doesn't have, then POSTs draft-preview and polls.
    func refreshIfNeeded(draft: FrameDraft, settings: SettingsStore, force: Bool = false,
                         localFileURL: @escaping (String) -> URL) async {}   // STUB

    /// Free the draft's folder on the Pi (call on send / discard / editor close).
    func discard(draftID: UUID, settings: SettingsStore) async {}             // STUB
}
