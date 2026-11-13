import CoreLocation
import SwiftUI

/// One hour of the forecast.
struct WeatherHour: Codable, Hashable {
    let time: Date
    let temp: Double           // °C
    let feels: Double          // °C, with the wind
    let rainChance: Int        // %
    let rain: Double           // mm in the hour
    let code: Int              // WMO weather code
    let wind: Double           // km/h

    /// Wet enough to want a raincoat: rain or snow likely, or some expected (drizzle can come with a low chance).
    var wet: Bool {
        if rain >= 0.2 || rainChance >= 45 { return true }
        let rainy = (51...67).contains(code) || (71...86).contains(code) || code >= 95
        return rainy && rainChance >= 20
    }

    var symbol: String {
        let night = { let h = Calendar.current.component(.hour, from: time); return h < 7 || h >= 19 }()
        switch code {
        case 0: return night ? "moon.stars.fill" : "sun.max.fill"
        case 1, 2: return night ? "cloud.moon.fill" : "cloud.sun.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...57: return "cloud.drizzle.fill"
        case 65, 67, 82: return "cloud.heavyrain.fill"
        case 61...67, 80...82: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }
}

/// The forecast, from Open-Meteo (free, no account). Your position goes to it rounded to about a kilometre.
enum Weather {
    static func hourly(_ c: CLLocationCoordinate2D) async -> [WeatherHour] {
        let la = (c.latitude * 100).rounded() / 100, lo = (c.longitude * 100).rounded() / 100
        let key = "\(la),\(lo)"
        if let hit = WeatherMemo.shared.get(key) { return hit }
        var u = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        u.queryItems = [.init(name: "latitude", value: "\(la)"), .init(name: "longitude", value: "\(lo)"),
                        .init(name: "hourly", value: "temperature_2m,apparent_temperature,precipitation_probability,precipitation,weather_code,wind_speed_10m"),
                        .init(name: "forecast_days", value: "2"), .init(name: "timeformat", value: "unixtime"), .init(name: "timezone", value: "auto")]
        var req = URLRequest(url: u.url!, timeoutInterval: 12)
        req.setValue("Haltewekker-iOS", forHTTPHeaderField: "User-Agent")
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let h = json["hourly"] as? [String: Any], let times = h["time"] as? [Double] else { continue }
            func nums(_ k: String) -> [Double] { ((h[k] as? [Any]) ?? []).map { ($0 as? Double) ?? Double(($0 as? Int) ?? 0) } }
            let t = nums("temperature_2m"), f = nums("apparent_temperature"), p = nums("precipitation_probability"),
                r = nums("precipitation"), w = nums("weather_code"), v = nums("wind_speed_10m")
            let n = [times.count, t.count, f.count, p.count, r.count, w.count, v.count].min() ?? 0
            let out = (0..<n).map { i in
                WeatherHour(time: Date(timeIntervalSince1970: times[i]), temp: t[i], feels: f[i], rainChance: Int(p[i]), rain: r[i], code: Int(w[i]), wind: v[i])
            }
            if !out.isEmpty { WeatherMemo.shared.set(key, out) }
            return out
        }
        return []
    }
}

/// Forecasts, remembered for half an hour per spot.
final class WeatherMemo: @unchecked Sendable {
    static let shared = WeatherMemo()
    private let lock = NSLock()
    private var items: [String: (hours: [WeatherHour], at: Date)] = [:]
    func get(_ k: String) -> [WeatherHour]? {
        lock.lock(); defer { lock.unlock() }
        guard let v = items[k], Date().timeIntervalSince(v.at) < 1800 else { return nil }
        return v.hours
    }
    func set(_ k: String, _ h: [WeatherHour]) { lock.lock(); items[k] = (h, Date()); lock.unlock() }
}

/// What to wear, in five grades by how cold it feels (with the wind).
enum Layer: Int, CaseIterable, Comparable {
    case winter = 1, cold, mild, warm, summer
    static func < (a: Layer, b: Layer) -> Bool { a.rawValue < b.rawValue }

