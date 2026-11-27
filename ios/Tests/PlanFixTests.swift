import XCTest

/// 0.42.8: ways kept by live times, and walks timed by their distance (the same vectors as Android's `PlanFixTest`;
/// minutes after 2026-11-27 00:00 UTC).
final class PlanFixTests: XCTestCase {
    private let base: Double = 1_795_737_600
    private func hm(_ h: Double, _ m: Double) -> Date { Date(timeIntervalSince1970: base + (h * 60 + m) * 60) }
    private func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    // MARK: by live times (Breda, 14:45)

    func test_aLateTrainStillToLeaveIsKeptAndRankedFirst() {
        let now = hm(14, 45)
        let eindhoven = LiveKeep.Way(departure: hm(14, 48), scheduled: hm(14, 38), start: hm(14, 46))     // 14:38 +10
        let zwolle = LiveKeep.Way(departure: hm(14, 54), scheduled: hm(14, 49), start: hm(14, 52))        // 14:49 +5
        let gone = LiveKeep.Way(departure: hm(14, 35), scheduled: hm(14, 30), start: hm(14, 33))          // 14:30 +5: left
        XCTAssertTrue(LiveKeep.keep(eindhoven, now: now))
        XCTAssertTrue(LiveKeep.keep(zwolle, now: now))
        XCTAssertFalse(LiveKeep.keep(gone, now: now))
        XCTAssertEqual(LiveKeep.order([zwolle, eindhoven]), [1, 0])
        // its live time just gone (20 s): still there; 40 s: gone; cancelled: gone; set off too long ago: gone
        XCTAssertTrue(LiveKeep.keep(LiveKeep.Way(departure: hm(14, 45).addingTimeInterval(-20), scheduled: hm(14, 38), start: hm(14, 44)), now: now))
        XCTAssertFalse(LiveKeep.keep(LiveKeep.Way(departure: hm(14, 45).addingTimeInterval(-40), scheduled: hm(14, 38), start: hm(14, 44)), now: now))
        XCTAssertFalse(LiveKeep.keep(LiveKeep.Way(departure: hm(14, 48), scheduled: hm(14, 38), start: hm(14, 46), cancelled: true), now: now))
        XCTAssertFalse(LiveKeep.keep(LiveKeep.Way(departure: hm(14, 48), scheduled: hm(14, 38), start: hm(14, 43)), now: now))
    }

    func test_askedFromFurtherBackAtAStation() {
        XCTAssertEqual(LiveKeep.askAt(now: hm(14, 45), atStation: true), hm(14, 30))
        XCTAssertEqual(LiveKeep.askAt(now: hm(14, 45), atStation: false), hm(14, 43))
        XCTAssertEqual(LiveKeep.count(5, atStation: true), 8)
        XCTAssertEqual(LiveKeep.count(5, atStation: false), 5)
    }

    func test_changesStillMadeAfterTheDelay() {
        // 14:48 → Eindhoven 15:22, the 15:31 on: made; a 15:24 one with a 2 min walk: missed
        XCTAssertTrue(LiveKeep.connects(arrivals: [hm(15, 22), hm(15, 50)], departures: [hm(14, 48), hm(15, 31)], walks: [3, 2]))
        XCTAssertFalse(LiveKeep.connects(arrivals: [hm(15, 22), hm(15, 50)], departures: [hm(14, 48), hm(15, 23)], walks: [3, 2]))
        XCTAssertTrue(LiveKeep.connects(arrivals: [hm(15, 22)], departures: [hm(14, 48)], walks: [3]))
    }

    func test_lateWords() {
        XCTAssertEqual(LiveKeep.lateWords(line: "IC", to: "Eindhoven Centraal", scheduled: hm(14, 38), departure: hm(14, 48), platform: "3", clock: clock),
                       "The 14:38 IC to Eindhoven Centraal is 10 min late — leaves 14:48 from platform 3")
    }

    // MARK: walks by their distance

    func test_speedIsYoursAfterFiveWalks() {
        XCTAssertEqual(WalkFirst.speed(learned: 1.35, walks: 5), 1.35)
        XCTAssertEqual(WalkFirst.speed(learned: 1.35, walks: 4), 1.2)
        XCTAssertEqual(WalkFirst.speed(learned: nil, walks: 9), 1.2)
    }

    func test_walkRetimedByItsDistance() {
        // the planner's 10 min over 780 m of foot route, the stop 240 m away: an odd route, the straight line × 1.3
        let m = WalkFirst.metres(planner: 780, straight: 240)
        XCTAssertEqual(m ?? 0, 312, accuracy: 0.01)
        XCTAssertEqual(WalkFirst.walk(plannerMinutes: 10, metres: m, speed: 1.35), 4)
        // a fair route: its own metres; never longer than the planner's minutes; unknown: the planner's
        XCTAssertEqual(WalkFirst.metres(planner: 400, straight: 300), 400)
        XCTAssertEqual(WalkFirst.walk(plannerMinutes: 10, metres: 400, speed: 1.35), 5)
        XCTAssertEqual(WalkFirst.walk(plannerMinutes: 3, metres: 400, speed: 1.35), 3)
        XCTAssertEqual(WalkFirst.walk(plannerMinutes: 10, metres: nil, speed: 1.35), 10)
        XCTAssertEqual(WalkFirst.metres(planner: nil, straight: 100) ?? 0, 130, accuracy: 0.01)
        XCTAssertEqual(WalkFirst.logLine(plannerMinutes: 10, plannerMetres: 780, yours: 4, speed: 1.35, usedYours: true),
                       "walk · planner 10 min (780 m) · yours 4 min (1.35 m/s) · used yours")
    }

    func test_hopFirstReplacedWhenTheWalkMakesTheSameRide() {
        // 07:20: a 4 min bus to Veghel busstation, then the 07:40 from there; walking there is 520 m
        XCTAssertEqual(WalkFirst.walkInstead(rideMinutes: 4, now: hm(7, 20), start: hm(7, 22), nextDeparture: hm(7, 40), walkMetres: 520, speed: 1.35), 7)
        // walking would miss it: keep the hop
        XCTAssertNil(WalkFirst.walkInstead(rideMinutes: 4, now: hm(7, 20), start: hm(7, 20), nextDeparture: hm(7, 26), walkMetres: 520, speed: 1.35))
        // a longer ride isn't a hop; a walk much longer than the hop isn't better
        XCTAssertNil(WalkFirst.walkInstead(rideMinutes: 8, now: hm(7, 20), start: hm(7, 22), nextDeparture: hm(7, 40), walkMetres: 520, speed: 1.35))
        XCTAssertNil(WalkFirst.walkInstead(rideMinutes: 4, now: hm(7, 20), start: hm(7, 28), nextDeparture: hm(7, 40), walkMetres: 1500, speed: 1.35))
    }
}
