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

    private func judged(_ id: String, _ r: Result<Double, Reject>) -> Judgement {
        Judgement(id: id, line: "306", isTrain: false, realTime: true, evidence: nil, result: r)
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
}
