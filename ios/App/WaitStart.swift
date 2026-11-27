import Foundation

/// Starting the trip while Fastest trip watches (0.42.4). From the field report of 27 November: on at Veghel bus
/// station, a stop before the planned one (Biezendijk) and an earlier 305 than the planned 09:52, the ride never
/// started; the screen went on saying "Go to Veghel, Biezendijk" with you on the bus past it. One look decides it now,
/// whatever is on screen:
/// - you move like a bus or train: at `vehicleSpeed` for `movingFor` of the last `window` (a stop on the way still
///   counts), or for `motionFor` while Motion & Fitness says automotive; never while it says you walk or cycle (below
///   `MotionRules.afootTop`), never standing at the stop while a bus goes by;
/// - the matcher's candidates that fit about as well as the best (`Rules.close`) are counted look by look; among them the
///   one that takes you on (to the planned ride's stop, a later ride's, or the destination) is the pick: the planned
///   ride first, then any ride of its line (an earlier or later departure), then the best fit;
/// - by its own GPS one look is enough for the planned ride or its line (this close: `Rules.oneLook`), else two; by its
///   times alone one for the planned ride (that close), two for its line, three for another line;
/// - none of them takes you on, and the best has had its own GPS with you for `WrongBus.gpsFor`: the wrong-bus alert,
///   once for that one (not silence).
/// The planned ride's time (`TimetableStart`) never holds a start on one that was found: it only ever held a start by
/// the timetable alone. Where you got on is the stop of its trip nearest to where you started moving (`boardedAt`), so
/// the leg starts there and not at the stop that was planned. Plain values, so the rules are tested. Foundation only.
enum WaitStart {
    /// m/s: bus or train speed (faster than you walk, run or cycle on the whole).
    static let vehicleSpeed: Double = 6
    /// s at that speed in the last `window` before it's a ride.
    static let movingFor: TimeInterval = 30
    /// …or this long while Motion & Fitness says automotive.
    static let motionFor: TimeInterval = 10
    /// s of fixes looked at.
    static let window: TimeInterval = 120
    /// s: a longer gap between two fixes says nothing about the speed in between.
    static let maxStep: TimeInterval = 30
    /// s: its own GPS fix at most this old makes it "by its GPS".
    static let gpsFresh: TimeInterval = 90
    /// s: below speed for longer than this, the moving starts again (where you got on).
    static let runBreak: TimeInterval = 90
    /// m: the stop you got on at is at most this far from where you started moving.
    static let boardedWithin: Double = 400
    /// m: a stop that close to the planned one is the planned one.
    static let samePlace: Double = 150
    /// m: a trip "takes you on" when one of its stops ahead is this close to a stop of your trip or the destination.
    static let reachWithin: Double = 600

    // MARK: moving like a bus or train

    struct Moving: Equatable, Sendable {
        /// s at `vehicleSpeed` or more in the last `window`.
        let seconds: TimeInterval
        /// m/s now: the newest step's.
        let speed: Double
    }

    /// What Motion & Fitness says, as far as this goes.
    enum Hint: Equatable, Sendable { case none, vehicle, afoot, still }

    static func hint(_ m: MotionNow?) -> Hint {
        if MotionRules.inVehicle(m) { return .vehicle }
        if MotionRules.afoot(m) { return .afoot }
        if MotionRules.still(m) { return .still }
        return .none
    }

    /// The speed between two fixes: the GPS's own when it has one, else the distance over the time when that's more
    /// than their accuracy (a jump indoors isn't a ride).
    static func stepSpeed(_ a: Fix, _ b: Fix) -> Double {
        let dt: TimeInterval = b.t.timeIntervalSince(a.t)
        guard dt > 0 else { return 0 }
        if b.speed.isFinite && b.speed >= 0 { return b.speed }
        let d: Double = Geo.metres(a.p, b.p)
        let acc: Double = max(a.accuracy, b.accuracy)
        return d > acc ? d / dt : 0
    }

