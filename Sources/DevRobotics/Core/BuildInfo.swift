import Foundation

/// Build identity, stamped by `Tools/install.sh` into `Resources/BuildStamp.json` (gitignored).
/// Missing file (clean checkout / plain `xtool dev`) falls back to "dev" values.
struct BuildInfo: Equatable {
    var version = "1.0.0"
    var build = "dev"
    var commit = "dev"
    var builtAt: Date?
    var swift: String?
    var xcode: String?
    var sdk: String?

    /// "1.0.0 · build 42 · a1b2c3d"
    var id: String { "\(version) · build \(build) · \(commit)" }

    static let current: BuildInfo = DemoMode.isOn ? .demo : load()

    static let demo = BuildInfo(version: "1.0.0", build: "87", commit: "e4f9a2c",
                                builtAt: Date().addingTimeInterval(-3600), swift: "6.3", xcode: "27.0", sdk: "26.5")

    private struct Stamp: Decodable {
        var version, build, commit, builtAt, swift, xcode, sdk: String?
    }

    private static func load() -> BuildInfo {
        var b = BuildInfo()
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String { b.version = v }
        guard let url = Bundle.module.url(forResource: "BuildStamp", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(Stamp.self, from: data) else { return b }
        func nonEmpty(_ x: String?) -> String? { (x?.isEmpty == false) ? x : nil }
        b.version = nonEmpty(s.version) ?? b.version
        b.build = nonEmpty(s.build) ?? b.build
        b.commit = nonEmpty(s.commit) ?? b.commit
        b.builtAt = s.builtAt.flatMap { ISO8601DateFormatter().date(from: $0) }
        b.swift = nonEmpty(s.swift); b.xcode = nonEmpty(s.xcode); b.sdk = nonEmpty(s.sdk)
        return b
    }
}
