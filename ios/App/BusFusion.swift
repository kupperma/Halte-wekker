import Foundation

/// The bus you wait for, where its GPS and its live times together put it (0.40.1). "Where the bus was on the map wasn't
/// matching the actual position until about the end. It teleported when the time changed. GPS usually runs behind the
/// real position, and the time guess is usually in front." (0.40's `WaitMarker` moved a bus drawn near your stop to
/// where its times put it whenever its time there was more than 2 min off: each new live time moved it.)
///
/// Everything in metres along its road:
/// - by its GPS: its last fix on the road, moved on by the time since at the speed it was seen going (at most 1.5× the
///   timetable's between the stops around it; standing at a stop before its live departure there it stays until then;
///   it waits at a timing point until its time), for at most `maxAge`;
/// - by its times: the live time at its next stop, the seconds left at the timetable's speed of that piece, on that
///   piece (`byTimes`);
/// - the two weighed by how sure each is (`gpsWeight`: an old fix counts less; `etaWeight`: fresh live times, and a bus
///   close to your stop, count more), kept between where it was seen and where its times put it; far apart (or seen
///   further on than its times have it), a fresh fix is trusted (`Note.gpsTrusted`); a fix that can't be this journey
///   (seen past its first stop before it starts, or a kilometre ahead of its times) isn't used (`Note.gpsIgnored`);
/// - drawn without jumps (`Glide`): only forward, at most `Glide.minCap` m/s or 1.5× its speed, easing towards the new
///   place over a few seconds; back only when a new fresh fix shows it more than 150 m behind, over 3 s.
/// Standing at your stop by a fresh fix before it leaves: there, "Waiting · leaves 17:42". Plain values, so the rules
/// are tested. Foundation only.
/// 0.40.3: this is only the faint "expected" ghost now; the bus or train itself is drawn where its own GPS put it
/// (`RealFirst`), or by Settings › Map › Bus position: Estimated, here (`RealFirst.estimated`).
enum BusFusion {
    /// s: a fix is moved on for at most this long (the oldest one drawn, `RealPositions.fresh`).
    static let maxAge: TimeInterval = 180
    /// s: a fix this new counts fully…
    static let fullFix: TimeInterval = 20
    /// …and one this old little (0.15), less still after.
    static let lowFix: TimeInterval = 120
    /// s: a fix this new is trusted when the two disagree badly (the matcher's freshness).
    static let trustFix: TimeInterval = 90
    /// m: further apart than this, they disagree badly.
    static let farApart: Double = 1000
    /// s: seen further on than its live times have it by more than this long at its timetable's speed (or `farApart`):
    /// not this journey.
    static let aheadFor: TimeInterval = 120
    /// m: its fix further on than its times have it by more than this: they disagree the wrong way round.
    static let wrongWay: Double = 50
    /// m: a fix this close to a stop is at it.
    static let atStop: Double = 35
    /// m: before its trip starts, a fix this far past its first stop is its journey before.
    static let beforeStart: Double = 150
    /// m/s: never faster than this (108 km/h).
    static let topSpeed: Double = 30
    /// m/s: a piece without times to go by (30 km/h).
    static let plainSpeed: Double = 8
    /// Its speed at most this share of the timetable's for the piece it's on.
    static let capShare: Double = 1.5
    /// s: the timetable has it stand at a stop this long or longer: a timing point (it waits there until its time).
    static let timingDwell: TimeInterval = 30
    /// m: its GPS and its times further apart than this: the stretch between is drawn faintly.
    static let hintApart: Double = 200
    /// s: "Waiting · leaves" only while it leaves more than this from now.
    static let waitLead: TimeInterval = 60
    /// Its times' weight at best (fresh, close): a fresh fix (1) counts more.
    static let etaShare: Double = 0.6

    /// A stop on its road: metres along, its times (live and the timetable's).
    struct Stop: Equatable, Sendable {
        var metres: Double
        var times: StopTimes
        var timing: Bool = false        // a timing point for sure (else by its timetable: `isTiming`)
    }

    /// Its last GPS fix on its road (not moved on): metres along, its time, and the speed it was seen going (between its
    /// last two fixes, or its own), when known.
    struct Fix: Equatable, Sendable {
        var metres: Double
        var at: Date
        var speed: Double? = nil
    }

