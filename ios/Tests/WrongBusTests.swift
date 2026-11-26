import XCTest

/// 0.39.1: the evening of the field report (25 November, synthetic data shaped like it): at 's-Hertogenbosch station
/// the board said "306 in 2 min, 154 in 10 min"; the 154 came, was taken for the 306, and went to Schijndel. One test
/// per thing that went wrong:
/// (a) "You'll miss the 17:21" while the late one was still coming (`MissRule`, `ChangeGuide`);
/// (b) a leg started by the timetable of a bus that left 11 minutes later (`TimetableStart`);
/// (c) the planned bus kept while its own GPS was 1.7 km from you and the other one's fitted (`VehicleMatch.choose`);
/// (d) nobody said it was the wrong bus (`WrongBus`);
/// (e) nobody said the 154 at the stop wasn't yours (`OtherAtStop`);
/// (f) the wrong bus learned as your usual line, and the moment you left by live times alone (`UsualLine`, `DepartMatch`).
final class WrongBusTests: XCTestCase {
    private let t0 = Fx.t0
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    private func hhmm(_ d: Date) -> String { "+\(Int(d.timeIntervalSince(t0) / 60))" }
    private func bus(_ id: String, _ line: String, _ s: TimeInterval, walk: Int = 2) -> ChangeGuide.Ride {
        ChangeGuide.Ride(tripId: id, line: line, isTrain: false, departure: at(s), platform: "B", walk: walk)
    }

    // MARK: (a) a miss at the change

    func test_a_atTheChange_notMissedBeforeItsLiveDeparture() {
        // 08:13:29 at the change, 160 m from the stop, the 08:14 in 31 s: you can still make it (and did)
        let next = ChangeGuide.Ride(tripId: "ic-0103", line: "IC", isTrain: true, departure: at(31), platform: "4", walk: 3)
        let g = ChangeGuide.guide(arrive: at(-600), arrivePlatform: nil, fromTrain: false, grade: nil, next: next, later: [],
                                  learned: 4, now: at(0), hhmm: hhmm, atChange: true)
        XCTAssertFalse(g.missed)
        XCTAssertNil(g.missText)
        // (0.39 said "You’ll miss" here: under the room the walk needs, counted from now; 0.42.3 on the way without a
        // ride instead from the change: tight, run)
        let old = ChangeGuide.guide(arrive: at(-600), arrivePlatform: nil, fromTrain: false, grade: nil, next: next, later: [],
                                    learned: 4, now: at(0), hhmm: hhmm)
        XCTAssertFalse(old.missed)
        XCTAssertEqual(old.call, .tight)
    }

    func test_a_theLateBusAtItsLiveTime_isStillComing() {
        // the 306 of 17:21 leaves at 17:24 by its live time; at 17:22:27 nothing is missed
        let live = bus("306-0600", "306", 180)
        let g = ChangeGuide.guide(arrive: at(-480), arrivePlatform: nil, fromTrain: true, grade: nil, next: live,
                                  later: [bus("305-0553", "305", 14 * 60)], learned: nil, now: at(87), hhmm: hhmm, atChange: true)
        XCTAssertFalse(g.missed)
        XCTAssertEqual(g.target.tripId, "306-0600")
    }

    func test_a_goneWithoutYou_isMissed_unlessItsGPSHasItBeforeTheStop() {
        // its live time 17:21 gone by 87 s, you still at the change: (0.42.3) only "may have left" for 3 minutes
        let next = bus("306-0600", "306", 0)
        let later = [bus("305-0553", "305", 14 * 60)]
        let maybe = ChangeGuide.guide(arrive: at(-480), arrivePlatform: nil, fromTrain: true, grade: nil, next: next, later: later,
                                      learned: nil, now: at(87), hhmm: hhmm, atChange: true)
        XCTAssertFalse(maybe.missed)
        XCTAssertEqual(maybe.call, .maybe)
        XCTAssertNil(maybe.missText)
        let gone = ChangeGuide.guide(arrive: at(-480), arrivePlatform: nil, fromTrain: true, grade: nil, next: next, later: later,
                                     learned: nil, now: at(190), hhmm: hhmm, atChange: true)
        XCTAssertTrue(gone.missed)
        XCTAssertEqual(gone.missText, "You’ll miss the +0 — take bus 305 at +14")
        // its own GPS still before the stop: late beyond its live time, still coming
        let coming = ChangeGuide.guide(arrive: at(-480), arrivePlatform: nil, fromTrain: true, grade: nil, next: next, later: later,
                                       learned: nil, now: at(190), hhmm: hhmm, atChange: true, notLeft: true)
        XCTAssertFalse(coming.missed)
        // within the minute's grace: not yet
        XCTAssertFalse(MissRule.missed(arrive: at(-480), departure: at(0), need: 2, now: at(50), atChange: true, notLeft: false))
    }

