import CoreLocation
import Foundation

/// A trip in one of the live lists, with the places it was planned between (for NS and Near me).
struct PanelTrip: Identifiable, Hashable {
    let trip: DoorTrip
    let from: Place
    let to: Place
    var id: String { trip.id }
}

/// What a bus on the Veghel board does: how long it takes to the station and when it gets there.
struct BoardRide: Hashable {
    let minutes: Double
    let station: String
    let arrival: Date
    let grade: String?
    var best: Double? = nil         // the fastest seen on this stretch, for the rank's numbers
}

/// Live times for the home screen: your next door-to-door trip and the lists per leg.
@MainActor
final class LiveStore: ObservableObject {
    @Published private(set) var next: [DoorTrip] = []
    @Published private(set) var nextError: String?
    @Published private(set) var board: [BoardDeparture] = []
    @Published private(set) var boardRides: [String: BoardRide] = [:]       // by "stopId|tripId"
    @Published private(set) var trains: [PanelTrip] = []
    @Published private(set) var buas: [PanelTrip] = []
    @Published private(set) var toVeghel: [PanelTrip] = []
    @Published private(set) var updated: Date?
    @Published private(set) var panelsUpdated: Date?
    @Published var pick = 0
    @Published var lineFilter = "mine"          // "mine", one line, or "all"
    @Published var stopFilter = "all"           // "all" or a board stop id
    /// Also show the ones that left in the last half hour (and cancelled ones), to see what happened.
    @Published var showEarlier = false
    private var emptyRetries = 0
    private var loadedFor: String?             // the direction, where you're going and where from
    private var busy = false
    private var lastPanels = Date.distantPast

    // MARK: from wherever you are

    /// Somewhere you picked to go yourself (nil: school or home, by the direction).
    @Published private(set) var custom: Destination? = LiveStore.saved("customDest")
    @Published private(set) var recents: [Destination] = LiveStore.saved("recentDests") ?? []
    /// Where you are, when trips start from there: you're away from your usual start (Veghel, or BUas going home),
    /// or going somewhere you picked. Nil: trips start from your usual place.
    @Published private(set) var here: CLLocation?
    @Published private(set) var nearStops: [Transit.NearStop] = []
    @Published private(set) var nearBoard: [BoardDeparture] = []     // what leaves from the stops around you
    private var lastSeen: CLLocation?
    private var plannedFrom: CLLocation?
    private var nearAt: (CLLocation, Date)?
    /// Trips from where you are, not one of your two routes (so the boards show what's around you).
    var anywhere: Bool { here != nil || custom != nil }

    nonisolated private static func saved<T: Decodable>(_ k: String) -> T? { UserDefaults.standard.data(forKey: k).flatMap { try? JSONDecoder().decode(T.self, from: $0) } }

    /// Go somewhere you picked (nil: back to school or home).
    func go(to d: Destination?) {
        custom = d
        UserDefaults.standard.set(d.flatMap { try? JSONEncoder().encode($0) }, forKey: "customDest")
        if let d {
            recents = Array(([d] + recents.filter { $0.id != d.id }).prefix(6))
            UserDefaults.standard.set(try? JSONEncoder().encode(recents), forKey: "recentDests")
        }
    }

    /// Where you're going: your pick, or school or home.
    func destination(_ dir: Direction) -> Place { custom?.place ?? (dir == .toSchool ? .buas : .veghel) }

    /// The stops near you (the two nearest bus stops, both sides, and the nearest station) and what leaves from them.
    private func loadNear(_ h: CLLocation) async {
        if nearAt.map({ h.distance(from: $0.0) > 150 || Date().timeIntervalSince($0.1) > 600 }) ?? true {
            let s = await Transit.nearStops(h.coordinate)
            if !s.isEmpty {
                let names = s.filter { !$0.rail }.map(\.name).reduce(into: [String]()) { if !$0.contains($1) && $0.count < 2 { $0.append($1) } }
                nearStops = s.filter { !$0.rail && names.contains($0.name) } + (s.first(where: { $0.rail }).map { [$0] } ?? [])
                nearAt = (h, Date())
            }
        }
        guard !nearStops.isEmpty else { return }
        let b = await Transit.board(stopIds: nearStops.map(\.id), from: Date().addingTimeInterval(-10 * 60), n: 14)
        if !b.isEmpty { nearBoard = b.sorted { $0.time < $1.time } }
    }

