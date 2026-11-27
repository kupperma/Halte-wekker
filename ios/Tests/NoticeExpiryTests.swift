import XCTest

final class NoticeExpiryTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func test_alarmAndStillOnAndUnknownStay() {
        for id in ["alarm", "backup", "still-on", "something-new"] { XCTAssertNil(NoticeExpiry.minutes(forId: id), id) }
        let due = NoticeExpiry.due([("alarm", t0), ("still-on", t0), ("x", t0)], now: t0.addingTimeInterval(86_400))
        XCTAssertEqual(due, [])
    }

    func test_longestPrefixWins() {
        XCTAssertEqual(NoticeExpiry.minutes(forId: "goboard-1800000000"), 10)
        XCTAssertEqual(NoticeExpiry.minutes(forId: "go-1800000000-2"), 15)
        XCTAssertEqual(NoticeExpiry.minutes(forId: "goboard-demo"), 10)
    }

    func test_eachKindHasItsTime() {
        XCTAssertEqual(NoticeExpiry.minutes(forId: "delay-ic3512-5"), 20)
        XCTAssertEqual(NoticeExpiry.minutes(forId: "platform-6F1A"), 20)
        XCTAssertEqual(NoticeExpiry.minutes(forId: "arrived-1800000000"), 10)
        XCTAssertEqual(NoticeExpiry.minutes(forId: "autostart"), 10)
        XCTAssertEqual(NoticeExpiry.minutes(forId: "arrive-leave"), 15)
        XCTAssertEqual(NoticeExpiry.minutes(forId: "wake-2026-11-18-0"), 60)
        XCTAssertEqual(NoticeExpiry.minutes(forId: "linewatch-abc-1800000000"), 15)
        // 0.36
        XCTAssertEqual(NoticeExpiry.minutes(forId: "checkout-1800000000-1"), 30)
        XCTAssertEqual(NoticeExpiry.minutes(forId: "nsclaim-1800000000"), 2880)
        XCTAssertEqual(NoticeExpiry.minutes(forId: "works-2026-11-26-7001"), 900)
        XCTAssertEqual(NoticeExpiry.minutes(forId: "lasthome-1800000000"), 45)
        // 0.39
        XCTAssertEqual(NoticeExpiry.minutes(forId: "ready-1800000000-1"), 10)
    }

    func test_getReadyGoesAfterTenMinutes() {                           // (0.39)
        let id = GetReady.id(tripStart: t0, leg: 1)
        XCTAssertTrue(id.hasPrefix(GetReady.idPrefix))
        XCTAssertEqual(NoticeExpiry.due([(id, t0)], now: t0.addingTimeInterval(9 * 60)), [])
        XCTAssertEqual(NoticeExpiry.due([(id, t0)], now: t0.addingTimeInterval(10 * 60)), [id])
    }

    func test_onlyOldOnesAreDue() {
        let list: [(id: String, at: Date)] = [
            ("arrived-1", t0),                                  // 10 min: due at +10
            ("delay-x-4", t0),                                  // 20 min: not yet
            ("go-2-0", t0.addingTimeInterval(-20 * 60)),        // 15 min, arrived 20 min before: due
        ]
        XCTAssertEqual(NoticeExpiry.due(list, now: t0.addingTimeInterval(9 * 60)), ["go-2-0"])
        XCTAssertEqual(NoticeExpiry.due(list, now: t0.addingTimeInterval(10 * 60)), ["arrived-1", "go-2-0"])
        XCTAssertEqual(NoticeExpiry.due(list, now: t0.addingTimeInterval(20 * 60)), ["arrived-1", "delay-x-4", "go-2-0"])
    }

    /// (0.42.5) A message from someone with your live link stays an hour.
    func test_liveMessages() {
        XCTAssertEqual(NoticeExpiry.minutes(forId: "livemsg-3"), 60)
        XCTAssertEqual(NoticeExpiry.due([("livemsg-3", t0)], now: t0.addingTimeInterval(59 * 60)), [])
        XCTAssertEqual(NoticeExpiry.due([("livemsg-3", t0)], now: t0.addingTimeInterval(60 * 60)), ["livemsg-3"])
    }
}
