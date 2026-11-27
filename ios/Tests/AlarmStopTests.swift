import XCTest

/// 0.42.1: stopping an alarm without unlocking: what each notification button stops, the same whether the trip engine
/// answers it or the app was started in the background just for it.
final class AlarmStopTests: XCTestCase {
    let open = "com.apple.UNNotificationDefaultActionIdentifier"
    let dismiss = "com.apple.UNNotificationDismissActionIdentifier"

    func test_actionsAreToldApart() {
        XCTAssertEqual(AlarmStop.action(WristNotice.stopAction, open: open, dismiss: dismiss), .stop)
        XCTAssertEqual(AlarmStop.action(open, open: open, dismiss: dismiss), .open)
        XCTAssertEqual(AlarmStop.action(dismiss, open: open, dismiss: dismiss), .dismiss)
        XCTAssertEqual(AlarmStop.action("STILL_YES", open: open, dismiss: dismiss), .other)
    }

    func test_stopOnTheRingingAlarmStopsTheTrip() {
        for id in [WristNotice.alarmId, WristNotice.againId] {
            for a: AlarmStop.Action in [.stop, .open, .dismiss] {
                let p = AlarmStop.plan(id: id, action: a)
                XCTAssertTrue(p.stopTrip, "\(id) \(a)")
                XCTAssertTrue(p.wakeRepeats.isEmpty)
                XCTAssertFalse(p.stopWake)
            }
        }
    }

    func test_stopOnTheOtherTripNoticesStopsTooButNotATapOrSwipe() {
        for id in ["backup", "heads-up-true", "arrived-1800000000"] {
            XCTAssertTrue(AlarmStop.plan(id: id, action: .stop).stopTrip, id)
            XCTAssertFalse(AlarmStop.plan(id: id, action: .open).stopTrip, id)
            XCTAssertFalse(AlarmStop.plan(id: id, action: .dismiss).stopTrip, id)
        }
    }

    func test_otherAnswersAreForTheTripEngine() {
        XCTAssertTrue(AlarmStop.plan(id: "still-on", action: .other).none)
        XCTAssertTrue(AlarmStop.plan(id: "friends-chat-abc", action: .open).none)
        XCTAssertFalse(AlarmStop.plan(id: WristNotice.alarmId, action: .open).none)
    }

    func test_schoolWakeUpTakesTheDaysRepeatsAway() {
        let ids = ["wake-2026-11-27-0", "wake-2026-11-27-1", "wake-2026-11-27-2"]
        let stop = AlarmStop.plan(id: "wake-2026-11-27-1", action: .stop)
        XCTAssertEqual(stop.wakeRepeats, ids)
        XCTAssertTrue(stop.stopWake)
        XCTAssertFalse(stop.stopTrip)
        // swiped away or opened: the repeats go, nothing else to stop
        for a: AlarmStop.Action in [.open, .dismiss] {
            let p = AlarmStop.plan(id: "wake-2026-11-27-0", action: a)
            XCTAssertEqual(p.wakeRepeats, ids)
            XCTAssertFalse(p.stopWake)
            XCTAssertFalse(p.stopTrip)
        }
    }

    func test_wakeRepeatsOfTheTestAlarmAndOfOtherIds() {
        XCTAssertEqual(AlarmStop.wakeRepeats(of: "wake-test-0"), ["wake-test-0", "wake-test-1", "wake-test-2"])
        XCTAssertEqual(AlarmStop.wakeRepeats(of: "alarm"), [])
        XCTAssertEqual(AlarmStop.wakeRepeats(of: "wake-0"), [])
        XCTAssertEqual(AlarmStop.wakeRepeats(of: "wake-"), [])
    }

    func test_whatGoesWithoutTheTripEngine() {
        XCTAssertTrue(AlarmStop.tripDelivered.contains(WristNotice.alarmId))
        XCTAssertTrue(AlarmStop.tripDelivered.contains(WristNotice.againId))
        XCTAssertTrue(AlarmStop.tripDelivered.contains("backup"))
    }

    // MARK: (0.42.9) which ring gets the lock screen's ringing state

    func test_everyRingKindRingsOnTheLockScreenWithStop() {
        let rings: [RingShow.Kind] = [.alarm, .headphonesQuiet, .phoneInUse, .byTime, .reckoned, .backup, .again]
        for k in rings {
            XCTAssertTrue(RingShow.lockRinging(k), "\(k)")
            XCTAssertEqual(RingShow.category(k), WristNotice.alarmCategory, "\(k)")
            XCTAssertNotNil(RingShow.notificationId(k), "\(k)")
        }
        // its notification is the alarm's own: Stop alarm, opening it or swiping it away stops it
        for k in rings { XCTAssertTrue(AlarmStop.plan(id: RingShow.notificationId(k)!, action: .dismiss).stopTrip, "\(k)") }
        for k: RingShow.Kind in [.shortNotice, .getReady, .arrived] {
            XCTAssertFalse(RingShow.lockRinging(k), "\(k)")
            XCTAssertEqual(RingShow.category(k), WristNotice.tripCategory)
            XCTAssertNil(RingShow.notificationId(k))
        }
    }

    func test_phoneInUseAndNoHeadphonesStillRing() {
        XCTAssertEqual(RingShow.kind(inUse: true, quiet: true), .phoneInUse)
        XCTAssertEqual(RingShow.kind(inUse: false, quiet: true), .headphonesQuiet)
        XCTAssertEqual(RingShow.kind(inUse: false, quiet: false), .alarm)
        XCTAssertTrue(RingShow.lockRinging(RingShow.kind(inUse: true, quiet: true)))
        XCTAssertTrue(RingShow.lockRinging(RingShow.kind(inUse: false, quiet: true)), "from the first second, while it only vibrates")
    }

    /// Without headphones it never goes out loud by itself: only with "Out loud if I don't stop it" on.
    func test_noHeadphonesStaysVibrationOnly() {
        XCTAssertEqual(RingShow.sound(.headphonesQuiet, quiet: true, outLoudLater: false), .vibrate(loudAfter: false))
        XCTAssertEqual(RingShow.sound(.backup, quiet: true, outLoudLater: false), .vibrate(loudAfter: false))
        XCTAssertEqual(RingShow.sound(.headphonesQuiet, quiet: true, outLoudLater: true), .vibrate(loudAfter: true))
        XCTAssertEqual(RingShow.sound(.alarm, quiet: false, outLoudLater: false), .loop)
        XCTAssertEqual(RingShow.sound(.phoneInUse, quiet: true, outLoudLater: true), .chimeOnce)
        XCTAssertEqual(RingShow.sound(.arrived, quiet: false, outLoudLater: false), .none)
    }
}