    /// A stop-to-stop piece of its road, one after another (the home map's pieces).
    struct Piece: Equatable, Sendable {
        var start: Double
        var length: Double
        var departure: Date
        var arrival: Date
        var scheduledDeparture: Date? = nil
        var scheduledArrival: Date? = nil
    }

    struct Input: Equatable, Sendable {
        var stops: [Stop]
        var fix: Fix?
        var live: Bool                  // its times are live (else the timetable's only)
        var timesAt: Date?              // when its live times were fetched
        var mine: Int?                  // your stop
        var mineLeaves: Date? = nil     // when it leaves your stop as the card says it (else its times')
        var now: Date
        var fromStart: Bool = true      // the first stop is where its trip starts (not only the first piece seen)
    }

    enum Note: String, Equatable, Sendable {
        case none
        case gpsTrusted                 // far apart, or seen further on than its times: its fresh fix is trusted
        case gpsIgnored                 // its fix can't be this journey
    }

    struct Estimate: Equatable, Sendable {
        var metres: Double?             // where it is (nil: not known, not drawn)
        var gps: Double? = nil          // by its GPS, moved on
        var eta: Double? = nil          // by its live times
        var raw: Double? = nil          // its fix itself
        var gpsAge: TimeInterval? = nil
        var gpsWeight: Double = 0
        var etaWeight: Double = 0
        var note: Note = .none
        var waiting: Date? = nil        // standing at your stop by a fresh fix: it leaves then
        var started: Bool = true

        /// The stretch between its GPS and its times when they're more than `hintApart` apart (from, to).
        var hint: (from: Double, to: Double)? {
            guard let g = gps, let e = eta, waiting == nil, abs(g - e) > BusFusion.hintApart else { return nil }
            return (min(g, e), max(g, e))
        }
    }

    // MARK: the stops

    /// A timing point: marked so, its trip's first stop, or its timetable has it stand there `timingDwell` or longer.
    static func isTiming(_ stops: [Stop], _ i: Int) -> Bool {
        guard stops.indices.contains(i) else { return false }
        if stops[i].timing || i == 0 { return true }
        guard let a = stops[i].times.scheduledArrival, let d = stops[i].times.scheduledDeparture else { return false }
        return d.timeIntervalSince(a) >= timingDwell
    }

    /// m/s of the piece from stop `k` to the next by the timetable (else its live times), 2 to `topSpeed`; a piece of
    /// less than 30 s (times in whole minutes) counts as 30 s; `plainSpeed` without times.
    static func speed(_ stops: [Stop], segment k: Int) -> Double {
        guard k >= 0, k + 1 < stops.count else { return plainSpeed }
        let length: Double = stops[k + 1].metres - stops[k].metres
        guard length > 0 else { return plainSpeed }
        let from: Date? = stops[k].times.scheduledLeaves ?? stops[k].times.leaves
        let to: Date? = stops[k + 1].times.scheduledAt ?? stops[k + 1].times.at
        guard let from, let to else { return plainSpeed }
        let secs: TimeInterval = max(30, to.timeIntervalSince(from))
        return min(topSpeed, max(2, length / secs))
    }

    /// The piece `m` metres along is on: the first stop whose next one is further on (before the first stop: 0); nil
    /// past the last.
    static func segment(_ stops: [Stop], at m: Double) -> Int? {
        guard stops.count >= 2 else { return nil }
        for k in 0..<(stops.count - 1) where stops[k + 1].metres > m { return k }
        return nil
    }

    /// The timetable's speed where it is (`speed` of the piece `m` is on, else of the last).
    static func plannedSpeed(_ stops: [Stop], at m: Double) -> Double {
        let k: Int = segment(stops, at: m) ?? max(0, stops.count - 2)
        return speed(stops, segment: k)
    }

    /// Stops from pieces one after another: each piece's end is the next one's start.
    static func stops(pieces: [Piece]) -> [Stop] {
        guard let first = pieces.first else { return [] }
        let t0 = StopTimes(arrival: nil, departure: first.departure, scheduledArrival: nil, scheduledDeparture: first.scheduledDeparture)
        var out: [Stop] = [Stop(metres: first.start, times: t0)]
        for k in pieces.indices {
            let p: Piece = pieces[k]
            let next: Piece? = k + 1 < pieces.count ? pieces[k + 1] : nil
            let t = StopTimes(arrival: p.arrival, departure: next?.departure, scheduledArrival: p.scheduledArrival,
                              scheduledDeparture: next?.scheduledDeparture)
            out.append(Stop(metres: p.start + p.length, times: t))
        }
        return out
    }

