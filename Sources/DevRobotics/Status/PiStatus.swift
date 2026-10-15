import Foundation

/// Response of GET /v1/status on polaris-app-api. Everything optional so a partial payload still renders.
struct PiStatus: Decodable {
    struct Usage: Decodable { var usedBytes: Double?; var totalBytes: Double? }
    struct Point: Decodable { var t: String?; var cpuTempC: Double?; var load1: Double? }
    struct Service: Decodable { var name: String; var state: String }
    struct LogEntry: Decodable {
        var date: String?; var time: String?; var summary: String?; var details: String?; var files: [String]?
    }

    var piOnline: Bool?
    var hostname: String?
    var lastUpdated: String?
    var cpuTempC: Double?
    var load1: Double?
    var load5: Double?
    var load15: Double?
    var cpuPercent: Double?
    var memory: Usage?
    var disk: Usage?
    var uptimeSeconds: Double?
    var history: [Point]?
    var services: [Service]?
    var lastPublish: String?
    var lastLog: LogEntry?
    var busy: Bool?

    var updatedDate: Date? { lastUpdated.flatMap(PiStatus.parseDate) }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withFullDate]
        return f.date(from: s)
    }
}

/// https://devrobotics.dev/polaris-pi-status.json (public, cached by the Pi every ~15 min).
struct PublicPiStatus: Decodable {
    var piOnline: Bool?
    var hostname: String?
    var lastUpdated: String?
    var cpuTempC: Double?
    var load1: Double?
    var load5: Double?
    var load15: Double?
    var cpuPercent: Double?
    var diskRoot: String?   // "16G/115G (15%)"
    var memory: String?     // "4.0Gi/15Gi"
    var history: [PiStatus.Point]?

    static let url = URL(string: "https://devrobotics.dev/polaris-pi-status.json")!

    func asPiStatus() -> PiStatus {
        PiStatus(piOnline: piOnline, hostname: hostname, lastUpdated: lastUpdated, cpuTempC: cpuTempC,
                 load1: load1, load5: load5, load15: load15, cpuPercent: cpuPercent,
                 memory: Self.parseUsage(memory), disk: Self.parseUsage(diskRoot),
                 uptimeSeconds: nil, history: history, services: nil, lastPublish: nil, lastLog: nil, busy: nil)
    }

    /// Parses "4.0Gi/15Gi" or "16G/115G (15%)" into bytes.
    static func parseUsage(_ s: String?) -> PiStatus.Usage? {
        guard let s else { return nil }
        let main = s.split(separator: " ").first.map(String.init) ?? s
        let parts = main.split(separator: "/").map(String.init)
        guard parts.count == 2, let u = bytes(parts[0]), let t = bytes(parts[1]) else { return nil }
        return PiStatus.Usage(usedBytes: u, totalBytes: t)
    }

    private static func bytes(_ s: String) -> Double? {
        let units: [(String, Double)] = [("Ti", 1_099_511_627_776), ("Gi", 1_073_741_824), ("Mi", 1_048_576), ("Ki", 1024),
                                         ("T", 1e12), ("G", 1e9), ("M", 1e6), ("K", 1e3), ("B", 1)]
        for (suffix, mult) in units where s.hasSuffix(suffix) {
            if let v = Double(s.dropLast(suffix.count)) { return v * mult }
        }
        return Double(s)
    }
}