    static func of(feels: Double) -> Layer {
        switch feels {
        case ..<2: return .winter
        case ..<10: return .cold
        case ..<17: return .mild
        case ..<24: return .warm
        default: return .summer
        }
    }

    var name: String {
        switch self {
        case .winter: return "Very cold winter"
        case .cold: return "Cold"
        case .mild: return "Mild"
        case .warm: return "Warm"
        case .summer: return "Peak summer"
        }
    }
    var layers: Int {
        switch self { case .winter: return 4; case .cold: return 3; case .mild: return 2; case .warm, .summer: return 1 }
    }
    var wear: String {
        switch self {
        case .winter: return "Winter coat over a warm sweater, with a scarf, gloves and a hat"
        case .cold: return "A coat over a sweater"
        case .mild: return "A sweater or a light jacket"
        case .warm: return "A T-shirt, with a thin layer for the evening"
        case .summer: return "A T-shirt and shorts, sunglasses, and water"
        }
    }
    /// The layers themselves, bottom to top.
    var pieces: [String] {
        switch self {
        case .winter: return ["Shirt", "Sweater", "Winter coat", "Scarf, gloves, hat"]
        case .cold: return ["Shirt", "Sweater", "Coat"]
        case .mild: return ["Shirt", "Sweater or light jacket"]
        case .warm: return ["T-shirt"]
        case .summer: return ["T-shirt, shorts"]
        }
    }
    var range: String {
        switch self {
        case .winter: return "feels under 2°"
        case .cold: return "feels 2° to 10°"
        case .mild: return "feels 10° to 17°"
        case .warm: return "feels 17° to 24°"
        case .summer: return "feels 24° and up"
        }
    }
    var icon: String {
        switch self {
        case .winter: return "snowflake"
        case .cold: return "thermometer.low"
        case .mild: return "thermometer.medium"
        case .warm: return "sun.min.fill"
        case .summer: return "sun.max.fill"
        }
    }
    var color: Color {
        switch self {
        case .winter: return Color(hex: 0x224F86)
        case .cold: return Color(hex: 0x528DBA)
        case .mild: return Color(hex: 0x4C9F70)
        case .warm: return Color(hex: 0xE0B020)
        case .summer: return Color(hex: 0xE0662A)
        }
    }
}

/// The day's outfit: where you are until you get there, then where you're going.
struct OutfitPlan {
    struct Hour: Hashable {
        let w: WeatherHour
        let there: Bool        // at the place you're going (else where you set off)
        let layer: Layer
    }
    struct Change: Hashable {
        let at: Date
        let place: String
        let from: Layer
        let to: Layer
        let feels: Double
    }
    let here: String
    let there: String
    let leave: Date
    let arrive: Date
    let tomorrow: Bool
    let hours: [Hour]

    /// What to put on when you set off.
    var start: Hour? { hours.first { $0.w.time.addingTimeInterval(3600) > leave } ?? hours.first }
    /// Rain: the wet stretches, with where.
    var rain: [(from: Date, to: Date, place: String, chance: Int)] {
        var out: [(Date, Date, String, Int)] = []
        for h in hours where h.w.wet {
            let p = h.there ? there : here
            if let last = out.last, last.1 == h.w.time, last.2 == p {
                out[out.count - 1] = (last.0, h.w.time.addingTimeInterval(3600), p, max(last.3, h.w.rainChance))
            } else {
                out.append((h.w.time, h.w.time.addingTimeInterval(3600), p, h.w.rainChance))
            }
        }
        return out.map { (from: $0.0, to: $0.1, place: $0.2, chance: $0.3) }
    }
    var raincoat: Bool { !rain.isEmpty }

    /// When to drop or add a layer: where the grade changes for two hours or more (or for the rest of the day).
    var changes: [Change] {
        guard let s = start, let from = hours.firstIndex(of: s) else { return [] }
        var out: [Change] = []
        var cur = s.layer
        for i in hours.indices where i > from {
            let l = hours[i].layer
            guard l != cur, i + 1 >= hours.count || hours[i + 1].layer == l else { continue }
            out.append(Change(at: hours[i].w.time, place: hours[i].there ? there : here, from: cur, to: l, feels: hours[i].w.feels))
            cur = l
        }
        return out
    }

