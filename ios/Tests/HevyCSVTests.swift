import XCTest

/// Made up, in the export's exact format: three workouts, set types normal, warmup, dropset and failure, an empty
/// weight, a hold, a cardio row, a superset, quotes, a comma, a line break and an emoji in a title, a Dutch note, an
/// exercise that comes back as a second block, an exercise the library doesn't know, and one row that can't be read.
/// A raw literal, because a plain `"""` one would end at the `""",` in row 9. Not from anyone's real export.
private let fixture = #"""
"title","start_time","end_time","description","exercise_title","superset_id","exercise_notes","set_index","set_type","weight_kg","reps","distance_km","duration_seconds","rpe"
"Pull","12 Nov 2026, 18:05","12 Nov 2026, 19:20","Goed geslapen, sterke dag","Pull Up (Weighted)",,"Langzaam zakken",0,"warmup",,5,,,
"Pull","12 Nov 2026, 18:05","12 Nov 2026, 19:20","Goed geslapen, sterke dag","Pull Up (Weighted)",,"Langzaam zakken",1,"normal",10,8,,,8
"Pull","12 Nov 2026, 18:05","12 Nov 2026, 19:20","Goed geslapen, sterke dag","Pull Up (Weighted)",,"Langzaam zakken",2,"failure",10,6,,,10
"Pull","12 Nov 2026, 18:05","12 Nov 2026, 19:20","Goed geslapen, sterke dag","Lat Pulldown (Cable)",,"",0,"normal",55,12,,,
"Pull","12 Nov 2026, 18:05","12 Nov 2026, 19:20","Goed geslapen, sterke dag","Lat Pulldown (Cable)",,"",1,"dropset",40,10,,,
"Pull","12 Nov 2026, 18:05","12 Nov 2026, 19:20","Goed geslapen, sterke dag","Lateral Raise (Dumbbell)",1,"",0,"normal",10,15,,,
"Pull","12 Nov 2026, 18:05","12 Nov 2026, 19:20","Goed geslapen, sterke dag","Rear Delt Reverse Fly (Cable)",1,"",0,"normal",15,12,,,
"Pull","12 Nov 2026, 18:05","12 Nov 2026, 19:20","Goed geslapen, sterke dag","Dead Hang",,"",0,"normal",,,,45,
"Afternoon workout 💪, ""easy""","10 Nov 2026, 14:00","10 Nov 2026, 14:50","Line one
line two","Walking",,"",0,"normal",,,2.5,1800,
"Afternoon workout 💪, ""easy""","10 Nov 2026, 14:00","10 Nov 2026, 14:50","Line one
line two","Bench Press (Dumbbell)",,"",0,"normal",24,10,,,
"Afternoon workout 💪, ""easy""","10 Nov 2026, 14:00","10 Nov 2026, 14:50","Line one
line two","Bench Press (Dumbbell)",,"",1,"normal",24,9,,,
"Afternoon workout 💪, ""easy""","10 Nov 2026, 14:00","10 Nov 2026, 14:50","Line one
line two","Triceps Rope Pushdown",,"",0,"normal",30,12,,,
"Afternoon workout 💪, ""easy""","10 Nov 2026, 14:00","10 Nov 2026, 14:50","Line one
line two","Bench Press (Dumbbell)",,"",0,"normal",20,12,,,
"Push","9 Nov 2026, 19:16","9 Nov 2026, 20:31","","Incline Bench Press (Dumbbell)",,"",0,"warmup",14,8,,,
"Push","9 Nov 2026, 19:16","9 Nov 2026, 20:31","","Incline Bench Press (Dumbbell)",,"",1,"normal",26,10,,,
"Push","9 Nov 2026, 19:16","9 Nov 2026, 20:31","","Incline Bench Press (Dumbbell)",,"",2,"normal",26,x,,,
"Push","9 Nov 2026, 19:16","9 Nov 2026, 20:31","","Pike Pushup",,"",0,"normal",,10,,,
"Push","9 Nov 2026, 19:16","9 Nov 2026, 20:31","","Some Odd Machine",,"",0,"normal",30,10,,,
"""#

private let afternoon = "Afternoon workout 💪, \"easy\""

private func readFixture(_ text: String = fixture) throws -> HevyFile {
    try HevyCSV.read(Data(text.utf8))
}

private func instant(_ iso: String) -> Date {
    ISO8601DateFormatter().date(from: iso)!
}

final class HevyCSVTests: XCTestCase {
    private func workout(_ list: [Workout], _ title: String) throws -> Workout {
        try XCTUnwrap(list.first { $0.title == title }, title)
    }

    private func exercise(_ w: Workout, _ id: String) throws -> LoggedExercise {
        try XCTUnwrap(w.exercises.first { $0.exerciseId == id }, id)
    }

    private func mapped(_ choices: HevyChoices = HevyChoices()) throws -> (workouts: [Workout], newExercises: [Exercise]) {
        HevyCSV.workouts(try readFixture(), library: WorkoutProgram.exercises, existing: [], choices: choices)
    }

    // MARK: - Fields and rows

    func test_fields() {
        XCTAssertEqual(HevyCSV.fields("a,\"b,c\",\"d \"\"e\"\"\",\"f\ng\"\r\n"), [["a", "b,c", "d \"e\"", "f\ng"]])
        XCTAssertEqual(HevyCSV.fields(""), [])
        XCTAssertEqual(HevyCSV.fields("a,,b\nc,\"\""), [["a", "", "b"], ["c", ""]])
        XCTAssertEqual(HevyCSV.fields("a\r\rb\n"), [["a"], [""], ["b"]])
        XCTAssertEqual(HevyCSV.fields("\u{FEFF}\"x\r\ny\",1"), [["x\ny", "1"]])
    }

    func test_readFixture() throws {
        let f = try readFixture()
        XCTAssertEqual(f.rows.count, 17)
        XCTAssertEqual(f.skipped, 1)
        XCTAssertEqual(f.rows[8].title, afternoon)
        XCTAssertEqual(f.rows[8].note, "Line one\nline two")
        XCTAssertEqual(f.rows[8].km, 2.5)
        XCTAssertEqual(f.rows[8].seconds, 1800)
        XCTAssertEqual(f.rows[1].kg, 10)
        XCTAssertEqual(f.rows[1].reps, 8)
        XCTAssertEqual(f.rows[1].rpe, 8)
        XCTAssertEqual(f.rows[1].setIndex, 1)
        XCTAssertEqual(f.rows[0].kg, nil)
        XCTAssertEqual(f.rows[0].setType, "warmup")
        XCTAssertEqual(f.rows[0].exerciseNotes, "Langzaam zakken")
        XCTAssertEqual(f.rows[5].superset, 1)
        XCTAssertEqual(f.rows[3].superset, nil)
        XCTAssertFalse(f.rows.contains { $0.reps == nil && $0.kg == 26 })
    }

    /// Review Focus 2: a file that was opened and saved again (CRLF, a BOM) reads to the same rows.
    func test_crlfAndBom() throws {
        let saved = "\u{FEFF}" + fixture.replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertTrue(saved.utf8.starts(with: [0xEF, 0xBB, 0xBF]))
        XCTAssertTrue(saved.contains("Line one\r\nline two"))
        let plain = try readFixture()
        let read = try readFixture(saved)
        XCTAssertEqual(read.rows, plain.rows)
        XCTAssertEqual(read.skipped, plain.skipped)
        XCTAssertEqual(try readFixture(saved + "\r\n").rows, plain.rows)
    }

    func test_columnsByName() throws {
        let reversed = HevyCSV.fields(fixture).map { record in
            record.reversed().map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",")
        }.joined(separator: "\n")
        let read = try readFixture(reversed)
        XCTAssertEqual(read.rows, try readFixture().rows)
        XCTAssertEqual(read.skipped, 1)
    }

    func test_missingColumns() {
        let noExercise = fixture.replacingOccurrences(of: "\"exercise_title\",", with: "\"exercise\",")
        XCTAssertThrowsError(try readFixture(noExercise)) { error in
            XCTAssertEqual(error as? HevyError, .missingColumns(["exercise_title"]))
        }
        XCTAssertThrowsError(try readFixture("\"start_time\",\"weight_kg\"\n")) { error in
            XCTAssertEqual(error as? HevyError, .missingColumns(["title", "exercise_title"]))
        }
        XCTAssertThrowsError(try HevyCSV.read(Data())) { error in
            XCTAssertEqual(error as? HevyError, .empty)
        }
        XCTAssertThrowsError(try HevyCSV.read(Data([0x22, 0xFF, 0xFE, 0x22]))) { error in
            XCTAssertEqual(error as? HevyError, .notText)
        }
    }

    func test_numbersAndSkippedRows() throws {
        let header = #""title","start_time","exercise_title","weight_kg","reps","set_index""#
        let text = [
            header,
            #""Push","9 Nov 2026, 19:16","Pike Pushup","12,5","8","""#,
            #""Push","9 Nov 2026, 19:16","Pike Pushup","12.5","8.0","1""#,
            #""Push","9 Nov 2026, 19:16","Pike Pushup","","",2"#,
            #""Push","9 Nov 2026, 19:16","Pike Pushup","1e3","8","3""#,
            #""Push","9 Nov 2026, 19:16","Pike Pushup","10","8.5","4""#,
            #""Push","13/11/2026","Pike Pushup","10","8","5""#,
            #"" ","9 Nov 2026, 19:16","Pike Pushup","10","8","6""#,
            #""Push","9 Nov 2026, 19:16","","10","8","7""#,
            #""Push","9 Nov 2026, 19:16","Pike Pushup","10","8""#,
            "",
            #""Push","9 Nov 2026, 19:16","Pike Pushup","10","8","8""#,
        ].joined(separator: "\n")
        let f = try readFixture(text)
        XCTAssertEqual(f.rows.map(\.kg), [12.5, 12.5, nil, 10])
        XCTAssertEqual(f.rows.map(\.reps), [8, 8, nil, 8])
        XCTAssertEqual(f.rows.map(\.setIndex), [0, 1, 2, 8])
        XCTAssertEqual(f.rows.map(\.end), ["", "", "", ""])
        XCTAssertEqual(f.skipped, 6)
    }

    func test_dates() {
        let first = instant("2026-11-13T18:16:00Z")
        XCTAssertEqual(HevyCSV.date("13 Nov 2026, 19:16"), first)
        XCTAssertEqual(HevyCSV.date("15 Jul 2026, 08:00"), instant("2026-07-15T06:00:00Z"))
        XCTAssertEqual(HevyCSV.date("Nov 13, 2026, 7:16 PM"), first)
        XCTAssertEqual(HevyCSV.date("2026-11-13T19:16:00+01:00"), first)
        XCTAssertEqual(HevyCSV.date("2026-11-13T18:16:00Z"), first)
        XCTAssertNil(HevyCSV.date("13/11/2026"))
        XCTAssertNil(HevyCSV.date(""))
        XCTAssertEqual(HevyCSV.date("13 Nov 2026, 19:16", timeZone: TimeZone(identifier: "UTC")!),
                       instant("2026-11-13T19:16:00Z"))
    }

    // MARK: - Workouts

    func test_group() throws {
        let g = HevyCSV.group(try readFixture().rows)
        XCTAssertEqual(g.map(\.title), ["Push", afternoon, "Pull"])
        XCTAssertEqual(g[1].blocks.map(\.title),
                       ["Walking", "Bench Press (Dumbbell)", "Triceps Rope Pushdown", "Bench Press (Dumbbell)"])
        XCTAssertEqual(g[1].blocks.map(\.sets.count), [1, 2, 1, 1])
        XCTAssertEqual(g[1].note, "Line one\nline two")
        XCTAssertEqual(g[1].end, instant("2026-11-10T13:50:00Z"))
        let pull = g[2]
        XCTAssertEqual(pull.blocks.map(\.title), ["Pull Up (Weighted)", "Lat Pulldown (Cable)", "Lateral Raise (Dumbbell)",
                                                  "Rear Delt Reverse Fly (Cable)", "Dead Hang"])
        XCTAssertEqual(pull.blocks[0].notes, "Langzaam zakken")
        XCTAssertEqual(pull.blocks[1].notes, "")
        XCTAssertEqual(pull.note, "Goed geslapen, sterke dag")
        XCTAssertEqual(pull.key, "Pull|12 Nov 2026, 18:05")
        XCTAssertEqual(pull.start, instant("2026-11-12T17:05:00Z"))
        XCTAssertEqual(g[0].blocks.map(\.sets.count), [2, 1, 1])
    }

    func test_workoutsMapping() throws {
        let list = try mapped().workouts
        XCTAssertEqual(list.map(\.title), ["Push", afternoon, "Pull"])
        XCTAssertTrue(list.allSatisfy { $0.source == .hevy && $0.routineIds.isEmpty && $0.bodyWeight == nil })
        XCTAssertTrue(list.allSatisfy { $0.exercises.allSatisfy { $0.sets.allSatisfy(\.done) } })

        let pull = try workout(list, "Pull")
        XCTAssertEqual(pull.hevyKey, "Pull|12 Nov 2026, 18:05")
        XCTAssertEqual(pull.note, "Goed geslapen, sterke dag")
        XCTAssertEqual(pull.end, instant("2026-11-12T18:20:00Z"))
        let first = try XCTUnwrap(pull.exercises.first)
        XCTAssertEqual(first.exerciseId, "weighted-pull-up")
        XCTAssertEqual(first.sets.map(\.kind), [.warmup, .normal, .failure])
        XCTAssertEqual(first.sets.map(\.kg), [nil, 10, 10])
        XCTAssertEqual(first.sets.map(\.rir), [nil, 2, 0])
        XCTAssertEqual(first.routineId, "pull")
        XCTAssertEqual(first.note, "Langzaam zakken")
        XCTAssertTrue(pull.exercises.allSatisfy { $0.routineId == "pull" })
        XCTAssertEqual(try exercise(pull, "lat-pulldown").sets.map(\.kind), [.normal, .drop])
        let lateral = try exercise(pull, "db-lateral-raise"), rear = try exercise(pull, "rear-delt-fly-cable")
        XCTAssertNotNil(lateral.superset)
        XCTAssertEqual(lateral.superset, rear.superset)
        XCTAssertNil(first.superset)
        let hang = try XCTUnwrap(exercise(pull, "dead-hang").sets.first)
        XCTAssertEqual(hang.seconds, 45)
        XCTAssertNil(hang.reps)

        let other = try workout(list, afternoon)
        let walk = try XCTUnwrap(exercise(other, "walking").sets.first)
        XCTAssertEqual(walk.km, 2.5)
        XCTAssertEqual(walk.seconds, 1800)
        XCTAssertTrue(other.exercises.allSatisfy { $0.routineId == nil })
        XCTAssertEqual(other.exercises.map(\.exerciseId), ["walking", "flat-db-press", "rope-pushdown", "flat-db-press"])

        let push = try workout(list, "Push")
        let pike = try XCTUnwrap(exercise(push, "pike-push-up").sets.first)
        XCTAssertNil(pike.kg)
        XCTAssertEqual(pike.reps, 10)
        XCTAssertTrue(push.exercises.allSatisfy { $0.routineId == "push" })
    }

    func test_unmatched() throws {
        let f = try readFixture()
        let p = HevyCSV.preview(f, library: WorkoutProgram.exercises, existing: [])
        XCTAssertEqual(p.matched, 10)
        XCTAssertEqual(p.total, 11)
        XCTAssertEqual(p.unmatched, [HevyUnmatched(title: "Some Odd Machine", example: "30 kg × 10")])
        XCTAssertTrue(p.dumbbellTitles.contains("Bench Press (Dumbbell)"))
        XCTAssertEqual(Set(p.dumbbellTitles),
                       ["Lateral Raise (Dumbbell)", "Bench Press (Dumbbell)", "Incline Bench Press (Dumbbell)"])

        let kept = try mapped(HevyChoices(keepAsIs: ["Some Odd Machine"]))
        XCTAssertEqual(kept.newExercises.count, 1)
        let made = try XCTUnwrap(kept.newExercises.first)
        XCTAssertEqual(made.name, "Some Odd Machine")
        XCTAssertEqual(made.id, "custom-some-odd-machine")
        XCTAssertTrue(made.custom)
        XCTAssertEqual(made.primary, [])
        XCTAssertEqual(made.equipment, .other)
        XCTAssertEqual(made.kind, .weight)
        XCTAssertEqual(try workout(kept.workouts, "Push").exercises.last?.exerciseId, made.id)
        // Known by its Hevy name from then on.
        let library = WorkoutProgram.exercises + kept.newExercises
        XCTAssertEqual(HevyCSV.preview(f, library: library, existing: []).matched, 11)
        XCTAssertEqual(HevyCSV.workouts(f, library: library, existing: [], choices: HevyChoices()).newExercises, [])

        let picked = try mapped(HevyChoices(mapping: ["Some Odd Machine": "machine-chest-fly"]))
        XCTAssertEqual(picked.newExercises, [])
        XCTAssertEqual(try workout(picked.workouts, "Push").exercises.map(\.exerciseId),
                       ["incline-db-press", "pike-push-up", "machine-chest-fly"])

        let none = try mapped()
        XCTAssertEqual(none.newExercises, [])
        XCTAssertEqual(try workout(none.workouts, "Push").exercises.map(\.exerciseId), ["incline-db-press", "pike-push-up"])
    }

    func test_customKindAndId() throws {
        let header = #""title","start_time","exercise_title","weight_kg","reps","distance_km","duration_seconds""#
        let text = [
            header,
            #""Push","9 Nov 2026, 19:16","Rowing Thing","","","1.2","300""#,
            #""Push","9 Nov 2026, 19:16","Wall Sit","","","","60""#,
            #""Push","9 Nov 2026, 19:16","Band Pull Apart","","15","","""#,
            #""Push","9 Nov 2026, 19:16","💪","","15","","""#,
            #""Push","9 Nov 2026, 19:16","Cat Girl","20","15","","""#,
        ].joined(separator: "\n")
        let taken = Exercise(id: "custom-band-pull-apart", name: "Band pull-apart")
        let choices = HevyChoices(keepAsIs: ["Rowing Thing", "Wall Sit", "Band Pull Apart", "💪", "Cat Girl"])
        let made = HevyCSV.workouts(try readFixture(text), library: WorkoutProgram.exercises + [taken], existing: [],
                                    choices: choices).newExercises
        XCTAssertEqual(made.map(\.id), ["custom-rowing-thing", "custom-wall-sit", "custom-band-pull-apart-2", "custom-exercise"])
        XCTAssertEqual(made.map(\.kind), [.cardio, .time, .bodyweight, .bodyweight])
        XCTAssertEqual(made.map(\.hevyNames), [["Rowing Thing"], ["Wall Sit"], ["Band Pull Apart"], ["💪"]])
    }

    func test_halve() throws {
        let list = try mapped(HevyChoices(halve: ["Bench Press (Dumbbell)"])).workouts
        let other = try workout(list, afternoon)
        XCTAssertEqual(other.exercises.filter { $0.exerciseId == "flat-db-press" }.flatMap(\.sets).map(\.kg), [12, 12, 10])
        XCTAssertEqual(try exercise(other, "rope-pushdown").sets.map(\.kg), [30])
    }

    func test_previewText() throws {
        let f = try readFixture()
        let p = HevyCSV.preview(f, library: WorkoutProgram.exercises, existing: [])
        XCTAssertEqual(p.workouts, 3)
        XCTAssertEqual(p.sets, 17)
        XCTAssertEqual(p.first, instant("2026-11-09T18:16:00Z"))
        XCTAssertEqual(p.last, instant("2026-11-12T17:05:00Z"))
        XCTAssertEqual(HevyCSV.previewText(p), "3 workouts · 17 sets · 9 Nov 2026 – 12 Nov 2026 · 10 of 11 exercises matched")
        XCTAssertEqual(HevyCSV.skippedText(p), ["1 row skipped"])

        var one = p
        one.workouts = 1
        one.sets = 1
        one.first = p.last
        one.matched = 1
        one.total = 1
        XCTAssertEqual(HevyCSV.previewText(one), "1 workout · 1 set · 12 Nov 2026 · 1 of 1 exercise matched")
        var many = p
        many.workouts = 0
        many.duplicates = 12
        many.overlapping = 2
        many.skippedRows = 1234
        XCTAssertEqual(HevyCSV.previewText(many), "Nothing new in this file.")
        XCTAssertEqual(HevyCSV.skippedText(many), ["2 skipped: already logged here", "12 already imported", "1,234 rows skipped"])
    }

    func test_duplicatesAndOverlap() throws {
        let f = try readFixture()
        let list = try mapped().workouts
        let pull = try workout(list, "Pull")
        let start = try XCTUnwrap(HevyCSV.date("9 Nov 2026, 19:00"))
        let app = Workout(title: "Push", routineIds: ["push"], start: start, end: nil)
        let existing = [WorkoutSummary(pull), WorkoutSummary(app)]
        let p = HevyCSV.preview(f, library: WorkoutProgram.exercises, existing: existing)
        XCTAssertEqual(p.duplicates, 1)
        XCTAssertEqual(p.overlapping, 1)
        XCTAssertEqual(p.workouts, 1)
        XCTAssertEqual(HevyCSV.workouts(f, library: WorkoutProgram.exercises, existing: existing, choices: HevyChoices())
            .workouts.map(\.title), [afternoon])
        // Without an end, an app workout covers 3 hours; a Hevy workout never makes another one overlap.
        let later = Workout(title: "Push", routineIds: ["push"], start: start.addingTimeInterval(-3 * 3600 - 60))
        XCTAssertEqual(HevyCSV.preview(f, library: WorkoutProgram.exercises, existing: [WorkoutSummary(later)]).overlapping, 0)
        var hevy = app
        hevy.source = .hevy
        XCTAssertEqual(HevyCSV.preview(f, library: WorkoutProgram.exercises, existing: [WorkoutSummary(hevy)]).overlapping, 0)
        XCTAssertEqual(HevyCSV.unseen(list + list, existing: [WorkoutSummary(pull)]).map(\.title), ["Push", afternoon])
    }
}

