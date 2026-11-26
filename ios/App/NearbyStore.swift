import CoreLocation
import Foundation

/// The stops around you drawn on the map (0.42, "Fastest trip, zoomed out"): what the map stops answer has within 1 km
/// (`Nearby.dotsRadius`), kept ten minutes per spot.
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
        let answer: Any?
        do {
            answer = try await Transit.$urgent.withValue(true) { () async throws -> Any in try await Transit.get("/v1/map/stops", q) }
        } catch {
            answer = nil
        }
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

/// The ways to the destination from the stops around you (0.42.2). A search is one plan from where you are: the
/// planner walks to every stop around itself (up to 1.6 km), and its ways are put with the stop each gets on at; a
/// second plan (the next page, walking up to 3 km) only while fewer than 3 stops have a way, or when the first got no
/// answer (`Nearby.nextPlan`). The time to leave (now, in 10, in 20) only filters what's in; it asks for the next page
/// only when that time needs it, a second after the switch. A stop tapped is planned from on its own, one at a time,
/// with its next departures (`/v6/stoptimes`). At most two requests at once from here, none more while Transitous asks
/// to slow down. Fastest trip's own ways are always put with their stops. Each search writes one line in the field log.
@MainActor
final class NearbyStore: ObservableObject {
    /// Whether a stop was planned from.
    enum Check: Equatable { case unasked, asking, done, failed }

    /// A stop and its ways to the destination (each first ride with your walk to the stop).
    struct Way: Identifiable {
        let group: Nearby.Group
        var trips: [DoorTrip] = []
        var check: Check = .unasked
        var walked: Int? = nil          // the planner's walk from your spot (minutes), from its own ways
        var seeded = false              // Fastest trip's own way gets on here
        var id: String { group.id }
    }

    /// Your walk to a stop: the planner's minutes (or about how long, by the map), at your own speed (`WalkPlan`).
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
    @Published private(set) var radius: Double = Nearby.searchRadii[0]
    @Published private(set) var busy = false
    @Published private(set) var stopsFailed = false
    @Published private(set) var planFailed = false
    @Published private(set) var fallback = false
    @Published private(set) var leave: Nearby.Leave = .now
    @Published private(set) var window: Nearby.Window = Nearby.window(.now, now: Date())
    @Published private(set) var here: CLLocation?
    /// A stop's next departures (`/v6/stoptimes`) of the lines its ways take, for the stop's sheet.
    @Published private(set) var boards: [String: [BoardDeparture]] = [:]
    private(set) var dest: Place?
    private var seed: [DoorTrip] = []
    private var best: [String: DoorTrip] = [:]
    private var sures: [String: Nearby.Sure] = [:]
    private var task: Task<Void, Never>?
    private var switchTask: Task<Void, Never>?
    private var startedAt: Date?
    // the search's plans: how many went, the next page, whether the last got an answer
    private var plansDone = 0
    private var cursor: String?
    private var lastFailed = false
    // the stops tapped are planned one at a time
    private var lazyChain: Task<Void, Never>?
    private var boardAt: [String: Date] = [:]
    // at most `Nearby.maxConcurrent` requests from here at once
    private var inFlight = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Asked again after this long on screen.
    static let refreshAfter: TimeInterval = 300

    // MARK: asking

    /// Look around `here` for ways to `dest` (again only when you've moved 250 m, it's another destination, or it's a
    /// few minutes old). `seed`: the trips Fastest trip has, put with their stops.
    func open(here h: CLLocation, dest d: Place, seed s: [DoorTrip]) {
        let near: Bool = here.map { $0.distance(from: h) < 250 } ?? false
        let same: Bool = dest?.key == d.key && near && (startedAt.map { Date().timeIntervalSince($0) < Self.refreshAfter } ?? false)
        absorb(s)
        if same { return }
        let fresh: Bool = dest?.key != d.key || !near
        here = h; dest = d
        start(fresh: fresh)
    }

