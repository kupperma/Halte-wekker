import XCTest

final class FromStopTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 9_000_000)
    private func at(_ min: Double) -> Date { now.addingTimeInterval(min * 60) }
    private func dep(_ id: String, line: String = "306", _ min: Double, sched: Double? = nil, live: Bool = true, cancelled: Bool = false,
                     platform: String? = nil, head: String = "'s-Hertogenbosch") -> FromStop.Dep {
        FromStop.Dep(id: id, tripId: id, line: line, headsign: head, time: at(min), scheduled: at(sched ?? min), live: live,
                     cancelled: cancelled, platform: platform, train: false, stop: "Veghel, Bolkenplein")
    }

    func test_linesThatGetYouThereFirst_othersApart() {
        let deps = [dep("a", 3), dep("x", line: "158", 4, head: "Uden"), dep("b", line: "305", 9), dep("c", 18), dep("y", line: "158", 25, head: "Uden")]
        let b = FromStop.board(deps, usefulLines: ["306", "305"], current: "c", atStop: at(5), now: now)
        XCTAssertEqual(b.useful.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(b.other.map(\.id), ["x", "y"])
        XCTAssertTrue(b.useful[2].current)
    }

    func test_oneYouCantBeThereFor_isGreyed_andNotSwitchable() {
        let deps = [dep("a", 3), dep("b", 9), dep("c", 18)]
        let b = FromStop.board(deps, usefulLines: ["306"], current: "b", atStop: at(5), now: now)
        XCTAssertTrue(b.useful[0].dimmed)
        XCTAssertFalse(b.useful[0].switchable)
        XCTAssertFalse(b.useful[1].switchable, "the one you're on already")
        XCTAssertTrue(b.useful[2].switchable)
    }

    func test_atMostSix_andTheCurrentOneAlwaysShown() {
        var deps: [FromStop.Dep] = []
        for k in 0..<9 { deps.append(dep("d\(k)", Double(2 + 5 * k))) }
        let b = FromStop.board(deps, usefulLines: ["306"], current: "d8", atStop: now, now: now)
        XCTAssertEqual(b.useful.count, FromStop.maxUseful)
        XCTAssertEqual(b.useful.last?.id, "d8")
    }

    func test_ghostRulesApply_cancelledHidden_unsureLower() {
        let deps = [dep("ghost", 6, live: false), dep("gone", 12, live: true, cancelled: true), dep("real", 10, live: true)]
        let b = FromStop.board(deps, usefulLines: ["306"], current: nil, atStop: now, now: now)
        XCTAssertEqual(b.useful.map(\.id), ["real", "ghost"])
        XCTAssertEqual(b.useful.last?.status, .unsure)
    }

    func test_lateAndPlace() {
        let b = FromStop.board([dep("a", 7, sched: 4, platform: "B"), dep("t", 9, live: false)], usefulLines: ["306"], current: nil, atStop: now, now: now)
        XCTAssertEqual(b.useful.first?.late, "+3")
        XCTAssertEqual(FromStop.place(b.useful[0].dep), "Stand B")
        XCTAssertNil(b.useful.first(where: { $0.id == "t" })?.late)
        XCTAssertEqual(FromStop.countdown(b.useful[0].dep, now: now), "in 7 min")
    }

    func test_leftOnes_go() {
        let b = FromStop.board([dep("old", -3), dep("a", 5)], usefulLines: ["306"], current: nil, atStop: now, now: now)
        XCTAssertEqual(b.useful.map(\.id), ["a"])
    }
}
