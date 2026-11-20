import XCTest

/// 0.34: two trains on the same track. On 2026-11-19 the user rode the Intercity Breda → 's-Hertogenbosch; the app had the
/// Intercity Breda → Tilburg → Eindhoven, which runs on the same track to past Tilburg, and the plan said "change at
/// Tilburg to a Sprinter".
final class TrainRulesTests: XCTestCase {
    private let t0 = Fx.t0

    // MARK: the cause, reproduced

    /// On a confirmed ride the "same train?" look judges the one shown alone. A timetable-only train on the same track
    /// is judged by its road and your speed (not by its times) and passes, whatever train you're really on, so nothing
    /// looked at the train whose own NS position was right with you until the tracks split.
    func test_reproduced_timetableOnlyWrongTrainPassesAlone() {
        let you = Fx.fixes(from: 2000, speed: 30, count: 15)
        // the Eindhoven one: no live times, its timetable 4 km away from you
        let wrong = Fx.track("IC1131", live: false, path: Fx.railway, at: 6000, speed: 30)
        let judged = VehicleMatch.judgeAll(you, [wrong], strictTimes: false)
        XCTAssertNotNil(Fx.ok(judged, "IC1131"), "kept as the one shown: \(judged)")
        // the one you're on, by NS's position of it, with you
        var mine = Fx.track("IC3624", path: Fx.railway, at: 2400, speed: 30)
        mine.gps = VehicleGPS(fix: GPSFix(lat: Fx.east(2400).lat, lon: Fx.east(2400).lon, bearing: 90, at: t0.addingTimeInterval(26), speed: 30))
        let both = VehicleMatch.judgeAll(you, [wrong, mine], strictTimes: false)
        XCTAssertTrue(VehicleMatch.passedByGPS(try XCTUnwrap(both.first { $0.id == "IC3624" })))
        // now: the confirmed ride's look also asks the other trains on your track, and one with you by its own GPS while
        // the one shown isn't starts a choice between them
        XCTAssertEqual(TrainRules.rivals(shown: both.first { $0.id == "IC1131" }, others: both.filter { $0.id != "IC1131" }), ["IC3624"])
    }

    // MARK: rivals

    private func train(_ id: String, gps: Bool, live: Bool = true, _ r: Result<Double, Reject>) -> Judgement {
        var e = Evidence(fixes: 15, span: 28, crossTrack: 20, accuracy: 30, shaped: true, progress: 840, offset: 0,
                         drift: 0, yourSpeed: 30, itsSpeed: 30, steady: true)
        e.gps = gps
        return Judgement(id: id, line: "IC", isTrain: true, realTime: live, evidence: e, result: r)
    }

    func test_rivalsOnlyWhenTheShownOneIsNotWithYouByItsGPS() {
        let rival = train("b", gps: true, .success(5))
        // the one shown is with you by its own GPS: nothing to look at
        XCTAssertEqual(TrainRules.rivals(shown: train("a", gps: true, .success(10)), others: [rival]), [])
        // by its live times only: the one by GPS is a rival
        XCTAssertEqual(TrainRules.rivals(shown: train("a", gps: false, .success(10)), others: [rival]), ["b"])
        // its GPS puts it far away
        XCTAssertEqual(TrainRules.rivals(shown: train("a", gps: true, .failure(.tooFarFromTimes)), others: [rival]), ["b"])
        // a rival by its times only isn't evidence
        XCTAssertEqual(TrainRules.rivals(shown: train("a", gps: false, .success(10)), others: [train("c", gps: false, .success(1))]), [])
        // a bus is no rival of a train
        let bus = Judgement(id: "bus", line: "305", isTrain: false, realTime: true, evidence: rival.evidence, result: .success(1))
        XCTAssertEqual(TrainRules.rivals(shown: train("a", gps: false, .success(10)), others: [bus]), [])
        // at most two, best first
        let many = [train("x", gps: true, .success(30)), train("y", gps: true, .success(3)), train("z", gps: true, .success(9))]
        XCTAssertEqual(TrainRules.rivals(shown: nil, others: many), ["y", "z"])
    }

    // MARK: stopping pattern

    /// Fixes every 2 s along the railway: `plan` is (seconds, speed) pieces from `m0`.
    private func ride(from m0: Double, _ plan: [(TimeInterval, Double)], accuracy: Double = 15) -> [Fix] {
        var out: [Fix] = [], m = m0, t: TimeInterval = 0
        for (span, v) in plan {
            var s: TimeInterval = 0
            while s < span {
                out.append(Fix(t: t0.addingTimeInterval(t), p: Fx.east(m), accuracy: accuracy, speed: v, course: 90))
                m += v * 2; t += 2; s += 2
            }
        }
        out.append(Fix(t: t0.addingTimeInterval(t), p: Fx.east(m), accuracy: accuracy, speed: plan.last?.1 ?? 0, course: 90))
        return out
    }

    func test_passedThroughAStationAtSpeed() {
        let f = ride(from: 0, [(120, 30)])                  // 0 → 3600 m at 30 m/s
        XCTAssertEqual(TrainRules.seen(f, at: Fx.east(1800)), .passedThrough)
        XCTAssertNil(TrainRules.seen(f, at: Fx.east(3500)), "not past it yet: nothing to say")
        XCTAssertNil(TrainRules.seen(f, at: Fx.east(1800, north: 1500)), "not by it")
    }

    func test_stoppedAtAStation() {
        let f = ride(from: 0, [(40, 25), (40, 0), (40, 20)])      // stands 40 s at 1000 m
        XCTAssertEqual(TrainRules.seen(f, at: Fx.east(1050)), .stopped)
        // only slowing down (not 20 s standing) is no stop
        let slow = ride(from: 0, [(40, 25), (10, 0), (40, 20)])
        XCTAssertNil(TrainRules.seen(slow, at: Fx.east(1050)))
    }

