import XCTest

final class ApproachTests: XCTestCase {
    private let t0 = Fx.t0

    /// A straight road east from (51.6, 5.3): pieces of 600 m, 2 minutes each (5 m/s), a minute at each stop.
    private func road(_ start: Date, pieces n: Int = 4) -> [RealPositions.Leg] {
        let kx = cos(51.6 * .pi / 180) * 111_320
        func p(_ m: Double) -> GeoPoint { GeoPoint(lat: 51.6, lon: 5.3 + m / kx) }
        return RealPositions.chained((0..<n).map { k in
            let d = start.addingTimeInterval(Double(k) * 180)
            return (path: [p(Double(k) * 600), p(Double(k + 1) * 600)], departure: d, arrival: d.addingTimeInterval(120))
        })
    }
    private func fix(_ m: Double, age: TimeInterval, _ now: Date) -> GPSFix {
        let kx = cos(51.6 * .pi / 180) * 111_320
        return GPSFix(lat: 51.6, lon: 5.3 + m / kx, bearing: 90, at: now.addingTimeInterval(-age))
    }

    /// The same road's stops (every 600 m) with their timetable: stop i leaves at start + 3i min, gets to the next
    /// 2 min later (a minute's wait at each stop). `live`: the live times, `late` seconds behind.
    private func stops(_ start: Date, count n: Int = 5, late: TimeInterval? = nil) -> (metres: [Double], times: [StopTimes]) {
        let metres = (0..<n).map { Double($0) * 600 }
        let times = (0..<n).map { i -> StopTimes in
            let dep = start.addingTimeInterval(Double(i) * 180)
            let arr = i == 0 ? dep : dep.addingTimeInterval(-60)
            return StopTimes(arrival: late.map { arr.addingTimeInterval($0) }, departure: late.map { dep.addingTimeInterval($0) },
                             scheduledArrival: arr, scheduledDeparture: dep)
        }
        return (metres, times)
    }

    // MARK: where to draw it

    /// The field bug: a fix 200 m before your stop, 45 s old, was moved on at its times' speed onto your stop.
    func test_movedOnFromItsFix_reachedYourStop_nowStopsShortOfIt() {
        let t = t0, legs = road(t), now = t.addingTimeInterval(100)
        let f = fix(400, age: 45, now)
        let placed = RealPositions.place(f, on: legs, now: now)
        XCTAssertEqual(placed?.metres ?? 0, 600, accuracy: 1, "today's rule: on the stop at 600 m")
        let raw = RealPositions.snap(f, on: legs).map { legs[$0.leg].start + $0.along } ?? -1
        XCTAssertEqual(raw, 400, accuracy: 1)
        XCTAssertEqual(Approach.drawn(advanced: placed!.metres, raw: raw, mine: 600), 600 - Approach.atStop, accuracy: 1e-9)
    }

    func test_drawn_followsItsGPSUntilItIsThere() {
        // still on its way: moving on is fine short of the stop
        XCTAssertEqual(Approach.drawn(advanced: 450, raw: 400, mine: 600), 450)
        // the fix itself within 35 m of the stop: it's there
        XCTAssertEqual(Approach.drawn(advanced: 600, raw: 570, mine: 600), 600)
        // the fix past the stop: as it is
        XCTAssertEqual(Approach.drawn(advanced: 640, raw: 640, mine: 600), 640)
        // moved on a long way from a fix far off: still short of the stop
        XCTAssertEqual(Approach.drawn(advanced: 700, raw: 100, mine: 600), 565)
        XCTAssertTrue(Approach.drawn(advanced: .nan, raw: 100, mine: 600).isNaN)
    }

    // MARK: when it can be there

    func test_runTime_restOfItsPieceAndThePiecesAfter_withoutTheWaits() {
        let s = stops(t0)
        // halfway along the first piece, your stop the fourth (1800 m): 60 + 120 + 120 s (the waits not counted)
        XCTAssertEqual(Approach.runTime(from: 300, stopMetres: s.metres, times: s.times, mine: 3) ?? -1, 300, accuracy: 1e-9)
        // at a stop: the pieces from there
        XCTAssertEqual(Approach.runTime(from: 600, stopMetres: s.metres, times: s.times, mine: 3) ?? -1, 240, accuracy: 1e-9)
        // before its first stop: from there
        XCTAssertEqual(Approach.runTime(from: -50, stopMetres: s.metres, times: s.times, mine: 2) ?? -1, 240, accuracy: 1e-9)
        // within 35 m of your stop, or just past it: there
        XCTAssertEqual(Approach.runTime(from: 1770, stopMetres: s.metres, times: s.times, mine: 3), 0)
        XCTAssertEqual(Approach.runTime(from: 1815, stopMetres: s.metres, times: s.times, mine: 3), 0)
        // past it: nothing to wait for
        XCTAssertNil(Approach.runTime(from: 1830, stopMetres: s.metres, times: s.times, mine: 3))
        // bad input
        XCTAssertNil(Approach.runTime(from: 300, stopMetres: s.metres, times: s.times, mine: 9))
        XCTAssertNil(Approach.runTime(from: .nan, stopMetres: s.metres, times: s.times, mine: 3))
        XCTAssertNil(Approach.runTime(from: 300, stopMetres: [0, 600], times: s.times, mine: 1))
    }

