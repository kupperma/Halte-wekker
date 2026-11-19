import Foundation

// Friends (0.28): the rides you can share, and meeting halfway. Each person's ways (from the planner, on the phone:
// from their start area to their school by their first class, or home after their last) are compared by the vehicle:
// the same trip id on a leg of two people's ways is the same bus or train, whichever stop each gets on at. Plain
// values, tested without the planner or the UI. Foundation only.

/// One bus or train of a way.
struct WayLeg: Codable, Equatable, Sendable {
    /// The vehicle's trip id as Transitous names it: the same id is the same bus or train.
    var trip: String
    /// "train" or "bus" (others read as train).
    var mode: String
    /// As shown: "IC", "SPR", "305".
    var line: String
    var num: String? = nil
    var name: String? = nil
    var head: String? = nil
    var from: TripCard.Spot
    var to: TripCard.Spot
    var dep: Date
    var arr: Date
    var plat: String? = nil
    /// Minutes of walking before it.
    var walk: Int? = nil

    var isTrain: Bool { mode != "bus" }
    /// "IC 3512", "Bus 305".
    var label: String {
        if isTrain { return num.map { "\(line) \($0)" } ?? line }
        return "Bus \(line)"
    }
    var card: TripCard.Ride {
        TripCard.Ride(mode: isTrain ? "train" : "bus", line: line, name: name, num: num, trip: trip, head: head, from: from, to: to,
                      dep: dep, arr: arr, plat: plat, walk: walk)
    }
}

/// One way somewhere: its rides, when you leave the door and when you get there.
struct Way: Codable, Equatable, Sendable {
    var legs: [WayLeg]
    var start: Date
    var end: Date

    var changes: Int { max(0, legs.count - 1) }
}

/// Someone's ways for one day and one direction, and what they must fit.
struct PersonWays: Equatable {
    var id: String
    var ways: [Way]
    /// To school: be there by (first class minus how early they like to be). Home: leave after (last class's end).
    var bound: Date
}

/// Someone on a shared ride: which of their ways, which leg, and where they get on and off.
struct Rider: Equatable {
    var id: String
    var way: Int
    var leg: Int
    var board: TripCard.Spot
    var dep: Date
    var alight: TripCard.Spot
    var arr: Date
}

/// A bus or train two or more of you can be on.
struct SharedRide: Equatable {
    var trip: String
    var mode: String
    var line: String
    var num: String?
    var riders: [Rider]

    var ids: [String] { riders.map(\.id) }
    var isTrain: Bool { mode != "bus" }
    var label: String {
        if isTrain { return num.map { "\(line) \($0)" } ?? line }
        return "Bus \(line)"
    }
    /// The first of you gets on.
    var firstDep: Date { riders.map(\.dep).min() ?? .distantPast }
    func rider(_ id: String) -> Rider? { riders.first { $0.id == id } }
}

enum SharedRides {
    enum Direction: String, Codable { case toSchool, home }

    /// A way is one you'd take: to school, there in time and no more than `slack` before your latest such way; home,
    /// leaving after your last class and no more than `slack` after your earliest such way.
    static let slack: TimeInterval = 45 * 60

    static func usable(_ p: PersonWays, _ dir: Direction) -> [Int] {
        switch dir {
        case .toSchool:
            let ok = p.ways.indices.filter { p.ways[$0].end <= p.bound.addingTimeInterval(60) }
            guard let latest = ok.map({ p.ways[$0].end }).max() else { return [] }
            return ok.filter { p.ways[$0].end >= latest.addingTimeInterval(-slack) }
        case .home:
            let ok = p.ways.indices.filter { p.ways[$0].start >= p.bound.addingTimeInterval(-60) }
            guard let earliest = ok.map({ p.ways[$0].start }).min() else { return [] }
            return ok.filter { p.ways[$0].start <= earliest.addingTimeInterval(slack) }
        }
    }

