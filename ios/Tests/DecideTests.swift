import XCTest

final class DecideTests: XCTestCase {
    private let t0 = Fx.t0

    /// The decisions for one look per (time, ranked) pair, carrying the state from look to look.
    private func looks(shown: String?, live: Set<String>, _ seq: [(TimeInterval, [Ranked])]) -> [Decision] {
        var state = SwitchState()
        return seq.map { VehicleMatch.decide(shown: shown, ranked: $0.1, liveIds: live, state: &state, now: t0 + $0.0) }
    }

    private func lead(_ by: Double) -> [Ranked] { [Ranked(id: "B", cost: 10), Ranked(id: "A", cost: 10 + by)] }

    /// S5: bunching; the shown bus is timetable-only: never switched on its times.
    func test_S5_timetableOnlyKeepsShown() {
        let ranked = [Ranked(id: "B", cost: 4), Ranked(id: "A", cost: 250)]
        let out = looks(shown: "A", live: ["B"], (0..<10).map { (Double($0) * 12, ranked) })
        XCTAssertEqual(out, Array(repeating: .keep("A"), count: 10))
    }

    func test_S5b_switchAfterThreeLooks() {
        let out = looks(shown: "A", live: ["A", "B"], [(0, lead(90)), (24, lead(90)), (48, lead(90))])
        XCTAssertEqual(out, [.keep("A"), .keep("A"), .switchTo("B")])
    }

    func test_S5c_runRestarts() {
        let out = looks(shown: "A", live: ["A", "B"], [(0, lead(90)), (24, lead(30)), (48, lead(90)), (72, lead(90))])
        XCTAssertEqual(out, Array(repeating: .keep("A"), count: 4))
    }

    func test_threeLooksTooQuick() {
        let out = looks(shown: "A", live: ["A", "B"], [(0, lead(90)), (10, lead(90)), (20, lead(90)), (50, lead(90))])
        XCTAssertEqual(out, [.keep("A"), .keep("A"), .keep("A"), .switchTo("B")])
    }

    func test_shownRejectedSwitches() {
        let ranked = [Ranked(id: "B", cost: 10)]          // A failed the hard tests
        let out = looks(shown: "A", live: ["A", "B"], [(0, ranked), (24, ranked), (48, ranked)])
        XCTAssertEqual(out, [.keep("A"), .keep("A"), .switchTo("B")])
    }

    /// S8: many lines share the road out of the bus station.
    func test_S8_sharedRoadUndecided() {
        let ranked = [Ranked(id: "b1", cost: 10), Ranked(id: "b2", cost: 12), Ranked(id: "b3", cost: 40),
                      Ranked(id: "b4", cost: 80), Ranked(id: "b5", cost: 90)]
        let out = looks(shown: nil, live: ["b1", "b2", "b3", "b4", "b5"], [(0, ranked)])
        XCTAssertEqual(out, [.undecided(["b1", "b2", "b3"])])
    }

    /// S8: only those within 60 s of the best stay in the running.
    func test_S8_sixtySecondFilter() {
        let ranked = [Ranked(id: "b1", cost: 10), Ranked(id: "b2", cost: 12), Ranked(id: "b3", cost: 90)]
        XCTAssertEqual(looks(shown: nil, live: ["b1", "b2", "b3"], [(0, ranked)]), [.undecided(["b1", "b2"])])
    }

    func test_clearWinnerNoShown() {
        let two = [Ranked(id: "b1", cost: 10), Ranked(id: "b2", cost: 200)]
        XCTAssertEqual(looks(shown: nil, live: ["b1", "b2"], [(0, two)]), [.switchTo("b1")])
        XCTAssertEqual(looks(shown: nil, live: ["b1"], [(0, two)]), [.undecided(["b1", "b2"])])
        XCTAssertEqual(looks(shown: nil, live: [], [(0, [Ranked(id: "b1", cost: 300)])]), [.switchTo("b1")])
        XCTAssertEqual(looks(shown: nil, live: ["b1", "b2"], [(0, [])]), [Decision.none])
    }