    func test_a_onTheWay_theLiveArrivalAndTheRoomStillDecide() {
        // in at +10 (live), the bus at +11 with a 3 min walk: missed before you're there, whatever its GPS says
        XCTAssertTrue(MissRule.missed(arrive: at(600), departure: at(660), need: 3, now: at(0), atChange: false, notLeft: true))
        XCTAssertFalse(MissRule.missed(arrive: at(600), departure: at(900), need: 3, now: at(0), atChange: false, notLeft: false))
    }

    func test_a_notLeft_byItsOwnGPS() {
        XCTAssertTrue(MissRule.notLeft(vehicleMetres: 1800, stopMetres: 2000, fixAge: 30), "200 m before the stop")
        XCTAssertTrue(MissRule.notLeft(vehicleMetres: 2030, stopMetres: 2000, fixAge: 30), "at it")
        XCTAssertFalse(MissRule.notLeft(vehicleMetres: 2150, stopMetres: 2000, fixAge: 30), "past it")
        XCTAssertFalse(MissRule.notLeft(vehicleMetres: 1800, stopMetres: 2000, fixAge: 400), "an old fix says nothing")
        XCTAssertFalse(MissRule.notLeft(vehicleMetres: nil, stopMetres: 2000, fixAge: 30))
    }

    // MARK: (b) by its timetable

    func test_b_neverByItsTimetableLongBeforeItLeaves() {
        let dep = at(35 * 60)                       // the 305 at 17:35
        XCTAssertFalse(TimetableStart.allowed(now: at(24 * 60 + 39), departure: dep), "17:24:39, 11 min before")
        XCTAssertTrue(TimetableStart.allowed(now: at(33 * 60 + 30), departure: dep), "90 s before")
        XCTAssertTrue(TimetableStart.allowed(now: at(40 * 60), departure: dep))
        XCTAssertFalse(TimetableStart.allowed(now: at(56 * 60), departure: dep), "21 min after: another one")
        XCTAssertEqual(TimetableStart.waitLine(label: "bus 305·0551", leaves: "17:35", minutes: 11),
                       "wait · not by its timetable: bus 305·0551 leaves 17:35 (in 11 min) · finding the one you're on")
    }

    // MARK: (c) the planned one far by its own GPS

    private func j(_ id: String, _ line: String, gps: Bool, _ r: Result<Double, Reject>, offset: Double = 0, cross: Double = 8,
                   train: Bool = false) -> Judgement {
        var e = Evidence(fixes: 15, span: 28, crossTrack: cross, accuracy: 15, shaped: true, progress: 300, offset: offset,
                         drift: 0, yourSpeed: 11, itsSpeed: 11, steady: true)
        e.gps = gps
        return Judgement(id: id, line: line, isTrain: train, realTime: true, evidence: e, result: r)
    }

    func test_c_farByGPS() {
        XCTAssertTrue(VehicleMatch.farByGPS(j("305-0551", "305", gps: true, .failure(.tooFarFromTimes), offset: 1683)))
        XCTAssertFalse(VehicleMatch.farByGPS(j("305-0551", "305", gps: true, .failure(.tooFarFromTimes), offset: 958)), "under a km")
        XCTAssertFalse(VehicleMatch.farByGPS(j("305-0551", "305", gps: false, .failure(.tooFarFromTimes), offset: 1683)), "its times only")
        XCTAssertFalse(VehicleMatch.farByGPS(j("305-0551", "305", gps: true, .failure(.offItsPath), offset: 1683)), "the roads rule")
        XCTAssertFalse(VehicleMatch.farByGPS(j("305-0551", "305", gps: true, .success(30), offset: 1683)))
        XCTAssertFalse(VehicleMatch.farByGPS(j("ic-1", "IC", gps: true, .failure(.tooFarFromTimes), offset: 1683, train: true)), "a train: 2.5 km")
    }