    /// The buses and trains two or more of you can be on, the most of you first, then the longest ride together, then
    /// the earliest. For each person the way that fits best (to school the one leaving latest; home the one there
    /// first).
    static func match(_ people: [PersonWays], _ dir: Direction) -> [SharedRide] {
        var byTrip: [String: [String: Rider]] = [:]
        var meta: [String: WayLeg] = [:]
        for p in people {
            let ok = usable(p, dir)
            for wi in ok {
                let w = p.ways[wi]
                for (li, l) in w.legs.enumerated() where !l.trip.isEmpty {
                    let r = Rider(id: p.id, way: wi, leg: li, board: l.from, dep: l.dep, alight: l.to, arr: l.arr)
                    if let had = byTrip[l.trip]?[p.id] {
                        let hw = p.ways[had.way]
                        let better: Bool = (dir == .toSchool) ? (w.start > hw.start) : (w.end < hw.end)
                        if !better { continue }
                    }
                    byTrip[l.trip, default: [:]][p.id] = r
                    if meta[l.trip] == nil { meta[l.trip] = l }
                }
            }
        }
        var out: [SharedRide] = []
        for (trip, riders) in byTrip where riders.count >= 2 {
            guard let l = meta[trip] else { continue }
            let list: [Rider] = riders.values.sorted { ($0.dep, $0.id) < ($1.dep, $1.id) }
            out.append(SharedRide(trip: trip, mode: l.mode, line: l.line, num: l.num, riders: list))
        }
        return out.sorted { a, b in
            if a.riders.count != b.riders.count { return a.riders.count > b.riders.count }
            let ta = together(a), tb = together(b)
            if ta != tb { return ta > tb }
            if a.firstDep != b.firstDep { return a.firstDep < b.firstDep }
            return a.trip < b.trip
        }
    }

    /// Seconds all of a ride's riders are on it at once (from the last one getting on to the first one getting off).
    static func together(_ r: SharedRide) -> TimeInterval {
        guard let on = r.riders.map(\.dep).max(), let off = r.riders.map(\.arr).min() else { return 0 }
        return max(0, off.timeIntervalSince(on))
    }

    /// The rides to show: the best, and others only when they bring someone else together (a different set of
    /// people), at most `limit`.
    static func shown(_ all: [SharedRide], limit: Int = 3) -> [SharedRide] {
        var out: [SharedRide] = []
        var sets: [Set<String>] = []
        for r in all {
            let s = Set(r.ids)
            if sets.contains(where: { s.isSubset(of: $0) }) { continue }
            out.append(r)
            sets.append(s)
            if out.count >= limit { break }
        }
        return out
    }
}

/// The words for shared rides.
enum RideWords {
    /// "IC 3512 · 07:41 from Eindhoven Centraal"
    static func headline(_ r: SharedRide) -> String {
        guard let first = r.riders.min(by: { $0.dep < $1.dep }) else { return r.label }
        return "\(r.label) · \(TimetableDays.hhmm(first.dep)) from \(first.board.name)"
    }

    /// "you, Sam (gets on at Tilburg 08:03) and Lisa": who's on it; someone who gets on somewhere else than the first
    /// says where and when.
    static func riders(_ r: SharedRide, name: (String) -> String) -> String {
        guard let first = r.riders.min(by: { $0.dep < $1.dep }) else { return "" }
        let parts: [String] = r.riders.map { x in
            let n = name(x.id)
            if x.board.name == first.board.name { return n }
            let on = n == "you" ? "get on" : "gets on"
            return "\(n) (\(on) at \(x.board.name) \(TimetableDays.hhmm(x.dep)))"
        }
        return CompareWords.names(parts)
    }

    /// Why someone isn't on a day's shared ride: "Tom starts 10:45", "Tom ends 17:15", "Tom: no classes", "Tom hasn't
    /// shared this day", "Tom: no start area yet", "Tom: no ride in common".
    static func missing(_ p: PersonDay, _ dir: SharedRides.Direction, name: String, hasArea: Bool) -> String {
        if !p.known { return "\(name) hasn’t shared this day" }
        guard p.hasSchool else { return "\(name): no classes" }
        if !hasArea { return "\(name): no start area yet" }
        switch dir {
        case .toSchool:
            if let f = p.first { return "\(name) starts \(TimetableDays.hhmm(f))" }
        case .home:
            if let e = p.lastEnd { return "\(name) ends \(TimetableDays.hhmm(e))" }
            return "\(name): end time not known"
        }
        return "\(name): no ride in common"
    }
}

// MARK: meet halfway

/// A stop of a bus or train's whole trip (from its own answer).
struct RouteStop: Equatable, Sendable {
    var name: String
    var id: String?
    var point: GeoPoint
    var dep: Date?
    var arr: Date?
    /// You may get on there.
    var boarding: Bool = true

    var spot: TripCard.Spot { TripCard.Spot(name: name, id: id, lat: point.lat, lon: point.lon) }
}

/// One way for all of you (or most): the vehicle you share, and everyone's own way with it.
struct MeetPlan: Equatable, Identifiable {
    enum Kind: Equatable {
        /// The same bus or train, each getting on at their own stop.
        case sameRide
        /// You all get on at the same stop, coming from different places: meet there first.
        case meetAt(TripCard.Spot, Date)
    }

