import SwiftUI

struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @State private var testing = false
    @State private var result: (ok: Bool, text: String)?

    var body: some View {
        @Bindable var s = settings
        NavigationStack {
            Form {
                Section {
                    TextField("Pi address", text: $s.host, prompt: Text("name.tailnet.ts.net"))
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    SecureField("Token", text: $s.token)
                } header: {
                    Text("Polaris")
                } footer: {
                    Text("Your Pi's Tailscale hostname (no https://) and the app API token. The phone must be on your tailnet. The token is stored in the iOS Keychain.")
                }

                Section {
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Text("Test connection")
                            if testing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(testing || !settings.isConfigured)
                    if let result {
                        Label(result.text, systemImage: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(result.ok ? Theme.ok : Color.red)
                            .font(Theme.font(14, relativeTo: .subheadline))
                    }
                    if let result, !result.ok {
                        ConnectionBanner()
                    }
                }
            }
            .font(Theme.font(16))
            .navigationTitle("Settings")
        }
    }

    private func test() async {
        testing = true
        result = nil
        defer { testing = false }
        do {
            let st = try await API(settings: settings).getJSON(.app, "v1/status", as: PiStatus.self)
            result = (true, "Connected to \(st.hostname ?? "Polaris")")
        } catch {
            result = (false, error.localizedDescription)
        }
    }
}
