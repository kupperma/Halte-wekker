import XCTest

final class WorkoutSessionTests: XCTestCase {
    private let lib = WorkoutProgram.exercises
    private let ladders = WorkoutProgram.ladders
    /// 15 Nov 2026, 12:00 UTC. Never the real clock.
    private let t0 = Date(timeIntervalSince1970: 1_794_744_000)

    private func input(index: WorkoutIndex = WorkoutIndex(), state: WorkoutState = WorkoutState(),
                       today: DayKey = "2026-11-15") -> PlanInput {
        PlanInput(routines: WorkoutProgram.routines, library: lib, ladders: ladders, state: state, index: index,
                  today: today, now: t0, bodyWeight: 88)
    }

    private func done(_ kg: Double?, _ reps: [Int]) -> [LoggedSet] {
        reps.map { LoggedSet(kg: kg, reps: $0, done: true) }
    }

    /// An index with one earlier workout holding these sets of one exercise.
    private func history(_ id: String, routine: String, _ sets: [LoggedSet], daysAgo: Double = 3) -> WorkoutIndex {
        let w = Workout(title: routine, routineIds: [routine], start: t0.addingTimeInterval(-daysAgo * 86_400),
                        exercises: [LoggedExercise(exerciseId: id, routineId: routine, sets: sets)])
        return WorkoutIndex.build([w], library: lib)
    }

    private func at(_ a: ActiveWorkout, _ id: String) throws -> Int {
        try XCTUnwrap(a.workout.exercises.firstIndex { $0.exerciseId == id }, id)
    }

    private func workSets(_ e: LoggedExercise) -> [LoggedSet] { e.sets.filter { $0.kind != .warmup } }
    private func warmups(_ e: LoggedExercise) -> [LoggedSet] { e.sets.filter { $0.kind == .warmup } }

    /// Marks every set before `c` in the set order done, without rest or records.
    private func doneBefore(_ a: inout ActiveWorkout, _ c: SessionCursor) {
        for x in Session.order(a.workout) {
            if x == c { return }
            a.workout.exercises[x.exercise].sets[x.set].done = true
        }
    }

    private func doneAll(_ a: inout ActiveWorkout) {
        for x in Session.order(a.workout) { a.workout.exercises[x.exercise].sets[x.set].done = true }
    }

    @discardableResult
    private func complete(_ a: inout ActiveWorkout, _ c: SessionCursor, kg: Double? = nil, reps: Int? = nil,
                          index: WorkoutIndex = WorkoutIndex(), at now: Date? = nil) -> SetOutcome {
        Session.complete(&a, c, kg: kg, reps: reps, seconds: nil, index: index, library: lib, now: now ?? t0)
    }

    private func target(_ routine: String, _ id: String) throws -> Target {
        let r = try XCTUnwrap(WorkoutProgram.routines.first { $0.id == routine })
        return try XCTUnwrap(r.items.first { $0.exerciseId == id }, id).target
    }

    /// The Pull + legs plan with lat pulldown prefilled 57.5 × 8, last time 55 × [12, 11, 11], and every set before
    /// its set 2 done.
    private func latPulldownSet2() throws -> (ActiveWorkout, Int) {
        var a = Session.plan(["pull", "legs"], input())
        let lat = try at(a, "lat-pulldown")
        for j in a.workout.exercises[lat].sets.indices {
            a.workout.exercises[lat].sets[j].kg = 57.5
            a.workout.exercises[lat].sets[j].reps = 8
        }
        a.previous[a.workout.exercises[lat].id.uuidString] = done(55, [12, 11, 11])
        doneBefore(&a, SessionCursor(exercise: lat, set: 1))
        return (a, lat)
    }

    // MARK: - Planning

