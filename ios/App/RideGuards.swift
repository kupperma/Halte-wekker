import Foundation

/// When a ride may start by itself, when a new leg wakes you, and when the one you picked gives way to another: plain
/// numbers, so they can be tested without CoreLocation. Every rule here refuses to start or to switch by itself; none
/// of them keeps the alarm of a ride you're really on from ringing (a ride refused here still starts by hand).
enum RideGuards {
    static let arriveM = 450.0                      // TripManager's arrival radius
    static let startMargin = 150.0                  // …and this much more (or the fix's accuracy, when more)
    static let movingWindow: TimeInterval = 30      // going: your fixes of the last 30 s…
    static let movingSpan: TimeInterval = 20        // …spanning at least 20 s…
    static let movingMetres = 100.0                 // …the first and the newest this far apart (walking about a stop: ~40 m)
    static let awayFromChange = arriveM + startMargin   // and this far from the stop you got off at (past its arrival radius)
    static let pickOffRoadBus = 300.0, pickOffRoadTrain = 700.0
    static let pickLooksApart: TimeInterval = 20
    static let planUnknownFor: TimeInterval = 60    // a hold from the plan: its road not to be had this long, it gives way

    /// A ride started without you whose (first) stop is where you are already: it would ring and say "You're at …" at
    /// once. `d`: metres from your fix to that stop; nil or not a number: nothing to go by (not refused).
    static func startsAtItsStop(targetMetres d: Double?, accuracy: Double) -> Bool {
        guard let d, d.isFinite, d >= 0 else { return false }
        let acc = accuracy.isFinite && accuracy > 0 ? accuracy : 0
        return d <= arriveM + max(startMargin, acc)
    }

    enum Wake: Equatable { case sleep, awakeSilently }

    /// A leg that starts inside its wake distance: no alarm on its first fix, whenever that fix comes; the announcement
    /// comes at the stop. Further: asleep, and it rings at the wake distance.
    static func wakeAtStart(targetMetres d: Double?, wakeMetres: Double) -> Wake {
        guard let d, d.isFinite, d >= 0 else { return .sleep }
        return d <= wakeMetres ? .awakeSilently : .sleep
    }

    /// How far you went in the last 30 s: from the first to the newest of your fixes then (a known accuracy under
    /// 150 m), once they span 20 s. Nil: too few fixes to tell.
    static func movedMetres(_ fixes: [Fix], now: Date) -> Double? {
        let w = fixes.filter { now.timeIntervalSince($0.t) <= movingWindow && $0.t <= now.addingTimeInterval(1)
                                 && $0.accuracy.isFinite && $0.accuracy >= 0 && $0.accuracy < 150 }
                     .sorted { $0.t < $1.t }
        guard let a = w.first, let b = w.last, b.t.timeIntervalSince(a.t) >= movingSpan else { return nil }
        return Geo.metres(a.p, b.p)
    }

    /// Going now: 100 m or more in the last 30 s. (A bus ride in that ended a minute ago doesn't count, nor does
    /// walking about among the buses at a bus station.)
    static func movingNow(_ fixes: [Fix], now: Date) -> Bool {
        (movedMetres(fixes, now: now) ?? 0) >= movingMetres
    }

    /// At a change: a vehicle may start the next leg once you're going and away from the stop you got off at (nil:
    /// not known, no hold).
    static func mayTakeAtChange(moving: Bool, fromChangeStop d: Double?) -> Bool {
        moving && (d ?? .infinity) > awayFromChange
    }