    private static func usable(_ fixes: [Fix], now: Date) -> [Fix] {
        let ok: [Fix] = fixes.filter { f in
            f.accuracy >= 0 && f.accuracy < 150 && now.timeIntervalSince(f.t) <= window && f.t <= now.addingTimeInterval(5)
        }
        return ok.sorted { $0.t < $1.t }
    }

    /// How long you've moved at bus or train speed in the last `window`, and how fast now.
    static func moving(_ fixes: [Fix], now: Date) -> Moving {
        let list: [Fix] = usable(fixes, now: now)
        var seconds: TimeInterval = 0
        var last: Double = 0
        if list.count >= 2 {
            for i in 1..<list.count {
                let a: Fix = list[i - 1], b: Fix = list[i]
                let dt: TimeInterval = b.t.timeIntervalSince(a.t)
                guard dt > 0, dt <= maxStep else { continue }
                let v: Double = stepSpeed(a, b)
                if v >= vehicleSpeed { seconds += dt }
                last = v
            }
        } else if let only = list.last, only.speed.isFinite, only.speed >= 0 {
            last = only.speed
        }
        return Moving(seconds: seconds, speed: last)
    }

    /// Nil: you move like a bus or train. Else the rule that holds.
    static func movingRule(_ m: Moving, motion: Hint) -> String? {
        if motion == .afoot && m.speed < MotionRules.afootTop { return "walking or cycling (motion)" }
        if m.seconds >= movingFor { return nil }
        if motion == .vehicle && m.seconds >= motionFor { return nil }
        if m.seconds <= 0 && m.speed < 2 { return "standing" }
        return "not at bus speed for \(Int(movingFor)) s yet"
    }

    /// Where the moving at bus speed began (the first fix of the run that goes on until now): where you got on. Only
    /// a run with a slower fix before it in the window (you stood or walked there): one that began before the window
    /// isn't a boarding it saw. Nil: none.
    static func startedMoving(_ fixes: [Fix], now: Date) -> GeoPoint? {
        let list: [Fix] = usable(fixes, now: now)
        guard list.count >= 2 else { return nil }
        var start: Int?
        var lastFast: Date?
        for i in 1..<list.count {
            let a: Fix = list[i - 1], b: Fix = list[i]
            let dt: TimeInterval = b.t.timeIntervalSince(a.t)
            guard dt > 0, dt <= maxStep, stepSpeed(a, b) >= vehicleSpeed else { continue }
            let broken: Bool = lastFast.map { a.t.timeIntervalSince($0) > runBreak } ?? true
            if start == nil || broken { start = i - 1 }
            lastFast = b.t
        }
        guard let k = start, k > 0 else { return nil }
        return list[k].p
    }

    // MARK: the one you're on

    /// One the matcher found moving with you.
    struct Candidate: Equatable, Sendable {
        let id: String
        let label: String           // "305·2718", for the field log
        let line: String
        let cost: Double            // the matcher's: s off its times (metres with classic matching)
        var gpsAge: TimeInterval? = nil     // judged by its own GPS fix this old (nil: by its times)
        var gpsFor: TimeInterval? = nil     // its own GPS has fitted you this long
        var reaches: Bool? = nil            // takes you on (nil: its stops not known)
        var planned: Bool = false           // the ride it watched for you
        var plannedLine: Bool = false       // a ride of that line (another departure of it)

        var byGPS: Bool { gpsAge.map { $0 <= WaitStart.gpsFresh } ?? false }
    }

    struct Rules: Equatable, Sendable {
        let oneLook: Double         // one look is enough for the planned ride or its line, this close
        let close: Double           // the ones this much worse than the best are counted too
    }

    struct State: Equatable, Sendable {
        var looks: [String: Int] = [:]      // looks in a row each one fitted about as well as the best
        var told: Set<String> = []          // the wrong-bus alert given for these
    }