    func test_planPullWithLegs() {
        let a = Session.plan(["pull", "legs"], input())
        let w = a.workout
        XCTAssertEqual(w.exercises.map(\.exerciseId), [
            "dragon-flag-tuck-negatives", "pull-up", "lat-pulldown", "seated-cable-row-v-grip",
            "single-arm-cable-lateral-raise", "rear-delt-fly-cable", "bayesian-curl", "leg-press", "romanian-deadlift-smith",
        ])
        XCTAssertEqual(w.exercises.reduce(0) { $0 + workSets($1).count }, 25)
        let ramps = w.exercises.flatMap { e in warmups(e).map { (e.exerciseId, $0.kg, $0.reps) } }
        XCTAssertEqual(ramps.map { $0.0 }, ["pull-up", "leg-press"])
        XCTAssertEqual(ramps.map { $0.1 }, [nil, nil])
        XCTAssertEqual(ramps.map { $0.2 }, [5, 10])
        // Warm-ups go in front, and nothing is done yet.
        XCTAssertEqual(w.exercises[1].sets.map(\.kind), [.warmup, .normal, .normal, .normal])
        XCTAssertFalse(w.exercises.flatMap(\.sets).contains(where: \.done))

        XCTAssertEqual(a.closed.map(\.exerciseId), ["hammer-curl-db", "lying-leg-curl"])
        XCTAssertEqual(a.closed.map(\.reason), ["Skipped on leg days", "Optional"])
        XCTAssertEqual(a.closed.map(\.routineId), ["pull", "legs"])

        XCTAssertEqual(w.title, "Pull + legs")
        XCTAssertEqual(w.routineIds, ["pull", "legs"])
        XCTAssertEqual(w.start, t0)
        XCTAssertEqual(w.bodyWeight, 88)
        XCTAssertFalse(w.deload)
        XCTAssertEqual(w.exercises.map(\.routineId), ["pull", "pull", "pull", "pull", "pull", "pull", "pull", "legs", "legs"])
        XCTAssertEqual(w.exercises[0].ladderId, "dragon-flag-ladder")
        XCTAssertEqual(w.exercises[1].ladderId, "pull-up-ladder")
        XCTAssertEqual(w.exercises[1].target?.rest, 150)
        XCTAssertEqual(w.exercises[4].superset, 1)
        XCTAssertEqual(w.exercises[5].superset, 1)
        XCTAssertEqual(Set(a.previous.keys), Set(w.exercises.map(\.id.uuidString)))

        XCTAssertEqual(Session.estimate(w), 70)
        XCTAssertEqual(Session.planLine(a), "9 exercises · 25 sets · about 70 min")
        XCTAssertEqual(Session.namesLine(a, library: lib, ladders: ladders),
                       "Dragon flag · Pull-up · Lat pulldown · Seated cable row (V-grip) · …")
        XCTAssertEqual(Session.namesLine(a, library: lib, ladders: ladders, max: 9).components(separatedBy: " · ").count, 9)
    }

    func test_legsAfterTwoWeeks() throws {
        var state = WorkoutState()
        state.firstLegsDay = "2026-11-01"
        let late = Session.plan(["pull", "legs"], input(state: state, today: "2026-11-15"))
        let latePress = late.workout.exercises[try at(late, "leg-press")]
        XCTAssertEqual(workSets(latePress).count, 3)
        let early = Session.plan(["pull", "legs"], input(state: state, today: "2026-11-14"))
        let earlyPress = early.workout.exercises[try at(early, "leg-press")]
        XCTAssertEqual(workSets(earlyPress).count, 2)
        XCTAssertEqual(earlyPress.target?.sets, 2)
        // Pull keeps its sets either way.
        let pulldown = early.workout.exercises[try at(early, "lat-pulldown")]
        XCTAssertEqual(workSets(pulldown).count, 3)
    }

    func test_planDeload() throws {
        var state = WorkoutState()
        Deload.start(&state.deload)
        let a = Session.plan(["push"], input(state: state))
        XCTAssertTrue(a.workout.deload)
        for (id, n) in [("incline-db-press", 2), ("single-arm-cable-lateral-raise", 3), ("flat-db-press", 1)] {
            let e = a.workout.exercises[try at(a, id)]
            XCTAssertEqual(workSets(e).count, n, id)
        }

        let index = history("incline-db-press", routine: "push", done(26, [10, 10, 9]))
        let b = Session.plan(["push"], input(index: index, state: state))
        let incline = workSets(b.workout.exercises[try at(b, "incline-db-press")])
        XCTAssertEqual(incline.map(\.kg), [26, 26])
        XCTAssertEqual(incline.map(\.reps), [10, 10])
        XCTAssertFalse(incline.contains(where: \.done))
    }

