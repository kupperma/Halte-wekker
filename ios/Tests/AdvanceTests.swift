import XCTest

/// 0.34: an old bus GPS fix moved forward by the bus's own pace. OVapi's positions are often 30–90 s old; they were moved
/// on at most a minute at the timetable's speed. Now: at the speed it was seen going between its last two fixes (when
/// that's sane), late as it is, standing a moment at a stop on its way, for up to 2 minutes; and you're judged against
/// that with more room for an older fix.
final class AdvanceTests: XCTestCase {
    private let t = Date(timeIntervalSince1970: 1_794_900_000)
    private let kx = cos(51.6 * .pi / 180) * 111_320

    private func p(_ m: Double) -> GeoPoint { GeoPoint(lat: 51.6, lon: 5.3 + m / kx) }
    private func fix(_ m: Double, at: Date, speed: Double? = nil) -> GPSFix {
        GPSFix(lat: 51.6, lon: 5.3 + m / kx, bearing: 90, at: at, speed: speed)
    }

    /// One long piece: 3000 m in 300 s (10 m/s), from t.
    private var long: [RealPositions.Leg] { RealPositions.chained([(path: [p(0), p(1500), p(3000)], departure: t, arrival: t.addingTimeInterval(300))]) }

    /// Pieces of 600 m, 2 minutes each (5 m/s), a minute at each stop.
    private var short: [RealPositions.Leg] {
        RealPositions.chained((0..<3).map { k in
            let d = t.addingTimeInterval(Double(k) * 180)
            return (path: [p(Double(k) * 600), p(Double(k) * 600 + 300), p(Double(k + 1) * 600)], departure: d, arrival: d.addingTimeInterval(120))
        })
    }

    func test_observedSpeedBetweenItsLastTwoFixes() {
        let legs = long
        let now = t.addingTimeInterval(100)
        // 300 m in 30 s along its road: 10 m/s
        XCTAssertEqual(RealPositions.observedSpeed(fix(800, at: now), previous: fix(500, at: now.addingTimeInterval(-30)), on: legs) ?? 0, 10, accuracy: 0.5)
        // the speed a train's own fix gives (NS)
        XCTAssertEqual(RealPositions.observedSpeed(fix(800, at: now, speed: 33), previous: nil, on: legs), 33)
        // not sane: too close in time, too far apart in time, faster than a bus can go, backwards
        XCTAssertNil(RealPositions.observedSpeed(fix(800, at: now), previous: fix(790, at: now.addingTimeInterval(-2)), on: legs))
        XCTAssertNil(RealPositions.observedSpeed(fix(800, at: now), previous: fix(0, at: now.addingTimeInterval(-300)), on: legs))
        XCTAssertNil(RealPositions.observedSpeed(fix(2800, at: now), previous: fix(0, at: now.addingTimeInterval(-30)), on: legs))
        XCTAssertNil(RealPositions.observedSpeed(fix(500, at: now), previous: fix(800, at: now.addingTimeInterval(-30)), on: legs))
        XCTAssertNil(RealPositions.observedSpeed(fix(800, at: now), previous: nil, on: legs))
    }

    func test_movesOnAtItsObservedSpeed_upToTwoMinutes() {
        let legs = long
        let now = t.addingTimeInterval(200)
        let old = fix(500, at: now.addingTimeInterval(-100))
        let s = RealPositions.snap(old, on: legs)!
        // its timetable: 10 m/s, a minute at most (today)
        let plain = RealPositions.advance(s, from: old.at, on: legs, now: now)
        XCTAssertEqual(plain.along, 1100, accuracy: 2)
        // seen going 8 m/s: 100 s at that
        let seen = RealPositions.advance(s, from: old.at, on: legs, now: now, pace: .init(speed: 8, late: nil))
        XCTAssertEqual(seen.along, 1300, accuracy: 2)
        // 150 s old: 2 minutes at most
        let older = fix(500, at: now.addingTimeInterval(-150))
        let s2 = RealPositions.snap(older, on: legs)!
        XCTAssertEqual(RealPositions.advance(s2, from: older.at, on: legs, now: now, pace: .init(speed: 8, late: nil)).along, 1460, accuracy: 2)
    }

