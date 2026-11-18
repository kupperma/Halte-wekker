import Foundation

/// The bus you're waiting for, by its own GPS (0.24.5): when it can be at your stop at the soonest, and where to draw
/// it until it's really there. Plain values (metres along its road, stop times), so the rules can be tested.
///
/// Why: the time on the card is Transitous's (OpenOV's predictions, which let a late bus make its delay up and lag
/// behind one stuck in traffic between two stops), while the map draws the bus by its GPS. The stop's own board
/// (KV78) said 8 minutes when the app still said 4. And the map moved the bus on from its fix at its times' speed for
/// up to a minute (`RealPositions.advance`), onto your stop and waiting there, while it was still a few hundred
/// metres off.
enum Approach {
    /// m: its GPS fix within this of your stop (or past it): it's there.
    static let atStop: Double = 35
    /// m: further past your stop than this, it has passed it (no time to wait for).
    static let passed: Double = 20
    /// An estimate from a fix this old or newer starts showing (the matcher's freshness)…
    static let fresh: TimeInterval = RealPositions.matchFresh
    /// …and one shown keeps showing with a fix this old or newer (what the map still draws by).
    static let keepFresh: TimeInterval = RealPositions.fresh
    /// The GPS's time at least this much later than the given one: it's shown instead…
    static let showFrom: TimeInterval = 120
    /// …until it's less than this later again.
    static let showUntil: TimeInterval = 60
    /// A new estimate replaces the one shown only when it's this much different (no flicker).
    static let deadBand: TimeInterval = 30

    // MARK: where to draw it

    /// Metres along to draw it at while you wait at your stop (`mine` metres along), with a GPS fix: moving it on from
    /// its fix (`advanced`) brings it at most `atStop` short of your stop; only the fix itself (`raw`) within `atStop`
    /// of the stop, or past it, puts it there.
    static func drawn(advanced: Double, raw: Double, mine: Double) -> Double {
        guard advanced.isFinite, raw.isFinite, mine.isFinite else { return advanced }
        if raw >= mine - atStop { return advanced }
        return min(advanced, mine - atStop)
    }

    // MARK: when it can be there

    /// Seconds its timetable takes from `metres` along to stop `mine`: the rest of the piece it's on, by its share of
    /// the way, and the pieces after it, each from leaving one stop to getting to the next (the timetable's times,
    /// else the live ones). The waits at stops on the way don't count (a late bus doesn't wait them out): it can't be
    /// there sooner than this. 0 when it's within `atStop` of your stop; nil when it has passed it, or a piece has no
    /// times. `stopMetres` and `times`: each stop's, in order.
    static func runTime(from metres: Double, stopMetres: [Double], times: [StopTimes], mine: Int) -> TimeInterval? {
        guard metres.isFinite, stopMetres.count == times.count, stopMetres.indices.contains(mine) else { return nil }
        let me = stopMetres[mine]
        if metres > me + passed { return nil }
        if metres >= me - atStop || mine == 0 { return 0 }
        // the piece it's on: from the last stop at or before it (before the first: from the first)
        let k = min(mine - 1, stopMetres.indices.last { stopMetres[$0] <= metres } ?? 0)
        func run(_ i: Int) -> TimeInterval? {
            let leave = times[i].scheduledLeaves ?? times[i].leaves
            let get = times[i + 1].scheduledAt ?? times[i + 1].at
            guard let leave, let get else { return nil }
            return max(0, get.timeIntervalSince(leave))
        }
        guard let first = run(k) else { return nil }
        let length = stopMetres[k + 1] - stopMetres[k]
        let share = length > 0 ? min(1, max(0, (stopMetres[k + 1] - metres) / length)) : 0
        var total = share * first
        for i in (k + 1)..<mine {
            guard let r = run(i) else { return nil }
            total += r
        }
        return total
    }

    /// The soonest it can be at stop `mine`, by its GPS fix of `fixAt` at `metres` along (`runTime`). Nil when it has
    /// passed your stop, or there are no times to go by.
    static func arrival(fixAt: Date, metres: Double, stopMetres: [Double], times: [StopTimes], mine: Int) -> Date? {
        runTime(from: metres, stopMetres: stopMetres, times: times, mine: mine).map { fixAt.addingTimeInterval($0) }
    }

    /// Which time to show for the one you're waiting for: the given one (Transitous's), unless its GPS says it can't be
    /// there before a later one. Steady: the GPS's time shows once it's `showFrom` later (from a fix of at most
    /// `fresh`), stays until it's less than `showUntil` later (or its fix is older than `keepFresh`, or gone), and
    /// moves only by `deadBand` or more.
    struct Steady: Equatable {
        private(set) var shown: Date?

        /// The later time to show now (nil: the given one). `estimate`: `arrival`'s, from a fix `fixAge` old.
        mutating func update(given: Date, estimate: Date?, fixAge: TimeInterval?) -> Date? {
            guard let est = estimate, let age = fixAge, age >= -60, age <= (shown == nil ? fresh : keepFresh) else {
                shown = nil; return nil
            }
            let lead = est.timeIntervalSince(given)
            if let s = shown {
                if lead < showUntil { shown = nil; return nil }
                if abs(est.timeIntervalSince(s)) >= deadBand { shown = est }
            } else {
                guard lead >= showFrom else { return nil }
                shown = est
            }
            return shown.map { max($0, given) }
        }
    }
}
