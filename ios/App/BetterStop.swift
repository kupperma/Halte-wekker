import Foundation

/// (0.42.9) The best place to get off. On 2026-11-27 the Intercity you were on went past both 's-Hertogenbosch and
/// Eindhoven, while the plan changed at Tilburg for Eindhoven and the 305 from there; getting off at 's-Hertogenbosch
/// for the 306 was much faster. While on a bus or train whose own stops go on past where this leg gets off, a few of its
/// later stops (within `horizon`, nearest your destination first, `maxCandidates` at most) are planned from, once each
/// (`every` at most); one that gets you there `gain` sooner, or as soon with fewer changes, is offered: "Stay on to
/// 's-Hertogenbosch — home 15:52 instead of 16:01 (bus 306 at 15:31)". Only a tap takes it (the plain merge, the same
/// train or as fast, is `TrainRules.stayOn`, by itself).
/// Plain values only, so it can be tested.
enum BetterStop {
    static let horizon: TimeInterval = 90 * 60      // its stops this far ahead
    static let maxCandidates = 3                    // one planner question each
    static let every: TimeInterval = 300            // looked at again at most this often
    static let gain: TimeInterval = 180             // at least this much sooner
    static let sameWithin: TimeInterval = 60        // "as soon": within this, then with fewer changes
    static let changeRoom: TimeInterval = 60        // the ride from there leaves at least this long after it gets there

    /// The vehicle's stops worth planning from: after `after` (the call where this leg gets off), still ahead, within
    /// `horizon`, nearest `dest` first, `maxCandidates` at most. None: it doesn't go on past your stop.
    static func candidates(calls: [TrainRules.StayCall], after: Int, dest: GeoPoint, now: Date) -> [Int] {
        guard after >= 0, after + 1 < calls.count else { return [] }
        let until = now.addingTimeInterval(horizon)
        let later: [Int] = Array((after + 1)..<calls.count).filter { i in
            guard let a = calls[i].arrival else { return false }
            return a > now && a <= until
        }
        let near: [Int] = later.sorted { a, b in
            let da: Double = Geo.metres(calls[a].p, dest)
            let db: Double = Geo.metres(calls[b].p, dest)
            return da != db ? da < db : a < b
        }
        return Array(near.prefix(maxCandidates))
    }

    /// Getting off at `stop` (its index among the calls), then the plan from there: there `arrival` with `changes`.
    struct Option: Equatable, Sendable {
        var stop: Int
        var arrival: Date
        var changes: Int
    }

    /// The one to offer, against the plan (there `current` with `currentChanges` changes still to make): the soonest,
    /// `gain` sooner, or as soon (`sameWithin`) with fewer changes. Nil: keep the plan.
    static func best(current: Date, currentChanges: Int, options: [Option]) -> Option? {
        let sorted: [Option] = options.sorted { a, b in
            a.arrival != b.arrival ? a.arrival < b.arrival : (a.changes != b.changes ? a.changes < b.changes : a.stop < b.stop)
        }
        for o in sorted {
            let saved: TimeInterval = current.timeIntervalSince(o.arrival)
            if saved >= gain { return o }
            if abs(saved) <= sameWithin, o.changes < currentChanges { return o }
        }
        return nil
    }

    /// "Stay on to 's-Hertogenbosch — home 15:52 instead of 16:01 (bus 306 at 15:31)".
    static func offerText(stop: String, dest: String, newAt: String, oldAt: String, then: String?) -> String {
        let ride: String = then.map { " (\($0))" } ?? ""
        return "Stay on to \(stop) — \(dest) \(newAt) instead of \(oldAt)\(ride)"
    }

    /// The field log's line: "better stop · stay on to 's-Hertogenbosch · home 15:52 (−9 min)".
    static func log(stop: String, dest: String, newAt: String, minutes: Int) -> String {
        "better stop · stay on to \(stop) · \(dest) \(newAt) (−\(max(0, minutes)) min)"
    }

    /// Whole minutes sooner.
    static func minutesSooner(current: Date, better: Date) -> Int { Int((current.timeIntervalSince(better) / 60).rounded()) }
}