    func test_c_theOtherOneFittedByGPSAMomentAgo_winsOverThePlannedFarOne() {
        // 17:26:41 the find: 154·0855 fits by its own GPS (its fit noted); 17:26:51 the planned 305·0551 is 1683 m from
        // you by its own GPS, the 154 889 m (its feed lags): the 154, at once ("keep 305 · the only one left" before)
        var gps = GPSChoice()
        let find = [j("154-0855", "154", gps: true, .success(150), offset: 900)]
        VehicleMatch.noteGPSFits(find, into: &gps.fitAt, now: at(0))
        gps.restart()                                           // (a new choice keeps what their GPS said)
        var misses: [String: Int] = [:], state = SwitchState()
        let ids = ["305-0551", "154-0855"]
        let look = [j("305-0551", "305", gps: true, .failure(.tooFarFromTimes), offset: 1683),
                    j("154-0855", "154", gps: true, .failure(.tooFarFromTimes), offset: 889)]
        let c = VehicleMatch.choose(ids, judged: look, shown: "305-0551", shownOffRoad: false, choosingFor: 10,
                                    misses: &misses, state: &state, gps: &gps, now: at(10))
        XCTAssertEqual(c.settle, "154-0855")
        XCTAssertEqual(c.why, .farByGPS)
        XCTAssertEqual(c.decision, .switchTo("154-0855"))
    }

    func test_c_withoutTheFindsFit_itIsNotTheOnlyOneLeftWhileTheOtherFittedByGPS() {
        // the same two looks, the 154's fit noted by the choice itself: the 154 is protected, never "the only one left"
        var gps = GPSChoice()
        var misses: [String: Int] = [:], state = SwitchState()
        let ids = ["305-0551", "154-0855"]
        let first = [j("305-0551", "305", gps: true, .failure(.tooFarFromTimes), offset: 958),
                     j("154-0855", "154", gps: true, .success(40), offset: 400)]
        let a = VehicleMatch.choose(ids, judged: first, shown: "305-0551", shownOffRoad: false, choosingFor: 0,
                                    misses: &misses, state: &state, gps: &gps, now: at(0))
        XCTAssertNotEqual(a.settle, "305-0551")
        let second = [j("305-0551", "305", gps: true, .failure(.tooFarFromTimes), offset: 1878),
                      j("154-0855", "154", gps: true, .failure(.tooFarFromTimes), offset: 1089)]
        let b = VehicleMatch.choose(ids, judged: second, shown: "305-0551", shownOffRoad: false, choosingFor: 12,
                                    misses: &misses, state: &state, gps: &gps, now: at(12))
        XCTAssertEqual(b.settle, "154-0855")
        XCTAssertNotEqual(b.why, .onlyOneLeft)
    }

    func test_c_morning0909_bothOffTheirPathKeepsThePlanned() {
        // 09:09:55 and 09:10:08: the planned 372 and the 4 both a little off their path (no GPS far): as before, the
        // planned 372 stays, the only one left
        var gps = GPSChoice()
        var misses: [String: Int] = [:], state = SwitchState()
        let ids = ["372-0101", "4-0177"]
        let ok = [j("372-0101", "372", gps: false, .success(7)), j("4-0177", "4", gps: false, .success(34))]
        let l0 = VehicleMatch.choose(ids, judged: ok, shown: "372-0101", shownOffRoad: false, choosingFor: 0,
                                     misses: &misses, state: &state, gps: &gps, now: at(0))
        XCTAssertNil(l0.settle)
        let off1 = [j("4-0177", "4", gps: false, .failure(.offItsPath), cross: 155),
                    j("372-0101", "372", gps: true, .failure(.offItsPath), offset: 1500, cross: 161)]
        let l1 = VehicleMatch.choose(ids, judged: off1, shown: "372-0101", shownOffRoad: false, choosingFor: 20,
                                     misses: &misses, state: &state, gps: &gps, now: at(20))
        XCTAssertNil(l1.settle)
        let off2 = [j("372-0101", "372", gps: true, .failure(.offItsPath), offset: 1500, cross: 191),
                    j("4-0177", "4", gps: false, .failure(.offItsPath), cross: 211)]
        let l2 = VehicleMatch.choose(ids, judged: off2, shown: "372-0101", shownOffRoad: false, choosingFor: 33,
                                     misses: &misses, state: &state, gps: &gps, now: at(33))
        XCTAssertEqual(l2.settle, "372-0101")
        XCTAssertEqual(l2.why, .onlyOneLeft)
    }

