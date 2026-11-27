import XCTest

/// 0.42.7: the stops around you by live times (the same vectors as Android's `NearbyLiveTest`; minutes after
/// 2026-11-27 00:00 UTC).
final class NearbyLiveTests: XCTestCase {
    private let base: Double = 1_795_737_600
    private func hm(_ h: Double, _ m: Double) -> Date { Date(timeIntervalSince1970: base + (h * 60 + m) * 60) }

    /// The report: bus 5 planned 14:38 (the answer said on time), Fastest trip knows it leaves 14:41.
    private var bus5: NearbyLive.Leg {
        NearbyLive.Leg(tripId: "5-1438", departure: hm(14, 38), scheduledDeparture: hm(14, 38), arrival: hm(14, 52),
                       scheduledArrival: hm(14, 52), live: true, toStop: "Breda, Centraal Station")
    }
    private var train: NearbyLive.Leg {
        NearbyLive.Leg(tripId: "ic-3600", departure: hm(15, 4), scheduledDeparture: hm(15, 4), arrival: hm(16, 0),
                       scheduledArrival: hm(16, 0), live: true, toStop: "Eindhoven Centraal")
    }

    func test_timeShownIsLiveWhenPresent() {
        let late = NearbyLive.shown(departure: hm(14, 41), scheduled: hm(14, 38), live: true, cancelled: false)
        XCTAssertEqual(late, NearbyLive.Shown(time: hm(14, 41), planned: hm(14, 38), word: "+3", late: true))
        let onTime = NearbyLive.shown(departure: hm(14, 38), scheduled: hm(14, 38), live: true, cancelled: false)
        XCTAssertEqual(onTime, NearbyLive.Shown(time: hm(14, 38), planned: nil, word: "live", late: false))
        // no live times: the timetable's, never called "live"
        let plan = NearbyLive.shown(departure: hm(14, 38), scheduled: hm(14, 38), live: false, cancelled: false)
        XCTAssertEqual(plan, NearbyLive.Shown(time: hm(14, 38), planned: nil, word: "timetable", late: false))
        XCTAssertEqual(NearbyLive.shown(departure: hm(14, 37), scheduled: hm(14, 38), live: true, cancelled: false).word, "-1")
        XCTAssertEqual(NearbyLive.shown(departure: hm(14, 41), scheduled: hm(14, 38), live: true, cancelled: true).word, "cancelled")
    }

    func test_aNewerUpdateMovesTheLegByItsDelay() {
        let u = NearbyLive.Update(tripId: "5-1438", departureDelay: 180, live: true, asOf: hm(14, 37))
        let l = NearbyLive.apply(bus5, u, answered: hm(14, 33))
        XCTAssertEqual(l.departure, hm(14, 41))
        XCTAssertEqual(l.arrival, hm(14, 55))              // moved as much as the departure (no arrival of its own)
        XCTAssertTrue(l.live)
        // the same update again: nothing more
        XCTAssertEqual(NearbyLive.apply(l, u, answered: hm(14, 33)), l)
        // older than the leg's own answer, not live, another trip: as it was
        XCTAssertEqual(NearbyLive.apply(bus5, u, answered: hm(14, 38)), bus5)
        var off = u; off.live = false
        XCTAssertEqual(NearbyLive.apply(bus5, off, answered: hm(14, 33)), bus5)
        var other = u; other.tripId = "x"
        XCTAssertEqual(NearbyLive.apply(bus5, other, answered: hm(14, 33)), bus5)
        // at its own stop the update's arrival counts
        let a = NearbyLive.Update(tripId: "5-1438", departureDelay: 180, arrivalDelay: 60, toStop: "Breda, Centraal Station", live: true, asOf: hm(14, 37))
        XCTAssertEqual(NearbyLive.apply(bus5, a, answered: hm(14, 33)).arrival, hm(14, 53))
    }

    func test_anUpdateFromAnotherStopOfTheSameTripFits() {
        // Fastest trip gets on two stops further on (planned 14:40, now 14:43): +3 here too
        let there = NearbyLive.Leg(tripId: "5-1438", departure: hm(14, 43), scheduledDeparture: hm(14, 40), arrival: hm(14, 55),
                                   scheduledArrival: hm(14, 52), live: true, toStop: "Breda, Centraal Station")
        let u = NearbyLive.update(there, asOf: hm(14, 37))
        let l = NearbyLive.apply(bus5, u, answered: hm(14, 33))
        XCTAssertEqual(l.departure, hm(14, 41))
        XCTAssertEqual(l.arrival, hm(14, 55))
    }

    func test_theWholeTripMovesWithItsLegs() {
        let ups = NearbyLive.merge([:], [NearbyLive.Update(tripId: "5-1438", departureDelay: 180, live: true, asOf: hm(14, 37))])
        let r = NearbyLive.trip(start: hm(14, 30), end: hm(16, 5), legs: [bus5, train], updates: ups, answered: hm(14, 33))
        XCTAssertEqual(r.start, hm(14, 33))
        XCTAssertEqual(r.end, hm(16, 5))                    // the train isn't late: there as before
        XCTAssertEqual(r.legs[0].departure, hm(14, 41))
        let late = NearbyLive.merge(ups, [NearbyLive.Update(tripId: "ic-3600", departureDelay: 300, arrivalDelay: 420,
                                                            toStop: "Eindhoven Centraal", live: true, asOf: hm(14, 37))])
        XCTAssertEqual(NearbyLive.trip(start: hm(14, 30), end: hm(16, 5), legs: [bus5, train], updates: late, answered: hm(14, 33)).end, hm(16, 12))
    }

    func test_mergeKeepsTheNewestLiveOne() {
        let a = NearbyLive.Update(tripId: "t", departureDelay: 60, live: true, asOf: hm(14, 30))
        let b = NearbyLive.Update(tripId: "t", departureDelay: 180, live: true, asOf: hm(14, 35))
        let old = NearbyLive.Update(tripId: "t", departureDelay: 0, live: true, asOf: hm(14, 20))
        let plan = NearbyLive.Update(tripId: "t", departureDelay: 0, live: false, asOf: hm(14, 40))
        XCTAssertEqual(NearbyLive.merge([:], [a, b, old, plan])["t"], b)
    }

    func test_fastestByLiveArrival() {
        // planned: A there 16:05, B 16:08; live, A's train is 7 late (16:12): B is the one there first
        let planned: [Date] = [hm(16, 5), hm(16, 8)]
        XCTAssertEqual(NearbyLive.fastest(arrivals: planned, changes: [2, 1], departures: [hm(14, 38), hm(14, 45)]), 0)
        let live: [Date] = [hm(16, 12), hm(16, 8)]
        XCTAssertEqual(NearbyLive.fastest(arrivals: live, changes: [2, 1], departures: [hm(14, 41), hm(14, 45)]), 1)
        // the same arrival: fewer changes, then the one that leaves later
        XCTAssertEqual(NearbyLive.fastest(arrivals: [hm(16, 8), hm(16, 8)], changes: [2, 1], departures: [hm(14, 41), hm(14, 30)]), 1)
        XCTAssertEqual(NearbyLive.fastest(arrivals: [hm(16, 8), hm(16, 8)], changes: [1, 1], departures: [hm(14, 41), hm(14, 30)]), 0)
        XCTAssertNil(NearbyLive.fastest(arrivals: [], changes: [], departures: []))
    }
}
