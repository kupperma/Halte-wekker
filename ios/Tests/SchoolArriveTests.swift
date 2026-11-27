import XCTest

/// The rules of 0.42.6: "Be there at …" per day, and never ringing when you're already on the way. The same vectors as
/// Android's `SchoolArriveTest` (minutes after 2026-11-27 00:00 UTC, clock in UTC).
final class SchoolArriveTests: XCTestCase {
    private let base: Double = 1_795_737_600          // 2026-11-27 00:00 UTC
    private let day = "2026-11-27"
    private func t(_ m: Double) -> Date { Date(timeIntervalSince1970: base + m * 60) }
    private func hm(_ h: Double, _ m: Double) -> Date { t(h * 60 + m) }
    private func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    // MARK: be there at

    func test_beThereIsTheTimetablesUnlessChanged() {
        let cls = hm(11, 0)
        XCTAssertEqual(SchoolArrive.timetable(classStart: cls, early: 10), hm(10, 50))
        XCTAssertEqual(SchoolArrive.beThere(classStart: cls, early: 10, override: nil), hm(10, 50))
        XCTAssertEqual(SchoolArrive.beThere(classStart: cls, early: 10, override: hm(9, 0)), hm(9, 0))
    }

    func test_quickChoicesFromTheTimetable() {
        let tt = hm(10, 50)
        XCTAssertEqual(SchoolArrive.quick(.hourEarlier, timetable: tt), hm(9, 50))
        XCTAssertEqual(SchoolArrive.quick(.twoHoursEarlier, timetable: tt), hm(8, 50))
        XCTAssertEqual(SchoolArrive.quick(.halfHourLater, timetable: tt), hm(11, 20))
        XCTAssertEqual(SchoolArrive.Quick.allCases.map(\.title), ["1 h earlier", "2 h earlier", "30 min later"])
    }

    func test_normalizedWholeMinutesNotTheTimetablesOwnNotAnotherDay() {
        let tt = hm(10, 50), cls = hm(11, 0)
        XCTAssertEqual(SchoolArrive.normalized(t(540.5), timetable: tt, classStart: cls), hm(9, 0))
        XCTAssertNil(SchoolArrive.normalized(hm(10, 50), timetable: tt, classStart: cls))
        XCTAssertNil(SchoolArrive.normalized(hm(23, 30), timetable: tt, classStart: cls))
        XCTAssertEqual(SchoolArrive.normalized(hm(22, 0), timetable: tt, classStart: cls), hm(22, 0))
    }

    func test_changesExpireAfterTheirDay() {
        let o: [String: Date] = ["2026-11-26": hm(9, 0), "2026-11-27": hm(9, 0), "2026-11-28": hm(8, 0)]
        XCTAssertEqual(Set(SchoolArrive.prune(o, today: day).keys), ["2026-11-27", "2026-11-28"])
        XCTAssertEqual(Set(SchoolArrive.prune(o, today: "2026-11-29").keys), [])
    }

    func test_wordsAndTheAlarmsLabel() {
        XCTAssertEqual(SchoolArrive.changedLine(beThere: hm(9, 0), classStart: hm(11, 0), clock: clock), "Changed: be there 09:00 (class 11:00)")
        let same = SchoolArrive.alarmText(leave: hm(9, 40), classStart: hm(11, 0), beThere: hm(10, 50), changed: false, clock: clock)
        XCTAssertEqual(same.title, "Time to get up")
        XCTAssertEqual(same.body, "Leave 09:40 for your 11:00 class")
        let moved = SchoolArrive.alarmText(leave: hm(7, 50), classStart: hm(11, 0), beThere: hm(9, 0), changed: true, clock: clock)
        XCTAssertEqual(moved.title, "Time to get up · be there 09:00")
        XCTAssertEqual(moved.body, "Leave 07:50 to be there 09:00 (class 11:00)")
    }

    func test_noAnswerAfterAChangeMovesTheOldTrip() {
        XCTAssertEqual(SchoolArrive.shiftedLeave(oldLeave: hm(9, 40), oldBeThere: hm(10, 50), newBeThere: hm(8, 50)), hm(7, 40))
        XCTAssertEqual(SchoolArrive.shiftedLeave(oldLeave: hm(9, 40), oldBeThere: hm(10, 50), newBeThere: hm(11, 20)), hm(10, 10))
    }

    // MARK: never ring when you're already going

    private func decide(_ seen: OnTheWay.Seen, _ live: OnTheWay.Live = OnTheWay.Live(), alarm: Date? = nil, now: Date? = nil, day d: String? = nil) -> OnTheWay.Decision {
        OnTheWay.decide(day: d ?? day, today: day, alarm: alarm ?? hm(8, 40), now: now ?? hm(7, 30), morning: hm(3, 0), seen: seen, live: live)
    }

    func test_aNormalMorningRings() {
        XCTAssertEqual(decide(OnTheWay.Seen(day: day)), .ring)
        var live = OnTheWay.Live(); live.homeMetres = 20; live.fixAt = hm(7, 29)
        XCTAssertEqual(decide(OnTheWay.Seen(day: day), live), .ring)
    }

