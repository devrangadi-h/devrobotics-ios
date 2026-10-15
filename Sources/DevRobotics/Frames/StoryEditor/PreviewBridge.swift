import SwiftUI

/// A pipeline problem, body-relative (1-based) line.
struct EditorIssue: Identifiable, Equatable {
    enum Level { case error, warning }
    enum Kind { case noDate, missingFile, marker, other }
    let id = UUID()
    var level: Level
    var line: Int
    var kind: Kind
    var message: String
    var name: String?
}

/// Everything the editor needs from the real-page preview. The editor only talks to this protocol, so the
/// DraftPreviewController (another agent) plugs in through `StoryPreviewBridges.make` below.
@MainActor
protocol StoryPreviewBridge: AnyObject {
    var issues: [EditorIssue] { get }
    var isStale: Bool { get }
    var isBuilding: Bool { get }
    /// Non-nil when the real preview can't be built (e.g. no Tailscale): the editor falls back to
    /// the local "approximate" preview and shows this text.
    var unavailableReason: String? { get }
    func refresh()
    func markChanged()
    func discard()
    func makePreviewView() -> AnyView
}

enum StoryPreviewBridges {
    /// INTEGRATION POINT. Return an adapter around `DraftPreviewController` + `DraftPreviewView(controller:…)`.
    /// While nil, Preview shows the local approximate preview and no pipeline issues are surfaced.
    @MainActor static func make(for model: DraftEditorModel) -> StoryPreviewBridge? { nil }
}