    enum Call: Equatable, Sendable {
        case start(String)
        case hold(String)
        case wrongBus(String)
    }

    struct Outcome: Equatable, Sendable {
        let state: State
        let call: Call
        let line: String
        /// Looks so far for the one it would start on (0: none on the way to starting).
        let progress: Int
    }

    /// Looks needed before it starts on `c`.
    static func needed(_ c: Candidate, rules r: Rules) -> Int {
        let ours: Bool = c.planned || c.plannedLine
        if c.byGPS { return ours && c.cost < r.oneLook ? 1 : 2 }
        if c.planned && c.cost < r.oneLook { return 1 }
        return c.plannedLine ? 2 : 3
    }

    /// One look while it waits for you to get on.
    static func step(_ s: State, moving m: Moving, motion: Hint, candidates all: [Candidate], rules r: Rules) -> Outcome {
        var st: State = s
        func done(_ call: Call, _ shown: [Candidate], progress: Int = 0) -> Outcome {
            Outcome(state: st, call: call, line: logLine(m, shown, call), progress: progress)
        }
        if let why = movingRule(m, motion: motion) {
            st.looks = [:]
            return done(.hold(why), all)
        }
        guard let top = all.first else {
            st.looks = [:]
            return done(.hold("no bus or train fits your gps"), all)
        }
        let near: [Candidate] = all.filter { $0.cost <= top.cost + r.close }
        var looks: [String: Int] = [:]
        for c in near { looks[c.id] = (st.looks[c.id] ?? 0) + 1 }
        st.looks = looks
        let going: [Candidate] = near.filter { $0.reaches == true }
        let pick: Candidate? = going.first(where: { $0.planned }) ?? going.first(where: { $0.plannedLine }) ?? going.first
        if let p = pick {
            let n: Int = looks[p.id] ?? 0
            let need: Int = needed(p, rules: r)
            if n >= need { return done(.start(p.id), all, progress: n) }
            return done(.hold("seen \(n) of \(need) looks"), all, progress: n)
        }
        if near.contains(where: { $0.reaches == nil }) { return done(.hold("its stops not known yet"), all) }
        // none of them takes you on: sure of the best by its own GPS, the wrong-bus alert (once for it)
        let sure: Bool = top.byGPS && (top.gpsFor ?? 0) >= WrongBus.gpsFor
        if sure && !st.told.contains(top.id) {
            st.told.insert(top.id)
            return done(.wrongBus(top.id), all)
        }
        return done(.hold(st.told.contains(top.id) ? "not your way (told)" : "not your way"), all)
    }

    /// "wait · moving 9 m/s 40 s · candidates 305·2718 gps 12 s fits, 306·1234 times elsewhere · start 305·2718"
    static func logLine(_ m: Moving, _ c: [Candidate], _ call: Call) -> String {
        let speed: Int = Int(m.speed.rounded())
        let secs: Int = Int(m.seconds.rounded())
        var parts: [String] = ["wait · moving \(speed) m/s \(secs) s"]
        if c.isEmpty {
            parts.append("no candidates")
        } else {
            let shown: [String] = c.prefix(3).map(describe)
            parts.append("candidates " + shown.joined(separator: ", "))
        }
        switch call {
        case .start(let id): parts.append("start " + (c.first { $0.id == id }?.label ?? id))
        case .hold(let why): parts.append("held by " + why)
        case .wrongBus(let id): parts.append("wrong bus " + (c.first { $0.id == id }?.label ?? id))
        }
        return parts.joined(separator: " · ")
    }

    private static func describe(_ c: Candidate) -> String {
        let how: String
        if let a = c.gpsAge, c.byGPS { how = "gps \(Int(max(0, a).rounded())) s" } else { how = "times" }
        let goes: String
        switch c.reaches {
        case .some(true): goes = "fits"
        case .some(false): goes = "elsewhere"
        case .none: goes = "stops ?"
        }
        return "\(c.label) \(how) \(goes)"
    }

