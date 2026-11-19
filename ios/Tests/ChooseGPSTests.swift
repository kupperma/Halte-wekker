import XCTest

/// Choosing between two buses on a shared road (0.26.1): their own GPS decides, the one shown (the planned one) only
/// wins a real tie. The sequences are shaped like the field log of 2026-11-18/19 (305 against 306 out of Veghel, and
/// 157 against 305).
final class ChooseGPSTests: XCTestCase {
    private let t0 = Fx.t0

    private enum Kind { case gps, live, timetable }

    /// One judged bus as a field log line shows it: "305·7821 gps 13 s", "306·7954 live drifting 10 m/s",
    /// "306·7954 gps 424 m from its times", "… too few fixes", "… off its path 1309 m".
    private func j(_ id: String, _ kind: Kind, _ r: Result<Double, Reject>, cross: Double = 8) -> Judgement {
        var e: Evidence? = Evidence(fixes: 15, span: 28, crossTrack: cross, accuracy: 15, shaped: true, progress: 300, offset: 0,
                                    drift: 0, yourSpeed: 11, itsSpeed: 11, steady: true)
        e?.gps = kind == .gps
        if case .failure(let why) = r, why == .tooFewFixes { e = nil }
        return Judgement(id: id, line: id, isTrain: false, realTime: kind != .timetable, evidence: e, result: r)
    }

    private struct Look {
        let at: TimeInterval        // s after t0
        let judged: [Judgement]
        var offRoad = false
    }

    /// Every look in turn, with the state carried from look to look, until one settles. `gps` is carried in (and out).
    private func run(_ ids: [String], shown: String, start: TimeInterval, _ seq: [Look], gps: inout GPSChoice) -> [ChoiceLook] {
        var misses: [String: Int] = [:], state = SwitchState()
        var out: [ChoiceLook] = []
        for l in seq {
            let c = VehicleMatch.choose(ids, judged: l.judged, shown: shown, shownOffRoad: l.offRoad, choosingFor: l.at - start,
                                        misses: &misses, state: &state, gps: &gps, now: t0 + l.at)
            out.append(c)
            if c.settle != nil { break }
        }
        return out
    }

    private func run(_ ids: [String], shown: String, start: TimeInterval, _ seq: [Look]) -> [ChoiceLook] {
        var gps = GPSChoice()
        return run(ids, shown: shown, start: start, seq, gps: &gps)
    }

    /// Seconds after 07:25:44 (the ride start) for a log time "07:mm:ss".
    private func at(_ mm: Int, _ ss: Int) -> TimeInterval { TimeInterval((mm - 25) * 60 + ss - 44) }

    /// 2026-11-19, oldest first: the choice between the planned 306·7954 (shown) and 305·7821 (the one the user was on).
    private var log19: [Look] {
        let a = "306", b = "305"
        return [
            Look(at: at(25, 58), judged: [j(a, .gps, .success(34)), j(b, .live, .failure(.standing))]),
            Look(at: at(26, 11), judged: [j(b, .live, .success(38)), j(a, .gps, .success(56))]),
            Look(at: at(26, 23), judged: [j(b, .live, .success(28)), j(a, .gps, .success(49))]),
            Look(at: at(26, 37), judged: [j(a, .gps, .success(25)), j(b, .live, .success(35))]),
            Look(at: at(26, 53), judged: [j(b, .gps, .success(15)), j(a, .gps, .success(33))]),
            Look(at: at(27, 7), judged: [j(b, .gps, .success(8)), j(a, .gps, .success(8))]),
            Look(at: at(27, 44), judged: [j(a, .gps, .failure(.tooFewFixes)), j(b, .live, .failure(.tooFewFixes))]),
            Look(at: at(27, 58), judged: [j(a, .gps, .failure(.tooFewFixes)), j(b, .gps, .failure(.tooFewFixes))]),
            Look(at: at(28, 14), judged: [j(a, .live, .success(1)), j(b, .gps, .success(11))]),
            Look(at: at(28, 27), judged: [j(b, .gps, .success(0)), j(a, .live, .failure(.drifting))]),
            Look(at: at(28, 41), judged: [j(b, .gps, .success(13)), j(a, .live, .failure(.drifting))]),
            Look(at: at(28, 56), judged: [j(b, .gps, .success(48)), j(a, .gps, .failure(.tooFarFromTimes))]),
            Look(at: at(29, 9), judged: [j(a, .gps, .success(32)), j(b, .gps, .success(72))]),
            Look(at: at(29, 21), judged: [j(a, .gps, .success(18)), j(b, .live, .failure(.drifting))]),
            Look(at: at(29, 33), judged: [j(a, .live, .success(40)), j(b, .live, .failure(.tooFarFromTimes))]),
        ]
    }

