import XCTest

/// 0.33: what the phone's motion coprocessor says (Motion & Fitness), turned into the few decisions it may change:
/// looking for your bus or train sooner, a cheaper GPS while you wait, and fewer false "on the move".
final class MotionRulesTests: XCTestCase {
    private let t0 = Fx.t0

    private func s(_ dt: Double, _ k: MotionKind, _ c: MotionConfidence = .high) -> MotionSample {
        MotionSample(t: t0 + dt, kind: k, confidence: c)
    }

    private func now(_ samples: [MotionSample], at dt: Double, live: Bool = true) -> MotionNow? {
        MotionRules.now(samples, at: t0 + dt, live: live)
    }

    // MARK: what it says now

    func test_nowIsTheLatestAndSinceWhen() {
        let m = now([s(0, .walking), s(60, .automotive, .medium), s(90, .automotive, .high)], at: 120)
        XCTAssertEqual(m?.kind, .automotive)
        XCTAssertEqual(m?.confidence, .high)
        XCTAssertEqual(m?.since, t0 + 60)
        XCTAssertNil(now([], at: 0))
    }

    func test_aLowConfidenceBlipDoesntBreakARun() {
        // in a bus at a stop: a moment of "walking, low" between automotive
        let m = now([s(0, .automotive), s(100, .walking, .low), s(110, .automotive)], at: 300)
        XCTAssertEqual(m?.since, t0)
        XCTAssertTrue(MotionRules.steadyVehicle(m, now: t0 + 300))
        // a sure "walking" does break it
        let w = now([s(0, .automotive), s(100, .walking, .high), s(110, .automotive)], at: 300)
        XCTAssertEqual(w?.since, t0 + 110)
    }

    func test_staleWithoutLiveUpdates() {
        let x = [s(0, .automotive)]
        XCTAssertNotNil(now(x, at: 20 * 60, live: true), "live: it holds until the next change")
        XCTAssertNotNil(now(x, at: MotionRules.stale, live: false))
        XCTAssertNil(now(x, at: MotionRules.stale + 1, live: false), "a history answer from long ago says nothing")
    }

    func test_samplesInTheFutureArentNow() {
        let m = now([s(0, .walking), s(500, .automotive)], at: 100)
        XCTAssertEqual(m?.kind, .walking)
    }

    // MARK: the decisions

    func test_inVehicleNeedsMediumOrHigh() {
        XCTAssertTrue(MotionRules.inVehicle(now([s(0, .automotive, .medium)], at: 1)))
        XCTAssertTrue(MotionRules.inVehicle(now([s(0, .automotive, .high)], at: 1)))
        XCTAssertFalse(MotionRules.inVehicle(now([s(0, .automotive, .low)], at: 1)))
        XCTAssertFalse(MotionRules.inVehicle(now([s(0, .cycling)], at: 1)))
        XCTAssertFalse(MotionRules.inVehicle(nil))
    }

    func test_steadyVehicleAfterThreeMinutes() {
        let x = [s(0, .automotive)]
        XCTAssertFalse(MotionRules.steadyVehicle(now(x, at: 179), now: t0 + 179))
        XCTAssertTrue(MotionRules.steadyVehicle(now(x, at: 180), now: t0 + 180))
        XCTAssertFalse(MotionRules.steadyVehicle(now([s(0, .automotive, .low)], at: 600), now: t0 + 600))
    }

    func test_cyclingOrWalkingQuicklyIsntAVehicle() {
        let bike = now([s(0, .cycling, .medium)], at: 1)
        XCTAssertTrue(MotionRules.notAVehicle(bike, speed: 7))
        XCTAssertFalse(MotionRules.movingLikeVehicle(byFixes: true, motion: bike, speed: 7))
        let run = now([s(0, .running)], at: 1)
        XCTAssertFalse(MotionRules.movingLikeVehicle(byFixes: true, motion: run, speed: 5.5))
        // walking down a train at 140 km/h: you are on a vehicle
        let aisle = now([s(0, .walking)], at: 1)
        XCTAssertFalse(MotionRules.notAVehicle(aisle, speed: 38))
        XCTAssertTrue(MotionRules.movingLikeVehicle(byFixes: true, motion: aisle, speed: 38))
        // unsure: the fixes decide, as before
        XCTAssertTrue(MotionRules.movingLikeVehicle(byFixes: true, motion: now([s(0, .cycling, .low)], at: 1), speed: 7))
        XCTAssertTrue(MotionRules.movingLikeVehicle(byFixes: true, motion: nil, speed: 7))
        XCTAssertFalse(MotionRules.movingLikeVehicle(byFixes: false, motion: nil, speed: 7))
    }

