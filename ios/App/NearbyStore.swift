import CoreLocation
import Foundation

/// The stops around you (0.42, "Fastest trip, zoomed out"), each planned to where you're going: what the map stops
/// answer has within 1 km, wider in steps (1.6, 2.2, 3 km) while fewer than 3 stops have a way; at most 8 stops and 12
/// plans a step (`Nearby.groups`), every plan through the planner as always (`Transit.plan`: kept 45 s, and the
/// requests to Transitous go a few at a time and pause on a 429, `Net`). Each stop is drawn as soon as its answer is
/// in. The whole answer is kept a minute per place, destination and time to leave.
enum NearbyFetch {
    /// The stops within `radius` of `c` (a square around it), one entry per station; nil when the request failed.
    static func stops(around c: CLLocationCoordinate2D, radius: Double) async -> [Nearby.Stop]? {
        let key: String = "\(Int((c.latitude * 500).rounded())),\(Int((c.longitude * 300).rounded()))|\(Int(radius))"
        return await memo.get(key, group: 1) { await ask(c, radius: radius) }
    }

    static let memo = Memo<String, [Nearby.Stop]>(ttl: 600, limit: 20)

    private static func ask(_ c: CLLocationCoordinate2D, radius: Double) async -> [Nearby.Stop]? {
        let dLat: Double = radius * 1.05 / 111_320
        let dLon: Double = radius * 1.05 / max(1, 111_320 * cos(c.latitude * .pi / 180))
        let q: [URLQueryItem] = [.init(name: "min", value: "\(c.latitude - dLat),\(c.longitude - dLon)"),
                                 .init(name: "max", value: "\(c.latitude + dLat),\(c.longitude + dLon)")]
        let answer: Any? = try? await Transit.$urgent.withValue(true) { try await Transit.get("/v1/map/stops", q) }
        guard let list = answer as? [[String: Any]] else { return nil }
        let here = GeoPoint(lat: c.latitude, lon: c.longitude)
        var seen = Set<String>()
        var out: [Nearby.Stop] = []
        for m in list {
            guard let id = m["stopId"] as? String, let name = m["name"] as? String,
                  let la = m["lat"] as? Double, let lo = m["lon"] as? Double else { continue }
            let modes: [String] = (m["modes"] as? [String]) ?? []
            let rail: Bool = modes.contains { $0.contains("RAIL") || $0 == "LONG_DISTANCE" || $0 == "HIGHSPEED" }
            let key: String = rail ? ((m["parentId"] as? String) ?? id) : id           // one entry per station
            guard seen.insert(key).inserted else { continue }
            let metres: Double = Geo.metres(here, GeoPoint(lat: la, lon: lo))
            out.append(Nearby.Stop(id: key, name: name, lat: la, lon: lo, rail: rail, metres: metres))
        }
        return out
    }
}

@MainActor
final class NearbyStore: ObservableObject {
    /// A stop and its ways to the destination (each first ride with your walk to the stop).
    struct Way: Identifiable {
        let group: Nearby.Group
        var trips: [DoorTrip] = []
        var asked = false               // its answer is in
        var id: String { group.id }
    }

    /// Your walk to a stop: the planner's minutes, at your own speed (`WalkPlan`), and its length.
    struct Walk {
        let planned: Int
        let shown: WalkPlan.Shown
        let metres: Double
        /// The minutes it counts on: your walk and its spare.
        var counted: Int { max(1, planned - shown.later) }
    }

    @Published private(set) var ways: [Way] = []
    @Published private(set) var options: [Nearby.Option] = []
    @Published private(set) var tags: [String: [Nearby.Tag]] = [:]
    @Published private(set) var radius: Double = Nearby.radii[0]
    @Published private(set) var busy = false
    @Published private(set) var failed = false
    @Published private(set) var leave: Nearby.Leave = .now
    @Published private(set) var window: Nearby.Window = Nearby.window(.now, now: Date())
    @Published private(set) var here: CLLocation?
    private(set) var dest: Place?
    private var best: [String: DoorTrip] = [:]
    private var sures: [String: Nearby.Sure] = [:]
    private var task: Task<Void, Never>?
    private var startedAt: Date?

