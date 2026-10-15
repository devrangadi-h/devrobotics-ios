import Foundation
import Observation

/// Talks to `Tools/mac/devrobotics-helper` on the Mac (plain http over Tailscale, port 8766, same bearer token as the Pi).
@MainActor @Observable
final class ReinstallFromMacModel {
    struct LastInstall: Decodable, Equatable {
        var build: String?
        var commit: String?
        var builtAt: String?
        var expiresAt: String?
    }
    struct MacStatus: Decodable, Equatable {
        var phoneConnected: Bool
        var installRunning: Bool
        var hostname: String?
        var lastInstall: LastInstall?
    }
    struct Job: Decodable, Equatable {
        var state: String
        var logTail: [String]?
        var startedAt: Double?
    }
    enum Problem: Equatable {
        case notConfigured, unreachable, unauthorised, phoneMissing, alreadyRunning, other(String)
        var text: String {
            switch self {
            case .notConfigured: "Enter your Mac's Tailscale address above."
            case .unreachable: "The Mac is unreachable. Check that it is awake, on Tailscale, and that the helper is running."
            case .unauthorised: "The Mac rejected the token. It must match the Polaris token in Settings."
            case .phoneMissing: "The iPhone is not plugged into the Mac."
            case .alreadyRunning: "An install is already running."
            case .other(let m): m
            }
        }
    }

    var status: MacStatus?
    var job: Job?
    var problem: Problem?
    var checking = false
    var startTick = 0
    var finishTick = 0
    var failTick = 0

    var isRunning: Bool { job?.state == "running" || status?.installRunning == true }
    var reachable: Bool { status != nil }
    var canInstall: Bool { reachable && status?.phoneConnected == true && !isRunning }

    private func send(_ settings: SettingsStore, _ path: String, method: String = "GET") async throws -> (Int, Data) {
        guard let base = settings.macBase, !settings.token.isEmpty else { throw URLError(.badURL) }
        var req = URLRequest(url: base.appending(path: path), timeoutInterval: 6)
        req.httpMethod = method
        req.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    /// One poll: status, and the job log while it is running (or just finished).
    func refresh(_ settings: SettingsStore) async {
        guard settings.macBase != nil else { status = nil; problem = .notConfigured; return }
        guard !settings.token.isEmpty else { status = nil; problem = .unauthorised; return }
        checking = true
        defer { checking = false }
        do {
            let (code, data) = try await send(settings, "v1/mac/status")
            if code == 401 { status = nil; problem = .unauthorised; return }
            guard code == 200, let s = try? JSONDecoder().decode(MacStatus.self, from: data) else {
                status = nil; problem = .other("The Mac answered with \(code). Is the helper up to date?"); return
            }
            status = s
            if problem == .unreachable || problem == .notConfigured || problem == .unauthorised { problem = nil }
            if case .other(let m)? = problem, m.hasPrefix("Can't reach the Mac") { problem = nil }
            if s.installRunning || job?.state == "running" {
                let was = job?.state
                if let (c2, d2) = try? await send(settings, "v1/mac/install"), c2 == 200,
                   let j = try? JSONDecoder().decode(Job.self, from: d2) {
                    job = j
                    if was == "running", j.state == "done" { finishTick += 1 }
                    if was == "running", j.state == "failed" { failTick += 1; problem = .other("The install failed. See the log below.") }
                }
            }
        } catch {
            status = nil
            // Show the real error code so a blocked or unreachable connection can be told apart
            // (-1022 transport security, -1001 timed out, -1004 could not connect, -1009 offline).
            let code = (error as? URLError)?.code.rawValue ?? (error as NSError).code
            problem = .other("Can't reach the Mac (error \(code)). Check it is awake and on Tailscale, the helper is running, and the address is its 100.x IP.")
        }
    }

    func start(_ settings: SettingsStore) async {
        problem = nil
        do {
            let (code, data) = try await send(settings, "v1/mac/install", method: "POST")
            switch code {
            case 202:
                startTick += 1
                job = Job(state: "running", logTail: [], startedAt: Date().timeIntervalSince1970)
                if status != nil { status?.installRunning = true }
            case 401: problem = .unauthorised; failTick += 1
            case 409: problem = .alreadyRunning
            case 412: problem = .phoneMissing; failTick += 1
            default:
                let m = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                problem = .other(m ?? "The Mac answered with \(code).")
                failTick += 1
            }
        } catch {
            problem = .unreachable
            failTick += 1
        }
    }
}
