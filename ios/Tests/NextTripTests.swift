import XCTest

final class NextTripTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 4_000_000)
    private func at(_ min: Double) -> Date { now.addingTimeInterval(min * 60) }

    // MARK: which trip

    func test_pick_dueSchoolFirstThenPlannedThenLive() {
        XCTAssertEqual(NextTrip.pick(schoolDue: true, plannedDue: true, liveLeaves: [at(5)], now: now).source, .school)
        XCTAssertEqual(NextTrip.pick(schoolDue: false, plannedDue: true, liveLeaves: [at(5)], now: now).source, .planned)
        let l = NextTrip.pick(schoolDue: false, plannedDue: false, liveLeaves: [at(5), at(20)], now: now)
        XCTAssertEqual(l.source, .live)
        XCTAssertEqual(l.index, 0)
        XCTAssertNil(NextTrip.pick(schoolDue: true, plannedDue: false, liveLeaves: [at(5)], now: now).index)
    }

    func test_pick_skipsTripsAlreadyMissed() {
        let p = NextTrip.pick(schoolDue: false, plannedDue: false, liveLeaves: [at(-10), at(-1), at(12)], now: now)
        XCTAssertEqual(p.source, .live)
        XCTAssertEqual(p.index, 1, "a minute past its time to leave: still catchable")
        let q = NextTrip.pick(schoolDue: false, plannedDue: false, liveLeaves: [at(-3), at(12)], now: now)
        XCTAssertEqual(q.index, 1)
    }

    func test_pick_noneWhenNothing() {
        XCTAssertEqual(NextTrip.pick(schoolDue: false, plannedDue: false, liveLeaves: [], now: now).source, .none)
        XCTAssertEqual(NextTrip.pick(schoolDue: false, plannedDue: false, liveLeaves: [at(-30)], now: now).source, .none)
    }

    // MARK: the countdown

    func test_countdown() {
        XCTAssertEqual(NextTrip.countdown(leave: at(9.5), now: now), .init(value: "9 min", unit: "until you leave", spoken: "9 minutes until you leave"))
        XCTAssertEqual(NextTrip.countdown(leave: at(1), now: now).spoken, "1 minute until you leave")
        XCTAssertEqual(NextTrip.countdown(leave: at(0.5), now: now).value, "Now")
        XCTAssertEqual(NextTrip.countdown(leave: at(-1), now: now).unit, "time to leave")
        XCTAssertEqual(NextTrip.countdown(leave: at(65), now: now).value, "1 h 05")
        XCTAssertEqual(NextTrip.countdown(leave: at(65), now: now).spoken, "1 hour 5 minutes until you leave")
        XCTAssertEqual(NextTrip.countdown(leave: at(120), now: now).spoken, "2 hours until you leave")
    }

    // MARK: the leg bar

    private func ride(_ d: Double, _ a: Double, _ line: String = "306", train: Bool = false) -> NextTrip.RideSpan {
        NextTrip.RideSpan(departure: at(d), arrival: at(a), line: line, train: train)
    }

    func test_legs_walkRideWaitRideWalk() {
        let l = NextTrip.legs(start: at(0), end: at(60), rides: [ride(4, 30), ride(37, 52, "IC", train: true)])
        XCTAssertEqual(l.map(\.kind), [.walk, .ride, .wait, .ride, .walk])
        XCTAssertEqual(l.map(\.minutes), [4, 26, 7, 15, 8])
        XCTAssertEqual(l[3].line, "IC")
        XCTAssertTrue(l[3].train)
    }

    func test_legs_dropsTinyGapsAndEmpty() {
        let l = NextTrip.legs(start: at(0), end: at(30.2), rides: [ride(0.2, 30)])
        XCTAssertEqual(l.map(\.kind), [.ride])
        XCTAssertEqual(NextTrip.legs(start: at(0), end: at(10), rides: []), [])
    }

    func test_fractions_addUpAndKeepAFloor() {
        let legs = NextTrip.legs(start: at(0), end: at(101), rides: [ride(1, 100)])
        let f = NextTrip.fractions(legs)
        XCTAssertEqual(f.count, 3)
        XCTAssertEqual(f.reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertGreaterThan(f[0], 0.05, "a one-minute walk still shows")
        XCTAssertGreaterThan(f[1], f[0])
        XCTAssertEqual(NextTrip.fractions([]), [])
        let zero = NextTrip.fractions([.init(kind: .ride, minutes: 0), .init(kind: .walk, minutes: 0)])
        XCTAssertEqual(zero, [0.5, 0.5])
    }

    func test_spoken() {
        let l = NextTrip.legs(start: at(0), end: at(48), rides: [ride(3, 35), ride(40, 44, "IC", train: true)])
        XCTAssertEqual(NextTrip.spoken(l), "3 min walk, bus 306 32 min, 5 min to change, train IC 4 min, 4 min walk")
    }

    // MARK: the week

    func test_weekDays() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        let tue = cal.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 18, minute: 30))!
        let days = NextTrip.weekDays(from: tue, cal: cal)
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days.first, cal.startOfDay(for: tue))
        XCTAssertEqual(cal.component(.day, from: days[6]), 23)
        XCTAssertEqual(days.filter { NextTrip.isWeekend($0, cal: cal) }.map { cal.component(.day, from: $0) }, [21, 22])
    }
}