    func test_c_morning0909_bothLeftThenSaysNothing() {
        let d = Departure(t: at(0), p: Fx.east(0), stood: 179)
        let a = DepartClue(id: "372-0101", offBy: 38)
        let b = DepartClue(id: "4-0177", offBy: 38)
        XCTAssertNil(DepartMatch.pick([a, b], ids: ["372-0101", "4-0177"]))
        XCTAssertEqual(DepartMatch.logLine(d, [a, b], lines: ["372-0101": "372", "4-0177": "4"], calendar: utc),
                       "depart · stood 179 s, left 08:00:00 · 372·0101 left then (live 38 s) · 4·0177 left then (live 38 s)")
    }

    // MARK: (d) the wrong bus

    func test_d_sureAfter75sOfItsGPS_orWhenTheRoadsSplit() {
        var runs: [String: WrongBus.Run] = [:]
        runs = WrongBus.note(runs, fitted: ["154-0855"], now: at(0))
        runs = WrongBus.note(runs, fitted: ["154-0855", "305-0551"], now: at(40))
        XCTAssertFalse(WrongBus.sure(runs["154-0855"], split: false, now: at(40)), "40 s")
        runs = WrongBus.note(runs, fitted: ["154-0855"], now: at(80))
        XCTAssertTrue(WrongBus.sure(runs["154-0855"], split: false, now: at(80)), "80 s of its GPS")
        XCTAssertFalse(WrongBus.sure(runs["305-0551"], split: false, now: at(80)))
        XCTAssertTrue(WrongBus.sure(nil, split: true, now: at(0)), "the roads split")
        XCTAssertFalse(WrongBus.sure(runs["154-0855"], split: false, now: at(80 + 200)), "its newest fit too old")
        // a gap of more than 3 minutes starts the run again
        runs = WrongBus.note(runs, fitted: ["154-0855"], now: at(80 + 200))
        XCTAssertEqual(runs["154-0855"]?.first, at(280))
        XCTAssertNil(runs["305-0551"], "gone after the gap")
    }

    func test_d_differsByLineOrDestination() {
        XCTAssertTrue(WrongBus.differs(plannedLine: "306", plannedTo: "", line: "154", to: "Schijndel"))
        XCTAssertFalse(WrongBus.differs(plannedLine: "306", plannedTo: "Veghel", line: "306", to: "Veghel"))
        XCTAssertTrue(WrongBus.differs(plannedLine: "306", plannedTo: "Veghel", line: "306", to: "Uden"))
        XCTAssertFalse(WrongBus.differs(plannedLine: "306", plannedTo: "", line: "306", to: "Uden"), "its destination not known")
        XCTAssertFalse(WrongBus.differs(plannedLine: "", plannedTo: "", line: "154", to: "Schijndel"), "nothing planned")
        XCTAssertTrue(WrongBus.due(differs: true, sure: true, byHand: false, told: false))
        XCTAssertFalse(WrongBus.due(differs: true, sure: true, byHand: true, told: false), "you picked it yourself")
        XCTAssertFalse(WrongBus.due(differs: true, sure: true, byHand: false, told: true), "once a ride")
        XCTAssertFalse(WrongBus.due(differs: true, sure: false, byHand: false, told: false))
    }

