import Foundation

/// (0.42.1) Stopping an alarm without unlocking the phone: what a notification's button (Stop alarm, swiping it away,
/// tapping it) stops, and what the app takes away when it was started in the background just for that button and the
/// trip engine isn't up. Plain values only, so it can be tested; `AlarmResponder` and `TripManager` do it.
enum AlarmStop {
    /// The button pressed, as the rules need it.
    enum Action: Equatable, Sendable { case stop, open, dismiss, other }

    /// `identifier` is the response's action; `open` and `dismiss` are iOS's own ids for a tap and a swipe-away.
    static func action(_ identifier: String, open: String, dismiss: String) -> Action {
        if identifier == WristNotice.stopAction { return .stop }
        if identifier == open { return .open }
        if identifier == dismiss { return .dismiss }
        return .other
    }

    struct Plan: Equatable, Sendable {
        /// The trip's alarm: its sound, buzz, out-loud-later and repeat, and the leg goes on as after Stop in the app.
        var stopTrip = false
        /// The school wake-up's notifications of that day (the ones still to come and the ones on the lock screen).
        var wakeRepeats: [String] = []
        /// An AlarmKit wake-up still ringing.
        var stopWake = false

        /// Nothing about an alarm: the response is for the trip engine (Still on?, which train, a friend's message…).
        var none: Bool { !stopTrip && wakeRepeats.isEmpty && !stopWake }
    }

    /// The same rules as since 0.37.1, in one place: a school wake-up's notification takes that day's repeats away
    /// whatever you did with it (opened, swiped away, Stop alarm), and Stop alarm also stops an AlarmKit wake-up still
    /// ringing; Stop alarm on any trip notification stops the trip's alarm, and so does opening or swiping away the
    /// ringing alarm's own notification (or its repeat).
    static func plan(id: String, action: Action) -> Plan {
        var p = Plan()
        if id.hasPrefix("wake-") {
            p.wakeRepeats = wakeRepeats(of: id)
            p.stopWake = action == .stop
            return p
        }
        let isAlarm = id == WristNotice.alarmId || id == WristNotice.againId
        p.stopTrip = action == .stop || (isAlarm && (action == .open || action == .dismiss))
        return p
    }

    /// How many notifications the school wake-up's fallback sends a day ("wake-<day>-0…2").
    static let wakeCount = 3

    /// The ids of the day's wake-up notifications for one of them: "wake-2026-11-27-1" → "wake-2026-11-27-0…2".
    /// (Not a wake-up id: none.)
    static func wakeRepeats(of id: String) -> [String] {
        guard id.hasPrefix("wake-"), let cut = id.lastIndex(of: "-") else { return [] }
        let base = String(id[..<cut])
        guard base.count > "wake".count else { return [] }
        return (0..<wakeCount).map { "\(base)-\($0)" }
    }

    /// The trip alarm's notifications on the lock screen, taken away when it's stopped while the trip engine isn't up
    /// (iOS started the app just for the button). Not the backup alarm still to come: it stays, as after a Stop in the
    /// app while nothing rings.
    static let tripDelivered: [String] = [WristNotice.alarmId, WristNotice.againId, "backup", "heads-up-true", "heads-up-false"]
}
