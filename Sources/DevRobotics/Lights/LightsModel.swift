import SwiftUI

struct LampRGB: Equatable, Codable { var r: Int; var g: Int; var b: Int
    var color: Color { Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255) }
}

struct Lamp: Identifiable, Equatable {
    var index: Int
    var name: String
    var online: Bool
    var on: Bool
    var brightness: Int
    var colorTempK: Int?
    var rgb: LampRGB?
    var id: Int { index }
}

struct LightScene: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var icon: String
    var kelvin: Int?
    var rgb: LampRGB?
    var brightness: Int
    var builtIn = false

    var color: Color { rgb?.color ?? kelvinColor(Double(kelvin ?? 4000)) }

    static let builtIns: [LightScene] = [
        .init(id: "reading", name: "Reading", icon: "book.fill", kelvin: 4500, rgb: nil, brightness: 80, builtIn: true),
        .init(id: "relax", name: "Relax", icon: "leaf.fill", kelvin: 2200, rgb: nil, brightness: 45, builtIn: true),
        .init(id: "focus", name: "Focus", icon: "scope", kelvin: 6500, rgb: nil, brightness: 100, builtIn: true),
        .init(id: "movie", name: "Movie", icon: "film.fill", kelvin: nil, rgb: .init(r: 90, g: 60, b: 200), brightness: 20, builtIn: true),
        .init(id: "night", name: "Night", icon: "moon.stars.fill", kelvin: 2000, rgb: nil, brightness: 8, builtIn: true),
    ]
}

/// Approximate colour of a black body at `k` Kelvin.
func kelvinColor(_ k: Double) -> Color {
    let t = max(10, min(400, k / 100))
    func c(_ v: Double) -> Double { max(0, min(255, v)) / 255 }
    let r = t <= 66 ? 255 : 329.698727446 * pow(t - 60, -0.1332047592)
    let g = t <= 66 ? 99.4708025861 * log(t) - 161.1195681661 : 288.1221695283 * pow(t - 60, -0.0755148492)
    let b = t >= 66 ? 255 : (t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307)
    return Color(red: c(r), green: c(g), blue: c(b))
}

