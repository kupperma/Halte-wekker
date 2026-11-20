import XCTest

final class StudentOVTests: XCTestCase {
    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        StudentOV.calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }
    private func fare(_ p: StudentOV.Product, _ d: Date, train: Bool = true) -> StudentOV.Fare? { StudentOV.fare(p, at: d, train: train)?.fare }

    // 2026-11-16 is a Monday; 2026-11-20 a Friday.

    func test_noProduct() {
        XCTAssertNil(StudentOV.fare(.none, at: at(2026, 11, 18, 10), train: true))
        XCTAssertNil(StudentOV.line(.none, at: at(2026, 11, 18, 10), train: true, fullCents: 600))
    }

    func test_weekProduct_mondayFourToSaturdayFour() {
        XCTAssertEqual(fare(.week, at(2026, 11, 16, 3, 59)), .discount(percent: 40))   // still Sunday's
        XCTAssertEqual(fare(.week, at(2026, 11, 16, 4, 0)), .free)
        XCTAssertEqual(fare(.week, at(2026, 11, 18, 8, 0)), .free)
        XCTAssertEqual(fare(.week, at(2026, 11, 21, 3, 59)), .free)                     // Friday's night
        XCTAssertEqual(fare(.week, at(2026, 11, 21, 4, 0)), .discount(percent: 40))
        XCTAssertEqual(StudentOV.fare(.week, at: at(2026, 11, 22, 12), train: true)?.why, .weekend)
        XCTAssertEqual(fare(.week, at(2026, 11, 22, 12), train: false), .discount(percent: 34))   // buses: 34%
    }

    func test_weekendProduct_windows() {
        // Friday: full until 09:00, discount until 12:00, then free
        XCTAssertEqual(fare(.weekend, at(2026, 11, 20, 8, 59)), .full)
        XCTAssertEqual(StudentOV.fare(.weekend, at: at(2026, 11, 20, 8), train: true)?.why, .morning)
        XCTAssertEqual(fare(.weekend, at(2026, 11, 20, 9, 0)), .discount(percent: 40))
        XCTAssertEqual(fare(.weekend, at(2026, 11, 20, 11, 59)), .discount(percent: 40))
        XCTAssertEqual(fare(.weekend, at(2026, 11, 20, 12, 0)), .free)
        XCTAssertEqual(fare(.weekend, at(2026, 11, 21, 3, 0)), .free)                    // Friday's night
        XCTAssertEqual(fare(.weekend, at(2026, 11, 22, 18)), .free)                      // Sunday
        XCTAssertEqual(fare(.weekend, at(2026, 11, 23, 3, 59)), .free)                   // until Monday 04:00
        XCTAssertEqual(fare(.weekend, at(2026, 11, 23, 4, 0)), .discount(percent: 40))   // Monday: discount all day
        XCTAssertEqual(fare(.weekend, at(2026, 11, 23, 7, 0)), .discount(percent: 40))
        XCTAssertEqual(fare(.weekend, at(2026, 11, 24, 3, 0)), .discount(percent: 40))   // Monday's night
        // Tuesday–Thursday: full 04:00–09:00, then a discount
        XCTAssertEqual(fare(.weekend, at(2026, 11, 24, 4, 0)), .full)
        XCTAssertEqual(fare(.weekend, at(2026, 11, 26, 8, 30)), .full)
        XCTAssertEqual(fare(.weekend, at(2026, 11, 26, 9, 0)), .discount(percent: 40))
        XCTAssertEqual(fare(.weekend, at(2026, 11, 26, 9, 0), train: false), .discount(percent: 34))
    }

    func test_summerIsDiscountForTheWeekProductOnly() {
        XCTAssertEqual(fare(.week, at(2026, 7, 16, 3, 59)), .free)                        // Wednesday 15th's night
        XCTAssertEqual(fare(.week, at(2026, 7, 16, 4, 0)), .discount(percent: 40))
        XCTAssertEqual(StudentOV.fare(.week, at: at(2026, 8, 3, 9), train: true)?.why, .summer)
        XCTAssertEqual(fare(.week, at(2026, 8, 17, 9)), .free)                            // Monday after
        XCTAssertEqual(fare(.weekend, at(2026, 8, 1, 10)), .free)                         // a summer Saturday
        XCTAssertEqual(fare(.weekend, at(2026, 8, 4, 10)), .discount(percent: 40))        // as the rest of the year
    }

    func test_holidays() {
        // DUO's list for 2026 and 2027
        for (y, m, d) in [(2026, 1, 1), (2026, 4, 3), (2026, 4, 6), (2026, 4, 27), (2026, 5, 5), (2026, 5, 14), (2026, 5, 25), (2026, 12, 25),
                          (2027, 3, 26), (2027, 3, 29), (2027, 4, 27), (2027, 5, 6), (2027, 5, 17)] {
            XCTAssertNotNil(StudentOV.holiday(year: y, month: m, day: d), "\(y)-\(m)-\(d)")
        }
        XCTAssertNil(StudentOV.holiday(year: 2026, month: 11, day: 20))
        // King's Day on a Sunday moves to the 26th (2025: 27 April is a Sunday)
        XCTAssertEqual(StudentOV.holiday(year: 2025, month: 4, day: 26), .kingsDay)
        XCTAssertNil(StudentOV.holiday(year: 2025, month: 4, day: 27))
        // week product: a discount on a holiday, except Good Friday
        XCTAssertEqual(fare(.week, at(2026, 4, 6, 10)), .discount(percent: 40))
        XCTAssertEqual(StudentOV.fare(.week, at: at(2026, 4, 6, 10), train: true)?.why, .holiday)
        XCTAssertEqual(fare(.week, at(2026, 4, 7, 3, 59)), .discount(percent: 40))        // until 04:00 the next day
        XCTAssertEqual(fare(.week, at(2026, 4, 7, 4, 0)), .free)
        XCTAssertEqual(fare(.week, at(2026, 4, 3, 10)), .free)                            // Good Friday
        // weekend product: free on a holiday, Good Friday and Ascension from 12:00 the day before
        XCTAssertEqual(fare(.weekend, at(2026, 5, 5, 7)), .free)
        XCTAssertEqual(fare(.weekend, at(2026, 5, 13, 11, 59)), .discount(percent: 40))
        XCTAssertEqual(fare(.weekend, at(2026, 5, 13, 12, 0)), .free)
        XCTAssertEqual(fare(.weekend, at(2026, 4, 2, 13)), .free)
        XCTAssertEqual(fare(.weekend, at(2026, 4, 2, 8)), .full)
    }

    func test_words() {
        XCTAssertEqual(StudentOV.line(.week, at: at(2026, 11, 18, 8), train: true, fullCents: 600), "Free with your student OV")
        XCTAssertEqual(StudentOV.line(.weekend, at: at(2026, 11, 18, 10), train: true, fullCents: 600), "Costs money now (weekday) — ~€3.60 with 40% off")
        XCTAssertEqual(StudentOV.line(.weekend, at: at(2026, 11, 18, 8), train: true, fullCents: 600), "Costs money now (weekday morning) — ~€6.00")
        XCTAssertEqual(StudentOV.line(.week, at: at(2026, 11, 22, 8), train: true, fullCents: nil), "Costs money now (weekend) — 40% off")
        XCTAssertEqual(StudentOV.line(.weekend, at: at(2026, 11, 18, 8), train: false, fullCents: nil), "Costs money now (weekday morning) — full fare")
        XCTAssertEqual(StudentOV.euros(1234), "€12.34")
        XCTAssertEqual(StudentOV.euros(5), "€0.05")
    }

    func test_tripLine_firstNotFreeDecides() {
        let fri11 = at(2026, 11, 20, 11, 40), fri12 = at(2026, 11, 20, 12, 5)
        XCTAssertEqual(StudentOV.tripLine(.weekend, rides: [(false, fri11), (true, fri12)], fullCents: 600),
                       "Costs money now (weekday) — 34% off")                              // the bus, before 12:00
        XCTAssertEqual(StudentOV.tripLine(.weekend, rides: [(true, fri12), (false, fri12)], fullCents: 600), "Free with your student OV")
        XCTAssertNil(StudentOV.tripLine(.none, rides: [(true, fri12)], fullCents: 600))
    }

    func test_fullFareFromRelayAnswers() {
        let trips: [String: Any] = ["source": "trips", "fares": [
            ["priceInCents": 1080, "travelClass": "FIRST_CLASS", "discountType": "NO_DISCOUNT"],
            ["priceInCents": 600, "travelClass": "SECOND_CLASS", "discountType": "NO_DISCOUNT"],
            ["priceInCents": 480, "travelClass": "SECOND_CLASS", "discountType": "DISCOUNT_20_PERCENT"],
        ], "productFare": ["priceInCents": 600, "travelClass": "SECOND_CLASS", "discountType": "NO_DISCOUNT"]]
        XCTAssertEqual(StudentOV.fullFareCents(trips), 600)
        XCTAssertNil(StudentOV.fullFareCents(["source": "trips", "fares": [Any]()]))
        XCTAssertNil(StudentOV.fullFareCents(nil))
        XCTAssertEqual(StudentOV.pay(StudentOV.Answer(fare: .discount(percent: 34), why: .weekday), fullCents: 250), 165)
        XCTAssertNil(StudentOV.pay(StudentOV.Answer(fare: .free, why: .weekday), fullCents: 250))
    }
}
