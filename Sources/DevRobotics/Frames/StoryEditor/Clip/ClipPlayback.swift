import SwiftUI
import AVFoundation
import AVKit

/// Where a clip's bytes come from.
enum ClipSource {
    case local(URL)
    case remote(path: String)   // v1/frames/<kind>/<slug>/clip/<name>
    case demo
}

enum ClipFormat {
    static func duration(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Duration lookups, cached per source key.
actor ClipDurationLoader {
    static let shared = ClipDurationLoader()
    private var cache: [String: Double] = [:]

    func local(_ url: URL) async -> Double? {
        let key = url.path
        if let d = cache[key] { return d }
        guard let t = try? await AVURLAsset(url: url).load(.duration), t.isNumeric, t.seconds > 0 else { return nil }
        cache[key] = t.seconds
        return t.seconds
    }

    func remote(key: String, request: URLRequest?) async -> Double? {
        if let d = cache[key] { return d }
        guard let request, let (data, resp) = try? await URLSession.shared.data(for: request),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = obj["durationSeconds"] as? Double, d > 0 else { return nil }
        cache[key] = d
        return d
    }
}

/// Muted, looping player.
final class LoopingPlayerBox {
    let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?

    func load(_ asset: AVURLAsset) {
        let item = AVPlayerItem(asset: asset)
        looper = AVPlayerLooper(player: player, templateItem: item)
        player.isMuted = true
    }

    func stop() {
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
    }
}

/// Bare player layer, no system controls.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class V: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
    func makeUIView(context: Context) -> V {
        let v = V()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspectFill
        v.isUserInteractionEnabled = false
        return v
    }
    func updateUIView(_ v: V, context: Context) { v.playerLayer.player = player }
}

/// Larger, full-width player (sound on, system controls).
struct ClipExpandedPlayer: View {
    let asset: AVURLAsset
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player).ignoresSafeArea()
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 15, weight: .bold))
                    .frame(width: 40, height: 40)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .padding()
            .accessibilityLabel("Close player")
        }
        .onAppear {
            let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            player = p
            p.play()
        }
        .onDisappear { player?.pause(); player = nil }
    }
}
