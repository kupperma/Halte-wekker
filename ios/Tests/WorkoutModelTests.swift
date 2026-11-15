import XCTest

final class WorkoutModelTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func local(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int, calendar: Calendar = RecompCalendar.calendar) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private var amsterdam: (zone: TimeZone, calendar: Calendar) {
        let zone = TimeZone(identifier: "Europe/Amsterdam")!
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return (zone, c)
    }

    func test_missingFieldsDecodeToDefaults() throws {
        let w = try decode(Workout.self, #"{"title":"Push","start":0}"#)
        XCTAssertEqual(w.routineIds, [])
        XCTAssertEqual(w.source, .app)
        XCTAssertEqual(w.exercises, [])
        XCTAssertFalse(w.deload)

        let s = try decode(LoggedSet.self, #"{"kg":26,"reps":10}"#)
        XCTAssertEqual(s.kind, .normal)
        XCTAssertFalse(s.done)
        XCTAssertNil(s.rir)

        XCTAssertEqual(try decode(WorkoutState.self, "{}"), WorkoutState())

        let e = try decode(Exercise.self, #"{"id":"x","name":"X"}"#)
        XCTAssertEqual(e.kind, .weight)
        XCTAssertEqual(e.primary, [])
        XCTAssertNil(e.step)

        let st = try decode(WorkoutSettings.self, #"{"restSound":false}"#)
        XCTAssertFalse(st.restSound)
        XCTAssertEqual(st.steps, WorkoutSettings.defaultSteps)
    }

    func test_unknownSetKindIsNormal() throws {
        let s = try decode(LoggedSet.self, #"{"kind":"superset","reps":8}"#)
        XCTAssertEqual(s.kind, .normal)
    }

    func test_activeRoundTrip() throws {
        let t = Target(sets: 3, lo: 6, hi: 10, rirLo: 1, rirHi: 2, rest: 150)
        let set = LoggedSet(kind: .failure, kg: 26, reps: 10, rir: 1, done: true, doneAt: Date(timeIntervalSince1970: 1_000))
        let ex = LoggedExercise(exerciseId: "press", routineId: "push", target: t, superset: 1, note: "n", sets: [set])
        let w = Workout(title: "Push", routineIds: ["push"], start: Date(timeIntervalSince1970: 500),
                        end: Date(timeIntervalSince1970: 5_000), bodyWeight: 80.5, exercises: [ex])
        let a = ActiveWorkout(workout: w,
                              previous: [ex.id.uuidString: [LoggedSet(kg: 24, reps: 10, done: true)]],
                              closed: [ClosedItem(id: UUID(), routineId: "push", exerciseId: "dips", target: t, reason: "shoulder")],
                              rest: RestState(started: Date(timeIntervalSince1970: 900), ends: Date(timeIntervalSince1970: 1_050)),
                              focus: set.id, lastRecord: "press")
        let data = try JSONEncoder().encode(a)
        XCTAssertEqual(try JSONDecoder().decode(ActiveWorkout.self, from: data), a)
    }

    func test_hardSets() {
        let sets = [LoggedSet(kind: .warmup, kg: 14, reps: 8, done: true),
                    LoggedSet(kg: 26, reps: 10, done: true),
                    LoggedSet(kind: .drop, kg: 20, reps: 10, done: true),
                    LoggedSet(kg: 26, reps: 8, done: false)]
        let w = Workout(title: "Push", start: Date(), exercises: [LoggedExercise(exerciseId: "x", sets: sets)])
        XCTAssertEqual(w.hardSets, 2)
    }

    func test_dayAndMonth() {
        let late = Workout(title: "Late", start: local(2026, 12, 1, 0, 30))
        XCTAssertEqual(late.day, "2026-11-30")
        XCTAssertEqual(late.month, "2026-11")
        let morning = Workout(title: "Morning", start: local(2026, 12, 1, 4, 0))
        XCTAssertEqual(morning.day, "2026-12-01")
        XCTAssertEqual(morning.month, "2026-12")
    }

    func test_setRows() {
        XCTAssertEqual(SetRow.main.count, 7)
        XCTAssertTrue(SetRow.legs.contains(.quads))
        XCTAssertFalse(SetRow.legs.contains(.chest))
        XCTAssertEqual(SetRow.muscle(.lats).title, "Lats & back")
    }

    func test_formatSet() {
        func all(_ s: LoggedSet, _ k: ExerciseKind) -> [String] {
            [WorkoutFormat.set(s, k, .long), WorkoutFormat.set(s, k, .short), WorkoutFormat.set(s, k, .compact)]
        }
        XCTAssertEqual(all(LoggedSet(kg: 57.5, reps: 8), .weight), ["57.5 kg × 8", "57.5 × 8", "57.5×8"])
        XCTAssertEqual(all(LoggedSet(kg: 10, reps: 8), .weighted), ["+10 kg × 8", "+10 × 8", "+10×8"])
        XCTAssertEqual(all(LoggedSet(reps: 8), .weighted), ["8 reps", "8", "8"])
        XCTAssertEqual(all(LoggedSet(kg: 20, reps: 8), .assisted), ["\u{2212}20 kg × 8", "\u{2212}20 × 8", "\u{2212}20×8"])
        XCTAssertEqual(all(LoggedSet(reps: 9), .bodyweight), ["9 reps", "9", "9"])
        XCTAssertEqual(all(LoggedSet(seconds: 45), .time), ["45 s", "45 s", "45 s"])
        XCTAssertEqual(all(LoggedSet(seconds: 1800, km: 2.5), .cardio), ["2.5 km · 30:00", "2.5 km · 30:00", "2.5 km · 30:00"])
        XCTAssertEqual(all(LoggedSet(kg: 26), .weight), ["26 kg", "26", "26"])
    }

    func test_formatTarget() {
        XCTAssertEqual(WorkoutFormat.target(Target(sets: 3, lo: 6, hi: 10, rirLo: 1, rirHi: 2, rest: 150), .weight),
                       "3 × 6–10 · RIR 1–2 · rest 2:30")
        XCTAssertEqual(WorkoutFormat.target(Target(sets: 2, lo: 8, hi: 12, rirLo: 1, rirHi: 1, rest: 120), .weight),
                       "2 × 8–12 · RIR 1 · rest 2:00")
        XCTAssertEqual(WorkoutFormat.target(Target(sets: 3, lo: 3, hi: 6, rest: 120), .bodyweight),
                       "3 × 3–6 · rest 2:00")
        XCTAssertEqual(WorkoutFormat.target(Target(sets: 3, lo: 10, hi: 10, rirLo: 1, rirHi: 2, rest: 150), .bodyweight),
                       "3 × 10 · RIR 1–2 · rest 2:30")
        XCTAssertEqual(WorkoutFormat.target(Target(sets: 3, lo: 20, hi: 40, rest: 120), .time),
                       "3 × 20–40 s · rest 2:00")
    }

    func test_formatMisc() {
        let (zone, cal) = amsterdam
        XCTAssertEqual(WorkoutFormat.kg(57.5), "57.5")
        XCTAssertEqual(WorkoutFormat.kg(26), "26")
        XCTAssertEqual(WorkoutFormat.kg(1.25), "1.25")
        XCTAssertEqual(WorkoutFormat.rest(75), "1:15")
        XCTAssertEqual(WorkoutFormat.rest(60), "1:00")

        let d = local(2026, 11, 12, 19, 16, calendar: cal)
        XCTAssertEqual(WorkoutFormat.day(d, timeZone: zone), "Thu 12 Nov")
        XCTAssertEqual(WorkoutFormat.date(d, timeZone: zone), "12 Nov 2026")

        let sets = [LoggedSet(kind: .warmup, kg: 14, reps: 8, done: true),
                    LoggedSet(kg: 26, reps: 10, done: true),
                    LoggedSet(kg: 26, reps: 10, done: true),
                    LoggedSet(kg: 26, reps: 9, done: true)]
        XCTAssertEqual(WorkoutFormat.dayLine(d, sets, .weight, timeZone: zone), "Thu 12 Nov · 26×10 · 26×10 · 26×9")

        XCTAssertEqual(WorkoutFormat.ago(days: 0), "today")
        XCTAssertEqual(WorkoutFormat.ago(days: 1), "yesterday")
        XCTAssertEqual(WorkoutFormat.ago(days: 2), "2 days ago")
        XCTAssertEqual(WorkoutFormat.minutes(local(2026, 11, 12, 18, 0, calendar: cal), local(2026, 11, 12, 19, 24, calendar: cal)), "84 min")
        XCTAssertEqual(WorkoutFormat.sets(1), "1 set")
        XCTAssertEqual(WorkoutFormat.sets(27), "27 sets")
        XCTAssertEqual(WorkoutFormat.count(2241), "2,241")
        XCTAssertEqual(WorkoutFormat.names(["Pull-up"]), "Pull-up")
        XCTAssertEqual(WorkoutFormat.names(["Pull-up", "Seated row"]), "Pull-up and Seated row")
        XCTAssertEqual(WorkoutFormat.names(["A", "B", "C"]), "A, B and C")
    }

    func test_input() {
        XCTAssertEqual(WorkoutInput.kg("57,5"), 57.5)
        XCTAssertEqual(WorkoutInput.kg("57.5"), 57.5)
        XCTAssertEqual(WorkoutInput.kg(" 26 "), 26)
        XCTAssertEqual(WorkoutInput.kg("26 kg"), 26)
        XCTAssertEqual(WorkoutInput.kg("0"), 0)
        XCTAssertNil(WorkoutInput.kg(""))
        XCTAssertNil(WorkoutInput.kg("abc"))
        XCTAssertNil(WorkoutInput.kg("-2"))
        XCTAssertNil(WorkoutInput.kg("501"))

        XCTAssertEqual(WorkoutInput.reps("8"), 8)
        XCTAssertNil(WorkoutInput.reps("0"))
        XCTAssertNil(WorkoutInput.reps("8.5"))

        XCTAssertEqual(WorkoutInput.seconds("45"), 45)
        XCTAssertEqual(WorkoutInput.seconds("1:30"), 90)
        XCTAssertNil(WorkoutInput.seconds("0:75"))
    }
}
