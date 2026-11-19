import Foundation

// Friends (0.28): the compare screen's and meet halfway's questions to the planner. Each person's way to school (by
// their first class) and home (after their last) comes from their start area, one question each, through Transitous'
// limiter (`Net`'s background lane) and the planner's own memo, then kept here per day (`WayCache`): 30 minutes for
// today and tomorrow, 6 hours for later days. On demand only: the screen looks up the next school day you share by
// itself, any other day when you tap it; at most `RequestBudget.compare` questions while it's open, and
// `RequestBudget.meet` per meet-halfway search.

/// The planner's ways, kept per question for the day.
@MainActor
final class WayCache {
    static let shared = WayCache()

    private struct Entry: Codable { var ways: [Way]; var at: Date; var asked: Date }
    private var items: [String: Entry] = [:]
    private static var file: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("friend-ways.json")
    }

    private init() {
        if let f = Self.file, let d = try? Data(contentsOf: f), let l = try? FriendJSON.decoder.decode([String: Entry].self, from: d) {
            items = l.filter { $0.value.at > Date().addingTimeInterval(-86400) }
        }
    }

    static func key(_ dir: SharedRides.Direction, from: String, to: String, at: Date) -> String {
        "\(dir.rawValue)|\(from)|\(to)|\(Int(at.timeIntervalSince1970 / 60))"
    }

    /// A kept answer still good: 30 minutes for a time within a day and a half, else 6 hours.
    func get(_ k: String, at: Date, now: Date = Date()) -> [Way]? {
        guard let e = items[k] else { return nil }
        let ttl: TimeInterval = at.timeIntervalSince(now) < 36 * 3600 ? 30 * 60 : 6 * 3600
        let age = now.timeIntervalSince(e.asked)
        return age >= 0 && age < ttl ? e.ways : nil
    }

    func put(_ k: String, ways: [Way], at: Date) {
        items[k] = Entry(ways: ways, at: at, asked: Date())
        if items.count > 200 {
            let old = items.sorted { $0.value.asked < $1.value.asked }.prefix(items.count - 200).map(\.key)
            for o in old { items[o] = nil }
        }
        guard let f = Self.file, let d = try? FriendJSON.encoder.encode(items) else { return }
        try? d.write(to: f, options: .atomic)
    }
}

/// The planner's trips as plain ways (and back, for the trip card).
enum WayMaking {
    static func spot(_ name: String, id: String?, lat: Double?, lon: Double?) -> TripCard.Spot {
        let plainId: String? = (id ?? "").isEmpty || (id ?? "").contains(",") ? nil : id
        return TripCard.Spot(name: name, id: plainId, lat: lat, lon: lon)
    }

    static func leg(_ r: Ride) -> WayLeg {
        WayLeg(trip: r.tripId, mode: r.isTrain ? "train" : "bus", line: r.line, num: r.num.isEmpty ? nil : r.num,
               name: r.name.isEmpty || r.name == r.line ? nil : r.name, head: r.headsign.isEmpty ? nil : r.headsign,
               from: spot(r.fromStop, id: r.fromId, lat: r.fromLat, lon: r.fromLon),
               to: spot(r.toStop, id: nil, lat: r.toLat, lon: r.toLon),
               dep: r.departure, arr: r.arrival, plat: r.platform, walk: r.walkBefore > 0 ? r.walkBefore : nil)
    }

    static func way(_ t: DoorTrip) -> Way { Way(legs: t.rides.map(leg), start: t.start, end: t.end) }

    /// Where a spot is asked from or to: its stop id, else its place.
    static func place(_ s: TripCard.Spot) -> String? {
        if let id = s.id, !id.isEmpty { return id }
        guard let p = s.point else { return nil }
        return "\(p.lat),\(p.lon)"
    }

    static func route(_ s: BoardAt.Stop) -> RouteStop {
        RouteStop(name: s.name, id: s.id.isEmpty ? nil : s.id, point: s.point, dep: s.departure, arr: s.arrival ?? s.departure,
                  boarding: s.boarding)
    }
}

