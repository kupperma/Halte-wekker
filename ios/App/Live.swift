import CoreLocation
import Foundation

/// A trip in one of the live lists, with the places it was planned between (for NS and Near me).
struct PanelTrip: Identifiable, Hashable, Codable {
    let trip: DoorTrip
    let from: Place
    let to: Place
    var id: String { trip.id }
}

/// What a bus on the Veghel board does: how long it takes to the station and when it gets there.
struct BoardRide: Hashable, Codable {
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
    /// When the trips, the lists per leg and the boards near you were the live answer, while what they show is a saved
    /// answer or kept from another planning key (nil: live). Shown as "as of 08:12".
    @Published private(set) var nextAsOf: Date?
    @Published private(set) var panelsAsOf: Date?
    @Published private(set) var nearAsOf: Date?
    private var emptyRetries = 0
    private var loadedFor: String?             // the direction, where you're going and where from
    private var loadedKey: PlanKey?            // the same, in parts
    private var busy = false
    private var refreshes = 0                  // refreshes begun: only the newest one, when it ends, says it's not busy
    private var lastPanels = Date.distantPast
    private var nextAt: Date?                  // when the trips shown came in
    private var panelsFor: Direction?          // the direction the lists per leg are for
    private var livePanels = LiveLists<PanelList>()     // which lists per leg are live for `loadedFor`, and when each came in
    private var nearBoardAt: Date?             // when the boards near you came in (the oldest rows they show)
    private var nearRound = 0                  // a new one when the boards near you are replaced: older loads then stop

