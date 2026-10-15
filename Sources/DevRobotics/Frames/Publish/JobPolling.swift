import Foundation

/// One entry in a preview/publish result.
struct FrameChange: Decodable, Identifiable, Hashable {
    enum Kind: String, Decodable, CaseIterable {
        case new, changed, removed
        var title: String {
            switch self { case .new: return "New"; case .changed: return "Changed"; case .removed: return "Removed" }
        }
    }
    let change: Kind
    let kind: String   // "photo" | "story"
    let slug: String
    var id: String { "\(change.rawValue)/\(kind)/\(slug)" }
}

struct JobResult: Decodable, Equatable {
    var changes: [FrameChange]?
    var builtAt: Int?
    var pushed: Bool?
    var error: String?
}

struct JobSnapshot: Decodable, Equatable {
    var id: String
    var kind: String?
    var state: String          // running | done | failed
    var log: [String]?
    var result: JobResult?
    var isFinished: Bool { state == "done" || state == "failed" }
}

enum JobStartError: Error, Equatable { case busy }

/// Polls a job until it finishes. `fetch` is injected so this is testable without a network.
@MainActor struct JobPoller {
    var fetch: (String) async throws -> JobSnapshot
    var interval: Duration = .seconds(1)
    var maxConsecutiveErrors = 8

    /// Calls `onUpdate` for every snapshot; returns the final one. Throws CancellationError if cancelled.
    func watch(_ id: String, onUpdate: (JobSnapshot) -> Void = { _ in }) async throws -> JobSnapshot {
        var errors = 0
        while true {
            try Task.checkCancellation()
            do {
                let snap = try await fetch(id)
                errors = 0
                onUpdate(snap)
                if snap.isFinished { return snap }
            } catch is CancellationError {
                throw CancellationError()
            } catch APIError.http(404, _) {
                throw APIError.http(404, "job no longer exists on the server")
            } catch {
                errors += 1
                if errors >= maxConsecutiveErrors { throw error }
            }
            try await Task.sleep(for: interval)
        }
    }
}

/// Talks to /v1/frames/{preview,publish} and /v1/jobs/<id>.
@MainActor struct FramesJobService {
    nonisolated(unsafe) let api: API

    func start(_ action: String) async throws -> JobSnapshot {
        do {
            let d = try await api.request(.app, "v1/frames/\(action)", method: "POST", body: Data("{}".utf8), contentType: "application/json")
            return try JSONDecoder().decode(JobSnapshot.self, from: d)
        } catch APIError.http(409, _) {
            throw JobStartError.busy
        }
    }

    func snapshot(_ id: String) async throws -> JobSnapshot {
        try await api.getJSON(.app, "v1/jobs/\(id)")
    }

    var poller: JobPoller { JobPoller(fetch: { try await self.snapshot($0) }) }
}
