import XCTest

/// The home's "you're on bus …" look (0.26.1): shaped like the field log of 2026-11-19, walking at a change in Den Bosch.
final class OnBoardRulesTests: XCTestCase {
    private enum Kind { case gps, live, timetable }

    private func j(_ id: String, _ kind: Kind, _ r: Result<Double, Reject>, you: Double = 5, fixes: Int = 15) -> Judgement {
        var e = Evidence(fixes: fixes, span: 28, crossTrack: 8, accuracy: 10, shaped: true, progress: you * 28, offset: 0,
                         drift: 0, yourSpeed: you, itsSpeed: 10, steady: true)
        e.gps = kind == .gps
        return Judgement(id: id, line: id, isTrain: false, realTime: kind != .timetable, evidence: e, result: r)
    }

    /// 07:53:17 · "9·8406 timetable 6 s | 305·7821 gps 14 s | …" while walking: the timetable-only 9 never beats the
    /// 305 by its GPS.
    func test_timetableNeverBeatsGPS() {
        let look = [j("9", .timetable, .success(6)), j("305", .gps, .success(14)), j("305b", .gps, .failure(.tooFarFromTimes)),
                    j("3", .timetable, .failure(.wrongWay))]
        XCTAssertEqual(OnBoardRules.best(look, yourSpeed: 5), "305")
        // at bus speed the same: by GPS first
        let fast = [j("9", .timetable, .success(6), you: 12), j("305", .gps, .success(14), you: 12)]
        XCTAssertEqual(OnBoardRules.best(fast, yourSpeed: 12), "305")
    }

    /// 07:54:18 · "15·9583 timetable 15 s | 119·1256 timetable 21 s | …" walking (150 m in 30 s): no bus claimed.
    func test_timetableOnlyWhileWalkingIsNone() {
        let look = [j("15", .timetable, .success(15)), j("119", .timetable, .success(21)), j("319", .timetable, .success(21))]
        XCTAssertNil(OnBoardRules.best(look, yourSpeed: 5))
        // moving like a bus: it counts
        let riding = look.map { x -> Judgement in
            guard case .success(let c) = x.result else { return x }
            return j(x.id, .timetable, .success(c), you: 11)
        }
        XCTAssertEqual(OnBoardRules.best(riding, yourSpeed: 11), "15")
        // with one fix: the GPS's own speed
        XCTAssertNil(OnBoardRules.best([j("15", .timetable, .success(15), you: 0, fixes: 1)], yourSpeed: 4))
        XCTAssertEqual(OnBoardRules.best([j("15", .timetable, .success(15), you: 0, fixes: 1)], yourSpeed: 9), "15")
    }

    /// Live times (not GPS) at walking speed still count as before, and keep their order with a GPS one.
    func test_liveKeepsItsPlace() {
        XCTAssertEqual(OnBoardRules.best([j("a", .live, .success(5)), j("b", .gps, .success(14))], yourSpeed: 5), "a")
        XCTAssertEqual(OnBoardRules.best([j("a", .live, .success(5))], yourSpeed: 1), "a")
        XCTAssertNil(OnBoardRules.best([j("a", .live, .failure(.offItsPath))], yourSpeed: 10))
        XCTAssertNil(OnBoardRules.best([], yourSpeed: 10))
    }

    /// 07:33:58 · a trip running on the 305: the home's on-board look never starts it again, on the same one or
    /// another; nor one you ended a ride on, or one a trip already started on by itself.
    func test_mayAutoStart() {
        XCTAssertFalse(OnBoardRules.mayAutoStart("7821", idle: false, running: "7821", blocked: []))
        XCTAssertFalse(OnBoardRules.mayAutoStart("7821", idle: false, running: "7954", blocked: []))
        XCTAssertFalse(OnBoardRules.mayAutoStart("7821", idle: true, running: nil, blocked: ["7821"]))
        XCTAssertTrue(OnBoardRules.mayAutoStart("7821", idle: true, running: nil, blocked: ["7954"]))
    }
}
