import XCTest

final class GhostDeparturesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 5_000_000)
    private func at(_ min: Double) -> Date { now.addingTimeInterval(min * 60) }
    private func dep(_ id: String, trip: String? = nil, line: String = "306", head: String = "Veghel", stop: String = "Schijndel, Centrum",
                     _ min: Double, sched: Double? = nil, live: Bool = false, cancelled: Bool = false, vehicle: Bool = false) -> GhostDepartures.Dep {
        GhostDepartures.Dep(id: id, tripId: trip ?? id, line: line, headsign: head, stop: stop, time: at(min), scheduled: at(sched ?? min),
                            live: live, cancelled: cancelled, vehicle: vehicle)
    }

    func test_sameJourneyFromTwoSources_isShownOnce_theLiveOne() {
        let a = dep("a", trip: "ovapi:1", 20, live: false)
        let b = dep("b", trip: "arriva:9", head: "Veghel Busstation", 22, sched: 20, live: true)
        let rows = GhostDepartures.clean([a, b], now: now)
        XCTAssertEqual(rows.map(\.dep.id), ["b"])
        XCTAssertEqual(rows.first?.status, .live)
    }

    func test_otherDirectionAtTheSameMinute_isNotADuplicate() {
        let a = dep("a", head: "Veghel", 20, live: true)
        let b = dep("b", head: "'s-Hertogenbosch Centraal", 20, live: true)
        XCTAssertEqual(GhostDepartures.clean([a, b], now: now).count, 2)
    }

    func test_cancelledAreHidden() {
        let rows = GhostDepartures.clean([dep("a", 5, live: true, cancelled: true), dep("b", 12, live: true)], now: now)
        XCTAssertEqual(rows.map(\.dep.id), ["b"])
    }

    func test_noLiveDataCloseToLeaving_onALiveLine_isUnsure_andRanksBelowLiveOnes() {
        let ghost = dep("ghost", 8)                       // timetable only, 8 min to go
        let real = dep("real", trip: "t2", 12, live: true)  // the same line runs live
        let rows = GhostDepartures.clean([ghost, real], now: now)
        XCTAssertEqual(rows.map(\.dep.id), ["real", "ghost"])
        XCTAssertEqual(rows.last?.status, .unsure)
    }

    func test_farOff_timetableOnly_isJustTimetable() {
        let rows = GhostDepartures.clean([dep("later", 30), dep("real", trip: "t2", 5, live: true)], now: now)
        XCTAssertEqual(rows.first(where: { $0.dep.id == "later" })?.status, .timetable, "half an hour off: no live data expected yet")
    }

    func test_lineThatNeverHasLiveData_isNeverUnsure() {
        let rows = GhostDepartures.clean([dep("a", line: "9", 5)], now: now)
        XCTAssertEqual(rows.first?.status, .timetable)
    }

    func test_lineSeenLiveElsewhereToday_counts() {
        let rows = GhostDepartures.clean([dep("a", 5)], now: now, alsoLive: ["306"])
        XCTAssertEqual(rows.first?.status, .unsure)
    }

    func test_aVehicleSeen_isNotUnsure() {
        let rows = GhostDepartures.clean([dep("a", 5, vehicle: true), dep("b", trip: "t2", 9, live: true)], now: now)
        XCTAssertEqual(rows.first(where: { $0.dep.id == "a" })?.status, .timetable)
    }

    func test_pastItsTimeWithNoSign_isGone() {
        let rows = GhostDepartures.clean([dep("ghost", -2), dep("live", trip: "t2", -2, live: true)], now: now)
        XCTAssertEqual(rows.map(\.dep.id), ["live"], "the live one may still be at the stop; the ghost goes")
        let fresh = GhostDepartures.clean([dep("ghost", -0.5), dep("live", trip: "t2", 4, live: true)], now: now)
        XCTAssertTrue(fresh.contains { $0.dep.id == "ghost" }, "within a minute of its time it stays")
    }

    func test_options_unsureFirstRideGoesAfterTheOthers() {
        let o1 = GhostDepartures.Option(id: "ghost", line: "306", departs: at(6), scheduled: at(6), live: false, cancelled: false)
        let o2 = GhostDepartures.Option(id: "real", line: "306", departs: at(21), scheduled: at(20), live: true, cancelled: false)
        let o3 = GhostDepartures.Option(id: "train", line: "IC", departs: at(30), scheduled: at(30), live: false, cancelled: false)
        XCTAssertEqual(GhostDepartures.order([o1, o2, o3], now: now), ["real", "train", "ghost"])
        XCTAssertEqual(GhostDepartures.statuses([o1, o2], now: now)["ghost"], .unsure)
        XCTAssertEqual(GhostDepartures.order([o1], now: now), ["ghost"], "only unsure ones: as they are")
    }

    func test_normalized() {
        XCTAssertEqual(GhostDepartures.normalized("'s-Hertogenbosch, Centraal"), "shertogenboschcentraal")
        XCTAssertTrue(GhostDepartures.sameHeadsign("Veghel", "Veghel Busstation"))
        XCTAssertTrue(GhostDepartures.sameHeadsign("", "Uden"))
        XCTAssertFalse(GhostDepartures.sameHeadsign("Uden", "Veghel"))
    }
}

final class DepartureGroupsGhostTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 5_100_000)
    private func at(_ min: Double) -> Date { now.addingTimeInterval(min * 60) }
    private func dep(_ trip: String, _ min: Double, live: Bool, cancelled: Bool = false, head: String = "Veghel") -> DepartureGroups.Departure {
        DepartureGroups.Departure(tripId: trip, stopId: "s1", line: "306", headsign: head, time: at(min), scheduled: at(min), live: live,
                                  cancelled: cancelled, platform: nil, train: false, stopName: "Schijndel, Centrum")
    }

    func test_cleaned_marksDedupesAndHides() {
        let deps = [dep("ghost", 6, live: false), dep("dup-a", 10, live: true), dep("dup-b", 10, live: false, head: "Veghel Busstation"),
                    dep("cx", 12, live: true, cancelled: true)]
        let out = DepartureGroups.cleaned(deps, now: now)
        XCTAssertEqual(out.map(\.tripId), ["dup-a", "ghost"])
        XCTAssertTrue(out[1].unsure)
        XCTAssertFalse(out[0].unsure)
    }

    func test_cards_rankUnsureBelowLive() {
        var ghost = dep("ghost", 6, live: false)
        ghost.unsure = true
        let live = dep("live", 10, live: true)
        let cards = DepartureGroups.cards(stops: [DepartureGroups.Stop(id: "s1", name: "Schijndel", rail: false, metres: 100)],
                                          departures: [ghost, live], now: now)
        XCTAssertEqual(cards.first?.departures.map(\.tripId), ["live", "ghost"])
    }
}