/// One day's rides together, as looked up.
struct DayRides: Equatable {
    var school: [SharedRide] = []
    var home: [SharedRide] = []
    var done = false
    /// Some questions got no answer (offline, or the budget ran out).
    var partial = false
}

/// The compare screen: you and a friend, or a group.
@MainActor
final class CompareModel: ObservableObject {
    /// The chat it's for: a friend's account, or `g.<group id>`.
    let key: String
    @Published private(set) var people: [ComparePerson] = []
    @Published private(set) var days: [CompareDay] = []
    @Published private(set) var rides: [String: DayRides] = [:]
    @Published private(set) var loading: Set<String> = []
    @Published private(set) var budget = RequestBudget(limit: RequestBudget.compare)

    init(key: String) { self.key = key }

    var me: String { FriendStore.shared.myAccount ?? "" }
    var groupId: String? { ChatKey.groupId(key) }

    /// "you", or their name.
    func name(_ id: String) -> String {
        if id == me { return "you" }
        return people.first { $0.id == id }?.name ?? FriendStore.shared.name(id)
    }

    func title(_ id: String) -> String { id == me ? "You" : name(id) }

    /// Who's in it, with what they shared (and yours, read now).
    func reload() async {
        let store = FriendStore.shared
        let tt = FriendTimetables.shared
        _ = await tt.readMine()
        var list: [ComparePerson] = [ComparePerson(id: me, name: "You", isMe: true, timetable: tt.mine, area: tt.myArea)]
        let others: [(String, String)]
        if let gid = groupId, let g = store.group(gid) {
            others = g.others(me).map { ($0.id, store.name($0.id)) }
        } else if let f = store.book?.friend(key) {
            others = [(f.id, f.name)]
        } else {
            others = []
        }
        for (id, n) in others {
            list.append(ComparePerson(id: id, name: n, timetable: tt.timetable(id), area: tt.area(id)))
        }
        people = list
        days = Compare.days(list, now: Date())
    }

    /// The next school day you share, looked up by itself.
    func autoLoad() async {
        guard let k = Compare.nextShared(days, now: Date()), rides[k] == nil else { return }
        await load(k)
    }

    /// The rides together on a day: everyone's ways there and home (kept, or one question each), matched.
    func load(_ dayKey: String) async {
        guard let day = days.first(where: { $0.key == dayKey }), !loading.contains(dayKey) else { return }
        loading.insert(dayKey)
        defer { loading.remove(dayKey) }
        var out = DayRides()
        let school: [PersonWays] = await ways(day, .toSchool, partial: &out.partial)
        let home: [PersonWays] = await ways(day, .home, partial: &out.partial)
        out.school = SharedRides.shown(SharedRides.match(school, .toSchool))
        out.home = SharedRides.shown(SharedRides.match(home, .home))
        out.done = true
        rides[dayKey] = out
    }

    private func ways(_ day: CompareDay, _ dir: SharedRides.Direction, partial: inout Bool) async -> [PersonWays] {
        var out: [PersonWays] = []
        let now = Date()
        for pd in day.atSchool {
            guard let p = people.first(where: { $0.id == pd.id }), let a = p.area else { continue }
            guard let q = Self.question(pd, area: a, dir) else { continue }
            if dir == .toSchool, q.at < now.addingTimeInterval(5 * 60) { continue }     // (on its way already)
            if dir == .home, q.at.addingTimeInterval(60 * 60) < now { continue }
            var got: [Way]? = Self.cached(q)
            if got == nil, budget.take() { got = await Self.fetch(q) }
            if let got { out.append(PersonWays(id: p.id, ways: got, bound: q.bound)) } else { partial = true }
        }
        return out
    }

    struct Question {
        var dir: SharedRides.Direction
        var from: String
        var to: String
        /// Asked for: to school when to be there; home when to leave.
        var at: Date
        var bound: Date
    }

