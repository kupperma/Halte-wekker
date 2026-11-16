import XCTest

final class DayTimelineTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        c.firstWeekday = 2
        return c
    }()
    private func at(_ d: Int, _ h: Int = 0, _ m: Int = 0, month: Int = 11) -> Date {
        cal.date(from: DateComponents(year: 2026, month: month, day: d, hour: h, minute: m))!
    }
    private func clock(_ d: Date) -> String { DayTimeline.fmt("HH:mm", cal).string(from: d) }

    // MARK: the timeline

    func test_fullDayInOrder() {
        var i = DayTimeline.Input(classStart: at(17, 9), title: "Design", room: "C1.04")
        i.leave = at(17, 7, 41); i.arrive = at(17, 8, 52); i.alarm = at(17, 7, 5)
        i.rides = [DayTimeline.Ride(line: "306", train: false, departure: at(17, 7, 44), to: "Den Bosch"),
                   DayTimeline.Ride(line: "IC", train: true, departure: at(17, 8, 16), to: "Breda", change: 6)]
        i.classesEnd = at(17, 15, 30); i.homeLeave = at(17, 15, 42); i.homeArrive = at(17, 16, 40)
        let items = DayTimeline.items(i, clock: clock)
        XCTAssertEqual(items.map(\.kind), [.wake, .leave, .firstClass, .leaveHome])
        XCTAssertEqual(items[0].time, at(17, 7, 5))
        XCTAssertNil(items[0].detail)
        XCTAssertEqual(items[1].rides.count, 2)
        XCTAssertEqual(items[1].detail, "At school 08:52")
        XCTAssertEqual(items[2].detail, "Design · C1.04\nClasses until 15:30")
        XCTAssertEqual(items[3].detail, "Home around 16:40")
    }

    func test_skippedDayShowsTheTimeItWouldRing() {
        var i = DayTimeline.Input(classStart: at(18, 9), title: "Class", room: nil)
        i.wouldWake = at(18, 6, 40); i.skipped = true; i.leave = at(18, 7, 40); i.lines = "306 · IC · 4"
        let items = DayTimeline.items(i, clock: clock)
        XCTAssertEqual(items[0].time, at(18, 6, 40))
        XCTAssertEqual(items[0].detail, "Off for this day")
        XCTAssertEqual(items[1].detail, "306 · IC · 4", "no rides known for this day: the lines")
        XCTAssertEqual(items.map(\.kind), [.wake, .leave, .firstClass], "no way home yet: left out")
        XCTAssertEqual(items[2].detail, "Class")
    }

    func test_defaultDayAndTitles() {
        XCTAssertEqual(DayTimeline.defaultDay(now: at(17, 8), todayFirst: at(17, 9), todayEnd: at(17, 15, 30), cal: cal), at(17))
        XCTAssertEqual(DayTimeline.defaultDay(now: at(17, 16), todayFirst: at(17, 9), todayEnd: at(17, 15, 30), cal: cal), at(18))
        XCTAssertEqual(DayTimeline.defaultDay(now: at(17, 14), todayFirst: at(17, 9), todayEnd: nil, cal: cal), at(17))
        XCTAssertEqual(DayTimeline.defaultDay(now: at(17, 8), todayFirst: nil, todayEnd: nil, cal: cal), at(18))
        XCTAssertEqual(DayTimeline.title(at(17, 10), now: at(17, 8), cal: cal), "Today")
        XCTAssertEqual(DayTimeline.title(at(18, 10), now: at(17, 23), cal: cal), "Tomorrow")
        XCTAssertEqual(DayTimeline.title(at(19), now: at(17, 8), cal: cal), "Thursday")
        XCTAssertEqual(DayTimeline.label(at(17), cal: cal), "Tue 17 Nov")
    }

    // MARK: skipping a day's alarm

    func test_skippedDateHasNoAlarmTheNextDayStillDoes() {
        let skipped: Set<String> = ["2026-11-17"]
        let now = at(16, 20)
        // the skipped day's alarm goes; one never set stays unset
        XCTAssertEqual(SchoolSkip.decide(at(17, 7), day: "2026-11-17", skipped: skipped, current: at(17, 7), hasId: true, now: now), .clear)
        XCTAssertEqual(SchoolSkip.decide(at(17, 7), day: "2026-11-17", skipped: skipped, current: nil, hasId: false, now: now), .keep)
        // the next day: set as usual, or kept when it's that minute already
        XCTAssertEqual(SchoolSkip.decide(at(18, 7), day: "2026-11-18", skipped: skipped, current: nil, hasId: false, now: now),
                       .set(at(18, 7), schedule: true))
        XCTAssertEqual(SchoolSkip.decide(at(18, 7), day: "2026-11-18", skipped: skipped, current: at(18, 7, 0), hasId: true, now: now), .keep)
        XCTAssertEqual(SchoolSkip.decide(at(18, 7, 5), day: "2026-11-18", skipped: skipped, current: at(18, 7), hasId: true, now: now),
                       .set(at(18, 7, 5), schedule: true))
    }

    func test_unskipRestores() {
        var skipped: Set<String> = ["2026-11-17"]
        skipped.remove("2026-11-17")
        XCTAssertEqual(SchoolSkip.decide(at(17, 7), day: "2026-11-17", skipped: skipped, current: nil, hasId: false, now: at(16, 20)),
                       .set(at(17, 7), schedule: true))
        // at once, from the trip it has: leave 07:40, wake 60 min before
        XCTAssertEqual(SchoolSkip.restore(leave: at(17, 7, 40), wakeMinutes: 60, now: at(16, 20)), at(17, 6, 40))
        // too late for it: none (and planning sets no alarm to ring either)
        XCTAssertNil(SchoolSkip.restore(leave: at(17, 7, 40), wakeMinutes: 60, now: at(17, 6, 40)))
        XCTAssertNil(SchoolSkip.restore(leave: nil, wakeMinutes: 60, now: at(16, 20)))
        XCTAssertEqual(SchoolSkip.decide(at(17, 7), day: "2026-11-17", skipped: [], current: nil, hasId: false, now: at(17, 7)),
                       .set(at(17, 7), schedule: false))
    }

    func test_pruneKeepsTodayAndLater() {
        XCTAssertEqual(SchoolSkip.prune(["2026-11-15", "2026-11-16", "2026-12-01"], today: "2026-11-16"), ["2026-11-16", "2026-12-01"])
    }

    // MARK: coming up

    private func ev(_ title: String, _ s: Date, _ e: Date, allDay: Bool = false, cancelled: Bool = false) -> ComingUp.Event {
        ComingUp.Event(title: title, start: s, end: e, allDay: allDay, cancelled: cancelled)
    }

    /// Classes Mon 16 to Fri 20 except Wed 18; none the week of the 23rd; classes again from Mon 30 until Tue 1 Dec.
    func test_freeWeekdaysWithinTheKnownRange() {
        var events: [ComingUp.Event] = []
        for d in [16, 17, 19, 20] { events.append(ev("Class", at(d, 9), at(d, 12))) }
        events.append(ev("Class", at(30, 9), at(30, 12)))
        events.append(ev("Class", at(1, 9, month: 12), at(1, 12, month: 12)))
        let r = ComingUp.build(events, now: at(16, 8), cal: cal)
        XCTAssertEqual(r.knownUntil, at(1, month: 12))
        // (Wednesday never has classes in the weeks known: a free Wednesday isn't news)
        XCTAssertEqual(r.items.map(\.when), ["Mon 23 – Fri 27 Nov"])
        XCTAssertEqual(r.items.map(\.title), ["No classes"])
    }

    /// Classes Mon to Thu for three weeks, Fridays never: a free Wednesday in week two shows, the Fridays don't.
    func test_singleFreeDayOnlyOnAUsualClassDay() {
        var events: [ComingUp.Event] = []
        for week in 0..<3 {
            for wd in 0..<4 where !(week == 1 && wd == 2) {
                let d = 16 + week * 7 + wd
                let (day, month) = d > 30 ? (d - 30, 12) : (d, 11)
                events.append(ev("Class", at(day, 9, month: month), at(day, 12, month: month)))
            }
        }
        let r = ComingUp.build(events, now: at(16, 8), cal: cal)
        XCTAssertEqual(r.items.map(\.when), ["Wed 25 Nov"])
    }

    func test_cancelledClassesMakeAFreeDayAndWeekendsJoinARun() {
        let events = [ev("Class", at(20, 9), at(20, 12), cancelled: true),
                      ev("Class", at(24, 9), at(24, 12))]
        // now Thu 19 (no class): Thu 19, Fri 20 (cancelled) and Mon 23 are one run over the weekend
        let r = ComingUp.build(events, now: at(19, 10), cal: cal)
        XCTAssertEqual(r.items.map(\.when), ["Thu 19 – Mon 23 Nov"])
    }

    func test_namedAndAllDayEvents() {
        let events = [ev("Class", at(16, 9), at(16, 12)), ev("Class", at(17, 9), at(17, 12)),
                      ev("Tentamen Maths", at(17, 13), at(17, 15)),
                      ev("Kerstvakantie", at(19, month: 12), at(31, month: 12), allDay: true),
                      ev("Lunch", at(17, 12), at(17, 13))]
        let r = ComingUp.build(events, now: at(16, 8), cal: cal, limit: 10)
        XCTAssertTrue(r.items.contains { $0.title == "Tentamen Maths" && $0.when == "Tue 17 Nov" })
        XCTAssertTrue(r.items.contains { $0.title == "Kerstvakantie" && $0.kind == .event })
        XCTAssertFalse(r.items.contains { $0.title == "Lunch" })
        XCTAssertTrue(ComingUp.isNamedDate("Project Week 3"))
        XCTAssertTrue(ComingUp.isNamedDate("EXAM"))
        XCTAssertFalse(ComingUp.isNamedDate("Design studio"))
    }

    func test_nothingKnown() {
        let r = ComingUp.build([], now: at(16), cal: cal)
        XCTAssertEqual(r.items, [])
        XCTAssertNil(r.knownUntil)
    }

    func test_rangeLabels() {
        XCTAssertEqual(ComingUp.range(at(26), at(26), cal), "Thu 26 Nov")
        XCTAssertEqual(ComingUp.range(at(30), at(2, month: 12), cal), "Mon 30 Nov – Wed 2 Dec")
    }
}
