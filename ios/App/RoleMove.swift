import Foundation

/// When Home or School moves somewhere else (more than 400 m), what was learnt for the old one goes: the wake
/// distances for its stop, the mode last picked for it, where the school alarm last saw you at home. The rules only;
/// the app clears them (and the saved answers, and plans the school week and the regions again).
enum RoleMove {
    enum Role: String, Sendable, CaseIterable {
        case home, school
        /// The role's key in saved data ("veghel", "buas").
        var key: String { self == .home ? RoleLogic.homeKey : RoleLogic.schoolKey }
    }

    /// Further than this is a move (closer is the same place, a stop across the road).
    static let radius = 400.0

    static func moved(from a: GeoPoint, to b: GeoPoint) -> Bool { Geo.metres(a, b) > radius }

    /// The roles that moved between two lists of places (a role missing on either side didn't move).
    static func moves(from old: [SavedPlace], to new: [SavedPlace]) -> Set<Role> {
        var out = Set<Role>()
        for (role, kind) in [(Role.home, SavedPlace.Kind.home), (.school, .school)] {
            guard let a = old.first(where: { $0.kind == kind }), let b = new.first(where: { $0.kind == kind }) else { continue }
            if moved(from: a.point, to: b.point) { out.insert(role) }
        }
        return out
    }

    /// The wake distances to keep: not those for the role's stop ("bus:veghel", "train:buas").
    static func keepKm(_ km: [String: Double], clearing roles: Set<Role>) -> [String: Double] {
        km.filter { k, _ in !roles.contains { k.hasSuffix(":\($0.key)") } }
    }

    /// The modes last picked per place to keep: not the role's own.
    static func keepModes(_ modes: [String: String], clearing roles: Set<Role>) -> [String: String] {
        modes.filter { k, _ in !roles.contains { $0.key == k } }
    }

    /// The saved keys that go with a move: where the school alarm last saw you at home goes when Home moves.
    static func defaultsKeys(clearing roles: Set<Role>) -> [String] {
        roles.contains(.home) ? ["school.homeLat", "school.homeLon"] : []
    }
}
