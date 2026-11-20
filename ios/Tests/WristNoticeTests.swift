import XCTest

/// 0.37.1: the trip and wake-up notifications as a paired Apple Watch shows them (the phone's, mirrored while it's
/// locked): short, the stop first, one repeat after 30 s while it still rings, grouped per trip.
final class WristNoticeTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func test_wakeUpSaysTheStopAndHowSoonFirst() {
        let t = WristNotice.ring(approach: true, stop: "Breda", soon: "2 min", inUse: false)
        XCTAssertEqual(t.title, "Get off at Breda · 2 min")
        XCTAssertEqual(t.body, "Wake up: get ready to get off.")
        XCTAssertEqual(WristNotice.ring(approach: true, stop: "Breda", soon: "800 m").title, "Get off at Breda · 800 m")
    }

    func test_atTheStop() {
        let t = WristNotice.ring(approach: false, stop: "Breda", soon: "0 m")
        XCTAssertEqual(t.title, "Get off now at Breda")
        XCTAssertEqual(t.body, "This is your stop.")
    }

    func test_headsUpWhenInUse() {
        XCTAssertEqual(WristNotice.ring(approach: true, stop: "Veghel, Busstation", soon: "3 min", inUse: true),
                       .init(title: "Get off at Veghel, Busstation · 3 min", body: "Get ready to get off."))
        XCTAssertEqual(WristNotice.ring(approach: false, stop: "Uden", soon: "", inUse: true).body, "This is your stop.")
    }

    func test_theRepeatSaysItStillRings() {
        XCTAssertEqual(WristNotice.ring(approach: true, stop: "Breda", soon: "2 min", again: true).body, "Still ringing: wake up and get ready to get off.")
        XCTAssertEqual(WristNotice.ring(approach: false, stop: "Breda", soon: "", again: true).body, "Still ringing: this is your stop.")
        XCTAssertEqual(WristNotice.ring(approach: true, stop: "Breda", soon: "2 min", again: true).title, "Get off at Breda · 2 min")
    }

    func test_longAndMissingStopNames() {
        XCTAssertEqual(WristNotice.stop(nil), "your stop")
        XCTAssertEqual(WristNotice.stop("   "), "your stop")
        XCTAssertEqual(WristNotice.stop(" Breda "), "Breda")
        XCTAssertEqual(WristNotice.stop("Amsterdam Centraal"), "Amsterdam Centraal")           // 18: fits
        let long = WristNotice.stop("'s-Hertogenbosch, Centraal Station perron")
        XCTAssertEqual(long.count, WristNotice.maxStop)
        XCTAssertTrue(long.hasSuffix("…"))
        XCTAssertTrue(long.hasPrefix("'s-Hertogenbosch"))
        XCTAssertEqual(WristNotice.ring(approach: true, stop: nil, soon: "1 min").title, "Get off at your stop · 1 min")
    }

    func test_minutesRoundUpAndAreAtLeastOne() {
        XCTAssertEqual(WristNotice.minutes(0), "1 min")
        XCTAssertEqual(WristNotice.minutes(61), "2 min")
        XCTAssertEqual(WristNotice.minutes(120), "2 min")
        XCTAssertEqual(WristNotice.minutes(-5), "1 min")
    }

    func test_arrivedAndBackup() {
        XCTAssertEqual(WristNotice.arrived(stop: "Breda", then: nil, finished: true),
                       .init(title: "You’re at Breda", body: "Get off here: your trip is done."))
        XCTAssertEqual(WristNotice.arrived(stop: "Breda", then: nil, finished: false).body, "Get off here.")
        XCTAssertEqual(WristNotice.arrived(stop: "Breda", then: "Change to bus 305 at 07:41", finished: false).body, "Change to bus 305 at 07:41")
        XCTAssertEqual(WristNotice.backup(stop: "Breda").title, "Get off at Breda soon")
    }

    /// The app's own banner sorts them by title: they stay "go" (and arriving stays "ok" by its userInfo).
    func test_titlesStillReadAsGo() {
        for t in [WristNotice.ring(approach: true, stop: "Breda", soon: "2 min"), WristNotice.ring(approach: false, stop: "Breda", soon: ""),
                  WristNotice.backup(stop: "Breda")] {
            XCTAssertTrue(t.title.lowercased().contains("get off"), t.title)
        }
    }

    func test_schoolWakeTitles() {
        XCTAssertEqual(WristNotice.wakeTitle("Time to get up", repeat: 0), "⏰ Time to get up")
        XCTAssertEqual(WristNotice.wakeTitle("Time to get up", repeat: 2), "⏰ Time to get up (again)")
    }

    // MARK: the one repeat

    func test_repeatAfterThirtySecondsWhileStillRinging() {
        XCTAssertEqual(WristNotice.againAfter, 30)
        XCTAssertFalse(WristNotice.againDue(rangAt: t0, now: t0.addingTimeInterval(29), stillRinging: true, sent: false))
        XCTAssertTrue(WristNotice.againDue(rangAt: t0, now: t0.addingTimeInterval(30), stillRinging: true, sent: false))
        XCTAssertTrue(WristNotice.againDue(rangAt: t0, now: t0.addingTimeInterval(31), stillRinging: true, sent: false))
    }

    func test_noRepeatOnceStoppedOrAlreadySent() {
        XCTAssertFalse(WristNotice.againDue(rangAt: t0, now: t0.addingTimeInterval(30), stillRinging: false, sent: false))
        XCTAssertFalse(WristNotice.againDue(rangAt: t0, now: t0.addingTimeInterval(30), stillRinging: true, sent: true))
        XCTAssertFalse(WristNotice.againDue(rangAt: t0, now: t0.addingTimeInterval(600), stillRinging: true, sent: true))
    }

    func test_howSoonAtTheRepeat() {
        XCTAssertEqual(WristNotice.secsAtAgain(150), 120)
        XCTAssertEqual(WristNotice.secsAtAgain(10), 0)
        XCTAssertNil(WristNotice.secsAtAgain(nil))
        XCTAssertEqual(WristNotice.minutes(WristNotice.secsAtAgain(150)!), "2 min")
    }

    /// The repeat isn't taken off by the lock-screen sweep (like the alarm itself), and isn't one of the expiring kinds.
    func test_repeatIsNotSweptAway() {
        XCTAssertNil(NoticeExpiry.minutes(forId: WristNotice.againId))
        XCTAssertNil(NoticeExpiry.minutes(forId: WristNotice.alarmId))
        XCTAssertNotEqual(WristNotice.againId, WristNotice.alarmId)
    }

    // MARK: grouping

    func test_groupedPerTrip() {
        XCTAssertEqual(WristNotice.thread(tripStart: t0), "trip-1800000000")
        XCTAssertEqual(WristNotice.thread(tripStart: nil), "trip")
        XCTAssertNotEqual(WristNotice.thread(tripStart: t0), WristNotice.thread(tripStart: t0.addingTimeInterval(3600)))
        XCTAssertEqual(WristNotice.wakeThread(day: "2026-11-20"), "wake-2026-11-20")
    }

    func test_ringingOnesOnTop() {
        XCTAssertEqual(WristNotice.relevance(.alarm), 1)
        XCTAssertEqual(WristNotice.relevance(.again), 1)
        XCTAssertGreaterThan(WristNotice.relevance(.headsUp), WristNotice.relevance(.arrived))
        for k in [WristNotice.Kind.alarm, .again, .headsUp, .backup, .arrived, .schoolWake] {
            let r = WristNotice.relevance(k)
            XCTAssertTrue(r >= 0 && r <= 1)
        }
    }

    func test_stopButtonIsTheOldStopPath() {
        XCTAssertEqual(WristNotice.stopAction, "STOP")
        XCTAssertEqual(WristNotice.stopTitle, "Stop alarm")
        XCTAssertEqual(WristNotice.alarmCategory, "ALARM")
        XCTAssertEqual(WristNotice.wakeCategory, "WAKE")
    }
}
