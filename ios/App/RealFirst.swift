import Foundation

/// The bus or train you wait for or ride, drawn where it really is (0.40.3). "The buses and trains on the map aren't
/// usually using their GPS locations, while waiting or travelling. I get that GPS lags behind. But it's nicer when you
/// see the bus actually arrive and it's actually there, even if it lags a little, than a simulated bus that 'should
/// arrive right now at my station' but isn't there yet." (0.40.1's `BusFusion` drew it half by its GPS, half by its
/// times: OVapi's fixes are mostly 25 to 90 s old, so it was rarely where it said it was, and a bus stuck in traffic
/// rolled on to just before your stop.)
///
/// Everything in metres along its road:
/// - by its GPS (`Source.gps`): at its last fix itself, put on its road when it's within `onRoad` of it (else at the fix,
///   `atFix`). Moved on only while its last fixes had it clearly going (`moving`, not standing at a stop): at most
///   `advanceFor` s at the speed it was seen going, never past the next stop it must stop at, never into your stop.
///   No pull from its times.
/// - the estimate (`BusFusion.fuse`, its GPS and its times together) is only a faint ghost ahead of it, when it's more
///   than `ghostAhead` further on; never at or in your stop unless it's due there within `ghostAtStopETA`.
/// - "Arriving", "Waiting · leaves 17:42", "It's at your stop" (`here`) only by a fix of at most `hereFresh` within
///   `hereNear` of your stop.
/// - no usable GPS (`Source.byTimes`): by its times along its road before your stop, not at your stop before it leaves
///   there; where the road before your stop isn't known (its stops start at yours), not drawn (`Source.none`).
/// - on board (`Source.onBoard`): where your own phone is, the surest sign of where it is.
/// Plain values, so the rules are tested. Foundation only.
enum RealFirst {
    /// s: moved on from its fix for at most this long…
    static let advanceFor: TimeInterval = 20
    /// …and only when its last fixes had it going at least this fast (m/s).
    static let moving: Double = 2
    /// m: a fix this close to its road is put on it; further, it's drawn at the fix itself.
    static let onRoad: Double = 60
    /// s: the oldest fix drawn (`RealPositions.fresh`).
    static let fresh: TimeInterval = 180
    /// m: the estimate is drawn (as a ghost) only when it's this much further on than where it's drawn.
    static let ghostAhead: Double = 150
    /// s: the ghost at or in your stop only when it's due there this soon…
    static let ghostAtStopETA: TimeInterval = 30
    /// …else at most this short of it (m).
    static let ghostShort: Double = 100
    /// s: "Arriving" and "Waiting" only by a fix this new…
    static let hereFresh: TimeInterval = 90
    /// …within this of your stop (m).
    static let hereNear: Double = 80
    /// m: a fix this close to your stop is at it (`BusFusion.atStop`).
    static let atStop: Double = BusFusion.atStop
    /// m: further past your stop than this, it has passed it.
    static let passed: Double = 20
    /// Off its known road: a fix no further from your stop than this fast (m/s) to its time there…
    static let rawTop: Double = 40
    /// …plus this (m); further, it can't be this journey.
    static let rawSlack: Double = 3000
    /// s: on board, your phone's fix at most this old…
    static let meFresh: TimeInterval = 30
    /// …and this accurate (m).
    static let meAccuracy: Double = 100

    enum Source: String, Equatable, Sendable {
        case onBoard                    // you're on it: where your phone is
        case gps                        // its own last fix (a little moved on at most)
        case byTimes                    // no usable GPS: by its times
        case none                       // not drawn: no live position
    }

    /// Where it is by a fresh close fix, for the words on the marker and the sheet.
    enum Here: Equatable, Sendable {
        case arriving                   // within `hereNear` before your stop
        case waiting(Date)              // standing at your stop, leaving then
        case atStop                     // at your stop
    }

    /// A position fix on its road: metres along (nil: not on the road known, drawn at the fix itself), its time, the
    /// speed it was seen going, standing at a stop (the feed's STOPPED_AT), metres straight to your stop (for a fix off
    /// its road), metres from its road.
    struct Fix: Equatable, Sendable {
        var metres: Double?
        var at: Date
        var speed: Double? = nil
        var stopped: Bool = false
        var toMine: Double? = nil
        var crossTrack: Double = 0
    }