    var kind: Kind
    var ride: SharedRide
    /// Everyone's whole way, by account.
    var ways: [String: Way]
    /// The people it doesn't fit (no way onto it in time).
    var missing: [String]

    var id: String { ride.trip + "|" + ride.ids.joined(separator: ",") }
}

/// How someone not on a shared ride could still get on it: where on, where off, and how they go on from there.
struct MeetJoin: Equatable {
    var board: Int
    var alight: Int
    /// After getting off: a walk of this many minutes to where they're going…
    var walkAfter: Int?
    /// …or the rest of one of their own ways, from that stop.
    var rest: [WayLeg]
}

enum MeetHalfway {
    /// Get there this long before the shared ride leaves (a way to its stop must arrive by then).
    static let boardMargin: TimeInterval = 3 * 60
    /// A stop this close to where you're going is a walk from there.
    static let walkFrom = 1500.0
    /// A stop this close to your start is a walk to it.
    static let walkTo = 900.0
    /// The same stop as a leg of your own way (to go on from there with it).
    static let sameStop = 300.0
    /// A change onto the rest of your own way needs at least this long.
    static let changeMargin: TimeInterval = 3 * 60

    /// Step 1, from everyone's own ways alone (no more questions): each bus or train two or more of you can be on,
    /// with everyone's way that has it (each person's `bound`: be there by).
    static func plans(_ people: [PersonWays]) -> [MeetPlan] {
        let rides = SharedRides.match(people, .toSchool)
        let all: [String] = people.map(\.id)
        var out: [MeetPlan] = []
        for r in rides {
            var ways: [String: Way] = [:]
            for x in r.riders {
                guard let p = people.first(where: { $0.id == x.id }), p.ways.indices.contains(x.way) else { continue }
                ways[x.id] = p.ways[x.way]
            }
            let missing = all.filter { ways[$0] == nil }
            out.append(MeetPlan(kind: kind(r, ways: ways), ride: r, ways: ways, missing: missing))
        }
        let bounds: [String: Date] = Dictionary(people.map { ($0.id, $0.bound) }, uniquingKeysWith: { a, _ in a })
        return rank(out, bounds: bounds)
    }

    /// Everyone gets on at the same stop and someone comes from somewhere else first: meet there (at the time the last
    /// of you gets there, else a few minutes before it leaves). Else the same ride, each from their own stop.
    static func kind(_ r: SharedRide, ways: [String: Way]) -> MeetPlan.Kind {
        guard let first = r.riders.first else { return .sameRide }
        let oneStop: Bool = r.riders.allSatisfy { x in
            x.board.name == first.board.name || near(x.board, first.board, within: Self.sameStop)
        }
        let someoneComes: Bool = r.riders.contains { $0.leg > 0 }
        guard oneStop, someoneComes, r.riders.count >= 2 else { return .sameRide }
        let arrivals: [Date] = r.riders.compactMap { x in
            guard x.leg > 0, let w = ways[x.id], w.legs.indices.contains(x.leg - 1) else { return nil }
            return w.legs[x.leg - 1].arr
        }
        let at: Date = arrivals.max() ?? first.dep.addingTimeInterval(-5 * 60)
        return .meetAt(first.board, min(at, first.dep))
    }

    /// Everyone first; then the fewest missing; then the least time to spare at the other end (waiting about), then
    /// the fewest changes.
    static func rank(_ list: [MeetPlan], bounds: [String: Date] = [:]) -> [MeetPlan] {
        func waits(_ p: MeetPlan) -> TimeInterval {
            var total: TimeInterval = 0
            for (id, w) in p.ways {
                let by: Date = bounds[id] ?? w.end
                total += max(0, by.timeIntervalSince(w.end))
            }
            return total
        }
        func changes(_ p: MeetPlan) -> Int { p.ways.values.reduce(0) { $0 + $1.changes } }
        return list.sorted { a, b in
            if a.missing.count != b.missing.count { return a.missing.count < b.missing.count }
            if a.ride.riders.count != b.ride.riders.count { return a.ride.riders.count > b.ride.riders.count }
            let wa = waits(a), wb = waits(b)
            if wa != wb { return wa < wb }
            let ca = changes(a), cb = changes(b)
            if ca != cb { return ca < cb }
            return a.id < b.id
        }
    }

    static func near(_ a: TripCard.Spot, _ b: TripCard.Spot, within m: Double) -> Bool {
        guard let p = a.point, let q = b.point else { return false }
        return Geo.metres(p, q) <= m
    }

