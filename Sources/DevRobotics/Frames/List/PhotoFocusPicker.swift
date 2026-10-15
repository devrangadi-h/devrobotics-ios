import SwiftUI

/// Large photo with a square-crop preview. Tap or drag to move the focus point; the crosshair springs to the touch.
struct PhotoFocusPicker: View {
    let source: ThumbSource?
    @Binding var focus: String
    @Environment(SettingsStore.self) private var settings
    @State private var image: UIImage?
    @State private var touching = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .overlay { GeometryReader { g in overlay(g.size) } }
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .fill(Theme.surface2).frame(height: 260)
                    .overlay { ProgressView() }
            }
        }
        .task(id: source) {
            guard let source else { return }
            image = await ThumbLoading.image(source, settings: settings, width: 1000)
        }
    }

    private func overlay(_ size: CGSize) -> some View {
        let f = FrameFormat.parseFocus(focus) ?? (0.5, 0.5)
        let side = min(size.width, size.height)
        let cx = min(max(f.x * size.width, side / 2), size.width - side / 2)
        let cy = min(max(f.y * size.height, side / 2), size.height - side / 2)
        let crop = CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side)
        return ZStack {
            Path { p in p.addRect(CGRect(origin: .zero, size: size)); p.addRect(crop) }
                .fill(.black.opacity(0.4), style: FillStyle(eoFill: true))
            RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.9), lineWidth: 1.5)
                .frame(width: crop.width, height: crop.height).position(x: crop.midX, y: crop.midY)
            Crosshair(active: touching)
                .position(x: f.x * size.width, y: f.y * size.height)
        }
        .dsAnimation(.dsSnappy, value: focus)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { v in
                touching = true
                focus = FrameFormat.focusString(x: min(max(v.location.x / max(size.width, 1), 0), 1),
                                                y: min(max(v.location.y / max(size.height, 1), 0), 1))
            }
            .onEnded { _ in touching = false })
        .sensoryFeedback(.selection, trigger: focus)
    }
}

private struct Crosshair: View {
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            Circle().stroke(.white, lineWidth: 2.5).frame(width: 30, height: 30)
            Circle().stroke(Theme.accent, lineWidth: 1.5).frame(width: 38, height: 38)
            Capsule().fill(.white).frame(width: 2, height: 10).offset(y: -22)
            Capsule().fill(.white).frame(width: 2, height: 10).offset(y: 22)
            Capsule().fill(.white).frame(width: 10, height: 2).offset(x: -22)
            Capsule().fill(.white).frame(width: 10, height: 2).offset(x: 22)
            Circle().fill(.white).frame(width: 5, height: 5)
        }
        .shadow(color: .black.opacity(0.5), radius: 3)
        .scaleEffect(active && !reduceMotion ? 1.25 : 1)
        .animation(reduceMotion ? nil : .dsSpring, value: active)
        .allowsHitTesting(false)
    }
}