    func test_runTime_liveTimesWithoutATimetable_noTimesNoAnswer() {
        var s = stops(t0, late: 90)
        for i in s.times.indices { s.times[i].scheduledArrival = nil; s.times[i].scheduledDeparture = nil }
        XCTAssertEqual(Approach.runTime(from: 300, stopMetres: s.metres, times: s.times, mine: 2) ?? -1, 180, accuracy: 1e-9)
        s.times[1] = StopTimes()
        XCTAssertNil(Approach.runTime(from: 300, stopMetres: s.metres, times: s.times, mine: 2))
    }

    /// The field case: the card said 4 min, the bus's GPS had it four pieces (8 min of driving) away.
    func test_arrival_theCardsFourMinutesAgainstItsGPS() {
        let now = t0.addingTimeInterval(600), s = stops(t0)
        let given = now.addingTimeInterval(4 * 60)
        let a = Approach.arrival(fixAt: now.addingTimeInterval(-20), metres: 0, stopMetres: s.metres, times: s.times, mine: 4)
        XCTAssertEqual(a?.timeIntervalSince(now) ?? 0, 460, accuracy: 1e-9)
        var steady = Approach.Steady()
        let shown = steady.update(given: given, estimate: a, fixAge: 20)
        XCTAssertEqual(shown, a, "about 8 min, not 4")
    }

    // MARK: which time to show

    func test_steady_showsTheGPSTimeOnlyWhenClearlyLater_andHoldsIt() {
        let given = t0
        var s = Approach.Steady()
        // under 2 min later: the given time
        XCTAssertNil(s.update(given: given, estimate: given.addingTimeInterval(100), fixAge: 30))
        // 2 min or more later: the GPS's
        XCTAssertEqual(s.update(given: given, estimate: given.addingTimeInterval(130), fixAge: 30), given.addingTimeInterval(130))
        // a little different: stays as it is (no flicker)
        XCTAssertEqual(s.update(given: given, estimate: given.addingTimeInterval(150), fixAge: 30), given.addingTimeInterval(130))
        // 30 s or more different: moves
        XCTAssertEqual(s.update(given: given, estimate: given.addingTimeInterval(170), fixAge: 30), given.addingTimeInterval(170))
        // under 2 but at least 1 min later: still shown (it doesn't jump back and forth around 2 min)
        XCTAssertEqual(s.update(given: given, estimate: given.addingTimeInterval(80), fixAge: 30), given.addingTimeInterval(80))
        // under a minute later: the given time again
        XCTAssertNil(s.update(given: given, estimate: given.addingTimeInterval(50), fixAge: 30))
        XCTAssertNil(s.shown)
    }

    func test_steady_theGivenTimeCatchingUp_neverEarlierThanIt() {
        var s = Approach.Steady()
        let est = t0.addingTimeInterval(300)
        XCTAssertEqual(s.update(given: t0, estimate: est, fixAge: 10), est)
        // the given time moved later (Transitous caught up): the later of the two, and once they're close, the given one
        XCTAssertEqual(s.update(given: t0.addingTimeInterval(200), estimate: est.addingTimeInterval(10), fixAge: 10), est)
        XCTAssertNil(s.update(given: t0.addingTimeInterval(280), estimate: est, fixAge: 10))
    }

    func test_steady_freshness() {
        var s = Approach.Steady()
        let given = t0, est = t0.addingTimeInterval(300)
        // a fix older than 90 s doesn't start it
        XCTAssertNil(s.update(given: given, estimate: est, fixAge: 95))
        XCTAssertEqual(s.update(given: given, estimate: est, fixAge: 60), est)
        // once shown, a fix up to 3 minutes old keeps it (between fetches)
        XCTAssertEqual(s.update(given: given, estimate: est, fixAge: 150), est)
        // older, or none: the given time
        XCTAssertNil(s.update(given: given, estimate: est, fixAge: 200))
        XCTAssertEqual(s.update(given: given, estimate: est, fixAge: 10), est)
        XCTAssertNil(s.update(given: given, estimate: nil, fixAge: nil))
        // a fix from well in the future (the phone's clock): not used
        XCTAssertNil(s.update(given: given, estimate: est, fixAge: -120))
    }
}
