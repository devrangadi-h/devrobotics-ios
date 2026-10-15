import SwiftUI
import Charts

@MainActor
@Observable
final class StatusModel {
    var status: PiStatus?
    var isCached = false
    var error: String?
    var loading = false

    func load(settings: SettingsStore) async {
        loading = true
        defer { loading = false }
        do {
            let s = try await API(settings: settings).getJSON(.app, "v1/status", as: PiStatus.self)
            status = s; isCached = false; error = nil
            return
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
        // Fallback: public cached snapshot.
        do {
            let (data, _) = try await URLSession.shared.data(from: PublicPiStatus.url)
            status = try JSONDecoder().decode(PublicPiStatus.self, from: data).asPiStatus()
            isCached = true
        } catch {
            if status == nil { self.error = (self.error ?? "") + "\nPublic status also unavailable." }
        }
    }
}

struct StatusView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model = StatusModel()
    @State private var appeared = false
    @State private var refreshTick = 0
    @State private var selectedTime: Date?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    if let s = model.status {
                        content(s)
                    } else if model.loading {
                        StatusSkeleton()
                    } else {
                        ConnectionBanner(text: model.error ?? "No status yet.")
                    }
                }
                .padding(.horizontal, DS.Space.l)
                .padding(.top, DS.Space.s)
                .padding(.bottom, 110)   // clear the floating tab bar
            }
            .dsPage()
            .navigationTitle("Status")
            .refreshable {
                await model.load(settings: settings)
                refreshTick += 1
            }
            .sensoryFeedback(.success, trigger: refreshTick)
            .task {
                while !Task.isCancelled {
                    await model.load(settings: settings)
                    try? await Task.sleep(for: .seconds(30))
                }
            }
            .onChange(of: model.status != nil) { _, has in
                if has { appeared = true }
            }
            .onAppear { if model.status != nil { appeared = true } }
        }
    }

    private func stagger(_ index: Int) -> StatusStagger {
        StatusStagger(shown: appeared, index: index, reduceMotion: reduceMotion)
    }

    @ViewBuilder private func content(_ s: PiStatus) -> some View {
        let updated = s.updatedDate
        let ageMin = updated.map { Date().timeIntervalSince($0) / 60 }
        let stale = (ageMin ?? 0) > 20
        let online = (s.piOnline ?? false) && !stale

        hero(s, online: online, stale: stale, updated: updated)
            .modifier(stagger(0))

        if model.isCached {
            let n = Int(ageMin ?? 0)
            ConnectionBanner(text: "Cached \u{00B7} \(n) min old. Connect Tailscale for live data.")
                .modifier(stagger(1))
        }

        chart(s).modifier(stagger(2))

        metrics(s).modifier(stagger(3))

        if let services = s.services, !services.isEmpty {
            servicesCard(services).modifier(stagger(4))
        }

        if let p = s.lastPublish {
            infoCard("Last Frames publish") {
                if let d = PiStatus.parseDate(p) {
                    Text(d.formatted(date: .abbreviated, time: .shortened))
                        .font(Theme.font(16, weight: .medium, relativeTo: .body))
                    Text(d, style: .relative).font(Theme.font(12, mono: true, relativeTo: .caption))
                        .foregroundStyle(.secondary)
                } else {
                    Text(p).font(Theme.font(16, relativeTo: .body))
                }
            }
            .modifier(stagger(5))
        }

        if let log = s.lastLog {
            infoCard("Last Polaris log") {
                let stamp = [log.date, log.time].compactMap { $0 }.joined(separator: " ")
                if !stamp.isEmpty {
                    Text(stamp).font(Theme.font(12, mono: true, relativeTo: .caption)).foregroundStyle(.secondary)
                }
                if let sum = log.summary {
                    Text(sum).font(Theme.font(16, weight: .medium, relativeTo: .body))
                }
                if let det = log.details {
                    Text(det).font(Theme.font(13, relativeTo: .footnote)).foregroundStyle(.secondary)
                }
                if let files = log.files, !files.isEmpty {
                    Text(files.joined(separator: ", ")).font(Theme.font(12, mono: true, relativeTo: .caption))
                        .foregroundStyle(Theme.accent)
                }
            }
            .modifier(stagger(6))
        }
    }

    // MARK: Hero

    private func hero(_ s: PiStatus, online: Bool, stale: Bool, updated: Date?) -> some View {
        let tint = online ? Theme.ok : Theme.warn
        let label = online ? "Online" : (stale ? "Stale" : "Offline")
        return GlassCard(tint: tint.opacity(0.12)) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(alignment: .center, spacing: DS.Space.m) {
                    Image(systemName: "cpu")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .symbolRenderingMode(.hierarchical)
                        .frame(width: 44, height: 44)
                        .background(Theme.accent.opacity(0.14), in: .rect(cornerRadius: DS.Radius.chip))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.hostname ?? "polaris")
                            .font(Theme.font(24, weight: .bold, relativeTo: .title2))
                            .lineLimit(2).minimumScaleFactor(0.7)
                        if let updated {
                            Text("Updated \(updated.formatted(.relative(presentation: .named)))")
                                .font(Theme.font(12, mono: true, relativeTo: .caption))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: DS.Space.m) {
                    StatusLivePill(text: label, color: tint, pulsing: online && !reduceMotion)
                    if let up = s.uptimeSeconds {
                        Label("Up \(Self.uptime(up))", systemImage: "clock")
                            .font(Theme.font(12, weight: .medium, relativeTo: .caption))
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Chart

    @ViewBuilder private func chart(_ s: PiStatus) -> some View {
        let all = (s.history ?? []).compactMap { p -> (Date, Double)? in
            guard let t = p.t.flatMap(PiStatus.parseDate), let c = p.cpuTempC else { return nil }
            return (t, c)
        }
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        let recent = all.filter { $0.0 >= cutoff }
        let pts = recent.count >= 2 ? recent : all
        if pts.count >= 2 {
            let selected = selectedTime.flatMap { t in
                pts.min { abs($0.0.timeIntervalSince(t)) < abs($1.0.timeIntervalSince(t)) }
            }
            let shown = selected ?? pts[pts.count - 1]
            GlassCard {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    HStack(alignment: .firstTextBaseline) {
                        Label("CPU temperature", systemImage: "thermometer.medium")
                            .font(Theme.font(12, weight: .semibold, relativeTo: .caption))
                            .foregroundStyle(.secondary)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(String(format: "%.1f \u{00B0}C", shown.1))
                                .font(Theme.font(20, weight: .semibold, mono: true, relativeTo: .title3))
                                .contentTransition(.numericText())
                            Text(selected == nil ? "Latest" : shown.0.formatted(date: .omitted, time: .shortened))
                                .font(Theme.font(11, mono: true, relativeTo: .caption2))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Chart {
                        ForEach(pts, id: \.0) { p in
                            AreaMark(x: .value("Time", p.0), yStart: .value("Base", pts.map(\.1).min()! - 2),
                                     yEnd: .value("\u{00B0}C", p.1))
                                .interpolationMethod(.monotone)
                                .foregroundStyle(LinearGradient(
                                    colors: [Theme.accent.opacity(0.45), Theme.accent.opacity(0.02)],
                                    startPoint: .top, endPoint: .bottom))
                            LineMark(x: .value("Time", p.0), y: .value("\u{00B0}C", p.1))
                                .interpolationMethod(.monotone)
                                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                                .foregroundStyle(Theme.accent)
                        }
                        if let selected {
                            RuleMark(x: .value("Time", selected.0))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                .foregroundStyle(.secondary)
                            PointMark(x: .value("Time", selected.0), y: .value("\u{00B0}C", selected.1))
                                .symbolSize(80).foregroundStyle(Theme.accent)
                        }
                    }
                    .chartXSelection(value: $selectedTime)
                    .chartYScale(domain: (pts.map(\.1).min()! - 2)...(pts.map(\.1).max()! + 2))
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                            AxisValueLabel(format: .dateTime.hour())
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(.secondary.opacity(0.3))
                            AxisValueLabel()
                        }
                    }
                    .frame(height: 170)
                    .sensoryFeedback(.selection, trigger: selected?.0)
                }
            }
        }
    }

    // MARK: Metrics

    private func metrics(_ s: PiStatus) -> some View {
        let load = [s.load1, s.load5, s.load15].compactMap { $0 }.map { String(format: "%.2f", $0) }.joined(separator: " ")
        return GlassEffectContainer(spacing: DS.Space.m) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: DS.Space.m), GridItem(.flexible(), spacing: DS.Space.m)],
                      alignment: .leading, spacing: DS.Space.m) {
                MetricTile(title: "CPU temp", value: s.cpuTempC.map { String(format: "%.1f \u{00B0}C", $0) } ?? "\u{2013}",
                           systemImage: "thermometer.medium", tint: tempTint(s.cpuTempC), detail: "Processor")
                MetricTile(title: "CPU", value: s.cpuPercent.map { String(format: "%.0f%%", $0) } ?? "\u{2013}",
                           systemImage: "cpu", detail: "Utilisation")
                MetricTile(title: "Load", value: load.isEmpty ? "\u{2013}" : load,
                           systemImage: "gauge.with.dots.needle.50percent",
                           detail: load.isEmpty ? nil : "1 / 5 / 15 min")
                MetricTile(title: "Uptime", value: s.uptimeSeconds.map(Self.uptime) ?? "\u{2013}", systemImage: "clock",
                           detail: "Since boot")
                MetricTile(title: "Memory", value: used(s.memory) ?? "\u{2013}", systemImage: "memorychip",
                           detail: percent(s.memory))
                MetricTile(title: "Disk", value: used(s.disk) ?? "\u{2013}", systemImage: "internaldrive",
                           detail: percent(s.disk))
            }
        }
    }

    private func tempTint(_ t: Double?) -> Color {
        guard let t else { return Theme.accent }
        return t >= 75 ? .red : (t >= 65 ? Theme.warn : Theme.accent)
    }

    private func percent(_ u: PiStatus.Usage?) -> String? {
        guard let used = u?.usedBytes, let total = u?.totalBytes, total > 0 else { return nil }
        let f = ByteCountFormatter(); f.countStyle = .binary
        return String(format: "%.0f%% of ", used / total * 100) + f.string(fromByteCount: Int64(total))
    }

    private func used(_ u: PiStatus.Usage?) -> String? {
        guard let used = u?.usedBytes, let total = u?.totalBytes, total > 0 else { return nil }
        let f = ByteCountFormatter(); f.countStyle = .binary
        return f.string(fromByteCount: Int64(used))
    }

    // MARK: Cards

    private func servicesCard(_ services: [PiStatus.Service]) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionTitle(text: "Services")
            VStack(spacing: 0) {
                ForEach(Array(services.enumerated()), id: \.element.name) { idx, svc in
                    let ok = svc.state == "active"
                    HStack(spacing: DS.Space.m) {
                        Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(ok ? Theme.ok : Theme.warn)
                            .symbolEffect(.bounce, value: svc.state)
                            .symbolEffect(.pulse, isActive: !ok && !reduceMotion)
                        Text(svc.name).font(Theme.font(15, mono: true, relativeTo: .subheadline))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: DS.Space.s)
                        Text(svc.state).font(Theme.font(13, weight: .medium, relativeTo: .footnote))
                            .foregroundStyle(ok ? Theme.ok : Theme.warn)
                    }
                    .padding(.vertical, DS.Space.m)
                    .accessibilityElement(children: .combine)
                    if idx < services.count - 1 { Divider() }
                }
            }
            .padding(.horizontal, DS.Space.l)
            .background(Theme.surface.opacity(0.7), in: .rect(cornerRadius: DS.Radius.control))
        }
    }

    private func infoCard<C: View>(_ title: String, @ViewBuilder _ body: () -> C) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionTitle(text: title)
            VStack(alignment: .leading, spacing: DS.Space.xs) { body() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Space.l)
                .background(Theme.surface.opacity(0.7), in: .rect(cornerRadius: DS.Radius.control))
        }
    }

    private func usage(_ u: PiStatus.Usage?) -> String? {
        guard let used = u?.usedBytes, let total = u?.totalBytes, total > 0 else { return nil }
        let f = ByteCountFormatter(); f.countStyle = .binary
        return "\(f.string(fromByteCount: Int64(used))) / \(f.string(fromByteCount: Int64(total)))"
    }

    private static func uptime(_ secs: Double) -> String {
        let s = Int(secs), d = s / 86400, h = s % 86400 / 3600, m = s % 3600 / 60
        return d > 0 ? "\(d)d \(h)h" : (h > 0 ? "\(h)h \(m)m" : "\(m)m")
    }
}

