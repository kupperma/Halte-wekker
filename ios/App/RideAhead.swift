import Foundation

/// The words and picks of the new ride, change and Fastest trip screens (0.20): plain, so they can be tested.
enum RideAhead {
    // MARK: the countdown to your stop

    struct Countdown: Equatable {
        let value: String       // "12", "1.4"
        let unit: String        // "min", "km"
        let spoken: String
    }

    /// The minutes to your stop while its time is known (and not more than two minutes past); else the distance; else
    /// nothing yet.
    static func countdown(eta: Date?, metres: Double?, now: Date) -> Countdown? {
        if let eta, eta > now.addingTimeInterval(-120) {
            let m = max(0, Int((eta.timeIntervalSince(now) / 60).rounded()))
            return Countdown(value: "\(m)", unit: "min", spoken: "\(m) minute\(m == 1 ? "" : "s")")
        }
        guard let d = metres else { return nil }
        if d < 1000 {
            let v = max(0, Int((d / 10).rounded()) * 10)
            return Countdown(value: "\(v)", unit: "m", spoken: "\(v) metres")
        }
        let km = String(format: "%.1f", d / 1000)
        return Countdown(value: km, unit: "km", spoken: "\(km) kilometres")
    }

    // MARK: the stops ahead

    /// The stops still ahead (their time after `now`; a stop without a time counts as ahead), the first `limit` of them.
    static func ahead(times: [Date?], now: Date, limit: Int = 3) -> [Int] {
        Array(times.indices.filter { (times[$0] ?? .distantFuture) > now }.prefix(max(0, limit)))
    }

    // MARK: the change ahead

    struct Change: Equatable {
        let minutes: Int        // between arriving and the next one leaving (negative: it has gone by then)
        let tight: Bool         // under the room it needs (after a slow bus: more)
        let text: String
    }

    /// The change ahead, from when you're at your stop and when the next one leaves: "7 min to change at Den Bosch,
    /// 3 min walk"; tight under the room it needs after this ride (a slow bus's speed rank wants more:
    /// `ChangeRoom.changeNote`): "· slow bus, needs 6"; gone: "Leaves before you’re there by its times".
    static func change(arrive: Date, leaves: Date, walk: Int, isTrain: Bool, grade: String?, at stop: String) -> Change {
        let m = Int((leaves.timeIntervalSince(arrive) / 60).rounded(.down))
        if m < 0 { return Change(minutes: m, tight: true, text: "It leaves \(stop) before you’re there, by its times") }
        let note = ChangeRoom.changeNote(minutes: m, walk: max(0, walk), isTrain: isTrain, grade: grade)
        var t = "\(m) min to change at \(stop)"
        if walk > 0 { t += ", \(walk) min walk" }
        if let why = note.why { t += " · \(why)" }
        return Change(minutes: m, tight: note.red, text: t)
    }

    // MARK: Fastest trip's big number

    /// "Leave in" with the minutes until you have to set off; within the minute "Go now"; on board "You’re on it".
    static func leave(start: Date, aboard: Bool, now: Date) -> Countdown {
        if aboard { return Countdown(value: "On it", unit: "", spoken: "You’re on it") }
        let m = Int((start.timeIntervalSince(now) / 60).rounded(.down))
        if m < 1 { return Countdown(value: "Go now", unit: "", spoken: "Leave now") }
        if m >= 60 {
            let h = m / 60, r = m % 60
            return Countdown(value: "\(h) h \(String(format: "%02d", r))", unit: "until you leave",
                             spoken: "Leave in \(h) hour\(h == 1 ? "" : "s")\(r == 0 ? "" : " \(r) minute\(r == 1 ? "" : "s")")")
        }
        return Countdown(value: "\(m) min", unit: "until you leave", spoken: "Leave in \(m) minute\(m == 1 ? "" : "s")")
    }

    /// The other ways against the fastest: "fastest", "same time", "+6 min".
    static func later(than best: Date, _ end: Date, fastest: Bool) -> String {
        if fastest { return "fastest" }
        let m = max(0, Int((end.timeIntervalSince(best) / 60).rounded()))
        return m == 0 ? "same time" : "+\(m) min"
    }
}
