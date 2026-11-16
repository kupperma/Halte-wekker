import XCTest

final class ChangeRoomTests: XCTestCase {
    private let t0 = Fx.t0

    func test_roomByGrade() {
        XCTAssertEqual(ChangeRoom.needed(afterGrade: "C"), 6)
        XCTAssertEqual(ChangeRoom.needed(afterGrade: "B"), 4)
        for g in ["S", "A", nil] as [String?] { XCTAssertEqual(ChangeRoom.needed(afterGrade: g), 2) }
        XCTAssertEqual(ChangeRoom.extra(afterGrade: "C"), 4)
        XCTAssertEqual(ChangeRoom.extra(afterGrade: "B"), 2)
        XCTAssertEqual(ChangeRoom.extra(afterGrade: "A"), 0)
    }

    /// The same ranks as the board's speed rank (`Ratings.grade`), without remembering anything.
    func test_speedGrade() {
        // the fastest seen on the stretch: 20 min
        XCTAssertEqual(ChangeRoom.speedGrade(minutes: 21, scheduled: 20, best: 20, cancelled: false), "S")      // 1 min slower
        XCTAssertEqual(ChangeRoom.speedGrade(minutes: 23, scheduled: 20, best: 20, cancelled: false), "A")      // 3 min
        XCTAssertEqual(ChangeRoom.speedGrade(minutes: 25.5, scheduled: 22, best: 20, cancelled: false), "B")    // 27% longer
        XCTAssertEqual(ChangeRoom.speedGrade(minutes: 27, scheduled: 22, best: 20, cancelled: false), "C")      // 35% longer
        XCTAssertEqual(ChangeRoom.speedGrade(minutes: 60, scheduled: 55, best: 50, cancelled: false), "B")      // 10 min, 20% longer
        // its own timetable is a new fastest: ranked against that (as `grade` would after remembering it)
        XCTAssertEqual(ChangeRoom.speedGrade(minutes: 18, scheduled: 18, best: 20, cancelled: false), "S")
        XCTAssertEqual(ChangeRoom.speedGrade(minutes: 25, scheduled: 18, best: nil, cancelled: false), "C")
        // nothing seen yet and no timetable: its own time is the fastest
        XCTAssertEqual(ChangeRoom.speedGrade(minutes: 25, scheduled: 0, best: nil, cancelled: false), "S")
        XCTAssertNil(ChangeRoom.speedGrade(minutes: 25, scheduled: 20, best: 20, cancelled: true))
        XCTAssertNil(ChangeRoom.speedGrade(minutes: 0, scheduled: 20, best: 20, cancelled: false))
    }

    /// The miss chance as it was (before slow buses got more room), for comparing.
    private func old(slack: Double, typical: Double, already: Double, soon: Bool, learned: [Double]) -> Double {
        if slack < 0 { return 0.95 }
        var p = min(0.95, exp(-(slack + 1) / typical))
        if learned.count >= 4 && !soon {
            let late = learned.filter { $0 > already + slack + 0.5 }.count
            let seen = min(0.95, (Double(late) + 0.5) / (Double(learned.count) + 1))
            let w = Double(learned.count) / Double(learned.count + 4)
            p = w * seen + (1 - w) * p
        }
        return p
    }

