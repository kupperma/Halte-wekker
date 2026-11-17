import XCTest

/// 0.20.3: the matcher judges a vehicle with a fresh GPS fix of its own by where that fix puts it, keeps the ride's
/// own one by it, and takes one in the fast lane. Without a fresh fix everything is as before.
final class GPSMatchTests: XCTestCase {
    private let t0 = Fx.t0

    /// A fix of the vehicle `m` metres along the railway at `t0 + dt`.
    private func fix(_ m: Double, at dt: TimeInterval, north: Double = 0, bearing: Double? = 90, speed: Double? = nil) -> GPSFix {
        let p = Fx.east(m, north: north)
        return GPSFix(lat: p.lat, lon: p.lon, bearing: bearing, at: t0.addingTimeInterval(dt), speed: speed)
    }

    private func bus(_ id: String = "305-4779", at m0: Double, speed: Double, gps: VehicleGPS? = nil) -> VehicleTrack {
        var v = Fx.track(id, line: "305", train: false, path: Fx.railway, at: m0, speed: speed)
        v.gps = gps
        return v
    }

    // MARK: judged by its own GPS

    /// Bus 305 on the highway: its times plus its delay put it 1200 m behind you; its GPS (40 s old, moved on) puts it
    /// with you. By its times: "1200 m from its times"; by its GPS: it passes, logged as "gps".
    func test_highway_byGPSNotByItsTimes() throws {
        let you = Fx.fixes(from: 1500, speed: 25, count: 16)                   // t0 … t0+30, 1500 … 2250 m
        let byTimes = bus(at: 300, speed: 25)
        XCTAssertEqual(Fx.why(VehicleMatch.judgeAll(you, [byTimes]), "305-4779"), .tooFarFromTimes)
        let withGPS = bus(at: 300, speed: 25, gps: VehicleGPS(fix: fix(1250, at: -10)))
        let j = VehicleMatch.judgeAll(you, [withGPS])
        let cost = try XCTUnwrap(Fx.ok(j, "305-4779"), "\(j)")
        XCTAssertLessThan(cost, 5)
        let e = try XCTUnwrap(j.first?.evidence)
        XCTAssertTrue(e.gps)
        XCTAssertEqual(try XCTUnwrap(e.gpsAge), 40, accuracy: 0.5)
        XCTAssertEqual(e.offset, 0, accuracy: 15)
        XCTAssertTrue(FieldFormat.match("on board", j, outcome: "best 305·4779").contains("305·4779 gps "))
    }

    /// Drifting by its times (its piece's even 12 m/s against your 25), not by its GPS: between its last two fixes it
    /// went 25 m/s.
    func test_drifting_usesItsGPSSpeed() throws {
        let you = Fx.fixes(from: 1000, speed: 25, count: 16)
        XCTAssertEqual(Fx.why(VehicleMatch.judgeAll(you, [bus(at: 1000, speed: 12)]), "305-4779"), .drifting)
        let g = VehicleGPS(fix: fix(1250, at: 10), previous: fix(500, at: -20))
        let j = VehicleMatch.judgeAll(you, [bus(at: 1000, speed: 12, gps: g)])
        XCTAssertNotNil(Fx.ok(j, "305-4779"), "\(j)")
        let e = try XCTUnwrap(j.first?.evidence)
        XCTAssertTrue(e.speedKnown)
        XCTAssertEqual(try XCTUnwrap(e.gpsSpeed), 25, accuracy: 0.5)
        XCTAssertEqual(e.itsSpeed, 25, accuracy: 0.5)
        XCTAssertEqual(e.drift, 0, accuracy: 1)
        // its GPS says it really goes 10 m/s while you go 25: drifting, by its GPS speed
        let slow = VehicleGPS(fix: fix(1250, at: 10), previous: fix(950, at: -20))
        let k = VehicleMatch.judgeAll(you, [bus(at: 1000, speed: 25, gps: slow)])
        XCTAssertEqual(Fx.why(k, "305-4779"), .drifting, "\(k)")
        XCTAssertTrue(FieldFormat.match("same bus", k, outcome: "x").contains("305·4779 gps drifting 15 m/s"))
    }