    /// The last answers, saved in `<Caches>/answers` and shown at once after launch or a planning-key change.
    struct SavedTrips: Codable { let trips: [DoorTrip]; let lat: Double?; let lon: Double? }          // "next|<key>"
    struct SavedPanels: Codable {                                                                    // "panels|<direction>"
        var board: [BoardDeparture]
        var rides: [String: BoardRide]
        var trains: [PanelTrip]
        var buas: [PanelTrip]
        var toVeghel: [PanelTrip]
    }
    struct SavedNear: Codable { let stops: [Transit.NearStop]; let board: [BoardDeparture]; let lat: Double; let lon: Double }   // "near"

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
    @Published private(set) var onBoard: OnBoard? { didSet { if onBoard == nil { onBoardLooks = 0 } } }
    /// How many refreshes in a row found you on the same one (0.20.5): from two, the home starts your trip by itself.
    @Published private(set) var onBoardLooks = 0
    /// Your fixes of the last minutes (0.20.5), for the matcher: it judges your track, not one position.
    private var fixes: [Fix] = []
    /// On a moving train or bus that isn't found yet: no walking plan from the railway, just "finding what you're on".
    @Published private(set) var onTheMove = false
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
        // (when you picked it, for the school window that ends it: `scheduleTakesOver`)
        if d != nil { UserDefaults.standard.set(Date(), forKey: "customDestAt") } else { UserDefaults.standard.removeObject(forKey: "customDestAt") }
        UserDefaults.standard.removeObject(forKey: "customDestUntil")
        if let d {
            recents = Array(([d] + recents.filter { $0.id != d.id }).prefix(6))
            UserDefaults.standard.set(try? JSONEncoder().encode(recents), forKey: "recentDests")
        }
    }

    /// A place you picked stays where you're going (across launches) until you change it, or until the next school
    /// window opens (the one in which Fastest trip opens by itself for your class: `HomeDest.resolve`). Then it's back
    /// to school or home, by your schedule.
    func scheduleTakesOver(now: Date = Date()) {
        guard custom != nil else { return }
        let ud = UserDefaults.standard
        let at: Date
        if let a = ud.object(forKey: "customDestAt") as? Date { at = a } else { at = now; ud.set(now, forKey: "customDestAt") }   // (picked before 0.20.2)
        let s = SchoolAlarm.shared
        let until = ud.object(forKey: "customDestUntil") as? Date
        let r = HomeDest.resolve(chosenAt: at, until: until,
                                 windowStart: HomeDest.windowStart(on: s.on, leave: s.next?.leave, alarm: s.next?.alarm), now: now)
        if r.over { go(to: nil) } else if let u = r.until, u != until { ud.set(u, forKey: "customDestUntil") }
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
    /// `history`: your fixes of the last minutes, read once the vehicles near you are in. Without a `tripId` it's the
    /// one that moves with you (`movesWithYou`); classic matching: the one whose position by its times now is nearest to you.
    static func onBoardTrips(_ f: CLLocation, to dest: Place, tripId: String? = nil, wasMoving: Bool = false,
                             late: TimeInterval? = nil, line: String? = nil, isTrain: Bool? = nil, reuse: Bool = false,
                             history: @MainActor @Sendable () -> [Fix] = { [] }) async -> (OnBoard, [DoorTrip])? {
        let now = Date()
        if let tripId, let late {
            let stops = await Transit.tripStops(tripId)
            guard let next = stops.first(where: { ($0.arrival ?? .distantPast).addingTimeInterval(late) > now.addingTimeInterval(20) }) else { return nil }
            let at = (next.arrival ?? now).addingTimeInterval(late)
            let its = await planOn(next: next, at: at, to: dest)
            return assemble(from: f, tripId: tripId, line: line ?? "?", isTrain: isTrain ?? false, toName: stops.last?.name ?? "",
                            stops: stops, next: next, at: at, its: its)
        }
        let still = f.speed < 3 && !wasMoving       // standing or walking now (or no speed): then it has to be right with you
        let speedNow = wasMoving ? max(f.speed, 15) : f.speed
        let classic = MatchSettings.classic()
        // (the matcher reads every trip on a piece several share; classic matching the first only)
        // (`reuse`, Fastest trip watching: the same map answer of the last 10 s, from about here at your speed: 0.20.7)
        let segs = await Transit.vehicles(near: f.coordinate, radiusDeg: tripId == nil && speedNow < 15 ? 0.02 : 0.04, allTrips: !classic,
                                          reuse: reuse, speed: speedNow)
        let chosen: VehicleSegment?
        if classic || tripId != nil {
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
            chosen = best?.0
        } else {
            chosen = await movesWithYou(f, segs, history: history, still: still, speed: speedNow, now: now)
        }
        guard let seg = chosen else { return nil }
        // Its next stop is where this piece goes (it left its last one, or leaves it within 20 s, and gets there after
        // that): its stops and the ways on from there are asked at once. Otherwise its stops first, then the first of
        // them it gets to after 20 s from now.
        if let la = seg.toLat, let lo = seg.toLon, seg.departure <= now.addingTimeInterval(20), seg.arrival > now.addingTimeInterval(20) {
            // Standing still and it's coming to where you are: you're at its stop (a bus station by the train station), not on it.
            if tripId == nil, still, f.distance(from: CLLocation(latitude: la, longitude: lo)) < 350 { return nil }
            let ahead = TripStop(name: seg.toName, coordinate: .init(latitude: la, longitude: lo), arrival: seg.arrival)
            async let asked = Transit.tripStops(seg.tripId)
            async let ways = planOn(next: ahead, at: seg.arrival, to: dest)
            let (stops, its) = await (asked, ways)
            guard !stops.isEmpty else { return nil }
            // that stop as its trip has it (its name, and for staying on past it)
            let there = CLLocation(latitude: la, longitude: lo)
            let next = stops.first { s in
                abs((s.arrival ?? .distantPast).timeIntervalSince(seg.arrival)) <= 120
                    && (s.name == ahead.name || there.distance(from: CLLocation(latitude: s.coordinate.latitude, longitude: s.coordinate.longitude)) < 150)
            } ?? ahead
            return assemble(from: f, tripId: seg.tripId, line: seg.line, isTrain: seg.isTrain, toName: seg.toName,
                            stops: stops, next: next, at: seg.arrival, its: its)
        }
        let stops = await Transit.tripStops(seg.tripId)
        guard let next = stops.first(where: { ($0.arrival ?? .distantPast) > now.addingTimeInterval(20) }) else { return nil }
        // Standing still and it's coming to where you are: you're at its stop (a bus station by the train station), not on it.
        if tripId == nil, still, f.distance(from: CLLocation(latitude: next.coordinate.latitude, longitude: next.coordinate.longitude)) < 350 { return nil }
        let its = await planOn(next: next, at: next.arrival ?? now, to: dest)
        return assemble(from: f, tripId: seg.tripId, line: seg.line, isTrain: seg.isTrain, toName: seg.toName,
                        stops: stops, next: next, at: next.arrival ?? now, its: its)
    }

    /// The matcher's pick for `onBoardTrips`: the bus or train that moves with you. Judged on your fixes once they span
    /// 20 s, else on this fix alone at its own time (on its path, going your way by the GPS's course, a possible speed,
    /// near its times: today's allowed distance, 250 m when you're standing); the best by the seconds you are off its
    /// times. Its piece now: the last of its pieces that has left (else its first). One with a fresh GPS fix of its own
    /// is judged by where that puts it (0.20.3).
    private static func movesWithYou(_ f: CLLocation, _ segs: [VehicleSegment], history read: @MainActor @Sendable () -> [Fix],
                                     still: Bool, speed: Double, now: Date) async -> VehicleSegment? {
        let one = Fix(f)
        // (a late bus by its times without catching up: its live times have it make its delay up within a few stops)
        let plain = VehicleTrack.group(Transit.noCatchUp(segs, asOf: now).map { MapPiece($0) })
        let tracks = await RealPositionsStore.shared.forMatcher(plain)
        BatteryLog.shared.check()
        let history = read()                // (read once the vehicles near you are in)
        let judged: [Judgement]
        if VehicleMatch.enough(history) {
            judged = VehicleMatch.judgeAll(history, tracks)
        } else {
            judged = tracks.map { v in
                VehicleMatch.judgeOne(one, v, tolerance: still ? 250 : VehicleMatch.tolerance(isTrain: v.isTrain, speed: speed))
            }
        }
        let ranked = VehicleMatch.rank(judged, planned: nil)
        let lines = Dictionary(tracks.map { ($0.tripId, $0.line) }, uniquingKeysWith: { a, _ in a })
        let outcome = ranked.first.map { "best " + FieldFormat.label($0.id, lines) } ?? "none"
        FieldLog.shared.add(.match, FieldFormat.match("on board", judged, outcome: outcome, count: judged.count))
        guard let id = ranked.first?.id else { return nil }
        let pieces = segs.filter { $0.tripId == id }
        return pieces.filter { $0.departure <= now }.max { $0.departure < $1.departure } ?? pieces.min { $0.departure < $1.departure }
    }

    /// The planner's ways on from the bus or train you're on: from its next stop, from when it gets there, to each of
    /// the destination's stops at once.
    private static func planOn(next: TripStop, at: Date, to dest: Place) async -> [DoorTrip] {
        let start = "\(next.coordinate.latitude),\(next.coordinate.longitude)", when = at.addingTimeInterval(-60)
        var jobs: [@Sendable () async -> [DoorTrip]] = []
        for b in dest.ids {
            jobs.append { await Transit.plan(from: start, to: b, modes: nil, at: when, count: 5, maxTransfers: 4) }
        }
        return await Progressive.all(jobs).flatMap { $0 }
    }

    /// The ways on from the bus or train you're on (`its`: the planner's, from its next stop), staying on when it goes
    /// where a later ride leaves.
    private static func assemble(from f: CLLocation, tripId: String, line: String, isTrain: Bool, toName: String,
                                 stops: [TripStop], next: TripStop, at: Date, its: [DoorTrip]) -> (OnBoard, [DoorTrip])? {
        let now = Date()
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
    /// Its lateness is reckoned at the fix's own time (the fix can be seconds old), and every trip on a piece that
    /// several share counts (classic matching: reckoned at now, and the first trip only).
    static func vehiclesByRoad(_ f: CLLocation) async -> [(tripId: String, line: String, isTrain: Bool, late: TimeInterval)] {
        guard f.course >= 0, f.speed >= 3 else { return [] }
        if !MatchSettings.classic() {
            let segs = await Transit.vehicles(near: f.coordinate, radiusDeg: 0.012, back: 12 * 60, ahead: 12 * 60, allTrips: true)
            return VehicleMatch.byRoad(Fix(f), segs.map { MapPiece($0) })
                .map { (tripId: $0.tripId, line: $0.line, isTrain: $0.isTrain, late: $0.late) }
        }
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

    /// The stops near you to ask: the nearest stop of the two nearest bus-stop names, and the nearest station (each
    /// one's board has every platform of its name: see `NearPick`).
    nonisolated static func onePerName(_ s: [Transit.NearStop]) -> [Transit.NearStop] {
        NearPick.onePerName(s, name: \.name, rail: \.rail)
    }

    /// The stops near you (the two nearest bus stops, both sides, and the nearest station) and what leaves from them.
    private func loadNear(_ h: CLLocation) async {
        let round = nearRound            // (a planning-key change that replaces the boards near you ends this load)
        if nearAt.map({ h.distance(from: $0.0) > 150 || Date().timeIntervalSince($0.1) > 600 }) ?? true {
            let s = await Transit.nearStops(h.coordinate)
            guard round == nearRound else { return }
            if !s.isEmpty {
                nearStops = Self.onePerName(s)
                nearAt = (h, Date())
            }
        }
        guard !nearStops.isEmpty else { return }
        // the last few that left, and the next ones (asked for apart, or a busy stop fills the list with ones that left)
        let ids = nearStops.map(\.id)
        async let past = Transit.board(stopIds: ids, from: Date().addingTimeInterval(-20 * 60), n: 6, stops: true)
        async let next = Transit.board(stopIds: ids, from: Date().addingTimeInterval(-60), n: 20, stops: true)
        let (p, n) = await (past, next)
        guard round == nearRound, nearStops.map(\.id) == ids else { return }
        // A stop whose next ones didn't come (a bad moment on the connection, or a busy server): keep the ones it had that
        // haven't left, instead of a board with only what's gone, and ask again in a few seconds.
        let now = Date()
        let answered = Set(n.map(\.stopId))
        let kept = nearBoard.filter { !answered.contains($0.stopId) && ids.contains($0.stopId) && ($0.cancelled ? $0.scheduled : $0.time) > now.addingTimeInterval(-60) }
        // the sides of a stop can each list the same bus: keep it once
        var seen = Set<String>()
        let b = (n + kept + p).filter { seen.insert("\($0.tripId)|\($0.stopName)").inserted }
        if !b.isEmpty {
            nearBoard = b.sorted { ($0.cancelled ? $0.scheduled : $0.time) < ($1.cancelled ? $1.scheduled : $1.time) }
            // Rows kept from before, for a stop that didn't answer, keep the board's older time (and a saved board's
            // "as of") until they're gone.
            nearBoardAt = Snapshots.boardTime(previous: nearBoardAt, now: now, keptOld: !kept.isEmpty)
            if kept.isEmpty { nearAsOf = nil }
            if let at = nearAt?.0 {
                SnapshotStore.shared.save(SavedNear(stops: nearStops, board: nearBoard, lat: at.coordinate.latitude, lon: at.coordinate.longitude),
                                          key: "near", at: nearBoardAt ?? now)
            }
        }
        if ids.contains(where: { !answered.contains($0) }), !nearRetrying {
            nearRetrying = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if self?.nearRound == round { await self?.loadNear(h) }
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
        scheduleTakesOver()
        let wasMoving = lastMoving.map { Date().timeIntervalSince($0) < 180 } ?? false
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
            if loc.horizontalAccuracy >= 0, loc.horizontalAccuracy <= 100, loc.timestamp > (fixes.last?.t ?? .distantPast) {
                fixes.append(Fix(loc))
                fixes.removeAll { loc.timestamp.timeIntervalSince($0.t) > 240 }
            }
        }
        // Away from your usual start (or going somewhere you picked): trips start from where you are.
        // Going to school, anywhere in Veghel counts as home (your Veghel bus board); going home, only the BUas campus
        // counts as school, so anywhere else in Breda the trip starts from where you are.
        let usual: Place = dir == .toSchool ? .veghel : .buas
        let radius = dir == .toSchool ? 2500.0 : 500.0
        let away = lastSeen.map { $0.distance(from: CLLocation(latitude: usual.coordinate.latitude, longitude: usual.coordinate.longitude)) > radius } ?? false
        let from: CLLocation? = (away || custom != nil) ? lastSeen : nil
        let plan = PlanKey(dir: dir.rawValue, dest: custom?.id ?? "", fromHere: from != nil)
        let key = plan.text
        if busy && loadedFor == key { return }
        // A new key (or the first load) doesn't empty the lists: its saved answers show at once, the lists that still
        // answer the question stay, and both are marked "as of" until the live answers are in.
        if loadedFor != key { keyChanged(from: loadedKey, to: plan, dir: dir, at: from) }
        // (on board already, it looks again on the minute, not every 300 m; just started moving, it looks now)
        let startedMoving = !wasMoving && (lastMoving.map { Date().timeIntervalSince($0) < 180 } ?? false)
        let moved = startedMoving || (onBoard == nil && (from.flatMap { f in plannedFrom.map { f.distance(from: $0) > 300 } } ?? false))
        if !force, !moved, loadedFor == key, let u = updated, Date().timeIntervalSince(u) < 60 { return }
        busy = true; loadedFor = key; loadedKey = plan; here = from
        // (an older one, for a key it switched away from, ending first mustn't let the same refresh start twice)
        refreshes += 1
        let mine = refreshes
        defer { if refreshes == mine { busy = false } }
        // the boards around you load at the same time as your trip (they used to wait for it), and so do the lists per
        // leg, each shown as soon as it's in (stopped when you've switched to somewhere else before your trip is in)
        async let boards: Void = loadNearIfAny(from)
        async let panels: Void = loadPanelsIfDue(dir, key: key, force: force)
        let trips: [DoorTrip]
        if let f = from {
            plannedFrom = f
            // on a bus or train (moving, or moved in the last 3 minutes, e.g. standing at a station): carry on with it
            let to = destination(dir)
            let history = fixes.filter { Date().timeIntervalSince($0.t) < 120 }     // (as the trip's: the last 2 minutes)
            if let m = lastMoving, Date().timeIntervalSince(m) < 180,
               let ob = await Net.within(7, { await Self.onBoardTrips(f, to: to, wasMoving: true, history: { history }) }) ?? nil {
                let same = onBoard?.vehicle.tripId == ob.0.vehicle.tripId
                onBoard = ob.0; trips = ob.1; onTheMove = false
                onBoardLooks = same ? onBoardLooks + 1 : 1
            } else if let m = lastMoving, Date().timeIntervalSince(m) < 180,
                      !VehicleMatch.planFromSpot(speed: f.speed, movedAgo: Date().timeIntervalSince(m)) {
                onBoard = nil; onTheMove = true; trips = []
            } else {
                onBoard = nil; onTheMove = false; trips = await Transit.tripsFrom(f.coordinate, to: destination(dir))
            }
        }
        else if custom != nil { onBoard = nil; onTheMove = false; trips = await Transit.tripsFrom(usual.coordinate, to: destination(dir)) }
        else { onBoard = nil; onTheMove = false; trips = await Transit.nextTrips(dir) }
        guard loadedFor == key else { await boards; return }
        // One empty answer from Transitous doesn't wipe what you had: keep the trips that haven't left yet, and ask again sooner.
        if trips.isEmpty {
            next = next.filter { $0.first.departure > Date().addingTimeInterval(-60) }
        } else {
            next = trips; nextAsOf = nil; nextAt = Date()
            SnapshotStore.shared.save(SavedTrips(trips: trips, lat: from?.coordinate.latitude, lon: from?.coordinate.longitude), key: "next|\(key)")
        }
        nextError = next.isEmpty && !onTheMove ? "No trips found right now. It tries again in a minute." : nil
        if pick >= next.count { pick = 0 }
        updated = trips.isEmpty ? Date().addingTimeInterval(-40) : Date()
        // From anywhere: the stops around you instead of the lists for your two routes.
        await boards
        if anywhere, loadedFor == key { panelsUpdated = Date() }
        await panels
    }

    /// The planning key changed, or it's the first load. Your next trips: the new key's saved answer (asked within 300 m
    /// of where you are, minus what has left); else, when only the start changed, the trips you had; else none. The lists
    /// per leg depend only on the direction: a new one shows its saved lists. The boards near you stay while you're within
    /// 300 m of where they were asked, else the saved ones from about here show. Whatever isn't live is marked "as of".
    private func keyChanged(from old: PlanKey?, to new: PlanKey, dir: Direction, at from: CLLocation?) {
        let now = Date(), store = SnapshotStore.shared
        let you = from.map { (lat: $0.coordinate.latitude, lon: $0.coordinate.longitude) }
        var saved: (trips: [DoorTrip], at: Date)?
        if let s = store.load(SavedTrips.self, key: "next|\(new.text)"),
           Snapshots.closeEnough(saved: Self.spot(s.value.lat, s.value.lon), here: you, metres: 300) {
            let l = Snapshots.upcoming(s.value.trips, now: now) { $0.rides.first?.departure ?? .distantPast }
            if !l.isEmpty { saved = (l, s.at) }
        }
        switch Snapshots.onKeyChange(from: old, to: new, hasSaved: saved != nil) {
        case .showSaved:
            if let saved { next = saved.trips; nextAsOf = saved.at; nextAt = saved.at }
            pick = 0
        case .keep:
            next = Snapshots.upcoming(next, now: now) { $0.first.departure }
            nextAsOf = next.isEmpty ? nil : (nextAsOf ?? nextAt)
            if pick >= next.count { pick = 0 }
        case .clear:
            next = []; nextAsOf = nil; nextAt = nil; pick = 0
        }
        nextError = nil; updated = nil; panelsUpdated = nil; lastPanels = .distantPast
        onBoard = nil; onTheMove = false        // (the bus or train you're on is found again for the new key)

        livePanels.reset()                      // what the lists per leg show isn't live for the new key
        if panelsFor != dir {
            panelsFor = dir
            let v = store.load(SavedPanels.self, key: "panels|\(dir.rawValue)")
            board = Snapshots.upcoming(v?.value.board ?? [], now: now) { $0.cancelled ? $0.scheduled : $0.time }
            // (a saved trip without rides can't be shown: it counts as gone)
            trains = Snapshots.upcoming(v?.value.trains ?? [], now: now) { $0.trip.rides.first?.departure ?? .distantPast }
            buas = Snapshots.upcoming(v?.value.buas ?? [], now: now) { $0.trip.rides.first?.departure ?? .distantPast }
            toVeghel = Snapshots.upcoming(v?.value.toVeghel ?? [], now: now) { $0.trip.rides.first?.departure ?? .distantPast }
            if let v { boardRides = v.value.rides }
            for l in [PanelList.board, .trains, .buas, .toVeghel] { livePanels.restored(l, at: hasContent(l) ? v?.at : nil) }
        }
        updatePanelsAsOf()

        if let f = from {
            if let n = nearAt, n.0.distance(from: f) <= 300 {
                if !nearBoard.isEmpty { nearAsOf = nearAsOf ?? nearBoardAt }
            } else if let s = store.load(SavedNear.self, key: "near"),
                      Snapshots.closeEnough(saved: (lat: s.value.lat, lon: s.value.lon), here: you, metres: 300) {
                nearRound += 1
                // (saved before one stop per name: its rows go with the kept stop of their name)
                let kept = Self.onePerName(s.value.stops)
                let to = NearPick.keptStop(s.value.stops.map { (id: $0.id, name: $0.name) }, kept: kept.map { (id: $0.id, name: $0.name) })
                nearStops = kept
                nearBoard = Snapshots.upcoming(s.value.board.map { $0.at(to[$0.stopId] ?? $0.stopId) }, now: now) { $0.cancelled ? $0.scheduled : $0.time }
                nearAt = (CLLocation(latitude: s.value.lat, longitude: s.value.lon), s.at)
                nearBoardAt = nearBoard.isEmpty ? nil : s.at
                nearAsOf = nearBoardAt
            } else {
                nearRound += 1
                nearBoard = []; nearAsOf = nil; nearBoardAt = nil
            }
        }
        if old == nil {                         // once a launch: the answers nobody asked for in a week go
            Task.detached(priority: .utility) { SnapshotStore.shared.prune(olderThan: 7 * 24 * 3600) }
        }
    }

    /// The lists per leg of `panelsFor` that show anything.
    private var panelContent: [PanelList] {
        (panelsFor == .home ? [PanelList.buas, .trains, .toVeghel] : [.board, .trains, .buas]).filter { hasContent($0) }
    }

    /// "as of" the oldest list's time while any list per leg shows what isn't live for this key.
    private func updatePanelsAsOf() { panelsAsOf = livePanels.asOf(panelContent) }

    nonisolated private static func spot(_ lat: Double?, _ lon: Double?) -> (lat: Double, lon: Double)? {
        guard let lat, let lon else { return nil }
        return (lat, lon)
    }

    /// One planner question for a list per leg.
    private struct PanelJob { let from: Place; let to: Place; let modes: String; let count: Int; let maxTransfers: Int }
    private enum PanelList { case board, trains, buas, toVeghel }

    /// The lists per leg, every two minutes (Transitous is volunteer-run), alongside your trip. Each list shows as soon
    /// as its own answer is in, if it's still for what you're looking at (an empty answer keeps the last list).
    private func loadPanelsIfDue(_ dir: Direction, key: String, force: Bool) async {
        // From anywhere: the stops around you instead of the lists for your two routes.
        guard !anywhere, loadedFor == key else { return }
        guard force || Date().timeIntervalSince(lastPanels) > 120 else { return }
        lastPanels = Date()
        let now = Date().addingTimeInterval(-30 * 60)          // from half an hour ago, for "Show earlier"
        let veghel = stops.veghel
        var empty = false, got = false
        if dir == .toSchool {
            async let b = loadBoard(veghel.ids, from: now, key: key)
            async let g: Void = loadBoardRides(veghel, key: key)
            async let t = loadList(.trains, [PanelJob(from: .eindhoven, to: .breda, modes: "RAIL", count: 8, maxTransfers: 1),
                                             PanelJob(from: .denBosch, to: .breda, modes: "RAIL", count: 8, maxTransfers: 1)], at: now, key: key)
            async let u = loadList(.buas, [PanelJob(from: .breda, to: .buas, modes: "BUS", count: 12, maxTransfers: 0)], at: now, key: key)
            let (bb, tt, uu) = await (b, t, u)
            await g
            empty = bb.isEmpty || tt.isEmpty || uu.isEmpty
            got = !bb.isEmpty || !tt.isEmpty || !uu.isEmpty
        } else {
            async let u = loadList(.buas, [PanelJob(from: .buas, to: .breda, modes: "BUS", count: 12, maxTransfers: 0)], at: now, key: key)
            async let t = loadList(.trains, [PanelJob(from: .breda, to: .eindhoven, modes: "RAIL", count: 8, maxTransfers: 1),
                                             PanelJob(from: .breda, to: .denBosch, modes: "RAIL", count: 8, maxTransfers: 1)], at: now, key: key)
            async let v = loadList(.toVeghel, [PanelJob(from: .denBosch, to: veghel, modes: "BUS", count: 8, maxTransfers: 0),
                                               PanelJob(from: .eindhoven, to: veghel, modes: "BUS", count: 8, maxTransfers: 0)], at: now, key: key)
            let (uu, tt, vv) = await (u, t, v)
            empty = uu.isEmpty || tt.isEmpty || vv.isEmpty
            got = !uu.isEmpty || !tt.isEmpty || !vv.isEmpty
        }
        guard loadedFor == key else { return }
        panelsUpdated = Date()
        if got {
            // A list whose answer didn't come (or was empty) still shows its older rows: the lists are saved as of the
            // oldest of them, and stay "as of" while one of them isn't live.
            updatePanelsAsOf()
            SnapshotStore.shared.save(SavedPanels(board: board, rides: boardRides, trains: trains, buas: buas, toVeghel: toVeghel),
                                      key: "panels|\(dir.rawValue)", at: livePanels.oldest(panelContent) ?? Date())
        }
        // Transitous now and then sends nothing back: try an empty list again at the next refresh (30 s), a few times.
        if empty && emptyRetries < 3 { emptyRetries += 1; lastPanels = .distantPast } else if !empty { emptyRetries = 0 }
        let rail = trains
        Task { await NSStore.shared.enrich(rail.map { ($0.trip, $0.from, $0.to) }) }
    }

    /// Your Veghel board, shown as soon as it's in.
    private func loadBoard(_ ids: [String], from: Date, key: String) async -> [BoardDeparture] {
        let b = await Transit.board(stopIds: ids, from: from, n: 40, stops: true)
        if loadedFor == key, !b.isEmpty { board = b; livePanels.shown(.board, at: Date()); updatePanelsAsOf() }    // (an empty answer keeps the last list)
        return b
    }

    /// How long each bus on the board takes to the stations, shown as soon as it's in.
    private func loadBoardRides(_ veghel: Place, key: String) async {
        let g = await boardGrades(veghel)
        if loadedFor == key, !g.isEmpty { boardRides = g }
    }

    /// One list per leg: its planner questions all at once. A partial answer only fills a list that's empty or not live
    /// for this key (a saved one, or one kept from another key), so a live list never drops to one station's rows; once
    /// every answer is in, the whole answer replaces it. Returns all of it.
    private func loadList(_ list: PanelList, _ jobs: [PanelJob], at: Date, key: String) async -> [PanelTrip] {
        var work: [@Sendable () async -> [PanelTrip]] = []
        for j in jobs { work.append { await self.panel(j, at: at) } }
        let all = await Progressive.gather(work) { soFar in await self.fillIfEmpty(soFar, as: list, key: key) }
        show(all, as: list, key: key)
        return all
    }

    /// A list per leg shows anything now.
    private func hasContent(_ list: PanelList) -> Bool {
        switch list {
        case .board: return !board.isEmpty
        case .trains: return !trains.isEmpty
        case .buas: return !buas.isEmpty
        case .toVeghel: return !toVeghel.isEmpty
        }
    }

    /// A partial answer, shown only when the list is empty, or shows what isn't live for this key.
    private func fillIfEmpty(_ l: [PanelTrip], as list: PanelList, key: String) {
        guard livePanels.takesPartial(list, empty: !hasContent(list)) else { return }
        show(l, as: list, key: key)
    }

    private func panel(_ j: PanelJob, at: Date) async -> [PanelTrip] {
        let l = await Transit.plan(from: j.from, to: j.to, modes: j.modes, at: at, count: j.count, maxTransfers: j.maxTransfers)
        Ratings.shared.learn(j.from, j.to, l)
        return l.map { PanelTrip(trip: $0, from: j.from, to: j.to) }
    }

    /// A list that's in, if it's still for what you're looking at (an empty answer keeps the last list).
    private func show(_ l: [PanelTrip], as list: PanelList, key: String) {
        guard loadedFor == key, !l.isEmpty else { return }
        let best = Self.keepBest(l)
        switch list {
        case .board: return                 // (not trips: `loadBoard` shows the board)
        case .trains: trains = best
        case .buas: buas = best
        case .toVeghel: toVeghel = best
        }
        livePanels.shown(list, at: Date())
        updatePanelsAsOf()
    }

    private static func keepBest(_ l: [PanelTrip]) -> [PanelTrip] {
        // Drop an option when one that leaves later still gets you there as early.
        l.filter { o in !l.contains { q in q.id != o.id && q.from == o.from && q.to == o.to && q.trip.first.departure > o.trip.first.departure && q.trip.end <= o.trip.end } }
            .sorted { $0.trip.first.departure < $1.trip.first.departure }
    }

    /// The board has no arrival times, so ask the planner how long each bus takes to the stations (all at once; the
    /// first answer for a bus wins, in the order of your stops, then Eindhoven before Den Bosch).
    private func boardGrades(_ veghel: Place) async -> [String: BoardRide] {
        let at = Date().addingTimeInterval(-120)
        var asks: [(id: String, station: Place)] = []
        for id in veghel.ids { for st in [Place.eindhoven, Place.denBosch] { asks.append((id, st)) } }
        var jobs: [@Sendable () async -> [DoorTrip]] = []
        for a in asks {
            let from = a.id, to = a.station.ids[0]
            jobs.append { await Transit.plan(from: from, to: to, modes: "BUS", at: at, count: 8, maxTransfers: 0) }
        }
        let answers = await Progressive.all(jobs)
        var out: [String: BoardRide] = [:]
        for (a, l) in zip(asks, answers) {
            Ratings.shared.learn(veghel, a.station, l.filter { $0.first.walkBefore == 0 })
            for t in l where t.first.walkBefore == 0 {           // a bus from the other Veghel stop has a walk first
                let k = "\(a.id)|\(t.first.tripId)"
                if out[k] == nil {
                    out[k] = BoardRide(minutes: t.rideMinutes, station: Fmt.place(t.last.toStop), arrival: t.last.arrival, grade: t.first.grade,
                                         best: Ratings.shared.best("\(t.first.fromId)>\(t.first.toStop)"))
                }
            }
        }
        return out
    }
}
