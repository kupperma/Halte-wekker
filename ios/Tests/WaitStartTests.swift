import XCTest

/// 0.42.4: the trip starts while Fastest trip watches, wherever you got on (`WaitStart`). Synthetic rides in Veghel: the
/// 305 from the bus station past Biezendijk (the stop it planned) towards Eindhoven.
final class WaitStartTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 7_000_000)
    private let rules = WaitStart.Rules(oneLook: 20, close: 60)

    // the 305's stops: the bus station, a stop on the way, Biezendijk (planned), on towards Eindhoven
    private let busStation = GeoPoint(lat: 51.6170, lon: 5.5440)
    private let middle = GeoPoint(lat: 51.6140, lon: 5.5390)
    private let biezendijk = GeoPoint(lat: 51.6100, lon: 5.5330)
    private let further = GeoPoint(lat: 51.6000, lon: 5.5200)
    private let eindhoven = GeoPoint(lat: 51.4430, lon: 5.4800)

    private var stops: [WaitStart.Stop] {
        [WaitStart.Stop(name: "Bus station", point: busStation, time: t0),
         WaitStart.Stop(name: "Middle", point: middle, time: t0.addingTimeInterval(90)),
         WaitStart.Stop(name: "Biezendijk", point: biezendijk, time: t0.addingTimeInterval(180)),
         WaitStart.Stop(name: "Further", point: further, time: t0.addingTimeInterval(330)),
         WaitStart.Stop(name: "Eindhoven", point: eindhoven, time: t0.addingTimeInterval(1800))]
    }

    /// Fixes every `every` s at `speed` along the stops' road from `from` (index) on, starting at `start` s.
    private func ride(fromStop k: Int, start: Double, seconds: Double, speed: Double = 9, every: Double = 2) -> [Fix] {
        let road: [GeoPoint] = Array(stops.map(\.point)[k...])
        var out: [Fix] = []
        var t: Double = 0
        while t <= seconds {
            let p: GeoPoint = along(road, metres: speed * t)
            out.append(Fix(t: t0.addingTimeInterval(start + t), p: p, accuracy: 8, speed: speed, course: 225))
            t += every
        }
        return out
    }

    private func along(_ road: [GeoPoint], metres m: Double) -> GeoPoint {
        var left: Double = m
        for i in 1..<road.count {
            let d: Double = Geo.metres(road[i - 1], road[i])
            if left <= d {
                let f: Double = d > 0 ? left / d : 0
                return GeoPoint(lat: road[i - 1].lat + (road[i].lat - road[i - 1].lat) * f,
                                lon: road[i - 1].lon + (road[i].lon - road[i - 1].lon) * f)
            }
            left -= d
        }
        return road[road.count - 1]
    }

    /// Standing at `p` from `start` s for `seconds`.
    private func stand(at p: GeoPoint, start: Double, seconds: Double, every: Double = 5) -> [Fix] {
        stride(from: 0.0, through: seconds, by: every).map { t in
            Fix(t: t0.addingTimeInterval(start + t), p: p, accuracy: 10, speed: 0, course: -1)
        }
    }

    /// Looks every 6 s up to `until` s; the matcher has `cands` from `from` s on (before that it isn't sure). The first
    /// start (its id and when), and every call.
    private func looks(_ fixes: [Fix], until: Double, from: Double, motion: WaitStart.Hint = .none,
                       cands: (Double) -> [WaitStart.Candidate]) -> (id: String?, at: Double?, calls: [WaitStart.Call]) {
        var state = WaitStart.State()
        var calls: [WaitStart.Call] = []
        var t: Double = 6
        while t <= until {
            let now: Date = t0.addingTimeInterval(t)
            let seen: [Fix] = fixes.filter { $0.t <= now }
            let m: WaitStart.Moving = WaitStart.moving(seen, now: now)
            let c: [WaitStart.Candidate] = t >= from ? cands(t) : []
            let out: WaitStart.Outcome = WaitStart.step(state, moving: m, motion: motion, candidates: c, rules: rules)
            state = out.state
            calls.append(out.call)
            if case .start(let id) = out.call { return (id, t, calls) }
            t += 6
        }
        return (nil, nil, calls)
    }

    private func cand(_ id: String, line: String = "305", cost: Double, gps: Double? = 12, gpsFor: Double? = 30,
                      reaches: Bool? = true, planned: Bool = false, plannedLine: Bool = true) -> WaitStart.Candidate {
        WaitStart.Candidate(id: id, label: "\(line)·\(id.suffix(4))", line: line, cost: cost, gpsAge: gps, gpsFor: gpsFor,
                            reaches: reaches, planned: planned, plannedLine: plannedLine)
    }

    // MARK: the field report: on at an earlier stop, an earlier 305

    func test_boardingTheSameLineAtAnEarlierStop_startsWithin90s_andBoardsWhereYouGotOn() {
        // standing at the bus station a minute, then on the earlier 305; the planned 09:52 from Biezendijk is nowhere
        // near you (it isn't among the candidates at all)
        let fixes: [Fix] = stand(at: busStation, start: -60, seconds: 60) + ride(fromStop: 0, start: 0, seconds: 120)
        let r = looks(fixes, until: 120, from: 20) { _ in [self.cand("trip-2718", cost: 25)] }
        XCTAssertEqual(r.id, "trip-2718")
        XCTAssertNotNil(r.at)
        XCTAssertLessThanOrEqual(r.at ?? 999, 90, "started within 90 s of boarding")
        // where you got on: the bus station, not Biezendijk
        let now: Date = t0.addingTimeInterval(r.at ?? 0)
        let seen: [Fix] = fixes.filter { $0.t <= now }
        let start: GeoPoint? = WaitStart.startedMoving(seen, now: now)
        XCTAssertNotNil(start)
        let here: GeoPoint = seen.last!.p
        let i: Int? = WaitStart.repoint(stops, startedAt: start, here: here, planned: biezendijk)
        XCTAssertEqual(i, 0, "the leg starts at the bus station")
    }

    func test_boardingAnEarlierDepartureOfThePlannedLine_byItsTimes_startsOnIt() {
        // no GPS of its own: by its live times, another departure of the planned line: two looks
        let fixes: [Fix] = stand(at: biezendijk, start: -60, seconds: 60) + ride(fromStop: 2, start: 0, seconds: 120)
        let r = looks(fixes, until: 120, from: 20) { _ in [self.cand("trip-1111", cost: 30, gps: nil, gpsFor: nil)] }
        XCTAssertEqual(r.id, "trip-1111")
        XCTAssertLessThanOrEqual(r.at ?? 999, 90)
        // got on at the planned stop: nothing to re-point
        let now: Date = t0.addingTimeInterval(r.at ?? 0)
        let seen: [Fix] = fixes.filter { $0.t <= now }
        XCTAssertNil(WaitStart.repoint(stops, startedAt: WaitStart.startedMoving(seen, now: now), here: seen.last!.p, planned: biezendijk))
    }

    func test_boardingThePlannedDepartureAtThePlannedStop_unchanged() {
        let fixes: [Fix] = stand(at: biezendijk, start: -60, seconds: 60) + ride(fromStop: 2, start: 0, seconds: 90)
        let r = looks(fixes, until: 90, from: 20) { _ in [self.cand("trip-0952", cost: 6, planned: true)] }
        XCTAssertEqual(r.id, "trip-0952")
        XCTAssertEqual(r.at, 30, "one look, as soon as you've been at bus speed for 30 s")
        let now: Date = t0.addingTimeInterval(30)
        let seen: [Fix] = fixes.filter { $0.t <= now }
        XCTAssertNil(WaitStart.repoint(stops, startedAt: WaitStart.startedMoving(seen, now: now), here: seen.last!.p, planned: biezendijk),
                     "the planned stop stays the leg's start")
    }

    func test_theOneOnTheRoadItSharesWithThe306_stillStarts() {
        // the 305 and the 306 leave Veghel together: the best flips between them; the 306 doesn't go your way
        let fixes: [Fix] = stand(at: busStation, start: -30, seconds: 30) + ride(fromStop: 0, start: 0, seconds: 120)
        let r = looks(fixes, until: 120, from: 20) { t in
            let a = self.cand("trip-2718", cost: 25)
            let b = self.cand("trip-3306", line: "306", cost: 22, reaches: false, plannedLine: false)
            return Int(t) % 12 == 0 ? [b, a] : [a, b]
        }
        XCTAssertEqual(r.id, "trip-2718")
        XCTAssertLessThanOrEqual(r.at ?? 999, 90)
    }

    func test_anotherLineThatGetsYouThere_needsTwoLooksByGPS() {
        let fixes: [Fix] = ride(fromStop: 0, start: 0, seconds: 120)
        let r = looks(fixes, until: 120, from: 20) { _ in [self.cand("trip-0150", line: "150", cost: 10, plannedLine: false)] }
        XCTAssertEqual(r.id, "trip-0150")
        XCTAssertEqual(r.at, 36)
    }

    func test_byItsTimesAlone_anotherLineNeedsThreeLooks() {
        let c = cand("x", line: "150", cost: 10, gps: nil, gpsFor: nil, plannedLine: false)
        XCTAssertEqual(WaitStart.needed(c, rules: rules), 3)
        XCTAssertEqual(WaitStart.needed(cand("y", cost: 10, gps: nil, gpsFor: nil, planned: true), rules: rules), 1)
        XCTAssertEqual(WaitStart.needed(cand("z", cost: 10), rules: rules), 1)
        XCTAssertEqual(WaitStart.needed(cand("z", cost: 25), rules: rules), 2)
    }

    // MARK: no start

    func test_standingAtTheStopWhileABusPasses_noStart() {
        let fixes: [Fix] = stand(at: busStation, start: 0, seconds: 240)
        let r = looks(fixes, until: 240, from: 0) { _ in [self.cand("trip-2718", cost: 5, planned: true)] }
        XCTAssertNil(r.id)
        XCTAssertTrue(r.calls.allSatisfy { $0 == .hold("standing") })
    }

    func test_walking_noStart() {
        let fixes: [Fix] = ride(fromStop: 0, start: 0, seconds: 240, speed: 1.4)
        let r = looks(fixes, until: 240, from: 20) { _ in [self.cand("trip-2718", cost: 5, planned: true)] }
        XCTAssertNil(r.id)
    }

    func test_cycling_noStart() {
        let slow: [Fix] = ride(fromStop: 0, start: 0, seconds: 240, speed: 5)
        XCTAssertNil(looks(slow, until: 240, from: 20) { _ in [self.cand("trip-2718", cost: 5, planned: true)] }.id)
        // a fast bike, Motion & Fitness says cycling
        let fast: [Fix] = ride(fromStop: 0, start: 0, seconds: 240, speed: 7.5)
        let r = looks(fast, until: 240, from: 20, motion: .afoot) { _ in [self.cand("trip-2718", cost: 5, planned: true)] }
        XCTAssertNil(r.id)
        XCTAssertTrue(r.calls.allSatisfy { $0 == .hold("walking or cycling (motion)") })
    }

    func test_automotive_startsSooner() {
        XCTAssertNil(WaitStart.movingRule(WaitStart.Moving(seconds: 12, speed: 8), motion: .vehicle))
        XCTAssertNotNil(WaitStart.movingRule(WaitStart.Moving(seconds: 12, speed: 8), motion: .none))
    }

    func test_aStopOnTheWay_stillCountsAsMoving() {
        // 40 s at speed, then 20 s at a stop: still riding
        let moving: [Fix] = ride(fromStop: 0, start: 0, seconds: 40)
        let stop: [Fix] = stand(at: moving.last!.p, start: 42, seconds: 20, every: 2)
        let m = WaitStart.moving(moving + stop, now: t0.addingTimeInterval(62))
        XCTAssertGreaterThanOrEqual(m.seconds, 30)
        XCTAssertNil(WaitStart.movingRule(m, motion: .none))
    }

    // MARK: the wrong bus

    func test_sureOnALineThatDoesntGoThere_wrongBusOnce_notSilence() {
        let fixes: [Fix] = ride(fromStop: 0, start: 0, seconds: 120)
        var state = WaitStart.State()
        var calls: [WaitStart.Call] = []
        for k in 0..<4 {
            let now: Date = t0.addingTimeInterval(60 + Double(k) * 6)
            let m = WaitStart.moving(fixes.filter { $0.t <= now }, now: now)
            let c = [cand("trip-0154", line: "154", cost: 8, gpsFor: 80, reaches: false, plannedLine: false)]
            let out = WaitStart.step(state, moving: m, motion: .none, candidates: c, rules: rules)
            state = out.state
            calls.append(out.call)
        }
        XCTAssertEqual(calls.first, .wrongBus("trip-0154"))
        XCTAssertEqual(calls.dropFirst().filter { $0 == .wrongBus("trip-0154") }.count, 0, "told once")
        XCTAssertEqual(calls.last, .hold("not your way (told)"))
    }

    func test_notYetSure_noWrongBus() {
        let m = WaitStart.Moving(seconds: 40, speed: 9)
        let c = [cand("trip-0154", line: "154", cost: 8, gpsFor: 20, reaches: false, plannedLine: false)]
        let out = WaitStart.step(WaitStart.State(), moving: m, motion: .none, candidates: c, rules: rules)
        XCTAssertEqual(out.call, .hold("not your way"))
    }

    func test_stopsNotKnown_holds() {
        let m = WaitStart.Moving(seconds: 40, speed: 9)
        let out = WaitStart.step(WaitStart.State(), moving: m, motion: .none, candidates: [cand("a", cost: 5, reaches: nil)], rules: rules)
        XCTAssertEqual(out.call, .hold("its stops not known yet"))
    }

    // MARK: where it goes

    func test_reaches_aheadOnly() {
        // on board past Biezendijk: Eindhoven ahead, the bus station behind
        let here: GeoPoint = further
        XCTAssertTrue(WaitStart.reaches(stops, here: here, targets: [eindhoven], now: t0))
        XCTAssertFalse(WaitStart.reaches(stops, here: here, targets: [busStation], now: t0.addingTimeInterval(400)))
        XCTAssertFalse(WaitStart.reaches(stops, here: here, targets: [GeoPoint(lat: 51.69, lon: 5.30)], now: t0))
    }

    func test_boardedAt_nearestStopToWhereYouStartedMoving() {
        let start = GeoPoint(lat: 51.6168, lon: 5.5436)          // a few tens of metres past the bus station
        XCTAssertEqual(WaitStart.boardedAt(stops, startedAt: start, here: further), 0)
        // nothing near where you started: none
        XCTAssertNil(WaitStart.boardedAt(stops, startedAt: GeoPoint(lat: 51.63, lon: 5.58), here: further))
    }

    // MARK: the watching, not a screen

    func test_theLookRunsWhileItWatches_whateverIsOnScreen() {
        // only the watching, no trip on yet and not the demo decide it: nothing about the screen in front
        XCTAssertNil(WaitStart.lookRuns(watching: true, tripIdle: true, demo: false))
        XCTAssertEqual(WaitStart.lookRuns(watching: false, tripIdle: true, demo: false), "not watching")
        XCTAssertEqual(WaitStart.lookRuns(watching: true, tripIdle: false, demo: false), "a trip runs")
        XCTAssertEqual(WaitStart.lookRuns(watching: true, tripIdle: true, demo: true), "the demo")
        XCTAssertEqual(WaitStart.onLine(again: false, inFront: false),
                       "wait · watching on · its look at what you get on runs (behind the screen)")
        XCTAssertEqual(WaitStart.offLine(why: "closed"), "wait · watching off · closed")
    }

    func test_logDue_everyLookWhileBusy_elseOnceAMinute() {
        let last: (key: String, at: Date) = (key: "standing", at: t0)
        XCTAssertTrue(WaitStart.logDue(key: "standing", last: last, busy: true, now: t0.addingTimeInterval(6)))
        XCTAssertFalse(WaitStart.logDue(key: "standing", last: last, busy: false, now: t0.addingTimeInterval(6)))
        XCTAssertTrue(WaitStart.logDue(key: "standing", last: last, busy: false, now: t0.addingTimeInterval(60)))
        XCTAssertTrue(WaitStart.logDue(key: "seen 1 of 2 looks", last: last, busy: false, now: t0.addingTimeInterval(6)))
        XCTAssertTrue(WaitStart.logDue(key: "standing", last: nil, busy: false, now: t0))
    }

    // MARK: the field log

    func test_logLine() {
        let m = WaitStart.Moving(seconds: 40, speed: 9.2)
        let c = [cand("trip-2718", cost: 25), cand("trip-1234", line: "306", cost: 40, gps: nil, gpsFor: nil, reaches: false, plannedLine: false)]
        XCTAssertEqual(WaitStart.logLine(m, c, .start("trip-2718")),
                       "wait · moving 9 m/s 40 s · candidates 305·2718 gps 12 s fits, 306·1234 times elsewhere · start 305·2718")
        XCTAssertEqual(WaitStart.logLine(WaitStart.Moving(seconds: 0, speed: 0), [], .hold("standing")),
                       "wait · moving 0 m/s 0 s · no candidates · held by standing")
    }
}