    /// The Sprinter: "wrong speed (you 7 m/s, it 23)" by its times; NS gives its own speed (25 km/h): it passes.
    func test_trainWrongSpeed_usesItsOwnSpeed() throws {
        let you = Fx.fixes(from: 1000, speed: 7, count: 16)
        let sprinter = Fx.track("spr-2416", line: "SPR", train: true, path: Fx.railway, at: 1000, speed: 23)
        XCTAssertEqual(Fx.why(VehicleMatch.judgeAll(you, [sprinter]), "spr-2416"), .implausibleSpeed)
        var withGPS = sprinter
        withGPS.gps = VehicleGPS(fix: fix(1070, at: 10, speed: 7))
        let j = VehicleMatch.judgeAll(you, [withGPS])
        XCTAssertNotNil(Fx.ok(j, "spr-2416"), "\(j)")
        XCTAssertEqual(try XCTUnwrap(j.first?.evidence?.gpsSpeed), 7, accuracy: 0.01)
    }

    /// Where its GPS puts it replaces where its times put it: right where its times say, but 1500 m behind by its GPS.
    func test_GPSFarBehind_isFromItsTimes() {
        let you = Fx.fixes(from: 3000, speed: 25, count: 16)
        let onTime = bus(at: 3000, speed: 25)
        XCTAssertNotNil(Fx.ok(VehicleMatch.judgeAll(you, [onTime]), "305-4779"))
        var behind = onTime
        behind.gps = VehicleGPS(fix: fix(1750, at: 10))
        let j = VehicleMatch.judgeAll(you, [behind])
        XCTAssertEqual(Fx.why(j, "305-4779"), .tooFarFromTimes)
        XCTAssertEqual(j.first?.evidence?.gps, true)
    }

    /// A stale fix (more than 90 s before your newest), a fix off its road, or none: everything exactly as before.
    func test_staleOrOffRoadFix_isAsBefore() {
        let you = Fx.fixes(from: 1500, speed: 25, count: 16)
        let plain = bus(at: 300, speed: 25)
        let before = VehicleMatch.judgeAll(you, [plain])
        XCTAssertEqual(Fx.why(before, "305-4779"), .tooFarFromTimes)
        for g in [VehicleGPS(fix: fix(1250, at: -61)),                     // 91 s before your newest fix
                  VehicleGPS(fix: fix(2200, at: 25, north: 300)),           // 300 m beside its road
                  VehicleGPS(fix: fix(2200, at: 120))] {                    // 90 s ahead of your newest
            var v = plain
            v.gps = g
            let j = VehicleMatch.judgeAll(you, [v])
            XCTAssertEqual(j, before, "\(g)")
            XCTAssertEqual(VehicleMatch.judgeOne(you.last!, v, tolerance: 1000), VehicleMatch.judgeOne(you.last!, plain, tolerance: 1000))
        }
        XCTAssertFalse(FieldFormat.match("on board", before, outcome: "none").contains("gps"))
    }

    /// Its GPS speed from before your fixes (it was at a stop then): the speed tests skip it, its place still counts.
    func test_speedFromBeforeYourFixes_isNotJudgedBy() throws {
        let you = Fx.fixes(from: 1000, speed: 25, count: 16)
        // standing between its last two fixes (40 s and 70 s before your newest), moved on at its piece's speed since
        let g = VehicleGPS(fix: fix(1000, at: -10), previous: fix(1000, at: -40))
        let j = VehicleMatch.judgeAll(you, [bus(at: 1000, speed: 25, gps: g)])
        let e = try XCTUnwrap(j.first?.evidence)
        XCTAssertFalse(e.speedKnown)
        XCTAssertEqual(try XCTUnwrap(e.gpsSpeed), 0, accuracy: 0.01)
        XCTAssertNotNil(Fx.ok(j, "305-4779"), "\(j)")
    }

    /// One fix alone (the on-board look before 20 s of fixes): by its GPS too.
    func test_judgeOne_byGPS() {
        let f = Fx.fixes(from: 1500, speed: 25, count: 1)[0]
        let plain = bus(at: 300, speed: 25)
        XCTAssertEqual(Fx.why([VehicleMatch.judgeOne(f, plain, tolerance: 1000)], "305-4779"), .tooFarFromTimes)
        var v = plain
        v.gps = VehicleGPS(fix: fix(1250, at: -10))
        let j = VehicleMatch.judgeOne(f, v, tolerance: 1000)
        XCTAssertNotNil(Fx.ok([j], "305-4779"), "\(j)")
        XCTAssertEqual(j.evidence?.gps, true)
        XCTAssertEqual(j.evidence?.headingOff ?? 99, 0, accuracy: 1)
    }

