import SwiftUI

struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings
    var body: some View {
        @Bindable var s = settings
        NavigationStack {
            Form {
                Section("Polaris") {
                    TextField("Pi address (e.g. name.tailnet.ts.net)", text: $s.host)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Token", text: $s.token)
                }
            }
            .navigationTitle("Settings")
        }
    }
}
