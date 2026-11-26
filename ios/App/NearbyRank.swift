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

    /// The walking ranges it looks in, one after the other while fewer than `usefulWanted` stops have a way.
    static let radii: [Double] = [1000, 1600, 2200, 3000]
    static let usefulWanted = 3
    /// At most this many stops are planned from, per range…
    static let maxGroups = 8
    /// …with at most this many ids each (the two sides of the road)…
    static let idsPerGroup = 2
    /// …and at most this many plans in all, per range.
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

    /// The next wider range to look in, while fewer than `usefulWanted` stops have a way (nil: wide enough, or the
    /// widest already).
    static func nextRadius(after r: Double, useful: Int) -> Double? {
        guard useful < usefulWanted else { return nil }
        return radii.first { $0 > r + 1 }
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

    /// The departures counted: from when you can be at the stop, for this long.
    static let windowMinutes = 35.0

    struct Window: Equatable, Sendable {
        let leave: Date             // when you set off
        let until: Date             // the last departure counted (plus your walk)
    }

    static func window(_ l: Leave, now: Date) -> Window {
        let leave: Date = now.addingTimeInterval(Double(l.rawValue) * 60)
        return Window(leave: leave, until: leave.addingTimeInterval(windowMinutes * 60))
    }

    /// You make a departure walking `walk` minutes when you set off at the window's start (half a minute's grace), and
    /// it's in the window.
    static func catchable(departure: Date, walk: Int, _ w: Window) -> Bool {
        let at: Date = w.leave.addingTimeInterval(Double(walk) * 60 - 30)
        let last: Date = w.until.addingTimeInterval(Double(walk) * 60)
        return departure >= at && departure <= last
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
    }

    enum Tag: String, Equatable, Sendable {
        case fastest = "Fastest", surest = "Surest", slower = "Slower"
    }

    /// Slower: there this much after the fastest, or more.
    static let slowerAfter: TimeInterval = 5 * 60

    /// The tags: Fastest the earliest there (the shorter walk, then the later departure, on a tie); Surest the most
    /// sure (the earlier there on a tie; the fastest itself when it's as sure); Slower the others `slowerAfter` or more
    /// after the fastest.
    static func tags(_ options: [Option]) -> [String: [Tag]] {
        guard let fast = fastest(options) else { return [:] }
        var out: [String: [Tag]] = [fast.id: [.fastest]]
        if let sure = surest(options, fastest: fast) {
            out[sure.id, default: []].append(.surest)
        }
        for o in options where out[o.id] == nil && o.arrival.timeIntervalSince(fast.arrival) >= slowerAfter {
            out[o.id] = [.slower]
        }
        return out
    }

    static func fastest(_ options: [Option]) -> Option? {
        options.min { a, b in
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
        let fastPct: Int = fast.sure?.percent ?? -1
        if (top.sure?.percent ?? 0) <= fastPct { return fast }
        return top
    }

    /// The list's order: the fastest, then the surest, then the rest by when you'd be there.
    static func ordered(_ options: [Option]) -> [Option] {
        let t: [String: [Tag]] = tags(options)
        func rank(_ o: Option) -> Int {
            let tg: [Tag] = t[o.id] ?? []
            if tg.contains(.fastest) { return 0 }
            if tg.contains(.surest) { return 1 }
            return 2
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
}
