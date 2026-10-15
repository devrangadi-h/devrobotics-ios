import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Shared banner: message + button that opens the Tailscale app (falls back to the web login).
struct ConnectionBanner: View {
    var text: String = "Not connected to Polaris. Connect Tailscale to use live features."
    var buttonTitle: String = "Connect Tailscale"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.system(size: 26))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.warn)
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text(text)
                    .font(Theme.font(13, relativeTo: .footnote))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Button { Self.openTailscale() } label: {
                    Label(buttonTitle, systemImage: "arrow.up.forward.app")
                        .font(Theme.font(13, weight: .semibold, relativeTo: .footnote))
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(DS.Space.m)
        .glassEffect(.regular.tint(Theme.warn.opacity(0.28)), in: .rect(cornerRadius: DS.Radius.control))
        .accessibilityElement(children: .contain)
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