    func test_planPrefills() throws {
        let sets = done(26, [10, 10, 10])
        let a = Session.plan(["push"], input(index: history("incline-db-press", routine: "push", sets)))
        let e = a.workout.exercises[try at(a, "incline-db-press")]
        XCTAssertEqual(workSets(e).map(\.kg), [28, 28, 28])
        XCTAssertEqual(workSets(e).map(\.reps), [6, 6, 6])
        XCTAssertFalse(e.sets.contains(where: \.done))
        XCTAssertEqual(warmups(e).map(\.kg), [14, 20])
        XCTAssertEqual(warmups(e).map(\.reps), [8, 4])
        XCTAssertEqual(e.sets.prefix(2).map(\.kind), [.warmup, .warmup])
        XCTAssertEqual(a.previous[e.id.uuidString], sets)
    }

    func test_title() {
        let r = WorkoutProgram.routines
        XCTAssertEqual(Session.title([], routines: r), "Workout")
        XCTAssertEqual(Session.title(["push"], routines: r), "Push")
        XCTAssertEqual(Session.title(["pull", "legs"], routines: r), "Pull + legs")
        XCTAssertEqual(Session.title(["gone"], routines: r), "Workout")
    }

    func test_emptyWorkout() {
        let a = Session.plan([], input())
        XCTAssertEqual(a.workout.title, "Workout")
        XCTAssertTrue(a.workout.exercises.isEmpty)
        XCTAssertNil(Session.next(a))
        XCTAssertNil(Session.doneLabel(a, library: lib))
        XCTAssertTrue(Session.liveState(a, library: lib, now: t0).allDone)
        XCTAssertNil(Session.finished(a, end: t0, note: ""))
    }

    // MARK: - Order, supersets and rest

    func test_supersetOrder() throws {
        let a = Session.plan(["pull"], input())
        let ids = a.workout.exercises.map(\.exerciseId)
        XCTAssertEqual(ids[4], "single-arm-cable-lateral-raise")
        XCTAssertEqual(ids[5], "rear-delt-fly-cable")
        let pairs: [(Int, Int)] = [(0, 0), (0, 1), (0, 2), (1, 0), (1, 1), (1, 2), (1, 3), (2, 0), (2, 1), (2, 2),
                                   (3, 0), (3, 1), (3, 2), (4, 0), (5, 0), (4, 1), (5, 1), (4, 2), (5, 2),
                                   (6, 0), (6, 1), (6, 2), (7, 0), (7, 1)]
        XCTAssertEqual(Session.order(a.workout), pairs.map { SessionCursor(exercise: $0.0, set: $0.1) })

        // A superset number is unique in the workout: Pull's second here.
        let b = Session.plan(["push", "pull"], input())
        let supersets = b.workout.exercises.compactMap(\.superset)
        XCTAssertEqual(supersets, [101, 101])
    }

    func test_supersetRest() {
        var a = Session.plan(["pull"], input())
        let lateral1 = SessionCursor(exercise: 4, set: 0)
        doneBefore(&a, lateral1)
        let first = complete(&a, lateral1)
        XCTAssertNil(first.rest)
        XCTAssertNil(a.rest)
        XCTAssertEqual(Session.next(a), SessionCursor(exercise: 5, set: 0))

        let t = t0.addingTimeInterval(90)
        let second = complete(&a, SessionCursor(exercise: 5, set: 0), at: t)
        XCTAssertEqual(second.rest, RestState(started: t, ends: t.addingTimeInterval(75)))
        XCTAssertEqual(a.rest, second.rest)
        XCTAssertEqual(Session.next(a), SessionCursor(exercise: 4, set: 1))
    }

