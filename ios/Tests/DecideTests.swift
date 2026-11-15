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

    func test_clearWinnerNoShown() {
        let two = [Ranked(id: "b1", cost: 10), Ranked(id: "b2", cost: 200)]
        XCTAssertEqual(looks(shown: nil, live: ["b1", "b2"], [(0, two)]), [.switchTo("b1")])
        XCTAssertEqual(looks(shown: nil, live: ["b1"], [(0, two)]), [.undecided(["b1", "b2"])])
        XCTAssertEqual(looks(shown: nil, live: [], [(0, [Ranked(id: "b1", cost: 300)])]), [.switchTo("b1")])
        XCTAssertEqual(looks(shown: nil, live: ["b1", "b2"], [(0, [])]), [Decision.none])
    }
}
