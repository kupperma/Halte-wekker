import Foundation

// 0.42.9: a long ride for less battery and data. Field logs of long rides showed the best GPS for almost all of them
// (also on long train legs far from the stop and through long waits at a change), a Live Activity update about once a
// minute, and long-distance coaches tens of kilometres away judged on every look. Plain numbers, so every rule is
// tested without CoreLocation, ActivityKit or the network; Android has the same rules (`ride/RideSaver.kt`) and both
// check `docs/battery-vectors.json`.
//
// Nothing here makes the alarm later. The rough GPS of a long ride is only ever on while the nearest you can be to the
// stop (the fix's distance, less its accuracy, less how far the vehicle can have gone since at its top speed) is
// beyond the wake distance plus 2 km plus what it can cover until the next look (`RideAccuracy.lookEvery`), and while
// its arrival is more than 6 minutes off: so the best GPS is back, at the latest, 2 km before the wake point.

/// The GPS of a ride far from its stop (0.42.9): rough (100 m, a fix every 300 m) while the vehicle you're on is
/// confirmed and the stop is far by distance and by time; the best again near the stop, on doubt, while boarding, and
/// whenever a fix is too old or too rough to say where you are.
enum RideAccuracy {
    enum Tier: String, Equatable { case best, reduced }

    /// The distance filter of the rough tier: a fix every 300 m (a train at 140 km/h: one every 8 s).
    static let reducedFilter = 300.0
    /// To switch it on: the stop more than 8 minutes off (when its time is known)…
    static let enterSeconds: TimeInterval = 8 * 60
    /// …and to stay in it more than 6.
    static let exitSeconds: TimeInterval = 6 * 60
    /// At least this far from the stop to switch it on.
    static let enterMetres = 8000.0
    /// The best again within the wake distance plus this (plus what the vehicle covers until the next look).
    static let exitMargin = 2000.0
    /// A kilometre more to switch it on than to stay in it.
    static let hysteresis = 1000.0
    /// While rough, the decision is taken again at least this often (a timer besides the fixes).
    static let lookEvery: TimeInterval = 30
    /// A bus: the best in its last 3 km whatever its wake distance.
    static let busBest = 3000.0
    /// The first 2 minutes of a leg (getting on, leaving the stop): the best.
    static let boarding: TimeInterval = 120
    /// The top speeds the nearest-you-can-be counts with (m/s): a bus 90 km/h, a train 160 km/h; yours when faster.
    static let busTop = 25.0
    static let trainTop = 45.0
    /// A fix this good (m) to switch it on; while on, a rough fix up to this still says where you are.
    static let enterAccuracy = 100.0
    static let maxAccuracy = 2000.0
    /// A fix older than this says nothing.
    static let freshFix: TimeInterval = 300
    /// The vehicle's last "still the same one?" look that passed: at most this old.
    static let confirmFresh: TimeInterval = 600

    struct Input: Equatable {
        var enabled = true                    // Settings › "Save battery on long rides"
        var asleep = true                     // the leg is asleep: no wake-up yet, nothing ringing
        var confirmed = false                 // the vehicle you're on is confirmed (looks passed, nothing to choose)
        var confirmedAge: TimeInterval?       // since the last look that passed (nil: none)
        var isTrain: Bool
        var metresToStop: Double?             // from your newest fix
        var accuracy: Double?                 // of that fix
        var fixAge: TimeInterval?
        var speed: Double?                    // your speed, m/s, when known
        var wakeMetres: Double                // the wake distance (by time: the time rule's reach)
        var secondsToStop: TimeInterval?      // when it reaches your stop (live, else its times; nil: not known)
        var legAge: TimeInterval              // since the leg started
        var backstop = false                  // the region around the stop was entered
        var needBest = false                  // something else wants the best now (a look that's in doubt)
        var wasReduced = false                // the rough tier is on now
    }

    /// The top speed for the nearest-you-can-be: the vehicle's, or yours when faster.
    static func top(isTrain: Bool, speed: Double?) -> Double {
        let own = speed.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0
        return max(isTrain ? trainTop : busTop, own)
    }

