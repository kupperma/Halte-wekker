import Foundation

/// The regions the auto-start and auto-home watch (iOS keeps them, cheaply, across launches; full GPS only switches on
/// once you leave one). On the corridor: today's (0.21) list exactly, the school's entry for auto-home and your home and
/// the corridor's stations to leave for auto-start. Off it (0.24): your home board's stops and School, each to leave;
/// School's entry too for auto-home. Leaving one looks for the bus or train you're on and starts a door-to-door trip to
/// the other role (`TripManager.autoStartDoor`), the way Fastest trip starts one.
enum RoleRegions {
    enum Role: Equatable, Sendable { case home, school }

    /// The school's region (auto-home's entry; off the corridor, auto-start's exit too).
    static let schoolId = "school"
    /// Off the corridor, a home stop's region: "home.0", "home.1"…; "home" when no stop has a position (Home itself).
    static let homePrefix = "home"
    /// Around your home stop (as around Veghel bus station today) and around a corridor station.
    static let homeRadius = 350.0
    static let stationRadius = 300.0
    /// Two home stops closer than this are one region (both sides of the road).
    static let mergeMetres = 150.0

    /// The regions wanted. `homeStops`: where your home board's stops are (off the corridor; the ones with a position).
    /// `schoolRadius`: around School (`NearMe.schoolRadius`).
    static func wanted(roles: Roles, homeStops: [GeoPoint], autoStart: Bool, autoHome: Bool, schoolRadius: Double) -> [RegionSpec] {
        var out: [RegionSpec] = []
        let school = roles.school
        guard let corridor = roles.corridor else {
            // off the corridor: School to leave (and to reach, for auto-home), then your home stops to leave
            if autoStart || autoHome {
                out.append(RegionSpec(id: schoolId, lat: school.lat, lon: school.lon, radius: schoolRadius, entry: autoHome, exit: autoStart))
            }
            if autoStart {
                let stops = merged(homeStops)
                if stops.isEmpty {
                    out.append(RegionSpec(id: homePrefix, lat: roles.home.lat, lon: roles.home.lon, radius: homeRadius, entry: false, exit: true))
                }
                for (i, p) in stops.enumerated() {
                    out.append(RegionSpec(id: "\(homePrefix).\(i)", lat: p.lat, lon: p.lon, radius: homeRadius, entry: false, exit: true))
                }
            }
            return out
        }
        // the corridor: exactly 0.21's (`TripManager.updateWatching`)
        if autoHome {
            out.append(RegionSpec(id: schoolId, lat: school.lat, lon: school.lon, radius: schoolRadius, entry: true, exit: false))
        }
        if autoStart {
            // `Place.all` minus School, in its order: home, Den Bosch, Eindhoven, Breda
            for p in [roles.home] + corridor.stations {
                out.append(RegionSpec(id: p.key, lat: p.lat, lon: p.lon, radius: p.key == RoleLogic.homeKey ? homeRadius : stationRadius,
                                      entry: false, exit: true))
            }
        }
        return out
    }

    /// (0.29) "Show friends when I'm at school": the school's region also tells when you get there and leave (added
    /// when it isn't watched; both ways when it is). The rest as `wanted` has it.
    static func withCampus(_ base: [RegionSpec], school: GeoPoint, radius: Double) -> [RegionSpec] {
        guard let i = base.firstIndex(where: { $0.id == schoolId }) else {
            return base + [RegionSpec(id: schoolId, lat: school.lat, lon: school.lon, radius: radius, entry: true, exit: true)]
        }
        var out = base
        let r = base[i]
        out[i] = RegionSpec(id: r.id, lat: r.lat, lon: r.lon, radius: r.radius, entry: true, exit: true)
        return out
    }

    /// (0.29) Leaving this region is one the trip watches for (auto-start): not one only "at school" added.
    static func exitStartsTrip(_ id: String, base: [RegionSpec]) -> Bool {
        base.contains { $0.id == id && $0.exit }
    }

    /// The stops, one per spot: a stop within 150 m of one already kept is the same place (at most three).
    static func merged(_ stops: [GeoPoint]) -> [GeoPoint] {
        var out: [GeoPoint] = []
        for s in stops where !out.contains(where: { Geo.metres($0, s) < mergeMetres }) {
            out.append(s)
            if out.count == 3 { break }
        }
        return out
    }

    /// Off the corridor: which role a region you left is (nil: not one of these).
    static func role(ofRegion id: String) -> Role? {
        if id == schoolId { return .school }
        if id == homePrefix || id.hasPrefix(homePrefix + ".") { return .home }
        return nil
    }
}
