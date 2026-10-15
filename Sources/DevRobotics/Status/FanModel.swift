import Foundation

/// `GET/POST /v1/fan` payload. All safety rules (floors, timers, early end) are enforced on the Pi; this is display state.
struct FanState: Decodable, Equatable, Sendable {
    var available: Bool
    var mode: String            // auto | manual | max
    var percent: Int?
    var rpm: Int?
    var tempC: Double?
    var revertsAt: Double?
    var minPercent: Int?

    var revertDate: Date? { revertsAt.map { Date(timeIntervalSince1970: $0) } }
    var isOverridden: Bool { mode != "auto" }
}

@MainActor
@Observable
final class FanModel {
    enum Phase: Equatable { case loading, unavailable, ready }

    private(set) var phase: Phase = .loading
    private(set) var state: FanState?
    private(set) var busy = false
    /// Last error to show inline. Cleared by the next successful call.
    private(set) var message: String?
    /// Bumped on every accepted change / failure so views can trigger haptics.
    private(set) var successTick = 0
    private(set) var errorTick = 0

    func refresh(settings: SettingsStore) async {
        guard !busy else { return }   // don't let a poll overwrite an in-flight change
        do {
            let s = try await API(settings: settings).getJSON(.app, "v1/fan", as: FanState.self)
            apply(s)
            if message != nil, !busy { message = nil }
        } catch is CancellationError {
        } catch let APIError.http(code, _) where code == 404 {
            phase = .unavailable
        } catch {
            // Keep the last known state on screen; show the problem.
            if phase == .loading { phase = .ready }
            message = Self.describe(error)
        }
    }

    func setAuto(settings: SettingsStore) async { await send(["mode": "auto"], settings) }
    func setManual(percent: Int, settings: SettingsStore) async {
        await send(["mode": "manual", "percent": percent], settings)
    }
    func setMax(settings: SettingsStore) async { await send(["mode": "max"], settings) }

    private func send(_ body: [String: Any], _ settings: SettingsStore) async {
        busy = true
        defer { busy = false }
        do {
            let payload = try JSONSerialization.data(withJSONObject: body)
            let data = try await API(settings: settings).request(.app, "v1/fan", method: "POST", body: payload,
                                                                 contentType: "application/json")
            apply(try JSONDecoder().decode(FanState.self, from: data))
            message = nil
            successTick += 1
        } catch let APIError.http(code, _) where code == 409 {
            message = "Too hot to override the fan. It stays on automatic."
            errorTick += 1
            await refreshAfterError(settings)
        } catch let APIError.http(code, _) where code == 404 || code == 503 {
            phase = .unavailable
            errorTick += 1
        } catch is CancellationError {
        } catch {
            message = Self.describe(error)
            errorTick += 1
            await refreshAfterError(settings)
        }
    }

    private func refreshAfterError(_ settings: SettingsStore) async {
        if let s = try? await API(settings: settings).getJSON(.app, "v1/fan", as: FanState.self) { apply(s) }
    }

    private func apply(_ s: FanState) {
        state = s
        phase = s.available ? .ready : .unavailable
    }

    private static func describe(_ error: Error) -> String {
        if let e = error as? APIError, case .http(let code, _) = e { return "Polaris returned \(code)." }
        if (error as? URLError) != nil { return "Can't reach Polaris. Check Tailscale." }
        return error.localizedDescription
    }
}