    func test_restAndNoneAtEnd() throws {
        var a = Session.plan(["pull"], input())
        let r = complete(&a, SessionCursor(exercise: 1, set: 1))
        XCTAssertEqual(r.rest, RestState(started: t0, ends: t0.addingTimeInterval(150)))
        XCTAssertEqual(a.rest, r.rest)

        var b = Session.plan(["pull"], input())
        let last = try XCTUnwrap(Session.order(b.workout).last)
        doneBefore(&b, last)
        XCTAssertNotNil(b.workout.exercises[last.exercise].target?.rest)
        let end = complete(&b, last)
        XCTAssertNil(end.rest)
        XCTAssertNil(b.rest)
    }

    func test_warmupRest() {
        var a = Session.plan(["pull"], input())
        XCTAssertEqual(a.workout.exercises[1].sets[0].kind, .warmup)
        let r = complete(&a, SessionCursor(exercise: 1, set: 0))
        XCTAssertEqual(r.rest, RestState(started: t0, ends: t0.addingTimeInterval(60)))
        XCTAssertNil(r.record)
    }

    func test_completeEndsRest() {
        var a = Session.plan(["pull"], input())
        complete(&a, SessionCursor(exercise: 1, set: 1))
        let t = t0.addingTimeInterval(40)
        let r = complete(&a, SessionCursor(exercise: 1, set: 2), at: t)
        XCTAssertEqual(r.rest, RestState(started: t, ends: t.addingTimeInterval(150)))
        XCTAssertEqual(a.rest, r.rest)
    }

    func test_completeValues() {
        var a = Session.plan(["pull"], input())
        let prefilled = a.workout.exercises[2].sets[0]
        complete(&a, SessionCursor(exercise: 2, set: 0), reps: 11, at: t0.addingTimeInterval(5))
        let s = a.workout.exercises[2].sets[0]
        XCTAssertTrue(s.done)
        XCTAssertEqual(s.doneAt, t0.addingTimeInterval(5))
        XCTAssertEqual(s.reps, 11)
        XCTAssertEqual(s.kg, prefilled.kg)
        XCTAssertEqual(s.id, prefilled.id)
    }

    func test_adjustRest() {
        var a = Session.plan(["pull"], input())
        Session.adjustRest(&a, by: 15, now: t0)
        XCTAssertNil(a.rest)

        complete(&a, SessionCursor(exercise: 1, set: 1))
        Session.adjustRest(&a, by: 15, now: t0)
        XCTAssertEqual(a.rest?.ends, t0.addingTimeInterval(165))
        XCTAssertEqual(a.rest?.started, t0)

        let now = t0.addingTimeInterval(135)   // 30 s left
        for _ in 0..<3 { Session.adjustRest(&a, by: -15, now: now) }
        XCTAssertEqual(a.rest?.ends, now)
    }

    func test_focus() {
        var a = Session.plan(["pull"], input())
        XCTAssertEqual(a.workout.exercises[6].exerciseId, "bayesian-curl")
        a.focus = a.workout.exercises[6].id
        XCTAssertEqual(Session.next(a), SessionCursor(exercise: 6, set: 0))
        complete(&a, SessionCursor(exercise: 6, set: 0))
        XCTAssertNotNil(a.focus)
        XCTAssertEqual(Session.next(a), SessionCursor(exercise: 6, set: 1))
        complete(&a, SessionCursor(exercise: 6, set: 1))
        complete(&a, SessionCursor(exercise: 6, set: 2))
        XCTAssertNil(a.focus)
        XCTAssertEqual(Session.next(a), SessionCursor(exercise: 0, set: 0))

        // A superset member's focus covers its whole group.
        a.focus = a.workout.exercises[5].id
        XCTAssertEqual(Session.next(a), SessionCursor(exercise: 4, set: 0))
    }

    // MARK: - Records