    // MARK: - Dropping candidates

    private func judged(_ id: String, _ r: Result<Double, Reject>, live: Bool = true) -> Judgement {
        Judgement(id: id, line: "306", isTrain: false, realTime: live, evidence: nil, result: r)
    }

    /// The ids `prune` returns for each look, carrying the misses from look to look.
    private func pruned(keep: String?, _ seq: [[Judgement]]) -> [[String]] {
        var misses: [String: Int] = [:]
        return seq.map { VehicleMatch.prune($0, misses: &misses, keep: keep).map(\.id) }
    }

    func test_pruneDropsAfterTwoMisses() {
        let look = [judged("a", .success(10)), judged("b", .failure(.offItsPath))]
        XCTAssertEqual(pruned(keep: nil, [look, look]), [["a", "b"], ["a"]])
    }

    func test_pruneNeverDropsShown() {
        let look = [judged("a", .failure(.offItsPath)), judged("b", .success(10))]
        XCTAssertEqual(pruned(keep: "a", [look, look, look]), [["a", "b"], ["a", "b"], ["a", "b"]])
    }

    func test_pruneResetsOnSuccess() {
        let fail = [judged("a", .success(10)), judged("b", .failure(.wrongWay))]
        let pass = [judged("a", .success(10)), judged("b", .success(20))]
        XCTAssertEqual(pruned(keep: nil, [fail, pass, fail]), [["a", "b"], ["a", "b"], ["a", "b"]])
    }

    func test_pruneIgnoresTooFewFixes() {
        let few = [judged("a", .success(10)), judged("b", .failure(.tooFewFixes))]
        XCTAssertEqual(pruned(keep: nil, [few, few, few]), [["a", "b"], ["a", "b"], ["a", "b"]])
        // no times now isn't a failure either, and doesn't break a run of misses: fail, not sure, fail is out
        let none = [judged("a", .success(10)), judged("b", .failure(.noTimes))]
        let fail = [judged("a", .success(10)), judged("b", .failure(.offItsPath))]
        XCTAssertEqual(pruned(keep: nil, [none, none, none]), [["a", "b"], ["a", "b"], ["a", "b"]])
        XCTAssertEqual(pruned(keep: nil, [fail, none, fail]), [["a", "b"], ["a", "b"], ["a"]])
    }

    /// The one shown that is only "not sure yet" (too few fixes, no times now) hasn't failed: it's kept, and the run for
    /// the other one starts again.
    func test_unsureShownIsNotFailed() {
        let other = [Ranked(id: "B", cost: 10)]
        var state = SwitchState()
        func look(_ dt: TimeInterval, unsure: Set<String>) -> Decision {
            VehicleMatch.decide(shown: "A", ranked: other, liveIds: ["A", "B"], unsure: unsure, state: &state, now: t0 + dt)
        }
        XCTAssertEqual((0..<6).map { look(Double($0) * 24, unsure: ["A"]) }, Array(repeating: .keep("A"), count: 6))
        // failed, not sure, then failed 3 looks spanning 48 s: only the last 3 count
        let out = [look(200, unsure: []), look(224, unsure: ["A"]), look(248, unsure: []), look(272, unsure: []), look(296, unsure: [])]
        XCTAssertEqual(out, [.keep("A"), .keep("A"), .keep("A"), .keep("A"), .switchTo("B")])
    }

    // MARK: - The one shown, while it's not sure yet: today's road check

    /// How far `f` is from the path (today's road check measures the same).
    private func metres(_ f: Fix?, _ path: [GeoPoint]) -> Double? {
        f.flatMap { Geo.project($0.p, on: path)?.crossTrack }
    }

    func test_offRoadPinsToday() {
        XCTAssertFalse(VehicleMatch.offRoad(299, isTrain: false))
        XCTAssertTrue(VehicleMatch.offRoad(300, isTrain: false))
        XCTAssertFalse(VehicleMatch.offRoad(699, isTrain: true))
        XCTAssertTrue(VehicleMatch.offRoad(700, isTrain: true))
        XCTAssertFalse(VehicleMatch.offRoad(nil, isTrain: false))
    }

