import XCTest

/// 0.42.3, synthetic data shaped like a field log:
/// (2) the alarm rang 30 s into a first leg only 530 m long (a bus hop to the station) (`ShortLeg`);
/// (3) on the planned train at the change, the leg started as "wrong way" and asked for a pick of that same train
///     (`RideGuards.plannedNextAmong`);
/// (4) a bus without GPS at night: which key found nothing in OVapi's feed, and whether its journey had begun
///     (`RealPositions.noMatchReason`).
final class ShortLegTests: XCTestCase {

    // MARK: (2) a leg shorter than its wake

    func test_2_aShortHopIsShort_aNormalLegIsNot() {
        XCTAssertTrue(ShortLeg.isShort(spanMetres: 530, wakeMetres: 1000))
        XCTAssertTrue(ShortLeg.isShort(spanMetres: 700, wakeMetres: 400), "under 800 m is a hop whatever the wake")
        XCTAssertFalse(ShortLeg.isShort(spanMetres: 5200, wakeMetres: 1000))
        XCTAssertFalse(ShortLeg.isShort(spanMetres: 1200, wakeMetres: 1000))
        XCTAssertFalse(ShortLeg.isShort(spanMetres: nil, wakeMetres: 1000), "not known: a normal leg")
        XCTAssertFalse(ShortLeg.isShort(spanMetres: .nan, wakeMetres: 1000))
    }

    func test_2_theFirstFix30sIntoA530mLeg_doesNotRing() {
        XCTAssertEqual(ShortLeg.onFire(legAge: 30, short: true), .quiet)
        XCTAssertEqual(ShortLeg.onFire(legAge: 300, short: true), .quiet, "a short leg never rings at the wake rule")
    }

    func test_2_aNormalLegStillRings_butNotInItsFirstMinute() {
        XCTAssertEqual(ShortLeg.onFire(legAge: 10, short: false), .quiet, "inside its wake distance from the start, as before")
        XCTAssertEqual(ShortLeg.onFire(legAge: 30, short: false), .wait)
        XCTAssertEqual(ShortLeg.onFire(legAge: 59, short: false), .wait)
        XCTAssertEqual(ShortLeg.onFire(legAge: 60, short: false), .ring)
        XCTAssertEqual(ShortLeg.onFire(legAge: 900, short: false), .ring)
    }

    func test_2_theQuietWordBeforeTheStop() {
        XCTAssertFalse(ShortLeg.noticeDue(legAge: 30, told: false, beforeReached: true, secondsLeft: 40, metres: 200, startedMetres: 530),
                       "never in the first minute")
        XCTAssertTrue(ShortLeg.noticeDue(legAge: 70, told: false, beforeReached: true, secondsLeft: 200, metres: 400, startedMetres: 530))
        XCTAssertTrue(ShortLeg.noticeDue(legAge: 70, told: false, beforeReached: false, secondsLeft: 80, metres: 400, startedMetres: 530))
        XCTAssertFalse(ShortLeg.noticeDue(legAge: 70, told: false, beforeReached: false, secondsLeft: 200, metres: 100, startedMetres: 530),
                       "its times say not yet")
        XCTAssertTrue(ShortLeg.noticeDue(legAge: 70, told: false, beforeReached: false, secondsLeft: nil, metres: 250, startedMetres: 530),
                      "no times: halfway")
        XCTAssertFalse(ShortLeg.noticeDue(legAge: 70, told: false, beforeReached: false, secondsLeft: nil, metres: 400, startedMetres: 530))
        XCTAssertFalse(ShortLeg.noticeDue(legAge: 70, told: true, beforeReached: true, secondsLeft: 10, metres: 10, startedMetres: 530), "once")
        let w = ShortLeg.words(stop: "Station")
        XCTAssertEqual(w.title, "Get off at the next stop")
        XCTAssertEqual(w.body, "Station is next. A short ride: this is your reminder, no alarm.")
    }

    func test_2_aShortLegIsntThereOnItsFirstFix() {
        XCTAssertEqual(ShortLeg.arriveMetres(startedMetres: 380), 200)
        XCTAssertEqual(ShortLeg.arriveMetres(startedMetres: 530), 265)
        XCTAssertEqual(ShortLeg.arriveMetres(startedMetres: 2000), 450)
        XCTAssertEqual(ShortLeg.arriveMetres(startedMetres: nil), 450)
        XCTAssertFalse(ShortLeg.mayArrive(legAge: 20, metres: 100, startedMetres: 380), "just got on")
        XCTAssertFalse(ShortLeg.mayArrive(legAge: 90, metres: 300, startedMetres: 380))
        XCTAssertTrue(ShortLeg.mayArrive(legAge: 90, metres: 150, startedMetres: 380))
    }

    // MARK: (3) on the planned train at the change

    func test_3_onThePlannedNextRide_isTheNextLeg_notWrongWay() {
        let onRoad = ["ic-other-5400", "ic-planned-8400", "bus-4"]
        XCTAssertEqual(RideGuards.plannedNextAmong(onRoad, plannedNext: "ic-planned-8400"), "ic-planned-8400")
        XCTAssertNil(RideGuards.plannedNextAmong(onRoad, plannedNext: "ic-elsewhere"), "another train: plan again from it, as before")
        XCTAssertNil(RideGuards.plannedNextAmong(onRoad, plannedNext: nil), "nothing planned for the next leg")
        XCTAssertNil(RideGuards.plannedNextAmong(onRoad, plannedNext: ""))
        XCTAssertNil(RideGuards.plannedNextAmong([], plannedNext: "ic-planned-8400"))
    }

    // MARK: (4) which OVapi key found nothing

    private func dutch(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return c.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    func test_4_theKeyIsOVapisOwnTripId() {
        XCTAssertEqual(RealPositions.key("20261201_22:40_nl-OpenOV_400100123"), "400100123")
        XCTAssertNil(RealPositions.key("20261201_22:40_nl-other_123"))
        XCTAssertEqual(RealPositions.dataset("20261201_22:40_nl-OpenOV_400100123"), "nl-OpenOV")
        XCTAssertNil(RealPositions.dataset("no-date-here"))
    }

    func test_4_noMatch_saysWhichKeyAndWhetherItHadStarted() {
        let id = "20261201_22:40_nl-OpenOV_400100123"
        XCTAssertEqual(RealPositions.noMatchReason(id, key: "400100123", now: dutch(2026, 12, 1, 23, 5)),
                       "no ovapi match for trip_id 400100123 (started 22:40)")
        XCTAssertEqual(RealPositions.noMatchReason(id, key: "400100123", now: dutch(2026, 12, 1, 22, 30)),
                       "no ovapi match for trip_id 400100123: not started yet, starts 22:40")
        XCTAssertEqual(RealPositions.noMatchReason("odd-id", key: "77", now: dutch(2026, 12, 1, 22, 30)), "no ovapi match for trip_id 77")
    }

    func test_4_aNightTripPastMidnightStartsTheNextDay() {
        let s = RealPositions.startTime("20261201_24:10_nl-OpenOV_400100200")
        XCTAssertEqual(s?.text, "24:10")
        XCTAssertEqual(s?.at, dutch(2026, 12, 2, 0, 10))
        XCTAssertNil(RealPositions.startTime("20261201_xx_nl-OpenOV_1"))
    }
}
