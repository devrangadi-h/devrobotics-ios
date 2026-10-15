import SwiftUI

struct LightsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model = LightsModel()
    @State private var lampsExpanded = true
    @State private var naming = false
    @State private var sceneName = ""
    @State private var pickerColor = Color.white
    @Namespace private var glassNS

    private var api: API { API(settings: settings) }
    private var enabled: Bool { model.reach == .up }
    private var loading: Bool { !model.stateLoaded && (model.reach == .unknown || model.reach == .checking) }
    private var color: Color { model.displayColor }
    private var glowStrength: Double { model.anyOn ? 0.25 + 0.5 * model.displayBrightness / 100 : 0 }
    private var pct: Int { Int(model.displayBrightness.rounded()) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Space.xl) {
                    statusWindow
                    if model.reach == .down || !settings.isConfigured {
                        ConnectionBanner(text: bannerText)
                    }
                    masterToggle
                    brightnessCard
                    colourCard
                    scenesSection
                    if model.supports("timer") { timerSection }
                    if !model.lamps.isEmpty { lampsCard }
                    feedbackRow
                }
                .padding(.horizontal, DS.Space.l)
                .padding(.top, DS.Space.s)
                .padding(.bottom, 120)
            }
            .dsPage()
            .background { ambientGlow }
            .navigationTitle("Lights")
            .task {
                await model.ping(api)
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(8))
                    if Task.isCancelled { break }
                    if !model.busy && !model.editing { await model.load(api) }
                }
            }
            .refreshable { await model.ping(api) }
            .sensoryFeedback(.success, trigger: model.sendTick) { _, _ in
                if case .ok = model.banner { return true } else { return false }
            }
            .sensoryFeedback(.error, trigger: model.sendTick) { _, _ in
                if case .failed = model.banner { return true } else { return false }
            }
            .alert("Save scene", isPresented: $naming) {
                TextField("Name", text: $sceneName)
                Button("Save") {
                    let n = sceneName.trimmingCharacters(in: .whitespaces)
                    if !n.isEmpty { withAnimation(.dsSpring) { model.saveCurrentScene(name: n) } }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Saves the current colour and brightness.")
            }
        }
    }

    private var bannerText: String {
        if !settings.isConfigured { return "Set the Pi address and token in Settings." }
        if case .failed(let m) = model.banner { return m }
        return "Can't reach the Pi. Make sure Tailscale is connected."
    }

    // MARK: Ambient

    private var ambientGlow: some View {
        ZStack {
            RadialGradient(colors: [color.opacity(glowStrength), .clear],
                           center: .init(x: 0.5, y: 0.2), startRadius: 10, endRadius: 460)
            RadialGradient(colors: [color.opacity(glowStrength * 0.4), .clear],
                           center: .init(x: 0.5, y: 0.95), startRadius: 10, endRadius: 380)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .dsAnimation(.dsSmooth, value: glowStrength)
        .animation(reduceMotion ? nil : .dsSmooth, value: color)
    }

    // MARK: Status window

    private var statusWindow: some View {
        GlassCard(tint: model.anyOn ? color.opacity(0.28) : nil) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(spacing: DS.Space.s) {
                    LightsLiveDot(color: reachColor, live: model.reach == .up)
                    Text(reachText)
                        .font(Theme.font(13, weight: .semibold, relativeTo: .footnote))
                        .contentTransition(.interpolate)
                    Spacer()
                    if model.reach == .down {
                        Button { Task { await model.ping(api) } } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                                .font(Theme.font(13, weight: .semibold, relativeTo: .footnote))
                        }
                        .buttonStyle(.glass)
                    } else if let t = model.lastUpdate {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text("Updated \(max(0, Int(ctx.date.timeIntervalSince(t))))s ago")
                                .font(Theme.font(12, mono: true, relativeTo: .caption))
                                .foregroundStyle(.secondary)
                                .contentTransition(.numericText())
                        }
                    }
                }
                HStack(spacing: DS.Space.l) {
                    ZStack {
                        Circle().fill(color.opacity(model.anyOn ? 0.55 : 0))
                            .frame(width: 84, height: 84).blur(radius: 14)
                        Circle().fill(model.anyOn ? color : Color.gray.opacity(0.35))
                            .frame(width: 58, height: 58)
                            .overlay { Circle().strokeBorder(.white.opacity(0.55), lineWidth: 2) }
                            .overlay {
                                Image(systemName: model.anyOn ? "lightbulb.max.fill" : "lightbulb.slash")
                                    .font(.system(size: 22))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .contentTransition(.symbolEffect(.replace))
                            }
                    }
                    .frame(width: 70, height: 70)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                            Text(model.anyOn ? "On" : "Off")
                                .font(Theme.font(28, weight: .bold, relativeTo: .title))
                                .contentTransition(.interpolate)
                            if model.anyOn {
                                Text("\(pct)%")
                                    .font(Theme.font(22, weight: .semibold, mono: true, relativeTo: .title2))
                                    .foregroundStyle(.secondary)
                                    .contentTransition(.numericText(value: model.displayBrightness))
                            }
                        }
                        Text(lampSummary)
                            .font(Theme.font(13, relativeTo: .footnote)).foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                if let end = model.timerEndsAt, model.supports("timer") {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        let left = max(0, Int(end.timeIntervalSince(ctx.date)))
                        HStack(spacing: DS.Space.s) {
                            Image(systemName: "moon.zzz.fill").symbolEffect(.pulse)
                            Text("Turns off in \(String(format: "%d:%02d", left / 60, left % 60))")
                                .font(Theme.font(14, weight: .medium, mono: true, relativeTo: .subheadline))
                                .contentTransition(.numericText(countsDown: true))
                            Spacer()
                            Button("Cancel") { model.cancelTimer(api) }
                                .font(Theme.font(13, weight: .semibold, relativeTo: .footnote))
                                .buttonStyle(.glass)
                        }
                    }
                    .transition(.opacity.combined(with: .scale(0.96)))
                }
            }
            .lightsShimmer(loading)
        }
        .dsAnimation(value: model.anyOn)
        .dsAnimation(value: model.timerEndsAt != nil)
        .dsAnimation(value: model.reach)
    }

    private var lampSummary: String {
        if loading { return "Looking for lamps" }
        if model.lamps.isEmpty { return model.power == nil ? "No state yet" : "Last command sent" }
        let n = model.lamps.count, on = model.lamps.filter(\.on).count
        let off = model.lamps.filter { !$0.online }.count
        var s = "\(n) lamp\(n == 1 ? "" : "s")"
        if on > 0 && on < n { s += " · \(on) on" }
        if off > 0 { s += " · \(off) offline" }
        return s
    }

    // MARK: Master toggle

    private var masterToggle: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("All lights").font(Theme.font(20, weight: .semibold, relativeTo: .title3))
                Text(model.busy ? "Sending..." : (model.anyOn ? "Tap to turn off" : "Tap to turn on"))
                    .font(Theme.font(13, relativeTo: .footnote)).foregroundStyle(.secondary)
                    .contentTransition(.interpolate)
            }
            Spacer()
            LightsSwitch(isOn: model.anyOn, tint: color, enabled: enabled) {
                model.setPower(api, !model.anyOn)
            }
        }
        .padding(.horizontal, DS.Space.xs)
        .dsAnimation(value: model.anyOn)
    }

    // MARK: Brightness

    private var brightnessCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(alignment: .firstTextBaseline) {
                    SectionTitle(text: "Brightness")
                    Spacer()
                    Text("\(Int(model.brightness.rounded()))%")
                        .font(Theme.font(28, weight: .semibold, mono: true, relativeTo: .title))
                        .contentTransition(.numericText(value: model.brightness))
                        .foregroundStyle(enabled ? Theme.text : Theme.muted)
                        .dsAnimation(.dsSnappy, value: Int(model.brightness.rounded()))
                }
                LightsSlider(value: $model.brightness, range: 1...100,
                             colors: [color.opacity(0.5), color], enabled: enabled, label: "Brightness", unit: " percent",
                             onEditing: { model.editing = $0 }, onCommit: { model.commitBrightness(api) })
                Text("Sent when you let go")
                    .font(Theme.font(12, relativeTo: .caption)).foregroundStyle(.secondary)
            }
        }
        .opacity(enabled ? 1 : 0.6)
        .dsAnimation(.dsSmooth, value: enabled)
    }

    // MARK: Colour

    private static let swatches: [(String, Color, LampRGB)] = [
        ("Red", .red, .init(r: 255, g: 50, b: 50)), ("Orange", .orange, .init(r: 255, g: 140, b: 0)),
        ("Yellow", .yellow, .init(r: 255, g: 220, b: 40)), ("Green", .green, .init(r: 40, g: 220, b: 90)),
        ("Teal", .teal, .init(r: 20, g: 200, b: 200)), ("Blue", .blue, .init(r: 40, g: 100, b: 255)),
        ("Purple", .purple, .init(r: 150, g: 70, b: 255)), ("Pink", .pink, .init(r: 255, g: 80, b: 170)),
    ]

    private var colourCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionTitle(text: "Colour")
            GlassEffectContainer(spacing: DS.Space.m) {
                HStack(spacing: DS.Space.m) {
                    presetChip("Warm", "3000K", "bright_white_warm", "Warm white (3000K)", .orange, "sun.max.fill")
                    presetChip("Cool", "6500K", "bright_white_cool", "Cool white (6500K)", .cyan, "snowflake")
                }
            }
            if model.supports("colortemp") || model.supports("color") {
                GlassCard {
                    VStack(alignment: .leading, spacing: DS.Space.m) {
                        if model.supports("colortemp") {
                            HStack(alignment: .firstTextBaseline) {
                                Text("Temperature").font(Theme.font(15, weight: .medium, relativeTo: .body))
                                Spacer()
                                Text("\(Int(model.kelvin))K")
                                    .font(Theme.font(17, weight: .semibold, mono: true, relativeTo: .headline))
                                    .contentTransition(.numericText(value: model.kelvin))
                                    .foregroundStyle(Theme.text)
                            }
                            LightsSlider(value: $model.kelvin, range: 2000...9000,
                                         colors: [kelvinColor(2000), kelvinColor(3500), kelvinColor(5500), kelvinColor(9000)],
                                         enabled: enabled, fill: false, label: "Colour temperature", unit: " Kelvin",
                                         onEditing: { model.editing = $0 }, onCommit: { model.commitKelvin(api) })
                        }
                        if model.supports("color") {
                            HStack {
                                Text("Colour").font(Theme.font(15, weight: .medium, relativeTo: .body))
                                Spacer()
                                ColorPicker("Custom colour", selection: $pickerColor, supportsOpacity: false)
                                    .labelsHidden()
                                    .disabled(!enabled)
                                    .onChange(of: pickerColor) { _, c in
                                        if let rgb = Self.rgb(c) { model.setColor(api, rgb) }
                                    }
                            }
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: DS.Space.m) {
                                    ForEach(Self.swatches, id: \.0) { name, c, rgb in
                                        let sel = model.lastRGB == rgb && model.preset == nil
                                        Button { model.setColor(api, rgb) } label: {
                                            Circle().fill(c.gradient).frame(width: 40, height: 40)
                                                .overlay { Circle().strokeBorder(.white.opacity(sel ? 1 : 0.25), lineWidth: sel ? 3 : 1) }
                                                .scaleEffect(sel && !reduceMotion ? 1.12 : 1)
                                        }
                                        .buttonStyle(.pressable)
                                        .disabled(!enabled)
                                        .accessibilityLabel(name)
                                        .dsAnimation(.dsSpring, value: sel)
                                    }
                                }
                                .padding(.vertical, DS.Space.xs)
                            }
                        }
                    }
                }
                .opacity(enabled ? 1 : 0.6)
            }
        }
        .dsAnimation(.dsSmooth, value: enabled)
    }

    private static func rgb(_ c: Color) -> LampRGB? {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return LampRGB(r: Int((r * 255).rounded()), g: Int((g * 255).rounded()), b: Int((b * 255).rounded()))
    }

    private func presetChip(_ title: String, _ kelvin: String, _ name: String, _ label: String,
                            _ tint: Color, _ icon: String) -> some View {
        let selected = model.preset == name
        return Button {
            model.setPreset(api, name, label: label)
        } label: {
            VStack(spacing: DS.Space.xs) {
                Image(systemName: icon).font(.system(size: 22)).symbolEffect(.bounce, value: selected)
                Text(title).font(Theme.font(16, weight: .semibold, relativeTo: .headline))
                Text(kelvin).font(Theme.font(12, mono: true, relativeTo: .caption)).foregroundStyle(.secondary)
            }
            .foregroundStyle(selected ? Theme.text : Theme.muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Space.m)
            .glassEffect(.regular.tint(tint.opacity(selected ? 0.55 : 0.15)).interactive(),
                         in: .rect(cornerRadius: DS.Radius.card))
            .glassEffectID(name, in: glassNS)
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.text).padding(8)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.6)
        .accessibilityLabel("\(label)\(selected ? ", selected" : "")")
        .sensoryFeedback(.selection, trigger: model.preset)
        .dsAnimation(.dsSpring, value: selected)
    }

    // MARK: Scenes

    private var scenesSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionTitle(text: "Scenes")
            ScrollView(.horizontal, showsIndicators: false) {
                GlassEffectContainer(spacing: DS.Space.s) {
                    HStack(spacing: DS.Space.s) {
                        ForEach(LightScene.builtIns + model.savedScenes) { scene in sceneChip(scene) }
                        Button {
                            sceneName = ""; naming = true
                        } label: {
                            VStack(spacing: DS.Space.xs) {
                                Image(systemName: "plus").font(.system(size: 20, weight: .semibold))
                                Text("Save").font(Theme.font(13, weight: .semibold, relativeTo: .footnote))
                            }
                            .frame(width: 76, height: 76)
                            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: DS.Radius.control))
                        }
                        .buttonStyle(.plain)
                        .disabled(!enabled)
                        .accessibilityLabel("Save current as scene")
                    }
                    .padding(.vertical, 2)
                }
            }
            .scrollClipDisabled()
        }
        .opacity(enabled ? 1 : 0.6)
    }

    private func sceneChip(_ scene: LightScene) -> some View {
        Button {
            model.apply(api, scene: scene)
        } label: {
            VStack(spacing: DS.Space.xs) {
                Image(systemName: scene.icon).font(.system(size: 20))
                    .symbolRenderingMode(.hierarchical)
                Text(scene.name).font(Theme.font(13, weight: .semibold, relativeTo: .footnote)).lineLimit(1)
            }
            .foregroundStyle(Theme.text)
            .frame(width: 76, height: 76)
            .glassEffect(.regular.tint(scene.color.opacity(0.5)).interactive(),
                         in: .rect(cornerRadius: DS.Radius.control))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .contextMenu {
            if !scene.builtIn {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    withAnimation(.dsSpring) { model.deleteScene(scene) }
                }
            }
        }
        .transition(.opacity.combined(with: .scale(0.9)))
        .accessibilityLabel("\(scene.name) scene")
    }

    // MARK: Timer

    private var timerSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionTitle(text: "Sleep timer")
            GlassEffectContainer(spacing: DS.Space.s) {
                HStack(spacing: DS.Space.s) {
                    ForEach([15, 30, 60, 120], id: \.self) { m in
                        Button {
                            model.setTimer(api, minutes: m)
                        } label: {
                            Text(m >= 60 ? "\(m / 60) h" : "\(m) m")
                                .font(Theme.font(15, weight: .semibold, relativeTo: .body))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, DS.Space.m)
                                .glassEffect(.regular.interactive(), in: .capsule)
                        }
                        .buttonStyle(.plain)
                        .disabled(!enabled)
                        .accessibilityLabel("Turn off in \(m) minutes")
                    }
                }
            }
        }
        .opacity(enabled ? 1 : 0.6)
    }

    // MARK: Lamps

    private var lampsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Button {
                    withAnimation(reduceMotion ? nil : .dsSpring) { lampsExpanded.toggle() }
                } label: {
                    HStack {
                        SectionTitle(text: "Lamps")
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(lampsExpanded ? 0 : -90))
                    }
                }
                .buttonStyle(.plain)
                .sensoryFeedback(.selection, trigger: lampsExpanded)
                if lampsExpanded {
                    ForEach(model.lamps) { lamp in lampRow(lamp) }
                }
            }
        }
        .opacity(enabled ? 1 : 0.6)
    }

    private func lampRow(_ lamp: Lamp) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Circle().fill(lamp.online ? Theme.ok : Color.gray).frame(width: 8, height: 8)
                Text(lamp.name).font(Theme.font(15, weight: .medium, relativeTo: .body)).lineLimit(1)
                Spacer()
                Text("\(lamp.brightness)%")
                    .font(Theme.font(13, mono: true, relativeTo: .footnote)).foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: Double(lamp.brightness)))
                Toggle("", isOn: Binding(get: { lamp.on }, set: { model.setPower(api, $0, lamp: lamp.index) }))
                    .labelsHidden()
                    .tint(color)
                    .disabled(!enabled || !lamp.online)
            }
            LightsSlider(value: lampBrightness(lamp), range: 1...100,
                         colors: [color.opacity(0.5), color], enabled: enabled && lamp.online && lamp.on,
                         height: 36, label: "\(lamp.name) brightness", unit: " percent",
                         onEditing: { model.editing = $0 },
                         onCommit: { model.commitLampBrightness(api, lamp: lamp.index, value: lamp.brightness) })
        }
        .transition(.opacity.combined(with: .scale(0.96)))
    }

    private func lampBrightness(_ lamp: Lamp) -> Binding<Double> {
        Binding(get: { Double(model.lamps.first { $0.index == lamp.index }?.brightness ?? lamp.brightness) },
                set: { v in
                    if let i = model.lamps.firstIndex(where: { $0.index == lamp.index }) { model.lamps[i].brightness = Int(v) }
                })
    }

    // MARK: Feedback

    @ViewBuilder private var feedbackRow: some View {
        Group {
            switch model.banner {
            case .none: Color.clear.frame(height: 0)
            case .working:
                GlassPill(text: "Sending...", systemImage: "paperplane.fill").symbolEffect(.pulse)
            case .ok(let m):
                GlassPill(text: m, systemImage: "checkmark.circle.fill", tint: Theme.ok.opacity(0.4))
                    .symbolEffect(.bounce, value: model.sendTick)
            case .failed(let m):
                GlassPill(text: m, systemImage: "exclamationmark.triangle.fill", tint: .red.opacity(0.4))
                    .symbolEffect(.bounce, value: model.sendTick)
            }
        }
        .frame(maxWidth: .infinity)
        .transition(.opacity.combined(with: .scale(0.96)))
        .dsAnimation(value: bannerKey)
    }

    private var bannerKey: String {
        switch model.banner {
        case .none: "none"; case .working: "working"
        case .ok(let m): "ok\(m)"; case .failed(let m): "f\(m)"
        }
    }

    private var reachColor: Color {
        switch model.reach { case .up: Theme.ok; case .down: .red; default: .gray }
    }
    private var reachText: String {
        switch model.reach {
        case .unknown: "Not checked"; case .checking: "Checking..."
        case .up: "Pi reachable"; case .down: "Pi unreachable"
        }
    }
}