    func test_automotiveIsMovingLikeAVehicleAtOnce() {
        let car = now([s(0, .automotive, .medium)], at: 1)
        XCTAssertTrue(MotionRules.movingLikeVehicle(byFixes: false, motion: car, speed: nil))
    }

    func test_lookPace() {
        let still = now([s(0, .stationary)], at: 1)
        XCTAssertEqual(MotionRules.lookWait(base: 7, motion: still, movingByFixes: false), MotionRules.slowLook)
        XCTAssertEqual(MotionRules.lookWait(base: 7, motion: still, movingByFixes: true), 7, "the fixes say you move")
        XCTAssertEqual(MotionRules.lookWait(base: 7, motion: nil, movingByFixes: false), 7)
        XCTAssertEqual(MotionRules.lookWait(base: 7, motion: now([s(0, .automotive)], at: 1), movingByFixes: false), 7)
        XCTAssertEqual(MotionRules.lookWait(base: 30, motion: still, movingByFixes: false), 30, "never faster than it was")
    }

    func test_waitingOnTheLowGPS() {
        let still = now([s(0, .stationary, .medium)], at: 1)
        let walk = now([s(0, .walking, .high)], at: 1)
        XCTAssertTrue(MotionRules.waitLow(waiting: true, motion: still, movingByFixes: false, metresToStop: 20_000, wakeMetres: 5000))
        XCTAssertTrue(MotionRules.waitLow(waiting: true, motion: walk, movingByFixes: false, metresToStop: 20_000, wakeMetres: 5000))
        XCTAssertFalse(MotionRules.waitLow(waiting: false, motion: still, movingByFixes: false, metresToStop: 20_000, wakeMetres: 5000))
        XCTAssertFalse(MotionRules.waitLow(waiting: true, motion: now([s(0, .automotive)], at: 1), movingByFixes: false, metresToStop: 20_000, wakeMetres: 5000))
        XCTAssertFalse(MotionRules.waitLow(waiting: true, motion: now([s(0, .stationary, .low)], at: 1), movingByFixes: false, metresToStop: 20_000, wakeMetres: 5000))
        XCTAssertFalse(MotionRules.waitLow(waiting: true, motion: nil, movingByFixes: false, metresToStop: 20_000, wakeMetres: 5000))
        XCTAssertFalse(MotionRules.waitLow(waiting: true, motion: still, movingByFixes: true, metresToStop: 20_000, wakeMetres: 5000))
        // near the stop it's going to, or not knowing how far: the best
        XCTAssertFalse(MotionRules.waitLow(waiting: true, motion: still, movingByFixes: false, metresToStop: 6500, wakeMetres: 5000))
        XCTAssertFalse(MotionRules.waitLow(waiting: true, motion: still, movingByFixes: false, metresToStop: nil, wakeMetres: 5000))
        // (cycling to the stop isn't waiting there)
        XCTAssertFalse(MotionRules.waitLow(waiting: true, motion: now([s(0, .cycling)], at: 1), movingByFixes: false, metresToStop: 20_000, wakeMetres: 5000))
    }

    func test_firstLookAfterLeavingAStation() {
        XCTAssertEqual(MotionRules.firstRegionLook(now([s(0, .automotive)], at: 1)), MotionRules.regionLookSoon)
        XCTAssertEqual(MotionRules.firstRegionLook(now([s(0, .walking)], at: 1)), MotionRules.regionLookUsual)
        XCTAssertEqual(MotionRules.firstRegionLook(nil), MotionRules.regionLookUsual)
        XCTAssertLessThan(MotionRules.regionLookSoon, MotionRules.regionLookUsual)
    }

    func test_trimKeepsAQuarterOfAnHourAndTheOneBefore() {
        let x = [s(0, .walking), s(100, .automotive), s(2000, .stationary)]
        let kept = MotionRules.trim(x, now: t0 + 2000)
        XCTAssertEqual(kept.map(\.kind), [.automotive, .stationary], "the one that began the oldest run kept stays")
        XCTAssertEqual(MotionRules.trim([s(0, .walking)], now: t0 + 5000).count, 1, "the last one always stays")
    }
}
