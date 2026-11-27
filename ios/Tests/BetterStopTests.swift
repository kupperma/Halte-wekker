import XCTest

/// 0.42.9: the best place to get off: a through train's later stops planned from, the faster one offered.
final class BetterStopTests: XCTestCase {
    private let t0 = Fx.t0
    private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
    private func p(_ m: Double, north: Double = 0) -> GeoPoint { Fx.east(m, north: north) }

    /// The train you're on: Breda, Tilburg (your stop as planned), then two stations further on (A, B), then a far one.
    private var calls: [TrainRules.StayCall] {
        [TrainRules.StayCall(name: "Breda", p: p(0), arrival: at(0)),
         TrainRules.StayCall(name: "Tilburg", p: p(20_000), arrival: at(1500)),
         TrainRules.StayCall(name: "A", p: p(40_000, north: 10_000), arrival: at(2400)),
         TrainRules.StayCall(name: "B", p: p(50_000), arrival: at(3300)),
         TrainRules.StayCall(name: "Far", p: p(150_000), arrival: at(1500 + 2 * 3600))]
    }
    private let dest = Fx.east(45_000, north: 20_000)

    func test_laterStopsAreTheCandidatesNearestTheDestinationFirst() {
        let c = BetterStop.candidates(calls: calls, after: 1, dest: dest, now: at(60))
        XCTAssertEqual(c, [2, 3], "A is nearer the destination; the far one is beyond 90 minutes")
        XCTAssertEqual(BetterStop.candidates(calls: calls, after: 4, dest: dest, now: at(60)), [], "it doesn't go on")
        XCTAssertEqual(BetterStop.candidates(calls: Array(calls.prefix(2)), after: 1, dest: dest, now: at(60)), [])
        XCTAssertEqual(BetterStop.candidates(calls: calls, after: 1, dest: dest, now: at(3000)), [3], "a stop behind you doesn't count")
    }

    /// Two later stops planned from: the faster one wins.
    func test_twoCandidatesPickTheFasterOne() {
        let current = at(6060)          // the plan: there at 16:01
        let options = [BetterStop.Option(stop: 2, arrival: at(5520), changes: 1),     // 15:52
                       BetterStop.Option(stop: 3, arrival: at(5880), changes: 1)]
        XCTAssertEqual(BetterStop.best(current: current, currentChanges: 2, options: options)?.stop, 2)
    }

    func test_noOfferUnderThreeMinutes() {
        let current = at(6060)
        XCTAssertNil(BetterStop.best(current: current, currentChanges: 1, options: [BetterStop.Option(stop: 2, arrival: at(5940), changes: 1)]))
        XCTAssertNil(BetterStop.best(current: current, currentChanges: 1, options: [BetterStop.Option(stop: 2, arrival: at(6300), changes: 0)]))
        // as soon, with fewer changes: offered
        XCTAssertEqual(BetterStop.best(current: current, currentChanges: 2, options: [BetterStop.Option(stop: 3, arrival: at(6080), changes: 1)])?.stop, 3)
        XCTAssertNil(BetterStop.best(current: current, currentChanges: 1, options: []))
    }

    func test_words() {
        XCTAssertEqual(BetterStop.offerText(stop: "'s-Hertogenbosch", dest: "home", newAt: "15:52", oldAt: "16:01", then: "bus 306 at 15:31"),
                       "Stay on to 's-Hertogenbosch — home 15:52 instead of 16:01 (bus 306 at 15:31)")
        XCTAssertEqual(BetterStop.log(stop: "'s-Hertogenbosch", dest: "home", newAt: "15:52", minutes: 9),
                       "better stop · stay on to 's-Hertogenbosch · home 15:52 (−9 min)")
        XCTAssertEqual(BetterStop.minutesSooner(current: at(6060), better: at(5520)), 9)
    }
}