    private struct Kept { let at: Date; let ways: [Way]; let radius: Double }
    private static var kept: [String: Kept] = [:]

    /// At most this many stops and plans in all, over the wider looks too.
    static let groupsMax = 12
    static let plansMax = 20

    // MARK: asking

    /// Look around `here` for ways to `dest` (again only when you've moved 250 m, it's another destination, or it's a
    /// minute and a half old). `seed`: the trips Fastest trip has, put with their stops.
    func open(here h: CLLocation, dest d: Place, seed: [DoorTrip]) {
        let same: Bool = dest?.key == d.key && here.map { $0.distance(from: h) < 250 } == true
            && (startedAt.map { Date().timeIntervalSince($0) < 90 } ?? false)
        if same {
            absorb(seed)
            return
        }
        here = h; dest = d
        start(seed: seed)
    }

    /// The switch: leave now, in 10 or in 20 minutes.
    func choose(_ l: Nearby.Leave) {
        guard l != leave else { return }
        leave = l
        start(seed: [])
    }

    func stop() {
        task?.cancel(); task = nil
        busy = false
    }

    /// Once a minute on screen: the window moves on with the clock ("Leave now" is now), and after three minutes
    /// it asks again.
    func tick() {
        guard here != nil, dest != nil, !busy else { return }
        if let s = startedAt, Date().timeIntervalSince(s) > 180 {
            if let k = cacheKey() { Self.kept[k] = nil }
            start(seed: [], keep: true)
            return
        }
        window = Nearby.window(leave, now: Date())
        recompute()
    }

    private func cacheKey() -> String? {
        guard let h = here, let d = dest else { return nil }
        let c = h.coordinate
        return "\(d.key)|\(leave.rawValue)|\(Int((c.latitude * 500).rounded())),\(Int((c.longitude * 300).rounded()))"
    }

    /// `keep`: what's on screen stays while it asks again (the same place, destination and time to leave).
    private func start(seed: [DoorTrip], keep: Bool = false) {
        task?.cancel()
        guard let h = here, let d = dest else { return }
        window = Nearby.window(leave, now: Date())
        startedAt = Date()
        failed = false
        sures = [:]
        if let k = cacheKey(), let hit = Self.kept[k], Date().timeIntervalSince(hit.at) < 60 {
            ways = hit.ways; radius = hit.radius
            absorb(leave == .now ? seed : [])
            busy = false
            return
        }
        if !keep { ways = []; radius = Nearby.radii[0] }
        busy = true
        recompute()
        let w: Nearby.Window = window
        let seeded: [DoorTrip] = leave == .now ? seed : []
        task = Task { [weak self] in await self?.look(from: h, to: d, window: w, seed: seeded) }
    }

    /// Where the planner is asked to go: the destination's stop, or its spot when it has several.
    private static func target(_ d: Place) -> String {
        let ids: [String] = PlanMemo.unique(d.ids)
        if ids.count == 1, let one = ids.first { return one }
        return "\(d.coordinate.latitude),\(d.coordinate.longitude)"
    }

    private func look(from h: CLLocation, to d: Place, window w: Nearby.Window, seed: [DoorTrip]) async {
        var r: Double = Nearby.radii[0]
        var asked = Set<String>()
        var plans = 0
        var first = true
        while !Task.isCancelled {
            guard let stops = await NearbyFetch.stops(around: h.coordinate, radius: r) else {
                if ways.isEmpty { failed = true }
                break
            }
            guard !Task.isCancelled else { return }
            var gs: [Nearby.Group] = Nearby.groups(stops, within: r, skip: asked)
            gs = Array(gs.prefix(max(0, Self.groupsMax - asked.count)))
            var room: Int = Self.plansMax - plans
            gs = gs.compactMap { g -> Nearby.Group? in
                guard room > 0 else { return nil }
                var g2 = g
                g2.ids = Array(g.ids.prefix(room))
                room -= g2.ids.count
                return g2
            }
            radius = max(radius, r)
            for g in gs {
                if let i = ways.firstIndex(where: { $0.id == g.id }) {
                    ways[i] = Way(group: g, trips: ways[i].trips, asked: ways[i].asked)
                } else {
                    ways.append(Way(group: g))
                }
            }
            if first { absorb(seed); first = false }
            recompute()
            await plan(gs, to: d, window: w)
            guard !Task.isCancelled else { return }
            asked.formUnion(gs.map(\.id))
            plans += gs.reduce(0) { $0 + $1.ids.count }
            guard plans < Self.plansMax, asked.count < Self.groupsMax,
                  let next = Nearby.nextRadius(after: r, useful: options.count) else { break }
            r = next
        }
        busy = false
        if let k = cacheKey(), !ways.isEmpty {
            Self.kept[k] = Kept(at: Date(), ways: ways, radius: radius)
            if Self.kept.count > 12 { Self.kept = Self.kept.filter { Date().timeIntervalSince($0.value.at) < 120 } }
        }
    }

