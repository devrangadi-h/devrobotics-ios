import SwiftUI
import AVFoundation
import ImageIO

/// Authenticated thumbnail loader with memory + disk cache, and local-file thumbnails.
actor ThumbLoader {
    static let shared = ThumbLoader()
    private let mem = NSCache<NSString, UIImage>()
    private let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("FrameThumbs")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    func remote(key: String, request: URLRequest) async -> UIImage? {
        let k = key as NSString
        if let i = mem.object(forKey: k) { return i }
        let safe = key.map { $0.isLetter || $0.isNumber ? $0 : "_" }
        let file = dir.appendingPathComponent(String(safe) + ".jpg")
        if let d = try? Data(contentsOf: file), let i = UIImage(data: d) { mem.setObject(i, forKey: k); return i }
        guard let (data, resp) = try? await URLSession.shared.data(for: request),
              (resp as? HTTPURLResponse)?.statusCode == 200, let i = UIImage(data: data) else { return nil }
        try? data.write(to: file)
        mem.setObject(i, forKey: k)
        return i
    }

    func local(url: URL, maxPixel: Int = 900) async -> UIImage? {
        let key = "\(url.path)|\(maxPixel)" as NSString
        if let i = mem.object(forKey: key) { return i }
        var image: UIImage?
        if FrameFormat.isClip(url.lastPathComponent) {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)
            if let r = try? await gen.image(at: .zero) { image = UIImage(cgImage: r.image) }
        } else if let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                         kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceThumbnailMaxPixelSize: maxPixel]
            if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) { image = UIImage(cgImage: cg) }
        }
        if let image { mem.setObject(image, forKey: key) }
        return image
    }
}

enum ThumbSource: Hashable {
    case remote(kind: FrameKind, slug: String, name: String, version: Int)
    case local(URL)
}

struct FrameThumb: View {
    let source: ThumbSource?
    var fill = true
    @Environment(SettingsStore.self) private var settings
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: fill ? .fill : .fit)
            } else if source != nil {
                ProgressView()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .clipped()
        .task(id: source) { await load() }
    }

    private func load() async {
        guard let source else { image = nil; return }
        image = await ThumbLoading.image(source, settings: settings)
    }
}

enum ThumbLoading {
    @MainActor
    static func image(_ source: ThumbSource, settings: SettingsStore, width: Int = 600) async -> UIImage? {
        switch source {
        case .local(let url):
            return await ThumbLoader.shared.local(url: url, maxPixel: width * 3 / 2)
        case .remote(let kind, let slug, let name, let version):
            guard let req = FramesAuth.thumbRequest(settings, kind: kind, slug: slug, name: name, width: width) else { return nil }
            return await ThumbLoader.shared.remote(key: "\(kind.rawValue)|\(slug)|\(name)|\(version)|\(width)", request: req)
        }
    }
}

/// Request builders on top of Core/API (which stays unchanged).
enum FramesAuth {
    static func url(_ settings: SettingsStore, _ path: String) -> URL? {
        try? API(settings: settings).url(.app, path)
    }

    static func authed(_ settings: SettingsStore, _ path: String) -> URLRequest? {
        guard let u = url(settings, path) else { return nil }
        var r = URLRequest(url: u)
        r.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
        return r
    }

    /// Authenticated request; request building happens on the main actor (SettingsStore isn't Sendable).
    @MainActor
    static func data(_ settings: SettingsStore, _ path: String, method: String = "GET") async throws -> Data {
        guard var req = authed(settings, path) else { throw APIError.notConfigured }
        req.httpMethod = method
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        return data
    }

    static func thumbRequest(_ settings: SettingsStore, kind: FrameKind, slug: String, name: String, width: Int) -> URLRequest? {
        guard var r = authed(settings, "v1/frames/\(kind.rawValue)/\(slug)/thumb/\(name)"),
              var c = URLComponents(url: r.url!, resolvingAgainstBaseURL: false) else { return nil }
        c.queryItems = [URLQueryItem(name: "w", value: String(width))]
        r.url = c.url
        return r
    }
}