/// All lamps are controlled together unless a lamp index is given.
/// If GET /api/lights/state is unavailable (older server) values shown are the last ones we sent.
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
    var kelvin: Double = UserDefaults.standard.object(forKey: "lights.kelvin") as? Double ?? 4000
    var lastRGB: LampRGB? = {
        guard let d = UserDefaults.standard.data(forKey: "lights.rgb") else { return nil }
        return try? JSONDecoder().decode(LampRGB.self, from: d)
    }()
    /// Bumps on every send result so views can drive haptics / symbol effects.
    var sendTick = 0

    var lamps: [Lamp] = []
    var timerEndsAt: Date?
    var lastUpdate: Date?
    var stateLoaded = false
    var stateUnsupported = false
    var unsupported: Set<String> = []
    var editing = false
    var savedScenes: [LightScene] = {
        guard let d = UserDefaults.standard.data(forKey: "lights.scenes") else { return [] }
        return (try? JSONDecoder().decode([LightScene].self, from: d)) ?? []
    }()

    private var debounce: [String: Task<Void, Never>] = [:]
    private var refreshTask: Task<Void, Never>?
    private var inflight = 0

    var busy: Bool { inflight > 0 }

    func supports(_ route: String) -> Bool { !unsupported.contains(route) }

    // MARK: Derived

    var onlineLamps: [Lamp] { lamps.filter(\.online) }
    var anyOn: Bool { lamps.isEmpty ? power == "on" : lamps.contains { $0.on && $0.online } }
    var allOn: Bool { lamps.isEmpty ? power == "on" : onlineLamps.allSatisfy(\.on) && !onlineLamps.isEmpty }
    var displayBrightness: Double {
        let b = onlineLamps.filter(\.on).map { Double($0.brightness) }
        return b.isEmpty ? brightness : b.reduce(0, +) / Double(b.count)
    }
    var displayColor: Color {
        if let l = onlineLamps.first(where: \.on) ?? lamps.first {
            if let rgb = l.rgb { return rgb.color }
            if let k = l.colorTempK { return kelvinColor(Double(k)) }
        }
        if lamps.isEmpty {
            if let rgb = lastRGB, preset == nil { return rgb.color }
            if preset == "bright_white_warm" { return kelvinColor(3000) }
            if preset == "bright_white_cool" { return kelvinColor(6500) }
            if UserDefaults.standard.object(forKey: "lights.kelvin") != nil { return kelvinColor(kelvin) }
        }
        return kelvinColor(5000)
    }

    // MARK: Loading

    func load(_ api: API, initial: Bool = false) async {
        if initial || reach == .unknown { reach = .checking }
        nonisolated(unsafe) let api = api
        do {
            if !stateUnsupported {
                let data = try await api.request(.lights, "/api/lights/state", timeout: 8)
                apply(state: data)
            } else {
                _ = try await api.request(.lights, "/api/lights/ping", timeout: 8)
            }
            reach = .up
            if case .failed = banner { banner = .none }
        } catch {
            if case APIError.http(404, _) = error, !stateUnsupported {
                stateUnsupported = true
                await load(api)
                return
            }
            reach = .down
            banner = .failed(Self.message(error))
        }
    }

    func ping(_ api: API) async { await load(api, initial: true) }

    private func apply(state data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let arr = obj["lamps"] as? [[String: Any]] ?? []
        lamps = arr.map { d in
            var rgb: LampRGB?
            if let c = d["color"] as? [String: Any], let r = c["r"] as? Int, let g = c["g"] as? Int, let b = c["b"] as? Int {
                rgb = LampRGB(r: r, g: g, b: b)
            }
            return Lamp(index: d["index"] as? Int ?? 0, name: d["name"] as? String ?? "Lamp",
                        online: d["online"] as? Bool ?? true, on: d["on"] as? Bool ?? false,
                        brightness: d["brightness"] as? Int ?? 100, colorTempK: d["colorTempK"] as? Int, rgb: rgb)
        }
        if let t = obj["timer"] as? [String: Any], let e = t["endsAt"] as? Double {
            timerEndsAt = Date(timeIntervalSince1970: e)
        } else { timerEndsAt = nil }
        lastUpdate = Date()
        stateLoaded = true
        if !editing {
            let on = onlineLamps.filter(\.on)
            if !on.isEmpty { brightness = on.map { Double($0.brightness) }.reduce(0, +) / Double(on.count) }
            if let k = on.first?.colorTempK { kelvin = Double(k) }
        }
    }

    private func scheduleRefresh(_ api: API) {
        guard !stateUnsupported else { lastUpdate = Date(); return }
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            await load(api)
        }
    }

    // MARK: Commands

    func setPower(_ api: API, _ on: Bool, lamp: Int? = nil) {
        var body: [String: Any] = ["value": on ? "on" : "off"]
        if let lamp { body["lamp"] = lamp }
        send(api, "power", body, lamp == nil ? "Lights \(on ? "on" : "off")" : "Lamp \(on ? "on" : "off")") {
            if let lamp { self.patch(lamp) { $0.on = on } } else {
                self.power = on ? "on" : "off"; UserDefaults.standard.set(self.power, forKey: "lights.power")
                for i in self.lamps.indices { self.lamps[i].on = on }
            }
        }
    }

    func setPreset(_ api: API, _ name: String, label: String) {
        send(api, "preset", ["value": name], label) {
            self.preset = name; UserDefaults.standard.set(name, forKey: "lights.preset")
            self.kelvin = name == "bright_white_warm" ? 3000 : 6500
            let k = Int(self.kelvin)
            for i in self.lamps.indices { self.lamps[i].colorTempK = k; self.lamps[i].rgb = nil }
        }
    }

    /// Called when a slider is released; debounced so rapid re-releases send only the last value.
    func commitBrightness(_ api: API) {
        debounced("brightness") {
            let v = Int(self.brightness.rounded())
            self.send(api, "brightness", ["value": v], "Brightness \(v)%") {
                UserDefaults.standard.set(self.brightness, forKey: "lights.brightness")
                for i in self.lamps.indices { self.lamps[i].brightness = v }
            }
        }
    }

    func commitLampBrightness(_ api: API, lamp: Int, value: Int) {
        debounced("brightness\(lamp)") {
            self.send(api, "brightness", ["value": value, "lamp": lamp], "Lamp \(lamp + 1) \(value)%") {
                self.patch(lamp) { $0.brightness = value }
            }
        }
    }

    func commitKelvin(_ api: API) {
        debounced("colortemp") {
            let k = Int(self.kelvin.rounded())
            self.send(api, "colortemp", ["value": k], "\(k)K") {
                UserDefaults.standard.set(self.kelvin, forKey: "lights.kelvin")
                self.preset = nil; UserDefaults.standard.removeObject(forKey: "lights.preset")
                self.lastRGB = nil; UserDefaults.standard.removeObject(forKey: "lights.rgb")
                for i in self.lamps.indices { self.lamps[i].colorTempK = k; self.lamps[i].rgb = nil }
            }
        }
    }

    func setColor(_ api: API, _ rgb: LampRGB) {
        debounced("color") {
            self.send(api, "color", ["r": rgb.r, "g": rgb.g, "b": rgb.b], "Colour") {
                self.lastRGB = rgb
                if let d = try? JSONEncoder().encode(rgb) { UserDefaults.standard.set(d, forKey: "lights.rgb") }
                self.preset = nil; UserDefaults.standard.removeObject(forKey: "lights.preset")
                for i in self.lamps.indices { self.lamps[i].rgb = rgb; self.lamps[i].colorTempK = nil }
            }
        }
    }

    func setTimer(_ api: API, minutes: Int) {
        send(api, "timer", ["minutes": minutes, "action": "off"], "Sleep timer \(minutes) min") {
            self.timerEndsAt = Date().addingTimeInterval(Double(minutes) * 60)
        }
    }

    func cancelTimer(_ api: API) {
        send(api, "timer", ["cancel": true], "Timer cancelled") { self.timerEndsAt = nil }
    }

    func apply(_ api: API, scene: LightScene) {
        inflight += 1
        banner = .working
        Task {
            nonisolated(unsafe) let api = api
            defer { inflight -= 1 }
            do {
                try await post(api, "power", ["value": "on"])
                if let rgb = scene.rgb {
                    try await post(api, "color", ["r": rgb.r, "g": rgb.g, "b": rgb.b])
                } else if let k = scene.kelvin {
                    try await post(api, "colortemp", ["value": k])
                }
                try await Task.sleep(for: .milliseconds(400))
                try await post(api, "brightness", ["value": scene.brightness])
                power = "on"; brightness = Double(scene.brightness)
                preset = nil
                if let k = scene.kelvin { kelvin = Double(k); lastRGB = nil }
                if let rgb = scene.rgb { lastRGB = rgb }
                for i in lamps.indices {
                    lamps[i].on = true; lamps[i].brightness = scene.brightness
                    lamps[i].colorTempK = scene.kelvin; lamps[i].rgb = scene.rgb
                }
                reach = .up; banner = .ok("\(scene.name) scene applied"); sendTick += 1
                scheduleRefresh(api)
            } catch {
                handle(error, route: "scene")
            }
        }
    }

    func saveCurrentScene(name: String) {
        let k: Int? = lastRGB == nil ? Int(kelvin.rounded()) : nil
        let scene = LightScene(id: UUID().uuidString, name: name, icon: "star.fill", kelvin: k, rgb: lastRGB,
                               brightness: Int(displayBrightness.rounded()))
        savedScenes.append(scene)
        persistScenes()
    }

    func deleteScene(_ scene: LightScene) {
        savedScenes.removeAll { $0.id == scene.id }
        persistScenes()
    }

    private func persistScenes() {
        if let d = try? JSONEncoder().encode(savedScenes) { UserDefaults.standard.set(d, forKey: "lights.scenes") }
    }

    // MARK: Plumbing

    private func patch(_ lamp: Int, _ f: (inout Lamp) -> Void) {
        if let i = lamps.firstIndex(where: { $0.index == lamp }) { f(&lamps[i]) }
    }

    private func debounced(_ key: String, _ work: @escaping @MainActor () -> Void) {
        debounce[key]?.cancel()
        debounce[key] = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            work()
        }
    }

    private func post(_ api: API, _ route: String, _ body: [String: Any]) async throws {
        nonisolated(unsafe) let api = api
        nonisolated(unsafe) let body = body
        _ = try await api.postJSON(.lights, "/api/lights/\(route)", body)
    }

    private func send(_ api: API, _ route: String, _ body: [String: Any], _ label: String, onSuccess: @escaping () -> Void) {
        banner = .working
        inflight += 1
        Task {
            defer { inflight -= 1 }
            do {
                try await post(api, route, body)
                onSuccess(); reach = .up; banner = .ok("\(label) sent"); sendTick += 1
                scheduleRefresh(api)
            } catch {
                handle(error, route: route)
            }
        }
    }

    private func handle(_ error: Error, route: String) {
        if case APIError.http(404, _) = error, ["colortemp", "color", "timer"].contains(route) {
            unsupported.insert(route)
            banner = .failed("This feature isn't available on the Pi yet.")
        } else {
            if error is URLError { reach = .down }
            banner = .failed(Self.message(error))
        }
        sendTick += 1
    }

    static func message(_ error: Error) -> String {
        if case APIError.http(401, _) = error { return "Unauthorized: check token in Settings." }
        if case APIError.notConfigured = error { return "Set the Pi address and token in Settings." }
        if error is URLError { return "Can't reach the Pi. Make sure Tailscale is connected." }
        return error.localizedDescription
    }
}