    struct Input: Equatable, Sendable {
        var stops: [BusFusion.Stop]
        var fix: Fix?
        var live: Bool                  // its times are live (else the timetable's only)
        var timesAt: Date?              // when its live times were fetched
        var mine: Int?                  // your stop
        var mineLeaves: Date? = nil     // when it leaves your stop as the card says it (else its times')
        var now: Date
        var fromStart: Bool = true      // the first stop is where its trip starts (else the road before it isn't known)
        var isTrain: Bool = false       // a train stops at every stop it lists
        var onBoard: Fix? = nil         // you're on it: your phone's own fix (`meFresh`, `meAccuracy` checked by the caller)
    }

    struct Shown: Equatable, Sendable {
        var source: Source
        var metres: Double?             // where it's drawn along its road (nil: at the fix itself, or not drawn)
        var atFix: Bool = false         // drawn at the fix's own place, not on its road
        var raw: Double? = nil          // its fix itself along its road
        var fixAge: TimeInterval? = nil
        var advanced: Double = 0        // m moved on from its fix
        var ghost: Double? = nil        // the estimate, faintly, when well ahead
        var here: Here? = nil
        var why: String? = nil          // no GPS used: why
        var estimate: BusFusion.Estimate

        /// "Waiting · leaves 17:42"'s time.
        var waiting: Date? {
            if case .waiting(let d)? = here { return d }
            return nil
        }

        var isHere: Bool {
            switch here {
            case .atStop?, .waiting?: return true
            default: return false
            }
        }
    }

    // MARK: where it's drawn

    /// Where to draw it now (see the type).
    static func show(_ x: Input) -> Shown {
        let e: BusFusion.Estimate = BusFusion.fuse(fusionInput(x))
        let mine: Int? = x.mine.flatMap { x.stops.indices.contains($0) ? $0 : nil }
        if let me = x.onBoard {
            let age: TimeInterval = max(0, x.now.timeIntervalSince(me.at))
            var out = Shown(source: .onBoard, metres: me.metres, atFix: me.metres == nil, raw: me.metres, fixAge: age, estimate: e)
            out.here = here(me, age: age, x, mine: mine)
            return out
        }
        var why: String = "no fix"
        if let f = x.fix {
            let age: TimeInterval = max(0, x.now.timeIntervalSince(f.at))
            if age > fresh {
                why = "fix \(Int(age.rounded())) s old"
            } else if f.metres != nil, e.note == .gpsIgnored {
                why = "fix not this journey"
            } else if f.metres == nil, !plausibleOffRoad(f, x, mine: mine) {
                why = "fix off its road"
            } else {
                return byGPS(f, age: age, x, e, mine: mine)
            }
        }
        return byTimes(x, e, mine: mine, why: why)
    }

    /// `BusFusion`'s input for the ghost: its fix only when it's on its road.
    static func fusionInput(_ x: Input) -> BusFusion.Input {
        var fix: BusFusion.Fix? = nil
        if let f = x.fix, let m = f.metres { fix = BusFusion.Fix(metres: m, at: f.at, speed: f.stopped ? 0 : f.speed) }
        return BusFusion.Input(stops: x.stops, fix: fix, live: x.live, timesAt: x.timesAt, mine: x.mine, mineLeaves: x.mineLeaves,
                               now: x.now, fromStart: x.fromStart)
    }

    /// A fix off its known road can be this journey: no further from your stop than `rawTop` m/s to its live time there,
    /// plus `rawSlack` (without your stop, or how far: when it's new enough to say "here").
    static func plausibleOffRoad(_ f: Fix, _ x: Input, mine: Int?) -> Bool {
        guard let k = mine, let d = f.toMine else { return x.now.timeIntervalSince(f.at) <= hereFresh }
        let due: Date? = x.stops[k].times.at
        let secs: TimeInterval = max(0, due.map { $0.timeIntervalSince(x.now) } ?? 0)
        return d <= rawTop * secs + rawSlack
    }

    /// By its own fix: there, a little moved on while it was clearly going (`advance`), the ghost ahead.
    static func byGPS(_ f: Fix, age: TimeInterval, _ x: Input, _ e: BusFusion.Estimate, mine: Int?) -> Shown {
        var out = Shown(source: .gps, metres: f.metres, atFix: f.metres == nil, raw: f.metres, fixAge: age, estimate: e)
        out.here = here(f, age: age, x, mine: mine)
        guard let m0 = f.metres else { return out }
        if f.crossTrack > onRoad { out.atFix = true }
        var drawn: Double = m0
        if !out.atFix { drawn = advance(f, from: m0, age: age, x, mine: mine) }
        // at your stop by a fresh fix: right there
        if out.isHere, let k = mine { drawn = x.stops[k].metres }
        out.metres = drawn
        out.advanced = max(0, drawn - m0)
        out.ghost = ghost(e.metres, drawn: drawn, x, mine: mine)
        return out
    }

