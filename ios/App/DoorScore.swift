import Foundation

/// The scoreboard for door-to-door trips (0.24): off the corridor there are no fixed routes to score, so a trip that
/// went from Home to School (or back) is scored as "home→school" ("school→home"), against your own fastest one. The
/// corridor keeps its routes' keys ("Via Den Bosch").
enum DoorScore {
    static let toSchool = "home→school"
    static let toHome = "school→home"
    /// The trip started this close to a role (where the alarm started: your stop, or on the bus just after it)…
    static let startMetres = 2500.0
    /// …and its last stop is this close to the other role.
    static let endMetres = 1500.0

    /// The board's key for a trip that started at `start` and ended at `end`, and whether it went home; nil when it
    /// wasn't between Home and School.
    static func key(start: GeoPoint, end: GeoPoint, home: GeoPoint, school: GeoPoint) -> (route: String, home: Bool)? {
        let sh = Geo.metres(start, home), ss = Geo.metres(start, school)
        let eh = Geo.metres(end, home), es = Geo.metres(end, school)
        if sh <= startMetres, es <= endMetres, sh < ss, es < eh { return (toSchool, false) }
        if ss <= startMetres, eh <= endMetres, ss < sh, eh < es { return (toHome, true) }
        return nil
    }

    /// How the board shows a trip's route: "Home → Fontys" for a door-to-door one, else its route's name.
    static func label(_ route: String, school: String) -> String {
        switch route {
        case toSchool: return "Home → \(school)"
        case toHome: return "\(school) → Home"
        default: return route
        }
    }
}
