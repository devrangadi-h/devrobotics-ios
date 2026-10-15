import Foundation
import Observation
import Security

/// Pi address + token. Address in UserDefaults, token in the Keychain. Never hard-code either.
@Observable
final class SettingsStore {
    var host: String { didSet { UserDefaults.standard.set(host, forKey: "host") } }
    var token: String { didSet { Keychain.set(token, for: "token") } }

    /// The Mac that reinstalls this app (Tailscale IP, e.g. 100.64.0.7). Not secret; UserDefaults.
    var macHost: String { didSet { UserDefaults.standard.set(macHost, forKey: "macHost") } }

    /// Tab opened at launch: "status" | "lights" | "frames" | "settings". Default "lights".
    var launchTab: String { didSet { UserDefaults.standard.set(launchTab, forKey: "launchTab") } }

    static let launchTabs = ["status", "lights", "frames", "settings"]
    static var storedLaunchTab: RootView.AppTab {
        switch UserDefaults.standard.string(forKey: "launchTab") {
        case "status": return .status
        case "frames": return .frames
        case "settings": return .settings
        default: return .lights
        }
    }

    init() {
        launchTab = UserDefaults.standard.string(forKey: "launchTab").flatMap { Self.launchTabs.contains($0) ? $0 : nil } ?? "lights"
        if DemoMode.isOn {   // screenshots only: fake host/token, never persisted (didSet doesn't run in init)
            host = DemoMode.host
            token = "demo"
            macHost = DemoMode.host
            return
        }
        host = UserDefaults.standard.string(forKey: "host") ?? ""
        macHost = UserDefaults.standard.string(forKey: "macHost") ?? ""
        token = Keychain.get("token") ?? ""
    }

    var isConfigured: Bool { !host.isEmpty && !token.isEmpty }
    /// Existing lights API (Tailscale Serve, port 443).
    var lightsBase: URL? { URL(string: "https://\(host)") }
    /// polaris-app-api (Tailscale Serve, port 8443).
    var appBase: URL? { URL(string: "https://\(host):8443") }
    /// devrobotics-helper on the Mac (plain http over the tailnet, port 8766).
    var macBase: URL? { macHost.isEmpty ? nil : URL(string: "http://\(macHost):8766") }
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
