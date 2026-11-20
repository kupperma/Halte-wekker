import XCTest

/// 0.33: waking by time on trains (and fast buses). The distance rule stays the safety net: the time rule only ever
/// rings earlier, never later, and only on an estimate it can trust.
final class WakeRuleTests: XCTestCase {
    private let t0 = Fx.t0

    private func input(by: WakeBy = .time, minutes: Int = 3, train: Bool = true, metres: Double = 9000,
                       route: Double? = nil, wake: Double = 5000, live: Date? = nil, liveAge: TimeInterval? = nil,
                       speed: Double? = nil, fromStart: Double? = 20_000) -> WakeRule.Input {
        WakeRule.Input(by: by, minutes: minutes, isTrain: train, metres: metres, routeMetres: route, wakeMetres: wake,
                       liveArrival: live, liveAge: liveAge, speed: speed, fromStartMetres: fromStart, now: t0)
    }

    // MARK: the distance rule, as before

    func test_distanceRuleStillFires() {
        XCTAssertEqual(WakeRule.decide(input(metres: 4900)), .distance)
        XCTAssertEqual(WakeRule.decide(input(by: .distance, metres: 4900)), .distance)
        XCTAssertEqual(WakeRule.decide(input(metres: 5000)), .distance, "at the wake distance itself, as `d <= wake`")
        XCTAssertNil(WakeRule.decide(input(by: .distance, metres: 5100)))
    }

    func test_distanceRuleWinsWhenBothHold() {
        // (the time rule held too: the distance rule is named, as it would have rung anyway)
        XCTAssertEqual(WakeRule.decide(input(metres: 4000, live: t0 + 60, liveAge: 10)), .distance)
    }

    func test_byDistanceNeverRingsByTime() {
        XCTAssertNil(WakeRule.decide(input(by: .distance, metres: 6000, live: t0 + 60, liveAge: 10, speed: 40)))
    }

    // MARK: by time, from the live arrival

    func test_liveArrivalWithinTheMinutes() {
        XCTAssertEqual(WakeRule.decide(input(metres: 6000, live: t0 + 170, liveAge: 20)),
                       .time(minutes: 3, source: .live, seconds: 170))
        XCTAssertNil(WakeRule.decide(input(metres: 6000, live: t0 + 200, liveAge: 20)))
    }

    func test_staleLiveFallsBackToSpeed() {
        // 6 km at 30 m/s is 200 s: not yet; at 36 m/s, 167 s
        XCTAssertNil(WakeRule.decide(input(metres: 6000, live: t0 + 60, liveAge: 400, speed: 30)))
        guard case .time(3, .speed, let s)? = WakeRule.decide(input(metres: 6000, live: t0 + 60, liveAge: 400, speed: 36)) else {
            return XCTFail("by speed")
        }
        XCTAssertEqual(s, 6000 / 36, accuracy: 0.01)
    }

    func test_liveThatCantBeRightIsntUsed() {
        // a minute to go and 7 km left is 117 m/s: no train goes that fast
        XCTAssertNil(WakeRule.decide(input(metres: 7000, live: t0 + 60, liveAge: 10)))
        // its time has passed and you're 6 km away: the answer is behind, not you
        XCTAssertNil(WakeRule.decide(input(metres: 6000, live: t0 - 30, liveAge: 10)))
    }

    // MARK: by time, from your speed

    func test_haltedAtAStationBeforeYoursDoesntRing() {
        // standing at the station before yours, 2.5 km from it, the bus rule 2 km: no speed to go by
        XCTAssertNil(WakeRule.decide(input(minutes: 2, train: false, metres: 2500, wake: 2000, speed: 0.5)))
        XCTAssertNil(WakeRule.decide(input(minutes: 2, train: false, metres: 2500, wake: 2000, speed: nil)))
    }

    func test_alongTheRouteNotStraight() {
        // the line bends: 5.5 km straight but 12 km along it; at 40 m/s that's 300 s, not 137
        XCTAssertNil(WakeRule.decide(input(metres: 5500, route: 12_000, speed: 40)))
        XCTAssertEqual(WakeRule.remaining(input(metres: 5500, route: 12_000)), 12_000)
        // a route shorter than straight (rounding, a stop list that cuts a corner) never counts for less
        XCTAssertEqual(WakeRule.remaining(input(metres: 5500, route: 5000)), 5500)
        guard case .time? = WakeRule.decide(input(metres: 5500, route: 6000, speed: 40)) else { return XCTFail("150 s") }
    }

