import XCTest

/// 0.39: the quiet "Get ready" one stop before yours.
final class GetReadyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ m: Double) -> Date { t0.addingTimeInterval(m * 60) }

    func test_theStopBeforeYours() {
        XCTAssertNil(GetReady.before(count: 2), "where you got on is the one before: nothing to say")
        XCTAssertEqual(GetReady.before(count: 3), 1)
        XCTAssertEqual(GetReady.before(count: 8), 6)
    }

    func test_dueAtTheStopBeforeYours() {
        // the stop before at +0, yours at +6, the alarm 3 min before
        XCTAssertFalse(GetReady.due(beforeYours: at(0), yours: at(6), now: at(-1), alarmWithin: 180, asleep: true, told: false))
        XCTAssertTrue(GetReady.due(beforeYours: at(0), yours: at(6), now: at(-0.4), alarmWithin: 180, asleep: true, told: false),
                      "30 s before it gets there")
        XCTAssertTrue(GetReady.due(beforeYours: at(0), yours: at(6), now: at(1), alarmWithin: 180, asleep: true, told: false))
    }

    func test_notWhenTheAlarmIsAboutToRingAnyway() {
        // yours 3.5 min off, the alarm at 3: within a minute of it
        XCTAssertFalse(GetReady.due(beforeYours: at(0), yours: at(3.5), now: at(0), alarmWithin: 180, asleep: true, told: false))
        // by distance (no time to go by): over a minute is enough
        XCTAssertTrue(GetReady.due(beforeYours: at(0), yours: at(3.5), now: at(0), alarmWithin: 0, asleep: true, told: false))
    }

    func test_notTooSoonNotTwiceNotAwake() {
        XCTAssertFalse(GetReady.due(beforeYours: at(0), yours: at(20), now: at(0), alarmWithin: 180, asleep: true, told: false),
                       "your stop 20 min off: too soon")
        XCTAssertFalse(GetReady.due(beforeYours: at(0), yours: at(6), now: at(0), alarmWithin: 180, asleep: true, told: true))
        XCTAssertFalse(GetReady.due(beforeYours: at(0), yours: at(6), now: at(0), alarmWithin: 180, asleep: false, told: false))
        XCTAssertFalse(GetReady.due(beforeYours: nil, yours: at(6), now: at(0), alarmWithin: 180, asleep: true, told: false))
        XCTAssertFalse(GetReady.due(beforeYours: at(6), yours: at(6), now: at(6), alarmWithin: 0, asleep: true, told: false))
    }

    func test_words() {
        let w = GetReady.words(stop: "Breda", secondsLeft: 330)
        XCTAssertEqual(w.title, "Get ready: Breda is next")
        XCTAssertEqual(w.body, "Your stop is the next one, about 6 min. The alarm still rings before it.")
        XCTAssertEqual(GetReady.words(stop: "", secondsLeft: nil).title, "Get ready: your stop is next")
        XCTAssertEqual(GetReady.id(tripStart: t0, leg: 1), "ready-1800000000-1")
    }
}
