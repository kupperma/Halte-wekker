import XCTest

final class RideAheadTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ min: Double) -> Date { now.addingTimeInterval(min * 60) }

    func testCountdownMinutesWhileTheTimeIsKnown() {
        XCTAssertEqual(RideAhead.countdown(eta: at(12.4), metres: 9000, now: now)?.value, "12")
        XCTAssertEqual(RideAhead.countdown(eta: at(12.4), metres: 9000, now: now)?.unit, "min")
        XCTAssertEqual(RideAhead.countdown(eta: at(1), metres: nil, now: now)?.spoken, "1 minute")
        // just past its time: still 0 min, not the distance
        XCTAssertEqual(RideAhead.countdown(eta: at(-1), metres: 300, now: now)?.value, "0")
    }

    func testCountdownFallsBackToTheDistance() {
        XCTAssertEqual(RideAhead.countdown(eta: at(-5), metres: 1430, now: now), .init(value: "1.4", unit: "km", spoken: "1.4 kilometres"))
        XCTAssertEqual(RideAhead.countdown(eta: nil, metres: 456, now: now)?.value, "460")
        XCTAssertEqual(RideAhead.countdown(eta: nil, metres: 456, now: now)?.unit, "m")
        XCTAssertNil(RideAhead.countdown(eta: nil, metres: nil, now: now))
    }

    func testAheadSkipsPassedStops() {
        let f = [0.1, 0.3, 0.5, 0.7, 0.9]
        XCTAssertEqual(RideAhead.ahead(times: [at(-3), at(2), at(5), at(9), at(12)], fractions: f, now: now, progress: 0.2), [1, 2, 3])
        XCTAssertEqual(RideAhead.ahead(times: [at(-3), at(-1)], fractions: [0.2, 0.4], now: now, progress: 0.5), [])
        XCTAssertEqual(RideAhead.ahead(times: [at(1), at(2)], fractions: [0.2, 0.4], now: now, progress: 0, limit: 1), [0])
        XCTAssertEqual(RideAhead.ahead(times: [at(1)], fractions: [0.5], now: now, progress: 0, limit: -2), [])
    }

    func testUntimedStopsGoByWhereTheyAreAlongTheLeg() {
        // no times: the ones past how far along you are
        XCTAssertEqual(RideAhead.ahead(times: [nil, nil, nil], fractions: [0.2, 0.5, 0.8], now: now, progress: 0.4), [1, 2])
        XCTAssertEqual(RideAhead.ahead(times: [nil, nil], fractions: [0.2, 0.5], now: now, progress: 0.9), [])
        // mixed: a passed timed stop, an untimed one behind you, one ahead
        XCTAssertEqual(RideAhead.ahead(times: [at(-2), nil, nil, at(6)], fractions: [0.1, 0.3, 0.6, 0.8], now: now, progress: 0.45), [2, 3])
        // a fraction missing: counted as ahead (the end of the leg)
        XCTAssertEqual(RideAhead.ahead(times: [nil, nil], fractions: [0.1], now: now, progress: 0.5), [1])
    }

    func testChangeWithRoom() {
        let c = RideAhead.change(arrive: at(10), leaves: at(17.5), walk: 3, isTrain: false, grade: "A", at: "Den Bosch")
        XCTAssertEqual(c, .init(minutes: 7, tight: false, text: "7 min to change at Den Bosch, 3 min walk"))
    }

    func testChangeAfterASlowBusIsTightAndSaysWhy() {
        // 5 min of room is fine after an A bus, not after a C one (it needs 6)
        let c = RideAhead.change(arrive: at(10), leaves: at(15), walk: 0, isTrain: false, grade: "C", at: "Den Bosch")
        XCTAssertTrue(c.tight)
        XCTAssertEqual(c.text, "5 min to change at Den Bosch · slow bus, needs 6")
        XCTAssertFalse(RideAhead.change(arrive: at(10), leaves: at(15), walk: 0, isTrain: false, grade: "A", at: "X").tight)
        // a train before it: the usual 2 minutes
        XCTAssertFalse(RideAhead.change(arrive: at(10), leaves: at(13), walk: 0, isTrain: true, grade: "C", at: "X").tight)
    }

    func testChangeUnderTheUsualRoomIsTightWithoutAReason() {
        let c = RideAhead.change(arrive: at(10), leaves: at(11), walk: 0, isTrain: true, grade: nil, at: "Breda")
        XCTAssertEqual(c, .init(minutes: 1, tight: true, text: "1 min to change at Breda"))
    }

    func testChangeThatHasGone() {
        let c = RideAhead.change(arrive: at(10), leaves: at(8), walk: 0, isTrain: false, grade: nil, at: "Breda")
        XCTAssertTrue(c.tight)
        XCTAssertLessThan(c.minutes, 0)
        XCTAssertEqual(c.text, "It leaves Breda before you’re there, by its times")
    }

    func testLeave() {
        XCTAssertEqual(RideAhead.leave(start: at(7.9), aboard: false, now: now).value, "7 min")
        XCTAssertEqual(RideAhead.leave(start: at(7.9), aboard: false, now: now).spoken, "Leave in 7 minutes")
        XCTAssertEqual(RideAhead.leave(start: at(0.5), aboard: false, now: now).value, "Go now")
        XCTAssertEqual(RideAhead.leave(start: at(-3), aboard: false, now: now).spoken, "Leave now")
        XCTAssertEqual(RideAhead.leave(start: at(65), aboard: false, now: now).value, "1 h 05")
        XCTAssertEqual(RideAhead.leave(start: at(60), aboard: false, now: now).spoken, "Leave in 1 hour")
        XCTAssertEqual(RideAhead.leave(start: at(20), aboard: true, now: now).value, "On it")
    }

    func testLater() {
        XCTAssertEqual(RideAhead.later(than: at(30), at(30), fastest: true), "fastest")
        XCTAssertEqual(RideAhead.later(than: at(30), at(30.2), fastest: false), "same time")
        XCTAssertEqual(RideAhead.later(than: at(30), at(36), fastest: false), "+6 min")
    }
}
