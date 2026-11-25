import Foundation

/// The walk to the stop, as long as it really takes you (0.40). "It says 10 minutes walk; realistically I'm there
/// sooner. I don't mind the head start." The walk shown is the one at your own walking speed (learned from your walks,
/// `Habits`, 0.34), with a small spare: "6 min walk · leave in 4 min (2 min spare)".
/// Safety: the time to leave (and the "Time to go" notification) gets later only once `Habits.walksNeeded` walks are
/// learned, and then only by what your walk saves minus `spare`: never later than the planner's walk would allow less
/// that spare. A slower walker keeps the planner's time (which already plans with their speed).
/// Plain values, so the rules are tested. Foundation only.
enum WalkPlan {
    /// Minutes of spare kept on top of your own walk.
    static let spare = 2
    /// Walks learned before your speed counts.
    static let walksNeeded = 5

    struct Shown: Equatable, Sendable {
        let walk: Int           // minutes: your walk (the planner's when nothing's learned)
        let spare: Int          // minutes of spare between your walk and the time to leave
        let later: Int          // minutes the time to leave moves on from the planner's (0 or more)
        let learned: Bool       // by your own speed
    }

    /// Your walk in minutes: `metres` (the walk's length when it's known, e.g. by the map's walking route; else the
    /// planner's `planned` minutes at the speed it planned with, `plannerSpeed`) at your `speed`, rounded up; never more
    /// than the planner's. Nil speed, or fewer than `walksNeeded` walks: the planner's.
    static func walk(planned: Int, metres: Double?, speed: Double?, walks: Int, plannerSpeed: Double) -> Int {
        guard planned > 0 else { return planned }
        guard walks >= walksNeeded, let v = speed, v.isFinite, v > 0 else { return planned }
        let base: Double = plannerSpeed.isFinite && plannerSpeed > 0 ? plannerSpeed : 1.2
        let m: Double = metres.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? Double(planned) * 60 * base
        let mine: Int = Int((m / v / 60).rounded(.up))
        return max(1, min(planned, mine))
    }

    /// Your walk, its spare and how much later you can leave than the planner says.
    static func shown(planned: Int, metres: Double?, speed: Double?, walks: Int, plannerSpeed: Double) -> Shown {
        let w: Int = walk(planned: planned, metres: metres, speed: speed, walks: walks, plannerSpeed: plannerSpeed)
        let learned: Bool = walks >= walksNeeded && speed != nil && planned > 0
        guard learned else { return Shown(walk: planned, spare: 0, later: 0, learned: false) }
        let saved: Int = max(0, planned - w)
        let later: Int = max(0, saved - spare)
        return Shown(walk: w, spare: saved - later, later: later, learned: true)
    }

    /// When to leave: the planner's time to leave (`leave`, its departure less the planner's walk) plus `later`.
    static func leave(_ leave: Date, _ s: Shown) -> Date { leave.addingTimeInterval(Double(s.later) * 60) }

    /// "6 min walk · leave in 4 min (2 min spare)", "6 min walk · leave by 08:04 (2 min spare)", "10 min walk".
    /// `leaveIn`: minutes until you leave (nil: say the time, `leaveBy`).
    static func words(_ s: Shown, leaveIn: Int?, leaveBy: String?) -> String {
        var t = "\(s.walk) min walk"
        if let m = leaveIn {
            t += m <= 0 ? " · leave now" : " · leave in \(m) min"
        } else if let b = leaveBy, !b.isEmpty {
            t += " · leave by \(b)"
        }
        if s.learned && s.spare > 0 && (leaveIn != nil || leaveBy != nil) { t += " (\(s.spare) min spare)" }
        return t
    }
}