    /// The nearest you can be to the stop now: the fix's distance, less its accuracy, less how far you can have gone
    /// since at `top`. Nil: nothing usable.
    static func nearest(metresToStop: Double?, accuracy: Double?, fixAge: TimeInterval?, top: Double) -> Double? {
        guard let d = metresToStop, d.isFinite, d >= 0 else { return nil }
        guard let a = accuracy, a.isFinite, a >= 0 else { return nil }
        guard let age = fixAge, age.isFinite, age >= 0 else { return nil }
        let off: Double = min(a, maxAccuracy) + top * age
        return max(0, d - off)
    }

    /// Within this of the stop the best is back: the wake distance, 2 km, and what `top` covers until the next look;
    /// for a bus at least its last 3 km.
    static func exitLine(wakeMetres: Double, isTrain: Bool, top: Double) -> Double {
        let w = max(0, wakeMetres.isFinite ? wakeMetres : 0)
        let line: Double = w + exitMargin + top * lookEvery
        return isTrain ? line : max(line, busBest)
    }

    /// Beyond this the rough tier may come on: the exit line and a kilometre more, at least 8 km.
    static func enterLine(wakeMetres: Double, isTrain: Bool, top: Double) -> Double {
        max(enterMetres, exitLine(wakeMetres: wakeMetres, isTrain: isTrain, top: top) + hysteresis)
    }

    static func tier(_ i: Input) -> Tier {
        guard i.enabled, i.asleep, i.confirmed, !i.backstop, !i.needBest else { return .best }
        guard let c = i.confirmedAge, c.isFinite, c >= 0, c <= confirmFresh else { return .best }
        guard i.legAge.isFinite, i.legAge >= boarding else { return .best }
        guard i.wakeMetres.isFinite, i.wakeMetres >= 0 else { return .best }
        let goodEnough: Double = i.wasReduced ? maxAccuracy : enterAccuracy
        guard let a = i.accuracy, a.isFinite, a >= 0, a < goodEnough else { return .best }
        guard let age = i.fixAge, age.isFinite, age >= 0, age <= freshFix else { return .best }
        if let s = i.secondsToStop {
            let due: TimeInterval = i.wasReduced ? exitSeconds : enterSeconds
            guard s.isFinite, s > due else { return .best }
        }
        let v = top(isTrain: i.isTrain, speed: i.speed)
        guard let near = nearest(metresToStop: i.metresToStop, accuracy: a, fixAge: age, top: v) else { return .best }
        let line: Double = i.wasReduced ? exitLine(wakeMetres: i.wakeMetres, isTrain: i.isTrain, top: v)
                                        : enterLine(wakeMetres: i.wakeMetres, isTrain: i.isTrain, top: v)
        return near > line ? .reduced : .best
    }
}

/// Waiting at a change (0.42.9): rough GPS (100 m, a fix every 100 m) once you've stood there 3 minutes, until 3
/// minutes before the next ride leaves (its live time) or you start moving; the best again at once then. Without a
/// known next departure: the best, as before.
enum ChangeWait {
    static let standFor: TimeInterval = 180
    static let lead: TimeInterval = 180
    static let filter = 100.0

    /// `standingFor`: how long you've stood where you are (nil: not known); `nextIn`: the next ride's departure (live,
    /// else planned; nil: none known); `moving`: your fixes move; `inVehicle`: Motion & Fitness says automotive.
    static func low(standingFor: TimeInterval?, nextIn: TimeInterval?, moving: Bool, inVehicle: Bool) -> Bool {
        guard !moving, !inVehicle else { return false }
        guard let s = standingFor, s.isFinite, s >= standFor else { return false }
        guard let n = nextIn, n.isFinite, n > lead else { return false }
        return true
    }
}

/// How often the Live Activity is updated (0.42.9): what it says you should do (waking, ringing, the change, arriving)
/// goes at once; a meaningful change (a stop passed, the delay or the arrival minute, the vehicle, the next ride, the
/// platform, the song) at most once a minute far from the stop, every 20 s in the last 5 minutes; only the distance or
/// the bar moving: every 3 minutes far away, every 20 s near. (The countdown is a timer text: it runs by itself.)
enum ActivityCadence {
    enum Change: Int, Equatable, Comparable {
        case none, look, meaningful, say
        static func < (a: Change, b: Change) -> Bool { a.rawValue < b.rawValue }
    }

