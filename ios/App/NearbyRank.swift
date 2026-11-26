import Foundation

/// "Fastest trip, zoomed out" (0.42, concept N5): every bus stop and train station you could walk to, each planned to
/// where you're going, on one map. A stop's circle is coloured by when you'd be there (green the earliest, red the
/// latest), its ring says how sure (solid: almost always on time, dashed: often late), and the list under it tags the
/// Fastest, the Surest and the Slower ones. The rules are here, as plain values, so they're tested; Foundation only.
/// The store (`NearbyStore`) asks the planner; the screen is NearbyViews.swift.
enum Nearby {
    // MARK: the stops around you

    /// A stop near you, as the map's stops answer has it (a station by the station, not one platform).
    struct Stop: Equatable, Sendable {
        let id: String
        let name: String
        let lat: Double
        let lon: Double
        let rail: Bool
        let metres: Double          // straight line from you
    }

    /// One stop to plan from: the stops of one name close together (the two sides of the road) as one, with up to
    /// `idsPerGroup` of their ids to plan from (the nearest first).
    struct Group: Equatable, Sendable, Identifiable {
        let id: String              // `key(name)`, or the station's id
        let name: String
        var ids: [String]
        let lat: Double
        let lon: Double
        let rail: Bool
        let metres: Double
        var point: GeoPoint { GeoPoint(lat: lat, lon: lon) }
    }

    /// The stops drawn on the map before any plan is in: those within this of you.
    static let dotsRadius: Double = 1000
    /// A search asks for more while fewer than this many stops have a way.
    static let usefulWanted = 3
    /// At most this many of the stops around are drawn…
    static let maxGroups = 8
    /// …with at most this many ids each (the two sides of the road; a stop tapped is planned from the first)…
    static let idsPerGroup = 2
    /// …and at most this many ids in all.
    static let maxPlans = 12
    /// Stops of one name within this of each other are one stop.
    static let sameStop: Double = 300
    /// Stations planned from at least, before the bus stops nearer by.
    static let stationsFirst = 2

    /// A stop's name as stops are told apart: lower case, single spaces.
    static func key(_ name: String) -> String {
        let parts: [Substring] = name.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" })
        return parts.joined(separator: " ")
    }

    /// The stops within `radius` grouped (`Group`), nearest first; at most `maxGroups`, the nearest `stationsFirst`
    /// stations always among them; `maxPlans` ids in all (each group its nearest id first, then second ids while
    /// there's room, nearest groups first). `skip`: groups already planned from (a wider look plans only the new ones).
    static func groups(_ stops: [Stop], within radius: Double, skip: Set<String> = []) -> [Group] {
        let near: [Stop] = stops.filter { $0.metres <= radius && $0.metres.isFinite }.sorted { $0.metres < $1.metres }
        var all: [Group] = []
        var allIds: [[String]] = []
        for s in near {
            let k: String = s.rail ? "rail:" + s.id : key(s.name)
            let here = GeoPoint(lat: s.lat, lon: s.lon)
            if let i = all.firstIndex(where: { $0.id == k && Geo.metres($0.point, here) <= sameStop }) {
                if !allIds[i].contains(s.id) { allIds[i].append(s.id) }
                continue
            }
            if all.contains(where: { $0.id == k }) { continue }      // the same name further off: not another stop of it
            all.append(Group(id: k, name: s.name, ids: [], lat: s.lat, lon: s.lon, rail: s.rail, metres: s.metres))
            allIds.append([s.id])
        }
        var picked: [Int] = []
        let stations: [Int] = all.indices.filter { all[$0].rail && !skip.contains(all[$0].id) }
        picked += stations.prefix(stationsFirst)
        for i in all.indices where !skip.contains(all[i].id) && !picked.contains(i) {
            if picked.count >= maxGroups { break }
            picked.append(i)
        }
        picked = Array(picked.prefix(maxGroups)).sorted { all[$0].metres < all[$1].metres }
        // the ids: one each, then a second each while there's room
        var out: [Group] = []
        var budget = maxPlans
        for i in picked where budget > 0 {
            var g = all[i]
            g.ids = [allIds[i][0]]
            budget -= 1
            out.append(g)
        }
        for n in out.indices where budget > 0 {
            guard let i = all.firstIndex(where: { $0.id == out[n].id }) else { continue }
            let more: [String] = Array(allIds[i].dropFirst().prefix(idsPerGroup - 1))
            for id in more where budget > 0 {
                out[n].ids.append(id)
                budget -= 1
            }
        }
        return out
    }

