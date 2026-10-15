import Foundation

/// Fields from the embedded provisioning profile (`embedded.mobileprovision`, a CMS-signed plist). Foundation only.
struct ProvisioningProfile: Equatable {
    var expiration: Date?
    var creation: Date?
    var teamName: String?
    var teamID: String?
    var deviceCount: Int?

    /// Pulls the XML plist out of the CMS blob (`<?xml` ... `</plist>`) and parses it. Nil when absent/unreadable.
    static func parse(_ raw: Data) -> ProvisioningProfile? {
        guard let start = raw.range(of: Data("<?xml".utf8)),
              let end = raw.range(of: Data("</plist>".utf8), in: start.lowerBound..<raw.endIndex) else { return nil }
        let xml = raw.subdata(in: start.lowerBound..<end.upperBound)
        guard let obj = try? PropertyListSerialization.propertyList(from: xml, options: [], format: nil),
              let d = obj as? [String: Any] else { return nil }
        var p = ProvisioningProfile()
        p.expiration = d["ExpirationDate"] as? Date
        p.creation = d["CreationDate"] as? Date
        p.teamName = d["TeamName"] as? String
        p.teamID = (d["TeamIdentifier"] as? [String])?.first ?? (d["ApplicationIdentifierPrefix"] as? [String])?.first
        p.deviceCount = (d["ProvisionedDevices"] as? [Any])?.count
        return p.expiration == nil && p.teamName == nil ? nil : p
    }

    static func loadEmbedded(bundle: Bundle = .main) -> ProvisioningProfile? {
        guard let path = bundle.path(forResource: "embedded", ofType: "mobileprovision"),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return parse(data)
    }
}

enum ExpiryLevel: Equatable { case ok, soon, urgent, expired }

/// Countdown maths + formatting, kept pure so it can be unit-checked with `Tools/aboutcheck.swift`.
enum ExpiryMath {
    static let lifetime: TimeInterval = 7 * 86400

    static func level(remaining: TimeInterval) -> ExpiryLevel {
        if remaining <= 0 { return .expired }
        if remaining < 12 * 3600 { return .urgent }
        if remaining < 48 * 3600 { return .soon }
        return .ok
    }

    /// "6 days 4 h left", "5 h 12 min left", "9 min left", "Expired 2 days ago".
    static func remainingText(_ remaining: TimeInterval) -> String {
        if remaining <= 0 {
            let a = -remaining
            if a < 60 { return "Expired just now" }
            return "Expired \(span(a)) ago"
        }
        return "\(span(remaining)) left"
    }

    /// "Expires in 6 d" / "Expires in 5 h" / "Expired".
    static func chipText(_ remaining: TimeInterval) -> String {
        if remaining <= 0 { return "Expired" }
        if remaining >= 86400 { return "Expires in \(Int(remaining / 86400)) d" }
        if remaining >= 3600 { return "Expires in \(Int(remaining / 3600)) h" }
        return "Expires in \(max(1, Int(remaining / 60))) min"
    }

    private static func span(_ s: TimeInterval) -> String {
        let t = Int(s)
        let d = t / 86400, h = (t % 86400) / 3600, m = (t % 3600) / 60
        if d > 0 { return "\(d) day\(d == 1 ? "" : "s") \(h) h" }
        if h > 0 { return "\(h) h \(m) min" }
        return "\(max(m, 1)) min"
    }

    /// Fraction of the 7-day lifetime that remains (0...1).
    static func fraction(remaining: TimeInterval, total: TimeInterval = lifetime) -> Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, remaining / total))
    }

    /// One day before expiry, or nil when that moment has already passed.
    static func reminderDate(expiry: Date, now: Date) -> Date? {
        let d = expiry.addingTimeInterval(-86400)
        return d > now ? d : nil
    }
}