    static let farGap: TimeInterval = 60
    static let nearGap: TimeInterval = 20
    static let quietGap: TimeInterval = 180
    static let nearWithin: TimeInterval = 5 * 60

    /// The last 5 minutes before the stop, or awake (inside the wake distance), or ringing.
    static func near(secondsToStop: TimeInterval?, awake: Bool) -> Bool {
        if awake { return true }
        guard let s = secondsToStop, s.isFinite else { return false }
        return s <= nearWithin
    }

    /// The biggest of what changed.
    static func change(say: Bool, meaningful: Bool, look: Bool) -> Change {
        say ? .say : meaningful ? .meaningful : look ? .look : .none
    }

    /// The least time between two updates for this change (nil: nothing to send).
    static func gap(_ c: Change, near: Bool) -> TimeInterval? {
        switch c {
        case .none: return nil
        case .say: return 0
        case .meaningful: return near ? nearGap : farGap
        case .look: return near ? nearGap : quietGap
        }
    }

    static func send(_ c: Change, near: Bool, sinceLast: TimeInterval) -> Bool {
        guard let g = gap(c, near: near) else { return false }
        return sinceLast < 0 || sinceLast >= g
    }

    /// A change held back goes in this many seconds (nil: nothing to send).
    static func later(_ c: Change, near: Bool, sinceLast: TimeInterval) -> TimeInterval? {
        guard let g = gap(c, near: near) else { return nil }
        return max(1, g - max(0, sinceLast))
    }

    /// The arrival as the update key counts it: to the minute.
    static func minute(_ d: Date?) -> Int {
        guard let d else { return 0 }
        return Int((d.timeIntervalSince1970 / 60).rounded(.down))
    }

    /// The distance as the update key counts it: 500 m steps (100 m within 2 km).
    static func distanceStep(_ m: Double?) -> Int {
        guard let m, m.isFinite, m >= 0 else { return -1 }
        return m < 2000 ? Int(m / 100) : 20 + Int(m / 500)
    }
}

/// A ride's network (0.42.9): the ridden trip's live times every 2 minutes far from the stop, every 45 s near it;
/// fewer ways in a re-check from behind the screen; nothing for the home screen while a ride runs.
enum RideNet {
    static let tripFar: TimeInterval = 120
    static let tripNear: TimeInterval = 45
    static let nearWithin: TimeInterval = 10 * 60
    static let nearMargin = 5000.0
    /// The ways a re-check behind the screen asks for at most.
    static let backgroundWays = 3

    /// Near: awake, the stop within 10 minutes, or within the wake distance plus 5 km; neither known: near (as before).
    static func near(secondsToStop: TimeInterval?, metresToStop: Double?, wakeMetres: Double, awake: Bool) -> Bool {
        if awake { return true }
        let s = secondsToStop.flatMap { $0.isFinite ? $0 : nil }
        let d = metresToStop.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        if s == nil && d == nil { return true }
        if let s, s <= nearWithin { return true }
        let w: Double = wakeMetres.isFinite ? max(0, wakeMetres) : 0
        if let d, d <= w + nearMargin { return true }
        return false
    }

    static func tripEvery(near: Bool) -> TimeInterval { near ? tripNear : tripFar }

    /// The ways a re-check asks for: as many as wanted in front, at most 3 behind the screen.
    static func ways(_ wanted: Int, inFront: Bool) -> Int { inFront ? wanted : min(wanted, backgroundWays) }

    /// The list of the next rides at a change: from 30 minutes back, 10 ways, in front; behind the screen 5 ways from
    /// 5 minutes before you got there, or 10 minutes back once that's later (a long wait: the ones still to come are in
    /// it; an older first one stays as it was, `TransferPolicy.firstListed`).
    static func changeList(inFront: Bool, arrived: Date?, now: Date) -> (from: Date, count: Int) {
        guard !inFront else { return (now.addingTimeInterval(-30 * 60), 10) }
        let recent = now.addingTimeInterval(-10 * 60)
        let a = arrived.map { $0.addingTimeInterval(-5 * 60) } ?? recent
        return (min(now, max(a, recent)), 5)
    }

