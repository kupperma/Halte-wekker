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
    private var lastMoving: Date?               // when you last went at bus or train speed
    /// The bus or train you're on now (you're moving, and its live position is right where you are).
    @Published private(set) var onBoard: OnBoard?
    struct OnBoard: Equatable {
        let vehicle: Vehicle
        let to: String              // where it's going
        let next: String            // its next stop
    }
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

    /// You're on a bus or train: find it (its live position closest to you), then plan from its next stop, from when it
    /// gets there, so your trip carries on with it (or changes there) instead of starting with one you'd still have to catch.
    /// The latest ride of `rides` you can get to by staying on (its stops from `next` on): which one, the stop, and when
    /// you're there. In time means a couple of minutes to change (more if it's a walk).
    nonisolated static func staysOn(_ stops: [TripStop], from next: TripStop, until rides: [Ride]) -> (Int, TripStop, Date)? {
        guard rides.count >= 2 else { return nil }
        let ahead = stops.drop(while: { !($0.name == next.name && $0.arrival == next.arrival) })
        for k in stride(from: rides.count - 1, through: 1, by: -1) {
            let r = rides[k]
            guard let a = r.fromLat, let o = r.fromLon else { continue }
            let at = CLLocation(latitude: a, longitude: o)
            if let s = ahead.first(where: { at.distance(from: CLLocation(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)) < 400 }),
               let arr = s.arrival, arr <= r.departure.addingTimeInterval(-Double(max(2, r.walkBefore + 1)) * 60) {
                return (k, s, arr)
            }
        }
        return nil
    }

    /// A GPS fix good enough to tell speed from (inside a station they're often off by 50 m and more).
    nonisolated static func goodFix(_ l: CLLocation) -> Bool { l.horizontalAccuracy >= 0 && l.horizontalAccuracy <= 40 }
    /// The GPS itself says bus or train speed, and is sure of it.
    /// (The GPS's speed comes from the Doppler shift, not from positions, so it's good even when the position isn't, as in
    /// a train: then a sure speed is enough. Without a speed accuracy it wants a good position.)
    nonisolated static func movingFix(_ l: CLLocation) -> Bool {
        guard l.speed >= 5, l.horizontalAccuracy >= 0, l.horizontalAccuracy <= 100 else { return false }
        return l.speedAccuracy >= 0 ? l.speedAccuracy < 2.5 : goodFix(l)
    }

    /// How far a bus or train can be from where its times put it and still be the one you're on: further the faster
    /// you go (at 130 km/h, half a minute off its times is a kilometre).
    nonisolated static func matchTolerance(train: Bool, speed: Double) -> Double {
        let v = max(0, speed)
        return train ? min(2500, max(600, v * 60)) : min(1000, max(400, v * 45))
    }

    /// `tripId`: plan from that one (the bus it now knows you're on), not just the nearest.
    /// `wasMoving`: you were going at train or bus speed just now (stopped at a signal, or slowing down): not "standing".
    /// `late` (with `tripId`): it was found by the road you're on, this many seconds off its times: its next stop is the
    /// next one ahead by its times moved by that much (its timetable position may be kilometres from you).
    static func onBoardTrips(_ f: CLLocation, to dest: Place, tripId: String? = nil, wasMoving: Bool = false,
                             late: TimeInterval? = nil, line: String? = nil, isTrain: Bool? = nil) async -> (OnBoard, [DoorTrip])? {
        let now = Date()
        if let tripId, let late {
            let stops = await Transit.tripStops(tripId)
            guard let next = stops.first(where: { ($0.arrival ?? .distantPast).addingTimeInterval(late) > now.addingTimeInterval(20) }) else { return nil }
            return await plans(from: f, tripId: tripId, line: line ?? "?", isTrain: isTrain ?? false, toName: stops.last?.name ?? "",
                               stops: stops, next: next, at: (next.arrival ?? now).addingTimeInterval(late), to: dest)
        }
        let still = f.speed < 3 && !wasMoving       // standing or walking now (or no speed): then it has to be right with you
        let speedNow = wasMoving ? max(f.speed, 15) : f.speed
        let segs = await Transit.vehicles(near: f.coordinate, radiusDeg: tripId == nil && speedNow < 15 ? 0.02 : 0.04)
        var best: (VehicleSegment, Double)?
        for s in segs {
            if let tripId, s.tripId != tripId { continue }
            guard let p = s.position(at: now) else { continue }
            // going your way, by the GPS's heading while you're moving (not one passing the other way)
            if tripId == nil, f.course >= 0, f.speed >= 3,
               let a = s.position(at: now.addingTimeInterval(-15)), let b = s.position(at: now.addingTimeInterval(15)),
               CLLocation(latitude: a.latitude, longitude: a.longitude).distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude)) > 20 {
                var turn = abs(Heading.bearing(a, b) - f.course).truncatingRemainder(dividingBy: 360)
                if turn > 180 { turn = 360 - turn }
                if turn > 75 { continue }
            }
            let d = f.distance(from: CLLocation(latitude: p.latitude, longitude: p.longitude))
            let tol = tripId != nil ? 4000 : still ? 250 : matchTolerance(train: s.isTrain, speed: speedNow)
            if d < tol, best == nil || d < best!.1 { best = (s, d) }
        }
        guard let seg = best?.0 else { return nil }
        let stops = await Transit.tripStops(seg.tripId)
        guard let next = stops.first(where: { ($0.arrival ?? .distantPast) > now.addingTimeInterval(20) }) else { return nil }
        // Standing still and it's coming to where you are: you're at its stop (a bus station by the train station), not on it.
        if tripId == nil, still, f.distance(from: CLLocation(latitude: next.coordinate.latitude, longitude: next.coordinate.longitude)) < 350 { return nil }
        return await plans(from: f, tripId: seg.tripId, line: seg.line, isTrain: seg.isTrain, toName: seg.toName, stops: stops, next: next, at: next.arrival ?? now, to: dest)
    }

    /// The ways on from the bus or train you're on: from its next stop, from when it gets there (staying on when it goes
    /// where a later ride leaves).
    private static func plans(from f: CLLocation, tripId: String, line: String, isTrain: Bool, toName: String,
                              stops: [TripStop], next: TripStop, at: Date, to dest: Place) async -> (OnBoard, [DoorTrip])? {
        let now = Date()
        var its: [DoorTrip] = []
        for b in dest.ids {
            its += await Transit.plan(from: "\(next.coordinate.latitude),\(next.coordinate.longitude)", to: b, modes: nil, at: at.addingTimeInterval(-60), count: 5, maxTransfers: 4)
        }
        let v = Vehicle(tripId: tripId, line: isTrain ? Transit.trainLabel(line) : line, isTrain: isTrain)
        func onIt(to name: String, lat: Double?, lon: Double?, arrival: Date, scheduled: Date) -> Ride {
            Ride(tripId: tripId, line: v.line, name: line, isTrain: isTrain, departure: now, scheduledDeparture: now,
                 arrival: arrival, scheduledArrival: scheduled, fromStop: "On board", fromId: "onboard", toStop: name, platform: nil,
                 live: true, cancelled: false, walkBefore: 0,
                 fromLat: f.coordinate.latitude, fromLon: f.coordinate.longitude, toLat: lat, toLon: lon)
        }
        var seen = Set<String>()
        let all: [DoorTrip] = its.compactMap { t in
            guard t.first.departure >= at.addingTimeInterval(-120) else { return nil }
            var rides = t.rides
            if rides.first?.tripId == tripId {
                let r = rides.removeFirst()          // it stays on: the ride you're on goes on to where you get off
                rides.insert(onIt(to: r.toStop, lat: r.toLat, lon: r.toLon, arrival: r.arrival, scheduled: r.scheduledArrival), at: 0)
            } else if let hit = Self.staysOn(stops, from: next, until: rides) {
                let (k, s, arr) = hit
                // The one you're on also gets to where a later ride leaves, in time for it: stay on until there. (The
                // planner, from its next stop, likes a later one from there best: a Sprinter to Tilburg, then an Intercity
                // to Breda, when the Sprinter goes to Breda anyway and makes the same bus.)
                rides = [onIt(to: s.name, lat: s.coordinate.latitude, lon: s.coordinate.longitude, arrival: arr, scheduled: arr)] + rides[k...]
            } else {
                rides.insert(onIt(to: next.name, lat: next.coordinate.latitude, lon: next.coordinate.longitude, arrival: at, scheduled: at), at: 0)
            }
            return DoorTrip(rides: rides, start: now, end: t.end)
        }
        .filter { seen.insert($0.id).inserted }
        .sorted { $0.end < $1.end }
        guard !all.isEmpty else { return nil }
        return (OnBoard(vehicle: v, to: Fmt.place(stops.last?.name ?? toName), next: Fmt.place(next.name)), Array(all.prefix(4)))
    }

    /// The buses and trains whose road you're on and that go your way, nearest to their own times first. Found by the
    /// road, not by where their times put them: one running a few minutes late or early (twelve at most) is kilometres
    /// from its timetable position, but it's on this road, going this way, about now.
    static func vehiclesByRoad(_ f: CLLocation) async -> [(tripId: String, line: String, isTrain: Bool, late: TimeInterval)] {
        guard f.course >= 0, f.speed >= 3 else { return [] }
        let segs = await Transit.vehicles(near: f.coordinate, radiusDeg: 0.012, back: 12 * 60, ahead: 12 * 60)
        let now = Date()
        var best: [String: (line: String, isTrain: Bool, late: TimeInterval)] = [:]
        for s in segs where s.path.count >= 2 {
            guard let p = project(f.coordinate, on: s.path), p.metres < 100 else { continue }
            var turn = abs(p.bearing - f.course).truncatingRemainder(dividingBy: 360)
            if turn > 180 { turn = 360 - turn }
            guard turn < 60 else { continue }
            // when its times have it here, and how far off that is from now
            let t = s.departure.addingTimeInterval(p.fraction * s.arrival.timeIntervalSince(s.departure))
            let late = now.timeIntervalSince(t)
            guard abs(late) < 12 * 60 else { continue }
            if best[s.tripId].map({ abs(late) < abs($0.late) }) ?? true {
                best[s.tripId] = (s.isTrain ? Transit.trainLabel(s.line) : s.line, s.isTrain, late)
            }
        }
        return best.map { (tripId: $0.key, line: $0.value.line, isTrain: $0.value.isTrain, late: $0.value.late) }.sorted { abs($0.late) < abs($1.late) }
    }

    /// Where a point is along a road: how far from it, how far along (0 to 1), and which way the road runs there.
    nonisolated static func project(_ c: CLLocationCoordinate2D, on path: [CLLocationCoordinate2D]) -> (metres: Double, fraction: Double, bearing: Double)? {
        guard path.count >= 2 else { return nil }
        let kx = cos(c.latitude * .pi / 180) * 111_320, ky = 110_540.0
        var lens: [Double] = [], total = 0.0
        for i in 1..<path.count {
            let dx = (path[i].longitude - path[i - 1].longitude) * kx, dy = (path[i].latitude - path[i - 1].latitude) * ky
            let l = (dx * dx + dy * dy).squareRoot()
            lens.append(l); total += l
        }
        guard total > 0 else { return nil }
        var best = (d: Double.greatestFiniteMagnitude, along: 0.0, seg: 1), acc = 0.0
        for i in 1..<path.count {
            let ax = (path[i - 1].longitude - c.longitude) * kx, ay = (path[i - 1].latitude - c.latitude) * ky
            let bx = (path[i].longitude - c.longitude) * kx, by = (path[i].latitude - c.latitude) * ky
            let dx = bx - ax, dy = by - ay, l2 = dx * dx + dy * dy
            let u = l2 > 0 ? max(0, min(1, -(ax * dx + ay * dy) / l2)) : 0
            let px = ax + u * dx, py = ay + u * dy, d = (px * px + py * py).squareRoot()
            if d < best.d { best = (d, acc + u * lens[i - 1], i) }
            acc += lens[i - 1]
        }
        return (best.d, best.along / total, Heading.bearing(path[best.seg - 1], path[best.seg]))
    }

    /// Where you're going: your pick, or school or home.
    func destination(_ dir: Direction) -> Place { custom?.place ?? (dir == .toSchool ? .buas : .veghel) }

    private func loadNearIfAny(_ h: CLLocation?) async { if let h { await loadNear(h) } }

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
        // the last few that left, and the next ones (asked for apart, or a busy stop fills the list with ones that left)
        let ids = nearStops.map(\.id)
        async let past = Transit.board(stopIds: ids, from: Date().addingTimeInterval(-20 * 60), n: 6, stops: true)
        async let next = Transit.board(stopIds: ids, from: Date().addingTimeInterval(-60), n: 20, stops: true)
        let (p, n) = await (past, next)
        // A stop whose next ones didn't come (a bad moment on the connection, or a busy server): keep the ones it had that
        // haven't left, instead of a board with only what's gone, and ask again in a few seconds.
        let now = Date()
        let answered = Set(n.map(\.stopId))
        let kept = nearBoard.filter { !answered.contains($0.stopId) && ids.contains($0.stopId) && ($0.cancelled ? $0.scheduled : $0.time) > now.addingTimeInterval(-60) }
        // the sides of a stop can each list the same bus: keep it once
        var seen = Set<String>()
        let b = (n + kept + p).filter { seen.insert("\($0.tripId)|\($0.stopName)").inserted }
        if !b.isEmpty { nearBoard = b.sorted { ($0.cancelled ? $0.scheduled : $0.time) < ($1.cancelled ? $1.scheduled : $1.time) } }
        if ids.contains(where: { !answered.contains($0) }), !nearRetrying {
            nearRetrying = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                await self?.loadNear(h)
                self?.nearRetrying = false
            }
        }
    }
    private var nearRetrying = false

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
        if let loc {
            // moving at bus or train speed (by the GPS, or between two positions): you're probably on board. Only on good
            // fixes, far enough apart: inside a big station the GPS jumps about and a few seconds can look like 20 km/h.
            if Self.movingFix(loc) { lastMoving = loc.timestamp }
            if let p = lastSeen, loc.timestamp > p.timestamp {
                let dt = loc.timestamp.timeIntervalSince(p.timestamp)
                if dt >= 20, dt < 300, loc.horizontalAccuracy >= 0, loc.horizontalAccuracy <= 25, p.horizontalAccuracy >= 0, p.horizontalAccuracy <= 25,
                   loc.distance(from: p) / dt >= 5 { lastMoving = loc.timestamp }
            }
            lastSeen = loc
        }
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
        // the boards around you load at the same time as your trip (they used to wait for it)
        async let boards: Void = loadNearIfAny(from)
        let trips: [DoorTrip]
        if let f = from {
            plannedFrom = f
            // on a bus or train (moving, or moved in the last 3 minutes, e.g. standing at a station): carry on with it
            let to = destination(dir)
            if let m = lastMoving, Date().timeIntervalSince(m) < 180, let ob = await Transit.within(7, { await Self.onBoardTrips(f, to: to) }) ?? nil {
                onBoard = ob.0; trips = ob.1
            } else {
                onBoard = nil; trips = await Transit.tripsFrom(f.coordinate, to: destination(dir))
            }
        }
        else if custom != nil { onBoard = nil; trips = await Transit.tripsFrom(usual.coordinate, to: destination(dir)) }
        else { onBoard = nil; trips = await Transit.nextTrips(dir) }
        guard loadedFor == key else { await boards; return }
        // One empty answer from Transitous doesn't wipe what you had: keep the trips that haven't left yet, and ask again sooner.
        next = trips.isEmpty ? next.filter { $0.first.departure > Date().addingTimeInterval(-60) } : trips
        nextError = next.isEmpty ? "No trips found right now. It tries again in a minute." : nil
        if pick >= next.count { pick = 0 }
        updated = trips.isEmpty ? Date().addingTimeInterval(-40) : Date()
        // From anywhere: the stops around you instead of the lists for your two routes.
        await boards
        if anywhere {
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
            async let b = Transit.board(stopIds: veghel.ids, from: now, n: 40, stops: true)
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
