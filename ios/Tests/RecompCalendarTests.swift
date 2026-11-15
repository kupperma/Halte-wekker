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
