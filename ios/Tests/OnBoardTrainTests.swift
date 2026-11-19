import XCTest

/// 0.26.2: on 2026-11-19 the trip to BUas was ended by hand at the change in Den Bosch, the user then rode an
/// Intercity, and the home didn't see it: no look for 14 minutes, a Sprinter by its times over the Intercity by its
/// own GPS, and "Now · time to leave · SPR 08:21 from Eindhoven".
final class OnBoardTrainTests: XCTestCase {
    private enum Kind { case gps, live, timetable }

    private func train(_ id: String, _ kind: Kind, _ r: Result<Double, Reject>, you: Double = 30) -> Judgement {
        var e = Evidence(fixes: 15, span: 28, crossTrack: 20, accuracy: 30, shaped: true, progress: you * 28, offset: 0,
                         drift: 0, yourSpeed: you, itsSpeed: 30, steady: true)
        e.gps = kind == .gps
        return Judgement(id: id, line: id, isTrain: true, realTime: kind != .timetable, evidence: e, result: r)
    }

    // MARK: a train by its own GPS first

    /// 08:06:14 · "SPR·9048 live 20 s | IC·6632 gps 22 s | IC·6558 gps 27 s → best SPR·9048": now the IC.
    func test_trainByItsGPSBeatsOneByItsTimes() {
        let look = [train("SPR9048", .live, .success(20)), train("IC6632", .gps, .success(22)), train("IC6558", .gps, .success(27)),
                    train("IC6923", .live, .failure(.tooFarFromTimes))]
        XCTAssertEqual(OnBoardRules.best(look, yourSpeed: 30), "IC6632")
        XCTAssertEqual(OnBoardRules.rank(look, planned: nil).map(\.id), ["IC6632", "IC6558", "SPR9048"])
    }

    /// Clearly better by its times (more than `trainGPSEdge`): it still wins. No train by GPS: as before.
    func test_muchBetterByTimesStillWins() {
        let look = [train("SPR", .live, .success(5)), train("IC", .gps, .success(40))]
        XCTAssertEqual(OnBoardRules.best(look, yourSpeed: 30), "SPR")
        let noGPS = [train("SPR", .live, .success(20)), train("IC", .live, .success(22))]
        XCTAssertEqual(OnBoardRules.rank(noGPS, planned: nil), VehicleMatch.rank(noGPS, planned: nil))
        // a failed GPS one gives no edge
        let failed = [train("SPR", .live, .success(20)), train("IC", .gps, .failure(.offItsPath))]
        XCTAssertEqual(OnBoardRules.rank(failed, planned: nil).map(\.cost), [20])
    }

    /// The planned one keeps its bonus (Fastest trip watching it): planned by its times 20 s, -45 + 30, before a GPS 22 s.
    func test_plannedKeepsItsBonus() {
        let look = [train("SPR", .live, .success(20)), train("IC", .gps, .success(22))]
        XCTAssertEqual(OnBoardRules.rank(look, planned: "SPR").first?.id, "SPR")
        XCTAssertEqual(OnBoardRules.rank(look, planned: "IC").first?.id, "IC")
    }

    /// Buses keep their order (their choice is `ChooseGPS`'s).
    func test_busesUnchanged() {
        var e = Evidence(fixes: 15, span: 28, crossTrack: 8, accuracy: 10, shaped: true, progress: 280, offset: 0,
                         drift: 0, yourSpeed: 10, itsSpeed: 10, steady: true)
        let live = Judgement(id: "a", line: "a", isTrain: false, realTime: true, evidence: e, result: .success(20))
        e.gps = true
        let gps = Judgement(id: "b", line: "b", isTrain: false, realTime: true, evidence: e, result: .success(22))
        XCTAssertEqual(OnBoardRules.rank([live, gps], planned: nil).map(\.id), ["a", "b"])
    }

    // MARK: moving like a train, by your track

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// Fixes every `every` s for `seconds`, `speed` m/s north, at `accuracy`, the GPS's own speed unknown (-1).
    private func track(speed: Double, seconds: Int, every: Int = 2, accuracy: Double = 65, end: Date? = nil) -> [Fix] {
        let last = end ?? t0
        return stride(from: seconds, through: 0, by: -every).map { s -> Fix in
            let back = Double(s) * speed
            return Fix(t: last.addingTimeInterval(-Double(s)), p: GeoPoint(lat: 51.69 - back / 110_540, lon: 5.29),
                       accuracy: accuracy, speed: -1, course: -1)
        }
    }

    /// On the Intercity: 30 m/s, the GPS's speed unknown, 65 m accuracy: moving.
    func test_trainByTrack() {
        XCTAssertTrue(OnBoardRules.movingByTrack(track(speed: 30, seconds: 30), now: t0))
        XCTAssertTrue(OnBoardRules.movingByTrack(track(speed: 30, seconds: 30), now: t0, speed: 8))
        // a bus at 9 m/s with good fixes
        XCTAssertTrue(OnBoardRules.movingByTrack(track(speed: 9, seconds: 40, accuracy: 10), now: t0))
    }

    func test_notMovingByTrack() {
        // walking at a change
        XCTAssertFalse(OnBoardRules.movingByTrack(track(speed: 1.4, seconds: 50, accuracy: 10), now: t0))
        // a bike at 6 m/s isn't Fastest trip's "faster than a bike"
        XCTAssertFalse(OnBoardRules.movingByTrack(track(speed: 6, seconds: 40, accuracy: 10), now: t0, speed: 8))
        // too short a span, too few fixes
        XCTAssertFalse(OnBoardRules.movingByTrack(track(speed: 30, seconds: 10), now: t0))
        XCTAssertFalse(OnBoardRules.movingByTrack(Array(track(speed: 30, seconds: 30, every: 15).prefix(2)), now: t0))
        // fixes from minutes ago
        XCTAssertFalse(OnBoardRules.movingByTrack(track(speed: 30, seconds: 30, end: t0.addingTimeInterval(-120)), now: t0))
        // poor fixes (cell towers)
        XCTAssertFalse(OnBoardRules.movingByTrack(track(speed: 30, seconds: 30, accuracy: 500), now: t0))
    }

