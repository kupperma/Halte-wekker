import XCTest

/// 0.34: following the ride in tunnels and dead zones.
final class DeadReckonTests: XCTestCase {
    private let t = Date(timeIntervalSince1970: 1_800_000_000)

    func test_neededOnceTheGoodFixesStop() {
        XCTAssertFalse(DeadReckon.needed(lastGoodAt: t.addingTimeInterval(-10), now: t))
        XCTAssertTrue(DeadReckon.needed(lastGoodAt: t.addingTimeInterval(-16), now: t))
        XCTAssertFalse(DeadReckon.needed(lastGoodAt: nil, now: t), "never a good fix on this leg: nothing to go on from")
        XCTAssertFalse(DeadReckon.needed(lastGoodAt: t.addingTimeInterval(-3600), now: t), "gone too long: it stops following")
    }

    func test_goodFix() {
        XCTAssertTrue(DeadReckon.good(accuracy: 65))
        XCTAssertFalse(DeadReckon.good(accuracy: 120))
        XCTAssertFalse(DeadReckon.good(accuracy: -1))
    }

    func test_onAtItsPace_neverPastYourStop() {
        let e = DeadReckon.along(from: 1000, at: t, now: t.addingTimeInterval(30), pace: 20, gps: nil, times: nil, end: 5000)
        XCTAssertEqual(e.metres, 1600, accuracy: 0.1)
        XCTAssertEqual(e.source, .pace)
        XCTAssertEqual(DeadReckon.along(from: 1000, at: t, now: t.addingTimeInterval(30), pace: 20, gps: nil, times: nil, end: 1200).metres, 1200)
        // not for ever
        let long = DeadReckon.along(from: 0, at: t, now: t.addingTimeInterval(7200), pace: 10, gps: nil, times: nil, end: 1e9)
        XCTAssertEqual(long.metres, 10 * DeadReckon.maxFor, accuracy: 0.1)
        // no pace: it stays
        XCTAssertEqual(DeadReckon.along(from: 1000, at: t, now: t.addingTimeInterval(30), pace: nil, gps: nil, times: nil, end: 5000).metres, 1000)
    }

    func test_itsOwnGPSThenItsTimesComeFirst() {
        let gps = DeadReckon.along(from: 1000, at: t, now: t.addingTimeInterval(30), pace: 20, gps: 1450, times: 1700, end: 5000)
        XCTAssertEqual(gps.metres, 1450); XCTAssertEqual(gps.source, .gps)
        let times = DeadReckon.along(from: 1000, at: t, now: t.addingTimeInterval(30), pace: 20, gps: nil, times: 1700, end: 5000)
        XCTAssertEqual(times.metres, 1700); XCTAssertEqual(times.source, .times)
        // never back from where you were last seen
        XCTAssertEqual(DeadReckon.along(from: 1000, at: t, now: t.addingTimeInterval(30), pace: 20, gps: 800, times: nil, end: 5000).metres, 1000)
        // times that run away (more than top speed from where you were): not believed, its pace instead
        let wild = DeadReckon.along(from: 1000, at: t, now: t.addingTimeInterval(30), pace: 20, gps: nil, times: 9000, end: 20000, isTrain: true)
        XCTAssertEqual(wild.source, .pace)
    }

    func test_pace() {
        XCTAssertEqual(DeadReckon.pace(remaining: 3000, arrival: t.addingTimeInterval(150), now: t, lastSpeed: 8, isTrain: true) ?? 0, 20, accuracy: 0.01)
        // its arrival passed or too near to say: your last speed
        XCTAssertEqual(DeadReckon.pace(remaining: 3000, arrival: t.addingTimeInterval(-5), now: t, lastSpeed: 8, isTrain: true), 8)
        XCTAssertNil(DeadReckon.pace(remaining: 3000, arrival: nil, now: t, lastSpeed: nil, isTrain: false))
        // never faster than a train or bus goes
        XCTAssertEqual(DeadReckon.pace(remaining: 30000, arrival: t.addingTimeInterval(100), now: t, lastSpeed: nil, isTrain: false), WakeRule.busTop)
    }

    /// Safety: a dead-reckoned place alone never rings by distance; the time rule may.
    func test_ringsOnADeadReckonedPlaceOnlyByTime() {
        XCTAssertFalse(DeadReckon.mayRing(.distance, deadReckoned: true))
        XCTAssertTrue(DeadReckon.mayRing(.time(minutes: 3, source: .live, seconds: 170), deadReckoned: true))
        XCTAssertTrue(DeadReckon.mayRing(.distance, deadReckoned: false))
        XCTAssertFalse(DeadReckon.mayRing(nil, deadReckoned: true))
    }

    /// The time rule on a dead-reckoned place (a train in a tunnel, its live arrival fresh): rings by time; the same place
    /// inside the wake distance but long before by time: no ring.
    func test_wakeRuleOnTheEstimate() {
        let live = WakeRule.Input(by: .time, minutes: 3, isTrain: true, metres: 4000, routeMetres: 4200, wakeMetres: 5000,
                                  liveArrival: t.addingTimeInterval(150), liveAge: 30, speed: 25, fromStartMetres: 20000, now: t)
        XCTAssertTrue(DeadReckon.mayRing(DeadReckon.decide(live), deadReckoned: true))
        var far = live
        far.liveArrival = t.addingTimeInterval(600)
        far.speed = 5
        XCTAssertFalse(DeadReckon.mayRing(DeadReckon.decide(far), deadReckoned: true))
    }
}
