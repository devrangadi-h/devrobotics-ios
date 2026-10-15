import SwiftUI

/// Big glass on/off switch. The track is glass tinted with the lamp colour; the knob is plain.
struct LightsSwitch: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var isOn: Bool
    var tint: Color
    var enabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Color.clear.frame(width: 104, height: 60)
                Circle()
                    .fill(.white)
                    .frame(width: 48, height: 48)
                    .overlay {
                        Image(systemName: isOn ? "lightbulb.max.fill" : "lightbulb")
                            .font(.system(size: 20))
                            .foregroundStyle(isOn ? tint : Color.gray)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                    .padding(6)
            }
            .glassEffect(.regular.tint(isOn ? tint.opacity(0.7) : nil).interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .animation(reduceMotion ? nil : .dsSpring, value: isOn)
        .sensoryFeedback(.impact(weight: .medium), trigger: isOn)
        .accessibilityLabel("Lights")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// Rounded slider with haptic detents. `fill` shows a filled bar; otherwise a thumb on a gradient track.
struct LightsSlider: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var value: Double
    var range: ClosedRange<Double>
    var colors: [Color]
    var enabled: Bool
    var fill = true
    var height: CGFloat = 52
    var label: String
    var unit = ""
    var onEditing: (Bool) -> Void = { _ in }
    var onCommit: () -> Void

    @State private var dragging = false

    private var frac: Double { (value - range.lowerBound) / (range.upperBound - range.lowerBound) }
    private var step: Int { Int(frac * 10) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                if fill {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(height, w * frac))
                        .overlay(alignment: .trailing) {
                            Capsule().fill(.white.opacity(0.9)).frame(width: 4, height: height * 0.42)
                                .padding(.trailing, 10)
                        }
                } else {
                    Capsule().fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    Circle().fill(.white).frame(width: height - 8, height: height - 8)
                        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                        .offset(x: 4 + (w - height + 8 - 8) * frac)
                }
            }
            .frame(height: height)
            .scaleEffect(y: dragging && !reduceMotion ? 1.1 : 1)
            .animation(reduceMotion ? nil : .dsSnappy, value: dragging)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if !dragging { dragging = true; onEditing(true) }
                    let f = min(1, max(0, g.location.x / w))
                    value = (range.lowerBound + f * (range.upperBound - range.lowerBound)).rounded()
                }
                .onEnded { _ in
                    dragging = false; onEditing(false)
                    onCommit()
                })
            .disabled(!enabled)
        }
        .frame(height: height)
        .sensoryFeedback(.selection, trigger: step) { _, _ in dragging }
        .sensoryFeedback(.impact(weight: .light), trigger: dragging) { _, d in !d }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(Int(value))\(unit)")
        .accessibilityAdjustableAction { dir in
            guard enabled else { return }
            let d = (range.upperBound - range.lowerBound) / 10
            value = min(range.upperBound, max(range.lowerBound, value + (dir == .increment ? d : -d)))
            onCommit()
        }
    }
}

/// Soft placeholder shimmer for the loading state.
struct LightsShimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var active: Bool
    func body(content: Content) -> some View {
        if active {
            content.redacted(reason: .placeholder)
                .phaseAnimator([0.45, 1.0]) { v, o in v.opacity(reduceMotion ? 0.7 : o) } animation: { _ in .easeInOut(duration: 0.9) }
        } else { content }
    }
}

extension View {
    func lightsShimmer(_ active: Bool) -> some View { modifier(LightsShimmer(active: active)) }
}

/// A dot that gently pulses while live.
struct LightsLiveDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var color: Color
    var live: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.35))
                .frame(width: 18, height: 18)
                .scaleEffect(pulse && live && !reduceMotion ? 1.0 : 0.5)
                .opacity(pulse && live ? 0 : 1)
            Circle().fill(color).frame(width: 9, height: 9)
        }
        .frame(width: 18, height: 18)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}