    /// The question for someone's day: from their start to school by their first class (minus how early they like to
    /// be there), or from school home from 5 minutes after their last.
    static func question(_ pd: PersonDay, area a: TimetableArea, _ dir: SharedRides.Direction, by: Date? = nil) -> Question? {
        guard let start = a.start, let s = WayMaking.place(start), let sch = WayMaking.place(a.school) else { return nil }
        switch dir {
        case .toSchool:
            let bound: Date
            if let by { bound = by } else if let f = pd.first { bound = f.addingTimeInterval(-Double(a.earlyMinutes) * 60) } else { return nil }
            return Question(dir: dir, from: s, to: sch, at: bound, bound: bound)
        case .home:
            guard let e = pd.lastEnd else { return nil }
            let leave = e.addingTimeInterval(5 * 60)
            return Question(dir: dir, from: sch, to: s, at: leave, bound: e)
        }
    }

    /// Kept, or one question (if the budget has one left). Nil: no answer.
    static func ask(_ q: Question, budget: inout RequestBudget) async -> [Way]? {
        if let hit = cached(q) { return hit }
        guard budget.take() else { return nil }
        return await fetch(q)
    }

    static func cached(_ q: Question) -> [Way]? {
        WayCache.shared.get(WayCache.key(q.dir, from: q.from, to: q.to, at: q.at), at: q.at)
    }

    /// One question to the planner (kept for the day when it answers).
    static func fetch(_ q: Question) async -> [Way]? {
        let trips = await Transit.plan(from: q.from, to: q.to, modes: nil, at: q.at, count: 5, maxTransfers: 3, arriveBy: q.dir == .toSchool)
        guard !trips.isEmpty else { return nil }
        let ways = trips.map(WayMaking.way)
        WayCache.shared.put(WayCache.key(q.dir, from: q.from, to: q.to, at: q.at), ways: ways, at: q.at)
        return ways
    }
}

/// Meet halfway: a bus or train all of you (or most) can be on, on a day, by each first class or a time you pick.
@MainActor
final class MeetModel: ObservableObject {
    @Published private(set) var plans: [MeetPlan] = []
    @Published private(set) var busy = false
    @Published private(set) var searched = false
    @Published private(set) var note: String?
    @Published private(set) var asked = 0
    /// Each person's "be there by" and where they go (for the cards).
    private(set) var bounds: [String: Date] = [:]
    private(set) var schools: [String: TripCard.Spot] = [:]

