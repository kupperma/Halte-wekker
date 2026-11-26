import XCTest

final class BusFusionTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 7_000_000)
    private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    /// Stops every 1000 m; `times[i]`: (arrives, leaves) by the timetable, s after `t0`; live: the timetable + `delay`.
    private func trip(_ times: [(Double, Double)], delay: TimeInterval = 0) -> [BusFusion.Stop] {
        var out: [BusFusion.Stop] = []
        for i in times.indices {
            let sa: Date = at(times[i].0)
            let sd: Date = at(times[i].1)
            let st = StopTimes(arrival: i == 0 ? nil : sa.addingTimeInterval(delay), departure: sd.addingTimeInterval(delay),
                               scheduledArrival: i == 0 ? nil : sa, scheduledDeparture: sd)
            out.append(BusFusion.Stop(metres: Double(i) * 1000, times: st))
        }
        return out
    }

    /// 1000 m in 2 minutes a piece (8.3 m/s), no waits.
    private var plain: [BusFusion.Stop] { trip([(0, 0), (120, 120), (240, 240), (360, 360)]) }

    private func fuse(_ stops: [BusFusion.Stop], fix: BusFusion.Fix?, live: Bool = true, mine: Int? = 3, now: Double) -> BusFusion.Estimate {
        BusFusion.fuse(BusFusion.Input(stops: stops, fix: fix, live: live, timesAt: at(now), mine: mine, now: at(now)))
    }

    // MARK: by its times

    func test_byTimes_theSecondsLeftAtTheTimetablesSpeed_onThatPiece() {
        let b = BusFusion.byTimes(plain, now: at(300))
        XCTAssertEqual(b?.metres ?? 0, 2500, accuracy: 0.01)
        XCTAssertEqual(b?.next, 3)
        // just gone from stop 2: on the piece after it, not before it
        let late = BusFusion.byTimes(plain, now: at(241))
        XCTAssertGreaterThanOrEqual(late?.metres ?? 0, 2000)
        // very late at the next stop: at the start of that piece, not further back
        var slow: [BusFusion.Stop] = plain
        slow[3].times.arrival = at(900)
        XCTAssertEqual(BusFusion.byTimes(slow, now: at(300))?.metres ?? 0, 2000, accuracy: 0.01)
    }

    // MARK: the two together

    func test_gpsBehind_etaAhead_isBlendedBetweenThem() {
        // its fix 48 s old at 2100 m going 5 m/s (2340 m by now); its times put it at 2500 m
        let e = fuse(plain, fix: BusFusion.Fix(metres: 2100, at: at(252), speed: 5), now: 300)
        XCTAssertEqual(e.gps ?? 0, 2340, accuracy: 0.01)
        XCTAssertEqual(e.eta ?? 0, 2500, accuracy: 0.01)
        XCTAssertEqual(e.metres ?? 0, 2410.5, accuracy: 1)
        XCTAssertGreaterThan(e.metres ?? 0, e.gps ?? 0)
        XCTAssertLessThan(e.metres ?? 0, e.eta ?? 0)
        XCTAssertEqual(e.note, .none)
        XCTAssertEqual(BusFusion.logLine(kind: "bus", vehicle: "305·9449", e, drawn: e.metres ?? 0),
                       "bus fused · 305·9449 · gps 48 s old +240 m · eta says +400 m · drawn +310 m")
    }

    func test_oldGPS_countsLittle() {
        let fresh = fuse(plain, fix: BusFusion.Fix(metres: 1300, at: at(280), speed: 4), now: 300)
        let old = fuse(plain, fix: BusFusion.Fix(metres: 1300, at: at(150), speed: 4), now: 300)
        XCTAssertEqual(old.gpsWeight, 0.10, accuracy: 0.001)
        XCTAssertEqual(old.gps ?? 0, 1925, accuracy: 0.5)
        XCTAssertGreaterThan(old.metres ?? 0, 2400)              // mostly its times
        XCTAssertLessThanOrEqual(old.metres ?? 0, 2500)
        XCTAssertEqual(fresh.gpsWeight, 1)
        XCTAssertLessThan(fresh.metres ?? 0, old.metres ?? 0)
        // the stretch between its GPS and its times, more than 200 m apart
        XCTAssertEqual(old.hint?.from ?? 0, 1925, accuracy: 0.5)
        XCTAssertEqual(old.hint?.to ?? 0, 2500, accuracy: 0.5)
    }

    func test_gpsWeight_byAge() {
        XCTAssertEqual(BusFusion.gpsWeight(age: 10), 1)
        XCTAssertEqual(BusFusion.gpsWeight(age: 70), 0.575, accuracy: 0.001)
        XCTAssertEqual(BusFusion.gpsWeight(age: 120), 0.15, accuracy: 0.001)
        XCTAssertEqual(BusFusion.gpsWeight(age: 400), 0.05, accuracy: 0.001)
        XCTAssertGreaterThan(BusFusion.etaWeight(timesAge: 10, toGo: 60), BusFusion.etaWeight(timesAge: 300, toGo: 1200))
    }

    func test_noGPS_isByItsTimesAlone() {
        let e = fuse(plain, fix: nil, now: 300)
        XCTAssertEqual(e.metres ?? 0, 2500, accuracy: 0.01)
        XCTAssertNil(e.gps)
        XCTAssertEqual(BusFusion.logLine(kind: "bus", vehicle: "305·9449", e, drawn: 2500), "bus fused · 305·9449 · no gps · drawn by its times")
    }

    func test_noLiveTimes_isByItsGPSAlone() {
        let e = fuse(plain, fix: BusFusion.Fix(metres: 2100, at: at(252), speed: 5), live: false, now: 300)
        XCTAssertEqual(e.metres ?? 0, 2340, accuracy: 0.01)
        XCTAssertNil(e.eta)
        XCTAssertNil(e.hint)
    }

    func test_standingAtATimingStop_staysUntilItsDeparture() {
        // stop 2 is a timing point: it stands there 2 minutes by its timetable, leaving at 360 s
        let s = trip([(0, 0), (120, 120), (240, 360), (480, 480)])
        XCTAssertTrue(BusFusion.isTiming(s, 2))
        let e = fuse(s, fix: BusFusion.Fix(metres: 2005, at: at(250), speed: 0), now: 300)
        XCTAssertEqual(e.gps ?? 0, 2005, accuracy: 0.01)
        XCTAssertEqual(e.metres ?? 0, 2005, accuracy: 0.01)
        // on its way to it early: not on past it before its time
        XCTAssertEqual(BusFusion.ahead(s, fix: BusFusion.Fix(metres: 1500, at: at(200), speed: 8.33), now: at(300)), 2000, accuracy: 0.01)
        // a stop that isn't a timing point: on past it
        XCTAssertFalse(BusFusion.isTiming(plain, 2))
        XCTAssertEqual(BusFusion.ahead(plain, fix: BusFusion.Fix(metres: 1500, at: at(200), speed: 8.3333), now: at(300)), 2333.3, accuracy: 0.5)
    }

    func test_neverMovedOnFasterThanTheTimetableAllows() {
        // seen going 20 m/s on a piece of 8.3 m/s: 12.5 m/s at most
        XCTAssertEqual(BusFusion.ahead(plain, fix: BusFusion.Fix(metres: 2000, at: at(260), speed: 20), now: at(300)), 2500, accuracy: 0.01)
        // and for at most 3 minutes (a slow piece: 2 m/s)
        let far = trip([(0, 0), (1200, 1200), (2400, 2400)])
        XCTAssertEqual(BusFusion.ahead(far, fix: BusFusion.Fix(metres: 0, at: at(0), speed: nil), now: at(600)), 360, accuracy: 0.5)
    }

    func test_disagreeingByMoreThanAKilometre_trustsFreshGPS() {
        // its times say 2500 m; its fix, 10 s old, at 1000 m: stuck in traffic
        let e = fuse(plain, fix: BusFusion.Fix(metres: 1000, at: at(290), speed: 0), now: 300)
        XCTAssertEqual(e.note, .gpsTrusted)
        XCTAssertEqual(e.metres ?? 0, e.gps ?? -1, accuracy: 0.01)
        XCTAssertLessThan(e.metres ?? 0, 1100)
        XCTAssertTrue(BusFusion.logLine(kind: "bus", vehicle: "305·9449", e, drawn: e.metres ?? 0).hasSuffix("far apart: gps trusted"))
    }

    func test_seenFurtherOnThanItsTimes_trustsFreshGPS() {
        let e = fuse(plain, fix: BusFusion.Fix(metres: 2700, at: at(290), speed: 8.3333), now: 300)
        XCTAssertEqual(e.note, .gpsTrusted)
        XCTAssertEqual(e.metres ?? 0, 2783.3, accuracy: 0.5)
    }

    func test_aKilometreAheadOfItsTimes_isntThisJourney() {
        // its times: 1250 m; a fix at 2700 m
        let e = fuse(plain, fix: BusFusion.Fix(metres: 2700, at: at(140), speed: nil), now: 150)
        XCTAssertEqual(e.note, .gpsIgnored)
        XCTAssertEqual(e.metres ?? 0, 1250, accuracy: 0.01)
        XCTAssertEqual(BusFusion.logLine(kind: "bus", vehicle: "305·9449", e, drawn: 1250), "bus fused · 305·9449 · gps not this journey · drawn by its times")
    }

    func test_notAtYourStopByMovingItOn() {
        // an old fix 500 m before your stop, moved on: short of the stop
        let e = fuse(plain, fix: BusFusion.Fix(metres: 1500, at: at(40), speed: 8.3333), mine: 2, now: 200)
        XCTAssertLessThan(e.metres ?? 9999, 1965.01)
        XCTAssertGreaterThan(e.metres ?? 0, 1500)
    }

    func test_stopsFromPieces() {
        let p = [BusFusion.Piece(start: 0, length: 800, departure: at(0), arrival: at(100), scheduledDeparture: at(0), scheduledArrival: at(90)),
                 BusFusion.Piece(start: 800, length: 400, departure: at(110), arrival: at(160))]
        let s = BusFusion.stops(pieces: p)
        XCTAssertEqual(s.map(\.metres), [0, 800, 1200])
        XCTAssertEqual(s[1].times.at, at(100))
        XCTAssertEqual(s[1].times.leaves, at(110))
        XCTAssertEqual(s[1].times.scheduledAt, at(90))
        XCTAssertNil(s[2].times.departure)
    }

    // MARK: drawing it

    func test_glide_neverBackwards_whenItsTimeJumps() {
        var g = BusFusion.Glide()
        XCTAssertEqual(g.step(to: 1000, now: at(0), speed: 8), 1000)
        XCTAssertEqual(g.step(to: 700, now: at(1), speed: 8), 1000)      // its time got later: it waits
        XCTAssertEqual(g.step(to: 800, now: at(2), speed: 8), 1000)
        let v = g.step(to: 1010, now: at(3), speed: 8)
        XCTAssertGreaterThan(v, 1000)
        XCTAssertLessThanOrEqual(v, 1010)
    }

    func test_glide_noTeleport_whenItsTimeJumpsAhead() {
        var g = BusFusion.Glide()
        _ = g.step(to: 1000, now: at(0), speed: 8)
        XCTAssertEqual(g.step(to: 2000, now: at(1), speed: 8), 1025, accuracy: 0.01)    // 25 m/s at most
        XCTAssertEqual(g.step(to: 2000, now: at(2), speed: 8), 1050, accuracy: 0.01)
        // the same moment again: no move
        XCTAssertEqual(g.step(to: 2000, now: at(2), speed: 8), 1050, accuracy: 0.01)
    }

    func test_glide_maxSpeed_isOneAndAHalfTimesItsSpeed_whenThatsMore() {
        var g = BusFusion.Glide()
        _ = g.step(to: 1000, now: at(0), speed: 20)
        XCTAssertEqual(g.step(to: 3000, now: at(1), speed: 20), 1030, accuracy: 0.01)
        // a step counts for 5 s at most
        XCTAssertEqual(g.step(to: 3000, now: at(11), speed: 20), 1180, accuracy: 0.01)
    }

    func test_glide_easesIn_andKeepsUpAtItsSpeed() {
        var g = BusFusion.Glide()
        _ = g.step(to: 1000, now: at(0), speed: 0)
        XCTAssertEqual(g.step(to: 1010, now: at(1), speed: 0), 1000 + 10 * (1 - exp(-0.5)), accuracy: 0.01)
        var h = BusFusion.Glide()
        _ = h.step(to: 1000, now: at(0), speed: 8)
        XCTAssertEqual(h.step(to: 1010, now: at(1), speed: 8), 1008, accuracy: 0.01)
        XCTAssertEqual(h.step(to: 1010, now: at(2), speed: 8), 1010, accuracy: 0.01)    // never past where it is
    }

    func test_glide_back_onAFreshFixBehind_overThreeSeconds() {
        var g = BusFusion.Glide()
        _ = g.step(to: 2000, now: at(0), speed: 8, fixAt: at(-30), fixAge: 30)
        XCTAssertEqual(g.step(to: 1700, now: at(1), speed: 8, fixAt: at(-4), fixAge: 5), 2000, accuracy: 0.01)
        XCTAssertEqual(g.step(to: 1700, now: at(2), speed: 8, fixAt: at(-4), fixAge: 6), 1900, accuracy: 0.01)
        XCTAssertEqual(g.step(to: 1700, now: at(3), speed: 8, fixAt: at(-4), fixAge: 7), 1800, accuracy: 0.01)
        XCTAssertEqual(g.step(to: 1700, now: at(4), speed: 8, fixAt: at(-4), fixAge: 8), 1700, accuracy: 0.01)
        XCTAssertGreaterThan(g.step(to: 1720, now: at(5), speed: 8, fixAt: at(-4), fixAge: 9), 1700)
    }

    func test_glide_notBack_forAnOldFix_orALittle() {
        var g = BusFusion.Glide()
        _ = g.step(to: 2000, now: at(0), speed: 8, fixAt: at(-30), fixAge: 30)
        XCTAssertEqual(g.step(to: 1700, now: at(1), speed: 8, fixAt: at(-100), fixAge: 101), 2000)     // old
        XCTAssertEqual(g.step(to: 1900, now: at(2), speed: 8, fixAt: at(-1), fixAge: 3), 2000)        // 100 m: waits
        // the same fix again proves nothing new
        XCTAssertEqual(g.step(to: 1700, now: at(3), speed: 8, fixAt: at(-1), fixAge: 4), 2000)
    }

    func test_glide_startsAgain_afterAPause() {
        var g = BusFusion.Glide()
        _ = g.step(to: 1000, now: at(0), speed: 8)
        XCTAssertEqual(g.step(to: 3000, now: at(60), speed: 8), 3000)
        g.reset()
        XCTAssertEqual(g.step(to: 500, now: at(61), speed: 8), 500)
    }

    func test_signedMetres() {
        XCTAssertEqual(BusFusion.signed(318), "+320 m")
        XCTAssertEqual(BusFusion.signed(-84), "-80 m")
        XCTAssertEqual(BusFusion.signed(0), "+0 m")
    }
}
