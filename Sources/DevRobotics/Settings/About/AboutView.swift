import SwiftUI

struct AboutView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.openURL) private var openURL
    @State private var model = AboutModel()
    @State private var remind = ExpiryReminder.enabled
    @State private var copiedTick = 0
    @State private var testTick = 0

    /// Demo-only: `-aboutScroll <Group title>` scrolls to a section for screenshots.
    private static let demoScroll: String? = {
        guard DemoMode.isOn else { return nil }
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-aboutScroll"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }()

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                Section { hero }
                    .listRowBackground(Color.clear).listRowInsets(EdgeInsets())

                expirySection
                ReinstallFromMacSection()
                groupSection(model.appGroup)
                groupSection(model.deviceGroup)
                piSection
                groupSection(model.storageGroup)
                diagnosticsSection
                creditsSection
                linksSection

                Section {} footer: {
                    Text("© 2026 Hardik Devrangadi").frame(maxWidth: .infinity).multilineTextAlignment(.center)
                }
            }
            .font(Theme.font(16))
            .dsPage()
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await model.loadLocal()
                await model.loadRemote(settings)
            }
            .task {   // ticks the countdown
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    withAnimation(.dsSmooth) { model.now = .now }
                }
            }
            .task {
                if remind, !DemoMode.isOn { _ = await ExpiryReminder.requestIfNeeded() }
                await ExpiryReminder.reschedule()
            }
            .task {
                if let t = Self.demoScroll {
                    try? await Task.sleep(for: .seconds(1.2))
                    proxy.scrollTo(t, anchor: .top)
                }
            }
        }
    }

    // MARK: hero

    private var hero: some View {
        GlassCard {
            VStack(spacing: DS.Space.m) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Theme.accentContrast)
                    .frame(width: 76, height: 76)
                    .background(LinearGradient(colors: [Theme.accent, Theme.accentStrong], startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: .rect(cornerRadius: DS.Radius.control))
                    .symbolEffect(.pulse, options: .repeat(2))
                VStack(spacing: DS.Space.xs) {
                    Text("DevRobotics").font(Theme.font(24, weight: .semibold, relativeTo: .title2))
                    Text("Created by Hardik Devrangadi").font(Theme.font(14, relativeTo: .subheadline)).foregroundStyle(.secondary)
                    Text(model.build.id)
                        .font(Theme.font(12, mono: true, relativeTo: .caption)).foregroundStyle(.secondary)
                        .textSelection(.enabled).multilineTextAlignment(.center)
                    if let d = model.build.builtAt {
                        Text("Built \(AboutModel.dateFmt.string(from: d))")
                            .font(Theme.font(12, mono: true, relativeTo: .caption)).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, DS.Space.xs)
    }

    // MARK: expiry

    private var tint: Color {
        switch ExpiryMath.level(remaining: model.remaining) {
        case .ok: Theme.ok
        case .soon: Theme.warn
        case .urgent, .expired: Theme.danger
        }
    }

    private var expirySection: some View {
        let rem = model.remaining
        let e = model.expiry
        return Section {
            HStack(spacing: DS.Space.l) {
                ZStack {
                    Circle().stroke(tint.opacity(0.2), lineWidth: 8)
                    Circle().trim(from: 0, to: ExpiryMath.fraction(remaining: rem, total: e.total))
                        .stroke(tint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: rem <= 0 ? "exclamationmark.triangle.fill" : "clock.badge.checkmark")
                        .foregroundStyle(tint).symbolEffect(.pulse, isActive: ExpiryMath.level(remaining: rem) == .urgent)
                }
                .frame(width: 60, height: 60)
                .dsAnimation(.dsSmooth, value: ExpiryMath.fraction(remaining: rem, total: e.total))
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(rem <= 0 ? "Expired" : "Expires \(AboutModel.dateFmt.string(from: e.expires).lowercasedMeridiem)\(e.estimated ? " (estimated)" : "")")
                        .font(Theme.font(15, weight: .semibold, relativeTo: .subheadline))
                    Text(ExpiryMath.remainingText(rem))
                        .font(Theme.font(14, mono: true, relativeTo: .subheadline)).foregroundStyle(tint)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, DS.Space.xs)
            .dsAnimation(value: rem <= 0)
            .accessibilityElement(children: .combine)

            Label {
                Text("Reinstall required: plug the phone into your Mac and run `Tools/install.sh` (or ask Claude).")
                    .font(Theme.font(14, relativeTo: .subheadline))
            } icon: { Image(systemName: "cable.connector").foregroundStyle(Theme.accent) }

            Toggle(isOn: $remind) {
                Label("Remind me before it expires", systemImage: "bell.badge")
            }
            .onChange(of: remind) { _, on in
                ExpiryReminder.enabled = on
                Task {
                    if on { _ = await ExpiryReminder.requestIfNeeded() }
                    await ExpiryReminder.reschedule()
                }
            }
        } header: {
            Text("Signing")
        } footer: {
            Text(e.estimated ? "No provisioning profile was readable, so this is the first launch of this build plus 7 days." : "Free Apple IDs expire after 7 days.")
        }
    }

    // MARK: groups

    private func groupSection(_ g: AboutModel.Group) -> some View {
        Section {
            ForEach(g.rows) { r in row(r) }
        } header: { Text(g.title) }
            .id(g.title)
    }

    private func row(_ r: AboutModel.Row) -> some View {
        LabeledContent {
            Text(r.value)
                .font(Theme.font(14, mono: true, relativeTo: .subheadline))
                .multilineTextAlignment(.trailing).textSelection(.enabled)
                .contentTransition(.numericText())
        } label: {
            Label(r.label, systemImage: r.symbol).font(Theme.font(15, relativeTo: .subheadline))
        }
        .dsAnimation(value: r.value)
    }

    private var piSection: some View {
        let g = model.piGroup
        return Section {
            ForEach(g.rows) { r in row(r) }
            Button {
                Task { await model.ping(settings); testTick += 1 }
            } label: {
                HStack {
                    Label(model.pinging ? "Testing…" : "Test again", systemImage: "arrow.triangle.2.circlepath")
                        .symbolEffect(.rotate, isActive: model.pinging)
                    if model.pinging { Spacer(); ProgressView() }
                }
            }
            .disabled(model.pinging || !settings.isConfigured)
            .sensoryFeedback(.impact, trigger: testTick)
            if let err = model.pingError {
                Label(err, systemImage: "exclamationmark.triangle").font(Theme.font(13, relativeTo: .footnote)).foregroundStyle(.secondary)
            }
        } header: { Text(g.title) } footer: {
            Text(settings.isConfigured ? "Latency is the round trip of GET v1/status." : "Connect to Polaris in Settings to measure.")
        }
        .id(g.title)
    }

    // MARK: diagnostics

    private var diagnosticsSection: some View {
        Section {
            Button {
                UIPasteboard.general.string = model.diagnostics()
                copiedTick += 1
            } label: {
                Label("Copy diagnostics", systemImage: copiedTick > 0 ? "checkmark.circle.fill" : "doc.on.doc")
                    .symbolEffect(.bounce, value: copiedTick)
                    .foregroundStyle(copiedTick > 0 ? Theme.ok : Theme.accent)
            }
            .sensoryFeedback(.success, trigger: copiedTick)
        } footer: {
            Text("Plain text for bug reports. The Pi address and token are never included.")
        }
        .id("Diagnostics")
    }

    // MARK: credits and links

    private var creditsSection: some View {
        Section {
            credit("Inter", "SIL Open Font License 1.1 · LICENSES/Inter-OFL.txt", "textformat")
            credit("JetBrains Mono", "SIL Open Font License 1.1 · LICENSES/JetBrainsMono-OFL.txt", "chevron.left.forwardslash.chevron.right")
            credit("xtool", "Builds and signs this app without Xcode", "hammer")
            credit("Tailscale", "Private network between the phone and Polaris", "network")
        } header: { Text("Open source") }
            .id("Open source")
    }

    private func credit(_ name: String, _ detail: String, _ symbol: String) -> some View {
        LabeledContent {
            EmptyView()
        } label: {
            Label {
                VStack(alignment: .leading, spacing: DS.Space.hair) {
                    Text(name).font(Theme.font(15, weight: .medium, relativeTo: .subheadline))
                    Text(detail).font(Theme.font(12, relativeTo: .caption)).foregroundStyle(.secondary)
                }
            } icon: { Image(systemName: symbol) }
        }
    }

    private var linksSection: some View {
        Section {
            link("Source on GitHub", "https://github.com/devrangadi-h/devrobotics-ios", "chevron.left.forwardslash.chevron.right")
            link("devrobotics.dev", "https://devrobotics.dev", "globe")
            link("Polaris", "https://polaris.devrobotics.dev/polaris.html", "server.rack")
        } header: { Text("Links") }
            .id("Links")
    }

    private func link(_ title: String, _ url: String, _ symbol: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                Image(systemName: "arrow.up.right").font(.footnote).foregroundStyle(.tertiary)
            }
        }
    }
}

private extension String {
    /// "21 Oct 2026, 11:26 PM" -> "21 Oct 2026, 11:26 pm"
    var lowercasedMeridiem: String {
        replacingOccurrences(of: " AM", with: " am").replacingOccurrences(of: " PM", with: " pm")
    }
}
