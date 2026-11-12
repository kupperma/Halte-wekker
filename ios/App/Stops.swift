import CoreLocation
import Foundation

/// A stop you added yourself, for "Wake me at a single stop".
struct SavedStop: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var lat: Double
    var lon: Double
    var stopId: String?
    var place: Place {
        Place(key: "s-\(id)", name: name, short: Fmt.place(name), ids: [stopId ?? "\(lat),\(lon)"],
              coordinate: .init(latitude: lat, longitude: lon), spoken: Fmt.place(name))
    }
}

/// A stop on the live bus board (Transitous stop id).
struct BoardStop: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var short: String { name.range(of: ", ").map { String(name[$0.upperBound...]) } ?? name }
}

@MainActor
final class StopsStore: ObservableObject {
    static let shared = StopsStore()
    static let maxBoardStops = 3
    static let defaultBoard = [BoardStop(id: Place.veghel.ids[0], name: "Veghel, Busstation"), BoardStop(id: Place.veghel.ids[1], name: "Veghel, Bolkenplein")]
    static let defaultLines = ["305", "306", "158"]

    @Published private(set) var saved: [SavedStop]
    @Published var boardStops: [BoardStop] { didSet { persist() } }
    @Published var lines: [String] { didSet { persist() } }
    @Published private(set) var lastMode: [String: String]

    private init() {
        let d = UserDefaults.standard
        saved = d.data(forKey: "savedStops").flatMap { try? JSONDecoder().decode([SavedStop].self, from: $0) } ?? []
        boardStops = d.data(forKey: "boardStops").flatMap { try? JSONDecoder().decode([BoardStop].self, from: $0) } ?? Self.defaultBoard
        lines = d.stringArray(forKey: "boardLines") ?? Self.defaultLines
        lastMode = d.dictionary(forKey: "lastMode") as? [String: String] ?? [:]
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(try? JSONEncoder().encode(saved), forKey: "savedStops")
        d.set(try? JSONEncoder().encode(boardStops), forKey: "boardStops")
        d.set(lines, forKey: "boardLines")
        d.set(lastMode, forKey: "lastMode")
    }

    /// Veghel as the live board sees it: your board stops (the alarm still aims at the bus station).
    var veghel: Place {
        let ids = boardStops.map(\.id)
        return Place(key: "veghel", name: Place.veghel.name, short: "Veghel", ids: ids.isEmpty ? Place.veghel.ids : ids,
                     coordinate: Place.veghel.coordinate, spoken: "Veghel")
    }

    /// "Veghel: Busstation and Bolkenplein"
    var boardTitle: String {
        let st = boardStops
        guard st.count > 1 else { return st.first.map { "At \($0.name)" } ?? "" }
        let towns = st.map { $0.name.components(separatedBy: ",").first ?? "" }
        let names = st.map(\.short)
        let joined = names.dropLast().joined(separator: ", ") + " and " + names.last!
        if let t = towns.first, !t.isEmpty, towns.allSatisfy({ $0 == t }) { return "\(t): \(joined)" }
        return "At " + st.map(\.name).dropLast().joined(separator: ", ") + " and " + st.last!.name
    }

    func add(name: String, at c: CLLocationCoordinate2D, stopId: String? = nil) {
        saved.append(SavedStop(id: UUID().uuidString.prefix(8).lowercased(), name: name, lat: c.latitude, lon: c.longitude, stopId: stopId))
        persist()
    }
    func update(_ s: SavedStop) { if let i = saved.firstIndex(where: { $0.id == s.id }) { saved[i] = s; persist() } }
    func delete(_ id: String) { saved.removeAll { $0.id == id }; persist() }

    func mode(for p: Place) -> Mode { Mode(rawValue: lastMode[p.key] ?? "") ?? (p == .veghel || p == .buas ? .bus : .train) }
    func setMode(_ m: Mode, for p: Place) { lastMode[p.key] = m.rawValue; persist() }

    func reset() {
        saved = []; boardStops = Self.defaultBoard; lines = Self.defaultLines; lastMode = [:]
        persist()
    }
}
