import CoreLocation
import Foundation

/// A place the planner knows. `ids` are Transitous stop ids (or "lat,lon").
struct Place: Hashable {
    let key: String
    let name: String
    let short: String
    let ids: [String]
    let coordinate: CLLocationCoordinate2D

    static func == (a: Place, b: Place) -> Bool { a.key == b.key }
    func hash(into h: inout Hasher) { h.combine(key) }

    static let veghel = Place(key: "veghel", name: "Veghel", short: "Veghel",
                              ids: ["nl-OpenOV_NL:S:64553000", "nl-OpenOV_4219829"],
                              coordinate: .init(latitude: 51.6137, longitude: 5.5474))
    static let denBosch = Place(key: "ht", name: "’s-Hertogenbosch Centraal", short: "Den Bosch",
                                ids: ["de-DELFI_000008400319"],
                                coordinate: .init(latitude: 51.6905, longitude: 5.2936))
    static let eindhoven = Place(key: "ehv", name: "Eindhoven Centraal", short: "Eindhoven",
                                 ids: ["de-DELFI_000008400206"],
                                 coordinate: .init(latitude: 51.4432, longitude: 5.4812))
    static let breda = Place(key: "bd", name: "Breda station", short: "Breda",
                             ids: ["nl-OpenOV_stoparea:17911"],
                             coordinate: .init(latitude: 51.5955, longitude: 4.7797))
}

enum Mode: String, Codable {
    case bus, train
    var title: String { self == .bus ? "Bus" : "Train" }
    var symbol: String { self == .bus ? "bus.fill" : "tram.fill" }
    var transitModes: String { self == .bus ? "BUS" : "RAIL" }
}

enum Direction: String {
    case toSchool, home
    var title: String { self == .toSchool ? "To Breda" : "Home" }
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

    static let all = [
        RoutePlan(id: "via-denbosch", name: "Via Den Bosch", station: .denBosch),
        RoutePlan(id: "via-eindhoven", name: "Via Eindhoven", station: .eindhoven),
    ]

    func legs(_ dir: Direction) -> [Leg] {
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
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = TimeZone(identifier: "Europe/Amsterdam")
        return f
    }()
    static func hhmm(_ d: Date) -> String { time.string(from: d) }
}
