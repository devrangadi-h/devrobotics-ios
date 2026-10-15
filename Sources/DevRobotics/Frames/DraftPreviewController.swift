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
    /// Failure is about reaching the Pi (show the Connect Tailscale hint).
    private(set) var needsConnection = false
    /// The draft last built; the web view sets the `polaris_preview` cookie from this.
    private(set) var draftID: UUID?

    @ObservationIgnored private var changeCounter = 0
    @ObservationIgnored private var running: Task<Void, Never>?

    var isWorking: Bool {
        switch phase { case .uploading, .building: return true; default: return false }
    }

    func markChanged() { isStale = true; changeCounter += 1 }

    /// Build if `isStale` (or `force`). Uploads only blobs the Pi doesn't have, then POSTs draft-preview and polls.
    func refreshIfNeeded(draft: FrameDraft, settings: SettingsStore, force: Bool = false,
                         localFileURL: @escaping (String) -> URL) async {
        if let running { await running.value; return }          // coalesce with an in-flight build
        guard force || isStale || phase == .idle else { return }
        guard draft.kind == .story else { return }
        guard let endpoint = PreviewEndpoint(settings) else {
            fail("Set the Pi address and token in Settings.", connection: true); return
        }
        let t = Task { [weak self] in
            guard let self else { return }
            await self.run(draft: draft, endpoint: endpoint, localFileURL: localFileURL)
        }
        running = t
        await withTaskCancellationHandler { await t.value } onCancel: { t.cancel() }
        running = nil
    }

    /// Cancel an in-flight build.
    func cancel() { running?.cancel() }

    /// Free the draft's folder on the Pi (call on send / discard / editor close).
    func discard(draftID: UUID, settings: SettingsStore) async {
        running?.cancel()
        if self.draftID == draftID {
            phase = .idle; issues = []; isStale = true; lastBuiltAt = nil; self.draftID = nil
        }
        guard let endpoint = PreviewEndpoint(settings) else { return }
        await DraftPreviewClient(endpoint: endpoint).delete(draftID: draftID.uuidString.lowercased())
    }

    // MARK: - Build

    private func fail(_ msg: String, connection: Bool = false) {
        needsConnection = connection
        phase = .failed(msg)
    }

    private func run(draft: FrameDraft, endpoint: PreviewEndpoint, localFileURL: (String) -> URL) async {
        let startedAt = changeCounter
        needsConnection = false
        draftID = draft.id
        let id = draft.id.uuidString.lowercased()
        let client = DraftPreviewClient(endpoint: endpoint)
        do {
            // 1. Hash local files (cached per path/size/mtime).
            phase = .uploading(done: 0, total: 0)
            var entries: [(name: String, url: URL, sha: String)] = []
            for name in draft.localFiles {
                let url = localFileURL(name)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    fail("File \(name) is missing from this device."); return
                }
                let sha = try await Task.detached(priority: .userInitiated) {
                    try FileHashCache.shared.sha256(of: url)
                }.value
                entries.append((name, url, sha))
            }
            // 2. Upload only what the Pi lacks.
            let missing = entries.isEmpty ? [] : try await client.missing(Array(Set(entries.map(\.sha))))
            var toSend: [(name: String, url: URL, sha: String)] = []
            var seen = Set<String>()
            for e in entries where missing.contains(e.sha) && seen.insert(e.sha).inserted { toSend.append(e) }
            phase = .uploading(done: 0, total: toSend.count)
            for (i, e) in toSend.enumerated() {
                try Task.checkCancellation()
                try await client.upload(sha: e.sha, name: e.name, file: e.url)
                phase = .uploading(done: i + 1, total: toSend.count)
            }
            // 3. Build.
            phase = .building
            let localNames = Set(draft.localFiles)
            var files: [[String: Any]] = entries.map { ["name": $0.name, "sha256": $0.sha] }
            files += draft.remoteFiles.filter { !localNames.contains($0) }.map { ["name": $0, "remote": true] }
            let payload: [String: Any] = [
                "draftId": id, "kind": "story", "slug": draft.slug,
                "fields": draft.fields, "body": draft.body, "files": files,
            ]
            let body = try JSONSerialization.data(withJSONObject: payload)
            var started: DraftPreviewJobSnapshot?
            var tries = 0
            while started == nil {
                do { started = try await client.startBuild(body) }
                catch DraftPreviewClientError.busy {
                    tries += 1
                    if tries >= 4 { fail("Polaris is busy with another build. Try again in a moment."); return }
                    try await Task.sleep(for: .seconds(2))
                }
            }
            let first = started!
            let final = first.isFinished ? first : try await client.poller.watch(first.id)
            let result = final.result
            issues = PreviewIssueMapper.map(result?.issues ?? [], bodyStartLine: result?.bodyStartLine)
            guard final.state == "done", let path = result?.url else {
                fail(result?.error ?? "Preview build failed.")
                return
            }
            let version = result?.builtAt.map(String.init) ?? String(Int(Date().timeIntervalSince1970))
            guard let page = URL(string: endpoint.base.absoluteString + path + (path.contains("?") ? "&" : "?") + "v=" + version) else {
                fail("Server returned a bad preview address."); return
            }
            lastBuiltAt = result?.builtAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date()
            isStale = changeCounter != startedAt      // edited while building -> still out of date
            phase = .ready(page)
        } catch is CancellationError {
            phase = .idle
        } catch let e as URLError where e.code == .cancelled {
            phase = .idle
        } catch let e as URLError {
            fail("Can't reach Polaris (\(e.localizedDescription)).", connection: true)
        } catch APIError.notConfigured {
            fail("Set the Pi address and token in Settings.", connection: true)
        } catch {
            fail(error.localizedDescription)
        }
    }
}
