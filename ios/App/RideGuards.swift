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
    static let awayFromChange = 300.0               // and this far from the stop you got off at
    static let pickOffRoadBus = 300.0, pickOffRoadTrain = 700.0
    static let pickLooksApart: TimeInterval = 20
    static let pickUnknownFor: TimeInterval = 60    // its road unknown this long (3 looks): it can't hold you

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

    /// The one you picked (or that the trip was planned with) gives way to another that doesn't go where the leg goes
    /// only once you're clearly off its road: the newest two looks at least 20 s apart each further than 300 m (a
    /// train: 700 m) from it, and no look between them on it. (On a track two trains share, the Intercity to Breda
    /// and the one to Den Bosch out of Eindhoven, it holds until their roads part.) A look without its road (nil) says
    /// nothing, unless the newest looks, 3 or more over a minute, all had none: then it can't be checked and gives way.
    static func pickRuledOut(_ looks: [(at: Date, metres: Double?)], isTrain: Bool) -> Bool {
        let limit = isTrain ? pickOffRoadTrain : pickOffRoadBus
        let sorted = looks.sorted { $0.at < $1.at }
        let unknown: ((at: Date, metres: Double?)) -> Bool = { l in l.metres.map { !$0.isFinite } ?? true }
        let run = Array(sorted.reversed().prefix(while: unknown).reversed())      // the newest looks without its road
        if run.count >= 3, let a = run.first, let b = run.last, b.at.timeIntervalSince(a.at) >= pickUnknownFor { return true }
        let known = sorted.compactMap { l in l.metres.flatMap { $0.isFinite ? (at: l.at, m: $0) : nil } }
        guard let last = known.last, last.m > limit,
              let prev = known.last(where: { last.at.timeIntervalSince($0.at) >= pickLooksApart }) else { return false }
        return prev.m > limit && !known.contains { $0.at >= prev.at && $0.m <= limit }
    }
}
