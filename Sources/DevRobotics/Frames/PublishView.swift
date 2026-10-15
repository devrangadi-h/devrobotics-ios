import SwiftUI

@MainActor @Observable
final class PublishModel {
    enum Phase: Equatable {
        case idle
        case building([String])
        case review([FrameChange], builtAt: Int?)
        case publishing([String])
        case published(pushed: Bool, [FrameChange])
        case failed(String, [String])
        case busy
    }
    var phase: Phase = .idle
    private var task: Task<Void, Never>?
    private static let activeKey = "frames.activeJob"   // "kind:id"

    /// Resume watching a job that was running when the sheet was last closed.
    func begin(settings: SettingsStore) {
        guard task == nil, settings.isConfigured,
              let saved = UserDefaults.standard.string(forKey: Self.activeKey),
              let r = saved.firstIndex(of: ":") else { return }
        let kind = String(saved[..<r]), id = String(saved[saved.index(after: r)...])
        task = Task { await self.resume(kind: kind, id: id, settings: settings) }
    }

    func start(_ action: String, settings: SettingsStore) {
        guard task == nil else { return }
        task = Task { await self.runNew(action, settings: settings) }
    }

    private func service(_ s: SettingsStore) -> FramesJobService { FramesJobService(api: API(settings: s)) }
    private func setRunning(_ action: String, _ log: [String]) {
        phase = action == "publish" ? .publishing(log) : .building(log)
    }

    private func runNew(_ action: String, settings: SettingsStore) async {
        defer { task = nil }
        let svc = service(settings)
        setRunning(action, [])
        do {
            let snap = try await svc.start(action)
            UserDefaults.standard.set("\(action):\(snap.id)", forKey: Self.activeKey)
            await follow(action, snap, svc)
        } catch JobStartError.busy {
            phase = .busy
        } catch {
            phase = .failed(error.localizedDescription, [])
        }
    }

    private func resume(kind: String, id: String, settings: SettingsStore) async {
        defer { task = nil }
        let svc = service(settings)
        do {
            let snap = try await svc.snapshot(id)
            setRunning(kind, snap.log ?? [])
            await follow(kind, snap, svc)
        } catch {
            UserDefaults.standard.removeObject(forKey: Self.activeKey)  // stale (server restarted)
            if case .idle = phase {} else { phase = .idle }
        }
    }

    private func follow(_ action: String, _ first: JobSnapshot, _ svc: FramesJobService) async {
        do {
            var snap = first
            if !first.isFinished {
                snap = try await svc.poller.watch(first.id) { s in
                    self.setRunning(action, s.log ?? [])
                }
            }
            UserDefaults.standard.removeObject(forKey: Self.activeKey)
            if snap.state == "done" {
                let changes = snap.result?.changes ?? []
                phase = action == "publish" ? .published(pushed: snap.result?.pushed ?? false, changes)
                                            : .review(changes, builtAt: snap.result?.builtAt)
            } else {
                phase = .failed(snap.result?.error ?? "The job failed.", Array((snap.log ?? []).suffix(25)))
            }
        } catch is CancellationError {
            // sheet closed; job continues server-side and its id stays saved
        } catch {
            phase = .failed(error.localizedDescription, [])
        }
    }

    func cancelWatching() { task?.cancel(); task = nil }
    func reset() { phase = .idle }
}

