import Foundation

struct PutResult: Decodable, Sendable {
    var ok: Bool?
    var valid: Bool?
    var problems: [String]?
}

/// Body for one PUT: written to a temp file so large originals are never held in memory.
struct MultipartBody: Sendable {
    let fileURL: URL
    let boundary: String
}

enum FramesUploader {
    private final class Progress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let report: @Sendable (Double) -> Void
        init(_ r: @escaping @Sendable (Double) -> Void) { report = r }
        func urlSession(_ s: URLSession, task: URLSessionTask, didSendBodyData b: Int64, totalBytesSent sent: Int64,
                        totalBytesExpectedToSend total: Int64) {
            if total > 0 { report(Double(sent) / Double(total)) }
        }
    }

    /// Build the multipart/form-data file: field `meta` + repeated `files` parts.
    static func buildBody(meta: Data, files: [(name: String, url: URL)]) throws -> MultipartBody {
        let boundary = "polaris-\(UUID().uuidString)"
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString).multipart")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let h = try FileHandle(forWritingTo: out)
        defer { try? h.close() }
        func w(_ s: String) throws { try h.write(contentsOf: Data(s.utf8)) }
        try w("--\(boundary)\r\nContent-Disposition: form-data; name=\"meta\"\r\nContent-Type: application/json\r\n\r\n")
        try h.write(contentsOf: meta)
        try w("\r\n")
        for f in files {
            try w("--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"\(f.name)\"\r\n"
                  + "Content-Type: application/octet-stream\r\n\r\n")
            let r = try FileHandle(forReadingFrom: f.url)
            defer { try? r.close() }
            while let chunk = try r.read(upToCount: 1 << 20), !chunk.isEmpty { try h.write(contentsOf: chunk) }
            try w("\r\n")
        }
        try w("--\(boundary)--\r\n")
        return MultipartBody(fileURL: out, boundary: boundary)
    }

    /// PUT the body. `request` already carries URL + Authorization.
    static func put(_ request: URLRequest, body: MultipartBody, progress: @escaping @Sendable (Double) -> Void) async throws -> PutResult {
        var req = request
        req.httpMethod = "PUT"
        req.timeoutInterval = 900
        req.setValue("multipart/form-data; boundary=\(body.boundary)", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await URLSession.shared.upload(for: req, fromFile: body.fileURL, delegate: Progress(progress))
        guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            var msg = String(data: data.prefix(300), encoding: .utf8) ?? ""
            if let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let e = o["error"] as? String { msg = e }
            throw APIError.http(http.statusCode, msg)
        }
        return (try? JSONDecoder().decode(PutResult.self, from: data)) ?? PutResult(ok: true, valid: true, problems: [])
    }
}