    func test_d_words() {
        XCTAssertEqual(WrongBus.title(line: "154", to: "Schijndel", planned: "306"), "You’re on the 154 to Schijndel, not your 306")
        XCTAssertEqual(WrongBus.title(line: "154", to: " ", planned: "306"), "You’re on the 154, not your 306")
        XCTAssertEqual(WrongBus.fix(getOff: "Kloosterstraat", nextStop: true, then: "306", at: "17:52"),
                       "Get off at Kloosterstraat — 306 back at 17:52")
        XCTAssertEqual(WrongBus.fix(getOff: "Schijndel", nextStop: false, then: "306", at: "18:11"),
                       "Stay on to Schijndel — 306 from there at 18:11")
        XCTAssertEqual(WrongBus.fix(getOff: "Veghel", nextStop: false, then: nil, at: nil), "Stay on to Veghel: it gets you there")
        XCTAssertEqual(WrongBus.logLine(label: "154·0855", to: "Schijndel", planned: "306", fix: "Stay on to Schijndel — 306 from there at 18:11"),
                       "wrong bus · on 154·0855 to Schijndel, planned 306 · Stay on to Schijndel — 306 from there at 18:11")
    }

    func test_d_itsNotificationGoesAfter20Minutes() {
        let id = WrongBus.id(tripStart: t0)
        XCTAssertTrue(id.hasPrefix(WrongBus.idPrefix))
        XCTAssertEqual(NoticeExpiry.minutes(forId: id), 20)
        XCTAssertEqual(NoticeExpiry.due([(id, t0)], now: at(19 * 60)), [])
        XCTAssertEqual(NoticeExpiry.due([(id, t0)], now: at(20 * 60)), [id])
    }

    // MARK: (e) another line's bus at your stop

    private let yours = OtherAtStop.Yours(line: "306", departure: Fx.t0.addingTimeInterval(150), lines: ["306"])
    private func seen(_ id: String, _ line: String, metres: Double?, age: TimeInterval? = 40, leaves: TimeInterval = 60) -> OtherAtStop.Seen {
        OtherAtStop.Seen(tripId: id, line: line, to: "Schijndel", departure: at(leaves), metres: metres, fixAge: age)
    }

    func test_e_the154AtYourStop_isNotYours() {
        let s = OtherAtStop.pick([seen("154-0855", "154", metres: 30), seen("156-0978", "156", metres: 900)], yours: yours,
                                 youToStop: 50, now: at(0))
        XCTAssertEqual(s?.tripId, "154-0855")
        let w = s.map { OtherAtStop.words($0, yours: yours, now: at(0)) }
        XCTAssertEqual(w?.title, "That’s the 154 to Schijndel — not yours")
        XCTAssertEqual(w?.body, "Your 306: 2 min")
        XCTAssertEqual(OtherAtStop.words(seen("154-0855", "154", metres: 30), yours: yours, now: at(120)).body, "Your 306: due")
    }

    func test_e_quietWhenItDoesntMatter() {
        let here = [seen("154-0855", "154", metres: 30)]
        XCTAssertNil(OtherAtStop.pick(here, yours: yours, youToStop: 400, now: at(0)), "you're not at the stop")
        XCTAssertNil(OtherAtStop.pick(here, yours: yours, youToStop: 50, now: at(-15 * 60)), "yours is 17 min off")
        XCTAssertNil(OtherAtStop.pick([seen("306-0681", "306", metres: 20)], yours: yours, youToStop: 50, now: at(0)), "it's yours")
        let both = OtherAtStop.Yours(line: "305", departure: at(150), lines: ["305", "306"])
        XCTAssertNil(OtherAtStop.pick([seen("306-0681", "306", metres: 20)], yours: both, youToStop: 50, now: at(0)), "your own route: both are yours")
        XCTAssertNil(OtherAtStop.pick([seen("154-0855", "154", metres: nil, age: nil)], yours: yours, youToStop: 50, now: at(0)), "no GPS of its own")
        XCTAssertNil(OtherAtStop.pick([seen("154-0855", "154", metres: 30, age: 400)], yours: yours, youToStop: 50, now: at(0)), "an old fix")
        XCTAssertNil(OtherAtStop.pick([seen("154-0855", "154", metres: 200)], yours: yours, youToStop: 50, now: at(0)), "not at your stop")
        XCTAssertNil(OtherAtStop.pick([seen("154-0855", "154", metres: 30, leaves: 20 * 60)], yours: yours, youToStop: 50, now: at(0)),
                     "it leaves long after yours")
        XCTAssertNil(OtherAtStop.pick(here, yours: nil, youToStop: 50, now: at(0)))
    }

