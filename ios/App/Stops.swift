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
    /// Where it is (0.24: set by the setup, for the auto-start's regions around your home stops; older boards have none).
    var lat: Double? = nil
    var lon: Double? = nil
    var short: String { name.range(of: ", ").map { String(name[$0.upperBound...]) } ?? name }
}

@MainActor
final class StopsStore: ObservableObject {
    static let shared = StopsStore()
    static let maxBoardStops = 3
    /// The board and lines you start with (and get back on Reset everything): on the corridor today's Veghel bus
    /// station and Bolkenplein with the 305, 306 and 158; else none (the board is Home's stops, every line).
    static var defaultBoard: [BoardStop] {
        guard RoleSnapshot.corridor != nil else { return [] }
        let v = Place.legacyVeghel.ids
        return [BoardStop(id: v[0], name: "Veghel, Busstation"), BoardStop(id: v[1], name: "Veghel, Bolkenplein")]
    }
    static var defaultLines: [String] { RoleSnapshot.corridor != nil ? ["305", "306", "158"] : [] }

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
        RoleSnapshot.setBoard(boardStops.map(\.id))
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(try? JSONEncoder().encode(saved), forKey: "savedStops")
        d.set(try? JSONEncoder().encode(boardStops), forKey: "boardStops")
        d.set(lines, forKey: "boardLines")
        d.set(lastMode, forKey: "lastMode")
        RoleSnapshot.setBoard(boardStops.map(\.id))
    }

    /// Home as trips from it start: on the corridor your board stops (the alarm still aims at the bus station), else
    /// Home's own stops (`RoleLogic.homeBoard`).
    var homePlace: Place { Place.homeBoard }

    /// The stops the live board shows: yours, or Home's when you have none.
    var boardIds: [String] {
        let ids = boardStops.map(\.id)
        return ids.isEmpty ? Place.home.ids : ids
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

    func mode(for p: Place) -> Mode { Mode(rawValue: lastMode[p.key] ?? "") ?? (p == .home || p == .school ? .bus : .train) }
    func setMode(_ m: Mode, for p: Place) { lastMode[p.key] = m.rawValue; persist() }
    /// Home or School moved: the mode last picked for it goes (`RoleMove`).
    func forgetModes(_ roles: Set<RoleMove.Role>) {
        let kept = RoleMove.keepModes(lastMode, clearing: roles)
        guard kept != lastMode else { return }
        lastMode = kept; persist()
    }

    func reset() {
        saved = []; boardStops = Self.defaultBoard; lines = Self.defaultLines; lastMode = [:]
        persist()
    }

    /// The setup's Done (0.23): the home board's stops, and its lines (none: every line).
    func setBoard(_ stops: [BoardStop], lines l: [String]) {
        if boardStops != stops { boardStops = Array(stops.prefix(Self.maxBoardStops)) }
        if lines != l { lines = l }
    }

    /// The saved board, lines and modes again (your own put back after a test).
    func reload() {
        // (all read first: setting the board saves everything, the modes too)
        let d = UserDefaults.standard
        let board = d.data(forKey: "boardStops").flatMap { try? JSONDecoder().decode([BoardStop].self, from: $0) } ?? Self.defaultBoard
        let l = d.stringArray(forKey: "boardLines") ?? Self.defaultLines
        let modes = d.dictionary(forKey: "lastMode") as? [String: String] ?? [:]
        lastMode = modes
        boardStops = board
        lines = l
        persist()
    }
}
