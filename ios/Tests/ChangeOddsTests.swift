import XCTest

/// 0.34: how reliable a change is, from your own history of it.
final class ChangeOddsTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return c
    }()

    private func date(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m))!
    }

    func test_keyAndBucket() {
        // Thursday 19 November 07:40: a weekday morning
        let k = ChangeOdds.key(from: "IC", to: "SPR", at: "Tilburg", time: date(19, 7, 40), calendar: cal)
        XCTAssertEqual(k, "IC>SPR@tilburg|wd-am")
        XCTAssertEqual(ChangeOdds.bucket(date(19, 12), calendar: cal), "wd-day")
        XCTAssertEqual(ChangeOdds.bucket(date(19, 17, 30), calendar: cal), "wd-pm")
        XCTAssertEqual(ChangeOdds.bucket(date(19, 21), calendar: cal), "wd-eve")
        XCTAssertEqual(ChangeOdds.bucket(date(19, 6), calendar: cal), "wd-early")
        XCTAssertEqual(ChangeOdds.bucket(date(21, 8), calendar: cal), "we-am", "Saturday")
        XCTAssertEqual(ChangeOdds.day(date(19, 7, 40), calendar: cal), "20261119")
    }

    func test_oneOutcomePerDay() {
        var b = ChangeBook()
        let k = "IC>SPR@tilburg|wd-am"
        b.record(k, day: "20261119", made: false)
        b.record(k, day: "20261119", made: true)        // the same day again: the last one counts
        b.record(k, day: "20261118", made: true)
        XCTAssertEqual(b.tally(k).days, 2)
        XCTAssertEqual(b.tally(k).made, 2)
        XCTAssertEqual(b.tally("other").days, 0)
    }

    func test_keepsTheNewestDays() {
        var b = ChangeBook()
        for d in 0..<45 { b.record("k", day: String(format: "2026%04d", 1000 + d), made: d >= 40) }
        XCTAssertEqual(b.tally("k").days, ChangeBook.daysKept)
        XCTAssertEqual(b.tally("k").made, 5, "the newest days are the ones kept")
    }

    func test_words() {
        XCTAssertNil(ChangeOdds.words(made: 2, days: 2), "fewer than 3: nothing to say")
        XCTAssertEqual(ChangeOdds.words(made: 9, days: 10), "this change worked on 9 of 10 days")
        XCTAssertEqual(ChangeOdds.words(made: 3, days: 3), "this change worked on 3 of 3 days")
    }

    func test_missChanceLeansOnYourHistory() {
        // nothing learned: the model's
        XCTAssertEqual(ChangeOdds.missChance(model: 0.3, made: 0, days: 0), 0.3)
        XCTAssertEqual(ChangeOdds.missChance(model: 0.3, made: 2, days: 2), 0.3, "fewer than 3 days: the model's")
        // made it every day for 10 days: much less
        XCTAssertLessThan(ChangeOdds.missChance(model: 0.3, made: 10, days: 10), 0.15)
        // missed it on most days: more
        XCTAssertGreaterThan(ChangeOdds.missChance(model: 0.1, made: 2, days: 8), 0.35)
        // a change you can't make (no time at all) stays one
        XCTAssertEqual(ChangeOdds.missChance(model: 0.95, made: 10, days: 10), 0.95)
    }

    func test_outcome() {
        let dep = date(19, 8, 0)
        XCTAssertEqual(ChangeOdds.made(plannedTrip: "a", plannedDeparture: dep, boardedTrip: "a", boardedDeparture: nil), true)
        XCTAssertEqual(ChangeOdds.made(plannedTrip: "a", plannedDeparture: dep, boardedTrip: "b", boardedDeparture: dep.addingTimeInterval(30)), true,
                       "another one leaving then (its id changed, or the one alongside)")
        XCTAssertEqual(ChangeOdds.made(plannedTrip: "a", plannedDeparture: dep, boardedTrip: "b", boardedDeparture: dep.addingTimeInterval(600)), false)
        XCTAssertNil(ChangeOdds.made(plannedTrip: "a", plannedDeparture: dep, boardedTrip: "b", boardedDeparture: nil))
    }

    func test_codable() throws {
        var b = ChangeBook()
        b.record("k", day: "20261119", made: true)
        XCTAssertEqual(try JSONDecoder().decode(ChangeBook.self, from: JSONEncoder().encode(b)), b)
    }
}