    /// Step 2: where someone not on the ride could get on it (stops before the last rider gets off, that it still
    /// leaves from at least `boardMargin` plus 7 minutes from now, where you may board), the nearest to their start
    /// first, at most `limit`, each with a way on from where they'd get off: a stop within `walkFrom` of where
    /// they're going, else one their own way leaves from (in time for its next leg, still there by their deadline).
    static func joins(route: [RouteStop], ride: SharedRide, start: GeoPoint, dest: GeoPoint, deadline: Date,
                      own: [Way], now: Date, limit: Int = 2) -> [MeetJoin] {
        guard route.count >= 2 else { return [] }
        // the part of the route you'd all be on: up to where the last of the riders gets off
        let lastOff: Int = ride.riders.compactMap { x in index(of: x.alight, in: route, after: -1) }.max() ?? (route.count - 1)
        let soonest = now.addingTimeInterval(boardMargin + 7 * 60)
        let boards: [Int] = (0..<lastOff).filter { i in
            guard route[i].boarding, let d = route[i].dep else { return false }
            return d >= soonest
        }
        .sorted { Geo.metres(start, route[$0].point) < Geo.metres(start, route[$1].point) }
        var out: [MeetJoin] = []
        for b in boards {
            guard let j = onFrom(route: route, board: b, dest: dest, deadline: deadline, own: own) else { continue }
            out.append(j)
            if out.count >= limit { break }
        }
        return out
    }

    /// The way on after getting on at `board`: off at the stop nearest where you're going (within `walkFrom`), else
    /// onto the rest of one of your own ways where it leaves from a stop of the route.
    static func onFrom(route: [RouteStop], board b: Int, dest: GeoPoint, deadline: Date, own: [Way]) -> MeetJoin? {
        guard b + 1 < route.count else { return nil }
        let later = Array((b + 1)..<route.count)
        if let off = later.min(by: { Geo.metres(dest, route[$0].point) < Geo.metres(dest, route[$1].point) }),
           Geo.metres(dest, route[off].point) <= walkFrom, let arr = route[off].arr ?? route[off].dep {
            let walk = BoardAt.walkMinutes(metres: Geo.metres(dest, route[off].point))
            if arr.addingTimeInterval(Double(walk) * 60) <= deadline.addingTimeInterval(60) {
                return MeetJoin(board: b, alight: off, walkAfter: walk, rest: [])
            }
        }
        // onto your own way's next leg where it leaves from a stop of this route
        for w in own where w.end <= deadline.addingTimeInterval(60) {
            for (li, l) in w.legs.enumerated() {
                guard let from = l.from.point else { continue }
                for off in later where Geo.metres(from, route[off].point) <= sameStop {
                    guard let arr = route[off].arr ?? route[off].dep, l.dep >= arr.addingTimeInterval(changeMargin) else { continue }
                    return MeetJoin(board: b, alight: off, walkAfter: nil, rest: Array(w.legs[li...]))
                }
            }
        }
        return nil
    }

    /// Where a spot is on the route (by its stop id, else within `sameStop`), after `after`.
    static func index(of s: TripCard.Spot, in route: [RouteStop], after: Int) -> Int? {
        let range = route.indices.filter { $0 > after }
        if let id = s.id, !id.isEmpty, let i = range.first(where: { route[$0].id == id }) { return i }
        if let p = s.point, let i = range.first(where: { Geo.metres(p, route[$0].point) <= sameStop }) { return i }
        return range.first { route[$0].name == s.name }
    }

    /// The shared bus or train from `board` to `alight` as a leg of someone's way.
    static func leg(_ ride: SharedRide, template: WayLeg, route: [RouteStop], board: Int, alight: Int, walk: Int?) -> WayLeg? {
        guard let dep = route[board].dep, let arr = route[alight].arr ?? route[alight].dep, arr >= dep else { return nil }
        var l = template
        l.from = route[board].spot
        l.to = route[alight].spot
        l.dep = dep
        l.arr = arr
        l.plat = nil
        l.walk = walk
        return l
    }

