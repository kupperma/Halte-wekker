import XCTest

final class TripTimelineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)     // 2027-01-15 08:00 UTC (a whole 5 minutes)

    private func at(_ m: Double) -> Date { t0.addingTimeInterval(m * 60) }

    private func leg(_ line: String, _ dep: Double, _ arr: Double, from: String, walk: Int, live: Bool = true, train: Bool = false) -> TripTimeline.Leg {
        TripTimeline.Leg(line: line, train: train, live: live, departure: at(dep), arrival: at(arr), from: from, walkBefore: walk)
    }

    func test_parts_walkWaitRide_changeWalkWait_walkAtTheEnd() {
        let legs: [TripTimeline.Leg] = [leg("305", 9, 20, from: "Bolkenplein", walk: 7),
                                        leg("IC", 27, 47, from: "Den Bosch", walk: 4, train: true)]
        let p: [TripTimeline.Part] = TripTimeline.parts(leave: at(1), legs: legs, end: at(52))
        XCTAssertEqual(p.map(\.kind), [.walk, .wait, .ride, .walk, .wait, .ride, .walk])
        XCTAssertEqual(p[0].end, at(8))
        XCTAssertEqual(p[1].end, at(9))
        XCTAssertEqual(p[2].line, "305")
        XCTAssertEqual(p[3].start, at(20)); XCTAssertEqual(p[3].end, at(24))
        XCTAssertEqual(p[4].end, at(27))
        XCTAssertTrue(p[5].train)
        XCTAssertEqual(p.last?.end, at(52))
    }

    func test_parts_noEmptyWaits_andNothingBackwards() {
        // leave late: the walk is cut at the departure, no wait; arriving at the door with the ride: no last walk
        let legs: [TripTimeline.Leg] = [leg("306", 5, 15, from: "A", walk: 8)]
        let p: [TripTimeline.Part] = TripTimeline.parts(leave: at(0), legs: legs, end: at(15))
        XCTAssertEqual(p.map(\.kind), [.walk, .ride])
        XCTAssertEqual(p[0].end, at(5))
    }

    func test_axis_roundsOutToFiveMinutes_andIsAtLeastTwenty() {
        let a = TripTimeline.Part(kind: .walk, start: at(2), end: at(30))
        let b = TripTimeline.Part(kind: .ride, start: at(12), end: at(41))
        let axis: TripTimeline.Axis? = TripTimeline.axis([[a], [b]])
        XCTAssertEqual(axis?.start, at(0))
        XCTAssertEqual(axis?.end, at(45))
        XCTAssertEqual(axis?.at(at(15)) ?? -1, 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(axis?.ticks, [at(0), at(15), at(30), at(45)])
        let short: TripTimeline.Axis? = TripTimeline.axis([[TripTimeline.Part(kind: .ride, start: at(1), end: at(6))]])
        XCTAssertEqual(short?.end, at(20))
        XCTAssertEqual(short?.ticks, [at(0), at(10), at(20)])
        XCTAssertNil(TripTimeline.axis([]))
    }

    func test_place_fractions_withAMinimumWidth() {
        let axis = TripTimeline.Axis(start: at(0), end: at(40))
        let parts: [TripTimeline.Part] = [TripTimeline.Part(kind: .walk, start: at(10), end: at(20)),
                                          TripTimeline.Part(kind: .wait, start: at(20), end: at(20.1))]
        let p: [TripTimeline.Placed] = TripTimeline.place(parts, on: axis)
        XCTAssertEqual(p[0].x, 0.25, accuracy: 1e-9)
        XCTAssertEqual(p[0].width, 0.25, accuracy: 1e-9)
        XCTAssertEqual(p[1].width, TripTimeline.minWidth, accuracy: 1e-9)
    }

    func test_changeLabels_atTheChange_leavingOutCrowdedOnes() {
        // changes at 10 and 12 minutes on a 40-minute axis: 0.25 and 0.30, too close; the second is left out
        let legs: [TripTimeline.Leg] = [leg("305", 2, 10, from: "Bolkenplein", walk: 2),
                                        leg("306", 11, 12, from: "Busstation", walk: 1),
                                        leg("IC", 13, 38, from: "Den Bosch", walk: 1, train: true)]
        let parts: [TripTimeline.Part] = TripTimeline.parts(leave: at(0), legs: legs, end: at(40))
        let axis = TripTimeline.Axis(start: at(0), end: at(40))
        let placed: [TripTimeline.Placed] = TripTimeline.place(parts, on: axis)
        let l: [TripTimeline.Label] = TripTimeline.changeLabels(legs, parts: placed, ends: (0, 1))
        XCTAssertEqual(l.map(\.text), ["Busstation"])
        XCTAssertEqual(l[0].x, 0.25, accuracy: 1e-9)
        // too near the trip's own end times: left out too
        let none: [TripTimeline.Label] = TripTimeline.changeLabels(legs, parts: placed, ends: (0.1, 1))
        XCTAssertEqual(none.map(\.text), ["Den Bosch"], "0.25 is near the start time at 0.1; 0.30 then has room")
    }

    func test_changeLabels_keptWhenApart_andAnchoredInwards() {
        let legs: [TripTimeline.Leg] = [leg("305", 1, 4, from: "A", walk: 1),
                                        leg("IC", 5, 20, from: "Den Bosch", walk: 1, train: true),
                                        leg("SPR", 21, 30, from: "Tilburg", walk: 1, train: true)]
        let parts: [TripTimeline.Part] = TripTimeline.parts(leave: at(0), legs: legs, end: at(40))
        let axis = TripTimeline.Axis(start: at(0), end: at(40))
        let placed: [TripTimeline.Placed] = TripTimeline.place(parts, on: axis)
        let l: [TripTimeline.Label] = TripTimeline.changeLabels(legs, parts: placed, ends: nil)
        XCTAssertEqual(l.map(\.text), ["Den Bosch", "Tilburg"])
        XCTAssertEqual(l[0].x, 0.1, accuracy: 1e-9)
        XCTAssertEqual(l[0].anchor, .leading)
        XCTAssertEqual(l[1].x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(l[1].anchor, .center)
        XCTAssertEqual(TripTimeline.anchor(0.95), .trailing)
    }

    func test_endLabels_bothWhenApart_elseOnlyTheArrival() {
        XCTAssertEqual(TripTimeline.endLabels(start: 0.1, end: 0.8).leave, true)
        XCTAssertEqual(TripTimeline.endLabels(start: 0.5, end: 0.6).leave, false)
        XCTAssertEqual(TripTimeline.endLabels(start: 0.5, end: 0.6).arrive, true)
    }
}
