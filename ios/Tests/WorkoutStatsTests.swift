import XCTest

final class WorkoutStatsTests: XCTestCase {
    private let lib = WorkoutProgram.exercises
    /// 15 Nov 2026, 12:00 UTC. Never the real clock.
    private let t0 = Date(timeIntervalSince1970: 1_794_744_000)

    private func kind(_ id: String) throws -> ExerciseKind {
        try XCTUnwrap(WorkoutProgram.exercise(id, in: lib), id).kind
    }

    /// "2026-11-12 18:00" in the zone the app's 04:00 day is counted in (`RecompCalendar.calendar`), so a workout's
    /// `day` is the intended one wherever the tests run.
    private func local(_ text: String) -> Date {
        let p = text.split { $0 == "-" || $0 == " " || $0 == ":" }.compactMap { Int($0) }
        return RecompCalendar.calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: p[3], minute: p[4]))!
    }

    private func done(_ kg: Double?, _ reps: [Int], kind: SetKind = .normal) -> [LoggedSet] {
        reps.map { LoggedSet(kind: kind, kg: kg, reps: $0, done: true) }
    }

    private func workout(_ at: String, ids: [String] = [], deload: Bool = false, bodyWeight: Double? = nil,
                         _ exercises: [LoggedExercise]) -> Workout {
        Workout(title: ids.first ?? "Workout", routineIds: ids, start: local(at), bodyWeight: bodyWeight, deload: deload,
                exercises: exercises)
    }

    // MARK: - Loads

    func test_load() {
        XCTAssertEqual(Lifts.load(LoggedSet(kg: 26, reps: 10), .weight, bodyWeight: nil), 26)
        XCTAssertEqual(Lifts.load(LoggedSet(kg: 10, reps: 8), .weighted, bodyWeight: 88), 98)
        XCTAssertEqual(Lifts.load(LoggedSet(reps: 8), .weighted, bodyWeight: 88), 88)
        XCTAssertEqual(Lifts.load(LoggedSet(kg: 20, reps: 8), .assisted, bodyWeight: 88), 68)
        XCTAssertEqual(Lifts.load(LoggedSet(reps: 8), .bodyweight, bodyWeight: 88), 88)
        XCTAssertNil(Lifts.load(LoggedSet(reps: 8), .bodyweight, bodyWeight: nil))
        XCTAssertNil(Lifts.load(LoggedSet(kg: 10, reps: 8), .weighted, bodyWeight: nil))
        XCTAssertNil(Lifts.load(LoggedSet(seconds: 30), .time, bodyWeight: 88))
        XCTAssertNil(Lifts.load(LoggedSet(seconds: 1200, km: 3), .cardio, bodyWeight: 88))
    }

    func test_e1rm() {
        XCTAssertEqual(Lifts.e1rm(load: 100, reps: 1), 100)
        XCTAssertEqual(Lifts.e1rm(load: 100, reps: 10), 133.33, accuracy: 0.01)
    }

    func test_volumeAndSessionBest() throws {
        let sets = done(26, [10, 10, 10]) + done(14, [8], kind: .warmup)
        XCTAssertEqual(Lifts.volume(sets, .weight), 780)
        // Weighted counts only the extra weight; assisted and bodyweight have no volume.
        XCTAssertEqual(Lifts.volume(done(10, [8]), .weighted), 80)
        XCTAssertEqual(Lifts.volume(done(20, [8]), .assisted), 0)
        XCTAssertEqual(Lifts.volume(done(nil, [8]), .bodyweight), 0)
        // An undone set doesn't count.
        XCTAssertEqual(Lifts.volume([LoggedSet(kg: 26, reps: 10)], .weight), 0)

        XCTAssertEqual(try XCTUnwrap(Lifts.sessionBest(sets + done(30, [3]), .weight, bodyWeight: nil)), 34.67, accuracy: 0.01)
        XCTAssertEqual(Lifts.sessionBest(done(nil, [9, 12, 8]), .bodyweight, bodyWeight: 88), 12)
        // A weighted set without a body weight falls back to reps.
        XCTAssertEqual(Lifts.sessionBest(done(10, [8, 7]), .weighted, bodyWeight: nil), 8)
        XCTAssertEqual(Lifts.sessionBest([LoggedSet(seconds: 30, done: true), LoggedSet(seconds: 40, done: true)], .time,
                                         bodyWeight: nil), 40)
        XCTAssertNil(Lifts.sessionBest(done(26, [10], kind: .warmup), .weight, bodyWeight: nil))
    }

    func test_bodyWeight() throws {
        let w = [Measure(day: "2026-11-10", value: 88.0), Measure(day: "2026-11-12", value: 87.6)]
        XCTAssertEqual(try XCTUnwrap(Lifts.bodyWeight(on: "2026-11-12", weights: w)), 87.8, accuracy: 1e-9)
        XCTAssertEqual(Lifts.bodyWeight(on: "2026-12-30", weights: w), 87.6)
        XCTAssertEqual(Lifts.bodyWeight(on: "2026-11-01", weights: w), 88.0)
        XCTAssertNil(Lifts.bodyWeight(on: "2026-11-12", weights: []))
        // Ten days either way: the earlier one.
        let apart = [Measure(day: "2026-11-21", value: 87.0), Measure(day: "2026-11-01", value: 89.0)]
        XCTAssertEqual(Lifts.bodyWeight(on: "2026-11-11", weights: apart), 89.0)
    }

    // MARK: - Records

    func test_recordsIgnoreWarmups() throws {
        var r = Records()
        let sets = [LoggedSet(kind: .warmup, kg: 30, reps: 10, done: true), LoggedSet(kg: 26, reps: 10, done: true),
                    LoggedSet(kg: 40, reps: 10, done: false)]
        for s in sets { r.add(s, .weight, bodyWeight: nil) }
        XCTAssertEqual(r.heaviest, 26)
        XCTAssertEqual(try XCTUnwrap(r.e1rm), 34.67, accuracy: 0.01)
        XCTAssertEqual(r.bestSet, 260)
        XCTAssertEqual(r.mostReps, 10)
        XCTAssertEqual(r.byReps, ["10": 26])
    }

    func test_recordsWithBodyWeight() throws {
        var r = Records()
        r.add(LoggedSet(kg: 10, reps: 8, done: true), try kind("weighted-pull-up"), bodyWeight: 88)
        XCTAssertEqual(r.heaviest, 98)
        XCTAssertEqual(try XCTUnwrap(r.e1rm), 124.13, accuracy: 0.01)
        XCTAssertEqual(r.bestSet, 80)
        XCTAssertEqual(r.byReps, ["8": 98])
    }

    func test_beaten() {
        var r = Records()
        r.add(LoggedSet(kg: 26, reps: 10, done: true), .weight, bodyWeight: nil)
        XCTAssertTrue(r.beaten(by: LoggedSet(kg: 28, reps: 8, done: true), .weight, bodyWeight: nil))
        XCTAssertFalse(r.beaten(by: LoggedSet(kg: 26, reps: 9, done: true), .weight, bodyWeight: nil))
        XCTAssertFalse(r.beaten(by: LoggedSet(kg: 26, reps: 10, done: true), .weight, bodyWeight: nil))
        // Heavier with a lower e1RM is still a best.
        XCTAssertTrue(r.beaten(by: LoggedSet(kg: 30, reps: 3, done: true), .weight, bodyWeight: nil))
        // A warm-up is never a best.
        XCTAssertFalse(r.beaten(by: LoggedSet(kind: .warmup, kg: 40, reps: 10, done: true), .weight, bodyWeight: nil))

        XCTAssertFalse(Records().beaten(by: LoggedSet(kg: 26, reps: 10, done: true), .weight, bodyWeight: nil))

        let bodyweight = Records(mostReps: 12)
        XCTAssertTrue(bodyweight.beaten(by: LoggedSet(reps: 13, done: true), .bodyweight, bodyWeight: nil))
        XCTAssertFalse(bodyweight.beaten(by: LoggedSet(reps: 12, done: true), .bodyweight, bodyWeight: nil))

        // .weight stays exact: a quarter kilo more is a best.
        XCTAssertTrue(r.beaten(by: LoggedSet(kg: 26.25, reps: 10, done: true), .weight, bodyWeight: nil))

        let hold = Records(longest: 30)
        XCTAssertTrue(hold.beaten(by: LoggedSet(seconds: 35, done: true), .time, bodyWeight: nil))
        XCTAssertFalse(hold.beaten(by: LoggedSet(seconds: 30, done: true), .time, bodyWeight: nil))
    }

    func test_bodyWeightDriftIsNoBest() throws {
        let weighted = try kind("weighted-pull-up")
        var r = Records()
        r.add(LoggedSet(kg: 10, reps: 8, done: true), weighted, bodyWeight: 88)
        // The same +10 × 8 at a 0.2 kg heavier body weight is not a best; one more rep is.
        XCTAssertFalse(r.beaten(by: LoggedSet(kg: 10, reps: 8, done: true), weighted, bodyWeight: 88.2))
        XCTAssertTrue(r.beaten(by: LoggedSet(kg: 10, reps: 9, done: true), weighted, bodyWeight: 88.2))
        // 2.5 kg more extra weight is.
        XCTAssertTrue(r.beaten(by: LoggedSet(kg: 12.5, reps: 8, done: true), weighted, bodyWeight: 88))
        // The record itself still keeps the higher number.
        r.add(LoggedSet(kg: 10, reps: 8, done: true), weighted, bodyWeight: 88.2)
        XCTAssertEqual(r.heaviest, 98.2)

        let assisted = try kind("assisted-pull-up")
        var help = Records()
        help.add(LoggedSet(kg: 20, reps: 8, done: true), assisted, bodyWeight: 88)
        XCTAssertFalse(help.beaten(by: LoggedSet(kg: 20, reps: 8, done: true), assisted, bodyWeight: 88.2))
        XCTAssertTrue(help.beaten(by: LoggedSet(kg: 17.5, reps: 8, done: true), assisted, bodyWeight: 88))
    }

    func test_bodyWeightDriftIsNoFall() throws {
        // +10 × 8 three times while the week average drops 88.0 → 87.8 → 87.6: no deload flag.
        func pulls(_ reps: [Int], _ weights: [Double]) -> [Workout] {
            zip(reps, weights).enumerated().map { i, p in
                workout(String(format: "2026-11-%02d 18:00", 3 + 3 * i), ids: ["pull"], bodyWeight: p.1,
                        [LoggedExercise(exerciseId: "weighted-pull-up", routineId: "pull", sets: done(10, [p.0, p.0]))])
            }
        }
        let drift = WorkoutIndex.build(pulls([8, 8, 8], [88.0, 87.8, 87.6]), library: lib)
        let recent = try XCTUnwrap(drift.exercises["weighted-pull-up"]?.recent)
        XCTAssertEqual(recent.count, 3)
        XCTAssertFalse(Deload.flagged(recent))
        // A rep less each time is a real fall.
        let falling = WorkoutIndex.build(pulls([8, 7, 6], [88.0, 87.8, 87.6]), library: lib)
        XCTAssertTrue(Deload.flagged(try XCTUnwrap(falling.exercises["weighted-pull-up"]?.recent)))
    }

    // MARK: - Sets per week

    func test_weeklySets21Days() {
        let incline = { (sets: [LoggedSet]) in LoggedExercise(exerciseId: "incline-db-press", sets: sets) }
        let warm = done(14, [8], kind: .warmup)
        let workouts = [
            workout("2026-10-26 18:00", [incline(warm + done(26, [10, 10, 9]))]),     // the window's first day
            workout("2026-11-08 18:00", [incline(warm + done(26, [10, 10, 10]))]),
            workout("2026-11-16 00:30", [incline(warm + done(28, [8, 8, 7]))]),       // after midnight: still 15 Nov
            workout("2026-10-25 18:00", [incline(done(26, [10, 9, 9]))]),             // outside
            workout("2026-10-26 02:00", [incline(done(26, [10, 9, 9]))]),             // after midnight: still 25 Oct, outside
        ]
        let c = WeeklySets.count(workouts, library: lib, today: "2026-11-15")
        XCTAssertEqual(c[.muscle(.chest)], RowCount(direct: 3, indirect: 0))
        XCTAssertEqual(c[.muscle(.triceps)], RowCount(direct: 0, indirect: 1.5))
        XCTAssertEqual(c[.muscle(.frontDelts)], RowCount(direct: 0, indirect: 1.5))
        XCTAssertEqual(c[.muscle(.lats)], RowCount(direct: 0, indirect: 0))
        XCTAssertEqual(c.count, SetRow.main.count + SetRow.more.count)
    }

    func test_weeklyLegsRow() {
        let w = [workout("2026-11-12 18:00", ids: ["pull", "legs"],
                         [LoggedExercise(exerciseId: "leg-press", sets: done(100, [12, 10, 10, 10, 9, 8]))])]
        let c = WeeklySets.count(w, library: lib, today: "2026-11-15")
        XCTAssertEqual(c[.legs], RowCount(direct: 2, indirect: 0))
        XCTAssertEqual(c[.muscle(.quads)], RowCount(direct: 2, indirect: 0))
        XCTAssertEqual(c[.muscle(.glutes)], RowCount(direct: 2, indirect: 0))
        XCTAssertEqual(c[.muscle(.hamstrings)], RowCount(direct: 0, indirect: 0))
    }

    func test_noMusclesCountsNowhere() {
        let w = [workout("2026-11-12 18:00", [LoggedExercise(exerciseId: "cat-girl", sets: done(10, [10, 10, 10, 10, 10, 10])),
                                              LoggedExercise(exerciseId: "not-in-the-library", sets: done(10, [10, 10]))])]
        let c = WeeklySets.count(w, library: lib, today: "2026-11-15")
        XCTAssertFalse(c.values.contains { $0.direct > 0 || $0.indirect > 0 })
    }

    func test_targetsFromProgram() throws {
        let t = WeeklySets.targets(WorkoutProgram.routines, ladders: WorkoutProgram.ladders, state: WorkoutState(), library: lib)
        XCTAssertEqual(t[.muscle(.sideDelts)], 16)
        XCTAssertEqual(t[.muscle(.lats)], 21)
        XCTAssertEqual(t[.muscle(.chest)], 19)
        XCTAssertEqual(t[.muscle(.rearDelts)], 7)
        XCTAssertEqual(t[.muscle(.triceps)], 7)
        XCTAssertEqual(t[.muscle(.biceps)], 12)
        XCTAssertEqual(t[.legs], 9)
        // The ladders by their current step: the dragon flag on Push and Pull.
        XCTAssertEqual(t[.muscle(.core)], 14)
        // Rows that come to 0 are left out.
        XCTAssertNil(t[.muscle(.forearms)])

        var routines = WorkoutProgram.routines
        let push = try XCTUnwrap(routines.firstIndex { $0.id == "push" })
        let raise = try XCTUnwrap(routines[push].items.firstIndex { $0.exerciseId == "single-arm-cable-lateral-raise" })
        routines[push].items[raise].target.sets = 5
        let more = WeeklySets.targets(routines, ladders: WorkoutProgram.ladders, state: WorkoutState(), library: lib)
        XCTAssertEqual(more[.muscle(.sideDelts)], 19)

        XCTAssertEqual(WeeklySets.priority, [.muscle(.sideDelts), .muscle(.lats)])
        XCTAssertEqual(WeeklySets.priorityFloor, 12)
    }

    // MARK: - Warm-ups and plates

    func test_warmup() {
        let incline = Warmup.sets([WarmupRamp(percent: 0.5, reps: 8), WarmupRamp(percent: 0.75, reps: 4)], workKg: 26, step: 2)
        XCTAssertEqual(incline.map(\.kg), [12, 18])
        XCTAssertEqual(incline.map(\.reps), [8, 4])
        XCTAssertTrue(incline.allSatisfy { $0.kind == .warmup && !$0.done })

        let easy = Warmup.sets([WarmupRamp(percent: 0, reps: 5)], workKg: 10, step: 2.5)
        XCTAssertEqual(easy.map(\.kg), [nil])
        XCTAssertEqual(easy.map(\.reps), [5])

        XCTAssertEqual(Warmup.sets([WarmupRamp(percent: 0.5, reps: 10)], workKg: 100, step: 2.5).map(\.kg), [50])
        XCTAssertEqual(Warmup.sets([WarmupRamp(percent: 0.5, reps: 8)], workKg: 2, step: 2).map(\.kg), [2])
        XCTAssertEqual(Warmup.sets([WarmupRamp(percent: 0.6, reps: 5)], workKg: 50, step: 2.5).map(\.kg), [30])
        XCTAssertEqual(Warmup.sets([WarmupRamp(percent: 0.5, reps: 8)], workKg: nil, step: 2).map(\.kg), [nil])
    }

    func test_plates() {
        XCTAssertEqual(Plates.text(50), "20 + 2 × 15")
        XCTAssertEqual(Plates.text(72.5), "20 + 2 × (25 + 1.25)")
        XCTAssertEqual(Plates.text(100), "20 + 2 × (25 + 15)")
        XCTAssertEqual(Plates.text(120), "20 + 2 × (25 + 25)")
        XCTAssertEqual(Plates.text(20), "Bar only")
        XCTAssertNil(Plates.text(19))
        XCTAssertNil(Plates.text(21))
    }

    // MARK: - The index

    func test_indexIncrementalEqualsBuild() throws {
        let push = workout("2026-11-10 18:00", ids: ["push"], bodyWeight: 88, [
            LoggedExercise(exerciseId: "incline-db-press", routineId: "push",
                           sets: done(12, [8], kind: .warmup) + done(26, [10, 10, 9])),
        ])
        let pull = workout("2026-11-12 18:00", ids: ["pull"], bodyWeight: 88, [
            LoggedExercise(exerciseId: "lat-pulldown", routineId: "pull", sets: done(55, [12, 11, 10])),
            LoggedExercise(exerciseId: "pull-up", routineId: "pull", sets: done(nil, [9, 9, 8])),
        ])
        let deload = workout("2026-11-14 18:00", ids: ["push"], deload: true, bodyWeight: 87.6, [
            LoggedExercise(exerciseId: "incline-db-press", routineId: "push", sets: done(26, [10, 10])),
        ])

        var added = WorkoutIndex()
        for w in [push, pull, deload] { added.add(w, library: lib) }
        let built = WorkoutIndex.build([deload, push, pull], library: lib)
        XCTAssertEqual(built, added)
        XCTAssertEqual(built.workouts.map(\.id), [push.id, pull.id, deload.id])

        let incline = try XCTUnwrap(built.exercises["incline-db-press"])
        XCTAssertEqual(incline.recent.count, 1)
        XCTAssertEqual(incline.recent.first?.day, push.day)
        XCTAssertEqual(try XCTUnwrap(incline.recent.first?.value), 34.67, accuracy: 0.01)
        XCTAssertEqual(incline.last?.workoutId, deload.id)
        XCTAssertEqual(incline.lastByRoutine["push"]?.workoutId, deload.id)
        XCTAssertEqual(incline.sessions, 2)
        XCTAssertEqual(incline.records.heaviest, 26)
        XCTAssertEqual(incline.lastNormal?.workoutId, push.id)
        XCTAssertEqual(incline.lastNormalByRoutine["push"]?.workoutId, push.id)
        XCTAssertEqual(built.exercises["pull-up"]?.recent.map(\.value), [9])

        // It survives the file, and an empty file is an empty index.
        let data = try JSONEncoder().encode(built)
        XCTAssertEqual(try JSONDecoder().decode(WorkoutIndex.self, from: data), built)
        XCTAssertEqual(try JSONDecoder().decode(WorkoutIndex.self, from: Data("{}".utf8)), WorkoutIndex())
    }

    func test_previousPrefersSameRoutine() throws {
        let pullSets = done(30, [10], kind: .warmup) + done(55, [12, 11])
        let pull = workout("2026-11-10 18:00", ids: ["pull"], [
            LoggedExercise(exerciseId: "lat-pulldown", routineId: "pull", sets: pullSets),
        ])
        let anySets = done(50, [10])
        let empty = workout("2026-11-12 18:00", [LoggedExercise(exerciseId: "lat-pulldown", sets: anySets)])
        let e = WorkoutIndex.build([pull, empty], library: lib).exercises["lat-pulldown"]

        XCTAssertEqual(Previous.sets(e, routineId: "pull"), pullSets)
        XCTAssertEqual(Previous.sets(e, routineId: nil), anySets)
        XCTAssertEqual(Previous.sets(e, routineId: "push"), anySets)
        XCTAssertEqual(Previous.sets(nil, routineId: "pull"), [])

        let previous = Previous.sets(e, routineId: "pull")
        XCTAssertEqual(Previous.row(previous, warmup: false, number: 0), pullSets[1])
        XCTAssertEqual(Previous.row(previous, warmup: false, number: 1), pullSets[2])
        XCTAssertEqual(Previous.row(previous, warmup: true, number: 0), pullSets[0])
        XCTAssertNil(Previous.row(previous, warmup: false, number: 2))
        XCTAssertNil(Previous.row(previous, warmup: true, number: 1))
    }

    func test_previousSkipsDeload() {
        let full = done(26, [10, 10, 9])
        let push = workout("2026-11-10 18:00", ids: ["push"], [
            LoggedExercise(exerciseId: "incline-db-press", routineId: "push", sets: full),
        ])
        let light = done(26, [10, 10])
        let deload = workout("2026-11-14 18:00", ids: ["push"], deload: true, [
            LoggedExercise(exerciseId: "incline-db-press", routineId: "push", sets: light),
        ])
        var added = WorkoutIndex()
        for w in [push, deload] { added.add(w, library: lib) }
        XCTAssertEqual(WorkoutIndex.build([deload, push], library: lib), added)

        let e = added.exercises["incline-db-press"]
        XCTAssertEqual(Previous.sets(e, routineId: "push"), full)
        XCTAssertEqual(Previous.sets(e, routineId: nil), full)
        // With only a deload, that is the last time.
        let only = WorkoutIndex.build([deload], library: lib).exercises["incline-db-press"]
        XCTAssertEqual(Previous.sets(only, routineId: "push"), light)
        XCTAssertEqual(Previous.sets(only, routineId: nil), light)
    }

    // MARK: - Chart series

    func test_series() throws {
        let day: TimeInterval = 86_400
        let sets = { self.done(26, [10, 10, 10]) }
        let old = Workout(title: "Push", start: t0.addingTimeInterval(-100 * day),
                          exercises: [LoggedExercise(exerciseId: "incline-db-press", sets: sets())])
        let newer = Workout(title: "Push", start: t0.addingTimeInterval(-60 * day),
                            exercises: [LoggedExercise(exerciseId: "incline-db-press", sets: sets())])
        let other = Workout(title: "Pull", start: t0.addingTimeInterval(-30 * day),
                            exercises: [LoggedExercise(exerciseId: "lat-pulldown", sets: done(55, [12]))])
        let warmOnly = Workout(title: "Push", start: t0.addingTimeInterval(-20 * day),
                               exercises: [LoggedExercise(exerciseId: "incline-db-press", sets: done(12, [8], kind: .warmup))])
        let sessions = Series.sessions([newer, other, warmOnly, old], exerciseId: "incline-db-press")
        XCTAssertEqual(sessions.map(\.start), [old.start, newer.start])

        let incline = try kind("incline-db-press")
        func points(_ m: ChartMetric, _ p: ChartPeriod) -> [ChartPoint] {
            Series.points(sessions, kind: incline, metric: m, period: p, now: t0)
        }
        XCTAssertEqual(points(.volume, .threeMonths).map(\.date), [newer.start])
        XCTAssertEqual(points(.volume, .year).count, 2)
        XCTAssertEqual(points(.volume, .all).count, 2)
        XCTAssertEqual(points(.volume, .all).map(\.value), [780, 780])
        XCTAssertEqual(points(.heaviest, .all).map(\.value), [26, 26])
        XCTAssertEqual(points(.reps, .all).map(\.value), [10, 10])
        XCTAssertEqual(try XCTUnwrap(points(.e1rm, .all).first?.value), 34.67, accuracy: 0.01)

        // A hold: Reps is the longest hold in seconds; it has no load.
        let holds = [30, 40, 35].map { LoggedSet(seconds: $0, done: true) }
        let hollow = [Workout(title: "Push", start: t0.addingTimeInterval(-10 * day),
                              exercises: [LoggedExercise(exerciseId: "hollow-body-hold", sets: holds)]),
                      Workout(title: "Push", start: t0.addingTimeInterval(-5 * day),
                              exercises: [LoggedExercise(exerciseId: "hollow-body-hold",
                                                         sets: [LoggedSet(seconds: 45, done: true)])])]
        let holdSessions = Series.sessions(hollow, exerciseId: "hollow-body-hold")
        let time = try kind("hollow-body-hold")
        XCTAssertEqual(Series.points(holdSessions, kind: time, metric: .reps, period: .threeMonths, now: t0).map(\.value), [40, 45])
        XCTAssertEqual(Series.points(holdSessions, kind: time, metric: .heaviest, period: .all, now: t0), [])

        XCTAssertEqual(ChartMetric.allCases.map(\.title), ["Heaviest", "e1RM", "Volume", "Reps"])
        XCTAssertEqual(ChartPeriod.allCases.map(\.title), ["3 months", "1 year", "All"])
    }
}
