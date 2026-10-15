import SwiftUI
import AVFoundation

/// Card for a clip block: poster/thumbnail, duration badge ("0:08"), a "Trimmed" mark, tap to play inline (muted, looping),
/// tap again to expand. Owned by the "clips + server" agent (implementation); the story editor's BlockViews uses it.
/// Local clips (just added) play from the draft folder; clips already on the Pi stream a small preview via
/// `GET v1/frames/<kind>/<slug>/clip/<name>` (see docs/problems-contract.md).
struct ClipCardView: View {
    let model: DraftEditorModel
    let name: String
    var trimmed = false

    @Environment(SettingsStore.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var duration: Double?
    @State private var box: LoopingPlayerBox?
    @State private var preparing = false
    @State private var failed = false
    @State private var expanded = false
    @State private var prepTask: Task<Void, Never>?

    private var source: ClipSource {
        if DemoMode.isOn { return .demo }
        if model.draft.localFiles.contains(name) { return .local(model.mediaURL(name)) }
        return .remote(path: "v1/frames/\(model.draft.kind.rawValue)/\(model.draft.slug)/clip/\(name)")
    }

    private var isDemo: Bool { if case .demo = source { true } else { false } }
    private var playing: Bool { box != nil }
    private var durationText: String { duration.map(ClipFormat.duration) ?? "-:--" }

    var body: some View {
        ZStack {
            poster
            if let box { PlayerLayerView(player: box.player).transition(.opacity) }
            if preparing { ProgressView().controlSize(.large).padding(18).glassEffect(.regular, in: .circle) }
            if !playing && !preparing {
                Image(systemName: failed ? "exclamationmark.triangle.fill" : "play.fill")
                    .font(.system(size: 20))
                    .frame(width: 52, height: 52)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    GlassPill(text: durationText, systemImage: "film")
                    if trimmed { GlassPill(text: "Trimmed", systemImage: "scissors") }
                }
            }
            .padding(8)
        }
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .onTapGesture(perform: tap)
        .task(id: name) { await loadDuration() }
        .onDisappear { stop() }
        .fullScreenCover(isPresented: $expanded) {
            if let asset = makeAsset(source) { ClipExpandedPlayer(asset: asset) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Clip \(name), \(duration.map(ClipFormat.duration) ?? "duration unknown")\(trimmed ? ", trimmed" : "")")
        .accessibilityHint(playing ? "Double tap to enlarge" : "Double tap to play")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private var poster: some View {
        if isDemo {
            LinearGradient(colors: [Color.accentColor.opacity(0.55), Color.accentColor.opacity(0.15)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay { Image(systemName: "film").font(.system(size: 44)).foregroundStyle(.white.opacity(0.6)) }
        } else {
            FrameThumb(source: model.source(for: name))
        }
    }

    // MARK: actions

    private func tap() {
        if isDemo { return }   // demo: static poster, no network
        if playing { expanded = true; return }
        guard !preparing else { return }
        start()
    }

    private func start() {
        failed = false
        preparing = true
        prepTask = Task {
            let ready = await prepare()
            guard !Task.isCancelled else { return }
            preparing = false
            guard ready, let asset = makeAsset(source) else { failed = true; return }
            let b = LoopingPlayerBox()
            b.load(asset)
            b.player.play()
            if reduceMotion { box = b } else { withAnimation(.easeOut(duration: 0.2)) { box = b } }
        }
    }

    /// Remote previews are generated on first request; the server answers 202 until ready.
    private func prepare() async -> Bool {
        guard case .remote(let path) = source else { return true }
        for _ in 0..<24 {
            guard var req = FramesAuth.authed(settings, path) else { return false }
            req.setValue("bytes=0-1", forHTTPHeaderField: "Range")
            req.timeoutInterval = 30
            guard let (_, resp) = try? await URLSession.shared.data(for: req),
                  let code = (resp as? HTTPURLResponse)?.statusCode else { return false }
            if code == 200 || code == 206 { return true }
            if code != 202 { return false }
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { return false }
        }
        return false
    }

    private func stop() {
        prepTask?.cancel()
        preparing = false
        box?.stop()
        box = nil
    }

    private func makeAsset(_ s: ClipSource) -> AVURLAsset? {
        switch s {
        case .local(let url): return AVURLAsset(url: url)
        case .demo: return nil
        case .remote(let path):
            guard let req = FramesAuth.authed(settings, path), let url = req.url else { return nil }
            let headers = ["Authorization": "Bearer \(settings.token)"]
            return AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        }
    }

    private func loadDuration() async {
        switch source {
        case .demo: duration = 8
        case .local(let url): duration = await ClipDurationLoader.shared.local(url)
        case .remote(let path):
            let info = path.replacingOccurrences(of: "/clip/", with: "/clipinfo/")
            let key = "\(model.draft.id)|\(model.draft.remoteVersion)|\(info)"
            duration = await ClipDurationLoader.shared.remote(key: key, request: FramesAuth.authed(settings, info))
        }
    }
}
