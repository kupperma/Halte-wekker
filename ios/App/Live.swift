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
    private var loadedFor: Direction?
    private var busy = false
    private var lastPanels = Date.distantPast

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

    func refresh(_ dir: Direction, force: Bool = false) async {
        if busy && loadedFor == dir { return }
        if loadedFor != dir { next = []; board = []; trains = []; buas = []; toVeghel = []; pick = 0; nextError = nil; panelsUpdated = nil }
        if !force, loadedFor == dir, let u = updated, Date().timeIntervalSince(u) < 60 { return }
        busy = true; loadedFor = dir
        defer { busy = false }
        let trips = await Transit.nextTrips(dir)
        guard loadedFor == dir else { return }
        next = trips
        nextError = trips.isEmpty ? "No trips found right now. It tries again in a minute." : nil
        if pick >= trips.count { pick = 0 }
        updated = Date()
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
        if dir == .toSchool {
            async let b = Transit.board(stopIds: veghel.ids, from: now, n: 40)
            async let t1 = panel(.eindhoven, .breda, "RAIL", 8, 1)
            async let t2 = panel(.denBosch, .breda, "RAIL", 8, 1)
            async let u = panel(.breda, .buas, "BUS", 12, 0)
            async let g = boardGrades(veghel)
            let (bb, a, c, d, gg) = await (b, t1, t2, u, g)
            guard loadedFor == dir else { return }
            board = bb
            boardRides = gg
            trains = keepBest(a + c)
            buas = keepBest(d)
        } else {
            async let u = panel(.buas, .breda, "BUS", 12, 0)
            async let t1 = panel(.breda, .eindhoven, "RAIL", 8, 1)
            async let t2 = panel(.breda, .denBosch, "RAIL", 8, 1)
            async let v1 = panel(.denBosch, veghel, "BUS", 8, 0)
            async let v2 = panel(.eindhoven, veghel, "BUS", 8, 0)
            let (uu, a, c, d, e) = await (u, t1, t2, v1, v2)
            guard loadedFor == dir else { return }
            buas = keepBest(uu)
            trains = keepBest(a + c)
            toVeghel = keepBest(d + e)
        }
        panelsUpdated = Date()
        // Transitous now and then sends nothing back: try an empty list again at the next refresh (30 s), a few times.
        let empty = dir == .toSchool ? (board.isEmpty || trains.isEmpty || buas.isEmpty) : (buas.isEmpty || trains.isEmpty || toVeghel.isEmpty)
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