private final class ImportClock {
    var date: Date
    init(_ d: Date) { date = d }
}

/// The import into a store with its own temporary folder and a clock it moves itself.
@MainActor
final class HevyImportTests: XCTestCase {
    private let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("HevyImportTests-" + UUID().uuidString, isDirectory: true)
    private let clock = ImportClock(HevyImportTests.at(2026, 11, 15, 12))

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    nonisolated private static func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Date {
        RecompCalendar.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func makeStore() -> WorkoutStore {
        let c = clock
        return WorkoutStore(directory: dir, now: { c.date })
    }

    private func url(_ path: String) -> URL { dir.appendingPathComponent(path) }

    private func setMode(_ path: String, _ mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url(path).path)
    }

    private func months() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url("history").path)) ?? []).sorted()
    }

    func test_importTwiceAddsNothing() async throws {
        let s = makeStore()
        let f = try readFixture()
        let added = try await s.importHevy(f, choices: HevyChoices())
        XCTAssertEqual(added, 3)
        XCTAssertEqual(s.index.workouts.count, 3)
        XCTAssertTrue(s.index.workouts.allSatisfy { $0.source == .hevy })
        let again = try await s.importHevy(f, choices: HevyChoices())
        XCTAssertEqual(again, 0)
        XCTAssertEqual(s.index.workouts.count, 3)
        let p = HevyCSV.preview(f, library: s.library, existing: s.index.workouts)
        XCTAssertEqual(p.duplicates, 3)
        XCTAssertEqual(HevyCSV.previewText(p), "Nothing new in this file.")
        XCTAssertEqual(HevyCSV.skippedText(p), ["3 already imported", "1 row skipped"])
        XCTAssertEqual(makeStore().index, s.index)
    }

    func test_newerExportAddsOnlyNew() async throws {
        let s = makeStore()
        let f = try readFixture()
        let first = try await s.importHevy(HevyFile(rows: f.rows.filter { $0.title == "Pull" }, skipped: 0),
                                           choices: HevyChoices())
        XCTAssertEqual(first, 1)
        let rest = try await s.importHevy(f, choices: HevyChoices())
        XCTAssertEqual(rest, 2)
        XCTAssertEqual(s.index.workouts.map(\.title), ["Push", afternoon, "Pull"])
    }

    func test_overlapSkipped() async throws {
        let s = makeStore()
        let start = try XCTUnwrap(HevyCSV.date("9 Nov 2026, 19:00")), end = try XCTUnwrap(HevyCSV.date("9 Nov 2026, 20:00"))
        let app = Workout(title: "Push", routineIds: ["push"], start: start, end: end,
                          exercises: [LoggedExercise(exerciseId: "incline-db-press", routineId: "push",
                                                     sets: [LoggedSet(kind: .normal, kg: 26, reps: 9, done: true)])])
        let saved = await s.update(app)
        XCTAssertTrue(saved)
        let f = try readFixture()
        let p = HevyCSV.preview(f, library: s.library, existing: s.index.workouts)
        XCTAssertEqual(p.overlapping, 1)
        XCTAssertTrue(HevyCSV.skippedText(p).contains("1 skipped: already logged here"))
        let added = try await s.importHevy(f, choices: HevyChoices())
        XCTAssertEqual(added, 2)
        XCTAssertEqual(s.index.workouts.map(\.title), ["Push", afternoon, "Pull"])
        XCTAssertEqual(s.index.workouts.first?.source, .app)
    }

    func test_importFeedsTheRest() async throws {
        let s = makeStore()
        s.bodyWeight = { _ in 88 }
        let added = try await s.importHevy(try readFixture(), choices: HevyChoices(keepAsIs: ["Some Odd Machine"]))
        XCTAssertEqual(added, 3)
        XCTAssertEqual(s.nextUp, .push)
        XCTAssertEqual(s.index.exercises["weighted-pull-up"]?.records.heaviest, 98)
        XCTAssertNotNil(s.index.exercises["custom-some-odd-machine"])
        XCTAssertNil(s.state.firstAppDay)
        XCTAssertEqual(s.recent.map(\.bodyWeight), [88, 88, 88])
        XCTAssertEqual(s.recent.map(\.title), ["Push", afternoon, "Pull"])
        XCTAssertTrue(s.library.contains { $0.id == "custom-some-odd-machine" && $0.custom })

        let reloaded = makeStore()
        XCTAssertNil(reloaded.state.firstAppDay)
        XCTAssertEqual(reloaded.library, s.library)
        XCTAssertEqual(reloaded.index, s.index)
        // Matched by its Hevy name from then on: nothing to choose, nothing doubled.
        let p = HevyCSV.preview(try readFixture(), library: reloaded.library, existing: [])
        XCTAssertEqual(p.matched, p.total)
    }

    /// As for a workout logged here: Recomp's weight on that day, else the fixed one, or only the fixed one.
    func test_importBodyWeightFollowsSettings() async throws {
        let f = try readFixture()
        let pull = HevyFile(rows: f.rows.filter { $0.title == "Pull" }, skipped: 0)
        let s = makeStore()
        s.bodyWeight = { _ in nil }
        var settings = s.state.settings
        settings.fixedBodyWeight = 75
        s.updateSettings(settings)
        let first = try await s.importHevy(pull, choices: HevyChoices())
        XCTAssertEqual(first, 1)
        XCTAssertEqual(s.recent.map(\.bodyWeight), [75])

        s.bodyWeight = { _ in 88 }
        settings.bodyWeightFromRecomp = false
        settings.fixedBodyWeight = 80
        s.updateSettings(settings)
        let rest = try await s.importHevy(f, choices: HevyChoices())
        XCTAssertEqual(rest, 2)
        XCTAssertEqual(s.recent.map(\.bodyWeight), [80, 80, 75])
    }

    func test_importProgress() async throws {
        let s = makeStore()
        let f = try readFixture()
        // The Push again, a month earlier: two months gain workouts.
        let october = f.rows.filter { $0.title == "Push" }.map { r -> HevyRow in
            var x = r
            x.start = "9 Oct 2026, 19:16"
            x.end = "9 Oct 2026, 20:31"
            return x
        }
        var shares: [Double] = []
        let added = try await s.importHevy(HevyFile(rows: f.rows + october, skipped: 0), choices: HevyChoices()) {
            shares.append($0)
        }
        XCTAssertEqual(added, 4)
        XCTAssertEqual(shares, [0.5, 1])
        XCTAssertEqual(months(), ["2026-10.json", "2026-11.json"])
    }

    /// Two imports of one file at once: the second checks against the months the first wrote.
    func test_concurrentImports() async throws {
        let s = makeStore()
        let f = try readFixture()
        async let first = s.importHevy(f, choices: HevyChoices())
        async let second = s.importHevy(f, choices: HevyChoices())
        let done = try await (first, second)
        XCTAssertEqual(done.0 + done.1, 3)
        XCTAssertEqual(s.index.workouts.count, 3)
        XCTAssertEqual(makeStore().index.workouts.count, 3)
    }

    /// As update, delete and restore (Ruling W-21): the import says so when the history can't be written.
    func test_importFailsLoudly() async throws {
        let s = makeStore()
        let f = try readFixture()
        let pull = HevyFile(rows: f.rows.filter { $0.title == "Pull" }, skipped: 0)
        let first = try await s.importHevy(pull, choices: HevyChoices())
        XCTAssertEqual(first, 1)
        let built = s.index, recent = s.recent, state = s.state

        try setMode("history", 0o555)
        defer { try? setMode("history", 0o755) }
        if FileManager.default.isWritableFile(atPath: url("history").path) {
            throw XCTSkip("This user can write any file.")
        }
        do {
            _ = try await s.importHevy(f, choices: HevyChoices())
            XCTFail("imported")
        } catch {
            XCTAssertEqual(error as? WorkoutStoreError, .notSaved)
        }
        try setMode("history", 0o755)
        XCTAssertEqual(s.index, built)
        XCTAssertEqual(s.recent, recent)
        XCTAssertEqual(s.state, state)
        XCTAssertEqual(months(), ["2026-11.json"])

        let rest = try await s.importHevy(f, choices: HevyChoices())
        XCTAssertEqual(rest, 2)
        XCTAssertEqual(s.index.workouts.count, 3)
    }
}
