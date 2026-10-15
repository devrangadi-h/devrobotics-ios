import Foundation
import WebKit

enum PreviewTarget: Hashable {
    case photo(String), story(String)

    /// Story -> /frames/<slug>.html ; photo -> /frames.html#<slug> (frames.js opens the lightbox from the hash).
    func url(base: URL) -> URL? {
        switch self {
        case .story(let s): return base.appending(path: "frames/\(s).html")
        case .photo(let s):
            let frag = s.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? s
            return URL(string: base.appending(path: "frames.html").absoluteString + "#" + frag)
        }
    }

    init?(change: FrameChange) {
        switch change.kind {
        case "photo": self = .photo(change.slug)
        case "story": self = .story(change.slug)
        default: return nil
        }
    }
}

/// Subresource requests from WKWebView carry no Authorization header, so the server reads this cookie.
enum PreviewCookie {
    static func make(host: String, token: String) -> HTTPCookie? {
        HTTPCookie(properties: [
            .name: "polaris_token", .value: token, .domain: host, .path: "/",
            .secure: "TRUE", .expires: Date().addingTimeInterval(3600),
        ])
    }

    @MainActor
    static func install(host: String, token: String) async {
        guard let c = make(host: host, token: token) else { return }
        await WKWebsiteDataStore.default().httpCookieStore.setCookie(c)
    }
}
