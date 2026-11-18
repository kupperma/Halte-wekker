import Foundation

/// A home, school or station as the planner gets it, in plain values (the app makes a `Place` of it).
struct RolePlace: Equatable, Sendable {
    var key: String
    var name: String
    var short: String
    /// Transitous stop ids, or "lat,lon".
    var ids: [String]
    var lat: Double
    var lon: Double
    /// How the announcer says it.
    var spoken: String

    var point: GeoPoint { GeoPoint(lat: lat, lon: lon) }
}

/// What the roles are made from: your saved Home and School (`places.v1`), your home board's stops and the profile.
struct RoleInputs: Equatable, Sendable {
    var home: SavedPlace?
    var school: SavedPlace?
    var boardIds: [String]
    var corridor: Corridor?
    var calendarHints: [String]

    /// Before the stores have said anything: today's defaults.
    static let legacy = RoleInputs(home: nil, school: nil, boardIds: RoleLogic.legacyHome.ids, corridor: .veghelBreda,
                                   calendarHints: ProfileLogic.legacyHints)
}

/// Your Home and School as the trips, the alarm and the words see them.
struct Roles: Equatable, Sendable {
    /// Home, where trips home go (key "veghel").
    var home: RolePlace
    /// Home as the trips from it start: your board stops, on the corridor (0.21's `StopsStore.veghel`).
    var homeBoard: RolePlace
    /// School (key "buas").
    var school: RolePlace
    var corridor: Corridor?
    /// Home and School are still today's exact places (the corridor's, within 400 m of them).
    var homeIsLegacy: Bool
    var schoolIsLegacy: Bool
    var words: RoleWords
}

/// The rules of the roles. Home keeps key "veghel" and School key "buas" whatever they are (saved data is keyed by
/// them: `kmMem`, `lastMode`, the scoreboard, region ids, the next-trip keys); name, stops and coordinate come from
/// your places. On the corridor, and still about where today's are, they are today's places to the byte.
enum RoleLogic {
    static let homeKey = "veghel"
    static let schoolKey = "buas"
    /// Within this of today's place (and on the corridor), Home or School is today's place exactly.
    static let legacyRadius = 400.0

    /// Today's (0.21) home and school, exactly.
    static let legacyHome = RolePlace(key: homeKey, name: "Veghel, Busstation", short: "Veghel",
                                      ids: ["nl-OpenOV_NL:S:64553000", "nl-OpenOV_4219829"], lat: 51.6137, lon: 5.5474, spoken: "Veghel")
    static let legacySchool = RolePlace(key: schoolKey, name: "Breda University (BUas)", short: "BUas",
                                        ids: ["51.5907,4.7932"], lat: 51.5907, lon: 4.7932, spoken: "Breda University")

    /// Today's place for a role while it's still there: on the corridor, and within 400 m of it (none saved yet
    /// counts as there: the places are seeded from it).
    static func isLegacy(_ saved: SavedPlace?, _ legacy: RolePlace, corridor: Corridor?) -> Bool {
        guard corridor == .veghelBreda else { return false }
        guard let s = saved else { return true }
        return Geo.metres(s.point, legacy.point) < legacyRadius
    }

    /// A saved place as a role: its name, its stops (none: its spot on the map) and its coordinate, with the role's key.
    static func place(_ s: SavedPlace, key: String) -> RolePlace {
        RolePlace(key: key, name: s.name, short: s.name, ids: s.stopIds.isEmpty ? ["\(s.lat),\(s.lon)"] : s.stopIds,
                  lat: s.lat, lon: s.lon, spoken: s.name)
    }

    /// Home as trips from it start. Today's home: your board stops replace its ids (0.21's `StopsStore.veghel`).
    /// A home of your own: its own stops (the board may still be somewhere else).
    static func homeBoard(_ home: RolePlace, isLegacy: Bool, boardIds: [String]) -> RolePlace {
        guard isLegacy else { return home }
        var h = home
        if !boardIds.isEmpty { h.ids = boardIds }
        return h
    }

    static func roles(_ i: RoleInputs) -> Roles {
        let hl = isLegacy(i.home, legacyHome, corridor: i.corridor), sl = isLegacy(i.school, legacySchool, corridor: i.corridor)
        let home = hl ? legacyHome : i.home.map { place($0, key: homeKey) } ?? legacyHome
        let school = sl ? legacySchool : i.school.map { place($0, key: schoolKey) } ?? legacySchool
        return Roles(home: home, homeBoard: homeBoard(home, isLegacy: hl, boardIds: i.boardIds), school: school,
                     corridor: i.corridor, homeIsLegacy: hl, schoolIsLegacy: sl,
                     words: RoleWords.make(school: school.short, corridor: i.corridor, hints: i.calendarHints))
    }
}

/// The corridor's own stations: the two hubs and the school's station (0.21's `Place.denBosch`, `.eindhoven`, `.breda`).
extension Corridor {
    var stations: [RolePlace] {
        switch self {
        case .veghelBreda:
            return [Self.denBosch, Self.eindhoven, Self.breda]
        }
    }

    static let denBosch = RolePlace(key: "ht", name: "’s-Hertogenbosch Centraal", short: "Den Bosch", ids: ["de-DELFI_000008400319"],
                                    lat: 51.6905, lon: 5.2936, spoken: "Den Bosch")
    static let eindhoven = RolePlace(key: "ehv", name: "Eindhoven Centraal", short: "Eindhoven", ids: ["de-DELFI_000008400206"],
                                     lat: 51.4432, lon: 5.4812, spoken: "Eindhoven Central")
    static let breda = RolePlace(key: "bd", name: "Breda station", short: "Breda", ids: ["nl-OpenOV_stoparea:17911"],
                                 lat: 51.5955, lon: 4.7797, spoken: "Breda station")
    /// The hubs where you change: the fixed routes go via these.
    var hubs: [RolePlace] { switch self { case .veghelBreda: return [Self.denBosch, Self.eindhoven] } }
}
