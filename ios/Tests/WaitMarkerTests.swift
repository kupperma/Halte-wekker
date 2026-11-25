import XCTest

final class WaitMarkerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 7_000_000)
    private func at(_ min: Double) -> Date { now.addingTimeInterval(min * 60) }

    func test_onItsWay_closeAndDueSoon_isDrawnWhereItIs() {
        let s = WaitMarker.place(drawn: 1960, byTime: 1950, mine: 2000, mineIsFirst: false, started: true, gpsRaw: 1960,
                                 waitingByTimes: false, eta: at(1), now: now)
        XCTAssertEqual(s, WaitMarker.Shown(metres: 1960, label: .none))
    }

    func test_farFromTheStop_isLeftAlone() {
        let s = WaitMarker.place(drawn: 400, byTime: 500, mine: 2000, mineIsFirst: false, started: true, gpsRaw: 400,
                                 waitingByTimes: false, eta: at(9), now: now)
        XCTAssertEqual(s.metres, 400)
    }

    func test_gpsOfThePreviousJourneyAtYourStop_butDueIn12Min_goesWhereItsTimesPutIt() {
        // the vehicle is still finishing the journey before, which ends right by your stop
        let s = WaitMarker.place(drawn: 2000, byTime: 600, mine: 2000, mineIsFirst: false, started: true, gpsRaw: 2005,
                                 waitingByTimes: false, eta: at(12), now: now)
        XCTAssertEqual(s, WaitMarker.Shown(metres: 600, label: .none))
    }

    func test_movedOnTooFar_fromAnOldFix_isPulledBack() {
        let s = WaitMarker.place(drawn: 1965, byTime: 900, mine: 2000, mineIsFirst: false, started: true, gpsRaw: 1500,
                                 waitingByTimes: false, eta: at(6), now: now)
        XCTAssertEqual(s.metres, 900)
    }

    func test_layoverAtTheTerminus_thatIsYourStop_withItsGPSThere_saysWaiting() {
        let s = WaitMarker.place(drawn: 0, byTime: 0, mine: 0, mineIsFirst: true, started: false, gpsRaw: 10,
                                 waitingByTimes: false, eta: at(14), now: now)
        XCTAssertEqual(s, WaitMarker.Shown(metres: 0, label: .waiting(leaves: at(14))))
        XCTAssertEqual(WaitMarker.text(s.label, clock: { _ in "17:42" }), "Waiting · leaves 17:42")
    }

    func test_beforeItsTripStarts_withoutAFix_atYourFirstStop_isntDrawn() {
        let s = WaitMarker.place(drawn: 0, byTime: 0, mine: 0, mineIsFirst: true, started: false, gpsRaw: nil,
                                 waitingByTimes: false, eta: at(14), now: now)
        XCTAssertEqual(s, WaitMarker.Shown(metres: nil, label: .none))
    }

    func test_fixElsewhere_atTheFirstStop_isntDrawnThere() {
        let s = WaitMarker.place(drawn: 0, byTime: 0, mine: 0, mineIsFirst: true, started: false, gpsRaw: 400,
                                 waitingByTimes: false, eta: at(10), now: now)
        XCTAssertNil(s.metres)
    }

    func test_standingAtATimingStop_byItsTimes_saysWaiting() {
        let s = WaitMarker.place(drawn: 2000, byTime: 2000, mine: 2000, mineIsFirst: false, started: true, gpsRaw: nil,
                                 waitingByTimes: true, eta: at(4), now: now)
        XCTAssertEqual(s.label, .waiting(leaves: at(4)))
    }

    func test_dueWithinTwoMinutes_atTheStop_isAtTheStop() {
        let s = WaitMarker.place(drawn: 2000, byTime: 2000, mine: 2000, mineIsFirst: false, started: true, gpsRaw: 1995,
                                 waitingByTimes: false, eta: at(1.5), now: now)
        XCTAssertEqual(s, WaitMarker.Shown(metres: 2000, label: .none))
    }

    func test_timesCloseToo_butETAFar_isJustShortOfTheStop() {
        let s = WaitMarker.place(drawn: 1990, byTime: 1900, mine: 2000, mineIsFirst: false, started: true, gpsRaw: nil,
                                 waitingByTimes: false, eta: at(5), now: now)
        XCTAssertEqual(s.metres, 1850)
    }
}
