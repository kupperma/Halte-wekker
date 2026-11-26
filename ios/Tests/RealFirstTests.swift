import XCTest

/// 0.40.3: the bus or train you wait for drawn where its own GPS put it (a little moved on at most), the estimate as a
/// ghost ahead, "here" only by a fresh close fix, by its times without GPS, not at your stop when the road before it
/// isn't known.
final class RealFirstTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 7_000_000)
    private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    /// Stops every 1000 m; `times[i]`: (arrives, leaves), s after `t0`, live as the timetable.
    private func trip(_ times: [(Double, Double)]) -> [BusFusion.Stop] {
        var out: [BusFusion.Stop] = []
        for i in times.indices {
            let st = StopTimes(arrival: i == 0 ? nil : at(times[i].0), departure: at(times[i].1),
                               scheduledArrival: i == 0 ? nil : at(times[i].0), scheduledDeparture: at(times[i].1))
            out.append(BusFusion.Stop(metres: Double(i) * 1000, times: st))
        }
        return out
    }

    /// 1000 m in 2 minutes a piece (8.3 m/s), no waits; your stop the last (3000 m, at 360 s).
    private var plain: [BusFusion.Stop] { trip([(0, 0), (120, 120), (240, 240), (360, 360)]) }

    private func show(_ s: [BusFusion.Stop], fix: RealFirst.Fix?, mine: Int? = 3, now: Double, fromStart: Bool = true,
                      train: Bool = false, leaves: Double? = nil, me: RealFirst.Fix? = nil) -> RealFirst.Shown {
        let x = RealFirst.Input(stops: s, fix: fix, live: true, timesAt: at(now), mine: mine, mineLeaves: leaves.map { at($0) },
                                now: at(now), fromStart: fromStart, isTrain: train, onBoard: me)
        return RealFirst.show(x)
    }

    // MARK: by its own GPS

    func test_aMinuteOldFix_isDrawnAtTheFix_movedOnTwentySecondsAtMost_theEstimateAGhostAhead() {
        // its fix 60 s old at 2100 m going 5 m/s; its times put it at 2500 m
        let s = show(plain, fix: RealFirst.Fix(metres: 2100, at: at(240), speed: 5), now: 300)
        XCTAssertEqual(s.source, .gps)
        XCTAssertEqual(s.metres ?? 0, 2200, accuracy: 0.01, "20 s at 5 m/s, not 60 s, and no pull from its times")
        XCTAssertEqual(s.advanced, 100, accuracy: 0.01)
        XCTAssertFalse(s.atFix)
        XCTAssertNil(s.here)
        // the estimate (`BusFusion`'s: its GPS and its times together) ahead, faintly
        XCTAssertEqual(s.ghost ?? 0, 2447.6, accuracy: 1)
        XCTAssertEqual(RealFirst.tag(s), "GPS 60 s")
        XCTAssertEqual(RealFirst.logLine(vehicle: "305·9449", feed: "ovapi", s),
                       "vehicle shown · 305·9449 · gps ovapi 60 s · real +100 m · ghost +350 m")
    }

    func test_aFreshFix_isDrawnThere_noGhostWhenTheEstimateIsClose() {
        let s = show(plain, fix: RealFirst.Fix(metres: 2470, at: at(296), speed: 8), now: 300)
        XCTAssertEqual(s.metres ?? 0, 2502, accuracy: 0.01)
        XCTAssertNil(s.ghost)
    }

    func test_stuckBus_isntMovedOn() {
        // standing still between its last two fixes, or not known, or standing at a stop by the feed
        let still = show(plain, fix: RealFirst.Fix(metres: 2100, at: at(240), speed: 0), now: 300)
        XCTAssertEqual(still.metres ?? 0, 2100, accuracy: 0.01)
        XCTAssertEqual(still.advanced, 0)
        let unknown = show(plain, fix: RealFirst.Fix(metres: 2100, at: at(240), speed: nil), now: 300)
        XCTAssertEqual(unknown.metres ?? 0, 2100, accuracy: 0.01)
        let stopped = show(plain, fix: RealFirst.Fix(metres: 2000, at: at(240), speed: 5, stopped: true), now: 300)
        XCTAssertEqual(stopped.metres ?? 0, 2000, accuracy: 0.01)
        let crawling = show(plain, fix: RealFirst.Fix(metres: 2100, at: at(240), speed: 1.2), now: 300)
        XCTAssertEqual(crawling.metres ?? 0, 2100, accuracy: 0.01, "not clearly moving")
    }

    func test_neverPastTheNextStopItMustStopAt() {
        // a train stops at every stop: 950 m going 20 m/s, 20 s old, stops at 1000 m
        let train = show(plain, fix: RealFirst.Fix(metres: 950, at: at(100), speed: 20), now: 120, train: true)
        XCTAssertEqual(train.metres ?? 0, 1000, accuracy: 0.01)
        // a bus passes a stop that isn't a timing point (it may not stop there)
        let bus = show(plain, fix: RealFirst.Fix(metres: 950, at: at(100), speed: 20), now: 120)
        XCTAssertEqual(bus.metres ?? 0, 1350, accuracy: 0.01)
        // …but not a timing point (the timetable has it stand there 60 s)
        let timing = trip([(0, 0), (120, 180), (300, 300), (420, 420)])
        let held = show(timing, fix: RealFirst.Fix(metres: 950, at: at(100), speed: 20), now: 120)
        XCTAssertEqual(held.metres ?? 0, 1000, accuracy: 0.01)
    }

    func test_neverIntoYourStop_withoutAFreshCloseFix() {
        // 100 m before your stop, going 10 m/s, 15 s old: moved on, but not into your stop, and not "here" (> 80 m)
        let s = show(plain, fix: RealFirst.Fix(metres: 2900, at: at(285), speed: 10), now: 300)
        XCTAssertEqual(s.metres ?? 0, 2965, accuracy: 0.01)
        XCTAssertNil(s.here)
        // within 80 m by a fresh fix: arriving
        let near = show(plain, fix: RealFirst.Fix(metres: 2940, at: at(290), speed: 6), now: 300)
        XCTAssertEqual(near.here, .arriving)
        XCTAssertLessThanOrEqual(near.metres ?? 9999, 2965.01)
        // right at your stop, but its fix 120 s old: nothing said, drawn at its fix
        let old = show(plain, fix: RealFirst.Fix(metres: 2990, at: at(180), speed: 0), now: 300)
        XCTAssertNil(old.here)
        XCTAssertEqual(old.metres ?? 0, 2990, accuracy: 0.01)
        // right at your stop by a fresh fix: there; leaving within a minute: "at your stop", later: "Waiting"
        let there = show(plain, fix: RealFirst.Fix(metres: 2990, at: at(280), speed: 0), now: 300)
        XCTAssertEqual(there.here, .atStop)
        XCTAssertTrue(there.isHere)
        XCTAssertEqual(there.metres ?? 0, 3000, accuracy: 0.01)
        let waiting = show(plain, fix: RealFirst.Fix(metres: 2990, at: at(280), speed: 0), now: 300, leaves: 480)
        XCTAssertEqual(waiting.waiting, at(480))
        XCTAssertEqual(BusFusion.waitingText(leaves: at(480), clock: { _ in "17:42" }), "Waiting · leaves 17:42")
    }

    func test_theGhost_isntAtYourStop_unlessItsDueThereWithinHalfAMinute() {
        // stuck 1.5 km before your stop; its times have it at your stop by now (it's due at 360 s, a minute away)
        let s = show(plain, fix: RealFirst.Fix(metres: 1500, at: at(290), speed: 0), now: 300)
        XCTAssertEqual(s.metres ?? 0, 1500, accuracy: 0.01)
        XCTAssertNotNil(s.ghost)
        XCTAssertLessThanOrEqual(s.ghost ?? 9999, 2900.01)
        // the rule itself: an estimate at your stop, due in 20 s, may be drawn there
        let x = RealFirst.Input(stops: plain, fix: nil, live: true, timesAt: at(340), mine: 3, now: at(340))
        XCTAssertEqual(RealFirst.ghost(2990, drawn: 2500, x, mine: 3) ?? 0, 2990, accuracy: 0.01)
        let early = RealFirst.Input(stops: plain, fix: nil, live: true, timesAt: at(300), mine: 3, now: at(300))
        XCTAssertEqual(RealFirst.ghost(2990, drawn: 2500, early, mine: 3) ?? 0, 2900, accuracy: 0.01)
        XCTAssertNil(RealFirst.ghost(2990, drawn: 2800, early, mine: 3), "less than 150 m ahead once kept off your stop")
    }

    func test_offItsRoad_isDrawnAtTheFixItself() {
        let s = show(plain, fix: RealFirst.Fix(metres: 2100, at: at(280), speed: 8, crossTrack: 90), now: 300)
        XCTAssertEqual(s.source, .gps)
        XCTAssertTrue(s.atFix)
        XCTAssertEqual(s.advanced, 0)
    }

    // MARK: a train through your station, its leg starting there

    func test_throughTrain_legStartsAtYourStop_fixTwentyKmBefore_isDrawnThere_notAtYourStop() {
        // its leg: your station (at 540 s, 9 minutes from now) and the next; NS has it 20 km before your station
        let leg = trip([(540, 600), (900, 900)])
        let fix = RealFirst.Fix(metres: nil, at: at(-10), speed: 30, toMine: 20_000)
        let s = show(leg, fix: fix, mine: 0, now: 0, fromStart: false, train: true)
        XCTAssertEqual(s.source, .gps)
        XCTAssertTrue(s.atFix)
        XCTAssertNil(s.metres, "not at your station")
        XCTAssertNil(s.here)
        // a fix 60 km away can't be it (no faster than 40 m/s to its time): not drawn at your station either
        let far = RealFirst.Fix(metres: nil, at: at(-10), speed: 30, toMine: 60_000)
        let none = show(leg, fix: far, mine: 0, now: 0, fromStart: false, train: true)
        XCTAssertEqual(none.source, .none)
        XCTAssertNil(none.metres)
        XCTAssertEqual(none.why, "fix off its road, road before your stop not known")
    }

    // MARK: without GPS

    func test_noGPS_nineMinutesOut_byItsTimes_nineMinutesOfRoadBeforeYourStop() {
        // a stop a kilometre every minute; your stop the tenth (9000 m, at 540 s)
        var times: [(Double, Double)] = []
        for i in 0..<10 { times.append((Double(i) * 60, Double(i) * 60)) }
        let s = show(trip(times), fix: nil, mine: 9, now: 1)
        XCTAssertEqual(s.source, .byTimes)
        XCTAssertEqual(s.metres ?? 0, 16.7, accuracy: 1)
        XCTAssertGreaterThan(9000 - (s.metres ?? 9000), 8900)
        XCTAssertEqual(RealFirst.tag(s), "by times")
        XCTAssertEqual(RealFirst.logLine(vehicle: "305·9449", feed: "ovapi", s), "vehicle shown · 305·9449 · no gps: no fix · by times")
    }

    func test_noGPS_byTimes_notAtYourStop_beforeItLeavesThere() {
        // its times have it at your stop (arrived 300 s, leaves 420 s): 35 m short of it until then
        let s = trip([(0, 0), (120, 120), (240, 240), (300, 420)])
        let shown = show(s, fix: nil, now: 330)
        XCTAssertEqual(shown.metres ?? 0, 2965, accuracy: 0.01)
        XCTAssertNil(shown.here)
    }

    func test_noRoadBeforeYourStop_noMarkerAtYourStop() {
        let leg = trip([(540, 600), (900, 900)])
        let s = show(leg, fix: nil, mine: 0, now: 0, fromStart: false)
        XCTAssertEqual(s.source, .none)
        XCTAssertNil(s.metres)
        XCTAssertEqual(RealFirst.tag(s), "")
        XCTAssertEqual(RealFirst.logLine(vehicle: "IC·3561", feed: "ns", s),
                       "vehicle shown · IC·3561 · no gps: no fix, road before your stop not known · not drawn")
        // its trip starts at your stop: not known where it is before it leaves
        XCTAssertEqual(show(leg, fix: nil, mine: 0, now: 0).source, .none)
    }

    func test_aFixThatCantBeThisJourney_isntUsed() {
        // a fresh fix 1.4 km ahead of its times: another journey's
        let s = show(plain, fix: RealFirst.Fix(metres: 2005, at: at(62), speed: 0), mine: 2, now: 72)
        XCTAssertEqual(s.source, .byTimes)
        XCTAssertEqual(s.why, "fix not this journey")
        XCTAssertNil(s.here)
        // a fix older than 3 minutes isn't drawn
        let old = show(plain, fix: RealFirst.Fix(metres: 1000, at: at(0), speed: 0), now: 200)
        XCTAssertEqual(old.source, .byTimes)
    }

    // MARK: on board

    func test_onBoard_itsWhereYouAre() {
        let me = RealFirst.Fix(metres: 1500, at: at(298))
        let s = show(plain, fix: RealFirst.Fix(metres: 1000, at: at(240), speed: 5), now: 300, me: me)
        XCTAssertEqual(s.source, .onBoard)
        XCTAssertEqual(s.metres ?? 0, 1500, accuracy: 0.01)
        XCTAssertNil(s.ghost)
        XCTAssertEqual(RealFirst.tag(s), "you’re on it")
    }

    // MARK: drawing it

    func test_glide_toANewFix_overTwoSeconds_backToo() {
        var g = RealFirst.Glide()
        XCTAssertEqual(g.step(to: 1000, now: at(0)), 1000)
        XCTAssertEqual(g.step(to: 1010, now: at(1)), 1010, "small moves: drawn where it is")
        // a new fix 110 m behind: from where it's drawn, back there over 2 s, no jump
        XCTAssertEqual(g.step(to: 900, now: at(2)), 1010)
        XCTAssertEqual(g.step(to: 900, now: at(3)), 955, accuracy: 0.01)
        XCTAssertEqual(g.step(to: 900, now: at(4)), 900, accuracy: 0.01)
        // forward too
        let mid: Double = g.step(to: 1200, now: at(5))
        XCTAssertEqual(mid, 900, accuracy: 0.01)
        let half: Double = g.step(to: 1200, now: at(6))
        XCTAssertEqual(half, 1050, accuracy: 0.01)
        XCTAssertEqual(g.step(to: 1200, now: at(7)), 1200, accuracy: 0.01)
        // not drawn for a while: there at once
        XCTAssertEqual(g.step(to: 3000, now: at(60)), 3000)
    }

    func test_estimatedMode_isTheOldFusedPlace() {
        let x = RealFirst.Input(stops: plain, fix: RealFirst.Fix(metres: 2100, at: at(252), speed: 5), live: true, timesAt: at(300),
                                mine: 3, now: at(300))
        let s = RealFirst.estimated(x)
        XCTAssertEqual(s.source, .gps)
        XCTAssertEqual(s.metres ?? 0, 2410.5, accuracy: 1)
        XCTAssertNil(s.ghost)
    }

    func test_ageText() {
        XCTAssertEqual(RealFirst.ageText(40.4), "40 s")
        XCTAssertEqual(RealFirst.ageText(150), "3 min")
    }
}
