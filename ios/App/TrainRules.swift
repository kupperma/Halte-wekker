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
/// - `stayOn`: the trip follows the train you're on (no change at Tilburg on the through train).
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

    static let stayNear = 400.0             // m: a call this close to where a later leg ends is there
    static let stayRoom: TimeInterval = 120 // s: in time for the ride after it, with this much room

    /// The train you're on (`calls`: its stops with their arrivals) goes on to where a later leg ends (`ends`, leg by
    /// leg; `departures`: each leg's planned departure): stay on to there instead of changing. The furthest such leg `k`
    /// (> `index`) and the call there; when `k` isn't the last leg, only when it arrives `stayRoom` before the ride after
    /// it (leg k + 1) leaves. Calls already behind you (`now`) don't count.
    static func stayOn(index: Int, ends: [GeoPoint], departures: [Date?], calls: [(p: GeoPoint, arrival: Date?)], now: Date) -> (leg: Int, call: Int)? {
        guard index + 1 < ends.count else { return nil }
        for k in stride(from: ends.count - 1, through: index + 1, by: -1) {
            guard let c = calls.indices.first(where: { i in
                guard let a = calls[i].arrival, a > now else { return false }
                return Geo.metres(calls[i].p, ends[k]) <= stayNear
            }), let arr = calls[c].arrival else { continue }
            if k + 1 < ends.count {
                guard departures.indices.contains(k + 1), let next = departures[k + 1], arr <= next.addingTimeInterval(-stayRoom) else { continue }
            }
            return (k, c)
        }
        return nil
    }
}
