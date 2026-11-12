import CoreLocation
import Foundation

/// A place the planner knows. `ids` are Transitous stop ids (or "lat,lon").
struct Place: Hashable {
    let key: String
    let name: String
    let short: String
    let ids: [String]
    let coordinate: CLLocationCoordinate2D
    var spoken: String          // how the announcer says it

    static func == (a: Place, b: Place) -> Bool { a.key == b.key }
    func hash(into h: inout Hasher) { h.combine(key) }

    static let veghel = Place(key: "veghel", name: "Veghel, Busstation", short: "Veghel",
                              ids: ["nl-OpenOV_NL:S:64553000", "nl-OpenOV_4219829"],
                              coordinate: .init(latitude: 51.6137, longitude: 5.5474), spoken: "Veghel")
    static let denBosch = Place(key: "ht", name: "’s-Hertogenbosch Centraal", short: "Den Bosch",
                                ids: ["de-DELFI_000008400319"],
                                coordinate: .init(latitude: 51.6905, longitude: 5.2936), spoken: "Den Bosch")
    static let eindhoven = Place(key: "ehv", name: "Eindhoven Centraal", short: "Eindhoven",
                                 ids: ["de-DELFI_000008400206"],
                                 coordinate: .init(latitude: 51.4432, longitude: 5.4812), spoken: "Eindhoven Central")
    static let breda = Place(key: "bd", name: "Breda station", short: "Breda",
                             ids: ["nl-OpenOV_stoparea:17911"],
                             coordinate: .init(latitude: 51.5955, longitude: 4.7797), spoken: "Breda station")
    static let buas = Place(key: "buas", name: "Breda University (BUas)", short: "BUas",
                            ids: ["51.5907,4.7932"],
                            coordinate: .init(latitude: 51.5907, longitude: 4.7932), spoken: "Breda University")
    static let all: [Place] = [.veghel, .denBosch, .eindhoven, .breda, .buas]
    /// Where you are now, as a place to plan from.
    static func here(_ c: CLLocationCoordinate2D) -> Place {
        Place(key: "here", name: "Where you are", short: "Here", ids: ["\(c.latitude),\(c.longitude)"], coordinate: c, spoken: "here")
    }
}

enum Mode: String, Codable {
    case bus, train
    var title: String { self == .bus ? "Bus" : "Train" }
    var symbol: String { self == .bus ? "bus.fill" : "tram.fill" }
    var transitModes: String { self == .bus ? "BUS" : "RAIL" }
}

enum Direction: String {
    case toSchool, home
    var word: String { self == .toSchool ? "BREDA" : "HOME" }
    var kicker: String { self == .toSchool ? "Going to" : "Going" }
}

struct Leg: Hashable {
    let mode: Mode
    let from: Place
    let to: Place
    var title: String { "\(mode.title) to \(to.short)" }
}

/// Your two routes. Going home is the same route backwards.
struct RoutePlan: Identifiable, Hashable {
    let id: String
    let name: String
    let station: Place
    var single: Leg? = nil          // "Wake me at a single stop": one leg, no route

    static func stop(_ p: Place, mode: Mode, from: Place) -> RoutePlan {
        RoutePlan(id: "stop-\(p.key)", name: p.name, station: p, single: Leg(mode: mode, from: from, to: p))
    }

    static let all = [
        RoutePlan(id: "via-denbosch", name: "Via Den Bosch", station: .denBosch),
        RoutePlan(id: "via-eindhoven", name: "Via Eindhoven", station: .eindhoven),
    ]
    static func via(_ station: Place) -> RoutePlan? { all.first { $0.station == station } }

    func legs(_ dir: Direction) -> [Leg] {
        if let single { return [single] }
        switch dir {
        case .toSchool:
            return [Leg(mode: .bus, from: .veghel, to: station), Leg(mode: .train, from: station, to: .breda)]
        case .home:
            return [Leg(mode: .train, from: .breda, to: station), Leg(mode: .bus, from: station, to: .veghel)]
        }
    }
}

enum Fmt {
    static func distance(_ m: Double) -> String {
        if m < 1000 { return "\(max(0, Int((m / 10).rounded()) * 10)) m" }
        if m < 100_000 { return String(format: "%.1f km", m / 1000) }
        return "\(Int((m / 1000).rounded())) km"
    }
    static func distanceParts(_ m: Double) -> (String, String) {
        let s = distance(m).split(separator: " ")
        return (String(s.first ?? ""), String(s.last ?? ""))
    }
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = TimeZone(identifier: "Europe/Amsterdam")
        return f
    }()
    static func hhmm(_ d: Date) -> String { time.string(from: d) }
    /// "24 min", "1 h 05 min"
    static func rideText(_ m: Double) -> String {
        let n = max(1, Int(m.rounded()))
        return n >= 60 ? "\(n / 60) h \(String(format: "%02d", n % 60)) min" : "\(n) min"
    }
    /// "2 km", "500 m"
    static func km(_ k: Double) -> String {
        if k < 1 { return "\(Int((k * 1000).rounded())) m" }
        let r = (k * 10).rounded() / 10
        return r == r.rounded() ? "\(Int(r)) km" : String(format: "%.1f km", r)
    }
    static let ymd: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "Europe/Amsterdam"); f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    /// "Today 08:21", "Yesterday 17:40", "Mon 10 Nov 08:21"
    static func when(_ d: Date) -> String {
        let cal = Calendar.current
        let day = cal.isDateInToday(d) ? "Today" : cal.isDateInYesterday(d) ? "Yesterday" : {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "EEE d MMM"; return f.string(from: d)
        }()
        return "\(day) \(hhmm(d))"
    }
    static func mins(_ s: TimeInterval) -> Int { max(0, Int((s / 60).rounded())) }
    /// "’s-Hertogenbosch, Centraal Station" → "Den Bosch"; "Breda, Nassausingel" → "Nassausingel"
    static func place(_ n: String) -> String {
        let l = n.lowercased()
        if l.contains("hertogenbosch") { return "Den Bosch" }
        if l.contains("eindhoven") { return "Eindhoven" }
        if l.contains("veghel") { return "Veghel" }
        if n == "END" || n == "START" { return "BUas" }
        if l == "breda" || l.hasPrefix("breda (") || l.hasPrefix("breda, centraal") { return "Breda" }
        if let r = n.range(of: ", ") { return String(n[r.upperBound...]) }
        return n
    }
}
