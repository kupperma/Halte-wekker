import XCTest

final class WorkoutRulesTests: XCTestCase {
    private let zone = TimeZone(identifier: "Europe/Amsterdam")!

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2
        c.timeZone = zone
        return c
    }

    /// "2026-11-12 18:00", Amsterdam time.
    private func date(_ text: String) -> Date {
        let p = text.split { $0 == "-" || $0 == " " || $0 == ":" }.compactMap { Int($0) }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: p[3], minute: p[4]))!
    }

    /// A summary of a workout; its day is the 04:00 day in Amsterdam, not in the zone of the machine running the tests.
    private func summary(_ title: String, ids: [String] = [], at: String = "2026-11-12 18:00", source: WorkoutSource = .app,
                         end: String? = nil, sets: Int = 0) -> WorkoutSummary {
        let done = (0..<sets).map { _ in LoggedSet(kg: 20, reps: 10, done: true) }
        let w = Workout(title: title, routineIds: ids, start: date(at), end: end.map { date($0) }, source: source,
                        exercises: done.isEmpty ? [] : [LoggedExercise(exerciseId: "x", sets: done)])
        var s = WorkoutSummary(w)
        s.day = RecompCalendar.day(for: w.start, calendar: calendar)
        return s
    }

    private func next(_ workouts: [WorkoutSummary], today: DayKey) -> NextUp {
        Rotation.next(Rotation.days(workouts), today: today)
    }

    // MARK: - Rotation

    func test_emptyStartsWithPush() {
        XCTAssertEqual(Rotation.next([], today: "2026-11-15"), .push)
    }

    func test_afterPush() {
        let pull = summary("Pull", ids: ["pull"], at: "2026-11-09 18:00")
        let pullLegs = summary("Pull + legs", ids: ["pull", "legs"], at: "2026-11-09 18:00")
        let push = summary("Push", ids: ["push"], at: "2026-11-11 18:00")
        XCTAssertEqual(next([pull, push], today: "2026-11-12"), .pull(legs: true))
        XCTAssertEqual(next([pullLegs, push], today: "2026-11-12"), .pull(legs: false))
        XCTAssertEqual(next([push], today: "2026-11-12"), .pull(legs: false))
        // Only the Pull right before the last Push counts.
        let older = summary("Pull + legs", ids: ["pull", "legs"], at: "2026-11-03 18:00")
        let olderPush = summary("Push", ids: ["push"], at: "2026-11-06 18:00")
        XCTAssertEqual(next([older, olderPush, pull, push], today: "2026-11-12"), .pull(legs: true))
    }

    func test_afterPullRest() {
        let pull = [summary("Pull", ids: ["pull"], at: "2026-11-14 18:00")]
        XCTAssertEqual(next(pull, today: "2026-11-14"), .restThenPush)
        XCTAssertEqual(next(pull, today: "2026-11-15"), .restThenPush)
        XCTAssertEqual(next(pull, today: "2026-11-16"), .push)
        XCTAssertEqual(next(pull, today: "2026-11-20"), .push)
    }

    func test_hevyTitles() {
        let hevy = [summary("Push", at: "2026-11-10 18:00", source: .hevy),
                    summary("Pull", at: "2026-11-12 18:00", source: .hevy),
                    summary("Legs", at: "2026-11-12 19:30", source: .hevy)]
        XCTAssertEqual(Rotation.days(hevy).map(\.kind), [.push, .pull(legs: true)])
        XCTAssertEqual(Rotation.days([summary(" pUsH ", source: .hevy)]).map(\.kind), [.push])

        let history = [summary("Bro split 1", at: "2026-11-10 18:00", source: .hevy),
                       summary("1", at: "2026-11-11 18:00", source: .hevy),
                       summary("Legs", at: "2026-11-12 18:00", source: .hevy)]
        XCTAssertEqual(Rotation.days(history), [])
    }

    func test_appRoutineIds() {
        XCTAssertEqual(Rotation.days([summary("Pull + legs", ids: ["pull", "legs"])]).map(\.kind), [.pull(legs: true)])
        XCTAssertEqual(Rotation.days([summary("Push", ids: [])]), [])
    }

    func test_afterMidnight() {
        let late = summary("Pull", ids: ["pull"], at: "2026-11-15 00:30")
        XCTAssertEqual(late.day, "2026-11-14")
        XCTAssertEqual(Rotation.days([late]).map(\.day), ["2026-11-14"])
        XCTAssertEqual(next([late], today: "2026-11-15"), .restThenPush)
        XCTAssertEqual(next([late], today: "2026-11-16"), .push)
    }

    func test_isTrainingDay() {
        let today = "2026-11-15"
        XCTAssertTrue(Rotation.isTrainingDay(.pull(legs: false), workouts: [], today: today))
        let done = summary("Push", ids: ["push"], at: "2026-11-15 09:00")
        XCTAssertFalse(Rotation.isTrainingDay(.pull(legs: false), workouts: [done], today: today))
        XCTAssertFalse(Rotation.isTrainingDay(.restThenPush, workouts: [], today: today))
    }

    func test_copy() {
        let today = "2026-11-15"
        let push = summary("Push", ids: ["push"], at: "2026-11-13 18:00")
        XCTAssertEqual(Rotation.cardLine(.pull(legs: true), last: push, today: today), "Next: Pull + legs · Push 2 days ago")
        let pull = summary("Pull", ids: ["pull"], at: "2026-11-14 18:00")
        XCTAssertEqual(Rotation.cardLine(.restThenPush, last: pull, today: today), "Rest day. Next: Push · Pull yesterday")
        XCTAssertEqual(Rotation.cardLine(.push, last: nil, today: today), "Next: Push")

        let last = summary("Push", ids: ["push"], at: "2026-11-12 19:16", end: "2026-11-12 20:31", sets: 22)
        XCTAssertEqual(Rotation.lastLine(last, timeZone: zone), "Last: Push · Thu 12 Nov · 75 min · 22 sets")
        // After midnight it is still the evening before.
        let late = summary("Push", ids: ["push"], at: "2026-11-13 00:30", end: "2026-11-13 01:30", sets: 1)
        XCTAssertEqual(Rotation.lastLine(late, timeZone: zone), "Last: Push · Thu 12 Nov · 60 min · 1 set")

        XCTAssertEqual([NextUp.push, .pull(legs: false), .pull(legs: true), .restThenPush].map(Rotation.title),
                       ["Push", "Pull", "Pull + legs", "Push"])
        XCTAssertEqual([NextUp.push, .pull(legs: false), .pull(legs: true), .restThenPush].map(Rotation.routineIds),
                       [["push"], ["pull"], ["pull", "legs"], ["push"]])
    }

    // MARK: - Progression

    private func done(_ kg: Double?, _ reps: [Int], rir: [Int?] = [], kind: SetKind = .normal) -> [LoggedSet] {
        reps.enumerated().map { i, r in LoggedSet(kind: kind, kg: kg, reps: r, rir: i < rir.count ? rir[i] : nil, done: true) }
    }

    private func holds(_ seconds: [Int]) -> [LoggedSet] {
        seconds.map { LoggedSet(seconds: $0, done: true) }
    }

    private func suggest(_ sets: [LoggedSet], _ t: Target, _ kind: ExerciseKind, step: Double = 2.5,
                         ladder: (rule: MoveUpRule, isLast: Bool)? = nil, deload: Bool = false) -> Suggestion {
        Progression.suggest(last: sets, target: t, kind: kind, step: step, ladder: ladder, deload: deload)
    }

    private let incline = Target(sets: 3, lo: 6, hi: 10, rirLo: 1, rirHi: 2, rest: 150)
    private let pulldown = Target(sets: 3, lo: 8, hi: 12, rirLo: 0, rirHi: 1, rest: 120)

    func test_allAtTopAddsStep() {
        let s = suggest(done(26, [10, 10, 10], rir: [1, 2, 1]), incline, .weight, step: 2)
        XCTAssertEqual(s, Suggestion(kg: 28, values: [6, 6, 6], topReached: true, moveUp: false, increased: true))
        XCTAssertEqual(Progression.nextTime(s, target: incline, kind: .weight, nextStep: nil), "All sets at 10. Next time 28 kg")
    }

    func test_rirBelowTargetHolds() {
        let s = suggest(done(26, [10, 10, 10], rir: [1, 2, 0]), incline, .weight, step: 2)
        XCTAssertEqual(s.kg, 26)
        XCTAssertEqual(s.values, [10, 10, 10])
        XCTAssertFalse(s.increased)
        XCTAssertFalse(s.topReached)
        XCTAssertNil(Progression.nextTime(s, target: incline, kind: .weight, nextStep: nil))
    }

    func test_noRirCountsAsPlanned() {
        let s = suggest(done(26, [10, 10, 10]), incline, .weight, step: 2)
        XCTAssertTrue(s.increased)
        XCTAssertEqual(s.kg, 28)
    }

    func test_stepPerEquipment() {
        func step(_ id: String, _ settings: WorkoutSettings = WorkoutSettings()) throws -> Double {
            Progression.step(try XCTUnwrap(WorkoutProgram.exercise(id, in: WorkoutProgram.exercises), id), settings: settings)
        }
        XCTAssertEqual(try step("incline-db-press"), 2)
        XCTAssertEqual(try step("lat-pulldown"), 2.5)
        XCTAssertEqual(try step("leg-press"), 2.5)
        XCTAssertEqual(try step("barbell-reverse-curl"), 2.5)
        XCTAssertEqual(try step("weighted-dip"), 2.5)

        var fine = WorkoutSettings()
        fine.steps["weighted"] = 1.25
        XCTAssertEqual(try step("weighted-dip", fine), 1.25)
        XCTAssertEqual(try step("assisted-pull-up", fine), 1.25)

        XCTAssertEqual(Progression.step(Exercise(id: "x", name: "X", equipment: .dumbbell, step: 1), settings: WorkoutSettings()), 1)

        var light = WorkoutSettings()
        light.steps["dumbbell"] = 1
        XCTAssertEqual(try step("incline-db-press", light), 1)
    }

    func test_onePlusOneRep() {
        let a = suggest(done(55, [12, 11, 11]), pulldown, .weight)
        XCTAssertEqual(a.kg, 55)
        XCTAssertEqual(a.values, [12, 12, 12])
        XCTAssertFalse(a.increased)
        let b = suggest(done(55, [9, 8, 8]), pulldown, .weight)
        XCTAssertEqual(b.kg, 55)
        XCTAssertEqual(b.values, [10, 9, 9])
    }

    func test_morePlannedSetsThanLast() {
        XCTAssertEqual(suggest(done(55, [10, 9]), pulldown, .weight).values, [11, 10, 10])
    }

    func test_dropSetsDontSetTheWeight() {
        let s = suggest(done(55, [10]) + done(40, [10], kind: .drop), pulldown, .weight)
        XCTAssertEqual(s.kg, 55)
        XCTAssertEqual(s.values, [11, 11, 11])
    }

    func test_noHistory() {
        let s = suggest([], incline, .weight)
        XCTAssertNil(s.kg)
        XCTAssertEqual(s.values, [6, 6, 6])
        XCTAssertFalse(s.topReached)
        XCTAssertFalse(s.increased)
    }

    func test_ladderMoveUp() {
        let tuck = Target(sets: 3, lo: 5, hi: 5, rest: 120)
        let s = suggest(done(nil, [5, 5, 5]), tuck, .bodyweight, ladder: (rule: .standard, isLast: false))
        XCTAssertTrue(s.moveUp)
        XCTAssertFalse(s.increased)
        XCTAssertEqual(s.values, [5, 5, 5])
        XCTAssertEqual(Progression.nextTime(s, target: tuck, kind: .bodyweight, nextStep: "tuck reps"), "Ready for tuck reps? Move up")
    }

    func test_lastStepAddsWeight() {
        let t = Target(sets: 3, lo: 5, hi: 8, rirLo: 1, rirHi: 2, rest: 150)
        let s = suggest(done(10, [8, 8, 8]), t, .weighted, step: 2.5, ladder: (rule: .standard, isLast: true))
        XCTAssertEqual(s.kg, 12.5)
        XCTAssertEqual(s.values, [5, 5, 5])
        XCTAssertTrue(s.increased)
        XCTAssertFalse(s.moveUp)
        XCTAssertEqual(Progression.nextTime(s, target: t, kind: .weighted, nextStep: nil), "All sets at 8. Next time +12.5 kg")
    }

    func test_pullUpToWeighted() {
        let t = Target(sets: 3, lo: 5, hi: 10, rirLo: 1, rirHi: 2, rest: 150)
        func up(_ reps: [Int], rir: [Int?] = []) -> Bool {
            suggest(done(nil, reps, rir: rir), t, .bodyweight, ladder: (rule: .pullUpToWeighted, isLast: false)).moveUp
        }
        XCTAssertTrue(up([12, 8, 7]))
        XCTAssertFalse(up([10, 10, 10], rir: [1, 1, 1]))
        XCTAssertTrue(up([10, 10, 10], rir: [2, 2, 3]))
        XCTAssertTrue(up([10, 10, 10]))
        XCTAssertFalse(up([10, 10, 9]))
        XCTAssertTrue(Progression.topReached(done(nil, [12, 8, 7]), t, kind: .bodyweight, rule: .pullUpToWeighted))
        XCTAssertFalse(Progression.topReached(done(nil, [12, 8, 7]), t, kind: .bodyweight))
    }

    func test_assistedLessHelp() {
        let t = Target(sets: 3, lo: 5, hi: 10, rest: 150)
        let s = suggest(done(20, [10, 10, 10]), t, .assisted, step: 2.5)
        XCTAssertEqual(s.kg, 17.5)
        XCTAssertEqual(s.values, [5, 5, 5])
        XCTAssertTrue(s.increased)
        XCTAssertEqual(Progression.nextTime(s, target: t, kind: .assisted, nextStep: nil), "All sets at 10. Next time \u{2212}17.5 kg")
    }

    func test_deloadHolds() {
        let s = suggest(done(26, [10, 10, 9]), incline, .weight, step: 2, deload: true)
        XCTAssertEqual(s, Suggestion(kg: 26, values: [10, 10, 9], topReached: false, moveUp: false, increased: false))
        let top = suggest(done(26, [10, 10, 10]), incline, .weight, step: 2, deload: true)
        XCTAssertEqual(top, Suggestion(kg: 26, values: [10, 10, 10], topReached: false, moveUp: false, increased: false))
        XCTAssertNil(Progression.nextTime(top, target: incline, kind: .weight, nextStep: nil))
    }

    func test_holdsAddFiveSeconds() {
        let t = Target(sets: 3, lo: 20, hi: 40, rest: 120)
        let s = suggest(holds([30, 30, 25]), t, .time)
        XCTAssertEqual(s.values, [35, 35, 30])
        XCTAssertNil(s.kg)
        XCTAssertFalse(s.topReached)
        XCTAssertTrue(Progression.topReached(holds([40, 40, 40]), t, kind: .time))
        let top = suggest(holds([40, 40, 40]), t, .time)
        XCTAssertTrue(top.topReached)
        XCTAssertFalse(top.increased)
        XCTAssertEqual(top.values, [40, 40, 40])
    }

    // MARK: - Ladders

    func test_ladderSteps() throws {
        let dragon = try XCTUnwrap(WorkoutProgram.ladders.first { $0.id == "dragon-flag-ladder" })
        var state = WorkoutState()
        XCTAssertEqual(Ladders.current(dragon, state: state), 1)
        XCTAssertEqual(Ladders.title(dragon, step: 1), "Dragon flag · tuck negatives (2 of 7)")
        Ladders.moveUp(dragon, state: &state)
        XCTAssertEqual(Ladders.current(dragon, state: state), 2)

        state.ladderSteps[dragon.id] = 6
        Ladders.moveUp(dragon, state: &state)
        XCTAssertEqual(Ladders.current(dragon, state: state), 6)

        state.ladderSteps[dragon.id] = 0
        Ladders.stepBack(dragon, state: &state)
        XCTAssertEqual(Ladders.current(dragon, state: state), 0)

        state.ladderSteps[dragon.id] = 99
        XCTAssertEqual(Ladders.current(dragon, state: state), 6)
    }

    // MARK: - Deload

    func test_deloadSets() {
        XCTAssertEqual([4, 3, 2, 1, 6].map(Deload.sets), [3, 2, 1, 1, 4])
    }

    func test_flagged() {
        func flagged(_ values: [Double]) -> Bool {
            Deload.flagged(values.enumerated().map { SessionBest(day: String(format: "2026-11-%02d", $0.offset + 1), value: $0.element) })
        }
        XCTAssertTrue(flagged([100, 98, 95]))
        XCTAssertFalse(flagged([100, 98, 98]))
        XCTAssertFalse(flagged([100, 95]))
        XCTAssertTrue(flagged([90, 100, 98, 95]))
        XCTAssertFalse(flagged([100, 95, 97]))
    }

    func test_sessionBestDecodesTolerantly() throws {
        let b = try JSONDecoder().decode(SessionBest.self, from: Data(#"{"value":95}"#.utf8))
        XCTAssertEqual(b, SessionBest(day: "", value: 95))
    }

    func test_lineFlags() {
        let line = Deload.line(flagNames: ["Pull-up", "Seated row"], state: DeloadState(), firstAppDay: nil, today: "2026-11-12")
        XCTAssertEqual(line, .flags(["Pull-up", "Seated row"]))
        XCTAssertEqual(line.map(Deload.text), "Reps fell two sessions running on Pull-up and Seated row. Deload this cycle?")
        XCTAssertNil(Deload.line(flagNames: ["Pull-up"], state: DeloadState(), firstAppDay: nil, today: "2026-11-12"))
    }

    func test_linePlanned() {
        let s = DeloadState(lastDay: "2026-10-01")
        let line = Deload.line(flagNames: [], state: s, firstAppDay: nil, today: "2026-11-12")
        XCTAssertEqual(line, .planned(weeks: 6))
        XCTAssertEqual(line.map(Deload.text), "Week 6 since your last deload. Take one this cycle?")
        XCTAssertNil(Deload.line(flagNames: [], state: s, firstAppDay: nil, today: "2026-11-11"))
    }

    func test_notYetHidesAWeek() {
        var s = DeloadState(lastDay: "2026-10-01")
        Deload.snooze(&s, today: "2026-11-12")
        XCTAssertEqual(s.snoozedUntil, "2026-11-19")
        XCTAssertNil(Deload.line(flagNames: [], state: s, firstAppDay: nil, today: "2026-11-18"))
        XCTAssertNil(Deload.line(flagNames: ["Pull-up", "Seated row"], state: s, firstAppDay: nil, today: "2026-11-18"))
        XCTAssertEqual(Deload.line(flagNames: [], state: s, firstAppDay: nil, today: "2026-11-19"), .planned(weeks: 7))
    }

    func test_clockNotFromImport() {
        XCTAssertNil(Deload.line(flagNames: [], state: DeloadState(), firstAppDay: nil, today: "2027-06-01"))
        XCTAssertEqual(Deload.line(flagNames: [], state: DeloadState(), firstAppDay: "2026-10-01", today: "2026-11-12"),
                       .planned(weeks: 6))
    }

    func test_activeHidesLine() {
        var s = DeloadState(lastDay: "2026-10-01")
        s.active = true
        XCTAssertNil(Deload.line(flagNames: ["Pull-up", "Seated row"], state: s, firstAppDay: nil, today: "2026-11-12"))
    }

    func test_cycleEnds() {
        var s = DeloadState(lastDay: "2026-10-01", snoozedUntil: "2026-11-19")
        Deload.start(&s)
        XCTAssertTrue(s.active)
        XCTAssertEqual(s.left, ["push", "pull"])

        Deload.finished(&s, routineIds: ["push"], day: "2026-11-12")
        XCTAssertTrue(s.active)
        XCTAssertEqual(s.left, ["pull"])

        Deload.finished(&s, routineIds: ["pull", "legs"], day: "2026-11-14")
        XCTAssertFalse(s.active)
        XCTAssertEqual(s.lastDay, "2026-11-14")
        XCTAssertEqual(s.left, [])
        XCTAssertNil(s.snoozedUntil)

        // Without a deload running, a finished workout changes nothing.
        Deload.finished(&s, routineIds: ["push"], day: "2026-11-16")
        XCTAssertEqual(s, DeloadState(lastDay: "2026-11-14"))
    }
}
