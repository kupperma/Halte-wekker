import XCTest

final class DepartureGroupsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 3_000_000)
    private typealias G = DepartureGroups

    private func dep(_ trip: String, _ stop: String, _ mins: Double, line: String = "306", delay: Double = 0,
                     live: Bool = true, cancelled: Bool = false) -> G.Departure {
        let sched = now.addingTimeInterval(mins * 60)
        return G.Departure(tripId: trip, stopId: stop, line: line, headsign: "Veghel", time: sched.addingTimeInterval(delay * 60), scheduled: sched,
                           live: live, cancelled: cancelled, platform: nil, train: false)
    }

    func test_stationNearYouComesFirst() {
        let s = [G.Stop(id: "bus1", name: "Busstation", rail: false, metres: 200),
                 G.Stop(id: "rail", name: "Station", rail: true, metres: 320),
                 G.Stop(id: "bus2", name: "Koningsweg", rail: false, metres: 150)]
        XCTAssertEqual(G.order(s).map(\.id), ["rail", "bus2", "bus1"])
    }

    func test_farStationByDistance() {
        let s = [G.Stop(id: "rail", name: "Station", rail: true, metres: 1900),
                 G.Stop(id: "bus", name: "Markt", rail: false, metres: 300),
                 G.Stop(id: "x", name: "Unknown", rail: false, metres: nil)]
        XCTAssertEqual(G.order(s).map(\.id), ["bus", "rail", "x"])
    }

    func test_duplicateStopsOnce() {
        let s = [G.Stop(id: "a", name: "A", rail: false, metres: 1), G.Stop(id: "a", name: "A", rail: false, metres: 1)]
        XCTAssertEqual(G.order(s).count, 1)
    }

    func test_cardsNextThreePerStopEachTripOnce() {
        let stops = [G.Stop(id: "a", name: "A", rail: false, metres: 100), G.Stop(id: "b", name: "B", rail: false, metres: 200)]
        let deps = [dep("t1", "a", 12), dep("t2", "a", 2), dep("t3", "a", -3), dep("t4", "a", 5), dep("t5", "a", 30),
                    dep("t2", "a", 2), dep("t6", "b", 1), dep("old", "b", -0.5)]
        let cards = G.cards(stops: stops, departures: deps, now: now)
        XCTAssertEqual(cards.map(\.stop.id), ["a", "b"])
        XCTAssertEqual(cards[0].departures.map(\.tripId), ["t2", "t4", "t1"])
        XCTAssertEqual(cards[1].departures.map(\.tripId), ["old", "t6"], "one that left under a minute ago still shows")
    }

    func test_cancelledSortsByItsPlannedTime() {
        let stops = [G.Stop(id: "a", name: "A", rail: false, metres: 100)]
        let deps = [dep("late", "a", 4, delay: 10, cancelled: true), dep("b", "a", 6)]
        XCTAssertEqual(G.cards(stops: stops, departures: deps, now: now)[0].departures.map(\.tripId), ["late", "b"])
    }

    func test_atMostThreeCards() {
        let stops = (0..<5).map { G.Stop(id: "s\($0)", name: "S\($0)", rail: false, metres: Double($0)) }
        XCTAssertEqual(G.cards(stops: stops, departures: [], now: now).map(\.stop.id), ["s0", "s1", "s2"])
    }

    func test_countdownLateWalk() {
        let clock: (Date) -> String = { _ in "19:04" }
        XCTAssertEqual(G.countdown(dep("a", "a", 0.5), now: now, clock: clock), "now")
        XCTAssertEqual(G.countdown(dep("a", "a", 5.2), now: now, clock: clock), "5 min")
        XCTAssertEqual(G.countdown(dep("a", "a", 75), now: now, clock: clock), "19:04")
        XCTAssertEqual(G.lateText(dep("a", "a", 5, delay: 4)), "+4")
        XCTAssertNil(G.lateText(dep("a", "a", 5, delay: 0.3)))
        XCTAssertNil(G.lateText(dep("a", "a", 5, delay: 4, cancelled: true)))
        XCTAssertNil(G.lateText(dep("a", "a", 5, delay: 4, live: false)))
        XCTAssertEqual(G.walkText(metres: 320), "4 min walk")
        XCTAssertEqual(G.walkText(metres: 10), "1 min walk")
        XCTAssertNil(G.walkText(metres: nil))
    }

    func test_leaveText() {
        XCTAssertEqual(G.leaveText(leave: now.addingTimeInterval(9 * 60 + 30), now: now), "Leave in 9 min")
        XCTAssertEqual(G.leaveText(leave: now.addingTimeInterval(20), now: now), "Leave now")
        XCTAssertEqual(G.leaveText(leave: now.addingTimeInterval(-4 * 60), now: now), "Leave now")
        XCTAssertNil(G.leaveText(leave: now.addingTimeInterval(-6 * 60), now: now))
    }
}
