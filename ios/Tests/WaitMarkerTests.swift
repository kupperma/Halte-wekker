import XCTest

/// The bus you wait for at your stop (0.40's `WaitMarker` cases, 0.40.1: by `BusFusion`): not drawn at your stop by
/// GPS that can't be this journey, "Waiting · leaves 17:42" only when its own fresh fix stands there before it leaves.
final class WaitMarkerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 7_000_000)
    private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    /// Stops every 1000 m; `times[i]`: (arrives, leaves), s after `t0` (live as the timetable).
    private func trip(_ times: [(Double, Double)]) -> [BusFusion.Stop] {
        var out: [BusFusion.Stop] = []
        for i in times.indices {
            let st = StopTimes(arrival: i == 0 ? nil : at(times[i].0), departure: at(times[i].1),
                               scheduledArrival: i == 0 ? nil : at(times[i].0), scheduledDeparture: at(times[i].1))
            out.append(BusFusion.Stop(metres: Double(i) * 1000, times: st))
        }
        return out
    }

    private func fuse(_ s: [BusFusion.Stop], fix: BusFusion.Fix?, mine: Int, now: Double) -> BusFusion.Estimate {
        BusFusion.fuse(BusFusion.Input(stops: s, fix: fix, live: true, timesAt: at(now), mine: mine, now: at(now)))
    }

    /// Its trip leaves its first stop in 14 minutes.
    private var later: [BusFusion.Stop] { trip([(840, 840), (960, 960), (1080, 1080)]) }
    private var plain: [BusFusion.Stop] { trip([(0, 0), (120, 120), (240, 240), (360, 360)]) }

    func test_layoverAtTheTerminus_thatIsYourStop_withItsGPSThere_saysWaiting() {
        let e = fuse(later, fix: BusFusion.Fix(metres: 10, at: at(-20)), mine: 0, now: 0)
        XCTAssertEqual(e.metres, 0)
        XCTAssertEqual(e.waiting, at(840))
        XCTAssertEqual(BusFusion.waitingText(leaves: at(840), clock: { _ in "17:42" }), "Waiting · leaves 17:42")
    }

    func test_beforeItsTripStarts_withoutAFix_atYourFirstStop_isntDrawn() {
        let e = fuse(later, fix: nil, mine: 0, now: 0)
        XCTAssertNil(e.metres)
        XCTAssertNil(e.waiting)
    }

    func test_fixElsewhere_beforeItsTripStarts_isItsJourneyBefore() {
        let e = fuse(later, fix: BusFusion.Fix(metres: 400, at: at(-20)), mine: 0, now: 0)
        XCTAssertEqual(e.note, .gpsIgnored)
        XCTAssertNil(e.metres)
    }

    func test_gpsOfThePreviousJourneyAtYourStop_butDueInMinutes_goesWhereItsTimesPutIt() {
        // its times: 600 m; a fresh fix right at your stop (2000 m), 1.4 km ahead of them
        let e = fuse(plain, fix: BusFusion.Fix(metres: 2005, at: at(62)), mine: 2, now: 72)
        XCTAssertEqual(e.note, .gpsIgnored)
        XCTAssertEqual(e.metres ?? 0, 600, accuracy: 0.01)
        XCTAssertNil(e.waiting)
    }

    func test_standingAtYourStop_byAFreshFix_beforeItLeaves_saysWaiting() {
        // a timing point: there at 240 s, leaving at 480 s
        let s = trip([(0, 0), (120, 120), (240, 480), (600, 600)])
        let e = fuse(s, fix: BusFusion.Fix(metres: 1995, at: at(225), speed: 0), mine: 2, now: 240)
        XCTAssertEqual(e.metres, 2000)
        XCTAssertEqual(e.waiting, at(480))
    }

    func test_standingAtYourStop_byAnOldFix_saysNothing() {
        let s = trip([(0, 0), (120, 120), (240, 480), (600, 600)])
        let e = fuse(s, fix: BusFusion.Fix(metres: 1995, at: at(90), speed: 0), mine: 2, now: 240)
        XCTAssertNil(e.waiting)
        XCTAssertLessThanOrEqual(e.metres ?? 9999, 2000)
    }

    func test_atYourStop_leavingWithinAMinute_isntWaiting() {
        let s = trip([(0, 0), (120, 120), (240, 280), (600, 600)])
        let e = fuse(s, fix: BusFusion.Fix(metres: 1995, at: at(235), speed: 0), mine: 2, now: 240)
        XCTAssertNil(e.waiting)
        XCTAssertEqual(e.metres ?? 0, 1996, accuracy: 2)
    }

    func test_onItsWay_closeAndDueSoon_isDrawnWhereItIs() {
        // its times: 1917 m (10 s from your stop); its fix 5 s old at 1900 m
        let e = fuse(plain, fix: BusFusion.Fix(metres: 1900, at: at(225), speed: 8.3333), mine: 2, now: 230)
        XCTAssertEqual(e.metres ?? 0, 1925, accuracy: 15)
        XCTAssertLessThan(e.metres ?? 9999, 1965.01)
    }
}