    /// Standing in a big station, the GPS jumps once by 300 m: not a ride.
    func test_oneJumpIsNotARide() {
        var fixes = (0...14).map { k in
            Fix(t: t0.addingTimeInterval(Double(k * 2 - 30)), p: GeoPoint(lat: 51.69, lon: 5.29), accuracy: 40, speed: -1, course: -1)
        }
        fixes.append(Fix(t: t0, p: GeoPoint(lat: 51.69 + 300 / 110_540, lon: 5.29), accuracy: 40, speed: -1, course: -1))
        XCTAssertFalse(OnBoardRules.movingByTrack(fixes, now: t0))
    }

    // MARK: the home's looks while you move

    func test_lookDue() {
        XCTAssertTrue(OnBoardRules.lookDue(startedMoving: true, onBoard: true, movedMetres: 0, sinceLast: 1))
        // at train speed 300 m is 10 s: not before 20 s
        XCTAssertFalse(OnBoardRules.lookDue(startedMoving: false, onBoard: false, movedMetres: 320, sinceLast: 10))
        XCTAssertTrue(OnBoardRules.lookDue(startedMoving: false, onBoard: false, movedMetres: 640, sinceLast: 21))
        XCTAssertTrue(OnBoardRules.lookDue(startedMoving: false, onBoard: false, movedMetres: 320, sinceLast: nil))
        // a bus: 300 m in 30 s, as before
        XCTAssertTrue(OnBoardRules.lookDue(startedMoving: false, onBoard: false, movedMetres: 310, sinceLast: 30))
        XCTAssertFalse(OnBoardRules.lookDue(startedMoving: false, onBoard: false, movedMetres: 200, sinceLast: 50))
        // on board: on the minute (not here)
        XCTAssertFalse(OnBoardRules.lookDue(startedMoving: false, onBoard: true, movedMetres: 2000, sinceLast: 30))
        XCTAssertFalse(OnBoardRules.lookDue(startedMoving: false, onBoard: false, movedMetres: nil, sinceLast: 30))
    }

    // MARK: no "time to leave" from somewhere you aren't

    /// 08:20 · on the Intercity, "Now · time to leave · SPR 08:21 from Eindhoven": hidden while you move.
    func test_leaveCardHiddenWhileMoving() {
        XCTAssertTrue(OnBoardRules.leaveCardHidden(onBoard: false, vehicleMovedAgo: 5, firstStopMetres: 2400))
        XCTAssertTrue(OnBoardRules.leaveCardHidden(onBoard: false, vehicleMovedAgo: 5, firstStopMetres: nil))
        XCTAssertTrue(OnBoardRules.leaveCardHidden(onBoard: true, vehicleMovedAgo: nil, firstStopMetres: 50))
        // at its stop (off the train, on the platform): shown
        XCTAssertFalse(OnBoardRules.leaveCardHidden(onBoard: false, vehicleMovedAgo: 30, firstStopMetres: 150))
        // not moving lately: shown, as before
        XCTAssertFalse(OnBoardRules.leaveCardHidden(onBoard: false, vehicleMovedAgo: nil, firstStopMetres: 2400))
        XCTAssertFalse(OnBoardRules.leaveCardHidden(onBoard: false, vehicleMovedAgo: 200, firstStopMetres: 2400))
    }

    // MARK: going on with a trip you ended by hand

    func test_resumeLeg() {
        // 07:53 · ended at the change in Den Bosch after leg 1 of 3 (bus, train, bus): on with the train
        XCTAssertEqual(TripResume.leg(atChange: true, finished: false, index: 0, count: 3), 1)
        XCTAssertEqual(TripResume.leg(atChange: true, finished: false, index: 1, count: 3), 2)
        // on a leg before the last: that leg
        XCTAssertEqual(TripResume.leg(atChange: false, finished: false, index: 0, count: 3), 0)
        // on the last leg, or there: nothing to go on with
        XCTAssertNil(TripResume.leg(atChange: false, finished: false, index: 2, count: 3))
        XCTAssertNil(TripResume.leg(atChange: false, finished: true, index: 2, count: 3))
        XCTAssertNil(TripResume.leg(atChange: false, finished: false, index: 0, count: 1))
    }

    func test_resumeOffer() {
        let end = t0
        // on the Intercity 13 minutes later
        XCTAssertTrue(TripResume.offer(endedAt: end, now: end.addingTimeInterval(13 * 60), idle: true, moving: true, metresToItsStop: 15_000))
        // still at the change, on the platform
        XCTAssertTrue(TripResume.offer(endedAt: end, now: end.addingTimeInterval(120), idle: true, moving: false, metresToItsStop: 250))
        // gone elsewhere, standing
        XCTAssertFalse(TripResume.offer(endedAt: end, now: end.addingTimeInterval(120), idle: true, moving: false, metresToItsStop: 5000))
        XCTAssertFalse(TripResume.offer(endedAt: end, now: end.addingTimeInterval(120), idle: true, moving: false, metresToItsStop: nil))
        // after half an hour, or with a trip running
        XCTAssertFalse(TripResume.offer(endedAt: end, now: end.addingTimeInterval(31 * 60), idle: true, moving: true, metresToItsStop: 100))
        XCTAssertFalse(TripResume.offer(endedAt: end, now: end.addingTimeInterval(60), idle: false, moving: true, metresToItsStop: 100))
    }
}