    /// Its fix moved on (m along): only when its last fixes had it going at least `moving` (not standing at a stop), for
    /// at most `advanceFor` s at that speed (`BusFusion.topSpeed` at most), never past the next stop it must stop at
    /// (`mustStop`), never into your stop (within `atStop`) when its fix isn't there yet.
    static func advance(_ f: Fix, from m0: Double, age: TimeInterval, _ x: Input, mine: Int?) -> Double {
        guard !f.stopped, let v = f.speed, v.isFinite, v >= moving else { return m0 }
        let secs: TimeInterval = min(max(0, age), advanceFor)
        let want: Double = m0 + min(v, BusFusion.topSpeed) * secs
        var cap: Double = want
        if let s = nextMustStop(x, after: m0, mine: mine) { cap = min(cap, x.stops[s].metres) }
        if let k = mine {
            let me: Double = x.stops[k].metres
            if m0 < me - atStop { cap = min(cap, me - atStop) }
        }
        return max(m0, min(want, cap))
    }

    /// The next stop after `m` metres it must stop at: a train's next stop; a bus's next timing point, your stop, or its
    /// last.
    static func nextMustStop(_ x: Input, after m: Double, mine: Int?) -> Int? {
        let last: Int = x.stops.count - 1
        for i in x.stops.indices where x.stops[i].metres > m + 1 {
            if x.isTrain || i == mine || i == last || BusFusion.isTiming(x.stops, i) { return i }
        }
        return nil
    }

    /// The estimate as a ghost: when it's more than `ghostAhead` further on than where it's drawn; not at or in your
    /// stop unless it's due there within `ghostAtStopETA` (else at most `ghostShort` before it); none once it's past
    /// your stop.
    static func ghost(_ estimate: Double?, drawn: Double, _ x: Input, mine: Int?) -> Double? {
        guard var g = estimate, g.isFinite else { return nil }
        if let k = mine {
            let me: Double = x.stops[k].metres
            if drawn > me + passed { return nil }
            let due: TimeInterval? = x.stops[k].times.at.map { $0.timeIntervalSince(x.now) }
            let soon: Bool = due.map { $0 <= ghostAtStopETA } ?? false
            if !soon, g > me - ghostShort { g = me - ghostShort }
        }
        return g - drawn > ghostAhead ? g : nil
    }

    /// Where it is by a fix of at most `hereFresh` against your stop: within `atStop` (or up to `passed` past) at it
    /// ("Waiting" while it leaves more than `BusFusion.waitLead` from now), within `hereNear` before it arriving.
    static func here(_ f: Fix, age: TimeInterval, _ x: Input, mine: Int?) -> Here? {
        guard age <= hereFresh, let k = mine else { return nil }
        let d: Double
        if let m = f.metres { d = m - x.stops[k].metres } else if let t = f.toMine { d = -t } else { return nil }
        guard d >= -hereNear, d <= passed else { return nil }
        if d < -atStop { return .arriving }
        if let leaves = x.mineLeaves ?? x.stops[k].times.leaves, leaves.timeIntervalSince(x.now) > BusFusion.waitLead {
            return .waiting(leaves)
        }
        return .atStop
    }

    /// No usable GPS: by its times along its road before your stop (`BusFusion.byTimes`), not at your stop before it
    /// leaves there (at most `atStop` short of it); not drawn while its stops start at yours and it hasn't left there
    /// (the road before your stop isn't known, or its trip hasn't started).
    static func byTimes(_ x: Input, _ e: BusFusion.Estimate, mine: Int?, why: String) -> Shown {
        guard let b = BusFusion.byTimes(x.stops, now: x.now) else {
            return Shown(source: .none, metres: nil, why: "\(why), no times", estimate: e)
        }
        if let k = mine, k == 0, b.next == 0, !b.done {
            let road: String = x.fromStart ? "trip not started" : "road before your stop not known"
            return Shown(source: .none, metres: nil, why: "\(why), \(road)", estimate: e)
        }
        var m: Double = b.metres
        if let k = mine {
            let me: Double = x.stops[k].metres
            let leaves: Date? = x.stops[k].times.leaves
            let gone: Bool = leaves.map { x.now >= $0 } ?? true
            if !gone, m > me - atStop { m = me - atStop }
        }
        return Shown(source: .byTimes, metres: m, why: why, estimate: e)
    }