    func test_e_itsNotificationGoesAfter10Minutes() {
        let id = OtherAtStop.id("20261125_17:24_nl-OpenOV_154")
        XCTAssertTrue(id.hasPrefix(OtherAtStop.idPrefix))
        XCTAssertEqual(NoticeExpiry.minutes(forId: id), 10)
    }

    // MARK: (f) your usual line, and the moment you left

    func test_f_onlyThePlannedLineIsLearnedFromAFoundRide() {
        XCTAssertFalse(UsualLine.learnsFound(line: "154", train: false, plannedLine: "306", plannedTrain: false), "the wrong bus")
        XCTAssertFalse(UsualLine.learnsFound(line: "154", train: false, plannedLine: "305", plannedTrain: false))
        XCTAssertTrue(UsualLine.learnsFound(line: "305", train: false, plannedLine: "305", plannedTrain: false))
        XCTAssertTrue(UsualLine.learnsFound(line: "IC", train: true, plannedLine: "ic", plannedTrain: true))
        XCTAssertFalse(UsualLine.learnsFound(line: "IC", train: true, plannedLine: "IC", plannedTrain: false))
        XCTAssertTrue(UsualLine.learnsFound(line: "306", train: false, plannedLine: nil, plannedTrain: nil), "nothing planned: your own route")
    }

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func test_f_notThenByLiveTimesAloneNeeds180s() {
        // 18:11:54: "306·0681 not then (live 91 s) · 154·0887 left then (gps 37 s)" picked the 154: it may not
        let d = Departure(t: at(0), p: Fx.east(0), stood: 179)
        let the306 = DepartClue(id: "306-0681", offBy: 91)
        let the154 = DepartClue(id: "154-0887", offBy: 37, byGPS: true)
        XCTAssertFalse(DepartMatch.notThen(the306, than: 37))
        XCTAssertNil(DepartMatch.pick([the306, the154], ids: ["154-0887", "306-0681"]))
        XCTAssertEqual(DepartMatch.logLine(d, [the306, the154], lines: ["306-0681": "306", "154-0887": "154"], calendar: utc),
                       "depart · stood 179 s, left 08:00:00 · 306·0681 not sure (live 91 s) · 154·0887 left then (gps 37 s)")
        // by its own GPS 91 s off, or 200 s by its live times: then it didn't
        XCTAssertTrue(DepartMatch.notThen(DepartClue(id: "306-0681", offBy: 91, byGPS: true), than: 37))
        XCTAssertEqual(DepartMatch.pick([DepartClue(id: "306-0681", offBy: 200), the154], ids: ["154-0887", "306-0681"]), "154-0887")
    }

    func test_f_twoStandingAtTheStop_sayNothing() {
        let d = Departure(t: at(0), p: Fx.east(0), stood: 179)
        var a = DepartClue(id: "154-0887", offBy: 20, byGPS: true)
        a.atStop = true
        var b = DepartClue(id: "306-0681", offBy: 300, byGPS: true)
        b.atStop = true
        XCTAssertTrue(DepartMatch.severalAtStop([a, b], ids: ["154-0887", "306-0681"]))
        XCTAssertNil(DepartMatch.pick([a, b], ids: ["154-0887", "306-0681"]))
        XCTAssertTrue(DepartMatch.bonuses([a, b], ids: ["154-0887", "306-0681"]).isEmpty)
        XCTAssertTrue(DepartMatch.logLine(d, [a, b], lines: ["154-0887": "154", "306-0681": "306"], calendar: utc)
            .hasSuffix(" · 2 at the stop: says nothing"))
        // its own GPS at the stop while you stood there
        let g = GPSFix(lat: Fx.east(10).lat, lon: Fx.east(10).lon, bearing: 90, at: at(-120))
        let piece = TimedPiece(departure: at(600), arrival: at(900), path: [Fx.east(0), Fx.east(1000)])
        let v = VehicleTrack(tripId: "306-0681", line: "306", isTrain: false, realTime: false, pieces: [piece],
                             gps: VehicleGPS(fix: g))
        XCTAssertTrue(DepartMatch.clue(v, at: d).atStop)
    }
}
