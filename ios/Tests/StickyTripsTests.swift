import XCTest

final class StickyTripsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 6_000_000)
    private func at(_ min: Double) -> Date { now.addingTimeInterval(min * 60) }
    private func item(_ id: String, bus: String? = nil, departs: Double, leave: Double? = nil, cancelled: Bool = false) -> StickyTrips.Item {
        StickyTrips.Item(id: id, firstTrip: bus ?? "bus-\(id)", departs: at(departs), leave: at(leave ?? departs - 8), cancelled: cancelled)
    }

    func test_failedAnswer_keepsWhatsStillToCome() {
        let kept = [item("a", departs: -3), item("b", departs: 4), item("c", departs: 20)]
        XCTAssertEqual(StickyTrips.merge(kept: kept, answer: [], kind: .failed, held: nil, now: now), ["b", "c"])
    }

    func test_emptyWholeAnswer_countsAsFailed() {
        let kept = [item("b", departs: 4)]
        XCTAssertEqual(StickyTrips.merge(kept: kept, answer: [], kind: .whole, held: nil, now: now), ["b"])
    }

    func test_partialAnswer_addsToTheList() {
        let kept = [item("b", departs: 4), item("c", departs: 20)]
        let answer = [item("b2", bus: "bus-b", departs: 5), item("d", departs: 12)]
        let out = StickyTrips.merge(kept: kept, answer: answer, kind: .partial, held: nil, now: now)
        XCTAssertEqual(out, ["b2", "d", "c"], "the same bus is the new answer's; the rest stays")
    }

    func test_wholeAnswer_replaces_butKeepsTheTripYoureHeadingFor() {
        let kept = [item("b", departs: 3, leave: -4), item("c", departs: 20)]
        // planned again from where you are: at the planner's pace you "can't" make the 3-minute bus any more
        let answer = [item("d", departs: 18), item("e", departs: 33)]
        let out = StickyTrips.merge(kept: kept, answer: answer, kind: .whole, held: "bus-b", now: now)
        XCTAssertEqual(out, ["b", "d", "e"])
        XCTAssertFalse(out.contains("c"), "a whole answer replaces the others")
    }

    func test_heldTrip_goesOnceItHasLeft_orYoureOnIt() {
        let kept = [item("b", departs: -1.5)]
        let answer = [item("d", departs: 18)]
        XCTAssertEqual(StickyTrips.merge(kept: kept, answer: answer, kind: .whole, held: "bus-b", now: now), ["d"])
        let still = [item("b", departs: 2)]
        XCTAssertEqual(StickyTrips.merge(kept: still, answer: answer, kind: .whole, held: "bus-b", onIt: true, now: now), ["d"])
    }

    func test_cancelledHeldTrip_isNotKept() {
        let kept = [item("b", departs: 4, cancelled: true)]
        XCTAssertEqual(StickyTrips.merge(kept: kept, answer: [item("d", departs: 18)], kind: .whole, held: "bus-b", now: now), ["d"])
    }

    func test_pick_holdsTheTripYoureWalkingTo_pastItsTimeToLeave() {
        let items = [item("b", departs: 3, leave: -4), item("d", departs: 18, leave: 10)]
        XCTAssertEqual(StickyTrips.pick(items: items, heldIndex: 0, reachable: true, now: now), 0)
        XCTAssertEqual(StickyTrips.pick(items: items, heldIndex: 0, reachable: false, now: now), 1, "too far to make it: the next one")
        XCTAssertEqual(StickyTrips.pick(items: items, heldIndex: 0, reachable: nil, now: now), 1, "not known: as before, two minutes")
        XCTAssertEqual(StickyTrips.pick(items: items, heldIndex: nil, reachable: nil, now: now), 1)
    }

    func test_pick_heldFarOff_doesntBlockAnEarlierOne() {
        let items = [item("x", departs: 9, leave: 2), item("b", departs: 40, leave: 30)]
        XCTAssertEqual(StickyTrips.pick(items: items, heldIndex: 1, reachable: true, now: now), 0)
    }

    func test_held_isTheShownOneWhileToCome() {
        XCTAssertEqual(StickyTrips.held(shown: item("b", departs: 4), now: now), "bus-b")
        XCTAssertNil(StickyTrips.held(shown: item("b", departs: -2), now: now))
        XCTAssertNil(StickyTrips.held(shown: nil, now: now))
    }

    func test_reachable() {
        XCTAssertEqual(StickyTrips.reachable(metres: 200, departs: at(3), now: now), true)
        XCTAssertEqual(StickyTrips.reachable(metres: 900, departs: at(3), now: now), false)
        XCTAssertNil(StickyTrips.reachable(metres: nil, departs: at(3), now: now))
    }
}

final class NextTripHeldTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 6_100_000)

    func test_pickWithLiveIndex() {
        XCTAssertEqual(NextTrip.pick(dest: "buas", dueDest: nil, schoolDue: false, plannedDue: false, liveDest: "buas", liveIndex: 2, now: now).index, 2)
        XCTAssertEqual(NextTrip.pick(dest: "buas", dueDest: nil, schoolDue: false, plannedDue: false, liveDest: "buas", liveIndex: nil, now: now).source, .none)
        XCTAssertEqual(NextTrip.pick(dest: "buas", dueDest: "buas", schoolDue: true, plannedDue: false, liveDest: "buas", liveIndex: 0, now: now).source, .school)
        XCTAssertEqual(NextTrip.pick(dest: "veghel", dueDest: nil, schoolDue: false, plannedDue: false, liveDest: "buas", liveIndex: 0, now: now).source, .none)
    }
}