    /// The 305 fits by its own GPS while the planned 306 drifts and is 424 m from where its GPS puts it: the 305 by
    /// 07:28:56, never "keep 306 · the only one left".
    func test_log19_305WinsByItsGPS() {
        let out = run(["306", "305"], shown: "306", start: 0, log19)
        XCTAssertEqual(out.last?.settle, "305")
        XCTAssertEqual(out.last?.why, .byGPS)
        XCTAssertEqual(out.count, 12)                                   // the look at 07:28:56
        XCTAssertTrue(out.dropLast().allSatisfy { $0.settle == nil })   // nothing sure before (both fitted about as well)
        XCTAssertTrue(out.allSatisfy { $0.alive == ["306", "305"] })
        // before: kept the planned 306 every look, then "the only one left" at 07:29:33
        XCTAssertEqual(out.last?.decision, .switchTo("305"))
    }

    /// The same log from 07:29:09 (the 305 just fitted by its GPS): its times saying it's off in the next two looks (its
    /// GPS feed quiet) is no miss, so the 306 isn't "the only one left".
    func test_log19_oneQuietRoundDoesNotHandItOver() {
        let tail = Array(log19.suffix(3))
        let out = run(["306", "305"], shown: "306", start: 0, tail)
        XCTAssertEqual(out.count, 3)
        XCTAssertTrue(out.allSatisfy { $0.settle == nil && $0.alive == ["306", "305"] })
        XCTAssertNotEqual(out.last?.why, .onlyOneLeft)
    }

    /// One bad round of the better-fitting bus by its own GPS: the other one leads that look, but nothing settles, and
    /// the better one wins once it fits again.
    func test_oneBadRoundOfTheBetterOne() {
        let a = "306", b = "305"
        let seq = [
            Look(at: 0, judged: [j(b, .gps, .success(5)), j(a, .gps, .failure(.tooFarFromTimes))]),
            Look(at: 12, judged: [j(b, .gps, .failure(.tooFarFromTimes)), j(a, .gps, .success(20))]),
            Look(at: 24, judged: [j(b, .gps, .success(6)), j(a, .gps, .failure(.tooFarFromTimes))]),
            Look(at: 36, judged: [j(b, .gps, .success(4)), j(a, .gps, .failure(.tooFarFromTimes))]),
        ]
        let out = run([a, b], shown: a, start: -20, seq)
        XCTAssertEqual(out.count, 4)
        XCTAssertEqual(out.map(\.settle), [nil, nil, nil, b])
        XCTAssertEqual(out[1].alive, [a, b])                            // one miss: still in the running
        XCTAssertEqual(out.last?.why, .byGPS)
    }

