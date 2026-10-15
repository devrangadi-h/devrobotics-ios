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

/// Preview -> changes list -> Approve & publish. Presented from FramesView in a sheet.
struct PublishView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var model = PublishModel()
    @State private var openTarget: PreviewTarget?
    @State private var confirming = false
    @State private var focusConsumed = false
    private let focus: PreviewTarget?

    init(focus: PreviewTarget? = nil) { self.focus = focus }

    private struct TargetID: Identifiable { let target: PreviewTarget; var id: PreviewTarget { target } }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Publish")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { model.cancelWatching(); dismiss() }
                    }
                }
        }
        .fullScreenCover(item: Binding(get: { openTarget.map(TargetID.init) },
                                       set: { openTarget = $0?.target })) { PreviewPage(target: $0.target) }
        .onAppear {
            model.begin(settings: settings)
            if focus != nil, settings.isConfigured, case .idle = model.phase { model.start("preview", settings: settings) }
        }
        .onDisappear { model.cancelWatching() }
        .onChange(of: model.phase) { _, p in
            if case .review = p, let focus, !focusConsumed { focusConsumed = true; openTarget = focus }
        }
    }

    @ViewBuilder private var content: some View {
        if !settings.isConfigured {
            message("Not configured", "Set the Pi address and token in Settings first.", icon: "gearshape")
        } else {
            switch model.phase {
            case .idle:
                VStack(spacing: 16) {
                    Image(systemName: "eye").font(.system(size: 44)).foregroundStyle(Theme.accent)
                    Text("Build a preview of everything in your inbox. Nothing goes live until you approve.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("Build preview") { model.start("preview", settings: settings) }
                        .buttonStyle(.borderedProminent).tint(Theme.accent)
                    Text("Requires Tailscale to be connected.").font(.footnote).foregroundStyle(.secondary)
                }.padding()
            case .building(let log): progress("Building preview…", log)
            case .publishing(let log): progress("Publishing…", log)
            case .busy:
                VStack(spacing: 16) {
                    message("Polaris is busy", "Another build or publish is running. Try again in a minute.", icon: "hourglass")
                    Button("Retry") { model.start("preview", settings: settings) }.buttonStyle(.borderedProminent)
                }
            case .review(let changes, _): review(changes)
            case .published(let pushed, let changes):
                VStack(spacing: 12) {
                    message("Published",
                            pushed ? "\(changes.count) change(s) are live." : "Committed on the Pi, but it was not pushed.",
                            icon: "checkmark.seal.fill")
                    Button("Done") { model.reset(); dismiss() }.buttonStyle(.borderedProminent)
                }
            case .failed(let msg, let log):
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Failed", systemImage: "xmark.octagon.fill").font(.title2).foregroundStyle(.red)
                        Text(msg)
                        Text("Nothing was left half-published.").font(.footnote).foregroundStyle(.secondary)
                        if !log.isEmpty {
                            Text(log.joined(separator: "\n")).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                        Button("Start over") { model.reset() }.buttonStyle(.bordered)
                    }.padding()
                }
            }
        }
    }

    private func message(_ title: String, _ detail: String, icon: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(Theme.accent)
            Text(title).font(.title3.bold())
            Text(detail).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }.padding()
    }

    private func progress(_ title: String, _ log: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { ProgressView(); Text(title).font(.headline) }
            ScrollView {
                Text(log.suffix(40).joined(separator: "\n")).font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding()
    }

    private func review(_ changes: [FrameChange]) -> some View {
        List {
            if changes.isEmpty {
                Section { Text("No changes: the preview matches what is already live.") }
            }
            ForEach(FrameChange.Kind.allCases, id: \.self) { kind in
                let rows = changes.filter { $0.change == kind }
                if !rows.isEmpty {
                    Section(kind.title) {
                        ForEach(rows) { c in
                            Button {
                                if c.change != .removed, let t = PreviewTarget(change: c) { openTarget = t }
                            } label: {
                                HStack {
                                    Image(systemName: c.kind == "photo" ? "photo" : "text.book.closed")
                                    Text(c.slug)
                                    Spacer()
                                    if c.change != .removed {
                                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }.foregroundStyle(.primary)
                        }
                    }
                }
            }
            Section {
                Button("Approve & publish") { confirming = true }
                    .buttonStyle(.borderedProminent).tint(Theme.accent).disabled(changes.isEmpty)
                Button("Rebuild preview") { model.start("preview", settings: settings) }
            }
        }
        .confirmationDialog("Publish \(changes.count) change(s)?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Publish everything listed") { model.start("publish", settings: settings) }
        } message: {
            Text("This publishes everything in the list (\(changes.count) entries) to devrobotics.dev.")
        }
    }
}