    /// "wait · watching on · its look at what you get on runs (in front)": Fastest trip began watching. The look runs
    /// from here until `offLine`, whatever is on screen (the cards, the stops around you, a sheet) and with the phone
    /// locked: it belongs to the watching, not to a screen.
    static func onLine(again: Bool, inFront: Bool) -> String {
        "wait · watching \(again ? "again" : "on") · its look at what you get on runs (\(inFront ? "in front" : "behind the screen"))"
    }

    /// "wait · watching off · you're there": it stopped watching, and why.
    static func offLine(why: String) -> String { "wait · watching off · \(why)" }

    /// The look at what you got on runs now (nil), or why not. Nothing about the screen: only the watching, no trip on
    /// yet, not the demo.
    static func lookRuns(watching: Bool, tripIdle: Bool, demo: Bool) -> String? {
        if !watching { return "not watching" }
        if !tripIdle { return "a trip runs" }
        if demo { return "the demo" }
        return nil
    }

    /// A look's line goes to the field log: each one while you move at bus speed or something moves with you, else
    /// once a minute while its call (`key`) stays the same.
    static func logDue(key: String, last: (key: String, at: Date)?, busy: Bool, now: Date) -> Bool {
        if busy { return true }
        guard let l = last else { return true }
        return l.key != key || now.timeIntervalSince(l.at) >= 60
    }

    /// The same line (a departure of the planned one's line, earlier or later).
    static func sameLine(_ a: String, _ b: String) -> Bool {
        let x: String = WrongBus.norm(a), y: String = WrongBus.norm(b)
        return !x.isEmpty && x == y
    }

    // MARK: where it goes, where you got on

    /// A stop of the vehicle's trip, with when it's there (nil: not known).
    struct Stop: Equatable, Sendable {
        let name: String
        let point: GeoPoint
        let time: Date?
    }

    /// It takes you on: a stop of its trip from the one nearest to you on (not one it passed more than 2 minutes ago)
    /// within `reachWithin` of one of `targets` (the planned ride's stop, a later ride's, the destination).
    static func reaches(_ stops: [Stop], here: GeoPoint?, targets: [GeoPoint], now: Date) -> Bool {
        guard !stops.isEmpty, !targets.isEmpty else { return false }
        var from: Int = 0
        if let h = here, let i = stops.indices.min(by: { Geo.metres(stops[$0].point, h) < Geo.metres(stops[$1].point, h) }) { from = i }
        for i in from..<stops.count {
            if let t = stops[i].time, t < now.addingTimeInterval(-120) { continue }
            let p: GeoPoint = stops[i].point
            if targets.contains(where: { Geo.metres($0, p) <= reachWithin }) { return true }
        }
        return false
    }

    /// Where you got on: of its stops up to the one nearest to you now, the one nearest to where you started moving,
    /// within `boardedWithin`. Nil: none that near.
    static func boardedAt(_ stops: [Stop], startedAt start: GeoPoint, here: GeoPoint) -> Int? {
        guard !stops.isEmpty else { return nil }
        let hi: Int = stops.indices.min { Geo.metres(stops[$0].point, here) < Geo.metres(stops[$1].point, here) } ?? stops.count - 1
        let before: [Int] = Array(0...hi).filter { Geo.metres(stops[$0].point, start) <= boardedWithin }
        return before.min { Geo.metres(stops[$0].point, start) < Geo.metres(stops[$1].point, start) }
    }

    /// The stop the leg should start at instead of `planned` (where the ride was to be got on; nil: on board, none):
    /// where you got on, when that's another stop than the planned one. Nil: keep it as it is.
    static func repoint(_ stops: [Stop], startedAt start: GeoPoint?, here: GeoPoint, planned: GeoPoint?) -> Int? {
        guard let s = start, let i = boardedAt(stops, startedAt: s, here: here) else { return nil }
        if let p = planned, Geo.metres(p, stops[i].point) <= samePlace { return nil }
        return i
    }
}