    /// 2026-11-18: the planned 305·4806 (shown) 598 m, 4044 m and 500 m from its times while the 157·4262 fitted by its
    /// GPS: the 157 after two looks (it kept the 305 eight minutes, through the approach alarm).
    func test_log18_157WinsOverPlanned305() {
        let a = "4806", b = "4262"
        let seq = [
            Look(at: 0, judged: [j(b, .gps, .success(13)), j(a, .gps, .failure(.tooFarFromTimes))]),
            Look(at: 12, judged: [j(b, .gps, .success(18)), j(a, .live, .failure(.tooFarFromTimes))]),
            Look(at: 24, judged: [j(b, .gps, .success(73)), j(a, .gps, .failure(.tooFarFromTimes))]),
        ]
        let out = run([a, b], shown: a, start: -8, seq)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out.last?.settle, b)
        XCTAssertEqual(out.last?.why, .byGPS)
    }

    /// The roads part: the one shown is 1309 m off its path while the other fits: that one at once.
    func test_roadsPartSwitchAtOnce() {
        let out = run(["306", "305"], shown: "306", start: -60, [
            Look(at: 0, judged: [j("305", .live, .success(20)), j("306", .gps, .failure(.offItsPath), cross: 1309)]),
        ])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.last?.settle, "305")
        XCTAssertEqual(out.last?.why, .split)
        // the other one that far off: out at once, the one shown is the only one left
        let other = run(["305", "306"], shown: "305", start: -60, [
            Look(at: 0, judged: [j("305", .gps, .success(20)), j("306", .gps, .failure(.offItsPath), cross: 1309)]),
        ])
        XCTAssertEqual(other.last?.alive, ["305"])
        XCTAssertEqual(other.last?.settle, "305")
        XCTAssertEqual(other.last?.why, .onlyOneLeft)
        // a little off its path (the usual test's 60 m, not 300): no split
        let near = run(["306", "305"], shown: "306", start: -60, [
            Look(at: 0, judged: [j("305", .live, .success(20)), j("306", .gps, .failure(.offItsPath), cross: 120)]),
        ])
        XCTAssertNil(near.last?.settle)
        XCTAssertFalse(VehicleMatch.roadsParted(j("x", .gps, .failure(.offItsPath), cross: 299)))
        XCTAssertTrue(VehicleMatch.roadsParted(j("x", .gps, .failure(.offItsPath), cross: 300)))
        XCTAssertFalse(VehicleMatch.roadsParted(j("x", .gps, .failure(.drifting), cross: 900)))
    }

    // MARK: - No flip-flop

    /// The two trade the lead by GPS look after look: never a switch; after 12 minutes it keeps the one shown.
    func test_alternatingLeadNeverSwitches() {
        let seq: [Look] = (0..<70).map { k in
            let b = k % 2 == 0
            return Look(at: 12 * Double(k), judged: [
                j("305", .gps, b ? .success(5) : .failure(.tooFarFromTimes)),
                j("306", .gps, b ? .failure(.tooFarFromTimes) : .success(5)),
            ])
        }
        let out = run(["306", "305"], shown: "306", start: -8, seq)
        XCTAssertTrue(out.dropLast().allSatisfy { $0.settle == nil && $0.decision == .keep("306") })
        XCTAssertEqual(out.last?.settle, "306")
        XCTAssertEqual(out.last?.why, .timedOut)
    }

    /// Both fit by GPS about as well (less than 30 s apart): a real tie, the one shown is kept.
    func test_tieKeepsShown() {
        let seq: [Look] = (0..<20).map { k in
            Look(at: 12 * Double(k), judged: [j("305", .gps, .success(k % 2 == 0 ? 2 : 20)), j("306", .gps, .success(22))])
        }
        let out = run(["306", "305"], shown: "306", start: 0, seq)
        XCTAssertEqual(out.count, 20)
        XCTAssertTrue(out.allSatisfy { $0.settle == nil && $0.decision == .keep("306") })
    }

    /// After the switch to the 305, a new choice with the 305 shown: its times off while its GPS is quiet, the 306
    /// fitting by its GPS, doesn't switch back within the memory of the 305's own GPS fit.
    func test_noFlipBackAfterSwitch() {
        var gps = GPSChoice()
        let first = run(["306", "305"], shown: "306", start: 0, log19, gps: &gps)
        XCTAssertEqual(first.last?.settle, "305")
        XCTAssertNil(gps.leader)                                        // the run starts again; the GPS fits stay
        let s = at(28, 56)
        let back: [Look] = [
            Look(at: s + 30, judged: [j("305", .live, .failure(.drifting)), j("306", .gps, .success(18))]),
            Look(at: s + 42, judged: [j("305", .live, .failure(.tooFarFromTimes)), j("306", .gps, .success(20))]),
            Look(at: s + 54, judged: [j("305", .live, .failure(.drifting)), j("306", .gps, .success(15))]),
        ]
        let out = run(["305", "306"], shown: "305", start: s + 20, back, gps: &gps)
        XCTAssertEqual(out.count, 3)
        XCTAssertTrue(out.allSatisfy { $0.settle == nil && $0.decision == .keep("305") && $0.shown == .notSure })
    }

    // MARK: - The pieces

    func test_gpsBest() {
        let ids = ["a", "b"]
        XCTAssertEqual(VehicleMatch.gpsBest(ids, judged: [j("a", .gps, .success(5)), j("b", .live, .failure(.drifting))]), "a")
        XCTAssertEqual(VehicleMatch.gpsBest(ids, judged: [j("a", .gps, .success(5)), j("b", .gps, .success(35))]), "a")
        XCTAssertNil(VehicleMatch.gpsBest(ids, judged: [j("a", .gps, .success(5)), j("b", .gps, .success(34))]))
        // not sure, or no track, isn't failing; a timetable-only one's cost says nothing
        XCTAssertNil(VehicleMatch.gpsBest(ids, judged: [j("a", .gps, .success(5)), j("b", .live, .failure(.tooFewFixes))]))
        XCTAssertNil(VehicleMatch.gpsBest(ids, judged: [j("a", .gps, .success(5))]))
        XCTAssertNil(VehicleMatch.gpsBest(ids, judged: [j("a", .gps, .success(5)), j("b", .timetable, .success(90))]))
        // fitting by its times only isn't by GPS
        XCTAssertNil(VehicleMatch.gpsBest(ids, judged: [j("a", .live, .success(5)), j("b", .live, .failure(.drifting))]))
    }

    func test_softenedOnlyTimesOnlySoonAfterAGPSFit() {
        let drifting = j("a", .live, .failure(.drifting))
        XCTAssertTrue(VehicleMatch.softened(drifting, fitAt: t0, now: t0 + 90))
        XCTAssertFalse(VehicleMatch.softened(drifting, fitAt: t0, now: t0 + 91))
        XCTAssertFalse(VehicleMatch.softened(drifting, fitAt: nil, now: t0))
        // by its own GPS, off its path, the other way: never softened
        XCTAssertFalse(VehicleMatch.softened(j("a", .gps, .failure(.tooFarFromTimes)), fitAt: t0, now: t0 + 10))
        XCTAssertFalse(VehicleMatch.softened(j("a", .live, .failure(.offItsPath)), fitAt: t0, now: t0 + 10))
        XCTAssertFalse(VehicleMatch.softened(j("a", .live, .failure(.wrongWay)), fitAt: t0, now: t0 + 10))
        var fits: [String: Date] = ["old": t0 - 200]
        VehicleMatch.noteGPSFits([j("a", .gps, .success(3)), j("b", .live, .success(3))], into: &fits, now: t0)
        XCTAssertEqual(fits, ["a": t0])
    }

    func test_runNeedsLooksCloseTogether() {
        var g = GPSChoice()
        let look = [j("a", .gps, .success(5)), j("b", .gps, .failure(.tooFarFromTimes))]
        XCTAssertNil(VehicleMatch.gpsLook(["a", "b"], judged: look, run: &g, now: t0))
        XCTAssertNil(VehicleMatch.gpsLook(["a", "b"], judged: look, run: &g, now: t0 + 61))     // too long after: again
        XCTAssertEqual(VehicleMatch.gpsLook(["a", "b"], judged: look, run: &g, now: t0 + 73), "a")
        // a look that says nothing keeps the run; one where it fails ends it
        var h = GPSChoice()
        let tie = [j("a", .gps, .success(5)), j("b", .gps, .success(10))]
        let fails = [j("a", .gps, .failure(.tooFarFromTimes)), j("b", .gps, .success(10))]
        XCTAssertNil(VehicleMatch.gpsLook(["a", "b"], judged: look, run: &h, now: t0))
        XCTAssertNil(VehicleMatch.gpsLook(["a", "b"], judged: tie, run: &h, now: t0 + 12))
        XCTAssertEqual(h.leader, "a")
        XCTAssertEqual(VehicleMatch.gpsLook(["a", "b"], judged: look, run: &h, now: t0 + 24), "a")
        var k = GPSChoice()
        XCTAssertNil(VehicleMatch.gpsLook(["a", "b"], judged: look, run: &k, now: t0))
        XCTAssertNil(VehicleMatch.gpsLook(["a", "b"], judged: fails, run: &k, now: t0 + 12))
        XCTAssertEqual(k.leader, "b")
    }
}
