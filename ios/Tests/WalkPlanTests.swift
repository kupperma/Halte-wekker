import XCTest

final class WalkPlanTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 8_000_000)

    func test_nothingLearned_isThePlannersWalk_andNoLaterLeave() {
        let s = WalkPlan.shown(planned: 10, metres: 700, speed: 1.6, walks: 4, plannerSpeed: 1.2)
        XCTAssertEqual(s, WalkPlan.Shown(walk: 10, spare: 0, later: 0, learned: false))
        let none = WalkPlan.shown(planned: 10, metres: 700, speed: nil, walks: 9, plannerSpeed: 1.2)
        XCTAssertFalse(none.learned)
        XCTAssertEqual(none.later, 0)
    }

    func test_fasterWalker_byTheMapsRoute_keepsTwoMinutesSpare() {
        // 570 m at 1.6 m/s: 6 minutes (5.9, up); the planner said 10
        let s = WalkPlan.shown(planned: 10, metres: 570, speed: 1.6, walks: 12, plannerSpeed: 1.2)
        XCTAssertEqual(s.walk, 6)
        XCTAssertEqual(s.spare, 2)
        XCTAssertEqual(s.later, 2, "10 − 6 − 2 spare")
        let leave = WalkPlan.leave(now, s)
        XCTAssertEqual(leave.timeIntervalSince(now), 120)
    }

    func test_withoutTheMap_byThePlannersMinutesAtItsSpeed() {
        // 10 min at 1.2 m/s = 720 m; at 1.55 m/s that's 8 min (7.7, up)
        let s = WalkPlan.shown(planned: 10, metres: nil, speed: 1.55, walks: 5, plannerSpeed: 1.2)
        XCTAssertEqual(s.walk, 8)
        XCTAssertEqual(s.later, 0, "two minutes saved is the spare: no later leave")
        XCTAssertEqual(s.spare, 2)
    }

    func test_slowerWalker_keepsThePlannersTime() {
        let s = WalkPlan.shown(planned: 6, metres: 600, speed: 0.9, walks: 20, plannerSpeed: 1.2)
        XCTAssertEqual(s.walk, 6, "never more than the planner's (it plans with your speed already)")
        XCTAssertEqual(s.later, 0)
    }

    func test_neverLaterThanTheDifferenceLessTheSpare() {
        for planned in 1...25 {
            for metres in stride(from: 50.0, through: 2000, by: 75) {
                let s = WalkPlan.shown(planned: planned, metres: metres, speed: 1.9, walks: 10, plannerSpeed: 1.2)
                XCTAssertLessThanOrEqual(s.later, max(0, planned - s.walk - WalkPlan.spare))
                XCTAssertGreaterThanOrEqual(s.later, 0)
                XCTAssertEqual(s.walk + s.spare + s.later, planned, "the time to leave and the departure stay apart by the planner's walk")
            }
        }
    }

    func test_words() {
        let s = WalkPlan.Shown(walk: 6, spare: 2, later: 2, learned: true)
        XCTAssertEqual(WalkPlan.words(s, leaveIn: 4, leaveBy: nil), "6 min walk · leave in 4 min (2 min spare)")
        XCTAssertEqual(WalkPlan.words(s, leaveIn: nil, leaveBy: "08:04"), "6 min walk · leave by 08:04 (2 min spare)")
        XCTAssertEqual(WalkPlan.words(s, leaveIn: 0, leaveBy: nil), "6 min walk · leave now (2 min spare)")
        XCTAssertEqual(WalkPlan.words(WalkPlan.Shown(walk: 10, spare: 0, later: 0, learned: false), leaveIn: nil, leaveBy: nil), "10 min walk")
    }

    func test_noWalk_staysNone() {
        XCTAssertEqual(WalkPlan.walk(planned: 0, metres: 30, speed: 1.5, walks: 10, plannerSpeed: 1.2), 0)
    }
}