    /// The one you picked gives way to another that doesn't go where the leg goes only once you're clearly off its
    /// road: the newest two looks at least 20 s apart each further than 300 m (a train: 700 m) from it, and no look
    /// between them on it. (On a track two trains share, the Intercity to Breda and the one to Den Bosch out of
    /// Eindhoven, it holds until their roads part.) A look whose road couldn't be had (nil) says nothing: the pick
    /// holds only on a leg, where the alarm for its stop is armed (`onOtherVehicle`). `fromPlan`: a hold the change made
    /// from the planned one's road (`atChange`), not a pick of yours: it also gives way once the newest looks over a
    /// minute couldn't have its road.
    static func pickRuledOut(_ looks: [(at: Date, metres: Double?)], isTrain: Bool, fromPlan: Bool = false) -> Bool {
        let limit = isTrain ? pickOffRoadTrain : pickOffRoadBus
        let sorted = looks.sorted { $0.at < $1.at }
        if fromPlan {
            let failed = Array(sorted.reversed().prefix { l in l.metres.map { !$0.isFinite } ?? true }.reversed())
            if let a = failed.first, let b = failed.last, b.at.timeIntervalSince(a.at) >= planUnknownFor { return true }
        }
        let known = sorted.compactMap { l in l.metres.flatMap { $0.isFinite ? (at: l.at, m: $0) : nil } }
        guard let last = known.last, last.m > limit,
              let prev = known.last(where: { last.at.timeIntervalSince($0.at) >= pickLooksApart }) else { return false }
        return prev.m > limit && !known.contains { $0.at >= prev.at && $0.m <= limit }
    }

    enum OtherVehicle: Equatable { case replan, keepPick, startNextLeg }

    /// Another vehicle, seen twice, that doesn't go where the leg goes: plan the rest again from it, or keep the one
    /// you picked. Only a pick of yours holds ("I'm on it" for the leg, or one picked in the list), not a ride the trip
    /// was only planned with; and it holds on a leg, where the alarm for its stop is armed, while you're on its road.
    /// At a change nothing is armed yet: a pick held there starts the next leg (on the picked one's road) instead, so
    /// the trip never waits at the change without an alarm.
    static func onOtherVehicle(atChange: Bool, picked: Bool, ruledOut: Bool) -> OtherVehicle {
        guard picked, !ruledOut else { return .replan }
        return atChange ? .startNextLeg : .keepPick
    }

    enum AtChange: Equatable { case startNextLeg, replan }

    /// At a change, going and away from the stop, with another vehicle that doesn't go where the next leg goes, or with
    /// none at all: on the road of the ride the next leg was planned with (`plannedRoadMetres` from it, 700 m for a
    /// train, 300 m for a bus), that's its line whatever the matcher sees (the next Intercity to Breda on the track the
    /// Den Bosch one shares, the planned one late or missed): start the next leg, its alarm armed, holding on that road.
    /// Its road not known, or off it: plan again from what it sees, as before.
    static func atChange(plannedRoadMetres d: Double?, isTrain: Bool) -> AtChange {
        guard let d, d.isFinite, d >= 0 else { return .replan }
        return d <= (isTrain ? pickOffRoadTrain : pickOffRoadBus) ? .startNextLeg : .replan
    }

    /// At a change on one of your own routes (Veghel–Eindhoven–Breda by the big button: nothing planned for the next
    /// leg), the ride whose road `atChange` goes by: of the next leg's departures (`departures`, as listed for it), the
    /// newest one that has left by now (a minute's grace) and not before you got there (2 minutes' grace: a late one
    /// listed by its live time); none has yet: the first after you got there. Nil: none listed.
    static func roadReference(_ departures: [Date], arrived: Date, now: Date) -> Int? {
        let after = departures.indices.filter { departures[$0] >= arrived.addingTimeInterval(-120) }
        let left = after.filter { departures[$0] <= now.addingTimeInterval(60) }
        if let i = left.max(by: { departures[$0] < departures[$1] }) { return i }
        return after.min(by: { departures[$0] < departures[$1] })
    }

    /// 0.42.3: going away from this leg's stop on the ride the next leg was planned with (`plannedNext`, among the
    /// vehicles on your road, `found`): you got off and onto it without this leg ending (a short hop to the station,
    /// its stop never reached by GPS). That's the next leg, started as at a change, its alarm armed and nothing to
    /// pick: not "wrong way" and a new plan from it. The id found, or nil.
    static func plannedNextAmong(_ found: [String], plannedNext: String?) -> String? {
        guard let p = plannedNext, !p.isEmpty else { return nil }
        return found.first { $0 == p }
    }
}
