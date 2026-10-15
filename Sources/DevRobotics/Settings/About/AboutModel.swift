import Foundation
import Observation
import UIKit
import UserNotifications

/// Per-launch bookkeeping (launch count, first-install date). Called from `DemoMode.installIfNeeded()` at app start.
enum LaunchStats {
    private static var defaults: UserDefaults { .standard }
    static func record() {
        if defaults.object(forKey: "about.firstInstall") == nil { defaults.set(Date(), forKey: "about.firstInstall") }
        defaults.set(defaults.integer(forKey: "about.launchCount") + 1, forKey: "about.launchCount")
        let key = ExpiryInfo.firstLaunchKey
        if defaults.object(forKey: key) == nil { defaults.set(Date(), forKey: key) }
        Task { await ExpiryReminder.reschedule() }
    }
    static var firstInstall: Date? { defaults.object(forKey: "about.firstInstall") as? Date }
    static var launchCount: Int { defaults.integer(forKey: "about.launchCount") }
}

/// When this build's signing expires. From the embedded profile, else first launch + 7 days (estimated).
struct ExpiryInfo: Equatable {
    var expires: Date
    var created: Date?
    var estimated: Bool
    var profile: ProvisioningProfile?

    static var firstLaunchKey: String { "about.firstLaunch.\(BuildInfo.current.id).\(BuildInfo.current.builtAt?.timeIntervalSince1970 ?? 0)" }

    static func current() -> ExpiryInfo {
        if DemoMode.isOn { return AboutDemo.expiry }
        if let p = ProvisioningProfile.loadEmbedded(), let e = p.expiration {
            return ExpiryInfo(expires: e, created: p.creation, estimated: false, profile: p)
        }
        let d = UserDefaults.standard
        let first = (d.object(forKey: firstLaunchKey) as? Date) ?? { let n = Date(); d.set(n, forKey: firstLaunchKey); return n }()
        return ExpiryInfo(expires: first.addingTimeInterval(ExpiryMath.lifetime), created: first, estimated: true,
                          profile: ProvisioningProfile.loadEmbedded())
    }

    func remaining(at now: Date = .now) -> TimeInterval { expires.timeIntervalSince(now) }
    var total: TimeInterval {
        if let created, expires > created { return expires.timeIntervalSince(created) }
        return ExpiryMath.lifetime
    }
}

enum ExpiryReminder {
    static let id = "devrobotics.expiry"
    static let enabledKey = "about.remind"
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Asks for permission only when it has never been asked. Returns whether notifications are allowed.
    @discardableResult static func requestIfNeeded() async -> Bool {
        let c = UNUserNotificationCenter.current()
        let s = await c.notificationSettings().authorizationStatus
        if s == .notDetermined { return (try? await c.requestAuthorization(options: [.alert, .sound])) ?? false }
        return s == .authorized || s == .provisional
    }

    /// Replaces the single pending reminder (or removes it). Never prompts.
    static func reschedule() async {
        guard !DemoMode.isOn else { return }
        let c = UNUserNotificationCenter.current()
        c.removePendingNotificationRequests(withIdentifiers: [id])
        guard enabled else { return }
        let s = await c.notificationSettings().authorizationStatus
        guard s == .authorized || s == .provisional else { return }
        guard let when = ExpiryMath.reminderDate(expiry: ExpiryInfo.current().expires, now: .now) else { return }
        let content = UNMutableNotificationContent()
        content.title = "DevRobotics expires tomorrow"
        content.body = "DevRobotics expires tomorrow. Plug in and reinstall."
        content.sound = .default
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: when)
        let trig = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        try? await c.add(UNNotificationRequest(identifier: id, content: content, trigger: trig))
    }
}

/// Everything the About screen shows, gathered in one place so the same data feeds the UI and "Copy diagnostics".
@MainActor @Observable
final class AboutModel {
    struct Row: Identifiable, Equatable { var id: String { label }; var label: String; var value: String; var symbol: String }
    struct Group: Identifiable, Equatable { var id: String { title }; var title: String; var rows: [Row] }

    var now = Date()
    var expiry = ExpiryInfo.current()
    var latencies: [Int] = []
    var pinging = false
    var pingError: String?
    var pi: PiBits?
    var lampsOnline: String?
    var cache: PolarisCacheInfo?
    var draftBytes: Int64 = 0
    var thumbBytes: Int64 = 0
    var appBytes: Int64 = 0
    var freeBytes: Int64 = 0