    // MARK: the old way (Settings › Map › Bus position: Estimated)

    /// 0.40.1's: where its GPS and its times together put it (`BusFusion`), no ghost.
    static func estimated(_ x: Input) -> Shown {
        let e: BusFusion.Estimate = BusFusion.fuse(fusionInput(x))
        let src: Source = e.metres == nil ? .none : (e.raw == nil ? .byTimes : .gps)
        var out = Shown(source: src, metres: e.metres, raw: e.raw, fixAge: e.gpsAge, estimate: e)
        if let w = e.waiting { out.here = .waiting(w) }
        if src == .none { out.why = "not known" }
        return out
    }

    // MARK: drawing it

    /// Where it's drawn, step by step: a new fix (its place moved by more than `jump` at once) glides from where it was
    /// drawn to there over `over` s, forward or back; else it's drawn where it is.
    struct Glide: Equatable, Sendable {
        /// s: a new place blends in over this long.
        static let over: TimeInterval = 2
        /// m: the place moved this much from one step to the next: a jump, glided.
        static let jump: Double = 25
        /// s: no step for this long: it starts again where it is.
        static let restartAfter: TimeInterval = 20

        private(set) var shown: Double? = nil
        private var at: Date? = nil
        private var target: Double? = nil
        private var from: Double? = nil
        private var start: Date? = nil

        init() {}

        mutating func step(to t: Double, now: Date) -> Double {
            guard t.isFinite else { return shown ?? 0 }
            guard let s = shown, let last = at, now >= last, now.timeIntervalSince(last) <= Self.restartAfter else {
                self = Glide()
                shown = t; at = now; target = t
                return t
            }
            at = now
            if let old = target, abs(t - old) > Self.jump { from = s; start = now }
            target = t
            guard let f = from, let st = start else {
                shown = t
                return t
            }
            let k: Double = min(1, max(0, now.timeIntervalSince(st) / Self.over))
            let ease: Double = k * k * (3 - 2 * k)
            let v: Double = f + (t - f) * ease
            if k >= 1 { from = nil; start = nil }
            shown = v
            return v
        }

        mutating func reset() { self = Glide() }
    }

    // MARK: words

    /// The marker's small label: "GPS 40 s", "by times", "you're on it" (none: "").
    static func tag(_ s: Shown) -> String {
        switch s.source {
        case .onBoard: return "you’re on it"
        case .gps: return "GPS \(ageText(s.fixAge ?? 0))"
        case .byTimes: return "by times"
        case .none: return ""
        }
    }

    /// "40 s", "2 min".
    static func ageText(_ age: TimeInterval) -> String {
        let a: Int = Int(max(0, age).rounded())
        return a < 100 ? "\(a) s" : "\(Int((Double(a) / 60).rounded())) min"
    }

    /// The log line, once a minute: "vehicle shown · 305·9449 · gps ovapi 48 s · real +320 m · ghost +510 m" (metres from
    /// its fix itself), "… · no gps: no fix · by times", "… · on board". `feed`: "ovapi", "ns".
    static func logLine(vehicle: String, feed: String, _ s: Shown, estimated: Bool = false) -> String {
        var parts: [String] = ["vehicle shown", vehicle]
        switch s.source {
        case .onBoard:
            parts.append("on board: drawn where you are")
        case .gps:
            parts.append("gps \(feed) \(Int((s.fixAge ?? 0).rounded())) s")
            if s.atFix {
                parts.append("real at its fix, off its road")
            } else if let raw = s.raw, let m = s.metres {
                parts.append("real \(BusFusion.signed(m - raw))")
                parts.append(s.ghost.map { "ghost \(BusFusion.signed($0 - raw))" } ?? "no ghost")
            }
        case .byTimes:
            parts.append("no gps: \(s.why ?? "no fix")")
            parts.append("by times")
        case .none:
            parts.append("no gps: \(s.why ?? "no fix")")
            parts.append("not drawn")
        }
        switch s.here {
        case .arriving?: parts.append("arriving")
        case .waiting?: parts.append("waiting at your stop")
        case .atStop?: parts.append("at your stop")
        case nil: break
        }
        if estimated { parts.append("estimated") }
        return parts.joined(separator: " · ")
    }
}
