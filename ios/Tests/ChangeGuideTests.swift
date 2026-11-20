import XCTest

/// 0.39: the change ahead, guided: platforms, the walk, the minutes, a miss and the one you make instead.
final class ChangeGuideTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ m: Double) -> Date { t0.addingTimeInterval(m * 60) }
    private func hhmm(_ d: Date) -> String { "+\(Int(d.timeIntervalSince(t0) / 60))" }
    private func train(_ id: String, _ m: Double, _ p: String?, walk: Int = 0) -> ChangeGuide.Ride {
        ChangeGuide.Ride(tripId: id, line: "IC", isTrain: true, departure: at(m), platform: p, walk: walk)
    }

    func test_platformWords() {
        XCTAssertEqual(ChangeGuide.platforms(arrive: "5", next: train("a", 0, "7")), "Platform 5 → 7")
        XCTAssertEqual(ChangeGuide.platforms(arrive: "5", next: train("a", 0, "5")), "Same platform (5)")
        XCTAssertEqual(ChangeGuide.platforms(arrive: nil, next: train("a", 0, "7")), "To platform 7")
        XCTAssertEqual(ChangeGuide.platforms(arrive: "5", next: train("a", 0, nil)), "Arrive at platform 5")
        XCTAssertEqual(ChangeGuide.platforms(arrive: " ", next: train("a", 0, "")), nil)
        let bus = ChangeGuide.Ride(tripId: "b", line: "306", isTrain: false, departure: at(0), platform: "B")
        XCTAssertEqual(ChangeGuide.platforms(arrive: "3b", next: bus), "Platform 3b → bus 306")
        XCTAssertNil(ChangeGuide.platforms(arrive: nil, next: bus))
    }

    func test_needIsTheWalkOrYourOwnChangeTime() {
        XCTAssertEqual(ChangeGuide.need(walk: 3, learned: nil), 3)
        XCTAssertEqual(ChangeGuide.need(walk: 3, learned: 4), 4)
        XCTAssertEqual(ChangeGuide.need(walk: 3, learned: 9), 5, "your change time counts 2 min over the walk at most")
        XCTAssertEqual(ChangeGuide.need(walk: 0, learned: nil), ChangeGuide.least, "never under a minute")
        XCTAssertEqual(ChangeGuide.need(walk: 4, learned: 2), 4)
    }

    func test_plentyOfRoom() {
        let g = ChangeGuide.guide(arrive: at(0), arrivePlatform: "5", fromTrain: true, grade: nil, next: train("p", 7, "7", walk: 3),
                                  later: [], learned: nil, now: at(-10), hhmm: hhmm)
        XCTAssertFalse(g.missed)
        XCTAssertFalse(g.tight)
        XCTAssertEqual(g.minutes, 7)
        XCTAssertEqual(g.countdown, "7 min to change")
        XCTAssertEqual(g.lockLine, "Platform 5 → 7 · 3 min walk")
        XCTAssertNil(g.missText)
        XCTAssertNil(g.planned)
        XCTAssertEqual(g.target.tripId, "p")
    }

    func test_aLateRideMissesItAndSaysWhatInstead() {
        // the train is late: in at +10, the 08:12 (+9) gone; the next one at +12 is too tight for a 3 min walk, +25 is made
        let later = [train("q", 12, "6", walk: 3), train("r", 25, "4", walk: 3), train("p", 9, "7", walk: 3)]
        let g = ChangeGuide.guide(arrive: at(10), arrivePlatform: "5", fromTrain: true, grade: nil, next: train("p", 9, "7", walk: 3),
                                  later: later, learned: 4, now: at(-5), hhmm: hhmm)
        XCTAssertTrue(g.missed)
        XCTAssertTrue(g.tight)
        XCTAssertEqual(g.target.tripId, "r")
        XCTAssertEqual(g.planned?.tripId, "p")
        XCTAssertEqual(g.minutes, 15)
        XCTAssertEqual(g.missText, "You’ll miss the +9 — take the +25 from platform 4")
        XCTAssertEqual(g.lockLine, "Platform 5 → 4 · 3 min walk")
    }

    func test_yourOwnChangeTimeDecidesAMiss() {
        let next = train("p", 3, "7", walk: 2)
        let walkOnly = ChangeGuide.guide(arrive: at(0), arrivePlatform: nil, fromTrain: true, grade: nil, next: next, later: [],
                                         learned: nil, now: at(-3), hhmm: hhmm)
        XCTAssertFalse(walkOnly.missed, "3 min for a 2 min walk")
        let slow = ChangeGuide.guide(arrive: at(0), arrivePlatform: nil, fromTrain: true, grade: nil, next: next, later: [],
                                     learned: 4, now: at(-3), hhmm: hhmm)
        XCTAssertTrue(slow.missed, "you need 4 min to change, it leaves 3 min after you're in")
    }

    func test_noLaterOneFound() {
        let g = ChangeGuide.guide(arrive: at(10), arrivePlatform: nil, fromTrain: true, grade: nil, next: train("p", 8, "7"),
                                  later: [], learned: nil, now: at(0), hhmm: hhmm)
        XCTAssertTrue(g.missed)
        XCTAssertEqual(g.target.tripId, "p")
        XCTAssertEqual(g.minutes, -2)
        XCTAssertEqual(g.countdown, "It leaves before you’re there")
        XCTAssertEqual(g.missText, "You’ll likely miss the +8")
    }

    func test_atTheChangeItCountsFromNow() {
        // got off at +0, now +3: the one at +7 leaves in 4
        let g = ChangeGuide.guide(arrive: at(0), arrivePlatform: "5", fromTrain: true, grade: nil, next: train("p", 7, "7", walk: 2),
                                  later: [], learned: nil, now: at(3), hhmm: hhmm)
        XCTAssertEqual(g.countdown, "4 min to change")
        XCTAssertFalse(g.missed)
    }

    func test_aBusInsteadIsNamed() {
        let bus = ChangeGuide.Ride(tripId: "b2", line: "306", isTrain: false, departure: at(20), platform: "B", walk: 4)
        let next = ChangeGuide.Ride(tripId: "b1", line: "306", isTrain: false, departure: at(5), platform: "B", walk: 4)
        let g = ChangeGuide.guide(arrive: at(3), arrivePlatform: "3", fromTrain: true, grade: nil, next: next, later: [bus],
                                  learned: nil, now: at(0), hhmm: hhmm)
        XCTAssertEqual(g.missText, "You’ll miss the +5 — take bus 306 at +20")
        XCTAssertEqual(g.platforms, "Platform 3 → bus 306")
    }

    func test_aSlowBusWantsMoreRoomButStillMakesIt() {
        // 5 min for a 1 min walk after a C bus: tight (it wants 6), not missed
        let g = ChangeGuide.guide(arrive: at(0), arrivePlatform: nil, fromTrain: false, grade: "C", next: train("p", 5, "3", walk: 1),
                                  later: [], learned: nil, now: at(-8), hhmm: hhmm)
        XCTAssertTrue(g.tight)
        XCTAssertFalse(g.missed)
    }

    func test_pickPlanByTripElseByTime() {
        let i = train("r", 25, "4")
        XCTAssertEqual(ChangeGuide.pickPlan([("x", at(20)), ("r", at(25))], instead: i), 1)
        XCTAssertEqual(ChangeGuide.pickPlan([("x", at(20)), ("y", at(25.5))], instead: i), 1)
        XCTAssertNil(ChangeGuide.pickPlan([("x", at(20)), ("y", at(30))], instead: i))
    }
}