    var coldest: Hour? { hours.min { $0.w.feels < $1.w.feels } }
    var warmest: Hour? { hours.max { $0.w.feels < $1.w.feels } }
}

/// Looks up the day's outfit now and then (every 20 minutes, or when where you are or where you're going changes).
@MainActor
final class OutfitStore: ObservableObject {
    static let shared = OutfitStore()
    @Published private(set) var plan: OutfitPlan?
    @Published private(set) var loading = false
    private var last: (key: String, at: Date)?
    private var context: (here: CLLocation?, dest: Place, leave: Date?, arrive: Date?)?

    /// Where you are and where you're going, and when (from your trip, if there is one).
    func set(here: CLLocation?, dest: Place, leave: Date?, arrive: Date?) {
        context = (here, dest, leave, arrive)
    }

    func refresh(force: Bool = false) async {
        guard let c = context else { return }
        let now = Date()
        let hereC = c.here?.coordinate ?? (c.dest == .veghel ? Place.buas.coordinate : Place.veghel.coordinate)
        let tomorrow = Calendar.current.component(.hour, from: now) >= 19
        let key = "\(Int(hereC.latitude * 100)),\(Int(hereC.longitude * 100))>\(c.dest.key)|\(tomorrow)|\(c.leave.map { Int($0.timeIntervalSince1970 / 900) } ?? 0)"
        if !force, let l = last, l.key == key, now.timeIntervalSince(l.at) < 20 * 60 { return }
        guard !loading else { return }
        loading = true
        defer { loading = false }
        async let a = Weather.hourly(hereC)
        async let b = Weather.hourly(c.dest.coordinate)
        let (atHere, atThere) = await (a, b)
        guard !atHere.isEmpty || !atThere.isEmpty else { return }
        // the day: from this hour (or 6 tomorrow morning, in the evening) until 11 at night
        let cal = Calendar.current
        let dayStart = tomorrow ? cal.date(bySettingHour: 6, minute: 0, second: 0, of: now.addingTimeInterval(86400))!
                                : cal.date(bySettingHour: cal.component(.hour, from: now), minute: 0, second: 0, of: now)!
        let dayEnd = cal.date(bySettingHour: 23, minute: 0, second: 0, of: dayStart)!
        var leave = c.leave ?? (tomorrow ? cal.date(bySettingHour: 8, minute: 0, second: 0, of: dayStart)! : now)
        if !tomorrow, leave < now { leave = now }
        let arrive = max(c.arrive ?? leave.addingTimeInterval(75 * 60), leave)
        var hours: [OutfitPlan.Hour] = []
        for w in (atHere.isEmpty ? atThere : atHere) where w.time >= dayStart && w.time <= dayEnd {
            let there = w.time.addingTimeInterval(1800) >= arrive
            let use = there ? (atThere.first { abs($0.time.timeIntervalSince(w.time)) < 60 } ?? w) : w
            hours.append(.init(w: use, there: there, layer: Layer.of(feels: use.feels)))
        }
        plan = OutfitPlan(here: Self.name(hereC), there: c.dest.short, leave: leave, arrive: arrive, tomorrow: tomorrow, hours: hours)
        last = (key, now)
    }

    /// The place's name, if it's one of yours (else "where you are").
    static func name(_ c: CLLocationCoordinate2D) -> String {
        let here = CLLocation(latitude: c.latitude, longitude: c.longitude)
        let near = NearMe.places.values.min { here.distance(from: CLLocation(latitude: $0.0.latitude, longitude: $0.0.longitude)) < here.distance(from: CLLocation(latitude: $1.0.latitude, longitude: $1.0.longitude)) }
        if let n = near, here.distance(from: CLLocation(latitude: n.0.latitude, longitude: n.0.longitude)) < 3000 {
            return n.1.replacingOccurrences(of: " station", with: "")
        }
        return "where you are"
    }
}