    // MARK: asking the planner (0.42.2)

    // 0.42.0 planned every stop around on its own: 12 plans at once and 8 more a range wider, again on every switch of
    // the time to leave. Transitous takes a few at a time; at 23:10 most of them never left the queue ("timed out · 0
    // tries"), two got a 429, each answer was 150–210 KB, and the screen said "No bus or train". Now a search is one
    // plan from where you are (the planner itself walks to every stop around), and a second one only when it's needed.

    /// The walks a search's plans take: the first plan up to `searchRadii[0]`, the second (a later page, or the first
    /// again when it failed) up to `searchRadii[1]`.
    static let searchRadii: [Double] = [1600, 3000]
    /// Plans a search sends at most (a stop tapped is one more, one at a time).
    static let maxSearchPlans = 2
    /// Requests from this screen on their way at once, at most.
    static let maxConcurrent = 2
    /// Ways asked for per plan, and the departures they span (seconds).
    static let itineraries = 8
    static let searchWindow = 3600
    /// The longest first walk a plan is asked for (seconds).
    static let maxPreTransit = 2700

    /// The first walk a plan may take to reach the stops within `radius`, in seconds.
    static func preTransit(radius: Double) -> Int { min(maxPreTransit, plannedWalk(straight: radius) * 60) }

    /// The next plan of a search: its walking range (nil: no more). `done` plans were sent; the first always goes; a
    /// second only while fewer than `usefulWanted` stops have a way, when there's a later page to ask (`hasCursor`) or
    /// the first failed (asked once more, wider), never while Transitous asks to slow down (`cooling`).
    static func nextPlan(done: Int, useful: Int, hasCursor: Bool, lastFailed: Bool, cooling: Bool) -> Double? {
        guard done < maxSearchPlans, done < searchRadii.count else { return nil }
        if done == 0 { return searchRadii[0] }
        guard !cooling, useful < usefulWanted, hasCursor || lastFailed else { return nil }
        return searchRadii[done]
    }

    // MARK: which stop a way leaves from

    /// Where a way gets on: its first ride's stop.
    struct Boarding: Equatable, Sendable {
        let id: String
        let name: String
        let lat: Double?
        let lon: Double?
        let rail: Bool
        var point: GeoPoint? { lat.flatMap { a in lon.map { GeoPoint(lat: a, lon: $0) } } }
    }

    /// The stop of `groups` a way gets on at: the one with its id, else a bus stop of its name within `sameStop`, else
    /// the nearest within 120 m (a station: 400 m). Nil: none of them (`newGroup`).
    static func groupIndex(_ b: Boarding, in groups: [Group]) -> Int? {
        if let i = groups.firstIndex(where: { $0.ids.contains(b.id) || $0.id == "rail:" + b.id }) { return i }
        let k: String = key(b.name)
        guard let p = b.point else {
            return b.rail ? nil : groups.firstIndex { !$0.rail && $0.id == k }
        }
        if !b.rail, let i = groups.firstIndex(where: { !$0.rail && $0.id == k && Geo.metres($0.point, p) <= sameStop }) { return i }
        var best: (i: Int, m: Double)? = nil
        for (i, g) in groups.enumerated() {
            let m: Double = Geo.metres(g.point, p)
            let near: Double = (g.rail || b.rail) ? 400 : 120
            if m <= near, m < (best?.m ?? .infinity) { best = (i, m) }
        }
        return best?.i
    }

    /// A stop of its own for a way that gets on where none of the stops around is (nil without where it is). Its id
    /// is told apart from a stop of the same name elsewhere (`taken`).
    static func newGroup(_ b: Boarding, here: GeoPoint, taken: Set<String>) -> Group? {
        guard let p = b.point else { return nil }
        var id: String = b.rail ? "rail:" + b.id : key(b.name)
        if taken.contains(id) { id += "@" + b.id }
        return Group(id: id, name: b.name, ids: [b.id], lat: p.lat, lon: p.lon, rail: b.rail, metres: Geo.metres(here, p))
    }

    // MARK: the walk

    /// A walk through streets is longer than the straight line: about this much.
    static let detour = 1.3
    /// The planner's own walking speed (m/s).
    static let plannerSpeed = 1.2