    /// The home screen's own looks (the live times around you, your planned trips): not while a ride runs.
    static func homeLooks(riding: Bool) -> Bool { !riding }
}

/// Before the matcher judges anyone (0.42.9): the ones that can't be the one you're on are left out, so they aren't
/// fetched for (a train's number), judged or logged: long-distance coaches (FlixBus and the like) unless planned, a
/// route that never comes within 1 km of your fixes, or its own GPS further than 3 km (a bus) or 10 km (a train) from
/// you (plus what it can have gone since that fix). The planned one is never left out.
enum CandidatePrefilter {
    enum Why: String, Equatable { case coach, route, far }

    static let routeNear = 1000.0
    static let busFar = 3000.0
    static let trainFar = 10_000.0
    static let busTop = 25.0
    static let trainTop = 45.0
    /// Words in a line's name that make it a long-distance coach.
    static let coachWords = ["flixbus", "flix bus", "blablacar", "eurolines", "regiojet", "megabus", "ouibus", "pinkbus"]

    struct Candidate: Equatable {
        var tripId: String
        var line: String
        var isTrain: Bool
        var paths: [[GeoPoint]]
        var gps: GeoPoint? = nil
        var gpsAge: TimeInterval? = nil
    }

    struct Counts: Equatable {
        var coach = 0
        var route = 0
        var far = 0
        var total: Int { coach + route + far }

        mutating func add(_ w: Why) {
            switch w {
            case .coach: coach += 1
            case .route: route += 1
            case .far: far += 1
            }
        }

        static func + (a: Counts, b: Counts) -> Counts { Counts(coach: a.coach + b.coach, route: a.route + b.route, far: a.far + b.far) }
    }

    static func isCoach(_ line: String) -> Bool {
        let l = line.lowercased()
        return coachWords.contains { l.contains($0) }
    }

    /// The least distance from your fixes to its route (nil: no route known).
    static func routeMetres(_ paths: [[GeoPoint]], from you: [GeoPoint]) -> Double? {
        var best: Double?
        for path in paths {
            for p in you {
                let d: Double?
                if path.count >= 2 { d = Geo.project(p, on: path)?.crossTrack }
                else if let only = path.first { d = Geo.metres(p, only) }
                else { d = nil }
                if let d, d.isFinite { best = min(best ?? d, d) }
            }
        }
        return best
    }

    /// Why `c` is left out (nil: it's judged). `you`: your recent fixes, newest last.
    static func drop(_ c: Candidate, you: [GeoPoint], planned: String?) -> Why? {
        if let planned, c.tripId == planned { return nil }
        if isCoach(c.line) { return .coach }
        guard let newest = you.last else { return nil }
        if let r = routeMetres(c.paths, from: you), r > routeNear { return .route }
        if let g = c.gps {
            let age: TimeInterval = c.gpsAge.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 0
            let limit: Double = (c.isTrain ? trainFar : busFar) + (c.isTrain ? trainTop : busTop) * age
            if Geo.metres(newest, g) > limit { return .far }
        }
        return nil
    }

    /// The ones judged, and how many were left out why.
    static func filter<T>(_ items: [T], you: [GeoPoint], planned: String?, candidate: (T) -> Candidate) -> (kept: [T], dropped: Counts) {
        var kept: [T] = []
        var counts = Counts()
        for x in items {
            if let w = drop(candidate(x), you: you, planned: planned) { counts.add(w) } else { kept.append(x) }
        }
        return (kept, counts)
    }

    /// "prefilter · board · 7 of 18 left out (3 coaches, 4 off their route, 0 far by their GPS)"
    static func line(place: String, dropped: Counts, of total: Int) -> String {
        "prefilter · \(place) · \(dropped.total) of \(total) left out (\(dropped.coach) coaches, \(dropped.route) off their route, \(dropped.far) far by their GPS)"
    }
}
