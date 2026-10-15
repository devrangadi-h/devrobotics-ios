import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Shared banner: message + button that opens the Tailscale app (falls back to the web login).
struct ConnectionBanner: View {
    var text: String = "Not connected to Polaris. Connect Tailscale to use live features."
    var buttonTitle: String = "Connect Tailscale"

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "bolt.horizontal.circle").foregroundStyle(Theme.warn)
            Text(text).font(Theme.font(13, relativeTo: .footnote)).foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(buttonTitle) { Self.openTailscale() }
                .font(Theme.font(13, weight: .semibold, relativeTo: .footnote))
                .buttonStyle(.bordered)
        }
        .padding(12)
        .background(Theme.warn.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    static func openTailscale() {
        #if canImport(UIKit)
        guard let app = URL(string: "tailscale://"), let web = URL(string: "https://login.tailscale.com") else { return }
        UIApplication.shared.open(app) { ok in
            if !ok { UIApplication.shared.open(web) }
        }
        #endif
    }
}