    /// A GPS failure is a real one (not "by its times only"), and one judged by GPS counts as live.
    func test_GPSFailureIsNotTimesOnly_andCountsAsLive() {
        let you = Fx.fixes(from: 3000, speed: 25, count: 16)
        var v = bus(at: 3000, speed: 25, gps: VehicleGPS(fix: fix(1750, at: 10)))
        v = VehicleTrack(tripId: v.tripId, line: v.line, isTrain: false, realTime: false, pieces: v.pieces, gps: v.gps)
        let j = VehicleMatch.judgeAll(you, [v], strictTimes: false)
        XCTAssertEqual(Fx.why(j, "305-4779"), .tooFarFromTimes, "a timetable-only one by its GPS is judged by it, also while choosing")
        XCTAssertFalse(VehicleMatch.timesOnly(j[0]))
        XCTAssertEqual(VehicleMatch.liveIds(j), ["305-4779"])
        let t = VehicleMatch.judgeAll(you, [bus("b", at: 1000, speed: 25)])
        XCTAssertTrue(VehicleMatch.timesOnly(t[0]))
    }

    // MARK: keeping the ride's own one

    private func evidence(offset: Double = 0, crossTrack: Double = 10, progress: Double = 700, you: Double = 25, drift: Double = 0,
                          gps: Bool = true, speedKnown: Bool = true, gpsSpeed: Double? = 25) -> Evidence {
        var e = Evidence(fixes: 15, span: 28, crossTrack: crossTrack, accuracy: 10, shaped: true, progress: progress, offset: offset,
                         drift: drift, yourSpeed: you, itsSpeed: 25, steady: true)
        e.gps = gps; e.speedKnown = speedKnown; e.gpsSpeed = gpsSpeed
        return e
    }

    func test_gpsKeeps() {
        XCTAssertTrue(VehicleMatch.gpsKeeps(evidence(offset: -180), isTrain: false))
        XCTAssertFalse(VehicleMatch.gpsKeeps(evidence(offset: 260), isTrain: false), "further than 200 m")
        XCTAssertFalse(VehicleMatch.gpsKeeps(evidence(gps: false), isTrain: false), "not by its GPS")
        XCTAssertFalse(VehicleMatch.gpsKeeps(nil, isTrain: false))
        XCTAssertFalse(VehicleMatch.gpsKeeps(evidence(crossTrack: 90), isTrain: false), "you're off its path")
        XCTAssertFalse(VehicleMatch.gpsKeeps(evidence(progress: 20, you: 1), isTrain: false), "you're standing")
        XCTAssertFalse(VehicleMatch.gpsKeeps(evidence(progress: -700), isTrain: false), "the other way")
        XCTAssertFalse(VehicleMatch.gpsKeeps(evidence(drift: 14), isTrain: false), "not moving with you")
        XCTAssertTrue(VehicleMatch.gpsKeeps(evidence(drift: 14, speedKnown: false), isTrain: false), "its speed from before your fixes")
        XCTAssertFalse(VehicleMatch.gpsKeeps(evidence(speedKnown: false, gpsSpeed: 0), isTrain: false), "it was standing then")
        XCTAssertTrue(VehicleMatch.gpsKeeps(evidence(speedKnown: false, gpsSpeed: nil), isTrain: false), "no speed of its own")
        XCTAssertFalse(VehicleMatch.gpsKeeps(evidence(you: 40), isTrain: false), "faster than a bus")
        XCTAssertTrue(VehicleMatch.gpsKeeps(evidence(you: 40, gpsSpeed: 40), isTrain: true))
    }

    /// The 305 at 13:24: drifting by its times, kept by its GPS (and judged by it, it passes as well).
    func test_highwayDriftByTimes_keptByGPS() throws {
        let you = Fx.fixes(from: 1000, speed: 25, count: 16)
        let v = bus(at: 1000, speed: 12, gps: VehicleGPS(fix: fix(1350, at: 10), previous: fix(600, at: -20)))
        let j = try XCTUnwrap(VehicleMatch.judgeAll(you, [v], strictTimes: false).first)
        XCTAssertTrue(VehicleMatch.gpsKeeps(j.evidence, isTrain: false), "\(j)")
        let plain = try XCTUnwrap(VehicleMatch.judgeAll(you, [bus(at: 1000, speed: 12)], strictTimes: false).first)
        XCTAssertFalse(VehicleMatch.gpsKeeps(plain.evidence, isTrain: false))
    }

    // MARK: the fast lane

    private func lane(_ id: String, gps: Bool = true, metres: Double? = 60, turn: Double? = 5, passed: Bool = true,
                      plausible: Bool = true) -> MatchRules.LaneCandidate {
        MatchRules.LaneCandidate(id: id, gps: gps, metres: metres, headingOff: turn, passed: passed, plausible: plausible)
    }

