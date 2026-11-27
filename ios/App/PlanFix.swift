import Foundation

// 0.42.7: two field reports on the planner's ways. Plain rules (Foundation only), tested in `PlanFixTests`; Android has
// the same (`data/PlanFix.kt`, `PlanFixTest`).
// - "The app missed this one" (Breda 14:48: the 14:38 Intercity to Eindhoven, 10 min late, still at platform 3, never
//   offered): a way is kept by its live departure, never its timetable time; at a station the planner is asked from 15
//   minutes back, so a late train still to leave is in the answer.
// - "In the mornings ... it says it's a 10-minute walk. It's more like 3–4 minutes. ... it sometimes recommends taking
//   the bus near my home to then take the other bus": a walk is timed by its distance (the planner's foot route, or the
//   straight line when that route is odd), and a short hop is swapped for walking straight to the next ride's stop.

/// Ways kept and ordered by their live times.
enum LiveKeep {
    /// The planner is asked this much before now: at (or near) a station 15 minutes, so a late train whose timetable
    /// time has passed is in the answer; elsewhere 2 minutes (as before).
    static func askAt(now: Date, atStation: Bool) -> Date {
        now.addingTimeInterval(atStation ? -15 * 60 : -120)
    }

    /// How many ways to ask for: a few more when asking from further back (the ones gone take places in the answer).
    static func count(_ n: Int, atStation: Bool) -> Int { atStation ? n + 3 : n }

    /// One way as these rules see it.
    struct Way: Equatable {
        var departure: Date             // its first ride's live departure (the timetable's when there are no live times)
        var scheduled: Date             // …the timetable's
        var start: Date                 // when you'd leave your door (or where you are)
        var cancelled = false
    }

    /// Still to catch: its live departure no more than 30 s ago, not cancelled, and you'd have had to set off at most
    /// a minute and a half ago. The timetable time doesn't count.
    static func keep(_ w: Way, now: Date) -> Bool {
        !w.cancelled && w.departure >= now.addingTimeInterval(-30) && w.start >= now.addingTimeInterval(-90)
    }

    /// The order the next ones are shown in: by live departure.
    static func order(_ ws: [Way]) -> [Int] {
        ws.indices.sorted { ws[$0].departure < ws[$1].departure }
    }

    /// Every change still made (by the minutes from one ride's arrival to the next one's departure, at least the walk
    /// between them and one minute), after live times moved a ride.
    static func connects(arrivals: [Date], departures: [Date], walks: [Int]) -> Bool {
        guard arrivals.count == departures.count, departures.count == walks.count else { return false }
        for k in departures.indices.dropFirst() {
            let room: TimeInterval = departures[k].timeIntervalSince(arrivals[k - 1])
            if room < Double(max(1, walks[k])) * 60 { return false }
        }
        return true
    }

    /// "The 14:38 to Eindhoven Centraal is 10 min late — leaves 14:48 from platform 3"
    static func lateWords(line: String, to: String, scheduled: Date, departure: Date, platform: String?, clock: (Date) -> String) -> String {
        let m: Int = Int((departure.timeIntervalSince(scheduled) / 60).rounded())
        let at: String = platform.map { " from platform \($0)" } ?? ""
        return "The \(clock(scheduled)) \(line) to \(to) is \(m) min late — leaves \(clock(departure))\(at)"
    }
}

/// Walks timed by their distance, and a short hop swapped for the walk.
enum WalkFirst {
    static let plannerSpeed: Double = 1.2           // m/s: Transitous' own
    static let walksNeeded = 5
    /// The straight line times this is about the walk.
    static let streets: Double = 1.3
    /// A foot route more than this times the straight line is odd (a detour round a missing path): the straight line.
    static let odd: Double = 2.0

    /// Your speed: learned from at least 5 walks, else the planner's.
    static func speed(learned: Double?, walks: Int) -> Double {
        guard let v = learned, v > 0, walks >= walksNeeded else { return plannerSpeed }
        return v
    }

    /// The metres it walks: the planner's foot route, unless that's over twice the straight line (then the straight
    /// line × 1.3); without the planner's, the straight line × 1.3.
    static func metres(planner: Double?, straight: Double?) -> Double? {
        if let p = planner, p > 0 {
            if let s = straight, s > 0, p > s * odd { return s * streets }
            return p
        }
        return straight.map { $0 * streets }
    }

    /// Minutes for `metres` at `speed` (whole minutes up, at least one).
    static func minutes(metres: Double, speed: Double) -> Int {
        max(1, Int((metres / max(0.3, speed) / 60).rounded(.up)))
    }

    /// The walk the way counts on: by its distance at the speed it was planned with, never longer than the planner's
    /// own minutes (no slack added twice). Unknown distance: the planner's.
    static func walk(plannerMinutes: Int, metres m: Double?, speed: Double) -> Int {
        guard plannerMinutes > 0, let m else { return plannerMinutes }
        return min(plannerMinutes, minutes(metres: m, speed: speed))
    }

    /// A way that starts with a short ride (6 minutes or less) to the next ride's stop: the minutes to walk straight
    /// there instead, when you make that same next ride (a minute to spare) and the walk takes no more than 1.3 × what
    /// the hop takes (from leaving to the next ride). Nil: keep the hop.
    static func walkInstead(rideMinutes: Double, now: Date, start: Date, nextDeparture: Date, walkMetres: Double, speed: Double) -> Int? {
        guard rideMinutes <= 6, walkMetres > 0 else { return nil }
        let w: Int = minutes(metres: walkMetres, speed: speed)
        let leave: Date = max(now, start)
        guard now.addingTimeInterval(Double(w + 1) * 60) <= nextDeparture else { return nil }
        let hop: Double = nextDeparture.timeIntervalSince(leave) / 60
        guard Double(w) <= 1.3 * hop else { return nil }
        return w
    }

    /// "walk · planner 10 min (780 m) · yours 4 min (1.35 m/s) · used yours"
    static func logLine(plannerMinutes: Int, plannerMetres: Double?, yours: Int, speed: Double, usedYours: Bool) -> String {
        let m: String = plannerMetres.map { " (\(Int($0.rounded())) m)" } ?? ""
        let v: String = String(format: "%.2f", speed)
        return "walk · planner \(plannerMinutes) min\(m) · yours \(yours) min (\(v) m/s) · used \(usedYours ? "yours" : "the planner's")"
    }
}
