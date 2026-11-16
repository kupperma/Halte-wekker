import Foundation

/// The room a change needs after a slow bus. A bus with a C speed rank (much slower than the fastest seen on that
/// stretch) has lost time already and tends to lose more: you missed your train twice after one. So a change after it
/// wants 6 minutes, after a B 4, after the rest the usual 2. Plain numbers, so it can be tested.
enum ChangeRoom {
    static let usual = 2.0

    /// Minutes of room a change needs after a bus of this speed rank.
    static func needed(afterGrade g: String?) -> Double {
        switch g {
        case "C": return 6
        case "B": return 4
        default: return usual
        }
    }

    /// The minutes more than usual.
    static func extra(afterGrade g: String?) -> Double { needed(afterGrade: g) - usual }

    /// A ride's speed rank, as `Ratings.grade` gives it but without remembering anything: `best` the fastest timetabled
    /// minutes seen on its stretch so far, `scheduled` its own timetabled minutes (a new fastest counts), `minutes` its
    /// own with delays. S as fast as it gets, A up to 3 min or 18% longer, B up to 30%, C more.
    static func speedGrade(minutes: Double, scheduled: Double, best: Double?, cancelled: Bool) -> String? {
        guard !cancelled, minutes > 0 else { return nil }
        var b = best
        if scheduled > 0, b == nil || scheduled < b! - 0.05 { b = (scheduled * 10).rounded() / 10 }
        let f = b ?? minutes, e = minutes - f, r = minutes / f
        if e <= 1 || r <= 1.06 { return "S" }
        if e <= 3 || r <= 1.18 { return "A" }
        if r <= 1.3 { return "B" }
        return "C"
    }

    /// How likely you'd miss a change (`Risk.miss`): `slack` the minutes between arriving and the next one leaving,
    /// less the walk; `typical` how late that line typically gets (minutes); `already` how late its live times have it
    /// now; `soon` it arrives within 10 minutes with live times; `learned` its delays on your own rides to that stop.
    /// `extra`: the room a slow bus before it needs on top (`extra(afterGrade:)`), taken off the slack.
    static func missChance(slack: Double, typical: Double, already: Double, soon: Bool, learned: [Double], extra: Double = 0) -> Double {
        if slack < 0 { return 0.95 }
        let room = slack - max(0, extra)
        var p = min(0.95, exp(-(room + 1) / typical))
        if learned.count >= 4 && !soon {
            let late = learned.filter { $0 > already + room + 0.5 }.count
            let seen = min(0.95, (Double(late) + 0.5) / (Double(learned.count) + 1))
            let w = Double(learned.count) / Double(learned.count + 4)
            p = w * seen + (1 - w) * p
        }
        return p
    }

    /// The buses that still make a train leaving at `dep`, the latest first: each one at the station (`end`, its walk
    /// included) the room it needs before the train leaves, by its own speed rank.
    static func inTime<T>(_ buses: [T], trainLeaves dep: Date, end: (T) -> Date, departure: (T) -> Date, grade: (T) -> String?) -> [T] {
        buses.filter { end($0) <= dep.addingTimeInterval(-needed(afterGrade: grade($0)) * 60) }
            .sorted { departure($0) > departure($1) }
    }

    /// On a C bus with a change ahead: tell you (once) when the room left drops under the 6 minutes it needs.
    static func warnOnRide(grade: String?, roomMinutes: Double) -> Bool {
        grade == "C" && roomMinutes.isFinite && roomMinutes < needed(afterGrade: "C")
    }
}
