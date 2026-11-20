import Foundation

/// 0.39: a quiet "Get ready" one stop before yours. Once the bus or train is at the stop before yours (by its live
/// times, or the ones saved when the trip started), and only while the alarm hasn't rung yet: a notification without
/// sound (`ready-…`, off the lock screen after 10 minutes, `NoticeExpiry`), a tap on the phone when it's open, and "Get
/// ready" on the lock screen. Not when the alarm would ring within a minute of it anyway, nor when your stop is still
/// further off than `farthest`. The alarm still rings as it always did. Plain values, so it can be tested.
enum GetReady {
    static let idPrefix = "ready-"
    /// The stop before yours counts as reached this long before its time.
    static let early: TimeInterval = 30
    /// Your stop further off than this: too soon to get ready (a long gap between two stations).
    static let farthest: TimeInterval = 15 * 60
    /// Within this of when the alarm rings anyway, it says nothing more.
    static let alarmGap: TimeInterval = 60

    /// The stop before yours in a leg's stops (from where you got on up to yours): nil when there's none between.
    static func before(count: Int) -> Int? { count >= 3 ? count - 2 : nil }

    /// Tell you now? Not told yet this leg, the alarm not rung yet, the stop before yours reached (`beforeYours` within
    /// `early` of now, or past), your stop (`yours`) further than `alarmWithin` + `alarmGap` seconds and within `farthest`.
    /// `alarmWithin`: how long before your stop the time rule rings (0 by distance).
    static func due(beforeYours: Date?, yours: Date?, now: Date, alarmWithin: TimeInterval, asleep: Bool, told: Bool) -> Bool {
        guard asleep, !told, let b = beforeYours, let y = yours, y > b else { return false }
        guard now >= b.addingTimeInterval(-early) else { return false }
        let left = y.timeIntervalSince(now)
        return left > max(0, alarmWithin) + alarmGap && left <= farthest
    }

    /// "Get ready: Breda is next" / "Your stop is the next one, about 6 min. The alarm still rings before it."
    static func words(stop: String, secondsLeft: Double?) -> (title: String, body: String) {
        let s = WristNotice.stop(stop)
        let about: String = secondsLeft.map { ", about \(WristNotice.minutes($0))" } ?? ""
        return ("Get ready: \(s) is next", "Your stop is the next one\(about). The alarm still rings before it.")
    }

    /// The notification's identifier: `ready-<trip start>-<leg>`.
    static func id(tripStart: Date?, leg: Int) -> String {
        "\(idPrefix)\(Int(tripStart?.timeIntervalSince1970 ?? 0))-\(leg)"
    }
}
