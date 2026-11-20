import Foundation

/// 0.37.1: the trip and wake-up notifications as they come on a paired Apple Watch. A real watch app can't be put on
/// the watch without a paid developer account, but iOS shows the iPhone's notifications on the Watch while the phone is
/// locked, with their buttons. So they're short and say the stop first (a glance at the wrist is enough), all
/// time sensitive, with a Stop alarm button that runs on the phone in the background (it doesn't open the app, so it
/// works from the Watch), one tap on the wrist again after 30 s while it still rings, and grouped per trip.
///
/// Plain values only: the notifications themselves are made in `TripManager` and `WakeAlarm`.
enum WristNotice {
    /// The Stop alarm button (no `.foreground`: it runs on the phone without opening the app, also from the Watch).
    static let stopAction = "STOP"
    static let stopTitle = "Stop alarm"
    /// The ringing alarm's category (its swipe-away is reported, and stops it).
    static let alarmCategory = "ALARM"
    /// Heads-up, arrival and backup: they don't ring for long by themselves, but Stop alarm silences the chime or the
    /// announcement, and stops an alarm ringing meanwhile.
    static let tripCategory = "TRIP"
    /// The school wake-up's notifications (when AlarmKit isn't used): Stop alarm takes the repeats away.
    static let wakeCategory = "WAKE"

    /// The ringing alarm, and its one repeat.
    static let alarmId = "alarm"
    static let againId = "alarm-again"
    /// The repeat comes this long after it started to ring.
    static let againAfter: TimeInterval = 30

    /// Longer stop names are cut, so the title fits the Watch's first lines.
    static let maxStop = 22

    struct Lines: Equatable, Sendable {
        let title: String
        let body: String
    }

    /// The stop as the title says it: trimmed, cut to `maxStop` with "…", "your stop" when there's none.
    static func stop(_ name: String?) -> String {
        let s = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "your stop" }
        guard s.count > maxStop else { return s }
        return String(s.prefix(maxStop - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// "2 min" from seconds still to go (rounded up, at least 1).
    static func minutes(_ secs: Double) -> String { "\(max(1, Int((secs / 60).rounded(.up)))) min" }

    /// The alarm (and the heads-up when you're on your phone): `approach` before the stop, else at it. `soon` is how
    /// soon or how far ("2 min", "800 m"). `again`: the repeat 30 s later.
    static func ring(approach: Bool, stop name: String?, soon: String, inUse: Bool = false, again: Bool = false) -> Lines {
        let s = stop(name)
        if approach {
            let title = "Get off at \(s) · \(soon)"
            if inUse { return Lines(title: title, body: "Get ready to get off.") }
            return Lines(title: title, body: again ? "Still ringing: wake up and get ready to get off." : "Wake up: get ready to get off.")
        }
        let title = "Get off now at \(s)"
        if inUse { return Lines(title: title, body: "This is your stop.") }
        return Lines(title: title, body: again ? "Still ringing: this is your stop." : "This is your stop.")
    }

    /// At the stop with the chime: "You’re at Breda", and what's next (or that the trip is done).
    static func arrived(stop name: String?, then: String?, finished: Bool) -> Lines {
        Lines(title: "You’re at \(stop(name))", body: then ?? (finished ? "Get off here: your trip is done." : "Get off here."))
    }

    /// The backup alarm (after the minutes you set, in case GPS dropped out).
    static func backup(stop name: String?) -> Lines {
        Lines(title: "Get off at \(stop(name)) soon", body: "Your backup alarm: your stop should be close.")
    }

    /// The school wake-up's notifications when AlarmKit isn't used: `i` is 0 for the first, then the repeats.
    static func wakeTitle(_ title: String, repeat i: Int) -> String { i == 0 ? "⏰ \(title)" : "⏰ \(title) (again)" }

    /// The one repeat goes now: that same alarm still rings, `againAfter` has passed since it rang, and it hasn't gone
    /// yet. (Never for the heads-up: nothing rings then.)
    static func againDue(rangAt: Date, now: Date, stillRinging: Bool, sent: Bool) -> Bool {
        stillRinging && !sent && now.timeIntervalSince(rangAt) >= againAfter
    }

    /// How soon it still is at the repeat: a time-based ring's seconds less the wait (nil: by distance, said anew).
    static func secsAtAgain(_ secs: Double?) -> Double? { secs.map { max(0, $0 - againAfter) } }

    /// One group per trip in Notification Centre and on the Watch: the trip's start, else just "trip".
    static func thread(tripStart: Date?) -> String { tripStart.map { "trip-\(Int($0.timeIntervalSince1970))" } ?? "trip" }

    /// The school wake-up's notifications group per day.
    static func wakeThread(day: String) -> String { "wake-\(day)" }

    enum Kind: Sendable { case alarm, again, headsUp, backup, arrived, schoolWake }

    /// Which of the app's notifications iOS puts on top of a summary (0…1): the ringing ones first.
    static func relevance(_ k: Kind) -> Double {
        switch k {
        case .alarm, .again, .schoolWake: return 1
        case .headsUp, .backup: return 0.9
        case .arrived: return 0.7
        }
    }
}
