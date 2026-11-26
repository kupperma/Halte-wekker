import ActivityKit
import Foundation
import UserNotifications

/// (0.42.1) Answers the app's notifications from the moment it starts, so Stop alarm works without unlocking the phone
/// also when iOS starts the app in the background just for that button (the school wake-up's notifications at night, a
/// trip notification after iOS closed the app). Before, `TripManager` answered them itself, but it's only made with the
/// app's window, which a background start doesn't make: the button was lost and the repeats kept ringing until you
/// unlocked and opened the app. Now this answers from `HaltewekkerApp.init`, hands everything to `TripManager` as soon
/// as it's there, and stops the alarms itself until then (`AlarmStop`). The lock screen's Stop alarm (`StopAlarmIntent`)
/// comes here too.
final class AlarmResponder: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = AlarmResponder()

    private let lock = NSLock()
    private weak var tripRef: TripManager?
    /// Answers that came before the trip engine was there and are for it (Still on?, which train…).
    private var waiting: [UNNotificationResponse] = []

    private var trip: TripManager? {
        lock.lock(); defer { lock.unlock() }
        return tripRef
    }

    /// At launch, before it has finished (iOS hands a button's answer only to a delegate set by then).
    @MainActor
    func install() {
        UNUserNotificationCenter.current().delegate = self
        AlarmControl.stop = { AlarmResponder.shared.stopTripAlarm() }
    }

    /// The trip engine is up: it answers from now on, and gets what was waiting for it.
    @MainActor
    func attach(_ t: TripManager) {
        lock.lock()
        tripRef = t
        let w = waiting
        waiting = []
        lock.unlock()
        let center = UNUserNotificationCenter.current()
        for r in w { t.userNotificationCenter(center, didReceive: r, withCompletionHandler: {}) }
    }

    /// Stop alarm on the lock screen or in the Dynamic Island: exactly what Stop does in the app.
    @MainActor
    func stopTripAlarm() {
        if let t = trip { t.stopAlarm(); return }
        Self.stopWithoutTrip()
    }

    /// Nothing rings without the trip engine (it plays the sound): what's left of the alarm on the lock screen goes,
    /// and a Live Activity from before stops saying it rings.
    @MainActor
    static func stopWithoutTrip() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: AlarmStop.tripDelivered)
        for a in Activity<TripAttributes>.activities where a.content.state.ringing {
            var s: TripAttributes.ContentState = a.content.state
            s.ringing = false
            Task { await a.update(ActivityContent(state: s, staleDate: nil)) }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        if let t = trip {
            t.userNotificationCenter(center, didReceive: response, withCompletionHandler: done)
            return
        }
        let id: String = response.notification.request.identifier
        let action: AlarmStop.Action = AlarmStop.action(response.actionIdentifier, open: UNNotificationDefaultActionIdentifier,
                                                        dismiss: UNNotificationDismissActionIdentifier)
        let plan: AlarmStop.Plan = AlarmStop.plan(id: id, action: action)
        if plan.none {
            // for the trip engine: it gets it when it's there (a tap opens the app, which makes it right away)
            lock.lock(); waiting.append(response); lock.unlock()
            done()
            return
        }
        Task { @MainActor in
            Self.apply(plan, trip: nil)
            done()
        }
    }

    /// Does what the plan says. With the trip engine there, its own Stop (the same as in the app).
    @MainActor
    static func apply(_ plan: AlarmStop.Plan, trip: TripManager?) {
        if !plan.wakeRepeats.isEmpty {
            let c = UNUserNotificationCenter.current()
            c.removePendingNotificationRequests(withIdentifiers: plan.wakeRepeats)
            c.removeDeliveredNotifications(withIdentifiers: plan.wakeRepeats)
        }
        if plan.stopWake { WakeAlarm.stopRinging() }
        if plan.stopTrip {
            if let trip { trip.stopAlarm() } else { stopWithoutTrip() }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        if let t = trip {
            t.userNotificationCenter(center, willPresent: notification, withCompletionHandler: done)
            return
        }
        let id: String = notification.request.identifier
        let ringing: Bool = id == WristNotice.alarmId || id == WristNotice.againId || id.hasPrefix("platform-")
        done(ringing ? [] : [.banner, .list, .sound])
    }
}
