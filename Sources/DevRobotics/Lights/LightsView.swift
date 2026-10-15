import SwiftUI
import UIKit

/// Both lamps are controlled together. The Pi has no "get state" endpoint, so values shown are the last ones we sent.
@MainActor
@Observable
final class LightsModel {
    enum Reach { case unknown, checking, up, down }
    enum Banner { case none, working, ok(String), failed(String) }

    var reach: Reach = .unknown
    var banner: Banner = .none
    var power: String? = UserDefaults.standard.string(forKey: "lights.power")
    var brightness: Double = UserDefaults.standard.object(forKey: "lights.brightness") as? Double ?? 100
    var preset: String? = UserDefaults.standard.string(forKey: "lights.preset")

    private var debounce: Task<Void, Never>?

    var busy: Bool { if case .working = banner { return true } else { return false } }

    func ping(_ api: API) async {
        reach = .checking
        do {
            nonisolated(unsafe) let api = api
            _ = try await api.request(.lights, "/api/lights/ping", timeout: 8)
            reach = .up
            if case .failed = banner { banner = .none }
        } catch {
            reach = .down
            banner = .failed(Self.message(error))
        }
    }

    func setPower(_ api: API, _ on: Bool) { send(api, "power", on ? "on" : "off", "Lights \(on ? "on" : "off")") {
        self.power = on ? "on" : "off"; UserDefaults.standard.set(self.power, forKey: "lights.power") } }

    func setPreset(_ api: API, _ name: String, label: String) { send(api, "preset", name, label) {
        self.preset = name; UserDefaults.standard.set(name, forKey: "lights.preset") } }

    /// Called when the slider is released; debounced so rapid re-releases send only the last value.
    func commitBrightness(_ api: API) {
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let v = Int(brightness.rounded())
            send(api, "brightness", v, "Brightness \(v)%") { UserDefaults.standard.set(self.brightness, forKey: "lights.brightness") }
        }
    }

    private func send(_ api: API, _ route: String, _ value: Any, _ label: String, onSuccess: @escaping () -> Void) {
        banner = .working
        Task {
            do {
                nonisolated(unsafe) let api = api
                _ = try await api.postJSON(.lights, "/api/lights/\(route)", ["value": value])
                onSuccess(); reach = .up; banner = .ok("\(label) sent")
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                if error is URLError { reach = .down }
                banner = .failed(Self.message(error))
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    static func message(_ error: Error) -> String {
        if case APIError.http(401, _) = error { return "Unauthorized: check token in Settings." }
        if case APIError.notConfigured = error { return "Set the Pi address and token in Settings." }
        if error is URLError { return "Can't reach the Pi. Make sure Tailscale is connected." }
        return error.localizedDescription
    }
}

struct LightsView: View {
    @Environment(SettingsStore.self) private var settings
    @State private var model = LightsModel()

    private var api: API { API(settings: settings) }
    private var enabled: Bool { model.reach == .up && !model.busy }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Circle().fill(reachColor).frame(width: 10, height: 10)
                        Text(reachText)
                        Spacer()
                        if model.reach == .checking { ProgressView() }
                        else { Button("Retry") { Task { await model.ping(api) } } }
                    }
                    bannerRow
                }
                Section("Power") {
                    HStack(spacing: 12) {
                        powerButton("Off", on: false)
                        powerButton("On", on: true)
                    }
                    lastSent(model.power.map { "Last sent: \($0)" })
                }
                Section("Brightness") {
                    Slider(value: $model.brightness, in: 1...100, step: 1) { editing in
                        if !editing { model.commitBrightness(api); UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                    }
                    .tint(Theme.accent).disabled(!enabled)
                    lastSent("Slider \(Int(model.brightness))% (sent on release)")
                }
                Section("Presets") {
                    presetButton("Cool white (6500K)", "bright_white_cool")
                    presetButton("Warm white (3000K)", "bright_white_warm")
                    lastSent(model.preset.map { "Last sent: " + ($0 == "bright_white_cool" ? "cool white" : "warm white") })
                }
                .disabled(!enabled)
            }
            .navigationTitle("Lights")
            .task { await model.ping(api) }
            .refreshable { await model.ping(api) }
        }
    }

    private func powerButton(_ title: String, on: Bool) -> some View {
        Button(title) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            model.setPower(api, on)
        }
        .buttonStyle(.borderedProminent).tint(on ? Theme.accent : .gray)
        .frame(maxWidth: .infinity).disabled(!enabled)
    }

    private func presetButton(_ title: String, _ name: String) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            model.setPreset(api, name, label: title)
        } label: {
            HStack { Text(title); Spacer(); if model.preset == name { Image(systemName: "checkmark") } }
        }
    }

    @ViewBuilder private func lastSent(_ text: String?) -> some View {
        if let text { Text(text).font(.footnote).foregroundStyle(.secondary) }
    }

    @ViewBuilder private var bannerRow: some View {
        switch model.banner {
        case .none: EmptyView()
        case .working: HStack { ProgressView(); Text("Sending...") }
        case .ok(let m): Label(m, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let m): Label(m, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    private var reachColor: Color {
        switch model.reach { case .up: .green; case .down: .red; default: .gray }
    }
    private var reachText: String {
        switch model.reach {
        case .unknown: "Not checked"; case .checking: "Checking..."
        case .up: "Pi reachable"; case .down: "Pi unreachable"
        }
    }
}
