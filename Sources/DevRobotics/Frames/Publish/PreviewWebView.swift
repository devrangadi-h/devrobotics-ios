import SwiftUI
import WebKit

@MainActor
final class WebController: NSObject, ObservableObject {
    @Published var canGoBack = false
    @Published var isLoading = false
    let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    private var obs: [NSKeyValueObservation] = []

    override init() {
        super.init()
        obs.append(webView.observe(\.canGoBack) { [weak self] w, _ in
            let v = w.canGoBack; Task { @MainActor in self?.canGoBack = v }
        })
        obs.append(webView.observe(\.isLoading) { [weak self] w, _ in
            let v = w.isLoading; Task { @MainActor in self?.isLoading = v }
        })
    }
}

struct WebViewHost: UIViewRepresentable {
    let controller: WebController
    func makeUIView(context: Context) -> WKWebView { controller.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// In-app preview of one entry: sets the auth cookie, then loads the page.
struct PreviewPage: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss
    let target: PreviewTarget
    @StateObject private var web = WebController()

    var body: some View {
        NavigationStack {
            WebViewHost(controller: web)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Preview")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        Button { web.webView.goBack() } label: { Image(systemName: "chevron.backward") }
                            .disabled(!web.canGoBack)
                    }
                }
                .overlay { if web.isLoading { ProgressView() } }
        }
        .task {
            guard let base = settings.appBase, let url = target.url(base: base) else { return }
            await PreviewCookie.install(host: settings.host, token: settings.token)
            web.webView.load(URLRequest(url: url))
        }
    }
}
