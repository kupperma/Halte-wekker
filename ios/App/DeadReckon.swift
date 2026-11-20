import Foundation

/// Following the ride in tunnels and dead zones (0.34). When the phone's fixes stop or go bad (worse than 100 m, or none
/// for more than 15 s) during a confirmed ride, the ride's place goes on along the vehicle's route: by the vehicle's
/// own GPS when it has a fresh one, else by its live times, else at its pace (the time its own arrival leaves for the
/// distance left). ETA, the wake rules and the ride screen keep going by it; a good fix puts it back where you are.
/// Safety: a dead-reckoned place alone never rings by distance, only when the time rule agrees.
enum DeadReckon {
    static let quietAfter: TimeInterval = 15        // s without a good fix: follow by reckoning
    static let poorAccuracy = 100.0                 // m: a fix worse than this isn't good
    static let maxFor: TimeInterval = 15 * 60       // s: no further on than this long (then it stays where it got to)
    static let every: TimeInterval = 5              // s between steps while following

    enum Source: String, Sendable { case gps, times, pace }

    struct Estimate: Equatable, Sendable {
        let metres: Double
        let source: Source
    }

    /// A fix good enough to follow you by.
    static func good(accuracy: Double) -> Bool { accuracy.isFinite && accuracy >= 0 && accuracy <= poorAccuracy }

    /// Follow by reckoning: the newest good fix is more than `quietAfter` old (and no more than `maxFor`: after that it
    /// stops; nil: none yet on this leg, nothing to go on from).
    static func needed(lastGoodAt: Date?, now: Date) -> Bool {
        guard let l = lastGoodAt else { return false }
        let quiet = now.timeIntervalSince(l)
        return quiet > quietAfter && quiet <= maxFor
    }

    /// m/s the vehicle goes: the distance left over the time to its arrival (live or timetable) when that's 30 s or more
    /// away, else your last speed; never faster than a train or bus goes (`WakeRule.top`). Nil: nothing to go by.
    static func pace(remaining: Double, arrival: Date?, now: Date, lastSpeed: Double?, isTrain: Bool) -> Double? {
        let top = WakeRule.top(isTrain: isTrain)
        if let a = arrival, a.timeIntervalSince(now) >= 30, remaining.isFinite, remaining >= 0 {
            return min(top, remaining / a.timeIntervalSince(now))
        }
        guard let v = lastSpeed, v.isFinite, v >= 0 else { return nil }
        return min(top, v)
    }

    /// Metres along the route at `now`, from `from` (where the last good fix put you, at `at`): the vehicle's own GPS
    /// (`gps`, moved on) first, then its live times (`times`, when no faster than `WakeRule.top` from there), else on at
    /// `pace` for at most `maxFor`. Never back from `from`, never past `end` (your stop).
    static func along(from: Double, at: Date, now: Date, pace: Double?, gps: Double?, times: Double?, end: Double,
                      isTrain: Bool = false) -> Estimate {
        let dt = max(0, min(maxFor, now.timeIntervalSince(at)))
        func clamp(_ m: Double) -> Double { min(max(from, end), max(from, m)) }
        if let g = gps, g.isFinite { return Estimate(metres: clamp(g), source: .gps) }
        if let m = times, m.isFinite, m - from <= WakeRule.top(isTrain: isTrain) * dt + 50 {
            return Estimate(metres: clamp(m), source: .times)
        }
        let v = pace.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0
        return Estimate(metres: clamp(from + v * dt), source: .pace)
    }

    /// The wake rules on a dead-reckoned place: the time rule only (the distance rule never rings on it alone).
    static func decide(_ i: WakeRule.Input) -> WakeRule.Fire? {
        var t = i
        t.by = .time
        t.wakeMetres = -1
        return WakeRule.decide(t)
    }

    /// May it ring: on a dead-reckoned place only by time.
    static func mayRing(_ fire: WakeRule.Fire?, deadReckoned: Bool) -> Bool {
        guard let fire else { return false }
        guard deadReckoned else { return true }
        if case .time = fire { return true }
        return false
    }
}