    struct PiBits: Equatable {
        var hostname, kernel, serverVersion: String?
        var uptime: Double?, cpuTemp: Double?
    }
    private struct Wire: Decodable {
        var hostname, kernel, serverVersion: String?
        var uptimeSeconds, cpuTempC: Double?
    }
    private struct Lamps: Decodable { struct L: Decodable { var online: Bool? }; var lamps: [L]? }

    var averageLatency: Int? { latencies.isEmpty ? nil : latencies.reduce(0, +) / latencies.count }
    var remaining: TimeInterval { expiry.remaining(at: now) }
    var build: BuildInfo { BuildInfo.current }

    // MARK: loading

    func loadLocal() async {
        expiry = ExpiryInfo.current()
        if DemoMode.isOn {
            draftBytes = AboutDemo.draftBytes; thumbBytes = AboutDemo.thumbBytes
            appBytes = AboutDemo.appBytes; freeBytes = AboutDemo.freeBytes
            return
        }
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FrameDrafts")
        let thumbs = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("FrameThumbs")
        let app = Bundle.main.bundleURL
        let sizes = await Task.detached { (Self.dirSize(support), Self.dirSize(thumbs), Self.dirSize(app)) }.value
        draftBytes = sizes.0; thumbBytes = sizes.1; appBytes = sizes.2
        let v = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        freeBytes = v?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    nonisolated static func dirSize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e {
            let v = try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
        }
        return total
    }

    func loadRemote(_ settings: SettingsStore) async {
        guard settings.isConfigured else { return }
        await ping(settings)
        let api = API(settings: settings)
        if let l = try? await api.getJSON(.lights, "api/lights/state", as: Lamps.self), let lamps = l.lamps {
            lampsOnline = "\(lamps.filter { $0.online == true }.count) of \(lamps.count)"
        }
        cache = try? await api.getJSON(.app, "v1/cache", as: PolarisCacheInfo.self)
    }

    /// One timed `GET v1/status`. Keeps the last 3.
    func ping(_ settings: SettingsStore) async {
        guard settings.isConfigured, !pinging else { return }
        pinging = true
        pingError = nil
        defer { pinging = false }
        let t0 = ContinuousClock.now
        do {
            let d = try await API(settings: settings).request(.app, "v1/status")
            let dt = ContinuousClock.now - t0
            var ms = Int((Double(dt.components.seconds) * 1000 + Double(dt.components.attoseconds) / 1e15).rounded())
            if DemoMode.isOn { ms = AboutDemo.latencies[latencies.count % AboutDemo.latencies.count] }
            withAnimationIfNeeded { self.latencies = Array(([ms] + self.latencies).prefix(3)) }
            if let w = try? JSONDecoder().decode(Wire.self, from: d) {
                pi = PiBits(hostname: w.hostname, kernel: w.kernel, serverVersion: w.serverVersion,
                            uptime: w.uptimeSeconds, cpuTemp: w.cpuTempC)
            }
        } catch {
            pingError = error.localizedDescription
        }
    }

    private func withAnimationIfNeeded(_ f: () -> Void) { f() }