    /// The right bus, timetable-only and 4 minutes late: its times ended before your fixes, but you're on its road.
    func test_lateRightBusOnItsRoadNotFailed() {
        let path = Fx.railway
        // by its times it got to the end (6900 m) 4 minutes ago; you're 300 m before the end
        let bus = Fx.track("B", line: "306", train: false, live: false, path: path, at: 6900 + 10 * 240, speed: 10)
        let you = Fx.fixes(from: 6300, speed: 10, count: 16, start: t0 - 30)
        let j = VehicleMatch.judgeAll(you, [bus], strictTimes: false)
        XCTAssertEqual(Fx.why(j, "B"), .noTimes)
        let away = VehicleMatch.offRoad(metres(you.last, path), isTrain: false)
        XCTAssertFalse(away)
        XCTAssertEqual(VehicleMatch.verdict(j.first?.result, offRoad: away), .notSure)
    }

    /// The wrong one: its trip ended at a stop you passed, and you went on 500 m.
    func test_wrongEndedTripOffItsRoadFails() {
        let path = [Fx.east(0), Fx.east(1500), Fx.east(3000)]
        let bus = Fx.track("A", line: "305", train: false, live: false, path: path, at: 3000 + 10 * 300, speed: 10)
        let you = Fx.fixes(from: 3200, speed: 10, count: 16, start: t0 - 30)       // to 3500 m at t0
        let j = VehicleMatch.judgeAll(you, [bus], strictTimes: false)
        XCTAssertEqual(Fx.why(j, "A"), .noTimes)
        let m = metres(you.last, path) ?? 0
        XCTAssertEqual(m, 500, accuracy: 5)
        XCTAssertEqual(VehicleMatch.verdict(j.first?.result, offRoad: VehicleMatch.offRoad(m, isTrain: false)), .fails)
    }

    func test_verdict() {
        // no track: the road decides
        XCTAssertEqual(VehicleMatch.verdict(nil, offRoad: false), .notSure)
        XCTAssertEqual(VehicleMatch.verdict(nil, offRoad: true), .fails)
        XCTAssertEqual(VehicleMatch.verdict(.failure(.tooFewFixes), offRoad: false), .notSure)
        XCTAssertEqual(VehicleMatch.verdict(.failure(.tooFewFixes), offRoad: true), .fails)
        // judged: the hard tests decide
        XCTAssertEqual(VehicleMatch.verdict(.success(10), offRoad: true), .passes)
        XCTAssertEqual(VehicleMatch.verdict(.failure(.wrongWay), offRoad: false), .fails)
    }

    // MARK: - One look while choosing

    /// Looks every 12 s from 8 s into choosing; `look(k)` gives that look's judgements and whether the one shown is off
    /// its road. Returns every look's result.
    private func choosing(_ ids: [String], shown: String?, looks n: Int,
                          _ look: (Int) -> (judged: [Judgement], offRoad: Bool)) -> [ChoiceLook] {
        var misses: [String: Int] = [:], state = SwitchState()
        var out: [ChoiceLook] = []
        for k in 0..<n {
            let at = 8 + 12 * Double(k), l = look(k)
            let c = VehicleMatch.choose(ids, judged: l.judged, shown: shown, shownOffRoad: l.offRoad, choosingFor: at,
                                        misses: &misses, state: &state, now: t0 + at)
            out.append(c)
            if c.settle != nil { break }
        }
        return out
    }

    func test_chooseOtherOutThenSure() {
        let out = choosing(["A", "B"], shown: "A", looks: 10) { _ in
            ([judged("A", .success(5)), judged("B", .failure(.offItsPath))], false)
        }
        XCTAssertEqual(out.map(\.alive), [["A", "B"], ["A"]])
        XCTAssertEqual(out.last?.settle, "A")
        XCTAssertEqual(out.last?.why, .onlyOneLeft)
        XCTAssertEqual(out.last?.shownFailing, false)
    }