    func test_aLateBusLeavesItsStopLate() {
        let legs = short
        // 50 m before the stop at 600 m, 60 s late; its next piece leaves at t+180, so a minute late at t+240
        let now = t.addingTimeInterval(230)
        let f = fix(550, at: now.addingTimeInterval(-60))
        let s = RealPositions.snap(f, on: legs)!
        let late = RealPositions.lateness(s, at: f.at, on: legs)
        XCTAssertEqual(late ?? 0, 60, accuracy: 3)
        let a = RealPositions.advance(s, from: f.at, on: legs, now: now, pace: .init(speed: 5, late: late))
        XCTAssertEqual(a.leg, 0, "still at the stop at t+230")
        XCTAssertEqual(a.along, 600, accuracy: 1)
        // without its lateness (today): gone on at t+180
        let b = RealPositions.advance(s, from: f.at, on: legs, now: now)
        XCTAssertEqual(b.leg, 1)
    }

    func test_standsAMomentAtAStopOnItsWay() {
        let legs = short
        // late at the stop: its departure has passed, but it stands there `dwell` before it goes on
        let now = t.addingTimeInterval(420)
        let f = fix(1150, at: now.addingTimeInterval(-60))          // 50 m before the stop at 1200, 5 m/s
        let s = RealPositions.snap(f, on: legs)!
        let a = RealPositions.advance(s, from: f.at, on: legs, now: now, pace: .init(speed: 5, late: nil))
        // 10 s to the stop, `dwell` there, then on at 5 m/s
        let expected = 1200 + 5 * (60 - 10 - RealPositions.dwell)
        XCTAssertEqual(legs[a.leg].start + a.along, expected, accuracy: 2)
    }

    func test_placeUsesItsFixBefore() {
        let legs = long
        let now = t.addingTimeInterval(200)
        let f = fix(1000, at: now.addingTimeInterval(-80)), before = fix(760, at: now.addingTimeInterval(-110))     // 8 m/s
        let p = RealPositions.place(f, previous: before, on: legs, now: now)
        XCTAssertEqual(p?.metres ?? 0, 1000 + 8 * 80, accuracy: 3)
        // without the one before: as today
        XCTAssertEqual(RealPositions.place(f, previous: nil, on: legs, now: now)?.metres ?? 0, 1600, accuracy: 3)
    }

    func test_moreRoomForAnOlderFix() {
        XCTAssertEqual(RealPositions.ageSlack(age: 20, speed: 10), 0)
        XCTAssertEqual(RealPositions.ageSlack(age: 90, speed: 10), 0.2 * 10 * 60, accuracy: 0.1)
        XCTAssertLessThanOrEqual(RealPositions.ageSlack(age: 600, speed: 40), RealPositions.maxSlack)
        XCTAssertEqual(RealPositions.ageSlack(age: .nan, speed: 10), 0)
    }

    /// The matcher: a bus whose fix is 85 s old and which is going faster than its timetable is judged where its own pace
    /// puts it, with you; and its older fix has more room.
    func test_matcherJudgesAgainstTheAdvancedFix() {
        let you = Fx.fixes(from: 2000, speed: 14, count: 15, start: Fx.t0)
        let newest = you.last!.t
        // timetable: 7 m/s; it really goes 14 (with you); its fix 85 s old at where it was then
        var bus = Fx.track("305", line: "305", train: false, path: Fx.railway, at: 1500, speed: 7)
        let back = 14.0 * 85
        let at = Fx.east(2000 + 14 * 28 - back)
        let before = Fx.east(2000 + 14 * 28 - back - 14 * 30)
        bus.gps = VehicleGPS(fix: GPSFix(lat: at.lat, lon: at.lon, bearing: 90, at: newest.addingTimeInterval(-85)),
                             previous: GPSFix(lat: before.lat, lon: before.lon, bearing: 90, at: newest.addingTimeInterval(-115)))
        let j = VehicleMatch.judgeAll(you, [bus], strictTimes: false)
        XCTAssertEqual(j.first?.evidence?.gps, true)
        XCTAssertNotNil(Fx.ok(j, "305"), "\(j)")
        XCTAssertLessThan(abs(j.first?.evidence?.offset ?? 9999), 100)
    }
}