    func test_gapInTheFixesIsNoPassThrough() {
        // a tunnel or no fixes for a minute next to the station: it may have stopped there
        var f = ride(from: 0, [(120, 30)])
        f.removeAll { $0.t > t0.addingTimeInterval(40) && $0.t < t0.addingTimeInterval(100) }
        XCTAssertNil(TrainRules.seen(f, at: Fx.east(1800)))
    }

    func test_outByStoppingPattern() {
        let calls: [String: Set<String>] = ["SPR": ["Breda", "Gilze-Rijen", "Tilburg"], "IC": ["Breda", "Tilburg"]]
        let through: [String: Set<String>] = ["SPR": ["Breda", "Gilze-Rijen", "Tilburg"], "IC": ["Breda", "Gilze-Rijen", "Tilburg"]]
        // through Gilze-Rijen at speed: not the Sprinter
        XCTAssertEqual(TrainRules.outByStops(calls: calls, runsThrough: through, seen: ["Gilze-Rijen": .passedThrough]), ["SPR"])
        // stopped at Gilze-Rijen: not the Intercity
        XCTAssertEqual(TrainRules.outByStops(calls: calls, runsThrough: through, seen: ["Gilze-Rijen": .stopped]), ["IC"])
        // a stop where its track doesn't run says nothing about it (another track's station)
        XCTAssertEqual(TrainRules.outByStops(calls: calls, runsThrough: ["SPR": ["Gilze-Rijen"], "IC": []], seen: ["Gilze-Rijen": .stopped]), [])
        // never all of them out (a stop at a signal by a station, a pattern that's wrong): today's choice instead
        XCTAssertEqual(TrainRules.outByStops(calls: ["A": ["X"], "B": ["X"]], runsThrough: ["A": ["X"], "B": ["X"]], seen: ["X": .passedThrough]), [])
    }

    // MARK: asking which one

    func test_askAfterTwoMinutesOfATieWithDifferentDestinations() {
        let dest = ["a": "'s-Hertogenbosch", "b": "Eindhoven Centraal"]
        XCTAssertNil(TrainRules.ask(alive: ["a", "b"], choosingFor: 100, trains: true, destinations: dest, asked: false))
        XCTAssertEqual(TrainRules.ask(alive: ["a", "b"], choosingFor: 130, trains: true, destinations: dest, asked: false)?.0, "a")
        XCTAssertNil(TrainRules.ask(alive: ["a", "b"], choosingFor: 130, trains: true, destinations: dest, asked: true), "once")
        XCTAssertNil(TrainRules.ask(alive: ["a"], choosingFor: 130, trains: true, destinations: dest, asked: false))
        XCTAssertNil(TrainRules.ask(alive: ["a", "b"], choosingFor: 130, trains: false, destinations: dest, asked: false), "trains only")
        XCTAssertNil(TrainRules.ask(alive: ["a", "b"], choosingFor: 130, trains: true, destinations: ["a": "Zwolle", "b": "zwolle"], asked: false),
                     "the same way: it doesn't matter which")
        XCTAssertNil(TrainRules.ask(alive: ["a", "b"], choosingFor: 130, trains: true, destinations: ["a": "Zwolle"], asked: false))
    }

    func test_askWords() {
        XCTAssertEqual(TrainRules.askTitle(("IC", "'s-Hertogenbosch"), ("IC", "Eindhoven Centraal")),
                       "IC to 's-Hertogenbosch or IC to Eindhoven Centraal?")
        XCTAssertEqual(TrainRules.answer(line: "SPR", to: "Tilburg"), "SPR to Tilburg")
    }

    // MARK: staying on

    private func p(_ m: Double) -> GeoPoint { Fx.east(m) }

    /// Planned: IC to Tilburg (leg 0), Sprinter Tilburg → Den Bosch (leg 1, the last). You're on the through Intercity,
    /// which calls at Den Bosch: stay on, no change at Tilburg.
    func test_stayOnToTheEndOfTheLastLeg() {
        let ends = [p(3000), p(6000)]
        let deps: [Date?] = [t0, t0.addingTimeInterval(900)]
        let calls = [(p: p(0), arrival: Optional(t0)), (p: p(3000), arrival: Optional(t0.addingTimeInterval(600))),
                     (p: p(6000), arrival: Optional(t0.addingTimeInterval(1200)))]
        let s = TrainRules.stayOn(index: 0, ends: ends, departures: deps, calls: calls, now: t0.addingTimeInterval(60))
        XCTAssertEqual(s?.leg, 1)
        XCTAssertEqual(s?.call, 2)
        // it doesn't go there: nothing
        XCTAssertNil(TrainRules.stayOn(index: 0, ends: ends, departures: deps, calls: Array(calls.prefix(2)), now: t0.addingTimeInterval(60)))
    }

    /// A change after it: only in time for the ride after (2 minutes' room).
    func test_stayOnInTimeForTheRideAfter() {
        let ends = [p(3000), p(6000), p(9000)]
        let calls = [(p: p(3000), arrival: Optional(t0.addingTimeInterval(600))), (p: p(6000), arrival: Optional(t0.addingTimeInterval(1200)))]
        let ok = TrainRules.stayOn(index: 0, ends: ends, departures: [t0, t0.addingTimeInterval(700), t0.addingTimeInterval(1500)],
                                   calls: calls, now: t0)
        XCTAssertEqual(ok?.leg, 1)
        let late = TrainRules.stayOn(index: 0, ends: ends, departures: [t0, t0.addingTimeInterval(700), t0.addingTimeInterval(1250)],
                                     calls: calls, now: t0)
        XCTAssertNil(late)
    }
}
