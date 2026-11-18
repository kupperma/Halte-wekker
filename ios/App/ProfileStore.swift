import Foundation

/// Your profile (`profile.v1`): set up or not, the corridor, where your timetable comes from. Loaded first thing at
/// launch (`HaltewekkerApp.init`), before any other store: `PlacesStore` saves its seed as soon as it starts, and that
/// would make a new install look like someone who used the app before.
@MainActor
final class ProfileStore: ObservableObject {
    static let shared = ProfileStore()
    @Published private(set) var profile: Profile

    private init() {
        let d = UserDefaults.standard
        let saved = ProfileLogic.decode(d.data(forKey: ProfileLogic.storageKey))
        let existing = ProfileLogic.isExistingUser(keys: Set(d.dictionaryRepresentation().keys))
        let places = PlacesLogic.decode(d.data(forKey: PlacesLogic.storageKey))
        profile = saved ?? ProfileLogic.load(data: nil, existing: existing, places: places)
        RoleSnapshot.setProfile(corridor: profile.corridor, hints: profile.calendarHints)
        guard saved == nil else { return }
        // The first launch with profiles: an earlier version's user whose Home or School was already moved in Your
        // places (0.21 didn't use it) gets what was learnt for the old one cleared, as for any move.
        if existing, let places {
            let moved = RoleMove.moves(from: Self.legacyPlaces, to: places)
            if !moved.isEmpty { Self.clearLearnt(moved) }
        }
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(ProfileLogic.encode(profile), forKey: ProfileLogic.storageKey)
        RoleSnapshot.setProfile(corridor: profile.corridor, hints: profile.calendarHints)
    }

    /// Today's (0.21) Home and School, as places, to tell whether yours are still there.
    private static var legacyPlaces: [SavedPlace] {
        let h = RoleLogic.legacyHome, s = RoleLogic.legacySchool
        return [SavedPlace(id: "home", name: "Home", kind: .home, lat: h.lat, lon: h.lon),
                SavedPlace(id: "school", name: s.short, kind: .school, lat: s.lat, lon: s.lon)]
    }

    /// Your places changed (`PlacesStore` saved them). Home or School moved more than 400 m: the corridor is worked out
    /// again, what was learnt for the old place goes (wake distances, the mode, where it last saw you at home, the
    /// saved answers), and the school week and the regions are planned again (`rolesMoved`).
    func placesChanged(from old: [SavedPlace], to new: [SavedPlace]) {
        let moved = RoleMove.moves(from: old, to: new)
        guard !moved.isEmpty else { return }
        if let h = new.first(where: { $0.kind == .home }), let s = new.first(where: { $0.kind == .school }) {
            let c = ProfileLogic.corridor(home: h.point, school: s.point)
            if c != profile.corridor { profile.corridor = c; persist() }
        }
        Self.clearLearnt(moved)
        StopsStore.shared.forgetModes(moved)
        NotificationCenter.default.post(name: .rolesMoved, object: nil, userInfo: ["roles": moved.map(\.rawValue)])
        Task { await SchoolAlarm.shared.refresh(force: true, now: true) }
    }

    /// What the saved data keeps for a role (the stores that hold some of it in memory follow `rolesMoved`).
    private static func clearLearnt(_ roles: Set<RoleMove.Role>) {
        let d = UserDefaults.standard
        if let km = d.dictionary(forKey: "kmMem") as? [String: Double] { d.set(RoleMove.keepKm(km, clearing: roles), forKey: "kmMem") }
        if let m = d.dictionary(forKey: "lastMode") as? [String: String] { d.set(RoleMove.keepModes(m, clearing: roles), forKey: "lastMode") }
        for k in RoleMove.defaultsKeys(clearing: roles) { d.removeObject(forKey: k) }
        // the saved answers (trips, boards, the lists per leg) were for the old place (a few small files)
        SnapshotStore.shared.prune(olderThan: 0)
    }
}
