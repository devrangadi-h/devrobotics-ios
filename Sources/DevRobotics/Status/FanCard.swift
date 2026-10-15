import SwiftUI

/// Status-tab card: live fan RPM and temperature, Auto / Manual, a speed slider, and a prominent Max button.
/// Content sits on the plain card surface; the Max / Back to Auto buttons are the only glass (hero actions).
/// Polls every ~5 s, but only while this view is on screen (the `.task` is cancelled when the tab disappears).
struct FanCard: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model = FanModel()
    @State private var draft: Double = 50
    @State private var dragging = false

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                card { ProgressView().frame(maxWidth: .infinity, minHeight: 120) }
            case .unavailable:
                card {
                    Label("Fan control isn't available on this Polaris yet.", systemImage: "fan.slash")
                        .font(Theme.font(14, relativeTo: .subheadline))
                        .foregroundStyle(.secondary)
                    Text("Update polaris-app-api and install the fan helper on the Pi.")
                        .font(Theme.font(12, relativeTo: .caption)).foregroundStyle(.tertiary)
                }
            case .ready:
                if let s = model.state { card { controls(s) } }
            }
        }
        .dsAnimation(value: model.state)
        .dsAnimation(value: model.phase)
        .sensoryFeedback(.success, trigger: model.successTick)
        .sensoryFeedback(.error, trigger: model.errorTick)
        .task {
            while !Task.isCancelled {
                await model.refresh(settings: settings)
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .onChange(of: model.state?.percent) { _, p in
            if !dragging, let p, model.state?.mode == "manual" { draft = Double(p) }
        }
    }

    // MARK: Layout

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionTitle(text: "Fan")
            VStack(alignment: .leading, spacing: DS.Space.m) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Space.l)
                .background(Theme.surface.opacity(0.7), in: .rect(cornerRadius: DS.Radius.control))
        }
    }

    @ViewBuilder private func controls(_ s: FanState) -> some View {
        readout(s)

        if s.mode == "max" {
            maxActive(s)
        } else {
            Picker("Fan mode", selection: modeBinding(s)) {
                Text("Auto").tag(false)
                Text("Manual").tag(true)
            }
            .pickerStyle(.segmented)
            .disabled(model.busy)

            if s.mode == "manual" {
                speedSlider(s)
                    .transition(.opacity.combined(with: .scale(0.96, anchor: .top)))
            }

            Button {
                Task { await model.setMax(settings: settings) }
            } label: {
                Label("Max for 15 min", systemImage: "wind")
            }
            .buttonStyle(.primaryAction)
            .disabled(model.busy)
            .accessibilityHint("Runs the fan at full speed, then returns to automatic.")
        }

        if let m = model.message {
            Label(m, systemImage: "exclamationmark.triangle.fill")
                .font(Theme.font(12, weight: .medium, relativeTo: .caption))
                .foregroundStyle(Theme.warn)
                .transition(.opacity)
        }
        hint(s)
    }

    private func readout(_ s: FanState) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.l) {
            VStack(alignment: .leading, spacing: 2) {
                Text(s.rpm.map { $0.formatted() } ?? "\u{2013}")
                    .font(Theme.font(30, weight: .semibold, mono: true, relativeTo: .title))
                    .foregroundStyle(Theme.accent)
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.6).lineLimit(1)
                Text("RPM").font(Theme.font(11, weight: .medium, relativeTo: .caption2)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(s.tempC.map { String(format: "%.1f\u{00B0}C", $0) } ?? "\u{2013}")
                    .font(Theme.font(30, weight: .semibold, mono: true, relativeTo: .title))
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.6).lineLimit(1)
                Text("CPU temp").font(Theme.font(11, weight: .medium, relativeTo: .caption2)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            GlassPill(text: modeLabel(s), systemImage: s.mode == "max" ? "bolt.fill" : (s.mode == "manual" ? "slider.horizontal.3" : "sparkles"),
                      tint: s.isOverridden ? Theme.accent.opacity(0.35) : nil)
        }
        .dsAnimation(value: s.rpm)
        .accessibilityElement(children: .combine)
    }

    private func speedSlider(_ s: FanState) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack {
                Text("Speed").font(Theme.font(13, weight: .medium, relativeTo: .footnote)).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(draft)) %")
                    .font(Theme.font(15, weight: .semibold, mono: true, relativeTo: .body))
                    .contentTransition(.numericText())
            }
            Slider(value: $draft, in: 0...100, step: 1) { editing in
                dragging = editing
                if !editing { Task { await model.setManual(percent: Int(draft), settings: settings) } }
            }
            .accessibilityLabel("Fan speed")
            .accessibilityValue("\(Int(draft)) percent")
            if let floor = s.minPercent, Int(draft) < floor {
                Text("Held at \(floor) % minimum while the Pi is this warm.")
                    .font(Theme.font(11, relativeTo: .caption2)).foregroundStyle(Theme.warn)
            }
        }
    }

    private func maxActive(_ s: FanState) -> some View {
        VStack(spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "wind").symbolEffect(.pulse, isActive: !reduceMotion)
                Text("Max")
                if let end = s.revertDate {
                    Text("\u{00B7}")
                    Text(end, style: .timer).monospacedDigit().contentTransition(.numericText(countsDown: true))
                    Text("left")
                }
            }
            .font(Theme.font(16, weight: .semibold, relativeTo: .headline))
            .foregroundStyle(Theme.accentContrast)
            .padding(.vertical, DS.Space.m)
            .frame(maxWidth: .infinity)
            .glassEffect(.regular.tint(Theme.accent), in: .rect(cornerRadius: DS.Radius.control))
            .accessibilityElement(children: .combine)

            Button {
                Task { await model.setAuto(settings: settings) }
            } label: {
                Label("Back to Auto", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.secondaryAction)
            .disabled(model.busy)
        }
    }

    @ViewBuilder private func hint(_ s: FanState) -> some View {
        let text: String = {
            switch s.mode {
            case "max": return "Returns to automatic on its own after the timer, or sooner once the Pi cools below 50\u{00B0}C."
            case "manual":
                if let d = s.revertDate { return "Returns to automatic at \(d.formatted(date: .omitted, time: .shortened))." }
                return "Returns to automatic on its own."
            default: return "Automatic follows the Pi's temperature. Any override reverts on its own."
            }
        }()
        Text(text).font(Theme.font(11, relativeTo: .caption2)).foregroundStyle(.secondary)
    }

    // MARK: Helpers

    private func modeLabel(_ s: FanState) -> String {
        switch s.mode {
        case "max": return "Max"
        case "manual": return "Manual"
        default: return "Auto"
        }
    }

    /// true = Manual. Picking Manual sends the current slider value; picking Auto reverts immediately.
    private func modeBinding(_ s: FanState) -> Binding<Bool> {
        Binding(
            get: { s.mode == "manual" },
            set: { wantsManual in
                if wantsManual {
                    if let p = s.percent, !dragging { draft = max(draft, Double(p)) }
                    Task { await model.setManual(percent: Int(draft), settings: settings) }
                } else {
                    Task { await model.setAuto(settings: settings) }
                }
            })
    }
}
