import Foundation

/// Two trains on the same track (0.34). On 2026-11-19 the user rode the Intercity Breda → 's-Hertogenbosch while the app
/// had the Intercity Breda → Tilburg → Eindhoven: both run on the same track to past Tilburg, and the plan then said
/// "change at Tilburg to a Sprinter". A confirmed ride's "same train?" look judged the one shown alone, and on a shared
/// track that passes (a timetable-only one is judged by its road and your speed, not by its times), so nothing looked at
/// the train that NS's own position had right with you until the tracks split.
/// - `rivals`: the confirmed train isn't with you by its own NS position, another one on your track is: choose.
/// - `seen`/`outByStops`: the stopping pattern. Through a station at speed: not one that calls there; standing at a
///   station: not one that runs through it without calling.
/// - `ask`: still tied after 2 minutes with different destinations: ask once which one.
/// - `stayOn`: the trip follows the train you're on (no change at Tilburg on the through train; 0.42.9: by the
///   vehicle's own stops against where the next leg gets off and when, and always when the plan split one train).
/// - `headline`: the ride by where the vehicle really goes, and where you get off.
/// Plain values only, so it can be tested.
enum TrainRules {
    // MARK: rivals of a confirmed train

    /// s between looks at the other trains on your track, while the one shown isn't with you by its own GPS.
    static let rivalEvery: TimeInterval = 120
    /// At most this many rivals join the choice.
    static let rivalCount = 2

    /// The trains to choose between with the one shown: those that passed by their own GPS (NS's position) while the one
    /// shown didn't (it has none, it's judged by its times, or its GPS puts it elsewhere). Best first, `rivalCount` at most.
    static func rivals(shown: Judgement?, others: [Judgement]) -> [String] {
        if let s = shown, VehicleMatch.passedByGPS(s) { return [] }
        let by: [(id: String, cost: Double)] = others.compactMap { j in
            guard j.isTrain, j.id != shown?.id, VehicleMatch.passedByGPS(j), case .success(let c) = j.result else { return nil }
            return (j.id, c)
        }
        return Array(by.sorted { $0.cost != $1.cost ? $0.cost < $1.cost : $0.id < $1.id }.prefix(rivalCount).map(\.id))
    }

    // MARK: the stopping pattern

    enum Seen: Equatable, Sendable { case stopped, passedThrough }

    static let near = 300.0                 // m: a fix this close to a station is at it
    static let stopNear = 250.0             // m: standing this close to a station is a stop there
    static let stopFor: TimeInterval = 20   // s standing…
    static let stopDrift = 40.0             // m: …within this of where it stopped (or 1.5 × the fixes' accuracy)
    static let passSpeed = 8.0              // m/s: through a station at least this fast all the way…
    static let passFrom = 600.0             // m: …from this far before it to this far after it…
    static let passGap: TimeInterval = 20   // s: …with no gap between fixes longer than this (a tunnel: no telling)
    static let maxAccuracy = 100.0          // m: worse fixes are left out

    /// What your fixes say you did at a station: stood there (`stopFor` within `stopNear`), went through it at speed
    /// (from `passFrom` before to `passFrom` after, every fix and every step between fixes at `passSpeed` or more, fixes
    /// no more than `passGap` apart), or nil (not past it yet, not by it, or no telling).
    static func seen(_ fixes: [Fix], at s: GeoPoint) -> Seen? {
        let f = fixes.filter { $0.accuracy.isFinite && $0.accuracy >= 0 && $0.accuracy <= maxAccuracy }.sorted { $0.t < $1.t }
        guard f.count >= 3 else { return nil }
        let d = f.map { Geo.metres($0.p, s) }
        // standing: two fixes `stopFor` apart near it with every fix between them close to the first
        for i in f.indices where d[i] <= stopNear {
            let lim = max(stopDrift, 1.5 * f[i].accuracy)
            var j = i
            while j + 1 < f.count, Geo.metres(f[j + 1].p, f[i].p) <= lim { j += 1 }
            if j > i, f[j].t.timeIntervalSince(f[i].t) >= stopFor { return .stopped }
        }
        // through it: the fix nearest it is near; before it a fix `passFrom` away, after it one too, and all at speed
        guard let k = d.indices.min(by: { d[$0] < d[$1] }), d[k] <= near else { return nil }
        guard let a = (0..<k).last(where: { d[$0] >= passFrom }),
              let b = ((k + 1)..<f.count).first(where: { d[$0] >= passFrom }) else { return nil }
        // the station lies between them, not off to one side
        guard Geo.metres(f[a].p, f[b].p) >= 0.8 * (d[a] + d[b]) else { return nil }
        for i in a..<b {
            let dt = f[i + 1].t.timeIntervalSince(f[i].t)
            guard dt > 0, dt <= passGap else { return nil }
            guard Geo.metres(f[i].p, f[i + 1].p) / dt >= passSpeed else { return nil }
        }
        for i in a...b where f[i].speed.isFinite && f[i].speed >= 0 && f[i].speed < passSpeed { return nil }
        return .passedThrough
    }