    // MARK: formatting

    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
    static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM yyyy, h:mm a"; return f
    }()
    static func uptime(_ s: Double) -> String {
        let t = Int(s); let d = t / 86400, h = (t % 86400) / 3600, m = (t % 3600) / 60
        return d > 0 ? "\(d) d \(h) h" : h > 0 ? "\(h) h \(m) min" : "\(m) min"
    }

    // MARK: groups

    var appGroup: Group {
        let b = build
        var rows: [Row] = [
            .init(label: "Bundle ID", value: Bundle.main.bundleIdentifier ?? "n/a", symbol: "shippingbox"),
            .init(label: "Version", value: b.version, symbol: "tag"),
            .init(label: "Build", value: b.build, symbol: "number"),
            .init(label: "Commit", value: b.commit, symbol: "arrow.triangle.branch"),
            .init(label: "Built", value: b.builtAt.map(Self.dateFmt.string) ?? "n/a (not stamped)", symbol: "hammer"),
            .init(label: "Toolchain", value: ["Swift \(b.swift ?? "n/a")", b.sdk.map { "iOS SDK \($0)" }].compactMap { $0 }.joined(separator: " · "), symbol: "swift"),
            .init(label: "Minimum iOS", value: (Bundle.main.infoDictionary?["MinimumOSVersion"] as? String) ?? "26.0", symbol: "iphone.gen3"),
            .init(label: "Signing team", value: Self.team(expiry.profile), symbol: "person.badge.key"),
            .init(label: "App size", value: Self.bytes(appBytes), symbol: "internaldrive"),
            .init(label: "First installed", value: (DemoMode.isOn ? AboutDemo.firstInstall : LaunchStats.firstInstall).map(Self.dateFmt.string) ?? "n/a", symbol: "calendar.badge.plus"),
            .init(label: "Launches", value: "\(DemoMode.isOn ? AboutDemo.launchCount : LaunchStats.launchCount)", symbol: "play.circle"),
        ]
        if let n = expiry.profile?.deviceCount { rows.insert(.init(label: "Provisioned devices", value: "\(n)", symbol: "iphone.and.arrow.right.outward"), at: 8) }
        return Group(title: "App", rows: rows)
    }

    private static func team(_ p: ProvisioningProfile?) -> String {
        guard let p else { return "n/a" }
        return [p.teamName, p.teamID.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
    }

    var deviceGroup: Group {
        if DemoMode.isOn { return AboutDemo.deviceGroup(free: Self.bytes(freeBytes)) }
        let d = UIDevice.current
        d.isBatteryMonitoringEnabled = true
        let state: String = switch d.batteryState {
        case .charging: "charging"; case .full: "full"; case .unplugged: "unplugged"; default: "unknown"
        }
        let level = d.batteryLevel >= 0 ? "\(Int(d.batteryLevel * 100))%" : "n/a"
        var sys = utsname(); uname(&sys)
        let model = withUnsafePointer(to: &sys.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 64) { String(cString: $0) } }
        let thermal: String = switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"; case .fair: "fair"; case .serious: "serious"; case .critical: "critical"; @unknown default: "unknown"
        }
        return Group(title: "Device", rows: [
            .init(label: "Model", value: model, symbol: "iphone"),
            .init(label: "iOS", value: d.systemVersion, symbol: "apple.logo"),
            .init(label: "Free storage", value: Self.bytes(freeBytes), symbol: "externaldrive"),
            .init(label: "Battery", value: "\(level) · \(state)", symbol: "battery.75percent"),
            .init(label: "Low Power Mode", value: ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off", symbol: "bolt.badge.clock"),
            .init(label: "Thermal state", value: thermal, symbol: "thermometer.medium"),
        ])
    }

    var piGroup: Group {
        let na = "n/a"
        let avg = averageLatency.map { "\($0) ms" } ?? na
        return Group(title: "Polaris link", rows: [
            .init(label: "Latency (avg of last \(latencies.count))", value: avg, symbol: "timer"),
            .init(label: "Recent", value: latencies.isEmpty ? na : latencies.map { "\($0) ms" }.joined(separator: ", "), symbol: "waveform.path"),
            .init(label: "Pi hostname", value: pi?.hostname ?? na, symbol: "server.rack"),
            .init(label: "Kernel", value: pi?.kernel ?? na, symbol: "terminal"),
            .init(label: "Uptime", value: pi?.uptime.map(Self.uptime) ?? na, symbol: "clock"),
            .init(label: "CPU temp", value: pi?.cpuTemp.map { String(format: "%.1f °C", $0) } ?? na, symbol: "thermometer.medium"),
            .init(label: "Server version", value: pi?.serverVersion ?? na, symbol: "number.square"),
            .init(label: "Lamps online", value: lampsOnline ?? na, symbol: "lightbulb"),
        ])
    }

    var storageGroup: Group {
        Group(title: "Storage", rows: [
            .init(label: "Unsent drafts (this phone)", value: Self.bytes(draftBytes), symbol: "doc.text"),
            .init(label: "Thumbnail cache (this phone)", value: Self.bytes(thumbBytes), symbol: "photo.on.rectangle"),
            .init(label: "Polaris cache", value: cache.map { "\(Self.bytes($0.usedBytes)) of \(Self.bytes($0.capBytes))" } ?? "n/a", symbol: "externaldrive.connected.to.line.below"),
        ])
    }

    /// Plain text for the clipboard. Contains no host or token.
    func diagnostics() -> String {
        var out = ["DevRobotics diagnostics", "Generated \(Self.dateFmt.string(from: .now))", ""]
        let e = expiry
        out += ["[Signing]",
                "Expires: \(Self.dateFmt.string(from: e.expires))\(e.estimated ? " (estimated)" : "")",
                "Remaining: \(ExpiryMath.remainingText(remaining))", ""]
        for g in [appGroup, deviceGroup, piGroup, storageGroup] {
            out.append("[\(g.title)]")
            out += g.rows.map { "\($0.label): \($0.value)" }
            out.append("")
        }
        out.append("Pi address and token: redacted")
        return out.joined(separator: "\n")
    }
}
