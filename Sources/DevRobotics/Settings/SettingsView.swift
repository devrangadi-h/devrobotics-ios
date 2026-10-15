import SwiftUI

/// `GET v1/cache` / `POST v1/cache/clear` payload.
struct PolarisCacheInfo: Decodable, Equatable {
    struct Parts: Decodable, Equatable {
        var drafts: Int64 = 0, blobs: Int64 = 0, thumbs: Int64 = 0, previewSite: Int64 = 0
        init() {}
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: Keys.self)
            drafts = (try? c.decode(Int64.self, forKey: .drafts)) ?? 0
            blobs = (try? c.decode(Int64.self, forKey: .blobs)) ?? 0
            thumbs = (try? c.decode(Int64.self, forKey: .thumbs)) ?? 0
            previewSite = (try? c.decode(Int64.self, forKey: .previewSite)) ?? 0
        }
        private enum Keys: String, CodingKey { case drafts, blobs, thumbs, previewSite }
    }
    var usedBytes: Int64
    var capBytes: Int64
    var draftCount: Int = 0
    var parts: Parts = .init()

    private enum CodingKeys: String, CodingKey { case usedBytes, capBytes, draftCount, parts }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        usedBytes = try c.decode(Int64.self, forKey: .usedBytes)
        capBytes = try c.decode(Int64.self, forKey: .capBytes)
        draftCount = (try? c.decode(Int.self, forKey: .draftCount)) ?? 0
        parts = (try? c.decode(Parts.self, forKey: .parts)) ?? .init()
    }
    init(usedBytes: Int64, capBytes: Int64) { self.usedBytes = usedBytes; self.capBytes = capBytes }
    var fraction: Double { capBytes > 0 ? min(1, Double(usedBytes) / Double(capBytes)) : 0 }
}

struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @State private var testing = false
    @State private var result: (ok: Bool, text: String)?
    @State private var resultTick = 0
    @State private var cache: PolarisCacheInfo?
    @State private var cacheError: String?
    @State private var clearing = false
    @State private var confirmClear = false
    @State private var clearedTick = 0

    var body: some View {
        @Bindable var s = settings
        NavigationStack {
            Form {
                Section { SettingsHeaderCard(connected: result?.ok == true) }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())

                Section {
                    LabeledContent {
                        TextField("name.tailnet.ts.net", text: $s.host)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            .multilineTextAlignment(.trailing)
                    } label: { Label("Address", systemImage: "network") }
                    LabeledContent {
                        SecureField("Required", text: $s.token).multilineTextAlignment(.trailing)
                    } label: { Label("Token", systemImage: "key.fill") }
                } header: {
                    Text("Polaris")
                } footer: {
                    Text("Your Pi's Tailscale hostname (no https://) and the app API token. The phone must be on your tailnet. The token is stored in the iOS Keychain.")
                }

                Section {
                    Button { Task { await test() } } label: {
                        HStack(spacing: DS.Space.m) {
                            ZStack {
                                if testing {
                                    ProgressView()
                                } else if let result {
                                    Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                        .foregroundStyle(result.ok ? Theme.ok : Color.red)
                                        .symbolEffect(.bounce, value: resultTick)
                                        .transition(.scale.combined(with: .opacity))
                                } else {
                                    Image(systemName: "bolt.horizontal").foregroundStyle(Theme.accent)
                                }
                            }
                            .frame(width: 24, height: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(testing ? "Testing…" : "Test connection")
                                    .font(Theme.font(16, weight: .medium))
                                if let result, !testing {
                                    Text(result.text)
                                        .font(Theme.font(13, relativeTo: .footnote))
                                        .foregroundStyle(result.ok ? Theme.ok : Color.red)
                                        .transition(.opacity)
                                }
                            }
                            Spacer()
                        }
                    }
                    .disabled(testing || !settings.isConfigured)
                    .sensoryFeedback(trigger: resultTick) { _, _ in result?.ok == true ? .success : .error }
                    if let result, !result.ok {
                        ConnectionBanner()
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }
                .dsAnimation(value: resultTick)

                cacheSection

                Section {
                    Picker(selection: $s.launchTab) {
                        Text("Status").tag("status")
                        Text("Lights").tag("lights")
                        Text("Frames").tag("frames")
                        Text("Settings").tag("settings")
                    } label: { Label("Tab", systemImage: "rectangle.on.rectangle") }
                    .pickerStyle(.menu)
                } header: {
                    Text("Open on launch")
                } footer: {
                    Text("The tab shown when the app starts.")
                }

                Section {
                    LabeledContent("Version", value: Self.versionString)
                } footer: {
                    Text("Drafts are stored on this phone until you send them.")
                }
            }
            .font(Theme.font(16))
            .dsPage()
            .navigationTitle("Settings")
            .task(id: settings.isConfigured) { await loadCache() }
            .refreshable { await loadCache() }
        }
    }

    // MARK: Cache

    @ViewBuilder private var cacheSection: some View {
        Section {
            if let cache {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(Self.bytes(cache.usedBytes))
                            .font(Theme.font(22, weight: .semibold, mono: true, relativeTo: .title2))
                            .contentTransition(.numericText())
                        Text("of \(Self.bytes(cache.capBytes))")
                            .font(Theme.font(14, relativeTo: .subheadline)).foregroundStyle(.secondary)
                        Spacer()
                        Text(cache.fraction.formatted(.percent.precision(.fractionLength(0))))
                            .font(Theme.font(13, weight: .medium, mono: true, relativeTo: .footnote))
                            .foregroundStyle(.secondary).contentTransition(.numericText())
                    }
                    ProgressView(value: cache.fraction)
                        .tint(cache.fraction > 0.85 ? Theme.warn : Theme.accent)
                }
                .padding(.vertical, DS.Space.xs)
                .dsAnimation(value: cache)
                partRow("Preview site", cache.parts.previewSite, "globe")
                partRow("Thumbnails", cache.parts.thumbs, "photo.on.rectangle")
                partRow("Uploaded media", cache.parts.blobs, "externaldrive")
                partRow("Drafts (\(cache.draftCount))", cache.parts.drafts, "doc.text")
                Button(role: .destructive) { confirmClear = true } label: {
                    HStack {
                        Label(clearing ? "Clearing…" : "Clear now", systemImage: "trash")
                        if clearing { Spacer(); ProgressView() }
                    }
                }
                .disabled(clearing)
                .sensoryFeedback(.success, trigger: clearedTick)
            } else if let cacheError {
                Label(cacheError, systemImage: "exclamationmark.triangle")
                    .font(Theme.font(14, relativeTo: .subheadline)).foregroundStyle(.secondary)
                Button("Try again") { Task { await loadCache() } }
            } else if settings.isConfigured {
                HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
            } else {
                Text("Connect to Polaris to see cache usage.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Polaris cache")
        } footer: {
            Text("Preview builds and thumbnails kept on the Pi. Clearing never touches published content; they are rebuilt on demand.")
        }
        .confirmationDialog("Clear the Polaris cache?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear cache", role: .destructive) { Task { await clear() } }
        } message: {
            Text("Cached previews and thumbnails are deleted and rebuilt the next time you need them.")
        }
    }

    private func partRow(_ title: String, _ bytes: Int64, _ icon: String) -> some View {
        LabeledContent {
            Text(Self.bytes(bytes)).font(Theme.font(14, mono: true, relativeTo: .subheadline))
        } label: {
            Label(title, systemImage: icon).font(Theme.font(15, relativeTo: .subheadline))
        }
    }

    private static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    private static var versionString: String {
        let i = Bundle.main.infoDictionary
        let v = i?["CFBundleShortVersionString"] as? String ?? "1.0"
        if let b = i?["CFBundleVersion"] as? String, b != v { return "\(v) (\(b))" }
        return v
    }

    private func loadCache() async {
        guard settings.isConfigured else { cache = nil; cacheError = nil; return }
        do {
            let c = try await API(settings: settings).getJSON(.app, "v1/cache", as: PolarisCacheInfo.self)
            cacheError = nil
            withAnimation(.dsSpring) { cache = c }
        } catch {
            if cache == nil { cacheError = "Couldn't load cache usage." }
        }
    }

    private func clear() async {
        clearing = true
        defer { clearing = false }
        do {
            if DemoMode.isOn, let c = cache {   // demo server has no clear route
                try? await Task.sleep(for: .milliseconds(600))
                withAnimation(.dsSpring) { cache = PolarisCacheInfo(usedBytes: 0, capBytes: c.capBytes) }
                clearedTick += 1
                return
            }
            let d = try await API(settings: settings).request(.app, "v1/cache/clear", method: "POST", timeout: 60)
            let c = try JSONDecoder().decode(PolarisCacheInfo.self, from: d)
            cacheError = nil
            withAnimation(.dsSpring) { cache = c }
            clearedTick += 1
        } catch APIError.http(409, _) {
            cacheError = "A build or publish is running on Polaris. Try again when it finishes."
            cache = nil
        } catch {
            cacheError = "Couldn't clear the cache. \(error.localizedDescription)"
            cache = nil
        }
    }

    // MARK: Test

    private func test() async {
        testing = true
        withAnimation(.dsSnappy) { result = nil }
        defer { testing = false }
        do {
            let st = try await API(settings: settings).getJSON(.app, "v1/status", as: PiStatus.self)
            withAnimation(.dsSpring) { result = (true, "Connected to \(st.hostname ?? "Polaris")") }
        } catch {
            withAnimation(.dsSpring) { result = (false, error.localizedDescription) }
        }
        resultTick += 1
    }
}

/// Hero card at the top of Settings: app mark, name, host, connection chip.
private struct SettingsHeaderCard: View {
    var connected: Bool
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        GlassCard {
            HStack(spacing: DS.Space.l) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Theme.accentContrast)
                    .frame(width: 56, height: 56)
                    .background(
                        LinearGradient(colors: [Theme.accent, Theme.accentStrong], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: .rect(cornerRadius: 14))
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("DevRobotics").font(Theme.font(20, weight: .semibold, relativeTo: .title3))
                    Text(settings.isConfigured ? settings.host : "Not configured")
                        .font(Theme.font(13, mono: true, relativeTo: .footnote))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if connected { GlassPill(text: "Online", systemImage: "checkmark", tint: Theme.ok.opacity(0.4)) }
            }
        }
        .padding(.vertical, DS.Space.xs)
    }
}
