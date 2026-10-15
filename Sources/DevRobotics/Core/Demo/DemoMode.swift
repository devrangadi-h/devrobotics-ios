import Foundation
import UIKit

/// Launch-argument demo mode for screenshots/design review only. `-demo` swaps the Pi for canned, obviously fake data
/// (no real host, token or photos). `-screen <name>` picks the screen to show. Never active in normal use.
///
/// Screens: status, lights, frames, settings, story (open the sample story editor), photo (open a sample photo editor),
/// publish (open the publish sheet).
enum DemoMode {
    static let host = "demo.invalid"
    static let isOn: Bool = ProcessInfo.processInfo.arguments.contains("-demo")

    static let screen: String? = {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-screen"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }()

    /// Call once at launch (before any request).
    static func installIfNeeded() {
        guard isOn else { return }
        URLProtocol.registerClass(DemoURLProtocol.self)
    }
}

/// Answers every request to `DemoMode.host` with fixtures. Registered globally, so URLSession.shared uses it.
final class DemoURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == DemoMode.host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let (status, type, data) = Self.respond(path: url.path, method: request.httpMethod ?? "GET", body: Self.bodyData(request))
        let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func json(_ obj: Any, status: Int = 200) -> (Int, String, Data) {
        (status, "application/json", (try? JSONSerialization.data(withJSONObject: obj)) ?? Data())
    }

    static func respond(path: String, method: String, body: Data? = nil) -> (Int, String, Data) {
        let parts = path.split(separator: "/").map(String.init)
        switch path {
        case "/v1/fan": return fan(method: method, body: body)
        case "/v1/status": return json(status())
        case "/v1/cache", "/v1/cache/clear":
            return json(["usedBytes": 61_000_000, "capBytes": 2_147_483_648, "draftCount": 0,
                         "parts": ["drafts": 0, "blobs": 0, "thumbs": 700_000, "previewSite": 60_300_000]])
        case "/v1/frames/entries": return json(["entries": entries])
        case "/v1/frames/preview", "/v1/frames/publish": return json(job(), status: 202)
        case "/v1/frames/draft-preview": return json(problemsJob(), status: 202)
        case "/api/lights/ping": return json(["ok": true])
        case "/api/lights/state":
            return json(["ok": true, "updatedAt": Int(Date().timeIntervalSince1970),
                         "timer": ["action": "off", "endsAt": Int(Date().timeIntervalSince1970) + 1500],
                         "lamps": [
                            ["index": 0, "name": "Floor lamp left", "online": true, "on": true, "brightness": 72,
                             "colorTempK": 3000, "color": NSNull()],
                            ["index": 1, "name": "Floor lamp right", "online": true, "on": true, "brightness": 72,
                             "colorTempK": NSNull(), "color": ["r": 120, "g": 80, "b": 255]]]])
        default: break
        }
        if path.hasPrefix("/api/lights/") { return json(["ok": true, "responses": []]) }
        if parts.count == 4, parts[0] == "v1", parts[1] == "frames", var e = entries.first(where: { ($0["slug"] as? String) == parts[3] }) {
            if parts[3] == "pumpkintime" { e["body"] = sampleBody }
            else if parts[3] == "problemstory" {
                e["body"] = "A story used to test the problems UI.\n\n<insert image IMG_0101.HEIC \"A photo that is used\">\n\n<insert image MISSING_0042.HEIC \"A photo that is not in the story\">\n\nThe last paragraph."
            }
            else { e["body"] = (e["fields"] as? [String: String])?["note"] ?? "A quiet moment worth keeping." }
            return json(e)
        }
        if parts.count == 3, parts[1] == "jobs" { return json(parts[2] == "demo-problems" ? problemsJob() : job()) }
        if parts.count == 6, parts[4] == "thumb" { return (200, "image/jpeg", thumb(seed: parts[3] + parts[5])) }
        if method == "DELETE" || method == "PUT" { return json(["ok": true, "valid": true, "problems": []]) }
        return json(["error": "demo: not found"], status: 404)
    }

    // MARK: fixtures (fake)

    /// Fan fixture. `-fan max|manual` (launch argument) picks the starting mode; POST /v1/fan changes it.
    nonisolated(unsafe) private static var fanMode: String = {
        let a = ProcessInfo.processInfo.arguments
        if let i = a.firstIndex(of: "-fan"), i + 1 < a.count { return a[i + 1] }
        return "auto"
    }()
    nonisolated(unsafe) private static var fanPercent = 40
    nonisolated(unsafe) private static var fanEnds = Date().addingTimeInterval(14 * 60 + 32)