    func test_neverFurtherThanTheMinutesAtTopSpeed() {
        // a GPS speed of 60 m/s, 9 km left: 150 s by the sum, but no train here covers 9 km in 3 minutes
        XCTAssertNil(WakeRule.decide(input(metres: 9000, speed: 60)))
        XCTAssertEqual(WakeRule.reach(isTrain: true, minutes: 3), 3 * 60 * WakeRule.trainTop)
        XCTAssertEqual(WakeRule.reach(isTrain: false, minutes: 2), 2 * 60 * WakeRule.busTop)
    }

    func test_notWhileStillAtTheLegsFirstStop() {
        XCTAssertNil(WakeRule.decide(input(metres: 6000, live: t0 + 170, liveAge: 10, fromStart: 150)))
        XCTAssertNotNil(WakeRule.decide(input(metres: 6000, live: t0 + 170, liveAge: 10, fromStart: nil)))
    }

    func test_fastBusRingsBeforeItsDistance() {
        // a bus on the motorway: 3 km to go at 25 m/s is 120 s, its 2 km rule much later
        XCTAssertEqual(WakeRule.decide(input(minutes: 2, train: false, metres: 3000, wake: 2000, speed: 25)),
                       .time(minutes: 2, source: .speed, seconds: 120))
        // a town bus at 10 m/s: the distance rule comes first
        XCTAssertNil(WakeRule.decide(input(minutes: 2, train: false, metres: 2100, wake: 2000, speed: 10)))
    }

    // MARK: words

    func test_logWords() {
        XCTAssertEqual(WakeRule.log(.distance), "by distance")
        XCTAssertEqual(WakeRule.log(.time(minutes: 3, source: .live, seconds: 170)), "by time 3 min (live)")
        XCTAssertEqual(WakeRule.log(.time(minutes: 2, source: .speed, seconds: 100)), "by time 2 min (speed)")
        // the ride log's ring line says which rule fired
        XCTAssertEqual(FieldFormat.rideRing(WakeRule.log(.time(minutes: 3, source: .live, seconds: 170)), metres: 5400, legAge: 600, started: 21_000),
                       "ring · by time 3 min (live) · 5400 m · leg 600 s old · started 21000 m")
        XCTAssertTrue(FieldFormat.rideRing(WakeRule.log(.distance), metres: 1990, legAge: 300, started: 9000).hasPrefix("ring · by distance · "))
    }

    func test_whatItSays() {
        let time = WakeSettings(by: .time, trainMinutes: 3, busMinutes: 2)
        XCTAssertEqual(WakeRule.says(time, isTrain: true, wakeMetres: 5000), "3 min before your stop (or 5 km)")
        XCTAssertEqual(WakeRule.says(time, isTrain: false, wakeMetres: 2500), "2 min before your stop (or 2.5 km)")
        let dist = WakeSettings(by: .distance, trainMinutes: 3, busMinutes: 2)
        XCTAssertEqual(WakeRule.says(dist, isTrain: true, wakeMetres: 800), "800 m before your stop")
    }

    // MARK: the far GPS tier keeps clear of it

    func test_gpsWakeMetres() {
        XCTAssertEqual(WakeRule.gpsWakeMetres(wakeMetres: 5000, WakeSettings(), isTrain: true), 3 * 60 * WakeRule.trainTop)
        XCTAssertEqual(WakeRule.gpsWakeMetres(wakeMetres: 9000, WakeSettings(), isTrain: true), 9000)
        XCTAssertEqual(WakeRule.gpsWakeMetres(wakeMetres: 5000, WakeSettings(by: .distance), isTrain: true), 5000)
    }

    // MARK: the setting

    func test_settingsDefaultsAndBounds() {
        let d = UserDefaults(suiteName: "WakeRuleTests")!
        d.removePersistentDomain(forName: "WakeRuleTests")
        var s = WakeSettings.load(d)
        XCTAssertEqual(s, WakeSettings(by: .time, trainMinutes: 3, busMinutes: 2))
        XCTAssertEqual(s.minutes(isTrain: true), 3)
        XCTAssertEqual(s.minutes(isTrain: false), 2)
        s.by = .distance; s.trainMinutes = 5
        s.save(d)
        XCTAssertEqual(WakeSettings.load(d), WakeSettings(by: .distance, trainMinutes: 5, busMinutes: 2))
        d.set(40, forKey: WakeSettings.trainKey); d.set(0, forKey: WakeSettings.busKey); d.set("nonsense", forKey: WakeSettings.byKey)
        XCTAssertEqual(WakeSettings.load(d), WakeSettings(by: .time, trainMinutes: WakeSettings.range.upperBound, busMinutes: WakeSettings.range.lowerBound))
    }

