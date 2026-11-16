import XCTest

final class PlanCompareTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 4_000_000)
    private func o(_ id: String, _ dep: Double, _ arr: Double, changes: Int = 1, room: Int? = 5) -> PlanCompare.Option {
        PlanCompare.Option(id: id, depart: now.addingTimeInterval(dep * 60), arrive: now.addingTimeInterval(arr * 60), changes: changes,
                           minRoom: changes == 0 ? nil : room)
    }

    func test_fastestRoomFewest() {
        let opts = [o("a", 5, 54, room: 3), o("b", 35, 84, room: 9), o("c", 10, 70, changes: 0)]
        let l = PlanCompare.labels(opts, deadline: nil)
        XCTAssertEqual(l["a"], .fastest)
        XCTAssertEqual(l["b"], .room)
        XCTAssertEqual(l["c"], .fewest)
    }

    func test_latestStillInTime() {
        let opts = [o("a", 5, 50), o("b", 20, 58), o("c", 40, 75)]
        let l = PlanCompare.labels(opts, deadline: now.addingTimeInterval(60 * 60))
        XCTAssertEqual(l["a"], .fastest)
        XCTAssertEqual(l["b"], .latest)
        XCTAssertNil(l["c"], "too late: no label")
    }

    func test_noneInTimeStillLabelsTheFastest() {
        let l = PlanCompare.labels([o("a", 5, 90), o("b", 10, 95)], deadline: now.addingTimeInterval(30 * 60))
        XCTAssertEqual(l["a"], .fastest)
        XCTAssertNil(l["b"])
    }

    func test_directFastestHasNoRoomLabel() {
        let l = PlanCompare.labels([o("a", 5, 40, changes: 0), o("b", 6, 50, room: 12)], deadline: nil)
        XCTAssertEqual(l, ["a": .fastest])
        XCTAssertEqual(PlanCompare.labels([], deadline: nil), [:])
    }

    func test_useful() {
        let opts = [o("late", 10, 80), o("beats", 12, 60), o("early", 2, 58)]
        XCTAssertEqual(PlanCompare.useful(opts).map(\.id), ["early", "beats"])
    }

    func test_actions() {
        XCTAssertTrue(PlanCompare.offersGo(fromHere: true, when: .now, now: now))
        XCTAssertFalse(PlanCompare.offersGo(fromHere: false, when: .now, now: now))
        XCTAssertFalse(PlanCompare.offersGo(fromHere: true, when: .leave(now.addingTimeInterval(3600)), now: now))
        XCTAssertTrue(PlanCompare.offersGo(fromHere: true, when: .arrive(now.addingTimeInterval(2 * 3600)), now: now))
        XCTAssertFalse(PlanCompare.offersGo(fromHere: true, when: .arrive(now.addingTimeInterval(5 * 3600)), now: now))
        XCTAssertTrue(PlanCompare.offersRemind(homeSchool: true, fromHere: false, when: .arrive(now), day: 1))
        XCTAssertFalse(PlanCompare.offersRemind(homeSchool: true, fromHere: false, when: .now, day: 0))
        XCTAssertFalse(PlanCompare.offersRemind(homeSchool: false, fromHere: false, when: .leave(now), day: 0))
        XCTAssertFalse(PlanCompare.offersRemind(homeSchool: true, fromHere: true, when: .leave(now), day: 0))
        XCTAssertFalse(PlanCompare.offersRemind(homeSchool: true, fromHere: false, when: .leave(now), day: 2))
    }
}
