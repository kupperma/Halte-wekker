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
        XCTAssertEqual(axis?.ticks(width: 320), [at(0), at(10), at(20), at(30), at(45)], "40 before the end: too close to it")
        let short: TripTimeline.Axis? = TripTimeline.axis([[TripTimeline.Part(kind: .ride, start: at(1), end: at(6))]])
        XCTAssertEqual(short?.end, at(20))
        XCTAssertEqual(short?.ticks(width: 320), [at(0), at(10), at(20)])
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

    // MARK: 0.42.2

    func test_tickStep_fromTheSpanAndTheWidth() {
        XCTAssertEqual(TripTimeline.tickStep(span: 40 * 60, width: 320), 10)
        XCTAssertEqual(TripTimeline.tickStep(span: 90 * 60, width: 320), 30, "15 min would be 53 pt apart")
        XCTAssertEqual(TripTimeline.tickStep(span: 90 * 60, width: 400), 15)
        XCTAssertEqual(TripTimeline.tickStep(span: 390 * 60, width: 320), 120)
        XCTAssertEqual(TripTimeline.tickStep(span: 48 * 3600, width: 320), 360, "the widest step at most")
    }

    func test_ticks_overnightAxis_neverOverlap_firstAndLastAlways() {
        // the screenshot: 23:30 → 06:00 on a phone-wide row; every 30 min drew "23:3000:0001:30…"
        let axis = TripTimeline.Axis(start: at(0), end: at(390))
        let w: Double = 320
        let t: [Date] = axis.ticks(width: w)
        XCTAssertEqual(t.first, at(0))
        XCTAssertEqual(t.last, at(390))
        for i in 1..<t.count {
            let pts: Double = (axis.at(t[i]) - axis.at(t[i - 1])) * w
            XCTAssertGreaterThanOrEqual(pts, TripTimeline.tickSpacing - 1e-9, "ticks \(i - 1) and \(i) overlap")
        }
        XCTAssertLessThanOrEqual(t.count, 6)
    }

    func test_ends_bothAlways_neverOverlapping_onTheRow() {
        let w: Double = 320, lw: Double = TripTimeline.timeWidth / w
        let wide: TripTimeline.Ends = TripTimeline.ends(start: 0.1, end: 0.8, width: w)
        XCTAssertEqual(wide.leave, 0.1, accuracy: 1e-9)
        XCTAssertEqual(wide.arrive, 0.8 - lw, accuracy: 1e-9)
        for (a, b) in [(0.5, 0.55), (0.0, 0.04), (0.97, 1.0), (0.3, 0.3)] {
            let e: TripTimeline.Ends = TripTimeline.ends(start: a, end: b, width: w)
            XCTAssertGreaterThanOrEqual(e.arrive - e.leave, lw, "\(a)–\(b): overlap")
            XCTAssertGreaterThanOrEqual(e.leave, 0)
            XCTAssertLessThanOrEqual(e.arrive + lw, 1 + 1e-9)
        }
    }

    func test_gapLabels_walkWaitChange_lastWalk_withTones() {
        // the screenshot's trip: walk 2, wait 1, bus 158 to 23:40, walk 3 + wait 5, SPR to 00:20, wait 2, bus 1, walk 4
        let legs: [TripTimeline.Leg] = [leg("158", 3, 23, from: "Bolkenplein", walk: 2),
                                        leg("SPR", 31, 60, from: "Den Bosch", walk: 3, train: true),
                                        leg("1", 62, 75, from: "Breda", walk: 0)]
        let parts: [TripTimeline.Part] = TripTimeline.parts(leave: at(0), legs: legs, end: at(79))
        let axis = TripTimeline.Axis(start: at(0), end: at(80))
        let placed: [TripTimeline.Placed] = TripTimeline.place(parts, on: axis)
        let g: [TripTimeline.GapLabel] = TripTimeline.gapLabels(placed, width: 320, changeNeeds: 6)
        XCTAssertEqual(g.map(\.text), ["2 walk + 1 wait", "3 walk + 5 wait", "2 min", "4 walk"])
        XCTAssertEqual(g.map(\.tone), [.plain, .plain, .risky, .plain])
        XCTAssertEqual(g[1].x, (23.0 + 31) / 2 / 80, accuracy: 1e-9, "centred on the gap")
        XCTAssertTrue(g[1].below, "8 minutes is 32 pt: too narrow for its words, under the bar")
        XCTAssertEqual(g.map(\.lane), [0, 1, 0, 0], "the second would touch the first: the row below")
        // a long wait holds its minutes inside the gap
        let long: [TripTimeline.Leg] = [leg("158", 0, 20, from: "A", walk: 0), leg("SPR", 50, 70, from: "B", walk: 0, train: true)]
        let lp: [TripTimeline.Placed] = TripTimeline.place(TripTimeline.parts(leave: at(0), legs: long, end: at(70)), on: axis)
        let lg: [TripTimeline.GapLabel] = TripTimeline.gapLabels(lp, width: 320)
        XCTAssertEqual(lg.map(\.text), ["30 min"])
        XCTAssertFalse(lg[0].below)
        XCTAssertEqual(lg[0].x, 35.0 / 80, accuracy: 1e-9)
        // a tight one: 4 minutes when you need 6
        let tight: [TripTimeline.Leg] = [leg("158", 0, 20, from: "A", walk: 0), leg("SPR", 24, 50, from: "B", walk: 0, train: true)]
        let tp: [TripTimeline.Placed] = TripTimeline.place(TripTimeline.parts(leave: at(0), legs: tight, end: at(50)), on: axis)
        XCTAssertEqual(TripTimeline.gapLabels(tp, width: 320, changeNeeds: 6).map(\.tone), [.tight])
        XCTAssertEqual(TripTimeline.gapLabels(tp, width: 320, changeNeeds: nil).map(\.tone), [.plain])
    }

    func test_gapLabels_under_neverOnTopOfEachOther() {
        // three narrow gaps side by side: two rows under the bar, the third left out rather than on top of one
        let legs: [TripTimeline.Leg] = [leg("1", 0, 20, from: "A", walk: 0), leg("2", 21, 22, from: "B", walk: 0),
                                        leg("3", 23, 24, from: "C", walk: 0), leg("4", 25, 60, from: "D", walk: 0)]
        let axis = TripTimeline.Axis(start: at(0), end: at(60))
        let placed: [TripTimeline.Placed] = TripTimeline.place(TripTimeline.parts(leave: at(0), legs: legs, end: at(60)), on: axis)
        let g: [TripTimeline.GapLabel] = TripTimeline.gapLabels(placed, width: 320)
        XCTAssertTrue(g.allSatisfy(\.below))
        for a in g { for b in g where a != b && a.lane == b.lane {
            let half: Double = (TripTimeline.textWidth(a.text) + TripTimeline.textWidth(b.text)) / 2 / 320
            XCTAssertGreaterThanOrEqual(abs(a.x - b.x), half, "\(a.text) and \(b.text) overlap")
        } }
        XCTAssertEqual(Set(g.map(\.lane)), [0, 1])
    }

    func test_rideLabels_onlyWhenTheyFit() {
        let legs: [TripTimeline.Leg] = [leg("158", 0, 41, from: "A", walk: 0), leg("1", 43, 45, from: "B", walk: 0)]
        let axis = TripTimeline.Axis(start: at(0), end: at(45))
        let placed: [TripTimeline.Placed] = TripTimeline.place(TripTimeline.parts(leave: at(0), legs: legs, end: at(45)), on: axis)
        let r: [TripTimeline.RideLabel] = TripTimeline.rideLabels(placed, width: 320)
        XCTAssertEqual(r.map(\.text), ["41 min"], "the 2-minute bus is too short for its minutes")
        XCTAssertEqual(placed[r[0].index].part.line, "158")
    }
}