    // MARK: by its times

    struct ByTimes: Equatable, Sendable {
        var metres: Double
        var next: Int                   // the stop it gets to next (or stands at)
        var started: Bool
        var done: Bool
        var toNext: TimeInterval?       // s until it's at `next` (0: standing there)
    }

    /// Where its live times put it at `now`: standing at a stop until it leaves there; on its way to the next stop, the
    /// seconds left at the timetable's speed of that piece (`speed`), on that piece.
    static func byTimes(_ stops: [Stop], now: Date) -> ByTimes? {
        guard !stops.isEmpty else { return nil }
        for i in stops.indices {
            if i > 0, let a = stops[i].times.at, now < a {
                let left: TimeInterval = a.timeIntervalSince(now)
                let lo: Double = stops[i - 1].metres
                let hi: Double = stops[i].metres
                let back: Double = left * speed(stops, segment: i - 1)
                return ByTimes(metres: min(hi, max(lo, hi - back)), next: i, started: true, done: false, toNext: left)
            }
            if let d = stops[i].times.leaves, now < d {
                return ByTimes(metres: stops[i].metres, next: i, started: i > 0, done: false, toNext: 0)
            }
        }
        let last: Int = stops.count - 1
        return ByTimes(metres: stops[last].metres, next: last, started: true, done: true, toNext: nil)
    }

    // MARK: by its GPS

    /// Its fix moved on to `now` (for at most `maxAge`): at the speed it was seen going (no less than half the
    /// timetable's, no more than `capShare` times it), else the timetable's; standing at a stop (within `atStop`, not
    /// moving) before its live departure there, it stays until then; reaching a timing point before its time, it waits.
    static func ahead(_ stops: [Stop], fix: Fix, now: Date) -> Double {
        let end: Date = min(now, fix.at.addingTimeInterval(maxAge))
        var t: Date = fix.at
        var m: Double = fix.metres
        guard stops.count >= 2, t < end else { return m }
        let moving: Bool = (fix.speed ?? 0) >= 1.5
        let near: [Int] = stops.indices.filter { abs(stops[$0].metres - m) <= atStop }
        if !moving, let s = near.min(by: { abs(stops[$0].metres - m) < abs(stops[$1].metres - m) }),
           m <= stops[s].metres + 15, let d = stops[s].times.leaves, d > t {
            t = d
        }
        var steps = 0
        while t < end, steps <= stops.count {
            steps += 1
            guard let k = segment(stops, at: m) else { break }
            let plan: Double = speed(stops, segment: k)
            var v: Double = plan
            if let seen = fix.speed, seen.isFinite, seen >= 0 { v = max(seen, 0.5 * plan) }
            v = min(v, plan * capShare, topSpeed)
            guard v > 0 else { break }
            let next: Double = stops[k + 1].metres
            let need: TimeInterval = (next - m) / v
            let left: TimeInterval = end.timeIntervalSince(t)
            if need >= left { m += v * left; break }
            t = t.addingTimeInterval(need)
            m = next
            if isTiming(stops, k + 1), let d = stops[k + 1].times.leaves, d > t { t = d }
        }
        return m
    }

    // MARK: weighing the two

    /// How much its GPS counts by its fix's age: 1 up to `fullFix`, down to 0.15 at `lowFix`, 0.05 at `maxAge`.
    static func gpsWeight(age: TimeInterval) -> Double {
        let a: Double = max(0, age)
        if a <= fullFix { return 1 }
        if a <= lowFix { return 1 - 0.85 * (a - fullFix) / (lowFix - fullFix) }
        return max(0.05, 0.15 - 0.10 * (a - lowFix) / (maxAge - lowFix))
    }

    /// How much its times count: `etaShare`, halved at most for live times 4 minutes old (`timesAge`) and for a bus
    /// still 15 minutes or more from your stop (`toGo`).
    static func etaWeight(timesAge: TimeInterval?, toGo: TimeInterval?) -> Double {
        let age: Double = max(0, timesAge ?? 0)
        let fresh: Double = age <= 60 ? 1 : max(0.5, 1 - 0.5 * (age - 60) / 180)
        let go: Double = max(0, toGo ?? 600)
        let close: Double = go <= 120 ? 1 : max(0.5, 1 - 0.5 * (go - 120) / 780)
        return etaShare * fresh * close
    }

