import Foundation

enum APIError: LocalizedError {
    case notConfigured, http(Int, String), badResponse
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Set the Pi address and token in Settings."
        case .http(let c, let m): return "Polaris returned \(c)\(m.isEmpty ? "" : ": \(m)")"
        case .badResponse: return "Unexpected response from Polaris."
        }
    }
}

/// Thin authenticated client. Which server: .app = polaris-app-api (:8443), .lights = existing lights API (:443).
struct API {
    enum Server { case app, lights }
    let settings: SettingsStore

    func url(_ server: Server, _ path: String) throws -> URL {
        guard settings.isConfigured, let base = (server == .app ? settings.appBase : settings.lightsBase) else { throw APIError.notConfigured }
        return base.appending(path: path)
    }

    func request(_ server: Server, _ path: String, method: String = "GET", body: Data? = nil,
                 contentType: String? = nil, timeout: TimeInterval = 20) async throws -> Data {
        var req = URLRequest(url: try url(server, path), timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        req.httpBody = body
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        return data
    }

    func getJSON<T: Decodable>(_ server: Server, _ path: String, as: T.Type = T.self) async throws -> T {
        let d = try await request(server, path)
        return try JSONDecoder().decode(T.self, from: d)
    }

    func postJSON(_ server: Server, _ path: String, _ body: [String: Any]) async throws -> Data {
        try await request(server, path, method: "POST", body: try JSONSerialization.data(withJSONObject: body),
                          contentType: "application/json")
    }
}