    /// Every stop's plans at once; each stop drawn as its answers come in.
    private func plan(_ gs: [Nearby.Group], to d: Place, window w: Nearby.Window) async {
        let to: String = Self.target(d)
        var jobs: [(group: String, id: String, at: Date)] = []
        var left: [String: Int] = [:]
        for g in gs {
            let walk: Walk = self.walk(g)
            let at: Date = max(Date().addingTimeInterval(-60), w.leave.addingTimeInterval(Double(walk.counted) * 60 - 60))
            for id in g.ids { jobs.append((g.id, id, at)); left[g.id, default: 0] += 1 }
        }
        let all: [(group: String, id: String, at: Date)] = jobs
        await Transit.$urgent.withValue(true) {
            await withTaskGroup(of: (String, [DoorTrip]).self) { tg in
                for j in all {
                    tg.addTask {
                        let found: [DoorTrip] = await Transit.plan(from: j.id, to: to, modes: nil, at: j.at, count: 5, maxTransfers: 3)
                        return (j.group, found)
                    }
                }
                for await (gid, found) in tg {
                    guard !Task.isCancelled else { return }
                    left[gid, default: 1] -= 1
                    let done: Bool = (left[gid] ?? 0) <= 0
                    await self.take(found, from: gid, done: done)
                }
            }
        }
    }

    /// The detail sheet: more of a stop's departures (six from when you can be there).
    func more(_ id: String) async {
        guard let way = ways.first(where: { $0.id == id }), let d = dest else { return }
        let walk: Walk = self.walk(way.group)
        let at: Date = max(Date().addingTimeInterval(-60), window.leave.addingTimeInterval(Double(walk.counted) * 60 - 60))
        let to: String = Self.target(d)
        let ids: [String] = way.group.ids
        let found: [DoorTrip] = await Transit.$urgent.withValue(true) { () async -> [DoorTrip] in
            var out: [DoorTrip] = []
            for s in ids { out += await Transit.plan(from: s, to: to, modes: nil, at: at, count: 7, maxTransfers: 3) }
            return out
        }
        take(found, from: id, done: true)
    }

    /// Answers from a stop: each trip to the stop it really leaves from (one of the stops around, by name or within
    /// 120 m; else, without a walk first, this one), with your walk to that stop.
    private func take(_ found: [DoorTrip], from gid: String, done: Bool) {
        for t in found { put(t, fallback: gid) }
        if done, let i = ways.firstIndex(where: { $0.id == gid }) { ways[i].asked = true }
        recompute()
    }

    /// Fastest trip's own trips (from your spot), with the stops they leave from.
    func absorb(_ seed: [DoorTrip]) {
        let usable: [DoorTrip] = seed.filter { $0.first.fromId != "onboard" && !$0.first.fromId.isEmpty }
        guard !usable.isEmpty else { return }
        for t in usable { put(t, fallback: nil) }
        recompute()
    }