    /// Its fix can't be this journey's: before its trip starts (by its times, a minute's slack), seen more than
    /// `beforeStart` past its first stop (the vehicle still on its journey before); or, its times live, seen more than
    /// `farApart` (or `aheadFor` at its timetable's speed, a train's whole-minute times) further on than they have it
    /// now (a bus isn't minutes early: another journey's position).
    static func notThisJourney(_ f: Fix, stops: [Stop], times: ByTimes, live: Bool, fromStart: Bool) -> Bool {
        if fromStart, !times.started, let s0 = stops.first, f.metres > s0.metres + beforeStart,
           let d0 = s0.times.leaves, f.at < d0.addingTimeInterval(-60) {
            return true
        }
        guard live else { return false }
        let limit: Double = max(farApart, aheadFor * plannedSpeed(stops, at: times.metres))
        return f.metres > times.metres + limit
    }

    /// Where it is now, by its GPS and its times together (see the type).
    static func fuse(_ x: Input) -> Estimate {
        var out = Estimate(metres: nil)
        guard let times = byTimes(x.stops, now: x.now) else { return out }
        let mine: Int? = x.mine.flatMap { x.stops.indices.contains($0) ? $0 : nil }
        let started: Bool = times.started || !x.fromStart
        out.started = started
        out.eta = times.metres
        var fix: Fix? = x.fix
        if let f = fix, notThisJourney(f, stops: x.stops, times: times, live: x.live, fromStart: x.fromStart) {
            fix = nil
            out.note = .gpsIgnored
        }
        guard let f = fix else {
            // by its times alone; before its trip starts at your stop, where it is isn't known
            if !started && mine == 0 { return out }
            out.metres = times.metres
            out.etaWeight = 1
            return out
        }
        let age: TimeInterval = max(0, x.now.timeIntervalSince(f.at))
        let g: Double = ahead(x.stops, fix: f, now: x.now)
        out.gps = g
        out.raw = f.metres
        out.gpsAge = age
        if !x.live { out.eta = nil }
        // standing at your stop by a fresh fix, before it leaves: there, "Waiting · leaves 17:42"
        if let m = mine, age <= trustFix, abs(f.metres - x.stops[m].metres) <= atStop,
           let leaves = x.mineLeaves ?? x.stops[m].times.leaves, leaves.timeIntervalSince(x.now) > waitLead {
            out.metres = x.stops[m].metres
            out.waiting = leaves
            out.gpsWeight = 1
            return out
        }
        var fused: Double = g
        if x.live {
            let e: Double = times.metres
            var toGo: TimeInterval? = times.toNext
            if let m = mine, let a = x.stops[m].times.at { toGo = a.timeIntervalSince(x.now) }
            let wg: Double = gpsWeight(age: age)
            let we: Double = etaWeight(timesAge: x.timesAt.map { x.now.timeIntervalSince($0) }, toGo: toGo)
            out.gpsWeight = wg
            out.etaWeight = we
            let blend: Double = (wg * g + we * e) / (wg + we)
            if f.metres > e + wrongWay {
                // seen further on than its times have it now: they're behind it
                if age <= trustFix { fused = g; out.note = .gpsTrusted } else { fused = max(f.metres, blend) }
            } else if e - g > farApart && age <= trustFix {
                fused = g
                out.note = .gpsTrusted
            } else {
                // GPS behind, its times ahead: between where it was seen and where its times put it
                let lo: Double = f.metres
                let hi: Double = max(e, f.metres)
                fused = min(hi, max(lo, blend))
            }
        } else {
            out.gpsWeight = 1
        }
        // (0.24.5) at your stop only once its fix is, not by moving it on
        if let m = mine {
            let me: Double = x.stops[m].metres
            if f.metres < me - atStop { fused = min(fused, me - atStop) }
        }
        out.metres = fused
        return out
    }

    // MARK: drawing it