    func test_chooseShownFailsSwitchAfterThreeLooks() {
        let out = choosing(["A", "B"], shown: "A", looks: 10) { _ in
            ([judged("A", .failure(.offItsPath)), judged("B", .success(5))], false)
        }
        // looks at 8, 20, 32, 44, 56 s: 3 in a row spanning 48 s at the fifth
        XCTAssertEqual(out.count, 5)
        XCTAssertEqual(out.last?.settle, "B")
        XCTAssertEqual(out.last?.why, .decided)
        XCTAssertEqual(out.map(\.shownFailing), [false, true, true, true, true])
        XCTAssertEqual(out.last?.alive, ["A", "B"])
    }

    /// Not sure yet, on its road: never failed, never switched away from.
    func test_chooseShownNotSureOnItsRoad() {
        let out = choosing(["A", "B"], shown: "A", looks: 20) { _ in
            ([judged("A", .failure(.noTimes)), judged("B", .success(5))], false)
        }
        XCTAssertEqual(out.count, 20)
        XCTAssertTrue(out.allSatisfy { $0.settle == nil && $0.decision == .keep("A") && $0.shown == .notSure && !$0.shownFailing })
    }

    /// Not sure yet, but off its road: it counts as failed.
    func test_chooseShownNotSureOffItsRoad() {
        let out = choosing(["A", "B"], shown: "A", looks: 10) { _ in
            ([judged("A", .failure(.noTimes)), judged("B", .success(5))], true)
        }
        XCTAssertEqual(out.count, 5)
        XCTAssertEqual(out.last?.settle, "B")
        XCTAssertEqual(out.first?.shown, .fails)
        XCTAssertEqual(out.last?.shownFailing, true)
        // no track for the one shown: the same
        let none = choosing(["A", "B"], shown: "A", looks: 10) { _ in ([judged("B", .success(5))], true) }
        XCTAssertEqual(none.last?.settle, "B")
        XCTAssertEqual(none.last?.why, .decided)
    }

    /// One it has no track for yet stays in the running; so does the one shown without a track, not failed.
    func test_chooseUntrackedStays() {
        let out = choosing(["A", "B", "C"], shown: "A", looks: 10) { _ in
            ([judged("B", .success(5)), judged("C", .failure(.offItsPath))], false)
        }
        XCTAssertEqual(out.count, 10)
        XCTAssertEqual(out.last?.alive, ["A", "B"])
        XCTAssertTrue(out.allSatisfy { $0.settle == nil && $0.decision == .keep("A") })
    }

    /// The one shown failed, and the two others trade the lead: nothing is sure for 12 minutes; then the best that passed
    /// that look.
    func test_chooseTwelveMinutesFailingShown() {
        let out = choosing(["A", "B", "C"], shown: "A", looks: 70) { k in
            let b = k % 2 == 0
            return ([judged("A", .failure(.offItsPath)), judged("B", .success(b ? 10 : 20)), judged("C", .success(b ? 20 : 10))], false)
        }
        // the first look past 720 s is at 728 s (k = 60, B leads)
        XCTAssertEqual(out.count, 61)
        XCTAssertTrue(out.dropLast().allSatisfy { $0.settle == nil })
        XCTAssertEqual(out.last?.settle, "B")
        XCTAssertEqual(out.last?.why, .timedOut)
        XCTAssertEqual(out.last?.shownFailing, true)
    }

    /// S5 while choosing: the one shown passes but isn't the best (timetable-only): after 12 minutes it keeps it.
    func test_chooseTwelveMinutesKeepsPassingShown() {
        let out = choosing(["A", "B"], shown: "A", looks: 70) { _ in
            ([judged("A", .success(250), live: false), judged("B", .success(4))], false)
        }
        XCTAssertEqual(out.count, 61)
        XCTAssertEqual(out.last?.settle, "A")
        XCTAssertEqual(out.last?.why, .timedOut)
    }

