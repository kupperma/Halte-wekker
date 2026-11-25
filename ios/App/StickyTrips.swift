import Foundation

/// Sticky upcoming trips (0.40). Walking to the stop, the bus you were heading for sometimes dropped out of your next
/// trips for a bit and came back: an answer that failed or came back empty or half, a new plan from where you are now
/// (that left it out: at the planner's walking pace you "can't" make it any more), or simply its time to leave being
/// more than two minutes ago while you're well on your way. The rules for the home's list of next trips:
/// - a failed, empty or partial answer never takes trips away: what's still to come stays (a partial one adds to it);
/// - a whole answer replaces the list, but the trip you're heading for (the one shown first) stays until it has left
///   (by its live time) — unless you're on it, which the on-board card shows instead;
/// - a trip in both is the new answer's (its times are newer).
/// Plain values, so the rules are tested. Foundation only.
enum StickyTrips {
    /// A trip has left this long after its (live) departure.
    static let leftAfter: TimeInterval = 60

    struct Item: Equatable, Sendable {
        var id: String              // the trip's own id
        var firstTrip: String       // its first ride's trip id: the same bus in two answers
        var departs: Date           // its first ride's departure (live, else the timetable's)
        var leave: Date             // when you leave for it
        var cancelled: Bool = false // its first ride is cancelled
    }

    enum Answer: Equatable, Sendable {
        case failed                 // nothing came back (an error, a timeout)
        case partial                // only part of the answer (the first plan in, a timeout half way)
        case whole                  // the whole answer
    }

    /// Still to come: not left yet (`leftAfter` past its departure), not cancelled.
    static func toCome(_ i: Item, now: Date) -> Bool {
        !i.cancelled && i.departs.addingTimeInterval(leftAfter) > now
    }

    /// The list after an answer (its ids, by when you leave; ties in the answer's order, then the kept ones').
    /// `held`: the first ride's trip id of the trip you're heading for (shown first); `onIt`: you're on that one now.
    static func merge(kept: [Item], answer: [Item], kind: Answer, held: String?, onIt: Bool = false, now: Date) -> [String] {
        // an empty whole answer is no answer: nothing to go by (Transitous has bad moments)
        let k: Answer = (kind == .whole && answer.isEmpty) ? .failed : kind
        var out: [Item] = []
        var seen = Set<String>()
        func add(_ i: Item) {
            guard seen.insert(i.firstTrip.isEmpty ? i.id : i.firstTrip).inserted else { return }
            out.append(i)
        }
        switch k {
        case .failed:
            for i in kept where toCome(i, now: now) { add(i) }
        case .partial:
            for i in answer where toCome(i, now: now) { add(i) }
            for i in kept where toCome(i, now: now) { add(i) }
        case .whole:
            for i in answer where toCome(i, now: now) { add(i) }
            if let h = held, !h.isEmpty, !onIt, let i = kept.first(where: { $0.firstTrip == h }), toCome(i, now: now) { add(i) }
        }
        let ordered = out.enumerated().sorted { a, b in
            a.element.leave != b.element.leave ? a.element.leave < b.element.leave : a.offset < b.offset
        }
        return ordered.map { $0.element.id }
    }

    /// The trip to hold on to: the one shown first now (`NextTrip.pick`'s), while it's still to come.
    static func held(shown: Item?, now: Date) -> String? {
        guard let s = shown, toCome(s, now: now) else { return nil }
        return s.firstTrip
    }

    /// You're heading for the held trip once its time to leave is this close (or past).
    static let headingWithin: TimeInterval = 5 * 60

    /// Which trip the card shows. The held one (`heldIndex`) once its time to leave has come (`headingWithin`), while
    /// it's still to come: as long as you can still get to its stop (`reachable`), or, when that isn't known, until
    /// `grace` past its time to leave (as before). Else the first you can still leave for in time (`NextTrip.grace`).
    static func pick(items: [Item], heldIndex: Int?, reachable: Bool?, now: Date, grace: TimeInterval = 2 * 60) -> Int? {
        if let h = heldIndex, items.indices.contains(h), toCome(items[h], now: now),
           items[h].leave.timeIntervalSince(now) <= headingWithin {
            if reachable == true { return h }
            if reachable == nil && items[h].leave.timeIntervalSince(now) > -grace { return h }
        }
        return items.firstIndex { $0.leave.timeIntervalSince(now) > -grace && !$0.cancelled }
            ?? items.firstIndex { $0.leave.timeIntervalSince(now) > -grace }
    }

    /// Can you still get to its stop in time: `metres` from it, at a brisk walk (`brisk` m/s, the streets a third
    /// longer than the straight line), before it leaves. Nil: where you are or the stop isn't known.
    static let brisk = 1.7
    static func reachable(metres: Double?, departs: Date, now: Date) -> Bool? {
        guard let m = metres, m.isFinite, m >= 0 else { return nil }
        let need: TimeInterval = m * 1.3 / brisk
        return now.addingTimeInterval(need) <= departs.addingTimeInterval(30)
    }
}
