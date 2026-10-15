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
    @State private var model = StatusModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let s = model.status {
                        content(s)
                    } else if model.loading {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                    } else {
                        ConnectionBanner(text: model.error ?? "No status yet.")
                    }
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("Status")
            .refreshable { await model.load(settings: settings) }
            .task {
                while !Task.isCancelled {
                    await model.load(settings: settings)
                    try? await Task.sleep(for: .seconds(30))
                }
            }
        }
    }

    @ViewBuilder private func content(_ s: PiStatus) -> some View {
        let updated = s.updatedDate
        let ageMin = updated.map { Date().timeIntervalSince($0) / 60 }
        let stale = (ageMin ?? 0) > 20
        let online = (s.piOnline ?? false) && !stale

        HStack(spacing: 10) {
            Circle().fill(online ? Theme.ok : Theme.warn).frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.hostname ?? "polaris").font(Theme.font(20, weight: .semibold, relativeTo: .title3))
                Text(online ? "Online" : (stale ? "Stale" : "Offline"))
                    .font(Theme.font(13, mono: true, relativeTo: .footnote)).foregroundStyle(Theme.muted)
            }
            Spacer()
            if let updated {
                Text(updated, style: .relative).font(Theme.font(12, mono: true, relativeTo: .caption))
                    .foregroundStyle(Theme.muted)
            }
        }
        .padding(14).background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))

        if model.isCached {
            let n = Int(ageMin ?? 0)
            ConnectionBanner(text: "Cached · \(n) min old. Connect Tailscale for live data.")
        }

        chart(s)

        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            tile("CPU temp", s.cpuTempC.map { String(format: "%.1f °C", $0) })
            tile("CPU", s.cpuPercent.map { String(format: "%.0f%%", $0) })
            tile("Load", [s.load1, s.load5, s.load15].compactMap { $0 }.map { String(format: "%.2f", $0) }.joined(separator: " "))
            tile("Uptime", s.uptimeSeconds.map(Self.uptime))
            tile("Memory", usage(s.memory))
            tile("Disk", usage(s.disk))
        }

        if let services = s.services, !services.isEmpty {
            card("Services") {
                ForEach(services, id: \.name) { svc in
                    HStack {
                        Circle().fill(svc.state == "active" ? Theme.ok : Theme.warn).frame(width: 8, height: 8)
                        Text(svc.name).font(Theme.font(14, mono: true, relativeTo: .subheadline))
                        Spacer()
                        Text(svc.state).font(Theme.font(13, relativeTo: .footnote)).foregroundStyle(Theme.muted)
                    }
                }
            }
        }

        if let p = s.lastPublish {
            card("Last Frames publish") {
                if let d = PiStatus.parseDate(p) {
                    Text(d.formatted(date: .abbreviated, time: .shortened)).font(Theme.font(14))
                } else {
                    Text(p).font(Theme.font(14))
                }
            }
        }

        if let log = s.lastLog {
            card("Last Polaris log") {
                Text([log.date, log.time].compactMap { $0 }.joined(separator: " "))
                    .font(Theme.font(12, mono: true, relativeTo: .caption)).foregroundStyle(Theme.muted)
                if let sum = log.summary { Text(sum).font(Theme.font(15, weight: .medium, relativeTo: .subheadline)) }
                if let det = log.details { Text(det).font(Theme.font(13, relativeTo: .footnote)).foregroundStyle(Theme.muted) }
                if let files = log.files, !files.isEmpty {
                    Text(files.joined(separator: ", ")).font(Theme.font(12, mono: true, relativeTo: .caption))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
    }

    @ViewBuilder private func chart(_ s: PiStatus) -> some View {
        let all = (s.history ?? []).compactMap { p -> (Date, Double)? in
            guard let t = p.t.flatMap(PiStatus.parseDate), let c = p.cpuTempC else { return nil }
            return (t, c)
        }
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        let recent = all.filter { $0.0 >= cutoff }
        let pts = recent.count >= 2 ? recent : all
        if pts.count >= 2 {
            card("CPU temperature") {
                Chart(pts, id: \.0) { p in
                    LineMark(x: .value("Time", p.0), y: .value("°C", p.1))
                        .foregroundStyle(Theme.accent).interpolationMethod(.monotone)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 160)
            }
        }
    }

    private func tile(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.font(12, weight: .medium, relativeTo: .caption)).foregroundStyle(Theme.muted)
            Text(value ?? "–").font(Theme.font(17, weight: .semibold, mono: true, relativeTo: .headline))
                .minimumScaleFactor(0.6).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14).background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func card<C: View>(_ title: String, @ViewBuilder _ body: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.font(12, weight: .medium, relativeTo: .caption)).foregroundStyle(Theme.muted)
            body()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14).background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
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
