import CoreLocation
import Foundation
import os

/// Your Home and School as roles, for any thread: the planner's background closures read them as well as the screens.
/// The stores hand in what the roles are made of (`PlacesStore` its Home and School, `StopsStore` the board's stops,
/// `ProfileStore` the corridor and hints) whenever they save; this never reads a store, so no store's start waits on
/// another's. Until the first store says anything it is today's (0.21) Veghel ⇄ BUas.
enum RoleSnapshot {
    private struct State: Sendable {
        var inputs: RoleInputs
        var roles: Roles
    }

    private static let lock = OSAllocatedUnfairLock(initialState: State(inputs: .legacy, roles: RoleLogic.roles(.legacy)))

    static var current: Roles { lock.withLock { $0.roles } }
    static var corridor: Corridor? { current.corridor }

    static func setPlaces(home: SavedPlace?, school: SavedPlace?) {
        lock.withLock { s in
            s.inputs.home = home; s.inputs.school = school
            s.roles = RoleLogic.roles(s.inputs)
        }
    }

    static func setBoard(_ ids: [String]) {
        lock.withLock { s in
            s.inputs.boardIds = ids
            s.roles = RoleLogic.roles(s.inputs)
        }
    }

    static func setProfile(corridor: Corridor?, hints: [String]) {
        lock.withLock { s in
            s.inputs.corridor = corridor; s.inputs.calendarHints = hints
            s.roles = RoleLogic.roles(s.inputs)
        }
    }
}

extension Place {
    init(_ r: RolePlace) {
        self.init(key: r.key, name: r.name, short: r.short, ids: r.ids,
                  coordinate: CLLocationCoordinate2D(latitude: r.lat, longitude: r.lon), spoken: r.spoken)
    }

    var point: GeoPoint { GeoPoint(lat: coordinate.latitude, lon: coordinate.longitude) }
}

extension RoleWords {
    /// The words for your school and home now.
    static var current: RoleWords { RoleSnapshot.current.words }
}

extension Notification.Name {
    /// Home or School moved somewhere else (`RoleMove`): what was learnt for the old place is gone; plan again.
    static let rolesMoved = Notification.Name("haltewekker.rolesMoved")
}