    func search(people: [ComparePerson], day: CompareDay, by: Date?) async {
        busy = true
        defer { busy = false; searched = true }
        var budget = RequestBudget(limit: RequestBudget.meet)
        var mine: [PersonWays] = []
        var starts: [String: GeoPoint] = [:]
        var dests: [String: GeoPoint] = [:]
        var startSpots: [String: TripCard.Spot] = [:]
        bounds = [:]
        schools = [:]
        var left: [String] = []
        for p in people {
            guard let a = p.area, let start = a.start, let sp = start.point, let dp = a.school.point else { left.append(p.id); continue }
            let pd: PersonDay = day.person(p.id) ?? PersonDay(id: p.id, known: false, classes: [])
            guard let q = CompareModel.question(pd, area: a, .toSchool, by: by) else { left.append(p.id); continue }
            starts[p.id] = sp; dests[p.id] = dp; startSpots[p.id] = start
            bounds[p.id] = q.bound
            schools[p.id] = a.school
            if let w = await CompareModel.ask(q, budget: &budget) { mine.append(PersonWays(id: p.id, ways: w, bound: q.bound)) }
        }
        var found = MeetHalfway.plans(mine)
        // nobody shares a ride by themselves: try onto the main ride of the first two of you
        if found.isEmpty {
            for p in mine.prefix(2) {
                guard let s = Self.seed(p, all: mine.map(\.id)) else { continue }
                found.append(s)
            }
        }
        // those not on it yet: onto it at a stop of its route near them (the best two plans)
        var better: [MeetPlan] = []
        for first in found.prefix(2) {
            var plan: MeetPlan = first
            if plan.missing.isEmpty { better.append(plan); continue }
            guard budget.take(), let stops = await Transit.boardStops(plan.ride.trip, maxAge: 300) else { better.append(plan); continue }
            let route: [RouteStop] = stops.map(WayMaking.route)
            guard let template = Self.template(plan) else { better.append(plan); continue }
            for m in plan.missing {
                guard let st = starts[m], let ds = dests[m], let bound = bounds[m], let from = startSpots[m] else { continue }
                let own: [Way] = mine.first { $0.id == m }?.ways ?? []
                for j in MeetHalfway.joins(route: route, ride: plan.ride, start: st, dest: ds, deadline: bound, own: own, now: Date()) {
                    var before: Way?
                    if Geo.metres(st, route[j.board].point) > MeetHalfway.walkTo {
                        guard let dep = route[j.board].dep, let fromId = WayMaking.place(from), budget.take() else { continue }
                        let to = route[j.board].id ?? "\(route[j.board].point.lat),\(route[j.board].point.lon)"
                        let at = dep.addingTimeInterval(-MeetHalfway.boardMargin)
                        let trips = await Transit.plan(from: fromId, to: to, modes: nil, at: at, count: 3, maxTransfers: 3, arriveBy: true)
                        before = trips.map(WayMaking.way).filter { $0.end <= dep.addingTimeInterval(-60) }.max { $0.start < $1.start }
                        if before == nil { continue }
                    }
                    if let w = MeetHalfway.joined(j, ride: plan.ride, template: template, route: route, start: st, before: before, deadline: bound) {
                        plan = MeetHalfway.adding(plan, id: m, way: w, trip: plan.ride.trip)
                        break
                    }
                }
            }
            better.append(plan)
        }
        let all: [MeetPlan] = better + found.dropFirst(min(2, found.count)).map { $0 }
        let shown: [MeetPlan] = all.filter { $0.ride.riders.count >= 2 }
        plans = Array(MeetHalfway.rank(shown, bounds: bounds).prefix(4))
        asked = budget.used
        if plans.isEmpty {
            note = left.count == people.count ? "Nobody here has shared a start area yet." : "No bus or train found that two of you can be on in time."
        } else {
            note = left.isEmpty ? nil : "\(left.count == 1 ? "1 person hasn’t" : "\(left.count) people haven’t") shared where they start yet."
        }
    }

    /// Someone's main ride (the longest of their latest way: the train, mostly) as a ride to get the others onto.
    static func seed(_ p: PersonWays, all: [String]) -> MeetPlan? {
        let ok = SharedRides.usable(p, .toSchool)
        guard let wi = ok.max(by: { p.ways[$0].start < p.ways[$1].start }) else { return nil }
        let w = p.ways[wi]
        guard let li = w.legs.indices.max(by: { w.legs[$0].arr.timeIntervalSince(w.legs[$0].dep) < w.legs[$1].arr.timeIntervalSince(w.legs[$1].dep) }) else { return nil }
        let l = w.legs[li]
        let r = Rider(id: p.id, way: wi, leg: li, board: l.from, dep: l.dep, alight: l.to, arr: l.arr)
        let ride = SharedRide(trip: l.trip, mode: l.mode, line: l.line, num: l.num, riders: [r])
        return MeetPlan(kind: .sameRide, ride: ride, ways: [p.id: w], missing: all.filter { $0 != p.id })
    }

    /// The shared leg as one of the riders has it.
    static func template(_ p: MeetPlan) -> WayLeg? {
        for r in p.ride.riders {
            if let w = p.ways[r.id], w.legs.indices.contains(r.leg), w.legs[r.leg].trip == p.ride.trip { return w.legs[r.leg] }
        }
        return nil
    }
}