    // MARK: - A live one shown that fails by its times only, against a timetable-only best (item 3)

    /// The live bus you're on runs ahead of its piece's even speed (drifting by its times); the same line 3 minutes on,
    /// timetable-only, passes by its road and your speed alone. It never switches: each such look is not sure for the one
    /// shown (no miss, the run starts again), and after 12 minutes it keeps the one shown.
    func test_chooseDriftingLiveShownKeptAgainstTimetableOnly() {
        let out = choosing(["A", "B"], shown: "A", looks: 20) { _ in
            ([judged("A", .failure(.drifting)), judged("B", .success(5), live: false)], false)
        }
        XCTAssertEqual(out.count, 20)
        XCTAssertTrue(out.allSatisfy { $0.settle == nil && $0.decision == .keep("A") && $0.shown == .notSure && !$0.shownFailing })
        XCTAssertTrue(out.allSatisfy { $0.alive == ["A", "B"] })
        for why in [Reject.standing, .tooFarFromTimes] {
            let other = choosing(["A", "B"], shown: "A", looks: 70) { _ in
                ([judged("A", .failure(why)), judged("B", .success(5), live: false)], false)
            }
            XCTAssertEqual(other.count, 61, "\(why)")
            XCTAssertTrue(other.dropLast().allSatisfy { $0.settle == nil && $0.decision == .keep("A") }, "\(why)")
            XCTAssertEqual(other.last?.settle, "A", "\(why)")
            XCTAssertEqual(other.last?.why, .timedOut, "\(why)")
        }
    }

    /// Off its path, or going the other way, still counts against it: it switches to the timetable-only one after the run.
    func test_chooseOffItsPathShownSwitchesToTimetableOnly() {
        for why in [Reject.offItsPath, .wrongWay] {
            let out = choosing(["A", "B"], shown: "A", looks: 20) { _ in
                ([judged("A", .failure(why)), judged("B", .success(5), live: false)], false)
            }
            XCTAssertEqual(out.count, 5, "\(why)")
            XCTAssertEqual(out.last?.settle, "B", "\(why)")
            XCTAssertEqual(out.last?.why, .decided, "\(why)")
            XCTAssertEqual(out.map(\.shown), [ShownVerdict?](repeating: .fails, count: 5), "\(why)")
        }
    }

    /// By its times against a live best, or while off its road by today's check: it counts as before.
    func test_chooseTimesOnlyFailureStillCounts() {
        let live = choosing(["A", "B"], shown: "A", looks: 20) { _ in
            ([judged("A", .failure(.drifting)), judged("B", .success(5))], false)
        }
        XCTAssertEqual(live.count, 5)
        XCTAssertEqual(live.last?.settle, "B")
        let offRoad = choosing(["A", "B"], shown: "A", looks: 20) { _ in
            ([judged("A", .failure(.tooFarFromTimes)), judged("B", .success(5), live: false)], true)
        }
        XCTAssertEqual(offRoad.count, 5)
        XCTAssertEqual(offRoad.last?.settle, "B")
        XCTAssertEqual(offRoad.last?.shownFailing, true)
    }

    /// Misses from looks before (no best then) don't let a timetable-only best take over at 12 minutes while the one
    /// shown fails by its times only.
    func test_chooseNoTwelveMinuteTakeoverByTimetableOnly() {
        let out = choosing(["A", "B"], shown: "A", looks: 70) { k in
            let b: Result<Double, Reject> = k < 3 ? .failure(.tooFewFixes) : .success(5)
            return ([judged("A", .failure(.drifting)), judged("B", b, live: false)], false)
        }
        XCTAssertEqual(out.prefix(3).map(\.shownFailing), [false, true, true])
        XCTAssertEqual(out.count, 61)
        XCTAssertEqual(out.last?.settle, "A")
        XCTAssertEqual(out.last?.why, .timedOut)
        XCTAssertEqual(out.last?.shownFailing, false)
    }

