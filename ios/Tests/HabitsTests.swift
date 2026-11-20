import XCTest

/// 0.34: learned from your own rides and walks, on the phone only.
final class HabitsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: walking speed

    /// Walking east at `speed`, a fix every 2 s for `seconds`.
    private func walk(_ speed: Double, seconds: Int, accuracy: Double = 8, gpsSpeed: Bool = true) -> [Fix] {
        stride(from: 0, through: seconds, by: 2).map { s in
            let m = speed * Double(s)
            return Fix(t: t0.addingTimeInterval(Double(s)), p: GeoPoint(lat: 51.59, lon: 4.70 + m / (111_320 * cos(51.59 * .pi / 180))),
                       accuracy: accuracy, speed: gpsSpeed ? speed : -1, course: 90)
        }
    }

    func test_aWalksSpeed() {
        XCTAssertEqual(Habits.walkSpeed(of: walk(1.5, seconds: 120)) ?? 0, 1.5, accuracy: 0.05)
        XCTAssertEqual(Habits.walkSpeed(of: walk(1.1, seconds: 120, gpsSpeed: false)) ?? 0, 1.1, accuracy: 0.05)
        XCTAssertNil(Habits.walkSpeed(of: walk(1.5, seconds: 30)), "too short to say")
        XCTAssertNil(Habits.walkSpeed(of: walk(1.5, seconds: 120, accuracy: 60)), "fixes too rough")
        XCTAssertNil(Habits.walkSpeed(of: walk(6, seconds: 120)), "a bike, not a walk")
        // standing still at the stop doesn't count as slow walking
        let wait = walk(0, seconds: 100) + walk(1.4, seconds: 120).map { Fix(t: $0.t.addingTimeInterval(102), p: $0.p, accuracy: $0.accuracy, speed: $0.speed, course: $0.course) }
        XCTAssertEqual(Habits.walkSpeed(of: wait) ?? 0, 1.4, accuracy: 0.05)
    }

    func test_yourWalkingSpeedOnceThereAreEnoughWalks() {
        var b = HabitBook()
        for _ in 0..<(Habits.walksNeeded - 1) { b.addWalk(1.6) }
        XCTAssertNil(Habits.walkSpeed(b))
        b.addWalk(1.6)
        XCTAssertEqual(Habits.walkSpeed(b), 1.6)
        // the planner's walk of 10 minutes at its 1.2 m/s, at your 1.6: 8 minutes
        XCTAssertEqual(Habits.walkMinutes(10, b), 8)
        XCTAssertEqual(Habits.walkMinutes(0, b), 0)
        XCTAssertEqual(Habits.walkMinutes(10, HabitBook()), 10, "nothing learned: the planner's")
        // the planner gets your speed (only when it's clearly not its own)
        XCTAssertEqual(Habits.pedestrianSpeed(b), 1.6)
        var slowish = HabitBook()
        for _ in 0..<Habits.walksNeeded { slowish.addWalk(1.25) }
        XCTAssertNil(Habits.pedestrianSpeed(slowish))
    }

    func test_walksKeptAreTheNewest() {
        var b = HabitBook()
        for _ in 0..<60 { b.addWalk(0.9) }
        for _ in 0..<Habits.keep { b.addWalk(1.8) }
        XCTAssertEqual(Habits.walkSpeed(b), 1.8)
        b.addWalk(.nan); b.addWalk(9)
        XCTAssertEqual(b.walks.count, Habits.keep, "nonsense isn't kept")
    }

    // MARK: change time

    func test_changeTimeInPractice() {
        let stop = GeoPoint(lat: 51.59, lon: 4.70 + 200 / (111_320 * cos(51.59 * .pi / 180)))
        // 200 m at 1.25 m/s: within 50 m of it after 120 s
        let f = walk(1.25, seconds: 300)
        XCTAssertEqual(Habits.changeMinutes(arrived: t0, fixes: f, stop: stop) ?? 0, 2, accuracy: 0.05)
        XCTAssertNil(Habits.changeMinutes(arrived: t0, fixes: Array(f.prefix(20)), stop: stop), "never got there")
    }

    func test_yourChangeTime() {
        var b = HabitBook()
        b.addChange(2); b.addChange(3)
        XCTAssertNil(Habits.changeMinutes(b))
        b.addChange(4)
        XCTAssertEqual(Habits.changeMinutes(b), 4, "what you needed on most days (the 80th percentile)")
        for _ in 0..<7 { b.addChange(2) }
        XCTAssertEqual(Habits.changeMinutes(b), 2, "8 of 10 days 2 minutes were enough")
    }

    // MARK: stops you prefer

    func test_preferredStops() {
        var b = HabitBook()
        b.plannedFrom("Breda, Station")
        for _ in 0..<3 { b.boarded(at: "Breda, Bolkenplein") }
        b.boarded(at: "Breda, Station")
        XCTAssertTrue(Habits.preferred("Breda, Bolkenplein", b))
        XCTAssertFalse(Habits.preferred("Breda, Station", b), "you get on there as often as it's planned")
        XCTAssertFalse(Habits.preferred("Elsewhere", b))
        XCTAssertEqual(Habits.bonus(firstStop: " breda, bolkenplein ", b), Habits.preferredBonus)
        XCTAssertEqual(Habits.bonus(firstStop: "Breda, Station", b), 0)
        XCTAssertEqual(Habits.preferredStops(b), ["Breda, Bolkenplein"])
    }

    // MARK: the settings row

    func test_wordsAndReset() {
        var b = HabitBook()
        XCTAssertEqual(Habits.rows(b).map(\.value), ["not yet", "not yet", "none yet", "none yet"])
        for _ in 0..<Habits.walksNeeded { b.addWalk(1.5) }
        for m in [3.0, 4, 5] { b.addChange(m) }
        for _ in 0..<3 { b.boarded(at: "Breda, Bolkenplein") }
        XCTAssertEqual(Habits.rows(b).map(\.value), ["5.4 km/h", "5 min", "Breda, Bolkenplein", "none yet"])
        XCTAssertEqual(Habits.rows(b).map(\.label), ["Walking speed", "Time you need to change", "Stops you prefer", "Your usual lines"])
        XCTAssertTrue(b.isEmpty == false)
        XCTAssertTrue(HabitBook().isEmpty)
    }

    func test_codable() throws {
        var b = HabitBook()
        b.addWalk(1.4); b.addChange(3); b.boarded(at: "X"); b.plannedFrom("Y")
        let back = try JSONDecoder().decode(HabitBook.self, from: JSONEncoder().encode(b))
        XCTAssertEqual(back, b)
    }
}