    /// The candidates the stopping pattern rules out: one that calls at a station you went through at speed; one whose
    /// track runs through a station you stood at, without calling there. Never all of them (a stop at a signal by a
    /// station, a pattern that's wrong): then none.
    /// `calls`: each one's stations (by name); `runsThrough`: the stations its track passes; `seen`: what you did at them.
    static func outByStops(calls: [String: Set<String>], runsThrough: [String: Set<String>], seen: [String: Seen]) -> Set<String> {
        var out = Set<String>()
        for (id, stations) in calls {
            for (s, what) in seen {
                switch what {
                case .passedThrough: if stations.contains(s) { out.insert(id) }
                case .stopped: if !stations.contains(s), runsThrough[id]?.contains(s) == true { out.insert(id) }
                }
            }
        }
        return out.count >= calls.count ? [] : out
    }

    // MARK: asking which one

    /// s: still choosing between two trains this long…
    static let askAfter: TimeInterval = 120

    /// …that go to different places (`destinations`, by their headsign): ask once (`asked`) which one you're on. The two
    /// to ask about, in the order given; nil: don't ask (not trains, not two, the same way, not long enough).
    static func ask(alive: [String], choosingFor: TimeInterval, trains: Bool, destinations: [String: String], asked: Bool) -> (String, String)? {
        guard trains, !asked, alive.count == 2, choosingFor > askAfter else { return nil }
        let a = alive[0], b = alive[1]
        guard let da = destinations[a], let db = destinations[b] else { return nil }
        let na = da.trimmingCharacters(in: .whitespaces).lowercased(), nb = db.trimmingCharacters(in: .whitespaces).lowercased()
        guard !na.isEmpty, !nb.isEmpty, na != nb else { return nil }
        return (a, b)
    }

    /// "IC to 's-Hertogenbosch or IC to Eindhoven?"
    static func askTitle(_ a: (line: String, to: String), _ b: (line: String, to: String)) -> String {
        "\(answer(line: a.line, to: a.to)) or \(answer(line: b.line, to: b.to))?"
    }

    /// A button: "IC to 's-Hertogenbosch".
    static func answer(line: String, to: String) -> String { to.isEmpty ? line : "\(line) to \(to)" }

    // MARK: the trip follows the train you're on

    static let stayNear = 400.0             // m: a call this close to a leg's stop is there
    static let stayNameNear = 1500.0        // m: …or this close with the same station name ("Eindhoven" / "Eindhoven Centraal")
    static let stayRoom: TimeInterval = 120 // s: with only the ride after it to go by, it arrives this long before that leaves
    static let stayLate: TimeInterval = 120 // s: no later than the planned ride gets there, give or take this
    static let stayCatch: TimeInterval = 60 // s: …and still this long before the ride after it leaves

    /// One leg of the trip as the stay-on rule needs it: where it gets on and off, the planned ride's times there, and
    /// which vehicle it was planned with (its trip id, its train number).
    struct StayLeg: Equatable, Sendable {
        var from: GeoPoint
        var to: GeoPoint
        var fromName: String = ""
        var toName: String = ""
        var departure: Date? = nil
        var arrival: Date? = nil
        var tripId: String = ""
        var num: String = ""
    }

    /// One stop of the vehicle you're on (its own stop list: the Transitous trip, the NS journey).
    struct StayCall: Equatable, Sendable {
        var name: String
        var p: GeoPoint
        var arrival: Date?
    }

    /// Stay on through leg `leg` (its stop becomes this leg's end): at `call` of the vehicle's stops (nil: the plan's
    /// own stop, the same train). `sameTrain`: the plan had split one train into legs.
    struct StayHit: Equatable, Sendable {
        let leg: Int
        let call: Int?
        let sameTrain: Bool
    }

    /// A station's name, to tell two spellings of one apart: "Eindhoven Centraal", "Eindhoven, Station" → "eindhoven".
    static func stationKey(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let words = folded.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let drop: Set<String> = ["station", "centraal", "cs", "centraalstation", "busstation", "perron"]
        return words.filter { !drop.contains($0) }.joined()
    }

    /// A train number's digits ("IC 3529" → "3529"); empty when it has none.
    static func digits(_ s: String) -> String { String(s.filter(\.isNumber)) }

    /// The plan's leg runs on the vehicle you're on: the same trip, or the same train number.
    static func sameTrain(_ l: StayLeg, tripId: String, num: String) -> Bool {
        if !tripId.isEmpty, l.tripId == tripId { return true }
        let a = digits(l.num), b = digits(num)
        return !a.isEmpty && a == b
    }

    /// The first call still ahead (`now`) at a stop: within `stayNear`, or by its name within `stayNameNear`.
    static func callAt(_ p: GeoPoint, name: String, in calls: [StayCall], now: Date) -> Int? {
        let key = stationKey(name)
        return calls.indices.first { i in
            guard let a = calls[i].arrival, a > now else { return false }
            let m = Geo.metres(calls[i].p, p)
            if m <= stayNear { return true }
            return !key.isEmpty && m <= stayNameNear && stationKey(calls[i].name) == key
        }
    }