    func test_record() throws {
        let index = history("incline-db-press", routine: "push", done(26, [10, 10, 10]))
        var a = Session.plan(["push"], input(index: index))
        let i = try at(a, "incline-db-press")
        XCTAssertEqual(a.workout.exercises[i].sets.map(\.kind), [.warmup, .warmup, .normal, .normal, .normal])

        XCTAssertNil(complete(&a, SessionCursor(exercise: i, set: 0), index: index).record)
        let best = complete(&a, SessionCursor(exercise: i, set: 2), kg: 28, reps: 8, index: index)
        XCTAssertEqual(best.record, "New best: 28 kg × 8")
        XCTAssertEqual(a.lastRecord, "New best: 28 kg × 8")
        // 28 kg beats the old 26, but not the 28 × 8 of a minute ago.
        XCTAssertNil(complete(&a, SessionCursor(exercise: i, set: 3), kg: 28, reps: 7, index: index).record)
        XCTAssertEqual(a.lastRecord, "New best: 28 kg × 8")

        let dip = try at(a, "weighted-dip")
        XCTAssertNil(complete(&a, SessionCursor(exercise: dip, set: 0), kg: 10, reps: 8, index: index).record)
        XCTAssertNil(complete(&a, SessionCursor(exercise: dip, set: 1), kg: 20, reps: 8, index: index).record)
    }

    // MARK: - Lines and the Live Activity

    func test_doneLabel() throws {
        let (a, _) = try latPulldownSet2()
        XCTAssertEqual(Session.doneLabel(a, library: lib), "Set 2 of 3 · 57.5 kg × 8")

        var b = Session.plan(["push"], input(index: history("incline-db-press", routine: "push", done(26, [10, 10, 10]))))
        b.focus = b.workout.exercises[try at(b, "incline-db-press")].id
        XCTAssertEqual(Session.doneLabel(b, library: lib), "Warm-up 1 of 2 · 14 kg × 8")
    }

    func test_liveState() throws {
        let set2 = try latPulldownSet2()
        var a = set2.0
        let lat = set2.1
        let s = Session.liveState(a, library: lib, now: t0)
        XCTAssertEqual(s.title, "Pull + legs")
        XCTAssertEqual(s.started, t0)
        XCTAssertEqual(s.exercise, "Lat pulldown")
        XCTAssertEqual(s.exerciseNumber, 3)
        XCTAssertEqual(s.exerciseCount, 9)
        XCTAssertEqual(s.setNumber, 2)
        XCTAssertEqual(s.setCount, 3)
        XCTAssertFalse(s.warmup)
        XCTAssertEqual(s.planned, "57.5 kg × 8")
        XCTAssertEqual(s.plannedShort, "57.5 × 8")
        XCTAssertEqual(s.last, "55 × 11")
        XCTAssertNil(s.restStarted)
        XCTAssertNil(s.restEnds)
        XCTAssertFalse(s.allDone)

        let t = t0.addingTimeInterval(600)
        complete(&a, SessionCursor(exercise: lat, set: 1), at: t)
        let resting = Session.liveState(a, library: lib, now: t.addingTimeInterval(10))
        XCTAssertEqual(resting.restStarted, t)
        XCTAssertEqual(resting.restEnds, t.addingTimeInterval(120))
        XCTAssertEqual(resting.setNumber, 3)
        XCTAssertEqual(resting.last, "55 × 11")
        // Once the rest is over, it isn't shown as one.
        XCTAssertNil(Session.liveState(a, library: lib, now: t.addingTimeInterval(121)).restEnds)

        doneAll(&a)
        let end = Session.liveState(a, library: lib, now: t)
        XCTAssertTrue(end.allDone)
        // The last done set: the lat pulldown set at t is the only one with a time.
        XCTAssertEqual(end.exercise, "Lat pulldown")
        XCTAssertEqual(end.setNumber, 2)
    }

    func test_liveStateStaysSmall() throws {
        let name = String(repeating: "Ü😀", count: 200)
        let library = lib + [Exercise(id: "custom-x", name: name, custom: true)]
        let e = LoggedExercise(exerciseId: "custom-x", target: Target(sets: 1, lo: 8, hi: 12, rest: 60),
                               sets: [LoggedSet(kg: 20, reps: 8)])
        let a = ActiveWorkout(workout: Workout(title: String(repeating: "Long title ", count: 20), start: t0, exercises: [e]),
                              previous: [e.id.uuidString: done(20, [8])],
                              rest: RestState(started: t0, ends: t0.addingTimeInterval(60)))
        let s = Session.liveState(a, library: library, now: t0)
        XCTAssertEqual(s.exercise.count, WorkoutLiveState.maxText)
        XCTAssertEqual(s.exercise.count, 40)
        XCTAssertEqual(s.exercise, String(repeating: "Ü😀", count: 20))
        XCTAssertEqual(s.title.count, 40)
        XCTAssertLessThan(try JSONEncoder().encode(s).count, 4096)
    }