    func test_aTripToSchoolSkips() {
        var s = OnTheWay.Seen(day: day); s.tripAt = hm(7, 12); s.schoolTripAt = hm(7, 12)
        var live = OnTheWay.Live(); live.running = true; live.runningToSchool = true
        XCTAssertEqual(decide(s, live), .skip(.onTheWay(trip: hm(7, 12))))
        XCTAssertEqual(OnTheWay.words(.onTheWay(trip: hm(7, 12)), clock: clock), "already on the way (trip 07:12)")
        XCTAssertEqual(OnTheWay.logLine(.onTheWay(trip: hm(7, 12)), clock: clock), "school alarm · skipped: already on the way (trip 07:12)")
        // still at the home stop, 300 m from home, on it: skipped
        live.homeMetres = 300; live.fixAt = hm(7, 29)
        XCTAssertEqual(decide(s, live), .skip(.onTheWay(trip: hm(7, 12))))
        // it ended and you're back home: rings
        let home = OnTheWay.Live(running: false, runningToSchool: false, homeMetres: 200, fixAt: hm(7, 25))
        XCTAssertEqual(decide(s, home), .ring)
        // it ended, no fresh fix: still skipped
        XCTAssertEqual(decide(s), .skip(.onTheWay(trip: hm(7, 12))))
    }

    func test_atSchoolSkips() {
        var s = OnTheWay.Seen(day: day); s.atSchool = hm(7, 20)
        XCTAssertEqual(decide(s), .skip(.atSchool(hm(7, 20))))
        XCTAssertEqual(OnTheWay.words(.atSchool(hm(7, 20)), clock: clock), "already at school (07:20)")
    }

    func test_leftHomeWithARideSkips() {
        // the field report: meeting friends first, two hours early, a trip elsewhere
        var s = OnTheWay.Seen(day: day); s.tripAt = hm(6, 30); s.leftHome = hm(6, 25)
        XCTAssertEqual(decide(s), .skip(.onTheWay(trip: hm(6, 30))))
        // a stale fix near home doesn't hold it
        XCTAssertEqual(decide(s, OnTheWay.Live(homeMetres: 100, fixAt: hm(6, 50))), .skip(.onTheWay(trip: hm(6, 30))))
        // back home (a fresh fix 100 m away): rings
        XCTAssertEqual(decide(s, OnTheWay.Live(homeMetres: 100, fixAt: hm(7, 28))), .ring)
        // no region exit, but 2.5 km away
        var far = OnTheWay.Seen(day: day); far.tripAt = hm(6, 30)
        XCTAssertEqual(decide(far, OnTheWay.Live(homeMetres: 2500, fixAt: hm(7, 26))), .skip(.onTheWay(trip: hm(6, 30))))
        // 600 m away only: not clearly gone
        XCTAssertEqual(decide(far, OnTheWay.Live(homeMetres: 600, fixAt: hm(7, 26))), .ring)
    }

    func test_movingAroundAtHomeNeverSkips() {
        // left home's region and 2 km away, but no trip or ride: rings
        var s = OnTheWay.Seen(day: day); s.leftHome = hm(7, 0)
        XCTAssertEqual(decide(s, OnTheWay.Live(homeMetres: 2000, fixAt: hm(7, 29))), .ring)
        // a trip, no exit, no position: rings
        var t = OnTheWay.Seen(day: day); t.tripAt = hm(7, 0)
        XCTAssertEqual(decide(t), .ring)
    }

    func test_onlyThisMorningAndOnlyAnAlarmStillToRing() {
        // a trip last night (before 03:00) doesn't count; one not started yet neither
        var night = OnTheWay.Seen(day: day); night.schoolTripAt = hm(2, 0); night.tripAt = hm(2, 0); night.leftHome = hm(1, 55)
        XCTAssertEqual(decide(night), .ring)
        var later = OnTheWay.Seen(day: day); later.schoolTripAt = hm(7, 40)
        XCTAssertEqual(decide(later), .ring)
        var s = OnTheWay.Seen(day: day); s.schoolTripAt = hm(7, 12)
        // it rang already: left alone; no alarm; another day; yesterday's record
        XCTAssertEqual(decide(s, alarm: hm(7, 0)), .ring)
        XCTAssertEqual(OnTheWay.decide(day: day, today: day, alarm: nil, now: hm(7, 30), morning: hm(3, 0), seen: s, live: OnTheWay.Live()), .ring)
        XCTAssertEqual(decide(s, day: "2026-11-28"), .ring)
        var old = s; old.day = "2026-11-26"
        XCTAssertEqual(decide(old), .ring)
    }

    func test_whereTheTripGoesAndBeingAtSchool() {
        XCTAssertTrue(OnTheWay.towardSchool(lastStopMetres: nil, fixedToSchool: true))
        XCTAssertTrue(OnTheWay.towardSchool(lastStopMetres: 1200, fixedToSchool: false))
        XCTAssertFalse(OnTheWay.towardSchool(lastStopMetres: 1600, fixedToSchool: false))
        XCTAssertFalse(OnTheWay.towardSchool(lastStopMetres: nil, fixedToSchool: false))
        XCTAssertTrue(OnTheWay.atSchool(metres: 350, fixAt: hm(7, 28), now: hm(7, 30)))
        XCTAssertFalse(OnTheWay.atSchool(metres: 350, fixAt: hm(7, 10), now: hm(7, 30)))
        XCTAssertFalse(OnTheWay.atSchool(metres: 450, fixAt: hm(7, 28), now: hm(7, 30)))
        XCTAssertFalse(OnTheWay.atSchool(metres: nil, fixAt: nil, now: hm(7, 30)))
    }

    func test_aNewDayStartsANewRecord() {
        var s = OnTheWay.Seen(day: "2026-11-26"); s.tripAt = hm(7, 0)
        XCTAssertEqual(OnTheWay.fresh(s, day: day), OnTheWay.Seen(day: day))
        var k = OnTheWay.Seen(day: day); k.tripAt = hm(7, 0)
        XCTAssertEqual(OnTheWay.fresh(k, day: day), k)
        XCTAssertEqual(OnTheWay.fresh(nil, day: day), OnTheWay.Seen(day: day))
        XCTAssertEqual(Set(OnTheWay.prune(["2026-11-26": "a", "2026-11-27": "b"], today: day).keys), ["2026-11-27"])
    }
}