    func test_timesOnly() {
        func j(_ r: Result<Double, Reject>, train: Bool = false, you: Double? = nil) -> Judgement {
            let e = you.map {
                Evidence(fixes: 15, span: 28, crossTrack: 5, accuracy: 20, shaped: true, progress: $0 * 28, offset: 0,
                         drift: 0, yourSpeed: $0, itsSpeed: 12, steady: true)
            }
            return Judgement(id: "x", line: "306", isTrain: train, realTime: true, evidence: e, result: r)
        }
        XCTAssertTrue(VehicleMatch.timesOnly(j(.failure(.drifting))))
        XCTAssertTrue(VehicleMatch.timesOnly(j(.failure(.standing))))
        XCTAssertTrue(VehicleMatch.timesOnly(j(.failure(.tooFarFromTimes))))
        XCTAssertTrue(VehicleMatch.timesOnly(j(.failure(.implausibleSpeed), you: 3)))              // the ratio to its times
        XCTAssertTrue(VehicleMatch.timesOnly(j(.failure(.implausibleSpeed), train: true)))
        XCTAssertFalse(VehicleMatch.timesOnly(j(.failure(.implausibleSpeed), you: 35)))            // faster than a bus goes
        XCTAssertFalse(VehicleMatch.timesOnly(j(.failure(.implausibleSpeed))))
        for why in [Reject.offItsPath, .wrongWay, .tooFewFixes, .noTimes] {
            XCTAssertFalse(VehicleMatch.timesOnly(j(.failure(why))), "\(why)")
        }
        XCTAssertFalse(VehicleMatch.timesOnly(j(.success(10))))
    }

    // MARK: - The timetable fallback with sparse fixes (item 4)

    func test_fallbackSureAfterAMinuteClearlyLeft() {
        XCTAssertTrue(VehicleMatch.fallbackSure(enough: true, leftSince: nil, now: t0))
        XCTAssertFalse(VehicleMatch.fallbackSure(enough: false, leftSince: nil, now: t0))
        XCTAssertFalse(VehicleMatch.fallbackSure(enough: false, leftSince: t0, now: t0 + 59))
        XCTAssertTrue(VehicleMatch.fallbackSure(enough: false, leftSince: t0, now: t0 + 60))
        // looks every 7 s, clearly left from the second: sure from the first look a minute after that
        var since: Date?
        var sureAt: [Int] = []
        let holds = [false, true, true, true, true, true, true, true, true, true, true, true, true]
        for (k, h) in holds.enumerated() {
            since = VehicleMatch.heldSince(since, holds: h, now: t0 + 7 * Double(k))
            if VehicleMatch.fallbackSure(enough: false, leftSince: since, now: t0 + 7 * Double(k)) { sureAt.append(k) }
        }
        XCTAssertEqual(since, t0 + 7)
        XCTAssertEqual(sureAt, [10, 11, 12])                           // 63 s after 7 s
        XCTAssertNil(VehicleMatch.heldSince(t0, holds: false, now: t0 + 30))     // a look where it doesn't hold: from the start
        XCTAssertEqual(VehicleMatch.heldSince(nil, holds: true, now: t0 + 30), t0 + 30)
    }

    func test_sameChoiceWithinTenMinutes() {
        let last = TimedOut(ids: ["a", "b"], at: t0)
        XCTAssertTrue(VehicleMatch.sameChoice(["b", "a"], as: last, now: t0 + 300))
        XCTAssertFalse(VehicleMatch.sameChoice(["a", "b"], as: last, now: t0 + 600))
        XCTAssertFalse(VehicleMatch.sameChoice(["a", "c"], as: last, now: t0 + 60))
        XCTAssertFalse(VehicleMatch.sameChoice(["a", "b", "c"], as: last, now: t0 + 60))
        XCTAssertFalse(VehicleMatch.sameChoice(["a", "b"], as: nil, now: t0))
    }
}