    /// The same slack after an S bus and after a C bus: the C one is likelier to be missed (a B one in between), and an
    /// S or A bus is exactly as before.
    func test_slowFeederRiskier() {
        let learned: [Double] = [0, 1, 2.5, 4, 1.5, 6, 0.5, 3]
        for (slack, typical, soon, l) in [(5.0, 2.0, false, [Double]()), (5.0, 3.5, false, learned), (3.0, 0.8, true, learned),
                                           (8.0, 2.6, false, learned), (0.0, 2.0, false, [Double]())] {
            let s = ChangeRoom.missChance(slack: slack, typical: typical, already: 0, soon: soon, learned: l,
                                          extra: ChangeRoom.extra(afterGrade: "S"))
            let b = ChangeRoom.missChance(slack: slack, typical: typical, already: 0, soon: soon, learned: l,
                                          extra: ChangeRoom.extra(afterGrade: "B"))
            let c = ChangeRoom.missChance(slack: slack, typical: typical, already: 0, soon: soon, learned: l,
                                          extra: ChangeRoom.extra(afterGrade: "C"))
            XCTAssertEqual(s, old(slack: slack, typical: typical, already: 0, soon: soon, learned: l), accuracy: 1e-12)
            XCTAssertGreaterThan(c, s, "slack \(slack)")
            XCTAssertGreaterThanOrEqual(c, b)
            XCTAssertGreaterThanOrEqual(b, s)
        }
        // what it costs, a train missed (20 min): 5 minutes after an S bus is safe enough, after a C bus it isn't
        let sCost = ChangeRoom.missChance(slack: 5, typical: 2.6, already: 0, soon: false, learned: []) * 20
        let cCost = ChangeRoom.missChance(slack: 5, typical: 2.6, already: 0, soon: false, learned: [], extra: 4) * 20
        XCTAssertLessThan(sCost, 3.5)
        XCTAssertGreaterThan(cCost, 3.5)
        // no room at all is as before: 95%
        XCTAssertEqual(ChangeRoom.missChance(slack: -1, typical: 2, already: 0, soon: false, learned: [], extra: 4), 0.95)
        XCTAssertLessThanOrEqual(ChangeRoom.missChance(slack: 1, typical: 2, already: 0, soon: false, learned: [], extra: 4), 0.95)
    }

    private struct Bus { let leaves: Date; let atStation: Date; let grade: String? }

    /// The planner's bus before the train: the latest that's at the station the room its rank needs before the train.
    func test_plannerPicksEarlierBusForC() {
        let train = t0 + 36 * 60                                   // 08:36
        let early = Bus(leaves: t0, atStation: t0 + 20 * 60, grade: "S")            // there 08:20
        func pick(_ late: Bus) -> Bus? {
            ChangeRoom.inTime([early, late], trainLeaves: train, end: { $0.atStation }, departure: { $0.leaves }, grade: { $0.grade }).first
        }
        let lateS = Bus(leaves: t0 + 10 * 60, atStation: t0 + 33 * 60, grade: "S")   // there 08:33: 3 min
        let lateC = Bus(leaves: t0 + 10 * 60, atStation: t0 + 33 * 60, grade: "C")
        let lateB = Bus(leaves: t0 + 10 * 60, atStation: t0 + 33 * 60, grade: "B")
        XCTAssertEqual(pick(lateS)?.leaves, lateS.leaves)           // 2 min is enough after an S bus
        XCTAssertEqual(pick(lateC)?.leaves, early.leaves)           // a C bus needs 6: the earlier one
        XCTAssertEqual(pick(lateB)?.leaves, early.leaves)           // a B bus needs 4
        let roomyC = Bus(leaves: t0 + 8 * 60, atStation: t0 + 30 * 60, grade: "C")   // there 08:30: 6 min
        XCTAssertEqual(pick(roomyC)?.leaves, roomyC.leaves)
        let atTwo = Bus(leaves: t0 + 10 * 60, atStation: t0 + 34 * 60, grade: "A")    // exactly 2 min
        XCTAssertEqual(pick(atTwo)?.leaves, atTwo.leaves)
        XCTAssertTrue(ChangeRoom.inTime([lateC], trainLeaves: train, end: { $0.atStation }, departure: { $0.leaves }, grade: { $0.grade }).isEmpty)
    }

    func test_warnOnRide() {
        XCTAssertTrue(ChangeRoom.warnOnRide(grade: "C", roomMinutes: 5.9))
        XCTAssertTrue(ChangeRoom.warnOnRide(grade: "C", roomMinutes: -2))
        XCTAssertFalse(ChangeRoom.warnOnRide(grade: "C", roomMinutes: 6))
        XCTAssertFalse(ChangeRoom.warnOnRide(grade: "B", roomMinutes: 3))
        XCTAssertFalse(ChangeRoom.warnOnRide(grade: nil, roomMinutes: 1))
        XCTAssertFalse(ChangeRoom.warnOnRide(grade: "C", roomMinutes: .nan))
    }
}
