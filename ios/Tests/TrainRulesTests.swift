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

    private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    /// Breda (0) → Tilburg (20 km) → Eindhoven (50 km) by train, then a bus from the station's bus bay (300 m on) to
    /// the end (70 km). The plan: IC 3529 to Tilburg (there 15:05, `at(1500)`), IC 3631 from Tilburg 15:12
    /// (`at(1920)`) to Eindhoven 15:45 (`at(3900)`), the bus at 15:50 (`at(4200)`).
    private var through: [TrainRules.StayLeg] {
        [TrainRules.StayLeg(from: p(0), to: p(20_000), fromName: "Breda", toName: "Tilburg", departure: at(0), arrival: at(1500), tripId: "t3529", num: "3529"),
         TrainRules.StayLeg(from: p(20_000), to: p(50_000), fromName: "Tilburg", toName: "Eindhoven Centraal", departure: at(1920), arrival: at(3900), tripId: "t3631", num: "3631"),
         TrainRules.StayLeg(from: p(50_300), to: p(70_000), fromName: "Eindhoven, Station", toName: "Veghel, Centrum", departure: at(4200), arrival: at(6000), tripId: "b305", num: "")]
    }

    /// The IC you're on: Breda, Tilburg, then on to Eindhoven (arriving `eindhoven`), and further.
    private func calls(eindhoven: Double) -> [TrainRules.StayCall] {
        [TrainRules.StayCall(name: "Breda", p: p(0), arrival: at(0)),
         TrainRules.StayCall(name: "Tilburg", p: p(20_000), arrival: at(1500)),
         TrainRules.StayCall(name: "Eindhoven", p: p(50_050), arrival: at(eindhoven)),
         TrainRules.StayCall(name: "Helmond", p: p(62_000), arrival: at(eindhoven + 600))]
    }

    /// The through train reaches Eindhoven before the planned change does: one leg less, no stop at Tilburg.
    func test_throughTrainReachingTheNextChangeInTimeIsMerged() {
        let s = TrainRules.stayOn(index: 0, legs: through, tripId: "t3529", num: "3529", calls: calls(eindhoven: 3840), now: at(60))
        XCTAssertEqual(s, TrainRules.StayHit(leg: 1, call: 2, sameTrain: false))
        // a minute after the planned one is still fine (+2 min)
        XCTAssertEqual(TrainRules.stayOn(index: 0, legs: through, tripId: "t3529", num: "3529", calls: calls(eindhoven: 3990), now: at(60))?.leg, 1)
    }

    /// Slower than the planned change (more than 2 minutes after it), or too late for the bus: the change stays.
    func test_slowerThroughTrainIsNotMerged() {
        XCTAssertNil(TrainRules.stayOn(index: 0, legs: through, tripId: "t3529", num: "3529", calls: calls(eindhoven: 4080), now: at(60)))
        var tight = through
        tight[2].departure = at(3930)
        XCTAssertNil(TrainRules.stayOn(index: 0, legs: tight, tripId: "t3529", num: "3529", calls: calls(eindhoven: 3900), now: at(60)),
                     "it must still leave a minute for the bus")
        // it doesn't go to Eindhoven at all
        let short = Array(calls(eindhoven: 3840).prefix(2))
        XCTAssertNil(TrainRules.stayOn(index: 0, legs: through, tripId: "t3529", num: "3529", calls: short, now: at(60)))
        // already past Eindhoven: a call behind you doesn't count
        XCTAssertNil(TrainRules.stayOn(index: 0, legs: through, tripId: "t3529", num: "3529", calls: calls(eindhoven: 3840), now: at(3850)))
    }

    /// The plan split one train in two legs (the same number, or the same trip): always one leg.
    func test_sameTrainNumberAcrossLegsIsMerged() {
        var split = through
        split[1].tripId = "other-id"; split[1].num = "IC 3529"
        // even with no stop list at all, and even when its times say it's later
        XCTAssertEqual(TrainRules.stayOn(index: 0, legs: split, tripId: "t3529", num: "3529", calls: [], now: at(60)),
                       TrainRules.StayHit(leg: 1, call: nil, sameTrain: true))
        var byTrip = through
        byTrip[1].tripId = "t3529"; byTrip[1].num = ""
        XCTAssertEqual(TrainRules.stayOn(index: 0, legs: byTrip, tripId: "t3529", num: "", calls: calls(eindhoven: 4500), now: at(60)),
                       TrainRules.StayHit(leg: 1, call: 2, sameTrain: true))
        XCTAssertNil(TrainRules.stayOn(index: 0, legs: through, tripId: "t3529", num: "3529", calls: [], now: at(60)), "another number: not the same train")
    }

    /// The next ride's boarding stop counts too (the bus bay by the station), as does the station by its name.
    func test_stayOnByTheRideAftersStopOrTheStationName() {
        var legs = through
        legs[1].to = p(51_000)            // the leg's own stop placed 950 m off: by its name ("Eindhoven Centraal")
        XCTAssertEqual(TrainRules.stayOn(index: 0, legs: legs, tripId: "t3529", num: "3529", calls: calls(eindhoven: 3840), now: at(60))?.call, 2)
        legs[1].toName = "Somewhere else"
        legs[2].from = p(50_200)          // …or the bus bay right by where it calls
        XCTAssertEqual(TrainRules.stayOn(index: 0, legs: legs, tripId: "t3529", num: "3529", calls: calls(eindhoven: 3840), now: at(60))?.call, 2)
        legs[2].from = p(53_000); legs[2].fromName = "Elsewhere"
        XCTAssertNil(TrainRules.stayOn(index: 0, legs: legs, tripId: "t3529", num: "3529", calls: calls(eindhoven: 3840), now: at(60)))
    }

    /// Planned: IC to Tilburg (leg 0), Sprinter Tilburg → Den Bosch (leg 1, the last, no planned arrival). You're on
    /// the through Intercity, which calls there: stay on to the end.
    func test_stayOnToTheEndOfTheLastLeg() {
        let legs = [TrainRules.StayLeg(from: p(0), to: p(3000), departure: t0),
                    TrainRules.StayLeg(from: p(3000), to: p(6000), departure: at(900))]
        let c = [TrainRules.StayCall(name: "", p: p(0), arrival: t0), TrainRules.StayCall(name: "", p: p(3000), arrival: at(600)),
                 TrainRules.StayCall(name: "", p: p(6000), arrival: at(1200))]
        XCTAssertEqual(TrainRules.stayOn(index: 0, legs: legs, tripId: "x", num: "", calls: c, now: at(60)), TrainRules.StayHit(leg: 1, call: 2, sameTrain: false))
        XCTAssertNil(TrainRules.stayOn(index: 0, legs: legs, tripId: "x", num: "", calls: Array(c.prefix(2)), now: at(60)))
        XCTAssertNil(TrainRules.stayOn(index: 1, legs: legs, tripId: "x", num: "", calls: c, now: at(60)), "the last leg: nothing to merge")
    }

    func test_stayLog() {
        XCTAssertEqual(TrainRules.stayLog(vehicle: "IC 3529", reaches: "Eindhoven", at: "15:44", changeAt: "Tilburg", changeTime: "15:05",
                                          next: "IC 3631", nextTime: "15:12", sameTrain: false),
                       "stay on · IC 3529 also reaches Eindhoven 15:44 (plan changed at Tilburg 15:05 → IC 3631 15:12)")
        XCTAssertEqual(TrainRules.stayLog(vehicle: "IC 3529", reaches: "Eindhoven", at: "", changeAt: "Tilburg", changeTime: "",
                                          next: "", nextTime: "", sameTrain: true),
                       "stay on · IC 3529 is the next leg's train too: on to Eindhoven (plan split it at Tilburg)")
    }

    /// The headline goes by where the vehicle really goes, never "Intercity to <your stop>".
    func test_headlineUsesTheHeadsign() {
        let h = TrainRules.headline(vehicle: "Intercity", headsign: "Zwolle", legEnd: "Tilburg", stayOnTo: nil)
        XCTAssertEqual(h.title, "Intercity to Zwolle")
        XCTAssertEqual(h.detail, "Get off at Tilburg")
        XCTAssertEqual(TrainRules.headline(vehicle: "Intercity", headsign: "Zwolle", legEnd: "Eindhoven", stayOnTo: "Eindhoven").title, "Stay on to Eindhoven")
        XCTAssertEqual(TrainRules.headline(vehicle: "Intercity", headsign: "Zwolle", legEnd: "Eindhoven", stayOnTo: "Eindhoven").detail, "Intercity to Zwolle")
        // it ends where you get off: just that
        let end = TrainRules.headline(vehicle: "Bus 305", headsign: "Eindhoven, Station", legEnd: "Eindhoven Centraal", stayOnTo: nil)
        XCTAssertEqual(end.title, "Bus 305 to Eindhoven, Station")
        XCTAssertNil(end.detail)
        // no headsign known: the vehicle alone, and where you get off
        XCTAssertEqual(TrainRules.headline(vehicle: "Sprinter", headsign: "", legEnd: "Tilburg", stayOnTo: nil).title, "Sprinter")
        XCTAssertEqual(TrainRules.lockHeadline(vehicle: "Intercity", headsign: "Zwolle", legEnd: "Tilburg", stayOnTo: nil),
                       "Intercity to Zwolle · get off at Tilburg")
        XCTAssertEqual(TrainRules.lockHeadline(vehicle: "Intercity", headsign: "Zwolle", legEnd: "Eindhoven", stayOnTo: "Eindhoven"), "Stay on to Eindhoven")
    }
}