    /// The switch: leave now, in 10 or in 20 minutes. What's in is filtered at once; a second later (the last switch
    /// counts) the next page is asked for when that time needs it. Nothing on its way is stopped.
    func choose(_ l: Nearby.Leave) {
        guard l != leave else { return }
        leave = l
        window = Nearby.window(l, now: Date())
        recompute()
        switchTask?.cancel()
        switchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.morePagesIfNeeded()
        }
    }

    func stop() {
        task?.cancel(); task = nil
        switchTask?.cancel(); switchTask = nil
        busy = false
    }

    /// Once a minute on screen: the window moves on with the clock ("Leave now" is now), and after a few minutes it
    /// asks again (what's in stays meanwhile).
    func tick() {
        guard here != nil, dest != nil, !busy else { return }
        window = Nearby.window(leave, now: Date())
        recompute()
        if let s = startedAt, Date().timeIntervalSince(s) > Self.refreshAfter { start(fresh: false) }
    }

    /// `fresh`: another place or destination (what's shown goes); else the same, asked again (what's shown stays).
    private func start(fresh: Bool) {
        guard let h = here, let d = dest else { return }
        task?.cancel()
        window = Nearby.window(leave, now: Date())
        startedAt = Date()
        stopsFailed = false
        planFailed = false
        plansDone = 0
        cursor = nil
        lastFailed = false
        sures = [:]
        if fresh {
            ways = []
            boards = [:]
            boardAt = [:]
            radius = Nearby.searchRadii[0]
        }
        busy = true
        absorb(seed)
        recompute()
        task = Task { [weak self] in await self?.search(from: h, to: d) }
    }

    /// Where the planner is asked to go: the destination's stop, or its spot when it has several.
    private static func target(_ d: Place) -> String {
        let ids: [String] = PlanMemo.unique(d.ids)
        if ids.count == 1, let one = ids.first { return one }
        return "\(d.coordinate.latitude),\(d.coordinate.longitude)"
    }

    private static func spot(_ h: CLLocation) -> String { "\(h.coordinate.latitude),\(h.coordinate.longitude)" }

    private var cooling: Bool { Net.Polite.transitous.coolingLeft != nil }

    /// The stops with a way in what's in (for the second page).
    private var usefulStops: Int { ways.filter { !$0.trips.isEmpty }.count }

    private func search(from h: CLLocation, to d: Place) async {
        let began = Date()
        var bytes = 0, plans = 0, pages = 0, failed = 0
        await enter()
        let stops: [Nearby.Stop]? = await NearbyFetch.stops(around: h.coordinate, radius: Nearby.dotsRadius)
        exit()
        guard !Task.isCancelled else { return }
        if let stops {
            for g in Nearby.groups(stops, within: Nearby.dotsRadius) where !ways.contains(where: { $0.id == g.id }) {
                ways.append(Way(group: g))
            }
            absorb(seed)
        } else {
            stopsFailed = true
        }
        recompute()
        let from: String = Self.spot(h)
        let to: String = Self.target(d)
        let at: Date = window.leave.addingTimeInterval(-60)
        while !Task.isCancelled,
              let r = Nearby.nextPlan(done: plansDone, useful: usefulStops, hasCursor: cursor != nil, lastFailed: lastFailed, cooling: cooling) {
            let page: String? = lastFailed ? nil : cursor
            let outcome: Transit.PlanOutcome = await askPage(from: from, to: to, at: at, radius: r, cursor: page)
            guard !Task.isCancelled else { return }
            if page != nil { pages += 1 } else { plans += 1 }
            if case .page(let p) = outcome { bytes += p.bytes } else { failed += 1 }
        }
        guard !Task.isCancelled else { return }
        busy = false
        planFailed = failed > 0
        recompute()
        var note: [String] = []
        if cooling { note.append("cooling") }
        if stopsFailed { note.append("no stops") }
        if !seed.isEmpty { note.append("seed \(seed.count)") }
        let line: String = Nearby.logLine(radius: radius, stops: ways.count, plans: plans, pages: pages, ways: options.count, failed: failed,
                                          seconds: Date().timeIntervalSince(began), bytes: bytes, note: note.joined(separator: " · "))
        FieldLog.shared.add(.net, line)
    }

    /// One plan of the search (within the two at once); its ways put with their stops.
    private func askPage(from: String, to: String, at: Date, radius r: Double, cursor page: String?) async -> Transit.PlanOutcome {
        plansDone += 1
        await enter()
        let pre: Int = Nearby.preTransit(radius: r)
        let outcome: Transit.PlanOutcome = await Transit.$urgent.withValue(true) { () async -> Transit.PlanOutcome in
            await Transit.planPage(from: from, to: to, at: at, count: Nearby.itineraries, maxTransfers: 3,
                                   preTransit: pre, window: Nearby.searchWindow, cursor: page)
        }
        exit()
        guard !Task.isCancelled else { return outcome }
        switch outcome {
        case .page(let p):
            lastFailed = false
            cursor = p.next
            radius = max(radius, r)
            for t in p.trips { put(t, planned: nil) }
        case .failed:
            lastFailed = true
        }
        recompute()
        return outcome
    }

    /// After a switch: the next page, when fewer than 3 stops have a way for that time and the search has a plan left.
    private func morePagesIfNeeded() async {
        guard !busy, let h = here, let d = dest else { return }
        let useful: Int = options.filter(\.ranked).count
        guard let r = Nearby.nextPlan(done: plansDone, useful: useful, hasCursor: cursor != nil, lastFailed: lastFailed, cooling: cooling) else { return }
        let began = Date()
        let page: String? = lastFailed ? nil : cursor
        busy = true
        let outcome: Transit.PlanOutcome = await askPage(from: Self.spot(h), to: Self.target(d), at: window.leave.addingTimeInterval(-60),
                                                         radius: r, cursor: page)
        busy = false
        var bytes = 0, failed = 0
        if case .page(let p) = outcome { bytes = p.bytes } else { failed = 1 }
        planFailed = planFailed || failed > 0
        recompute()
        let line: String = Nearby.logLine(radius: radius, stops: ways.count, plans: page == nil ? 1 : 0, pages: page == nil ? 0 : 1,
                                          ways: options.count, failed: failed, seconds: Date().timeIntervalSince(began), bytes: bytes,
                                          note: "after the switch to \(leave.title.lowercased())")
        FieldLog.shared.add(.net, line)
    }

    private func enter() async {
        if inFlight < Nearby.maxConcurrent { inFlight += 1; return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in waiting.append(c) }
    }

    private func exit() {
        if waiting.isEmpty { inFlight = max(0, inFlight - 1); return }
        waiting.removeFirst().resume()          // the place goes on to the next
    }

    // MARK: a stop tapped

    /// The stop's sheet: its own plan when the search had no way from it (one stop at a time, not while Transitous
    /// asks to slow down), and its next departures of the lines its ways take (`/v6/stoptimes`, kept a minute).
    func more(_ id: String) async {
        guard let i = ways.firstIndex(where: { $0.id == id }), dest != nil else { return }
        let needsPlan: Bool = ways[i].trips.isEmpty && (ways[i].check == .unasked || ways[i].check == .failed)
        if needsPlan { ways[i].check = .asking }
        let before: Task<Void, Never>? = lazyChain
        let job = Task { [weak self] in
            await before?.value
            await self?.check(id, plan: needsPlan)
        }
        lazyChain = job
        await job.value
    }

    private func check(_ id: String, plan: Bool) async {
        guard let d = dest, let i0 = ways.firstIndex(where: { $0.id == id }), let first = ways[i0].group.ids.first else { return }
        let began = Date()
        var bytes = 0
        var failed = false
        if plan {
            if cooling {
                failed = true
            } else {
                let walk: Walk = self.walk(ways[i0].group)
                let at: Date = Nearby.planAt(window, walk: walk.planned, now: Date())
                let to: String = Self.target(d)
                await enter()
                let outcome: Transit.PlanOutcome = await Transit.$urgent.withValue(true) { () async -> Transit.PlanOutcome in
                    await Transit.planPage(from: first, to: to, at: at, count: 5, maxTransfers: 3,
                                           preTransit: nil, window: nil, cursor: nil)
                }
                exit()
                switch outcome {
                case .page(let p):
                    bytes += p.bytes
                    for t in p.trips { put(t, planned: id) }
                case .failed:
                    failed = true
                }
            }
            if let i = ways.firstIndex(where: { $0.id == id }), ways[i].check == .asking { ways[i].check = failed ? .failed : .done }
            recompute()
        }
        var boardCount: Int? = nil
        if !cooling, let i = ways.firstIndex(where: { $0.id == id }), !ways[i].trips.isEmpty,
           boardAt[id].map({ Date().timeIntervalSince($0) > 60 }) ?? true {
            let walk: Walk = self.walk(ways[i].group)
            let from: Date = Nearby.planAt(window, walk: walk.counted, now: Date())
            await enter()
            let all: [BoardDeparture] = await Transit.$urgent.withValue(true) { () async -> [BoardDeparture] in
                await Transit.board(stopIds: [first], from: from, n: 16)
            }
            exit()
            boardAt[id] = Date()
            let trips: [DoorTrip] = ways.first { $0.id == id }?.trips ?? []
            boards[id] = Self.sameWay(all, as: trips)
            boardCount = boards[id]?.count
        }
        let n: Int = departures(id).count
        FieldLog.shared.add(.net, Nearby.stopLogLine(planned: plan, failed: failed, ways: n, board: boardCount,
                                                      seconds: Date().timeIntervalSince(began), bytes: bytes))
    }

    /// The departures of a board that go the way the stop's ways go: their lines and directions, not one of them.
    private static func sameWay(_ all: [BoardDeparture], as trips: [DoorTrip]) -> [BoardDeparture] {
        let firsts: [Ride] = trips.map(\.first)
        let taken: Set<String> = Set(firsts.map(\.tripId))
        let lines: Set<String> = Set(firsts.map { "\($0.name)|\($0.headsign)" })
        let bare: Set<String> = Set(firsts.filter { $0.headsign.isEmpty }.map(\.name))
        return all.filter { (b: BoardDeparture) -> Bool in
            guard !b.cancelled, !taken.contains(b.tripId) else { return false }
            return lines.contains("\(b.line)|\(b.headsign)") || bare.contains(b.line)
        }
    }

    // MARK: putting ways with their stops

    /// Fastest trip's own trips (from your spot), with the stops they leave from (a stop of its own when it's none of
    /// those around).
    func absorb(_ s: [DoorTrip]) {
        let usable: [DoorTrip] = s.filter { !$0.rides.isEmpty && $0.first.fromId != "onboard" && !$0.first.fromId.isEmpty }
        guard !usable.isEmpty else { return }
        seed = usable
        for t in usable {
            if let i = put(t, planned: nil) { ways[i].seeded = true }
        }
        recompute()
    }

    /// A way, with the stop it gets on at (`Nearby.groupIndex`; a stop of its own when it's none of these). From your
    /// spot (`planned` nil) its walk is the planner's; planned from a stop (`planned`: that stop), the walk to the stop
    /// it gets on at is put first. One per departure: the newest answer.
    @discardableResult
    private func put(_ t: DoorTrip, planned gid: String?) -> Int? {
        guard !t.rides.isEmpty, let h = here else { return nil }
        let f: Ride = t.first
        guard f.fromId != "onboard" else { return nil }
        let b = Nearby.Boarding(id: f.fromId, name: f.fromStop, lat: f.fromLat, lon: f.fromLon, rail: f.isTrain)
        let groups: [Nearby.Group] = ways.map(\.group)
        var at: Int? = Nearby.groupIndex(b, in: groups)
        if at == nil, f.walkBefore == 0, let g = gid { at = ways.firstIndex { $0.id == g } }
        if at == nil, let g = Nearby.newGroup(b, here: GeoPoint(h.coordinate), taken: Set(groups.map(\.id))) {
            ways.append(Way(group: g, check: .done))
            at = ways.count - 1
        }
        guard let i = at else { return nil }
        var mine: DoorTrip = t
        if gid != nil {
            let planned: Int = Nearby.plannedWalk(straight: ways[i].group.metres)
            let ride: Ride = f.walking(planned)
            mine = DoorTrip(rides: [ride] + Array(t.rides.dropFirst()), start: ride.departure.addingTimeInterval(-Double(planned) * 60), end: t.end)
        } else if f.walkBefore > 0 {
            ways[i].walked = min(ways[i].walked ?? Int.max, f.walkBefore)
        }
        if let j = ways[i].trips.firstIndex(where: { $0.first.tripId == f.tripId }) {
            ways[i].trips[j] = mine
        } else {
            ways[i].trips.append(mine)
        }
        if ways[i].check == .unasked || ways[i].check == .failed { ways[i].check = .done }
        return i
    }

    // MARK: what's shown

    /// Your walk to a stop: the planner's from your spot once a way of it is in, else about how long by the map.
    func walk(_ g: Nearby.Group) -> Walk {
        let b: HabitBook = HabitStore.shared.book
        let metres: Double = Nearby.walkMetres(straight: g.metres)
        if let p = ways.first(where: { $0.id == g.id })?.walked {
            // (the planner walked at your speed once it's learned)
            let used: Double = HabitStore.pedestrianSpeed() ?? Habits.plannerWalk
            let shown: WalkPlan.Shown = WalkPlan.shown(planned: p, metres: nil, speed: Habits.walkSpeed(b), walks: b.walks.count,
                                                       plannerSpeed: used)
            return Walk(planned: p, shown: shown, metres: metres)
        }
        let planned: Int = Nearby.plannedWalk(straight: g.metres)
        let shown: WalkPlan.Shown = WalkPlan.shown(planned: planned, metres: metres, speed: Habits.walkSpeed(b), walks: b.walks.count,
                                                   plannerSpeed: Habits.plannerWalk)
        return Walk(planned: planned, shown: shown, metres: metres)
    }

    /// A way as the window looks at it: when you leave your door (your walk counted once), and its longest change.
    private func dep(_ t: DoorTrip, later: Int) -> Nearby.Dep {
        var longest: TimeInterval = 0
        for k in t.rides.indices.dropFirst() {
            let wait: TimeInterval = t.rides[k].departure.timeIntervalSince(t.rides[k - 1].arrival)
            longest = max(longest, wait)
        }
        let door: Date = t.start.addingTimeInterval(Double(later) * 60)
        return Nearby.Dep(door: door, departure: t.first.departure, arrival: t.end, cancelled: t.first.cancelled, longestWait: longest)
    }

    private func deps(_ w: Way) -> [Nearby.Dep] {
        let later: Int = walk(w.group).shown.later
        return w.trips.map { dep($0, later: later) }
    }

    /// A stop's departures you make (`Nearby.shown`: those in the window and at least the next two), by when they leave.
    func departures(_ id: String) -> [DoorTrip] {
        guard let w = ways.first(where: { $0.id == id }) else { return [] }
        let ds: [Nearby.Dep] = deps(w)
        let idx: [Int] = Nearby.shown(ds, window)
        if idx.isEmpty, fallback, w.seeded {
            return Nearby.shown(ds, Nearby.window(.now, now: Date())).map { w.trips[$0] }
        }
        return idx.map { w.trips[$0] }
    }

    /// Overnight or much later (`Nearby.late`): shown apart, never ranked.
    func isLate(_ t: DoorTrip, at id: String) -> Bool {
        guard let w = ways.first(where: { $0.id == id }) else { return false }
        return Nearby.late(dep(t, later: walk(w.group).shown.later), window)
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

    private func option(for w: Way, _ t: DoorTrip, ranked: Bool) -> Nearby.Option {
        let walk: Walk = self.walk(w.group)
        return Nearby.Option(id: w.id, arrival: t.end, departure: t.first.departure, walk: walk.shown.walk, sure: sure(t), ranked: ranked)
    }

    private func recompute() {
        var opts: [Nearby.Option] = []
        var b: [String: DoorTrip] = [:]
        for w in ways {
            guard let pick = Nearby.best(deps(w), window) else { continue }
            let t: DoorTrip = w.trips[pick.index]
            b[w.id] = t
            opts.append(option(for: w, t, ranked: pick.ranked))
        }
        // at worst Fastest trip's own way, from its stop (nothing found for that time yet)
        var fb = false
        if opts.isEmpty {
            let nowWindow: Nearby.Window = Nearby.window(.now, now: Date())
            for w in ways where w.seeded {
                guard let pick = Nearby.best(deps(w), nowWindow) else { continue }
                let t: DoorTrip = w.trips[pick.index]
                b[w.id] = t
                opts.append(option(for: w, t, ranked: false))
                fb = true
            }
        }
        fallback = fb
        best = b
        options = opts
        tags = Nearby.tags(opts)
    }

    /// The earliest and latest arrival of the ranked stops (for the colours and the legend); of them all when none is.
    var arrivals: (earliest: Date, latest: Date)? {
        let ranked: [Nearby.Option] = options.filter(\.ranked)
        let use: [Nearby.Option] = ranked.isEmpty ? options : ranked
        guard let a = use.map(\.arrival).min(), let z = use.map(\.arrival).max() else { return nil }
        return (a, z)
    }

    /// What the screen says about the search (`Nearby.statusLine`).
    var situation: Nearby.Situation {
        var s = Nearby.Situation()
        s.located = here != nil
        s.stopsFailed = stopsFailed
        s.busy = busy
        s.options = options.count
        s.planFailed = planFailed
        s.unchecked = ways.filter { $0.check == .failed }.count
        s.seed = !seed.isEmpty
        s.fallback = fallback
        s.cooling = cooling
        return s
    }
}