    func test_fastLane_rule() {
        let one = lane("a")
        XCTAssertEqual(MatchRules.fastLane([one], yourSpeed: 20, fixes: 2, span: 8), "a")
        XCTAssertEqual(MatchRules.fastLane([one, lane("far", gps: false, metres: 900)], yourSpeed: 20, fixes: 2, span: 8), "a")
        // too little: 1 fix, or 7 s
        XCTAssertNil(MatchRules.fastLane([one], yourSpeed: 20, fixes: 1, span: 8))
        XCTAssertNil(MatchRules.fastLane([one], yourSpeed: 20, fixes: 2, span: 7))
        // slow: 11 m/s or less
        XCTAssertNil(MatchRules.fastLane([one], yourSpeed: 11, fixes: 2, span: 8))
        XCTAssertNil(MatchRules.fastLane([one], yourSpeed: .nan, fixes: 2, span: 8))
        // the wrong heading, or none known
        XCTAssertNil(MatchRules.fastLane([lane("a", turn: 50)], yourSpeed: 20, fixes: 2, span: 8))
        XCTAssertNil(MatchRules.fastLane([lane("a", turn: nil)], yourSpeed: 20, fixes: 2, span: 8))
        // further than 150 m, not by GPS (a stale fix: judged by its times), or it didn't pass
        XCTAssertNil(MatchRules.fastLane([lane("a", metres: 160)], yourSpeed: 20, fixes: 2, span: 8))
        XCTAssertNil(MatchRules.fastLane([lane("a", gps: false)], yourSpeed: 20, fixes: 2, span: 8))
        XCTAssertNil(MatchRules.fastLane([lane("a", passed: false)], yourSpeed: 20, fixes: 2, span: 8))
        // a rival within 400 m that could be it: by its times, or by its GPS (two by GPS within 150 m: not exactly one)
        XCTAssertNil(MatchRules.fastLane([one, lane("b", gps: false, metres: 380)], yourSpeed: 20, fixes: 2, span: 8))
        XCTAssertNil(MatchRules.fastLane([one, lane("b", metres: 300, passed: false)], yourSpeed: 20, fixes: 2, span: 8))
        XCTAssertNil(MatchRules.fastLane([one, lane("b", metres: 100)], yourSpeed: 20, fixes: 2, span: 8))
        // …one that can't be it (off its path, the other way) doesn't count, nor one without evidence
        XCTAssertEqual(MatchRules.fastLane([one, lane("b", gps: false, metres: 50, passed: false, plausible: false)],
                                           yourSpeed: 20, fixes: 2, span: 8), "a")
        XCTAssertEqual(MatchRules.fastLane([one, lane("b", gps: false, metres: nil, passed: false, plausible: false)],
                                           yourSpeed: 20, fixes: 2, span: 8), "a")
    }

    /// The whole way: 5 fixes over 8 s at 20 m/s, the 305 by its GPS with you.
    func test_fastLane_judged() {
        let you = Fx.fixes(from: 1000, speed: 20, count: 5)            // t0 … t0+8
        let mine = bus(at: 0, speed: 20, gps: VehicleGPS(fix: fix(800, at: -10)))
        func take(_ vs: [VehicleTrack], speed: Double = 20, fixes: [Fix]? = nil) -> String? {
            let f = fixes ?? you
            let j = VehicleMatch.judgeAll(f, vs, minFixes: MatchRules.fastFixes, minSpan: MatchRules.fastSpan)
            let s = VehicleMatch.spread(f)
            return MatchRules.fastLane(VehicleMatch.lane(j), yourSpeed: speed, fixes: s.fixes, span: s.span)
        }
        XCTAssertEqual(take([mine, bus("far", at: 3500, speed: 20)]), "305-4779")
        // not enough for the usual rules
        XCTAssertNil(Fx.ok(VehicleMatch.judgeAll(you, [mine]), "305-4779"))
        // a rival nearby: another 305 by its times 300 m ahead of you
        XCTAssertNil(take([mine, bus("rival", at: 1300, speed: 20)]))
        // a stale fix (100 s old): judged by its times, 1000 m off
        XCTAssertNil(take([bus(at: 0, speed: 20, gps: VehicleGPS(fix: fix(800, at: -92)))]))
        // slow: 10 m/s
        let slow = Fx.fixes(from: 1000, speed: 10, count: 5)
        XCTAssertNil(take([bus(at: 0, speed: 10, gps: VehicleGPS(fix: fix(900, at: -10)))], speed: 10, fixes: slow))
        // the wrong heading: its own GPS says it points south
        XCTAssertNil(take([bus(at: 0, speed: 20, gps: VehicleGPS(fix: fix(800, at: -10, bearing: 180)))]))
    }
}
