import Foundation

// 0.42.15: how sure a way is depends a lot on when you take it: a 19:00 bus is far less on time than a 13:00 one. So
// your own rides count only around the same time (weekdays and weekends apart), the estimate goes by the time of day
// first, and the sheet says which. Plain rules, tested in `NearbySlotTests` and docs/nearby-cards-vectors.json
// (Android: `travel/NearbySlot.kt`). Foundation only.

enum NearbySlot {
    /// One of your rides as the book keeps it: the minute of the day it was due at the stop (its timetable time),
    /// weekend or not, and how late it got there (minutes).
    struct Entry: Equatable, Sendable, Codable {
        let minute: Int
        let weekend: Bool
        let delay: Double
    }

    /// The windows tried (minutes either side): the narrowest that has `Nearby.ownNeeded` rides.
    static let windows: [Int] = [60, 90, 120]

    /// Minutes between two times of day, around midnight too.
    static func apart(_ a: Int, _ b: Int) -> Int {
        let d: Int = abs(((a - b) % 1440 + 1440) % 1440)
        return min(d, 1440 - d)
    }

    /// Your rides around `minute` (weekdays or weekends, as `weekend`), oldest first: within 60 minutes either side,
    /// else 90, else 120 (the widest, however few). And the window used.
    static func pick(_ entries: [Entry], minute: Int, weekend: Bool) -> (delays: [Double], window: Int) {
        let same: [Entry] = entries.filter { $0.weekend == weekend }
        for w in windows {
            let d: [Double] = same.filter { apart($0.minute, minute) <= w }.map(\.delay)
            if d.count >= Nearby.ownNeeded || w == windows[windows.count - 1] { return (d, w) }
        }
        return ([], windows[windows.count - 1])
    }

    /// The minute of the day of `d`.
    static func minute(_ d: Date, calendar: Calendar) -> Int {
        let c: DateComponents = calendar.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// What part of the day it is, and how late buses and trains typically get then (minutes: the chance of more
    /// than x minutes late is about e^(−x / it)). Rush hours (07–09, 16–19) worst, the evening after them still busy.
    struct Period: Equatable, Sendable {
        let name: String
        let bus: Double
        let train: Double
    }

    static func period(hour h: Double, weekend: Bool) -> Period {
        if weekend { return Period(name: "weekend", bus: 1.8, train: 0.8) }
        switch h {
        case 7..<9, 16..<19: return Period(name: "rush hour", bus: 3.5, train: 1.2)
        case 6.5..<7, 9..<9.5, 15..<16: return Period(name: "busy", bus: 2.6, train: 1.0)
        case 19..<20.5: return Period(name: "evening", bus: 2.4, train: 0.9)
        case 9.5..<15: return Period(name: "daytime", bus: 2.0, train: 0.8)
        default: return Period(name: "quiet", bus: 1.5, train: 0.7)
        }
    }

    /// The chance of more than `by` minutes late at a typical lateness `scale`.
    static func lateChance(scale: Double, by: Double) -> Double {
        let s: Double = scale.isFinite ? max(0.5, scale) : 2
        return exp(-by / s)
    }

    /// "around 19:00 on weekdays" (to the nearest half hour).
    static func slotWords(minute: Int, weekend: Bool) -> String {
        let m: Int = ((Int((Double(minute) / 30).rounded()) * 30) % 1440 + 1440) % 1440
        let t: String = String(format: "%02d:%02d", m / 60, m % 60)
        return "around \(t) on " + (weekend ? "weekends" : "weekdays")
    }

    /// Where a way's % comes from, for the sheet: your own rides then, else the estimate by the time of day (and live
    /// delays on that line), times the chance you make the changes.
    static func explain(_ s: Nearby.Sure, line: String, to stop: String, slot: String, period: String, changes: Int) -> String {
        let late: String = "less than \(Int(Nearby.lateBy)) min late"
        var out: String
        switch s.source {
        case .yours(let n):
            let ok: Int = s.onTime ?? 0
            out = "Based on your last \(n) ride\(n == 1 ? "" : "s") on the \(line) to \(stop) \(slot): \(ok) on time (\(late))."
            if let w = s.window, w > windows[0] {
                out += " Counted up to \(w) min either side: too few closer to that time."
            }
        case .live:
            out = "Estimated: fewer than \(Nearby.ownNeeded) of your own rides \(slot). From how late the \(line) runs then (\(period)), what the app saw of it, and its live delays today."
        case .estimate:
            out = "Estimated from the time of day only (\(slot), \(period)): no live times of the \(line) yet."
        }
        if changes > 0 && s.made < 0.995 {
            let pct: Int = Int((s.made * 100).rounded())
            out += " Times the chance you make your \(changes == 1 ? "change" : "\(changes) changes") (about \(pct)%)."
        }
        return out
    }
}
