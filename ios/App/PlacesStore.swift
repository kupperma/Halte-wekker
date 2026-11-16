import CoreLocation
import SwiftUI

/// Your places (Home, School, pinned ones), saved on the phone. The quick chips and Plan's suggestions read it. Seeded
/// once from today's defaults; today's trip direction and school schedule don't read it (they work as before).
@MainActor
final class PlacesStore: ObservableObject {
    static let shared = PlacesStore()
    @Published private(set) var list: [SavedPlace]

    private init() {
        list = PlacesLogic.load(UserDefaults.standard.data(forKey: PlacesLogic.storageKey), seed: Self.seed())
        if UserDefaults.standard.data(forKey: PlacesLogic.storageKey) == nil { persist() }
    }

    /// Today's defaults: Home is your Veghel board stops, School is BUas.
    private static func seed() -> [SavedPlace] {
        let v = StopsStore.shared.veghel, b = Place.buas
        return PlacesLogic.seed(
            home: SavedPlace(id: "home", name: "Home", kind: .home, lat: v.coordinate.latitude, lon: v.coordinate.longitude, stopIds: v.ids),
            school: SavedPlace(id: "school", name: b.short, kind: .school, lat: b.coordinate.latitude, lon: b.coordinate.longitude, stopIds: b.ids))
    }

    private func persist() { UserDefaults.standard.set(PlacesLogic.encode(list), forKey: PlacesLogic.storageKey) }

    var home: SavedPlace? { list.first { $0.kind == .home } }
    var school: SavedPlace? { list.first { $0.kind == .school } }
    var chips: [SavedPlace] { PlacesLogic.chips(list) }

    func add(name: String, lat: Double, lon: Double, stopIds: [String]) {
        list.append(SavedPlace(id: PlacesLogic.newId(list, seed: String(UUID().uuidString.prefix(6)).lowercased()), name: name, kind: .custom,
                               lat: lat, lon: lon, stopIds: stopIds))
        persist()
    }
    func update(_ p: SavedPlace) {
        guard let i = list.firstIndex(where: { $0.id == p.id }) else { return }
        list[i] = p; persist()
    }
    /// Reset everything: back to today's defaults.
    func reset() { list = Self.seed(); persist() }
    func remove(_ id: String) { list = PlacesLogic.remove(list, id: id); persist() }
    func move(from: Int, to: Int) { list = PlacesLogic.move(list, from: from, to: to); persist() }

    /// The place to plan to. Home and School, while they're still about where today's defaults are, are today's own
    /// places (so Fastest trip, the school alarm's trip and Be there by behave exactly as before).
    func place(_ p: SavedPlace) -> Place {
        let here = CLLocation(latitude: p.lat, longitude: p.lon)
        func near(_ q: Place) -> Bool { here.distance(from: CLLocation(latitude: q.coordinate.latitude, longitude: q.coordinate.longitude)) < 400 }
        if p.kind == .home, near(.veghel) { return StopsStore.shared.veghel }
        if p.kind == .school, near(.buas) { return .buas }
        return Place(key: "p:\(p.id)", name: p.name, short: p.name, ids: p.stopIds.isEmpty ? ["\(p.lat),\(p.lon)"] : p.stopIds,
                     coordinate: .init(latitude: p.lat, longitude: p.lon), spoken: p.name)
    }

    /// Is this place today's Home or School (the trips the planned-trip reminders know)?
    func direction(of p: SavedPlace) -> Direction? {
        let pl = place(p)
        if pl.key == Place.veghel.key { return .home }
        if pl.key == Place.buas.key { return .toSchool }
        return nil
    }
}