    func test_nextNilWhenAllDone() {
        var a = Session.plan(["pull"], input())
        doneAll(&a)
        XCTAssertNil(Session.next(a))
        XCTAssertNil(Session.doneLabel(a, library: lib))

        let before = a
        let stale = complete(&a, SessionCursor(exercise: 99, set: 0))
        XCTAssertEqual(stale, SetOutcome(record: nil, rest: before.rest))
        XCTAssertEqual(a, before)
        XCTAssertEqual(complete(&a, SessionCursor(exercise: 0, set: 99)), SetOutcome(record: nil, rest: nil))
        XCTAssertEqual(complete(&a, SessionCursor(exercise: -1, set: 0)), SetOutcome(record: nil, rest: nil))
        // A set that is already done is not logged twice.
        complete(&a, SessionCursor(exercise: 0, set: 0), reps: 99)
        XCTAssertEqual(a, before)
    }

    // MARK: - Finishing

    func test_finished() {
        var a = Session.plan(["pull"], input())
        complete(&a, SessionCursor(exercise: 1, set: 0))
        complete(&a, SessionCursor(exercise: 1, set: 1))
        let end = t0.addingTimeInterval(3600)
        let w = Session.finished(a, end: end, note: "Goed")
        XCTAssertEqual(w?.exercises.map(\.exerciseId), ["pull-up"])
        XCTAssertEqual(w?.exercises.first?.sets.count, 2)
        XCTAssertEqual(w?.exercises.first?.sets.allSatisfy(\.done), true)
        XCTAssertEqual(w?.end, end)
        XCTAssertEqual(w?.note, "Goed")
        XCTAssertEqual(w?.id, a.workout.id)

        XCTAssertNil(Session.finished(Session.plan(["pull"], input()), end: end, note: ""))
    }

    private func logged(_ id: String, routine: String?, ladder: String? = nil, target: Target?,
                        _ kg: Double?, _ reps: [Int]) -> LoggedExercise {
        LoggedExercise(exerciseId: id, ladderId: ladder, routineId: routine, target: target, sets: done(kg, reps))
    }

