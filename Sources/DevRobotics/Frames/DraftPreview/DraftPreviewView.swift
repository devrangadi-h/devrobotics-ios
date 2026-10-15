import SwiftUI
import WebKit

/// Shows the real site page for the draft, with progress, staleness and error states.
struct DraftPreviewView: View {
    let controller: DraftPreviewController
    let draft: FrameDraft
    var localFileURL: (String) -> URL
    @Environment(SettingsStore.self) private var settings
    @StateObject private var web = WebController()
    @State private var loadedURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            ZStack {
                WebViewHost(controller: web)
                    .opacity(loadedURL == nil ? 0.15 : 1)
                content
            }
        }
        .task {
            await refresh(force: false)
            if case .ready(let url) = controller.phase, loadedURL == nil { await show(url) }
        }
        .onChange(of: controller.phase) { _, p in
            if case .ready(let url) = p { Task { await show(url) } }
        }
        .onDisappear { controller.cancel() }
    }

    @ViewBuilder private var content: some View {
        switch controller.phase {
        case .idle:
            ProgressView()
        case .uploading(let done, let total):
            progressCard(total == 0 ? "Preparing files..." : "Uploading \(done) of \(total)")
        case .building:
            progressCard("Building preview...")
        case .ready:
            EmptyView()
        case .failed(let msg):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").font(.title)
                Text(msg).multilineTextAlignment(.center)
                if controller.needsConnection { ConnectionBanner() }
                Button("Try again") { Task { await refresh(force: true) } }.buttonStyle(.borderedProminent)
            }
            .padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)).padding()
        }
    }

    private func progressCard(_ text: String) -> some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(text)
            Button("Cancel") { controller.cancel() }.buttonStyle(.bordered)
        }
        .padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if controller.isStale, loadedURL != nil {
                Label("Out of date", systemImage: "clock.arrow.circlepath").foregroundStyle(.orange)
            } else if let t = controller.lastBuiltAt {
                Text("Built \(t.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
            }
            Spacer()
            Button { Task { await refresh(force: true) } } label: {
                Label("Refresh preview", systemImage: "arrow.clockwise")
            }
            .disabled(controller.isWorking)
        }
        .font(.footnote)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func refresh(force: Bool) async {
        await controller.refreshIfNeeded(draft: draft, settings: settings, force: force, localFileURL: localFileURL)
    }

    private func show(_ url: URL) async {
        await PreviewCookie.install(host: settings.host, token: settings.token)
        if let id = controller.draftID, let c = HTTPCookie(properties: [
            .name: "polaris_preview", .value: id.uuidString.lowercased(), .domain: settings.host, .path: "/",
            .secure: "TRUE", .expires: Date().addingTimeInterval(3600),
        ]) {
            await WKWebsiteDataStore.default().httpCookieStore.setCookie(c)
        }
        loadedURL = url
        web.webView.load(URLRequest(url: url))
    }
}