    // MARK: speed, smoothed

    func test_smootherWarmsUpAndFollows() {
        var s = SpeedSmoother()
        s.add(30, at: t0)
        XCTAssertNil(s.speed(now: t0), "one reading isn't a speed yet")
        for k in 1...10 { s.add(30, at: t0 + Double(k) * 2) }
        XCTAssertEqual(s.speed(now: t0 + 20) ?? 0, 30, accuracy: 0.01)
        // halting at a station: it falls, not at once
        for k in 11...20 { s.add(0, at: t0 + Double(k) * 2) }
        let v = s.speed(now: t0 + 40) ?? -1
        XCTAssertLessThan(v, 20)
        XCTAssertGreaterThan(v, 5)
        for k in 21...80 { s.add(0, at: t0 + Double(k) * 2) }
        XCTAssertLessThan(s.speed(now: t0 + 160) ?? 99, WakeRule.minSpeed)
    }

    func test_smootherForgetsAfterAGap() {
        var s = SpeedSmoother()
        for k in 0...15 { s.add(30, at: t0 + Double(k) * 2) }
        XCTAssertNotNil(s.speed(now: t0 + 30))
        XCTAssertNil(s.speed(now: t0 + 30 + SpeedSmoother.gap + 1), "no reading for a while: not known")
        s.add(10, at: t0 + 200)
        XCTAssertNil(s.speed(now: t0 + 200), "after a gap it warms up again")
    }

    func test_smootherIgnoresNonsense() {
        var s = SpeedSmoother()
        for k in 0...15 { s.add(20, at: t0 + Double(k) * 2) }
        s.add(-1, at: t0 + 32)
        s.add(.nan, at: t0 + 33)
        s.add(400, at: t0 + 34)
        XCTAssertEqual(s.speed(now: t0 + 34) ?? 0, 20, accuracy: 0.01)
    }

    func test_readingFromAFix() {
        let a = Fix(t: t0, p: Fx.east(0), accuracy: 10, speed: -1, course: -1)
        let b = Fix(t: t0 + 10, p: Fx.east(300), accuracy: 10, speed: -1, course: -1)
        XCTAssertEqual(SpeedSmoother.reading(b, previous: a) ?? 0, 30, accuracy: 0.5)
        let own = Fix(t: t0 + 10, p: Fx.east(300), accuracy: 10, speed: 22, course: 90)
        XCTAssertEqual(SpeedSmoother.reading(own, previous: a), 22, "the GPS's own speed first")
        let rough = Fix(t: t0 + 10, p: Fx.east(300), accuracy: 120, speed: -1, course: -1)
        XCTAssertNil(SpeedSmoother.reading(rough, previous: a), "rough positions say nothing")
        XCTAssertNil(SpeedSmoother.reading(b, previous: nil))
    }

    // MARK: along the route

    func test_routeLeft() {
        let path = [Fx.east(0), Fx.east(3000), Fx.east(6900)]
        XCTAssertEqual(RouteLeft.metres(from: Fx.east(1000), along: path) ?? 0, 5900, accuracy: 2)
        XCTAssertEqual(RouteLeft.metres(from: Fx.east(1000, north: 200), along: path) ?? 0, 5900, accuracy: 2)
        XCTAssertNil(RouteLeft.metres(from: Fx.east(1000, north: 3000), along: path), "far off the route: not this route")
        XCTAssertNil(RouteLeft.metres(from: Fx.east(1000), along: [Fx.east(0)]))
    }

    func test_routeLeftAroundABend() {
        // out east 3 km, then back west 2 km north of the start: the stop is near you straight, far along
        let path = [Fx.east(0), Fx.east(3000), Fx.east(3000, north: 1000), Fx.east(500, north: 1000)]
        let you = Fx.east(800)
        let left = RouteLeft.metres(from: you, along: path) ?? 0
        XCTAssertEqual(left, 2200 + 1000 + 2500, accuracy: 3)
        XCTAssertLessThan(Geo.metres(you, Fx.east(500, north: 1000)), 1100)
    }
}