    private static func bodyData(_ r: URLRequest) -> Data? {
        if let b = r.httpBody { return b }
        guard let s = r.httpBodyStream else { return nil }
        s.open(); defer { s.close() }
        var out = Data(); var buf = [UInt8](repeating: 0, count: 1024)
        while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; out.append(buf, count: n) }
        return out
    }

    private static func fan(method: String, body: Data?) -> (Int, String, Data) {
        if method == "POST", let b = body, let o = try? JSONSerialization.jsonObject(with: b) as? [String: Any],
           let mode = o["mode"] as? String {
            fanMode = mode
            if mode == "manual" { fanPercent = (o["percent"] as? Int) ?? 40; fanEnds = Date().addingTimeInterval(30 * 60) }
            if mode == "max" { fanEnds = Date().addingTimeInterval(15 * 60) }
        }
        let t = Date().timeIntervalSince1970
        let pct = fanMode == "max" ? 100 : (fanMode == "manual" ? fanPercent : 0)
        let wobble = Int(t) % 7 * 9
        return json(["available": true, "mode": fanMode, "percent": pct,
                     "rpm": fanMode == "auto" ? 0 : pct * 72 + wobble,
                     "tempC": 48.6 + Double(Int(t) % 5) * 0.2,
                     "revertsAt": fanMode == "auto" ? NSNull() : Int(fanEnds.timeIntervalSince1970) as Any,
                     "minPercent": NSNull()])
    }

    /// A finished draft-preview job that failed with typical pipeline issues (used by `-screen storyproblems`).
    private static func problemsJob() -> [String: Any] {
        ["id": "demo-problems", "kind": "draft-preview", "state": "failed", "started": Int(Date().timeIntervalSince1970) - 5,
         "finished": Int(Date().timeIntervalSince1970), "log": ["ERROR: inbox has errors; fix them first"],
         "result": ["error": "inbox has errors; fix them first", "bodyStartLine": 7,
                    "issues": [
                        ["level": "error", "line": 3, "file": "story.md", "kind": "no-date", "name": "IMG_0100.HEIC",
                         "message": "the cover IMG_0100.HEIC has no date taken; add \"date: YYYY-MM-DD\" to the header"],
                        ["level": "error", "line": 11, "file": "story.md", "kind": "missing-file", "name": "MISSING_0042.HEIC",
                         "message": "MISSING_0042.HEIC is not in this story folder"],
                        ["level": "warning", "line": NSNull(), "file": "IMG_9999.HEIC", "kind": "other", "name": "IMG_9999.HEIC",
                         "message": "not used by any insert marker or cover (it will not be published)"]]]]
    }

    /// An already-finished job (preview/publish/draft-preview) with a plausible change list.
    private static func job() -> [String: Any] {
        ["id": "demo-job", "kind": "preview", "state": "done", "started": Int(Date().timeIntervalSince1970) - 6,
         "finished": Int(Date().timeIntervalSince1970),
         "log": ["$ frames.py build", "built 4 photo(s), 1 story(ies): 2 processed, 9 unchanged"],
         "result": ["changes": [["change": "changed", "kind": "story", "slug": "pumpkintime"],
                                ["change": "new", "kind": "photo", "slug": "mountainfog"],
                                ["change": "removed", "kind": "photo", "slug": "oldtest"]],
                    "builtAt": Int(Date().timeIntervalSince1970), "pushed": true,
                    "url": "/frames/pumpkintime.html", "bodyStartLine": 9, "issues": []]]
    }

    private static func status() -> [String: Any] {
        let now = Date()
        let iso = ISO8601DateFormatter()
        let history: [[String: Any]] = (0..<96).map { i in
            let t = now.addingTimeInterval(Double(i - 95) * 900)
            let wave = sin(Double(i) / 9)
            return ["t": iso.string(from: t), "cpuTempC": 47.0 + wave * 3 + Double(i % 5) * 0.2, "load1": max(0.02, 0.15 + wave * 0.12)]
        }
        return [
            "piOnline": true, "hostname": "polaris", "lastUpdated": iso.string(from: now),
            "cpuTempC": 48.6, "load1": 0.19, "load5": 0.11, "load15": 0.07, "cpuPercent": 4.8,
            "memory": ["usedBytes": 4_300_000_000, "totalBytes": 16_600_000_000],
            "disk": ["usedBytes": 16_900_000_000, "totalBytes": 123_000_000_000],
            "uptimeSeconds": 9 * 86400 + 5 * 3600 + 1260,
            "history": history,
            "services": [["name": "lights-api", "state": "active"], ["name": "polaris-app-api", "state": "active"],
                         ["name": "flower-tracker", "state": "inactive"], ["name": "local-chat-ui", "state": "active"]],
            "lastPublish": iso.string(from: now.addingTimeInterval(-86400 * 2)),
            "lastLog": ["date": "2026-10-14", "time": "19:41", "summary": "Published Frames from iPhone: changed story pumpkintime",
                        "details": "Published from the DevRobotics iPhone app.", "files": ["frames.json"]],
            "busy": false,
        ]
    }

    private static var entries: [[String: Any]] { [
        entry("story", "problemstory", ["title": "Sample with problems", "place": "Seattle, Washington", "cover": "IMG_0100.HEIC", "gps": "hide"],
              ["IMG_0100.HEIC", "IMG_0101.HEIC", "IMG_9999.HEIC"]),
        entry("photo", "rainersky", ["place": "In flight, Mt. Rainier", "gps": "show", "alt": "Sky at dusk", "note": "When I see this beautiful mountain, I know I'm home"], ["IMG_7311.HEIC"]),
        entry("photo", "jaipurfort", ["place": "Amer Fort, Jaipur, India", "gps": "show", "alt": "Fort walls at golden hour"], ["IMG_6278.HEIC"]),
        entry("photo", "coloradostars", ["place": "Rocky Mountain National Park, Colorado", "gps": "hide", "alt": "Milky Way over a ridge"], ["IMG_0108.HEIC"]),
        entry("photo", "cremewaffle", ["place": "Carmel-by-the-Sea, California", "gps": "show", "alt": "A waffle with cream"], ["IMG_0170.HEIC"]),
        entry("story", "pumpkintime", ["title": "Pumpkin Season 2026, Student Days", "place": "Monterey, California", "cover": "IMG_0132.HEIC",
                                        "gps": "show", "summary": "Pumpkins outside Trader Joe's, and a trip back to my student days in Boston",
                                        "alt": "bunch of pumpkins"], ["IMG_0132.HEIC", "IMG_0133.HEIC", "IMG_0134.HEIC", "IMG_3919.HEIC"]),
    ] }

    private static func entry(_ kind: String, _ slug: String, _ fields: [String: String], _ files: [String]) -> [String: Any] {
        ["kind": kind, "slug": slug, "fields": fields, "published": true,
         "modified": Int(Date().timeIntervalSince1970) - 3600,
         "files": files.map { ["name": $0, "type": "image", "size": 3_400_000] }]
    }

    private static var sampleBody: String { """
    Seeing the pumpkins outside Trader Joe's took me straight back to my student days. When I was doing my master's, I used to go there regularly to stock up on groceries.

    <insert image IMG_3919.HEIC "From the Boston store on Boylston Street" place="Boston, Massachusetts">

    During pumpkin season they sold all kinds of pumpkin-flavoured snacks, and there used to be **huge lines** outside.

    <insert images IMG_0133.HEIC "The classic orange ones" alt="Close-up pile of orange pumpkins" IMG_0134.HEIC "Pumpkins of all shapes and sizes">

    ## Student meals

    I used to get pasta and pasta sauce there:

    - pepper jack cheese
    - jalapeños
    - multigrain bread

    > Life was tighter back then, but it was also simpler.

    There isn't a Trader Joe's near my house in Seattle, so I was happy to find this one in Monterey.
    """ }

    /// A soft gradient JPEG, different per seed, standing in for a photo thumbnail.
    private static func thumb(seed: String) -> Data {
        var h = 0
        for u in seed.unicodeScalars { h = (h &* 31 &+ Int(u.value)) & 0xffff }
        let hue = CGFloat(h % 360) / 360
        let size = CGSize(width: 600, height: 450)
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [UIColor(hue: hue, saturation: 0.55, brightness: 0.95, alpha: 1).cgColor,
                          UIColor(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.55, alpha: 1).cgColor]
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
            ctx.cgContext.drawLinearGradient(g, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        }
        return img.jpegData(compressionQuality: 0.8) ?? Data()
    }
}