    private func put(_ t: DoorTrip, fallback gid: String?) {
        guard !t.rides.isEmpty else { return }
        let f: Ride = t.first
        let k: String = Nearby.key(f.fromStop)
        let spot: GeoPoint? = f.fromLat.flatMap { a in f.fromLon.map { GeoPoint(lat: a, lon: $0) } }
        var at: Int? = ways.firstIndex { (w: Way) -> Bool in
            if !w.group.rail && w.group.id == k { return true }
            guard let s = spot else { return false }
            return Geo.metres(s, w.group.point) <= (w.group.rail ? 400 : 120)
        }
        if at == nil, f.walkBefore == 0, let g = gid { at = ways.firstIndex { $0.id == g } }
        guard let i = at else { return }
        let walk: Walk = self.walk(ways[i].group)
        let ride: Ride = f.walking(walk.planned)
        let start: Date = ride.departure.addingTimeInterval(-Double(walk.planned) * 60)
        let mine = DoorTrip(rides: [ride] + Array(t.rides.dropFirst()), start: start, end: t.end)
        // one per departure: the one there first
        if let j = ways[i].trips.firstIndex(where: { $0.first.tripId == f.tripId }) {
            if mine.end < ways[i].trips[j].end { ways[i].trips[j] = mine }
        } else {
            ways[i].trips.append(mine)
        }
    }

    // MARK: what's shown

    /// Your walk to a stop.
    func walk(_ g: Nearby.Group) -> Walk {
        let planned: Int = Nearby.plannedWalk(straight: g.metres)
        let metres: Double = Nearby.walkMetres(straight: g.metres)
        let b: HabitBook = HabitStore.shared.book
        let shown: WalkPlan.Shown = WalkPlan.shown(planned: planned, metres: metres, speed: Habits.walkSpeed(b), walks: b.walks.count,
                                                   plannerSpeed: Habits.plannerWalk)
        return Walk(planned: planned, shown: shown, metres: metres)
    }

    /// A stop's departures you make in the window, one per trip, by when they leave.
    func departures(_ id: String) -> [DoorTrip] {
        guard let w = ways.first(where: { $0.id == id }) else { return [] }
        let counted: Int = walk(w.group).counted
        let win: Nearby.Window = window
        let ok: [DoorTrip] = w.trips.filter { t in
            !t.first.cancelled && Nearby.catchable(departure: t.first.departure, walk: counted, win)
        }
        return ok.sorted { $0.first.departure < $1.first.departure }
    }

    func way(_ id: String) -> Way? { ways.first { $0.id == id } }
    func bestTrip(_ id: String) -> DoorTrip? { best[id] }
    func option(_ id: String) -> Nearby.Option? { options.first { $0.id == id } }

    /// How sure a trip gets you there on time (`Nearby.sure`): your own rides on its last line to its last stop
    /// (`DelayBook`, from your rides), else how late that line gets now and at this time of day (`Steady`: live times
    /// and what the app saw of it); times the chance you make each change (`Risk.miss`).
    func sure(_ t: DoorTrip) -> Nearby.Sure {
        if let s = sures[t.id] { return s }
        let last: Ride = t.last
        let own: [Double] = DelayBook.shared.delays(line: last.line, stop: last.toStop, at: last.scheduledArrival)
        let model: Double = Steady.late(line: last.line, train: last.isTrain, stop: last.toStop, at: last.scheduledArrival, by: Nearby.lateBy)
        var made: Double = 1
        for i in t.rides.indices.dropFirst() { made *= 1 - Risk.miss(t, at: i) }
        let name: String = LiveDelays.name(last.line, train: last.isTrain)
        let live: Bool = t.rides.contains { $0.live } || LiveDelays.shared.now(line: name).count >= 2
        let s: Nearby.Sure = Nearby.sure(own: own, modelLate: model, made: made, live: live)
        sures[t.id] = s
        return s
    }

    private func recompute() {
        var opts: [Nearby.Option] = []
        var b: [String: DoorTrip] = [:]
        for w in ways {
            let deps: [DoorTrip] = departures(w.id)
            guard let first = deps.min(by: { $0.end < $1.end }) else { continue }
            b[w.id] = first
            let walk: Walk = self.walk(w.group)
            opts.append(Nearby.Option(id: w.id, arrival: first.end, departure: first.first.departure, walk: walk.shown.walk, sure: sure(first)))
        }
        best = b
        options = opts
        tags = Nearby.tags(opts)
    }

    /// The earliest and latest arrival of the stops with a way (for the colours and the legend).
    var arrivals: (earliest: Date, latest: Date)? {
        guard let a = options.map(\.arrival).min(), let z = options.map(\.arrival).max() else { return nil }
        return (a, z)
    }
}