    /// The vehicle you're on (`tripId`, `num`; `calls`: its own stops, with their arrivals) and the trip's `legs`, on
    /// leg `index`: stay seated instead of changing?
    /// - The plan's next legs are the same train (the planner split it): always, up to the last of them.
    /// - It calls at a later leg `k`'s stop (where that leg gets off, or where the ride after it gets on) no later than
    ///   the planned ride gets there (+ `stayLate`), and `stayCatch` before the ride after it leaves; with no planned
    ///   arrival, `stayRoom` before that ride leaves (the last leg: it just has to go there). The furthest such leg.
    /// - Slower, or not going there: nil (the change stays).
    static func stayOn(index: Int, legs: [StayLeg], tripId: String, num: String, calls: [StayCall], now: Date) -> StayHit? {
        guard index >= 0, index + 1 < legs.count else { return nil }
        var same = index
        while same + 1 < legs.count, sameTrain(legs[same + 1], tripId: tripId, num: num) { same += 1 }
        for k in stride(from: legs.count - 1, through: index + 1, by: -1) where k > same {
            if let c = throughCall(k, legs: legs, calls: calls, now: now) { return StayHit(leg: k, call: c, sameTrain: false) }
        }
        guard same > index else { return nil }
        let end = legs[same]
        return StayHit(leg: same, call: callAt(end.to, name: end.toName, in: calls, now: now), sameTrain: true)
    }

    /// Where the vehicle calls at leg `k`'s stop in time (`stayOn`), or nil.
    private static func throughCall(_ k: Int, legs: [StayLeg], calls: [StayCall], now: Date) -> Int? {
        let l = legs[k]
        let after: StayLeg? = k + 1 < legs.count ? legs[k + 1] : nil
        var c = callAt(l.to, name: l.toName, in: calls, now: now)
        if c == nil, let a = after { c = callAt(a.from, name: a.fromName, in: calls, now: now) }
        guard let i = c, let arr = calls[i].arrival else { return nil }
        let nextDep: Date? = after?.departure
        if let planned = l.arrival {
            guard arr <= planned.addingTimeInterval(stayLate) else { return nil }
            if let d = nextDep { guard arr <= d.addingTimeInterval(-stayCatch) else { return nil } }
            return i
        }
        if let d = nextDep { return arr <= d.addingTimeInterval(-stayRoom) ? i : nil }
        return after == nil ? i : nil
    }

    /// The field log's line: "stay on · IC 3529 also reaches Eindhoven 15:24 (plan changed at Tilburg 15:05 → IC 3631
    /// 15:12)"; the same train split by the plan: "stay on · IC 3529 is the next leg's train too: on to Eindhoven
    /// (plan split it at Tilburg)". Times as shown ("" when not known).
    static func stayLog(vehicle: String, reaches: String, at: String, changeAt: String, changeTime: String,
                        next: String, nextTime: String, sameTrain: Bool) -> String {
        if sameTrain { return "stay on · \(vehicle) is the next leg's train too: on to \(reaches) (plan split it at \(changeAt))" }
        let when = at.isEmpty ? "" : " \(at)"
        let changed = changeTime.isEmpty ? changeAt : "\(changeAt) \(changeTime)"
        let nextAt: String = nextTime.isEmpty ? "" : " \(nextTime)"
        let then: String = next.isEmpty ? "" : " → \(next)\(nextAt)"
        return "stay on · \(vehicle) also reaches \(reaches)\(when) (plan changed at \(changed)\(then))"
    }

    // MARK: what the ride screen calls it

    /// The ride's headline: the vehicle by where it really goes (its headsign), and where you get off. Never "Intercity
    /// to <your stop>" for a train that goes further. `stayOnTo`: the trip stays on it past a planned change.
    /// "Intercity to Zwolle" / "Get off at Tilburg"; "Stay on to Eindhoven" / "Intercity to Zwolle".
    static func headline(vehicle: String, headsign: String, legEnd: String, stayOnTo: String?) -> (title: String, detail: String?) {
        let sign = headsign.trimmingCharacters(in: .whitespaces)
        let going = sign.isEmpty ? vehicle : "\(vehicle) to \(sign)"
        if let s = stayOnTo, !s.isEmpty { return ("Stay on to \(s)", going) }
        if !sign.isEmpty, stationKey(sign) == stationKey(legEnd) { return (going, nil) }
        return (going, legEnd.isEmpty ? nil : "Get off at \(legEnd)")
    }

    /// The same, on one line for the lock screen: "Intercity to Zwolle · get off at Tilburg"; "Stay on to Eindhoven".
    static func lockHeadline(vehicle: String, headsign: String, legEnd: String, stayOnTo: String?) -> String {
        let h = headline(vehicle: vehicle, headsign: headsign, legEnd: legEnd, stayOnTo: stayOnTo)
        if stayOnTo != nil { return h.title }
        guard let d = h.detail else { return h.title }
        return "\(h.title) · \(d.prefix(1).lowercased())\(d.dropFirst())"
    }
}