    /// Step 3: someone's whole way with a join: their way to the stop (`before`, from the planner, there by
    /// `boardMargin` before it leaves; nil: they walk there, `walkTo` at most), the shared ride, and the way on. Nil:
    /// it doesn't get them there by `deadline`.
    static func joined(_ j: MeetJoin, ride: SharedRide, template: WayLeg, route: [RouteStop], start: GeoPoint,
                       before: Way?, deadline: Date) -> Way? {
        guard route.indices.contains(j.board), route.indices.contains(j.alight), let dep = route[j.board].dep else { return nil }
        var legs: [WayLeg] = []
        var startAt: Date
        if let before {
            guard before.end <= dep.addingTimeInterval(-60) else { return nil }
            legs = before.legs
            startAt = before.start
            guard let l = leg(ride, template: template, route: route, board: j.board, alight: j.alight, walk: nil) else { return nil }
            legs.append(l)
        } else {
            let m = Geo.metres(start, route[j.board].point)
            guard m <= walkTo else { return nil }
            let walk = BoardAt.walkMinutes(metres: m)
            guard let l = leg(ride, template: template, route: route, board: j.board, alight: j.alight, walk: walk) else { return nil }
            legs.append(l)
            startAt = dep.addingTimeInterval(-Double(walk) * 60 - 60)
        }
        var end: Date = legs.last!.arr
        if let w = j.walkAfter { end = end.addingTimeInterval(Double(w) * 60) }
        legs += j.rest
        if let r = j.rest.last { end = r.arr }
        guard end <= deadline.addingTimeInterval(60), legs.count <= TripCard.maxRides else { return nil }
        if startAt > dep { startAt = dep }
        return Way(legs: legs, start: startAt, end: end)
    }

    /// A plan with someone added (their way with the join): one fewer missing, the ride with them on it.
    static func adding(_ p: MeetPlan, id: String, way: Way, trip: String) -> MeetPlan {
        var q = p
        q.ways[id] = way
        q.missing.removeAll { $0 == id }
        if let li = way.legs.firstIndex(where: { $0.trip == trip }) {
            let l = way.legs[li]
            q.ride.riders.append(Rider(id: id, way: -1, leg: li, board: l.from, dep: l.dep, alight: l.to, arr: l.arr))
            q.ride.riders.sort { ($0.dep, $0.id) < ($1.dep, $1.id) }
        }
        q.kind = kind(q.ride, ways: q.ways)
        return q
    }

    /// The card that goes to the chat: someone's own way (`to` where it ends, there `by`).
    static func card(_ w: Way, to: TripCard.Spot, by: Date?, note: String?) -> TripCard {
        TripCard(rides: Array(w.legs.prefix(TripCard.maxRides)).map(\.card), to: to, from: nil, start: w.start, end: w.end, by: by,
                 note: note.map { String(ChatText.clean($0).prefix(TripCard.maxNote)) })
    }
}

/// The words for meeting halfway.
enum MeetWords {
    /// "Same train: IC 3512 at 07:41", "Meet at Eindhoven Centraal 07:35, then IC 3512 together"
    static func title(_ p: MeetPlan) -> String {
        switch p.kind {
        case .sameRide:
            let what = p.ride.isTrain ? "train" : "bus"
            return "Same \(what): \(p.ride.label) at \(TimetableDays.hhmm(p.ride.firstDep))"
        case .meetAt(let s, let at):
            return "Meet at \(s.name) \(TimetableDays.hhmm(at)), then \(p.ride.label) together"
        }
    }

    /// One person's part: "Bus 305 07:05 Veghel → Eindhoven, then IC 3512 07:41 Eindhoven → Breda · there 08:32".
    static func way(_ w: Way) -> String {
        let rides = w.legs.map { "\($0.label) \(TimetableDays.hhmm($0.dep)) \($0.from.name) → \($0.to.name)" }.joined(separator: ", then ")
        return "\(rides) · there \(TimetableDays.hhmm(w.end))"
    }

    /// The card's line: "Meet halfway: IC 3512 together · Sam gets on at Tilburg 08:03"
    static func note(_ p: MeetPlan, name: (String) -> String, me: String) -> String {
        let others: [String] = p.ride.riders.filter { $0.id != me }.map { "\(name($0.id)) gets on at \($0.board.name) \(TimetableDays.hhmm($0.dep))" }
        var s = "Meet halfway: \(p.ride.label) together"
        if !others.isEmpty { s += " · " + others.joined(separator: " · ") }
        return String(s.prefix(TripCard.maxNote))
    }
}

/// How many planner questions a compare screen (or one meet-halfway search) may ask Transitous: each person's way to
/// school and home is one question per day looked up (people with the same start, school and time share one), a
/// meet-halfway search adds the shared bus or train's stops and one way to its stop per person not on it yet.
struct RequestBudget: Equatable {
    /// A compare screen, while it's open.
    static let compare = 24
    /// One meet-halfway search.
    static let meet = 12

    let limit: Int
    private(set) var used = 0

    init(limit: Int) { self.limit = limit }

    var left: Int { max(0, limit - used) }

    /// Takes `n` if there are that many left.
    mutating func take(_ n: Int = 1) -> Bool {
        guard n >= 0, used + n <= limit else { return false }
        used += n
        return true
    }
}
