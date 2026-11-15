import XCTest

final class RecompCalendarTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        c.firstWeekday = 2
        return c
    }()

    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func test_dayStartsAtFour() {
        XCTAssertEqual(RecompCalendar.day(for: at(2026, 11, 16, 3, 59), calendar: cal), "2026-11-15")
        XCTAssertEqual(RecompCalendar.day(for: at(2026, 11, 16, 4, 0), calendar: cal), "2026-11-16")
        XCTAssertEqual(RecompCalendar.day(for: at(2026, 11, 16, 23, 30), calendar: cal), "2026-11-16")
    }

    func test_dstNights() {
        XCTAssertEqual(RecompCalendar.day(for: at(2026, 3, 29, 3, 59), calendar: cal), "2026-03-28")
        XCTAssertEqual(RecompCalendar.day(for: at(2026, 10, 25, 3, 59), calendar: cal), "2026-10-24")
        XCTAssertEqual(RecompCalendar.day(for: at(2026, 10, 25, 4, 0), calendar: cal), "2026-10-25")
    }

    func test_bounds() {
        let b = RecompCalendar.bounds(of: "2026-11-16", calendar: cal)
        XCTAssertEqual(b.start, at(2026, 11, 16, 4, 0))
        XCTAssertEqual(b.end, at(2026, 11, 17, 4, 0))
    }

    /// The nights the clocks change: 23 and 25 hours, and the edges agree with `day(for:)`.
    func test_boundsOnDstNights() {
        let spring = RecompCalendar.bounds(of: "2026-03-28", calendar: cal)
        XCTAssertEqual(spring.start, at(2026, 3, 28, 4, 0))
        XCTAssertEqual(spring.end, at(2026, 3, 29, 4, 0))
        XCTAssertEqual(spring.end.timeIntervalSince(spring.start), 23 * 3600, accuracy: 0.5)
        XCTAssertEqual(RecompCalendar.day(for: spring.end.addingTimeInterval(-60), calendar: cal), "2026-03-28")
        XCTAssertEqual(RecompCalendar.day(for: spring.end, calendar: cal), "2026-03-29")

        let autumn = RecompCalendar.bounds(of: "2026-10-24", calendar: cal)
        XCTAssertEqual(autumn.start, at(2026, 10, 24, 4, 0))
        XCTAssertEqual(autumn.end, at(2026, 10, 25, 4, 0))
        XCTAssertEqual(autumn.end.timeIntervalSince(autumn.start), 25 * 3600, accuracy: 0.5)
        XCTAssertEqual(RecompCalendar.day(for: autumn.end.addingTimeInterval(-60), calendar: cal), "2026-10-24")
        XCTAssertEqual(RecompCalendar.day(for: autumn.end, calendar: cal), "2026-10-25")
    }

    func test_monday() {
        XCTAssertEqual(RecompCalendar.monday(of: "2026-11-15", calendar: cal), "2026-11-09")
        XCTAssertEqual(RecompCalendar.monday(of: "2026-11-16", calendar: cal), "2026-11-16")
    }

    func test_addingAndBetween() {
        XCTAssertEqual(RecompCalendar.adding(28, to: "2026-11-16", calendar: cal), "2026-12-14")
        XCTAssertEqual(RecompCalendar.daysBetween("2026-11-16", "2026-12-14", calendar: cal), 28)
        XCTAssertEqual(RecompCalendar.adding(7, to: "2026-03-23", calendar: cal), "2026-03-30")
    }

    func test_shortText() {
        XCTAssertEqual(RecompCalendar.shortText("2026-11-16"), "16 Nov")
    }
}
