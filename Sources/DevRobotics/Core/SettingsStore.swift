import Foundation
import Observation
import Security

/// Pi address + token. Address in UserDefaults, token in the Keychain. Never hard-code either.
@Observable
final class SettingsStore {
    var host: String { didSet { UserDefaults.standard.set(host, forKey: "host") } }
    var token: String { didSet { Keychain.set(token, for: "token") } }

    init() {
        host = UserDefaults.standard.string(forKey: "host") ?? ""
        token = Keychain.get("token") ?? ""
    }

    var isConfigured: Bool { !host.isEmpty && !token.isEmpty }
    /// Existing lights API (Tailscale Serve, port 443).
    var lightsBase: URL? { URL(string: "https://\(host)") }
    /// polaris-app-api (Tailscale Serve, port 8443).
    var appBase: URL? { URL(string: "https://\(host):8443") }
}

enum Keychain {
    static func set(_ value: String, for key: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        guard !value.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}