    /// The walk's length on foot for a straight line.
    static func walkMetres(straight m: Double) -> Double { max(0, m) * detour }

    /// The planner's walk in whole minutes (up), at least 1.
    static func plannedWalk(straight m: Double, speed: Double = plannerSpeed) -> Int {
        let v: Double = speed.isFinite && speed > 0 ? speed : plannerSpeed
        let mins: Double = walkMetres(straight: m) / v / 60
        return max(1, Int(mins.rounded(.up)))
    }

    // MARK: when you'd leave

    /// The switch: leave now, in 10 or in 20 minutes.
    enum Leave: Int, CaseIterable, Sendable, Identifiable {
        case now = 0, in10 = 10, in20 = 20
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .now: return "Leave now"
            case .in10: return "In 10 min"
            case .in20: return "In 20 min"
            }
        }
    }

    /// The ways ranked (Fastest, Surest, the colours): leaving your door within this of the time you set off…
    static let windowMinutes = 35.0
    /// …and none waiting longer than this anywhere (before the first ride, or at a change)…
    static let maxWait: TimeInterval = 90 * 60
    /// …and there within this of the time you set off.
    static let maxTrip: TimeInterval = 3 * 3600
    /// A stop's departures shown, at least (later ones too).
    static let minPerStop = 2
    /// The grace for leaving your door (seconds).
    static let doorGrace: TimeInterval = 30

    struct Window: Equatable, Sendable {
        let leave: Date             // when you set off
        let until: Date             // the last time to leave the door that's ranked
    }

    static func window(_ l: Leave, now: Date) -> Window {
        let leave: Date = now.addingTimeInterval(Double(l.rawValue) * 60)
        return Window(leave: leave, until: leave.addingTimeInterval(windowMinutes * 60))
    }

    /// You make a way that has you leave your door at `door` (its departure less your walk, counted once) when you set
    /// off at the window's start or later (half a minute's grace). No upper bound: a later one is still a way.
    static func catchable(door: Date, _ w: Window) -> Bool {
        door >= w.leave.addingTimeInterval(-doorGrace)
    }

    /// When to ask the planner from a stop you walk `walk` minutes to: when you can be there (not before now).
    static func planAt(_ w: Window, walk: Int, now: Date) -> Date {
        max(now.addingTimeInterval(-60), w.leave.addingTimeInterval(Double(max(0, walk)) * 60 - 60))
    }

    /// A way, as the window looks at it.
    struct Dep: Equatable, Sendable {
        let door: Date              // when you leave your door (its departure less your walk)
        let departure: Date
        let arrival: Date
        var cancelled = false
        var longestWait: TimeInterval = 0       // at a change
    }

    /// Overnight, or much later: leaving `maxWait` after you set off, a wait of `maxWait` at a change, or there more
    /// than `maxTrip` after you set off. Shown apart (with its day), never ranked.
    static func late(_ d: Dep, _ w: Window) -> Bool {
        d.door.timeIntervalSince(w.leave) > maxWait || d.longestWait > maxWait || d.arrival.timeIntervalSince(w.leave) > maxTrip
    }

    /// Ranked: you leave your door in the window, and it's not `late`.
    static func ranked(_ d: Dep, _ w: Window) -> Bool {
        catchable(door: d.door, w) && d.door <= w.until && !late(d, w)
    }

    /// The departures of a stop shown (indices into `deps`, by departure): every one you make that leaves your door in
    /// the window, and at least `minPerStop` of the ones you make however late (the next ones tonight, or tomorrow's).
    static func shown(_ deps: [Dep], _ w: Window) -> [Int] {
        let ok: [Int] = deps.indices.filter { !deps[$0].cancelled && catchable(door: deps[$0].door, w) }
            .sorted { deps[$0].departure < deps[$1].departure }
        var out: [Int] = []
        for i in ok where deps[i].door <= w.until || out.count < minPerStop { out.append(i) }
        return out
    }

    /// A stop's best way of those shown: the earliest there of the ranked ones, else of them all; and whether it's ranked.
    static func best(_ deps: [Dep], _ w: Window) -> (index: Int, ranked: Bool)? {
        let s: [Int] = shown(deps, w)
        let r: [Int] = s.filter { ranked(deps[$0], w) }
        if let i = r.min(by: { deps[$0].arrival < deps[$1].arrival }) { return (i, true) }
        guard let i = s.min(by: { deps[$0].arrival < deps[$1].arrival }) else { return nil }
        return (i, false)
    }

    /// The ways shown apart from the rest: the `late` ones (indices into `deps`, in their order).
    static func split(_ deps: [Dep], _ w: Window) -> (soon: [Int], later: [Int]) {
        var soon: [Int] = [], later: [Int] = []
        for i in deps.indices { if late(deps[i], w) { later.append(i) } else { soon.append(i) } }
        return (soon, later)
    }

    /// The day of `d` when it isn't today: nil today, and on the night after (before 04:00) too; "tomorrow"; else the
    /// weekday ("Sat").
    static func dayWord(_ d: Date, now: Date, calendar: Calendar) -> String? {
        let a: Date = calendar.startOfDay(for: now)
        let b: Date = calendar.startOfDay(for: d)
        let days: Int = calendar.dateComponents([.day], from: a, to: b).day ?? 0
        if days <= 0 { return nil }
        let hour: Int = calendar.component(.hour, from: d)
        if days == 1 && hour < 4 { return nil }
        if days == 1 { return "tomorrow" }
        let names: [String] = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let wd: Int = calendar.component(.weekday, from: d)
        return names[max(0, min(6, wd - 1))]
    }

    /// The heading of the ways shown apart: "Tomorrow morning" when the first of them gets there tomorrow before noon,
    /// else "Later" (with its day: "Later · Sat").
    static func laterTitle(firstArrival: Date, now: Date, calendar: Calendar) -> String {
        let day: String? = dayWord(firstArrival, now: now, calendar: calendar)
        let hour: Int = calendar.component(.hour, from: firstArrival)
        if day == "tomorrow" && hour < 12 { return "Tomorrow morning" }
        return day.map { "Later · \($0)" } ?? "Later"
    }

    // MARK: how sure

    /// Minutes late that count as late at the destination.
    static let lateBy = 3.0
    /// Your own rides it takes before it says "of your last N rides".
    static let ownNeeded = 4
    /// The last rides counted.
    static let ownKept = 20

    enum Source: Equatable, Sendable {
        case yours(rides: Int)      // your own rides on that line to that stop
        case live                   // live times of that line now, and what the app saw of it
        case estimate               // only the time of day
    }

    struct Sure: Equatable, Sendable {
        let percent: Int            // on time at the destination, 1…99
        let source: Source
        let usual: Int?             // your rides: the usual minutes late (median), when it's 1 or more
    }

    /// How sure: of your own last rides (`ownNeeded` at least, the last `ownKept`) the share less than `lateBy`
    /// minutes late, else the model's chance (`modelLate`: of more than `lateBy` minutes late); either times the
    /// chance you make each change (`made`). `live`: the line's live times are seen now.
    static func sure(own: [Double], modelLate: Double, made: Double, live: Bool) -> Sure {
        let m: Double = made.isFinite ? min(1, max(0, made)) : 1
        let mine: [Double] = Array(own.filter(\.isFinite).suffix(ownKept))
        if mine.count >= ownNeeded {
            let onTime: Int = mine.filter { $0 < lateBy }.count
            let share: Double = Double(onTime) / Double(mine.count)
            let med: Double = median(mine)
            let usual: Int? = med >= 0.5 ? Int(med.rounded()) : nil
            return Sure(percent: clampPercent(share * m), source: .yours(rides: mine.count), usual: usual)
        }
        let late: Double = modelLate.isFinite ? min(1, max(0, modelLate)) : 0.3
        return Sure(percent: clampPercent((1 - late) * m), source: live ? .live : .estimate, usual: nil)
    }

    private static func clampPercent(_ p: Double) -> Int { min(99, max(1, Int((p * 100).rounded()))) }

    private static func median(_ xs: [Double]) -> Double {
        let s: [Double] = xs.sorted()
        guard !s.isEmpty else { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// "on time 98% of your last 20 rides · usually +1 min", "on time about 85% (by live times)".
    static func sureWords(_ s: Sure) -> String {
        switch s.source {
        case .yours(let n):
            let usual: String = s.usual.map { " · usually +\($0) min" } ?? ""
            return "on time \(s.percent)% of your last \(n) ride\(n == 1 ? "" : "s")" + usual
        case .live:
            return "on time about \(s.percent)% (by live times)"
        case .estimate:
            return "on time about \(s.percent)% (by the time of day; no live times yet)"
        }
    }

    /// The ring around a stop: solid at `solidAt`% or more, dashed under; neutral when it only goes by the time of day.
    enum Ring: Equatable, Sendable { case solid, dashed, neutral }
    static let solidAt = 85

    static func ring(_ s: Sure?) -> Ring {
        guard let s, s.source != .estimate else { return .neutral }
        return s.percent >= solidAt ? .solid : .dashed
    }

    // MARK: fastest, surest, slower

    /// A stop's best way: the earliest there of the ones you make.
    struct Option: Equatable, Sendable, Identifiable {
        let id: String              // its `Group.id`
        let arrival: Date
        let departure: Date
        let walk: Int
        let sure: Sure?
        var ranked = true           // in the window, not overnight (`ranked`): only these get tags and colours
    }

    enum Tag: String, Equatable, Sendable {
        case fastest = "Fastest", surest = "Surest", slower = "Slower"
    }

    /// Slower: there this much after the fastest, or more.
    static let slowerAfter: TimeInterval = 5 * 60

    /// Surest only at this on-time chance or more (0.42.2: not "Surest" next to "on time about 60%").
    static let surestAt = 70

    /// The tags, of the ranked options only: Fastest the earliest there (the shorter walk, then the later departure,
    /// on a tie); Surest the most sure, at `surestAt`% at least (the earlier there on a tie; the fastest itself when
    /// it's as sure); Slower the others `slowerAfter` or more after the fastest.
    static func tags(_ options: [Option]) -> [String: [Tag]] {
        let ranked: [Option] = options.filter(\.ranked)
        guard let fast = fastest(ranked) else { return [:] }
        var out: [String: [Tag]] = [fast.id: [.fastest]]
        if let sure = surest(ranked, fastest: fast) {
            out[sure.id, default: []].append(.surest)
        }
        for o in ranked where out[o.id] == nil && o.arrival.timeIntervalSince(fast.arrival) >= slowerAfter {
            out[o.id] = [.slower]
        }
        return out
    }

    static func fastest(_ options: [Option]) -> Option? {
        options.filter(\.ranked).min { a, b in
            if a.arrival != b.arrival { return a.arrival < b.arrival }
            if a.walk != b.walk { return a.walk < b.walk }
            return a.departure > b.departure
        }
    }

    private static func surest(_ options: [Option], fastest fast: Option) -> Option? {
        let rated: [Option] = options.filter { $0.sure != nil }
        guard let top = rated.max(by: { a, b in
            let pa: Int = a.sure?.percent ?? 0, pb: Int = b.sure?.percent ?? 0
            if pa != pb { return pa < pb }
            return a.arrival > b.arrival
        }) else { return nil }
        let topPct: Int = top.sure?.percent ?? 0
        guard topPct >= surestAt else { return nil }
        let fastPct: Int = fast.sure?.percent ?? -1
        if topPct <= fastPct { return fast }
        return top
    }

    /// Of a stop's departures (each its on-time %), the one to tag Surest: the most sure, at `surestAt`% at least and
    /// surer than the one there first (`fastest`, an index). Nil: none.
    static func surestOf(_ percents: [Int], fastest: Int) -> Int? {
        guard percents.indices.contains(fastest), let top = percents.indices.max(by: { a, b in
            percents[a] != percents[b] ? percents[a] < percents[b] : a > b      // a tie: the earlier one
        }) else { return nil }
        let p: Int = percents[top]
        return p >= surestAt && p > percents[fastest] ? top : nil
    }

    /// The list's order: the fastest, then the surest, then the rest by when you'd be there.
    static func ordered(_ options: [Option]) -> [Option] {
        let t: [String: [Tag]] = tags(options)
        func rank(_ o: Option) -> Int {
            let tg: [Tag] = t[o.id] ?? []
            if tg.contains(.fastest) { return 0 }
            if tg.contains(.surest) { return 1 }
            return o.ranked ? 2 : 3
        }
        return options.sorted { a, b in
            let ra: Int = rank(a), rb: Int = rank(b)
            if ra != rb { return ra < rb }
            if a.arrival != b.arrival { return a.arrival < b.arrival }
            return a.walk < b.walk
        }
    }

    // MARK: the colours

    /// Green, yellow, orange, red: earliest to latest there.
    static let scale: [UInt32] = [0x3DD598, 0xC9D45A, 0xE8A33D, 0xE86F5A]
    /// Arrivals closer together than this don't go all the way to red.
    static let minSpread: TimeInterval = 8 * 60

    /// Where an arrival sits between the earliest and the latest (0…1; at least `minSpread` between them).
    static func fraction(_ arrival: Date, earliest: Date, latest: Date) -> Double {
        let span: Double = max(minSpread, latest.timeIntervalSince(earliest))
        let f: Double = arrival.timeIntervalSince(earliest) / span
        return f.isFinite ? min(1, max(0, f)) : 0
    }

    /// The colour at `f` along `scale`, as 0xRRGGBB.
    static func color(_ f: Double) -> UInt32 {
        let x: Double = f.isFinite ? min(1, max(0, f)) : 0
        let steps: Double = Double(scale.count - 1)
        let i: Int = min(scale.count - 2, Int((x * steps).rounded(.down)))
        let t: Double = x * steps - Double(i)
        return mix(scale[i], scale[i + 1], t)
    }

    private static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        func ch(_ v: UInt32, _ s: UInt32) -> Double { Double((v >> s) & 0xFF) }
        func one(_ s: UInt32) -> UInt32 {
            let v: Double = ch(a, s) + (ch(b, s) - ch(a, s)) * t
            return UInt32(min(255, max(0, v.rounded()))) << s
        }
        return one(16) | one(8) | one(0)
    }

    // MARK: the map's frame

    struct Frame: Equatable, Sendable {
        let lat: Double
        let lon: Double
        let latDelta: Double
        let lonDelta: Double
    }

    /// The map's frame: you and the stops (only the useful ones, when there are), with room around them (`pad`), at
    /// least `minMetres` across.
    static func frame(you: GeoPoint, stops: [GeoPoint], minMetres: Double = 600, pad: Double = 1.4) -> Frame {
        let pts: [GeoPoint] = [you] + stops
        let lats: [Double] = pts.map(\.lat), lons: [Double] = pts.map(\.lon)
        let minLat: Double = lats.min() ?? you.lat, maxLat: Double = lats.max() ?? you.lat
        let minLon: Double = lons.min() ?? you.lon, maxLon: Double = lons.max() ?? you.lon
        let midLat: Double = (minLat + maxLat) / 2
        let perLat: Double = 111_320
        let perLon: Double = max(1, 111_320 * cos(midLat * .pi / 180))
        let latDelta: Double = max((maxLat - minLat) * pad, minMetres / perLat)
        let lonDelta: Double = max((maxLon - minLon) * pad, minMetres / perLon)
        return Frame(lat: midLat, lon: (minLon + maxLon) / 2, latDelta: latDelta, lonDelta: lonDelta)
    }

    // MARK: on the line now

    /// How many stops a vehicle has to go to yours (`mine`): at stop `next` (`atStop`) or on its way to it. Nil: it's
    /// past your stop.
    static func stopsAway(next: Int, atStop: Bool, mine: Int) -> Int? {
        if atStop { return next <= mine ? mine - next : nil }
        return next <= mine ? mine - next + 1 : nil
    }

    /// "GPS 20 s", "GPS 2 min".
    static func gpsAge(_ seconds: TimeInterval) -> String {
        let s: Int = max(0, Int(seconds.rounded()))
        return s < 60 ? "GPS \(s) s" : "GPS \(s / 60) min"
    }

    /// "in 9 min · 4 stops", "in 1 min · next stop", "now".
    static func comingWords(minutes: Int, stops: Int?) -> String {
        let when: String = minutes <= 0 ? "now" : "in \(minutes) min"
        guard let n = stops else { return when }
        if n == 0 { return when + " · at the stop" }
        return when + (n == 1 ? " · next stop" : " · \(n) stops")
    }

    // MARK: stops close together on the map (0.42.2)

    /// A stop's circle on the map.
    struct Pin: Equatable, Sendable {
        let id: String
        let lat: Double
        let lon: Double
        let arrival: Date?
        var point: GeoPoint { GeoPoint(lat: lat, lon: lon) }
    }

    /// Circles drawn as one: the best of them (`id`, where it is) and the others under it.
    struct Cluster: Equatable, Sendable {
        let id: String
        let lat: Double
        let lon: Double
        var members: [String]
    }

    /// Circles closer than `within` metres (a circle's width at the map's scale) are one: the earliest there (then the
    /// first by id) at its own place, the others under it. Never two that overlap.
    static func merge(_ pins: [Pin], within metres: Double) -> [Cluster] {
        let order: [Pin] = pins.sorted { a, b in
            switch (a.arrival, b.arrival) {
            case let (x?, y?) where x != y: return x < y
            case (.some, .none): return true
            case (.none, .some): return false
            default: return a.id < b.id
            }
        }
        var out: [Cluster] = []
        for p in order {
            let i: Int? = out.firstIndex { Geo.metres(GeoPoint(lat: $0.lat, lon: $0.lon), p.point) < metres }
            if let i {
                out[i].members.append(p.id)
            } else {
                out.append(Cluster(id: p.id, lat: p.lat, lon: p.lon, members: [p.id]))
            }
        }
        return out
    }

    /// A circle's width (points) and the room between two.
    static let pinPoints = 40.0

    // MARK: what the screen says

    struct Situation: Equatable, Sendable {
        var located = true
        var stopsFailed = false     // the stops around couldn't be had
        var busy = false
        var options = 0             // stops with a way shown
        var planFailed = false      // a search's plans got no answer (timed out, busy)
        var unchecked = 0           // stops tapped whose plan got no answer
        var seed = false            // Fastest trip has a way (its own cards)
        var fallback = false        // only Fastest trip's own way is shown (nothing later found)
        var cooling = false         // Transitous asked to slow down
    }

    /// The line over the list (nil: nothing to say), and whether it's still asking. Never "No bus or train" while the
    /// planner didn't answer, or while Fastest trip has a way.
    static func statusLine(_ s: Situation, range: String) -> (text: String, asking: Bool)? {
        if !s.located { return ("Finding where you are…", true) }
        if s.busy { return ("Asking the planner for the ways from the stops within \(range)…", true) }
        let busyWord: String = s.cooling ? "the planner is busy" : "no answer in time"
        if s.options == 0 {
            if s.fallback { return ("Nothing found yet for that time: this is your trip’s way. See your trip for its other times.", false) }
            if s.planFailed || s.stopsFailed {
                return ("Couldn’t check the stops around you just now (\(busyWord)). Your trip has the fastest way.", false)
            }
            if s.seed { return ("Your trip has the way: see your trip.", false) }
            return ("No bus or train from the stops within \(range) in this time. Try later, or see your trip.", false)
        }
        if s.planFailed { return ("Couldn’t check every stop just now (\(busyWord)): these are the ones in.", false) }
        if s.unchecked > 0 {
            return ("Couldn’t check \(s.unchecked) stop\(s.unchecked == 1 ? "" : "s") just now (\(busyWord)). Tap one to try again.", false)
        }
        return nil
    }

    /// The field log's line for a search: "nearby · r 1.6 km · stops 9 · plans 1 (+1 page) · ways 6 · 0 failed ·
    /// 0.8 s · 320 KB". `plans`: the plans sent (a later page counted apart, `pages`); `failed`: of them, no answer.
    static func logLine(radius: Double, stops: Int, plans: Int, pages: Int, ways: Int, failed: Int,
                        seconds: Double, bytes: Int, note: String? = nil) -> String {
        let km: Double = (radius / 100).rounded() / 10
        let r: String = String(format: "%.1f", km)
        let page: String = pages > 0 ? " (+\(pages) page\(pages == 1 ? "" : "s"))" : ""
        let s: String = String(format: "%.1f", max(0, seconds))
        let kb: Int = Int((Double(max(0, bytes)) / 1024).rounded())
        var out: String = "nearby · r \(r) km · stops \(stops) · plans \(plans)\(page) · ways \(ways) · \(failed) failed · \(s) s · \(kb) KB"
        if let note, !note.isEmpty { out += " · " + note }
        return out
    }

    /// The field log's line for a stop tapped: "nearby stop · plan · ways 3 · 0.9 s · 150 KB", "… · plan failed".
    static func stopLogLine(planned: Bool, failed: Bool, ways: Int, board: Int?, seconds: Double, bytes: Int) -> String {
        var out: String = "nearby stop"
        if planned { out += failed ? " · plan failed" : " · plan" }
        out += " · ways \(ways)"
        if let b = board { out += " · times \(b)" }
        out += " · " + String(format: "%.1f", max(0, seconds)) + " s · \(Int((Double(max(0, bytes)) / 1024).rounded())) KB"
        return out
    }
}
