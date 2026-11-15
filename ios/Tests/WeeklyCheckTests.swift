import XCTest

final class WeeklyCheckTests: XCTestCase {
    private let today = "2026-12-14"

    private func week(_ monday: DayKey, kg: Double, days: Int = 5) -> [Measure] {
        (0..<days).map { Measure(day: RecompCalendar.adding($0, to: monday), value: kg) }
    }

    private func eval(_ w: [Measure], _ waists: [Measure] = [], _ s: CheckState = CheckState(), today t: DayKey? = nil) -> (Verdict, CheckState) {
        WeeklyCheck.evaluate(weights: w, waists: waists, state: s, today: t ?? today)
    }

    private var flatEatLess: [Measure] { week("2026-11-16", kg: 88.0) + week("2026-12-07", kg: 87.9) }

    func test_weekAverage() {
        let w = [Measure(day: "2026-12-08", value: 88.0), Measure(day: "2026-12-14", value: 89.0)]
        XCTAssertEqual(WeightMath.weekAverage(w, endingOn: "2026-12-14")!, 88.5, accuracy: 0.001)
        XCTAssertNil(WeightMath.weekAverage(w, endingOn: "2026-11-01"))
    }

    func test_waistDue() {
        XCTAssertTrue(WeightMath.waistDue([], skippedOn: nil, today: today))
        XCTAssertFalse(WeightMath.waistDue([Measure(day: "2026-12-01", value: 90)], skippedOn: nil, today: today))
        XCTAssertTrue(WeightMath.waistDue([Measure(day: "2026-11-30", value: 90)], skippedOn: nil, today: today))
        XCTAssertFalse(WeightMath.waistDue([Measure(day: "2026-11-30", value: 90)], skippedOn: today, today: today))
    }

    func test_notEnoughData() {
        let w = week("2026-11-16", kg: 88, days: 3) + week("2026-11-23", kg: 88) + week("2026-11-30", kg: 88) + week("2026-12-07", kg: 88)
        let (v, s) = eval(w)
        XCTAssertEqual(v, .notEnoughData)
        XCTAssertEqual(s, CheckState())
    }

    func test_eatLess() {
        let (v, s) = eval(flatEatLess)
        XCTAssertEqual(v, .eatLess)
        XCTAssertEqual(s.pending, PendingAdvice(kind: .eatLess, shownOn: "2026-12-14"))
    }

    func test_recompWorking() {
        let waists = [Measure(day: "2026-11-18", value: 93.0), Measure(day: "2026-12-09", value: 91.5)]
        let (v, s) = eval(flatEatLess, waists)
        guard case .recompWorking(let cm) = v else { return XCTFail("got \(v)") }
        XCTAssertEqual(cm, -1.5, accuracy: 0.001)
        XCTAssertNil(s.pending)
    }

    func test_onTrack() {
        let (v, _) = eval(week("2026-11-16", kg: 88.6) + week("2026-12-07", kg: 87.7))
        guard case .onTrack(let kg) = v else { return XCTFail("got \(v)") }
        XCTAssertEqual(kg, -0.3, accuracy: 0.001)
    }

    func test_eatMore() {
        let (v, s) = eval(week("2026-11-23", kg: 89.4) + week("2026-11-30", kg: 88.8) + week("2026-12-07", kg: 88.2))
        XCTAssertEqual(v, .eatMore)
        XCTAssertEqual(s.pending?.kind, .eatMore)
    }

    func test_pendingStaysUntilAdjusted() {
        let state = CheckState(pending: PendingAdvice(kind: .eatLess, shownOn: "2026-12-14"), baseline: nil)
        let w = week("2026-11-30", kg: 88.6) + week("2026-12-14", kg: 87.7)
        let (v, s) = eval(w, [], state, today: "2026-12-21")
        XCTAssertEqual(v, .eatLess)
        XCTAssertEqual(s, state)
    }

    func test_adjustedWaits() {
        let state = WeeklyCheck.adjusted(CheckState(pending: PendingAdvice(kind: .eatLess, shownOn: "2026-11-16"), baseline: nil))
        XCTAssertEqual(state.baseline, "2026-11-16")
        XCTAssertNil(state.pending)
        let w = week("2026-11-09", kg: 90) + week("2026-11-16", kg: 88.6) + week("2026-12-07", kg: 87.7)
        let (v1, _) = eval(w, [], state, today: "2026-12-07")
        XCTAssertEqual(v1, .waiting(adjustedOn: "2026-11-16", nextCheck: "2026-12-14"))
        let (v2, _) = eval(w, [], state, today: "2026-12-14")
        guard case .onTrack(let kg) = v2 else { return XCTFail("got \(v2)") }
        XCTAssertEqual(kg, -0.3, accuracy: 0.001)
    }

    func test_autoBaselineAfterThreeWeeks() {
        let state = CheckState(pending: PendingAdvice(kind: .eatLess, shownOn: "2026-11-16"), baseline: nil)
        let (v, s) = eval(flatEatLess, [], state, today: "2026-12-07")
        XCTAssertEqual(v, .waiting(adjustedOn: "2026-11-16", nextCheck: "2026-12-14"))
        XCTAssertEqual(s.baseline, "2026-11-16")
        XCTAssertNil(s.pending)
    }

    func test_text() {
        XCTAssertEqual(WeeklyCheck.text(.eatLess).title, "Your weight hasn't moved in 3 weeks. Eat about 200 kcal less a day.")
        XCTAssertEqual(WeeklyCheck.text(.eatLess).detail, "A smaller plate, measured oil, or no second helping.")
        XCTAssertEqual(WeeklyCheck.text(.eatMore).title, "You're losing faster than 0.5 kg a week. Eat a bit more so you keep your muscle.")
        XCTAssertNil(WeeklyCheck.text(.eatMore).detail)
        XCTAssertEqual(WeeklyCheck.text(.recompWorking(waistCm: -1.5)).title, "Weight steady, waist down 1.5 cm. That's a recomp working.")
        XCTAssertEqual(WeeklyCheck.text(.onTrack(kgPerWeek: -0.3)).title, "On track: losing 0.3 kg a week.")
        XCTAssertEqual(WeeklyCheck.text(.waiting(adjustedOn: "2026-11-16", nextCheck: "2026-12-14")).title, "Adjusted on 16 Nov. Next check on 14 Dec.")
        XCTAssertEqual(WeeklyCheck.text(.notEnoughData).title, "Not enough weigh-ins yet.")
        XCTAssertEqual(WeeklyCheck.text(.notEnoughData).detail, "Weigh in at least 4 mornings a week. The check compares this week with 3 weeks ago.")
    }
}
