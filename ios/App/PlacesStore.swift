import CoreLocation
import SwiftUI

/// Your places (Home, School, pinned ones), saved on the phone. Home and School are the roles everything plans with
/// (`Place.home`, `Place.school`: `RoleSnapshot` gets them on every save); the quick chips and Plan read the list.
/// Seeded once from today's defaults.
@MainActor
final class PlacesStore: ObservableObject {
    static let shared = PlacesStore()
    @Published private(set) var list: [SavedPlace]

    private init() {
        list = PlacesLogic.load(UserDefaults.standard.data(forKey: PlacesLogic.storageKey), seed: Self.seed())
        if UserDefaults.standard.data(forKey: PlacesLogic.storageKey) == nil { persist() } else { pushRoles() }
    }

    /// Today's defaults: Home is your Veghel board stops, School is BUas (0.21's seed, from the constants: never from
    /// the roles, which may be a Home of your own). Without the corridor (0.23's setup makes those) there's nothing
    /// to go back to: Home and School stay as they are.
    private static func seed() -> [SavedPlace] {
        let v = Place.legacyVeghel, b = Place.legacyBuas
        let board = StopsStore.shared.boardStops.map(\.id)
        return PlacesLogic.seed(
            home: SavedPlace(id: "home", name: "Home", kind: .home, lat: v.coordinate.latitude, lon: v.coordinate.longitude,
                             stopIds: board.isEmpty ? v.ids : board),
            school: SavedPlace(id: "school", name: b.short, kind: .school, lat: b.coordinate.latitude, lon: b.coordinate.longitude, stopIds: b.ids))
    }

    private func persist() {
        UserDefaults.standard.set(PlacesLogic.encode(list), forKey: PlacesLogic.storageKey)
        pushRoles()
    }
    private func pushRoles() { RoleSnapshot.setPlaces(home: home, school: school) }

    var home: SavedPlace? { list.first { $0.kind == .home } }
    var school: SavedPlace? { list.first { $0.kind == .school } }
    var chips: [SavedPlace] { PlacesLogic.chips(list) }

    func add(name: String, lat: Double, lon: Double, stopIds: [String]) {
        list.append(SavedPlace(id: PlacesLogic.newId(list, seed: String(UUID().uuidString.prefix(6)).lowercased()), name: name, kind: .custom,
                               lat: lat, lon: lon, stopIds: stopIds))
        persist()
    }
    /// A changed place. Home or School moved somewhere else (over 400 m): what was learnt for the old one goes, and the
    /// school week and the regions are planned again (`ProfileStore.placesChanged`).
    func update(_ p: SavedPlace) {
        guard let i = list.firstIndex(where: { $0.id == p.id }) else { return }
        let old = list
        list[i] = p; persist()
        ProfileStore.shared.placesChanged(from: old, to: list)
    }
    /// Reset everything: back to today's defaults on the corridor; else Home and School stay (the pinned places go).
    func reset() {
        let old = list
        if ProfileStore.shared.profile.corridor != nil { list = Self.seed() } else { list = [home, school].compactMap { $0 } }
        persist()
        ProfileStore.shared.placesChanged(from: old, to: list)
    }
    func remove(_ id: String) { list = PlacesLogic.remove(list, id: id); persist() }
    /// The setup's Done (0.23): all your places at once. Home or School somewhere else: what was learnt for the old
    /// one goes, as for any move.
    func replaceAll(_ new: [SavedPlace]) {
        let old = list
        list = PlacesLogic.load(PlacesLogic.encode(new), seed: old)
        persist()
        ProfileStore.shared.placesChanged(from: old, to: list)
    }
    /// The saved list again (your own put back after a test; the caller clears what was learnt).
    func reload() {
        list = PlacesLogic.load(UserDefaults.standard.data(forKey: PlacesLogic.storageKey), seed: Self.seed())
        pushRoles()
    }
    func move(from: Int, to: Int) { list = PlacesLogic.move(list, from: from, to: to); persist() }

    /// The place to plan to: Home and School are always the roles (Home as trips from it start, your board stops on
    /// the corridor), so Fastest trip, the school alarm's trip and Be there by go wherever you put them.
    func place(_ p: SavedPlace) -> Place {
        switch p.kind {
        case .home: return Place.homeBoard
        case .school: return Place.school
        case .custom:
            return Place(key: "p:\(p.id)", name: p.name, short: p.name, ids: p.stopIds.isEmpty ? ["\(p.lat),\(p.lon)"] : p.stopIds,
                         coordinate: .init(latitude: p.lat, longitude: p.lon), spoken: p.name)
        }
    }

    /// Is this place your Home or School (the trips the planned-trip reminders know)?
    func direction(of p: SavedPlace) -> Direction? {
        switch p.kind {
        case .home: return .home
        case .school: return .toSchool
        case .custom: return nil
        }
    }
}
