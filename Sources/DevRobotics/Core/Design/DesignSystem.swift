import SwiftUI

/// Shared design tokens. Rules live in docs/design.md; read them before styling anything.
enum DS {
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }
    enum Radius {
        static let chip: CGFloat = 14
        static let control: CGFloat = 20
        static let card: CGFloat = 28
    }
}

extension Animation {
    /// Default feel for state changes (cards expanding, values changing).
    static let dsSpring = Animation.spring(duration: 0.45, bounce: 0.28)
    /// Quick feedback (selection, toggles).
    static let dsSnappy = Animation.snappy(duration: 0.28)
    /// Slow, soft transitions (content appearing).
    static let dsSmooth = Animation.smooth(duration: 0.55)
}

extension View {
    /// Animate `value` changes with the shared spring unless Reduce Motion is on.
    func dsAnimation<V: Equatable>(_ animation: Animation = .dsSpring, value: V) -> some View {
        modifier(DSAnimationModifier(animation: animation, value: value))
    }
}

private struct DSAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: V
    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

// MARK: - Background

/// Soft brand-tinted mesh behind scrolling content. This is what gives Liquid Glass something to refract.
/// Static on purpose (no battery cost). Use as `.background { AppBackground() }`.
struct AppBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let a = Theme.accent.opacity(dark ? 0.34 : 0.26)
        let b = Color(red: 0.38, green: 0.36, blue: 0.95).opacity(dark ? 0.26 : 0.16)   // indigo
        let c = Color(red: 0.10, green: 0.70, blue: 0.75).opacity(dark ? 0.22 : 0.16)   // teal
        let base = Theme.background
        MeshGradient(width: 3, height: 3,
                     points: [[0, 0], [0.5, 0], [1, 0],
                              [0, 0.45], [0.62, 0.38], [1, 0.5],
                              [0, 1], [0.5, 1], [1, 1]],
                     colors: [a, b, base,
                              base, c, a,
                              b, base, c])
            .background(base)
            .ignoresSafeArea()
    }
}

// MARK: - Glass surfaces

/// A glass card. Use for the few surfaces that float over the background (status header, metric tiles, banners).
/// Do not nest glass inside glass; group neighbours in a `GlassEffectContainer`.
struct GlassCard<Content: View>: View {
    var tint: Color? = nil
    var interactive = false
    var padding: CGFloat = DS.Space.l
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(glass, in: .rect(cornerRadius: DS.Radius.card))
    }

    private var glass: Glass {
        var g = Glass.regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }
}

/// Small status chip ("Online", "Draft", "2 problems").
struct GlassPill: View {
    var text: String
    var systemImage: String? = nil
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(text)
        }
        .font(Theme.font(12, weight: .semibold, relativeTo: .caption))
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, 6)
        .glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular, in: .capsule)
    }
}

/// A metric tile: icon, small label, large monospaced value. Value changes roll like a counter.
struct MetricTile: View {
    var title: String
    var value: String
    var systemImage: String
    var tint: Color = Theme.accent
    var detail: String? = nil

    var body: some View {
        GlassCard(padding: DS.Space.m) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Label(title, systemImage: systemImage)
                    .font(Theme.font(12, weight: .medium, relativeTo: .caption))
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
                Text(value)
                    .font(Theme.font(26, weight: .semibold, mono: true, relativeTo: .title))
                    .foregroundStyle(tint)
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                if let detail {
                    Text(detail).font(Theme.font(11, relativeTo: .caption2)).foregroundStyle(.secondary)
                }
            }
        }
        .dsAnimation(value: value)
    }
}

// MARK: - Buttons

/// Spring press for custom (non-glass) tappable views: scales down, dips opacity, light haptic on press.
struct PressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(reduceMotion ? nil : .dsSnappy, value: configuration.isPressed)
            .sensoryFeedback(.impact(weight: .light), trigger: configuration.isPressed) { _, pressed in pressed }
    }
}

/// Primary call-to-action: prominent glass, tinted with the brand colour.
struct PrimaryActionStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.font(16, weight: .semibold, relativeTo: .headline))
            .foregroundStyle(Theme.accentContrast)
            .padding(.vertical, DS.Space.m)
            .padding(.horizontal, DS.Space.xl)
            .frame(maxWidth: .infinity)
            .glassEffect(.regular.tint(Theme.accent).interactive(), in: .rect(cornerRadius: DS.Radius.control))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .dsSnappy, value: configuration.isPressed)
            .sensoryFeedback(.impact(weight: .medium), trigger: configuration.isPressed) { _, pressed in pressed }
    }
}

/// Secondary action: plain glass.
struct SecondaryActionStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.font(15, weight: .medium, relativeTo: .body))
            .foregroundStyle(Theme.accent)
            .padding(.vertical, DS.Space.m)
            .padding(.horizontal, DS.Space.l)
            .frame(maxWidth: .infinity)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: DS.Radius.control))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .dsSnappy, value: configuration.isPressed)
            .sensoryFeedback(.impact(weight: .light), trigger: configuration.isPressed) { _, pressed in pressed }
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
}
extension ButtonStyle where Self == PrimaryActionStyle {
    static var primaryAction: PrimaryActionStyle { PrimaryActionStyle() }
}
extension ButtonStyle where Self == SecondaryActionStyle {
    static var secondaryAction: SecondaryActionStyle { SecondaryActionStyle() }
}

// MARK: - Layout helpers

/// Small section header used above groups of content.
struct SectionTitle: View {
    var text: String
    var body: some View {
        Text(text.uppercased())
            .font(Theme.font(12, weight: .semibold, relativeTo: .caption))
            .tracking(0.8)
            .foregroundStyle(.secondary)
            .padding(.horizontal, DS.Space.xs)
    }
}

extension View {
    /// Standard scrolling page: brand background, page margins, interactive keyboard dismissal.
    func dsPage() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background { AppBackground() }
            .scrollDismissesKeyboard(.interactively)
    }
}