    var stops: StopsStore { StopsStore.shared }

    /// The board after the chips: your lines (or one, or all) at your stops (or one).
    var boardShown: [BoardDeparture] {
        let lines = stops.lines
        let now = Date()
        var l = board.filter { d in
            showEarlier ? d.time > now.addingTimeInterval(-30 * 60) || d.scheduled > now.addingTimeInterval(-30 * 60)
                        : d.time > now.addingTimeInterval(-60) || (d.cancelled && d.scheduled > now.addingTimeInterval(-15 * 60))
        }
        if stopFilter != "all" { l = l.filter { $0.stopId == stopFilter } }
        if lineFilter == "mine" && !lines.isEmpty { l = l.filter { lines.contains($0.line) } }
        else if lineFilter != "mine" && lineFilter != "all" { l = l.filter { $0.line == lineFilter } }
        return Array(l.prefix(showEarlier ? 24 : 12))
    }

    func refresh(_ dir: Direction, at loc: CLLocation? = nil, force: Bool = false) async {
        if let loc { lastSeen = loc }
        // Away from your usual start (or going somewhere you picked): trips start from where you are.
        // Going to school, anywhere in Veghel counts as home (your Veghel bus board); going home, only the BUas campus
        // counts as school, so anywhere else in Breda the trip starts from where you are.
        let usual: Place = dir == .toSchool ? .veghel : .buas
        let radius = dir == .toSchool ? 2500.0 : 500.0
        let away = lastSeen.map { $0.distance(from: CLLocation(latitude: usual.coordinate.latitude, longitude: usual.coordinate.longitude)) > radius } ?? false
        let from: CLLocation? = (away || custom != nil) ? lastSeen : nil
        let key = "\(dir.rawValue)|\(custom?.id ?? "")|\(from == nil ? "usual" : "here")"
        if busy && loadedFor == key { return }
        if loadedFor != key {
            next = []; board = []; trains = []; buas = []; toVeghel = []; nearBoard = []; pick = 0; nextError = nil; panelsUpdated = nil; updated = nil
            lastPanels = .distantPast
        }
        let moved = from.flatMap { f in plannedFrom.map { f.distance(from: $0) > 300 } } ?? false
        if !force, !moved, loadedFor == key, let u = updated, Date().timeIntervalSince(u) < 60 { return }
        busy = true; loadedFor = key; here = from
        defer { busy = false }
        let trips: [DoorTrip]
        if let f = from { plannedFrom = f; trips = await Transit.tripsFrom(f.coordinate, to: destination(dir)) }
        else if custom != nil { trips = await Transit.tripsFrom(usual.coordinate, to: destination(dir)) }
        else { trips = await Transit.nextTrips(dir) }
        guard loadedFor == key else { return }
        // One empty answer from Transitous doesn't wipe what you had: keep the trips that haven't left yet, and ask again sooner.
        next = trips.isEmpty ? next.filter { $0.first.departure > Date().addingTimeInterval(-60) } : trips
        nextError = next.isEmpty ? "No trips found right now. It tries again in a minute." : nil
        if pick >= next.count { pick = 0 }
        updated = trips.isEmpty ? Date().addingTimeInterval(-40) : Date()
        // From anywhere: the stops around you instead of the lists for your two routes.
        if anywhere {
            if let f = from { await loadNear(f) }
            guard loadedFor == key else { return }
            panelsUpdated = Date()
            return
        }
        // The lists per leg every two minutes (Transitous is volunteer-run).
        guard force || Date().timeIntervalSince(lastPanels) > 120 else { return }
        lastPanels = Date()
        let now = Date().addingTimeInterval(-30 * 60)          // from half an hour ago, for "Show earlier"
        let veghel = stops.veghel
        func panel(_ a: Place, _ b: Place, _ modes: String, _ n: Int, _ maxT: Int) async -> [PanelTrip] {
            let l = await Transit.plan(from: a, to: b, modes: modes, at: now, count: n, maxTransfers: maxT)
            Ratings.shared.learn(a, b, l)
            return l.map { PanelTrip(trip: $0, from: a, to: b) }
        }
        func keepBest(_ l: [PanelTrip]) -> [PanelTrip] {
            // Drop an option when one that leaves later still gets you there as early.
            l.filter { o in !l.contains { q in q.id != o.id && q.from == o.from && q.to == o.to && q.trip.first.departure > o.trip.first.departure && q.trip.end <= o.trip.end } }
                .sorted { $0.trip.first.departure < $1.trip.first.departure }
        }
        var empty = false
        if dir == .toSchool {
            async let b = Transit.board(stopIds: veghel.ids, from: now, n: 40)
            async let t1 = panel(.eindhoven, .breda, "RAIL", 8, 1)
            async let t2 = panel(.denBosch, .breda, "RAIL", 8, 1)
            async let u = panel(.breda, .buas, "BUS", 12, 0)
            async let g = boardGrades(veghel)
            let (bb, a, c, d, gg) = await (b, t1, t2, u, g)
            guard loadedFor == key else { return }
            empty = bb.isEmpty || (a + c).isEmpty || d.isEmpty
            if !bb.isEmpty { board = bb }                       // (an empty answer keeps the last list)
            if !gg.isEmpty { boardRides = gg }
            if !(a + c).isEmpty { trains = keepBest(a + c) }
            if !d.isEmpty { buas = keepBest(d) }
        } else {
            async let u = panel(.buas, .breda, "BUS", 12, 0)
            async let t1 = panel(.breda, .eindhoven, "RAIL", 8, 1)
            async let t2 = panel(.breda, .denBosch, "RAIL", 8, 1)
            async let v1 = panel(.denBosch, veghel, "BUS", 8, 0)
            async let v2 = panel(.eindhoven, veghel, "BUS", 8, 0)
            let (uu, a, c, d, e) = await (u, t1, t2, v1, v2)
            guard loadedFor == key else { return }
            empty = uu.isEmpty || (a + c).isEmpty || (d + e).isEmpty
            if !uu.isEmpty { buas = keepBest(uu) }
            if !(a + c).isEmpty { trains = keepBest(a + c) }
            if !(d + e).isEmpty { toVeghel = keepBest(d + e) }
        }
        panelsUpdated = Date()
        // Transitous now and then sends nothing back: try an empty list again at the next refresh (30 s), a few times.
        if empty && emptyRetries < 3 { emptyRetries += 1; lastPanels = .distantPast } else if !empty { emptyRetries = 0 }
        let rail = trains
        Task { await NSStore.shared.enrich(rail.map { ($0.trip, $0.from, $0.to) }) }
    }

    /// The board has no arrival times, so ask the planner how long each bus takes to the stations.
    private func boardGrades(_ veghel: Place) async -> [String: BoardRide] {
        var out: [String: BoardRide] = [:]
        let at = Date().addingTimeInterval(-120)
        for id in veghel.ids {
            for st in [Place.eindhoven, Place.denBosch] {
                let l = await Transit.plan(from: id, to: st.ids[0], modes: "BUS", at: at, count: 8, maxTransfers: 0)
                Ratings.shared.learn(veghel, st, l.filter { $0.first.walkBefore == 0 })
                for t in l where t.first.walkBefore == 0 {           // a bus from the other Veghel stop has a walk first
                    let k = "\(id)|\(t.first.tripId)"
                    if out[k] == nil {
                        out[k] = BoardRide(minutes: t.rideMinutes, station: Fmt.place(t.last.toStop), arrival: t.last.arrival, grade: t.first.grade,
                                             best: Ratings.shared.best("\(t.first.fromId)>\(t.first.toStop)"))
                    }
                }
            }
        }
        return out
    }
}