// MARK: - Status-only helpers

/// Staggered entrance: each section fades and rises a little later than the previous one.
private struct StatusStagger: ViewModifier {
    var shown: Bool
    var index: Int
    var reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 18)
            .animation(reduceMotion ? nil : .dsSmooth.delay(Double(index) * 0.06), value: shown)
    }
}

/// Glass status chip with a pulsing dot while live.
private struct StatusLivePill: View {
    var text: String
    var color: Color
    var pulsing: Bool

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                if pulsing {
                    Circle().fill(color).frame(width: 10, height: 10)
                        .phaseAnimator([false, true]) { v, on in
                            v.scaleEffect(on ? 2.4 : 1).opacity(on ? 0 : 0.55)
                        } animation: { _ in .easeOut(duration: 1.4) }
                }
                Circle().fill(color).frame(width: 10, height: 10)
            }
            .frame(width: 14, height: 14)
            Text(text).font(Theme.font(14, weight: .semibold, relativeTo: .subheadline))
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, 8)
        .glassEffect(.regular.tint(color.opacity(0.25)), in: .capsule)
        .accessibilityLabel("Status \(text)")
    }
}

/// Placeholder shown during the first load.
private struct StatusSkeleton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: DS.Space.l) {
            block(height: 120)
            block(height: 230)
            HStack(spacing: DS.Space.m) { block(height: 96); block(height: 96) }
            HStack(spacing: DS.Space.m) { block(height: 96); block(height: 96) }
        }
        .phaseAnimator([0.45, 0.9]) { v, o in
            v.opacity(reduceMotion ? 0.6 : o)
        } animation: { _ in .easeInOut(duration: 0.9) }
        .accessibilityLabel("Loading status")
    }

    private func block(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: DS.Radius.card)
            .fill(.secondary.opacity(0.18))
            .frame(height: height)
    }
}
