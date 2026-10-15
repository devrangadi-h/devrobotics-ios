import Foundation
import CryptoKit

/// Sendable snapshot of where/how to talk to the app server.
struct PreviewEndpoint: Sendable {
    let base: URL
    let token: String
    let host: String

    @MainActor
    init?(_ settings: SettingsStore) {
        guard settings.isConfigured, let b = settings.appBase else { return nil }
        base = b; token = settings.token; host = settings.host
    }

    func request(_ path: String, method: String = "GET", timeout: TimeInterval = 20) -> URLRequest {
        var r = URLRequest(url: base.appending(path: path), timeoutInterval: timeout)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return r
    }
}

/// Hash cache keyed by (path, size, mtime) so re-previews don't re-hash unchanged files.
final class FileHashCache: @unchecked Sendable {
    static let shared = FileHashCache()
    private let lock = NSLock()
    private var store: [String: String] = [:]

    func sha256(of url: URL) throws -> String {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(size)|\(mtime)"
        lock.lock(); let hit = store[key]; lock.unlock()
        if let hit { return hit }
        let h = try Self.streamHash(url)
        lock.lock(); store[key] = h; lock.unlock()
        return h
    }

    static func streamHash(_ url: URL) throws -> String {
        let f = try FileHandle(forReadingFrom: url)
        defer { try? f.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let chunk = try f.read(upToCount: 1 << 20)
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum DraftPreviewClientError: Error { case busy }

/// Network calls for draft preview. Stateless and nonisolated.
struct DraftPreviewClient: Sendable {
    let endpoint: PreviewEndpoint

    private func send(_ req: URLRequest, body: Data? = nil) async throws -> (Data, Int) {
        var req = req
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse }
        return (data, http.statusCode)
    }

    private static func message(_ data: Data) -> String {
        if let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let e = o["error"] as? String { return e }
        return String(data: data.prefix(200), encoding: .utf8) ?? ""
    }

    func missing(_ hashes: [String]) async throws -> Set<String> {
        let body = try JSONSerialization.data(withJSONObject: ["hashes": hashes])
        let (d, code) = try await send(endpoint.request("v1/blobs/missing", method: "POST"), body: body)
        guard (200..<300).contains(code) else { throw APIError.http(code, Self.message(d)) }
        struct R: Decodable { var missing: [String] }
        return Set(try JSONDecoder().decode(R.self, from: d).missing)
    }

    func upload(sha: String, name: String, file: URL) async throws {
        var req = endpoint.request("v1/blobs/\(sha)", method: "PUT", timeout: 900)
        req.setValue(name, forHTTPHeaderField: "X-File-Name")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (d, resp) = try await URLSession.shared.upload(for: req, fromFile: file)
        guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw APIError.http(http.statusCode, Self.message(d)) }
    }

    func startBuild(_ body: Data) async throws -> DraftPreviewJobSnapshot {
        let (d, code) = try await send(endpoint.request("v1/frames/draft-preview", method: "POST", timeout: 60), body: body)
        if code == 409 { throw DraftPreviewClientError.busy }
        guard (200..<300).contains(code) else { throw APIError.http(code, Self.message(d)) }
        return try JSONDecoder().decode(DraftPreviewJobSnapshot.self, from: d)
    }

    func snapshot(_ id: String) async throws -> DraftPreviewJobSnapshot {
        let (d, code) = try await send(endpoint.request("v1/jobs/\(id)"))
        guard (200..<300).contains(code) else { throw APIError.http(code, Self.message(d)) }
        return try JSONDecoder().decode(DraftPreviewJobSnapshot.self, from: d)
    }

    func delete(draftID: String) async {
        _ = try? await send(endpoint.request("v1/frames/draft-preview/\(draftID)", method: "DELETE"))
    }

    var poller: DraftPreviewJobPoller {
        let c = self
        return DraftPreviewJobPoller(fetch: { try await c.snapshot($0) })
    }
}