    func test_summary() throws {
        let earlier = [
            Workout(title: "Pull", routineIds: ["pull"], start: t0.addingTimeInterval(-3 * 86_400),
                    exercises: [logged("pull-up", routine: "pull", target: nil, nil, [8, 8, 8])]),
            Workout(title: "Push", routineIds: ["push"], start: t0.addingTimeInterval(-2 * 86_400),
                    exercises: [logged("incline-db-press", routine: "push", target: nil, 26, [10, 10, 10])]),
        ]
        let before = WorkoutIndex.build(earlier, library: lib)
        let state = WorkoutState()
        func summary(_ w: Workout) -> FinishSummary {
            Session.summary(w, before: before, library: lib, ladders: ladders, state: state)
        }
        let pullUp = WorkoutProgram.ladders[1].steps[1].target
        let tuck = WorkoutProgram.ladders[0].steps[1].target
        let incline = try target("push", "incline-db-press")

        // 18:00 → 19:24 with 27 counting sets.
        var exercises = [logged("pull-up", routine: "pull", ladder: "pull-up-ladder", target: pullUp, nil, [9, 9, 8])]
        for id in ["dragon-flag-tuck-negatives", "lat-pulldown", "seated-cable-row-v-grip", "single-arm-cable-lateral-raise",
                   "rear-delt-fly-cable", "bayesian-curl", "leg-press", "romanian-deadlift-smith"] {
            exercises.append(logged(id, routine: "pull", target: nil, 20, [10, 10, 10]))
        }
        exercises[1].sets.insert(LoggedSet(kind: .warmup, kg: 10, reps: 5, done: true), at: 0)
        let start = t0.addingTimeInterval(6 * 3600)
        let pull = Workout(title: "Pull + legs", routineIds: ["pull", "legs"], start: start,
                           end: start.addingTimeInterval(84 * 60), exercises: exercises)
        let s = summary(pull)
        XCTAssertEqual(s.heading, "Pull + legs · 84 min · 27 sets")
        XCTAssertEqual(s.lines.count, 9)
        XCTAssertEqual(s.lines[0], FinishLine(exerciseId: "pull-up", text: "Pull-up 9 · 9 · 8", change: "+2 reps", next: nil))
        XCTAssertEqual(s.records, ["Pull-up 9 reps"])
        // No last time: no change, and no target: no suggestion.
        XCTAssertEqual(s.lines[2].text, "Lat pulldown 20×10 · 20×10 · 20×10")
        XCTAssertNil(s.lines[2].change)
        XCTAssertNil(s.lines[2].next)

        func push(_ kg: Double, _ reps: [Int]) -> Workout {
            Workout(title: "Push", routineIds: ["push"], start: start, end: start.addingTimeInterval(3600),
                    exercises: [logged("incline-db-press", routine: "push", target: incline, kg, reps)])
        }
        let heavier = summary(push(28, [6, 6, 6]))
        XCTAssertEqual(heavier.lines[0].text, "Incline DB press 28×6 · 28×6 · 28×6")
        XCTAssertEqual(heavier.lines[0].change, "+2 kg")
        XCTAssertNil(heavier.lines[0].next)
        // Each best once: the second and third 28 × 6 don't beat the first.
        XCTAssertEqual(heavier.records, ["Incline DB press 28 kg × 6"])

        XCTAssertEqual(summary(push(26, [9, 9, 8])).lines[0].change, "\u{2212}4 reps")
        XCTAssertEqual(summary(push(26, [10, 10, 11])).lines[0].change, "+1 rep")
        let top = summary(push(26, [10, 10, 10])).lines[0]
        XCTAssertNil(top.change)
        XCTAssertEqual(top.next, "All sets at 10. Next time 28 kg")

        let flag = Workout(title: "Push", routineIds: ["push"], start: start, end: start.addingTimeInterval(3600),
                           exercises: [logged("dragon-flag-tuck-negatives", routine: "push", ladder: "dragon-flag-ladder",
                                              target: tuck, nil, [5, 5, 5])])
        XCTAssertEqual(summary(flag).lines[0].next, "Ready for tuck reps? Move up")
    }

    func test_summaryOnDeload() throws {
        let earlier = Workout(title: "Push", routineIds: ["push"], start: t0.addingTimeInterval(-2 * 86_400),
                              exercises: [logged("incline-db-press", routine: "push", target: nil, 26, [10, 10, 10])])
        let before = WorkoutIndex.build([earlier], library: lib)
        var incline = try target("push", "incline-db-press")
        incline.sets = Deload.sets(incline.sets)
        var w = Workout(title: "Push", routineIds: ["push"], start: t0, end: t0.addingTimeInterval(45 * 60),
                        exercises: [logged("incline-db-press", routine: "push", target: incline, 26, [10, 10])])

        // As a normal workout this would read "−10 reps" and "Next time 28 kg".
        let normal = Session.summary(w, before: before, library: lib, ladders: ladders, state: WorkoutState())
        XCTAssertEqual(normal.lines[0].change, "\u{2212}10 reps")
        XCTAssertEqual(normal.lines[0].next, "All sets at 10. Next time 28 kg")

        w.deload = true
        let s = Session.summary(w, before: before, library: lib, ladders: ladders, state: WorkoutState())
        XCTAssertEqual(s.heading, "Push · 45 min · 2 sets")
        XCTAssertEqual(s.lines, [FinishLine(exerciseId: "incline-db-press", text: "Incline DB press 26×10 · 26×10",
                                            change: nil, next: nil)])
    }
}