    /// Where it's drawn, step by step: towards where it is (`step`), never backwards for nothing, never in a jump.
    struct Glide: Equatable, Sendable {
        /// s: closes about 40 % of a gap a second (a new place blends in over a few seconds)…
        static let tau: TimeInterval = 2
        /// …at most this fast (m/s), or `capShare` times its speed when that's more.
        static let minCap: Double = 25
        /// m: a new fresh fix this far behind what's drawn moves it back…
        static let backBy: Double = 150
        /// …over this long (s).
        static let backFor: TimeInterval = 3
        /// s: a fix this new is fresh enough to move it back.
        static let freshBack: TimeInterval = 60
        /// s: no step for this long: it starts again where it is.
        static let restartAfter: TimeInterval = 20
        /// s: one step counts for this long at most.
        static let maxStep: TimeInterval = 5

        private(set) var shown: Double? = nil
        private(set) var at: Date? = nil
        private var fixAt: Date? = nil
        private var backFrom: Double? = nil
        private var backStart: Date? = nil

        init() {}

        /// Where to draw it at `now`, going to `target` (metres along) at about `speed` (m/s, its timetable's there).
        /// `fixAt`/`fixAge`: its GPS fix used (a new one, fresh and far enough behind, moves it back).
        mutating func step(to target: Double, now: Date, speed: Double, fixAt fix: Date? = nil, fixAge: TimeInterval? = nil) -> Double {
            let newFix: Bool = fix != nil && fix != fixAt
            if fix != nil { fixAt = fix }
            guard target.isFinite else { return shown ?? 0 }
            guard let s = shown, let last = at, now >= last, now.timeIntervalSince(last) <= Self.restartAfter else {
                shown = target; at = now; backFrom = nil; backStart = nil
                return target
            }
            let dt: TimeInterval = min(Self.maxStep, now.timeIntervalSince(last))
            at = now
            let fresh: Bool = (fixAge ?? .infinity) <= Self.freshBack
            if newFix && fresh && target < s - Self.backBy {
                backFrom = s
                backStart = now
            }
            if let from = backFrom, let start = backStart {
                let f: Double = min(1, now.timeIntervalSince(start) / Self.backFor)
                let v: Double = from + (target - from) * f
                if f >= 1 || target >= from { backFrom = nil; backStart = nil }
                shown = v
                return v
            }
            guard target > s else { return s }
            let gap: Double = target - s
            let v: Double = max(0, speed.isFinite ? speed : 0)
            let cap: Double = max(Self.minCap, BusFusion.capShare * v) * dt
            let ease: Double = gap * (1 - exp(-dt / Self.tau))
            let pace: Double = v * dt
            let move: Double = min(gap, cap, max(ease, pace))
            shown = s + move
            return s + move
        }

        /// Not drawn any more: the next step starts where it is.
        mutating func reset() { self = Glide() }
    }

    // MARK: words

    /// "Waiting · leaves 17:42" (`clock` formats the time).
    static func waitingText(leaves: Date, clock: (Date) -> String) -> String { "Waiting · leaves \(clock(leaves))" }

    /// "+320 m", "-80 m": metres rounded to 10, signed.
    static func signed(_ m: Double) -> String {
        guard m.isFinite else { return "? m" }
        let r: Int = Int((max(-1e7, min(1e7, m)) / 10).rounded()) * 10
        return r >= 0 ? "+\(r) m" : "\(r) m"
    }

    /// The log line, once a minute while you wait: "bus fused · 305·9449 · gps 48 s old +320 m · eta says +510 m ·
    /// drawn +440 m" (metres from its fix itself). `kind`: "bus"/"train"; `vehicle`: "305·9449".
    static func logLine(kind: String, vehicle: String, _ e: Estimate, drawn: Double) -> String {
        var parts: [String] = ["\(kind) fused", vehicle]
        if let raw = e.raw, let g = e.gps {
            let age: Int = Int((e.gpsAge ?? 0).rounded())
            parts.append("gps \(age) s old \(signed(g - raw))")
            parts.append(e.eta.map { "eta says \(signed($0 - raw))" } ?? "no live times")
            parts.append("drawn \(signed(drawn - raw))")
        } else {
            parts.append(e.note == .gpsIgnored ? "gps not this journey" : "no gps")
            parts.append("drawn by its times")
        }
        if e.note == .gpsTrusted { parts.append("far apart: gps trusted") }
        if e.waiting != nil { parts.append("waiting at your stop") }
        return parts.joined(separator: " · ")
    }
}
