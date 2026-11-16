import XCTest

private final class Clock {
    var date: Date
    init(_ d: Date) { date = d }
}

/// Set inside a history rewrite off the main actor, read by the test.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var open: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }
}

/// Every test has its own temporary folder and a clock it moves itself: never Application Support or the real time.
/// XCTest makes a new object for every test, so both are new for each.
@MainActor
final class WorkoutStoreTests: XCTestCase {
    private let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("WorkoutStoreTests-" + UUID().uuidString, isDirectory: true)
    private let clock = Clock(WorkoutStoreTests.at(2026, 11, 15, 12))

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    // MARK: - Helpers

    /// Local time, as the app's 04:00 day reads it.
    nonisolated private static func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        RecompCalendar.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        Self.at(year, month, day, hour, minute)
    }

    private func makeStore(_ directory: URL? = nil) -> WorkoutStore {
        let c = clock
        return WorkoutStore(directory: directory ?? dir, now: { c.date })
    }

    private func url(_ path: String) -> URL { dir.appendingPathComponent(path) }

    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: url(path).path) }

    private func names(_ path: String = "") -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url(path).path)) ?? []).sorted()
    }

    private func text(_ path: String) throws -> String {
        String(decoding: try Data(contentsOf: url(path)), as: UTF8.self)
    }

    private func put(_ text: String, _ path: String) throws {
        let u = url(path)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: u)
    }

    private func put<T: Encodable>(_ value: T, _ path: String) throws {
        try put(String(decoding: try JSONEncoder().encode(value), as: UTF8.self), path)
    }

    private func month(_ m: String) throws -> [Workout] {
        try JSONDecoder().decode(MonthFile.self, from: Data(contentsOf: url("history/\(m).json"))).workouts
    }

    private func modified(_ path: String) throws -> Date? {
        try FileManager.default.attributesOfItem(atPath: url(path).path)[.modificationDate] as? Date
    }

    /// Starts the routines at `date`, does the next set and finishes.
    @discardableResult
    private func finishOne(_ s: WorkoutStore, _ ids: [String], at date: Date) throws -> Workout {
        clock.date = date
        s.start(ids)
        XCTAssertTrue(s.completeNext())
        return try XCTUnwrap(s.finish(note: ""))
    }

    /// A Push at `date` with one incline DB press set of kg × reps.
    @discardableResult
    private func finishIncline(_ s: WorkoutStore, _ kg: Double, _ reps: Int, at date: Date) throws -> Workout {
        clock.date = date
        s.start(["push"])
        let a = try XCTUnwrap(s.active)
        let i = try XCTUnwrap(a.workout.exercises.firstIndex { $0.exerciseId == "incline-db-press" })
        let j = try XCTUnwrap(a.workout.exercises[i].sets.firstIndex { $0.kind != .warmup })
        s.complete(SessionCursor(exercise: i, set: j), kg: kg, reps: reps, seconds: nil)
        return try XCTUnwrap(s.finish(note: ""))
    }

    private func inclinePush(_ kg: Double, _ reps: Int, at date: Date) -> Workout {
        Workout(title: "Push", routineIds: ["push"], start: date, end: date.addingTimeInterval(3600),
                exercises: [LoggedExercise(exerciseId: "incline-db-press", routineId: "push",
                                           sets: [LoggedSet(kind: .normal, kg: kg, reps: reps, done: true)])])
    }

    private func index(_ a: ActiveWorkout, _ id: String) throws -> Int {
        try XCTUnwrap(a.workout.exercises.firstIndex { $0.exerciseId == id }, id)
    }

    private func setMode(_ path: String, _ mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url(path).path)
    }

    /// Root reads and writes any file, so those tests can't run as root.
    private func skipUnlessDenied(_ path: String, write: Bool = false) throws {
        let p = url(path).path
        let allowed = write ? FileManager.default.isWritableFile(atPath: p) : FileManager.default.isReadableFile(atPath: p)
        if allowed { throw XCTSkip("This user can \(write ? "write" : "read") any file.") }
    }

    // MARK: - Loading

    func test_firstRunSeeds() {
        let s = makeStore()
        XCTAssertEqual(s.library.count, WorkoutProgram.exercises.count)
        XCTAssertEqual(s.library, WorkoutProgram.exercises)
        XCTAssertEqual(s.ladders, WorkoutProgram.ladders)
        XCTAssertEqual(s.routines.count, 3)
        XCTAssertEqual(s.routines.map(\.id), ["push", "pull", "legs"])
        XCTAssertEqual(s.state, WorkoutState())
        XCTAssertNil(s.active)
        XCTAssertTrue(s.index.workouts.isEmpty)
        XCTAssertTrue(s.recent.isEmpty)
        XCTAssertNil(s.lastWorkout)
        XCTAssertEqual(s.nextUp, .push)
        for f in ["library.json", "routines.json", "state.json"] { XCTAssertTrue(exists(f), f) }
        XCTAssertFalse(exists("current.json"))

        let again = makeStore()
        XCTAssertEqual(again.library, s.library)
        XCTAssertEqual(again.routines, s.routines)
        XCTAssertEqual(again.state, s.state)
    }

    func test_missingFieldsTolerated() throws {
        try put(#"{"version":1,"settings":{"restSound":false}}"#, "state.json")
        let s = makeStore()
        XCTAssertFalse(s.state.settings.restSound)
        XCTAssertFalse(s.state.settings.keepScreenOn)
        XCTAssertTrue(s.state.settings.bodyWeightFromRecomp)
        XCTAssertEqual(s.state.settings.steps, WorkoutSettings.defaultSteps)
        XCTAssertEqual(s.state.ladderSteps, [:])
        XCTAssertEqual(s.state.deload, DeloadState())
        XCTAssertFalse(names().contains { $0.contains("corrupt") })
    }

    func test_newSeedExercisesAdded() throws {
        let own = Exercise(id: "custom-band-pull-apart", name: "Band pull-apart", custom: true)
        let saved = WorkoutProgram.exercises.filter { $0.id != "goblet-squat" } + [own]
        try put(LibraryFile(exercises: saved, ladders: WorkoutProgram.ladders), "library.json")
        let s = makeStore()
        XCTAssertNotNil(s.exercise("goblet-squat"))
        XCTAssertEqual(s.exercise("custom-band-pull-apart"), own)
        XCTAssertEqual(s.library.count, WorkoutProgram.exercises.count + 1)
        // Written back, so the next start has it as well.
        let file = try JSONDecoder().decode(LibraryFile.self, from: Data(contentsOf: url("library.json")))
        XCTAssertTrue(file.exercises.contains { $0.id == "goblet-squat" })
        XCTAssertTrue(file.exercises.contains { $0.id == "custom-band-pull-apart" })
    }

    func test_corruptMonthKept() throws {
        try put("not json", "history/2026-10.json")
        let w = inclinePush(26, 10, at: at(2026, 11, 10, 18))
        try put(MonthFile(month: "2026-11", workouts: [w]), "history/2026-11.json")
        let s = makeStore()
        XCTAssertEqual(s.index.workouts.count, 1)
        XCTAssertEqual(s.index.workouts.first?.id, w.id)
        let files = names("history")
        XCTAssertFalse(files.contains("2026-10.json"))
        XCTAssertTrue(files.contains("2026-11.json"))
        let kept = files.filter { $0.hasPrefix("2026-10.corrupt-") }
        XCTAssertEqual(kept, ["2026-10.corrupt-20261115-120000.json"])
        let name = try XCTUnwrap(kept.first)
        XCTAssertEqual(try text("history/" + name), "not json")
        XCTAssertEqual(s.recent.map(\.id), [w.id])
        XCTAssertTrue(exists("index.json"))
    }

    func test_corruptLibraryKeptAndReseeded() throws {
        try put("{", "library.json")
        let s = makeStore()
        XCTAssertEqual(s.library, WorkoutProgram.exercises)
        XCTAssertEqual(s.ladders, WorkoutProgram.ladders)
        let kept = names().filter { $0.hasPrefix("library.corrupt-") }
        XCTAssertEqual(kept.count, 1)
        let name = try XCTUnwrap(kept.first)
        XCTAssertEqual(try text(name), "{")
        let file = try JSONDecoder().decode(LibraryFile.self, from: Data(contentsOf: url("library.json")))
        XCTAssertEqual(file.exercises, WorkoutProgram.exercises)
    }

    func test_corruptCurrentKept() throws {
        try put("garbage", "current.json")
        let s = makeStore()
        XCTAssertNil(s.active)
        XCTAssertFalse(exists("current.json"))
        let kept = names().filter { $0.hasPrefix("current.corrupt-") }
        XCTAssertEqual(kept, ["current.corrupt-20261115-120000.json"])
        XCTAssertEqual(try text("current.corrupt-20261115-120000.json"), "garbage")

        // Without a workout it isn't one either; the same second gets its own name.
        try put("{}", "current.json")
        XCTAssertNil(makeStore().active)
        XCTAssertEqual(names().filter { $0.hasPrefix("current.corrupt-") },
                       ["current.corrupt-20261115-120000-2.json", "current.corrupt-20261115-120000.json"])
        XCTAssertEqual(try text("current.corrupt-20261115-120000.json"), "garbage")
    }

    func test_indexRebuilt() throws {
        let w = inclinePush(26, 10, at: at(2026, 11, 10, 18))
        try put(MonthFile(month: "2026-11", workouts: [w]), "history/2026-11.json")

        // Older than this version: rebuilt from the months and written.
        try put(#"{"version":0}"#, "index.json")
        XCTAssertEqual(makeStore().index.workouts.map(\.id), [w.id])
        let written = try JSONDecoder().decode(WorkoutIndex.self, from: Data(contentsOf: url("index.json")))
        XCTAssertEqual(written.version, 1)
        XCTAssertEqual(written.workouts.map(\.id), [w.id])
        XCTAssertEqual(written.exercises["incline-db-press"]?.records.heaviest, 26)

        // Corrupt: kept, and rebuilt.
        try put("[", "index.json")
        XCTAssertEqual(makeStore().index.workouts.map(\.id), [w.id])
        XCTAssertEqual(names().filter { $0.hasPrefix("index.corrupt-") }.count, 1)

        // A good index is read as it is: the months are not read for it.
        let other = inclinePush(28, 8, at: at(2026, 11, 12, 18))
        try put(MonthFile(month: "2026-11", workouts: [w, other]), "history/2026-11.json")
        XCTAssertEqual(makeStore().index.workouts.map(\.id), [w.id])
    }

    /// Before the first unlock after a restart the files can't be read. Then nothing is renamed or written, and the
    /// first action once they can be read loads them.
    func test_unreadableFileNeverOverwritten() throws {
        let own = Exercise(id: "custom-x", name: "X", custom: true)
        try put(LibraryFile(exercises: WorkoutProgram.exercises + [own], ladders: WorkoutProgram.ladders), "library.json")
        let before = try Data(contentsOf: url("library.json"))
        let path = url("library.json").path
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }
        if FileManager.default.isReadableFile(atPath: path) { throw XCTSkip("This user can read any file.") }

        let s = makeStore()
        XCTAssertFalse(s.available)
        XCTAssertNil(s.exercise("custom-x"))
        XCTAssertFalse(names().contains { $0.contains("corrupt") })
        XCTAssertFalse(exists("state.json"))
        XCTAssertFalse(exists("routines.json"))
        s.start(["push"])
        XCTAssertNil(s.active)
        s.moveUp("pull-up-ladder")
        XCTAssertEqual(s.state.ladderSteps, [:])
        XCTAssertFalse(exists("state.json"))

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        s.refresh()
        XCTAssertTrue(s.available)
        XCTAssertEqual(s.exercise("custom-x"), own)
        s.moveUp("pull-up-ladder")
        XCTAssertEqual(s.state.ladderSteps["pull-up-ladder"], 2)
        XCTAssertTrue(exists("state.json"))
        XCTAssertEqual(try Data(contentsOf: url("library.json")), before)
    }

    // MARK: - Month files and a restart

    /// Review Focus 1: 00:30 on 1 Dec is still 30 Nov, and so is its month file.
    func test_monthFiles() throws {
        let s = makeStore()
        let a = try finishOne(s, ["push"], at: at(2026, 11, 30, 10))
        let b = try finishOne(s, ["pull"], at: at(2026, 12, 1, 0, 30))
        XCTAssertEqual(b.day, "2026-11-30")
        XCTAssertEqual(try month("2026-11").map(\.id), [a.id, b.id])
        XCTAssertFalse(exists("history/2026-12.json"))

        // An old date on the file shows whether anything writes it again.
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url("history/2026-11.json").path)
        let before = try modified("history/2026-11.json")
        let c = try finishOne(s, ["push"], at: at(2026, 12, 1, 10))
        XCTAssertEqual(c.day, "2026-12-01")
        XCTAssertEqual(try month("2026-12").map(\.id), [c.id])
        XCTAssertEqual(try month("2026-11").map(\.id), [a.id, b.id])
        XCTAssertEqual(try modified("history/2026-11.json"), before)

        XCTAssertEqual(s.index.workouts.map(\.id), [a.id, b.id, c.id])
        XCTAssertEqual(s.recent.map(\.id), [a.id, b.id, c.id])
    }

    func test_resumeAfterRestart() throws {
        let s = makeStore()
        s.start(["pull"])
        XCTAssertTrue(s.completeNext())
        clock.date = clock.date.addingTimeInterval(30)
        XCTAssertTrue(s.completeNext())
        let a = try XCTUnwrap(s.active)
        let rest = try XCTUnwrap(a.rest)

        let again = makeStore()
        XCTAssertEqual(again.active?.workout.id, a.workout.id)
        XCTAssertEqual(again.active?.workout.exercises.flatMap(\.sets).filter(\.done).count, 2)
        XCTAssertEqual(again.active, a)
        XCTAssertNotNil(again.active?.rest)

        clock.date = rest.ends.addingTimeInterval(1)
        let later = makeStore()
        XCTAssertNil(later.active?.rest)
        XCTAssertEqual(later.active?.workout, a.workout)
    }

    // MARK: - Completing sets

    /// Ruling W-20: a Live Activity that shows another set than the next one logs nothing.
    func test_completeNextWrongSetId() throws {
        let s = makeStore()
        s.start(["push"])
        let before = try XCTUnwrap(s.active)
        XCTAssertFalse(s.completeNext(setId: UUID()))
        XCTAssertEqual(s.active, before)

        let c = try XCTUnwrap(Session.next(before))
        let id = before.workout.exercises[c.exercise].sets[c.set].id
        XCTAssertTrue(s.completeNext(setId: id))
        XCTAssertEqual(s.active?.workout.exercises[c.exercise].sets[c.set].done, true)

        // The same set again, from a Live Activity that hasn't caught up.
        let after = s.active
        XCTAssertFalse(s.completeNext(setId: id))
        XCTAssertEqual(s.active, after)
        XCTAssertEqual(makeStore().active, after)
    }

    /// Review Focus 4: "Set done" after the last set, or after Finish, logs nothing.
    func test_completeNextNothingLeft() throws {
        let s = makeStore()
        XCTAssertFalse(s.completeNext())

        s.start(["push"])
        let total = s.active?.workout.exercises.reduce(0) { $0 + $1.sets.count } ?? 0
        XCTAssertGreaterThan(total, 0)
        var n = 0
        while n <= total, s.completeNext() { n += 1 }
        XCTAssertEqual(n, total)
        XCTAssertEqual(s.active?.workout.exercises.flatMap(\.sets).allSatisfy(\.done), true)
        XCTAssertFalse(s.completeNext())
        XCTAssertFalse(s.completeNext(setId: s.active?.workout.exercises.last?.sets.last?.id))
        XCTAssertEqual(s.active?.workout.exercises.reduce(0) { $0 + $1.sets.count }, total)

        XCTAssertNotNil(s.finish(note: ""))
        XCTAssertFalse(s.completeNext())
        XCTAssertNil(s.active)
    }

    // MARK: - Finishing

    func test_finishZeroSetsNotSaved() throws {
        let s = makeStore()
        s.start(["push"])
        XCTAssertNil(s.finish(note: ""))
        XCTAssertNotNil(s.active)
        XCTAssertTrue(names("history").isEmpty)

        // A warm-up alone is not saved either (Ruling W-19).
        let a = try XCTUnwrap(s.active)
        let i = try index(a, "incline-db-press")
        let w = try XCTUnwrap(a.workout.exercises[i].sets.firstIndex { $0.kind == .warmup })
        s.complete(SessionCursor(exercise: i, set: w), kg: nil, reps: nil, seconds: nil)
        XCTAssertEqual(s.active?.workout.exercises[i].sets[w].done, true)
        XCTAssertNil(s.finish(note: ""))
        XCTAssertTrue(names("history").isEmpty)
        XCTAssertTrue(s.index.workouts.isEmpty)
        XCTAssertTrue(exists("current.json"))

        s.discard()
        XCTAssertNil(s.active)
        XCTAssertFalse(exists("current.json"))
        XCTAssertNil(makeStore().active)
    }

    func test_finishUpdatesStateAndIndex() throws {
        let s = makeStore()
        s.start(["pull", "legs"])
        XCTAssertEqual(s.state.firstAppDay, "2026-11-15")
        XCTAssertNil(s.state.firstLegsDay)
        XCTAssertTrue(s.completeNext())
        clock.date = at(2026, 11, 15, 13, 15)
        let w = try XCTUnwrap(s.finish(note: "Goed geslapen"))
        XCTAssertEqual(w.note, "Goed geslapen")
        XCTAssertEqual(w.end, clock.date)
        XCTAssertEqual(w.hardSets, 1)

        XCTAssertEqual(s.state.firstLegsDay, "2026-11-15")
        XCTAssertEqual(s.state.firstAppDay, "2026-11-15")
        XCTAssertEqual(s.index.workouts.count, 1)
        XCTAssertEqual(s.lastWorkout?.id, w.id)
        XCTAssertEqual(s.nextUp, .restThenPush)
        XCTAssertNil(s.active)
        XCTAssertFalse(exists("current.json"))
        XCTAssertEqual(try month("2026-11"), [w])
        XCTAssertEqual(s.recent, [w])
        XCTAssertEqual(s.weeklySets, WeeklySets.count([w], library: s.library, today: "2026-11-15"))
        XCTAssertEqual(s.targets, WeeklySets.targets(s.routines, ladders: s.ladders, state: s.state, library: s.library))

        let again = makeStore()
        XCTAssertEqual(again.index, s.index)
        XCTAssertEqual(again.state, s.state)
        XCTAssertNil(again.active)
        XCTAssertEqual(again.recent, [w])
        XCTAssertEqual(again.nextUp, .restThenPush)
    }

    // MARK: - Deload

    func test_deloadAfterOnePushOnePull() throws {
        let s = makeStore()
        s.startDeload()
        XCTAssertTrue(s.state.deload.active)
        let push = try finishOne(s, ["push"], at: at(2026, 11, 15, 18))
        XCTAssertTrue(push.deload)
        XCTAssertTrue(s.state.deload.active)
        XCTAssertEqual(s.state.deload.left, ["pull"])

        let pull = try finishOne(s, ["pull"], at: at(2026, 11, 16, 18))
        XCTAssertTrue(pull.deload)
        XCTAssertFalse(s.state.deload.active)
        XCTAssertEqual(s.state.deload.lastDay, "2026-11-16")
        XCTAssertEqual(makeStore().state.deload, s.state.deload)
    }

    func test_deloadButtons() {
        let s = makeStore()
        s.startDeload()
        s.cancelDeload()
        XCTAssertFalse(s.state.deload.active)
        XCTAssertEqual(s.state.deload.left, [])
        XCTAssertNil(s.state.deload.lastDay)

        // Six weeks after the first workout in the app, then "Not yet" for a week.
        s.start([])
        s.discard()
        XCTAssertEqual(s.state.firstAppDay, "2026-11-15")
        XCTAssertNil(s.deloadLine)
        clock.date = at(2026, 12, 27, 12)
        XCTAssertEqual(s.deloadLine, .planned(weeks: 6))
        s.snoozeDeload()
        XCTAssertEqual(s.state.deload.snoozedUntil, "2027-01-03")
        XCTAssertNil(s.deloadLine)
        XCTAssertEqual(makeStore().state.deload, s.state.deload)
        clock.date = at(2027, 1, 3, 12)
        XCTAssertEqual(s.deloadLine, .planned(weeks: 7))
    }

    /// Ruling W-6: the falls that led to a deload don't flag again after it.
    func test_flaggedIgnoresBeforeDeload() throws {
        let old = [inclinePush(30, 8, at: at(2026, 11, 1, 18)), inclinePush(28, 8, at: at(2026, 11, 4, 18)),
                   inclinePush(26, 8, at: at(2026, 11, 7, 18))]
        try put(MonthFile(month: "2026-11", workouts: old), "history/2026-11.json")
        var state = WorkoutState()
        state.deload.lastDay = "2026-11-07"
        try put(state, "state.json")
        clock.date = at(2026, 11, 8, 12)
        let s = makeStore()
        let recent = try XCTUnwrap(s.index.exercises["incline-db-press"]?.recent)
        XCTAssertTrue(Deload.flagged(recent))
        XCTAssertEqual(s.flagged, [])

        try finishIncline(s, 30, 8, at: at(2026, 11, 9, 18))
        try finishIncline(s, 28, 8, at: at(2026, 11, 11, 18))
        XCTAssertEqual(s.flagged, [])
        try finishIncline(s, 26, 8, at: at(2026, 11, 13, 18))
        XCTAssertEqual(s.flagged, ["incline-db-press"])
    }

    // MARK: - Changing the history

    /// Review Focus 5: no record or "last time" points at a deleted workout.
    func test_deleteRebuildsRecords() async throws {
        let s = makeStore()
        let first = try finishIncline(s, 30, 8, at: at(2026, 11, 10, 18))
        let second = try finishIncline(s, 26, 10, at: at(2026, 11, 12, 18))
        XCTAssertEqual(s.index.exercises["incline-db-press"]?.records.heaviest, 30)

        let deleted = await s.delete(first.id)
        XCTAssertTrue(deleted)
        let x = try XCTUnwrap(s.index.exercises["incline-db-press"])
        XCTAssertEqual(x.records.heaviest, 26)
        XCTAssertEqual(x.last?.workoutId, second.id)
        XCTAssertEqual(x.lastByRoutine["push"]?.workoutId, second.id)
        XCTAssertEqual(s.index.workouts.map(\.id), [second.id])
        XCTAssertEqual(try month("2026-11").map(\.id), [second.id])
        XCTAssertEqual(s.recent.map(\.id), [second.id])
        XCTAssertEqual(makeStore().index, s.index)
    }

    func test_updateMovesMonth() async throws {
        let s = makeStore()
        let w = try finishOne(s, ["push"], at: at(2026, 11, 30, 10))
        var moved = w
        moved.start = at(2026, 12, 2, 10)
        moved.end = at(2026, 12, 2, 11)
        moved.note = "Verschoven"
        let updated = await s.update(moved)
        XCTAssertTrue(updated)
        XCTAssertFalse(try month("2026-11").contains { $0.id == w.id })
        XCTAssertEqual(try month("2026-12"), [moved])
        XCTAssertEqual(s.index.workouts.map(\.start), [moved.start])
        XCTAssertTrue(s.recent.isEmpty)
        let all = await s.allWorkouts()
        XCTAssertEqual(all, [moved])
        let december = await s.workouts(month: "2026-12")
        XCTAssertEqual(december, [moved])
        let november = await s.workouts(month: "2026-11")
        XCTAssertEqual(november, [])
    }

    // MARK: - Body weight, replacing, ladders

    func test_bodyWeightStored() {
        let s = makeStore()
        s.bodyWeight = { _ in 87.6 }
        XCTAssertEqual(s.bodyWeightNow, 87.6)
        s.start(["pull"])
        XCTAssertEqual(s.active?.workout.bodyWeight, 87.6)
        s.discard()

        var settings = s.state.settings
        settings.bodyWeightFromRecomp = false
        settings.fixedBodyWeight = 90
        s.updateSettings(settings)
        s.start(["pull"])
        XCTAssertEqual(s.active?.workout.bodyWeight, 90)
        s.discard()

        // From Recomp, but no weight there: the fixed one.
        settings.bodyWeightFromRecomp = true
        s.updateSettings(settings)
        s.bodyWeight = { _ in nil }
        XCTAssertEqual(s.bodyWeightNow, 90)
        XCTAssertEqual(makeStore().state.settings, settings)
    }

    func test_replaceKeepsDoneSets() throws {
        let s = makeStore()
        s.start(["pull"])
        var a = try XCTUnwrap(s.active)
        let count = a.workout.exercises.count
        let lat = try index(a, "lat-pulldown")
        let first = try XCTUnwrap(a.workout.exercises[lat].sets.firstIndex { $0.kind != .warmup })
        s.complete(SessionCursor(exercise: lat, set: first), kg: 55, reps: 12, seconds: nil)
        s.replaceExercise(lat, with: "single-arm-cable-pulldown")
        a = try XCTUnwrap(s.active)
        XCTAssertEqual(a.workout.exercises.count, count + 1)
        let old = a.workout.exercises[lat]
        let new = a.workout.exercises[lat + 1]
        XCTAssertEqual(old.exerciseId, "lat-pulldown")
        XCTAssertEqual(old.sets.count, 1)
        XCTAssertEqual(old.sets.first?.done, true)
        XCTAssertEqual(old.sets.first?.kg, 55)
        XCTAssertEqual(new.exerciseId, "single-arm-cable-pulldown")
        XCTAssertEqual(new.sets.count, 2)
        XCTAssertFalse(new.sets.contains(where: \.done))
        XCTAssertEqual(new.target?.sets, 2)
        XCTAssertEqual(new.routineId, "pull")
        XCTAssertNotNil(a.previous[new.id.uuidString])
        XCTAssertEqual(makeStore().active, a)

        s.discard()
        s.start(["pull"])
        let before = try XCTUnwrap(s.active)
        s.replaceExercise(lat, with: "single-arm-cable-pulldown")
        a = try XCTUnwrap(s.active)
        XCTAssertEqual(a.workout.exercises.count, count)
        XCTAssertEqual(a.workout.exercises[lat].exerciseId, "single-arm-cable-pulldown")
        XCTAssertEqual(a.workout.exercises[lat].sets.count, 3)
        XCTAssertFalse(a.workout.exercises.contains { $0.exerciseId == "lat-pulldown" })
        XCTAssertNil(a.previous[before.workout.exercises[lat].id.uuidString])
        XCTAssertEqual(a.workout.exercises[lat + 1], before.workout.exercises[lat + 1])

        // On a ladder: another step stays on it (with its warm-up), anything else leaves it.
        let pu = try index(a, "pull-up")
        s.replaceExercise(pu, with: "assisted-pull-up")
        let assisted = try XCTUnwrap(s.active?.workout.exercises[pu])
        XCTAssertEqual(assisted.exerciseId, "assisted-pull-up")
        XCTAssertEqual(assisted.ladderId, "pull-up-ladder")
        XCTAssertEqual(assisted.sets.map(\.kind), [.warmup, .normal, .normal, .normal])
        s.replaceExercise(pu, with: "seated-cable-row-bar-grip")
        XCTAssertNil(s.active?.workout.exercises[pu].ladderId)
    }

    func test_ladderMoveUpPersists() throws {
        let s = makeStore()
        let ladder = try XCTUnwrap(s.ladder("pull-up-ladder"))
        XCTAssertEqual(Ladders.current(ladder, state: s.state), 1)
        s.moveUp("pull-up-ladder")
        XCTAssertEqual(Ladders.current(ladder, state: s.state), 2)

        let again = makeStore()
        XCTAssertEqual(Ladders.current(ladder, state: again.state), 2)
        again.moveUp("pull-up-ladder")
        XCTAssertEqual(Ladders.current(ladder, state: again.state), 2)
        again.stepBack("pull-up-ladder")
        XCTAssertEqual(Ladders.current(ladder, state: makeStore().state), 1)
    }

    // MARK: - Changing a running workout

    func test_editsWriteCurrent() throws {
        let s = makeStore()
        s.start(["pull", "legs"])
        var a = try XCTUnwrap(s.active)
        let lat = try index(a, "lat-pulldown")
        let c = SessionCursor(exercise: lat, set: 0)

        s.edit(c, kg: 57.5, reps: 8, seconds: nil)
        a = try XCTUnwrap(s.active)
        XCTAssertEqual(a.workout.exercises[lat].sets[0].kg, 57.5)
        XCTAssertEqual(a.workout.exercises[lat].sets[0].reps, 8)
        XCTAssertFalse(a.workout.exercises[lat].sets[0].done)
        XCTAssertNil(a.rest)

        s.complete(c, kg: nil, reps: nil, seconds: nil)
        let rest = try XCTUnwrap(s.active?.rest)
        XCTAssertEqual(s.active?.workout.exercises[lat].sets[0].done, true)
        s.edit(c, kg: nil, reps: 9, seconds: nil)
        XCTAssertEqual(s.active?.workout.exercises[lat].sets[0].kg, 57.5)
        XCTAssertEqual(s.active?.workout.exercises[lat].sets[0].reps, 9)
        XCTAssertEqual(s.active?.rest, rest)
        s.setRIR(c, 7)
        XCTAssertEqual(s.active?.workout.exercises[lat].sets[0].rir, 4)
        s.setRIR(c, nil)
        XCTAssertNil(s.active?.workout.exercises[lat].sets[0].rir)
        s.setKind(c, .failure)
        XCTAssertEqual(s.active?.workout.exercises[lat].sets[0].kind, .failure)
        s.adjustRest(by: 15)
        XCTAssertEqual(s.active?.rest?.ends, rest.ends.addingTimeInterval(15))
        s.skipRest()
        XCTAssertNil(s.active?.rest)

        s.addSet(exercise: lat)
        a = try XCTUnwrap(s.active)
        XCTAssertEqual(a.workout.exercises[lat].sets.count, 4)
        XCTAssertFalse(a.workout.exercises[lat].sets[3].done)
        XCTAssertNotEqual(a.workout.exercises[lat].sets[3].id, a.workout.exercises[lat].sets[2].id)
        s.removeSet(SessionCursor(exercise: lat, set: 3))
        XCTAssertEqual(s.active?.workout.exercises[lat].sets.count, 3)
        s.setExerciseNote(lat, "Brede greep")
        XCTAssertEqual(s.active?.workout.exercises[lat].note, "Brede greep")

        s.focus(lat + 1)
        XCTAssertEqual(s.active.flatMap { Session.next($0) }?.exercise, lat + 1)
        s.focus(nil)
        XCTAssertNil(s.active?.focus)

        // A closed row joins after the last exercise of its routine.
        let closed = try XCTUnwrap(s.active?.closed)
        XCTAssertEqual(closed.map(\.exerciseId), ["hammer-curl-db", "lying-leg-curl"])
        s.addClosed(closed[0].id)
        a = try XCTUnwrap(s.active)
        let hammer = try index(a, "hammer-curl-db")
        XCTAssertEqual(a.workout.exercises[hammer - 1].exerciseId, "bayesian-curl")
        XCTAssertEqual(a.workout.exercises[hammer + 1].exerciseId, "leg-press")
        XCTAssertEqual(a.workout.exercises[hammer].routineId, "pull")
        XCTAssertEqual(a.workout.exercises[hammer].sets.count, 2)
        XCTAssertEqual(a.closed.map(\.exerciseId), ["lying-leg-curl"])

        s.addExercise("goblet-squat")
        a = try XCTUnwrap(s.active)
        XCTAssertEqual(a.workout.exercises.last?.exerciseId, "goblet-squat")
        XCTAssertNil(a.workout.exercises.last?.routineId)
        XCTAssertEqual(a.workout.exercises.last?.sets.count, 3)
        let last = a.workout.exercises.count - 1
        s.moveExercise(from: IndexSet(integer: last), to: 0)
        XCTAssertEqual(s.active?.workout.exercises.first?.exerciseId, "goblet-squat")
        s.moveExercise(from: IndexSet(integer: 0), to: 2)
        XCTAssertEqual(s.active?.workout.exercises[1].exerciseId, "goblet-squat")
        s.removeExercise(1)
        XCTAssertFalse(s.active?.workout.exercises.contains { $0.exerciseId == "goblet-squat" } ?? true)

        XCTAssertEqual(makeStore().active, s.active)
    }

    // MARK: - Exercises and routines

    func test_newExerciseAndRoutine() throws {
        let s = makeStore()
        let a = s.newExercise(name: "  Band pull-apart ", kind: .bodyweight, equipment: .other)
        XCTAssertEqual(a.id, "custom-band-pull-apart")
        XCTAssertEqual(a.name, "Band pull-apart")
        XCTAssertTrue(a.custom)
        let b = s.newExercise(name: "Band pull-apart", kind: .weight, equipment: .cable)
        XCTAssertEqual(b.id, "custom-band-pull-apart-2")
        XCTAssertEqual(makeStore().exercise(b.id), b)
        var edited = a
        edited.primary = [.rearDelts]
        s.saveExercise(edited)
        XCTAssertEqual(makeStore().exercise(a.id)?.primary, [.rearDelts])

        let w = try finishOne(s, ["pull"], at: at(2026, 11, 15, 18))
        s.saveAsRoutine(w, name: " Short pull ")
        let r = try XCTUnwrap(s.routines.last)
        XCTAssertEqual(r.id, "routine-short-pull")
        XCTAssertEqual(r.name, "Short pull")
        XCTAssertEqual(r.items.map(\.ladderId), ["dragon-flag-ladder"])
        XCTAssertEqual(r.items.first?.target, w.exercises.first?.target)
        s.saveAsRoutine(w, name: "Short pull")
        XCTAssertEqual(s.routines.last?.id, "routine-short-pull-2")

        // An imported workout has no targets: they come from its sets.
        let imported = Workout(title: "Back", start: at(2026, 11, 1, 10), source: .hevy, exercises: [
            LoggedExercise(exerciseId: "lat-pulldown", sets: [
                LoggedSet(kind: .warmup, kg: 30, reps: 15, done: true),
                LoggedSet(kind: .normal, kg: 55, reps: 12, done: true),
                LoggedSet(kind: .normal, kg: 55, reps: 10, done: true),
            ]),
        ])
        s.saveAsRoutine(imported, name: "")
        let back = try XCTUnwrap(s.routines.last)
        XCTAssertEqual(back.id, "routine-back")
        XCTAssertEqual(back.name, "Back")
        XCTAssertEqual(back.items.map(\.exerciseId), ["lat-pulldown"])
        XCTAssertEqual(back.items.first?.target, Target(sets: 2, lo: 10, hi: 12, rest: 120))
        XCTAssertEqual(makeStore().routines, s.routines)

        s.saveRoutines(Array(s.routines.prefix(3)))
        XCTAssertEqual(makeStore().routines.map(\.id), ["push", "pull", "legs"])
    }

    // MARK: - Backup

    func test_backupRestore() async throws {
        let s = makeStore()
        try finishOne(s, ["push"], at: at(2026, 11, 12, 18))
        try finishOne(s, ["pull"], at: at(2026, 11, 13, 18))
        let data = await s.backup()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(json["workouts"])
        let want = await s.allWorkouts()
        XCTAssertEqual(want.count, 2)

        let r = makeStore(dir.appendingPathComponent("restored", isDirectory: true))
        try await r.restore(data)
        var got = await r.allWorkouts()
        XCTAssertEqual(got, want)
        XCTAssertEqual(r.routines, s.routines)
        XCTAssertEqual(r.state, s.state)
        XCTAssertEqual(r.library, s.library)
        XCTAssertEqual(r.index, s.index)

        try await r.restore(data)
        got = await r.allWorkouts()
        XCTAssertEqual(got, want)
        XCTAssertEqual(r.index.workouts.count, 2)

        for bad in ["x", #"{"version":1,"routines":[]}"#, "[]"] {
            do {
                try await r.restore(Data(bad.utf8))
                XCTFail("restored \(bad)")
            } catch {
                XCTAssertEqual(error as? WorkoutStoreError, .notABackup)
            }
        }
        XCTAssertEqual(r.routines, s.routines)

        // Nothing on the phone is deleted, and the running workout stays.
        let phone = makeStore(dir.appendingPathComponent("phone", isDirectory: true))
        let own = try finishOne(phone, ["push"], at: at(2026, 11, 14, 18))
        phone.start(["pull"])
        let running = try XCTUnwrap(phone.active)
        try await phone.restore(data)
        let all = await phone.allWorkouts()
        XCTAssertEqual(all.map(\.id), want.map(\.id) + [own.id])
        XCTAssertEqual(phone.index.workouts.count, 3)
        XCTAssertEqual(phone.active, running)
    }

    // MARK: - Saving safely

    /// Ruling W-21: a month that can't be read or written saves nothing, and nothing else changes.
    func test_finishNothingWhenMonthFails() throws {
        let s = makeStore()
        let first = try finishOne(s, ["push"], at: at(2026, 11, 12, 18))
        clock.date = at(2026, 11, 15, 18)
        s.start(["pull", "legs"])
        XCTAssertTrue(s.completeNext())
        let active = s.active, built = s.index, state = s.state, recent = s.recent
        let current = try Data(contentsOf: url("current.json"))
        func unchanged(line: UInt = #line) throws {
            XCTAssertEqual(s.active, active, line: line)
            XCTAssertEqual(s.index, built, line: line)
            XCTAssertEqual(s.state, state, line: line)
            XCTAssertEqual(s.recent, recent, line: line)
            XCTAssertEqual(try Data(contentsOf: url("current.json")), current, line: line)
            XCTAssertEqual(try month("2026-11").map(\.id), [first.id], line: line)
        }

        try setMode("history/2026-11.json", 0)
        defer { try? setMode("history/2026-11.json", 0o644) }
        try skipUnlessDenied("history/2026-11.json")
        XCTAssertNil(s.finish(note: ""))
        try setMode("history/2026-11.json", 0o644)
        try unchanged()

        try setMode("history", 0o555)
        defer { try? setMode("history", 0o755) }
        try skipUnlessDenied("history", write: true)
        XCTAssertNil(s.finish(note: ""))
        try setMode("history", 0o755)
        try unchanged()

        let w = try XCTUnwrap(s.finish(note: ""))
        XCTAssertEqual(try month("2026-11").map(\.id), [first.id, w.id])
        XCTAssertEqual(s.index.workouts.map(\.id), [first.id, w.id])
        XCTAssertEqual(s.state.firstLegsDay, "2026-11-15")
        XCTAssertNil(s.active)
    }

    /// A running workout that can't be read yet is neither finished nor lost; `refresh()` brings it back.
    func test_finishUnreadableCurrent() throws {
        let s = makeStore()
        s.start(["push"])
        XCTAssertTrue(s.completeNext())
        let running = try XCTUnwrap(s.active)
        let bytes = try Data(contentsOf: url("current.json"))
        try setMode("current.json", 0)
        defer { try? setMode("current.json", 0o644) }
        try skipUnlessDenied("current.json")

        let t = makeStore()
        XCTAssertFalse(t.available)
        XCTAssertNil(t.active)
        XCTAssertNil(t.finish(note: ""))
        XCTAssertFalse(t.completeNext())
        XCTAssertFalse(exists("history/2026-11.json"))
        try setMode("current.json", 0o644)
        XCTAssertEqual(try Data(contentsOf: url("current.json")), bytes)
        XCTAssertFalse(names().contains { $0.contains("corrupt") })

        t.refresh()
        XCTAssertTrue(t.available)
        XCTAssertEqual(t.active, running)
        let w = try XCTUnwrap(t.finish(note: ""))
        XCTAssertEqual(try month("2026-11"), [w])
        XCTAssertEqual(t.index.workouts.map(\.id), [w.id])
    }

    /// After a crash before current.json was gone, finishing again keeps one copy, in the month and in the index.
    func test_finishAgainAfterCrash() throws {
        let s = makeStore()
        s.start(["push"])
        XCTAssertTrue(s.completeNext())
        let current = try Data(contentsOf: url("current.json"))
        let emptyIndex = try Data(contentsOf: url("index.json"))
        let w = try XCTUnwrap(s.finish(note: ""))

        try current.write(to: url("current.json"))
        let again = makeStore()
        XCTAssertEqual(again.active?.workout.id, w.id)
        XCTAssertEqual(again.finish(note: "")?.id, w.id)
        XCTAssertEqual(try month("2026-11").map(\.id), [w.id])
        XCTAssertEqual(again.index.workouts.map(\.id), [w.id])

        // And before index.json was written too.
        try current.write(to: url("current.json"))
        try emptyIndex.write(to: url("index.json"))
        let third = makeStore()
        XCTAssertTrue(third.index.workouts.isEmpty)
        XCTAssertEqual(third.finish(note: "")?.id, w.id)
        XCTAssertEqual(try month("2026-11").map(\.id), [w.id])
        XCTAssertEqual(third.index.workouts.map(\.id), [w.id])
        XCTAssertEqual(makeStore().index, third.index)
    }

    /// Ruling W-22: rewrites run one after the other.
    func test_concurrentDeletes() async throws {
        let s = makeStore()
        let a = try finishOne(s, ["push"], at: at(2026, 11, 10, 18))
        let b = try finishOne(s, ["pull"], at: at(2026, 11, 11, 18))
        let c = try finishOne(s, ["push"], at: at(2026, 11, 13, 18))
        async let first = s.delete(a.id)
        async let second = s.delete(b.id)
        let done = await (first, second)
        XCTAssertTrue(done.0)
        XCTAssertTrue(done.1)
        XCTAssertEqual(try month("2026-11").map(\.id), [c.id])
        XCTAssertEqual(s.index.workouts.map(\.id), [c.id])
        XCTAssertEqual(s.recent.map(\.id), [c.id])
        XCTAssertEqual(makeStore().index, s.index)
    }

    /// Ruling W-22: a finish while a rewrite has read the months waits for its writes, and the rewrite then reads the
    /// files again instead of publishing its older snapshot.
    func test_finishDuringSlowRewrite() async throws {
        let s = makeStore()
        let a = try finishOne(s, ["push"], at: at(2026, 11, 12, 18))
        let b = try finishOne(s, ["pull"], at: at(2026, 11, 13, 18))
        clock.date = at(2026, 11, 15, 18)
        s.start(["push"])
        XCTAssertTrue(s.completeNext())

        let reading = Gate()
        s.rewritePause = {
            reading.set()
            Thread.sleep(forTimeInterval: 0.3)
        }
        let deleting = Task { await s.delete(a.id) }
        while !reading.open { try await Task.sleep(nanoseconds: 5_000_000) }
        let c = try XCTUnwrap(s.finish(note: ""))
        let deleted = await deleting.value
        s.rewritePause = nil
        XCTAssertTrue(deleted)
        XCTAssertEqual(try month("2026-11").map(\.id), [b.id, c.id])
        XCTAssertEqual(s.index.workouts.map(\.id), [b.id, c.id])
        XCTAssertEqual(s.recent.map(\.id), [b.id, c.id])
        XCTAssertEqual(makeStore().index, s.index)
    }

    /// Ruling W-21: update, delete and restore say so when the history can't be read or written.
    func test_rewriteFailsLoudly() async throws {
        let s = makeStore()
        let a = try finishOne(s, ["push"], at: at(2026, 11, 12, 18))
        let b = try finishOne(s, ["pull"], at: at(2026, 11, 13, 18))
        let data = await s.backup()
        var other = try JSONDecoder().decode(WorkoutBackup.self, from: data)
        other.state.settings.restSound = false
        let backup = try XCTUnwrap(WorkoutFiles.encode(other))
        let built = s.index, recent = s.recent, library = s.library, state = s.state
        var edited = a
        edited.note = "Bewerkt"

        try setMode("history/2026-11.json", 0)
        defer { try? setMode("history/2026-11.json", 0o644) }
        try skipUnlessDenied("history/2026-11.json")
        let updated = await s.update(edited)
        XCTAssertFalse(updated)
        let deleted = await s.delete(b.id)
        XCTAssertFalse(deleted)
        do {
            try await s.restore(backup)
            XCTFail("restored")
        } catch {
            XCTAssertEqual(error as? WorkoutStoreError, .notSaved)
        }
        try setMode("history/2026-11.json", 0o644)
        XCTAssertEqual(s.index, built)
        XCTAssertEqual(s.recent, recent)
        XCTAssertEqual(s.library, library)
        XCTAssertEqual(s.state, state)
        XCTAssertEqual(try month("2026-11").map(\.note), ["", ""])

        try setMode("history", 0o555)
        defer { try? setMode("history", 0o755) }
        try skipUnlessDenied("history", write: true)
        let stillThere = await s.delete(b.id)
        XCTAssertFalse(stillThere)
        try setMode("history", 0o755)
        XCTAssertEqual(s.index, built)
        XCTAssertEqual(try month("2026-11").map(\.id), [a.id, b.id])

        let gone = await s.delete(b.id)
        XCTAssertTrue(gone)
        XCTAssertEqual(s.index.workouts.map(\.id), [a.id])
    }

    /// Ruling W-23: values built from the defaults shown before the first unlock are never saved.
    func test_lockedSettersRefused() throws {
        var saved = WorkoutState()
        saved.settings.restSound = false
        try put(saved, "state.json")
        let own = Exercise(id: "custom-band-pull-apart", name: "Band pull-apart", custom: true)
        try put(LibraryFile(exercises: WorkoutProgram.exercises + [own], ladders: WorkoutProgram.ladders), "library.json")
        try put(RoutinesFile(routines: Array(WorkoutProgram.routines.prefix(2))), "routines.json")
        let stateBytes = try Data(contentsOf: url("state.json"))
        let routineBytes = try Data(contentsOf: url("routines.json"))
        try setMode("library.json", 0)
        try setMode("state.json", 0)
        defer {
            try? setMode("library.json", 0o644)
            try? setMode("state.json", 0o644)
        }
        try skipUnlessDenied("library.json")

        let s = makeStore()
        XCTAssertFalse(s.available)
        XCTAssertTrue(s.state.settings.restSound)
        var seeded = s.state.settings
        seeded.keepScreenOn = true
        s.updateSettings(seeded)
        s.saveRoutines(s.routines)
        s.saveExercise(Exercise(id: "pull-up", name: "Pull-up"))
        try setMode("state.json", 0o644)
        XCTAssertEqual(try Data(contentsOf: url("state.json")), stateBytes)
        XCTAssertEqual(try Data(contentsOf: url("routines.json")), routineBytes)

        // Readable again, but this value was built from the defaults: still refused, and the store loads.
        try setMode("library.json", 0o644)
        s.updateSettings(seeded)
        XCTAssertTrue(s.available)
        XCTAssertFalse(s.state.settings.restSound)
        XCTAssertFalse(s.state.settings.keepScreenOn)
        XCTAssertEqual(try Data(contentsOf: url("state.json")), stateBytes)
        XCTAssertEqual(s.routines.count, 2)
        XCTAssertEqual(s.exercise("pull-up")?.primary, [.lats])

        var real = s.state.settings
        real.keepScreenOn = true
        s.updateSettings(real)
        XCTAssertEqual(makeStore().state.settings, real)

        // A new exercise made just as the files become readable gets an id that is free in the real library.
        try setMode("library.json", 0)
        let t = makeStore()
        XCTAssertFalse(t.available)
        try setMode("library.json", 0o644)
        let made = t.newExercise(name: "Band pull-apart", kind: .bodyweight, equipment: .other)
        XCTAssertEqual(made.id, "custom-band-pull-apart-2")
        XCTAssertEqual(makeStore().exercise(made.id), made)
        XCTAssertEqual(makeStore().exercise(own.id), own)
    }

    /// Ruling W-24: records depend on the kind, so a new kind rebuilds the index.
    func test_saveExerciseKindRebuilds() async throws {
        let s = makeStore()
        s.bodyWeight = { _ in 80 }
        try finishIncline(s, 26, 10, at: at(2026, 11, 12, 18))
        XCTAssertEqual(s.index.exercises["incline-db-press"]?.records.heaviest, 26)
        var e = try XCTUnwrap(s.exercise("incline-db-press"))
        e.kind = .weighted
        s.saveExercise(e)
        await s.waitForHistory()
        XCTAssertEqual(s.index.exercises["incline-db-press"]?.records.heaviest, 106)
        XCTAssertEqual(makeStore().index, s.index)
    }

    /// Ruling W-24: a workout that isn't the newest any more (a restore or an import while it ran) rebuilds the index.
    func test_finishOlderThanLastRebuilds() async throws {
        let s = makeStore()
        clock.date = at(2026, 11, 10, 18)
        s.start(["push"])
        let a = try XCTUnwrap(s.active)
        let i = try index(a, "incline-db-press")
        let j = try XCTUnwrap(a.workout.exercises[i].sets.firstIndex { $0.kind != .warmup })
        s.complete(SessionCursor(exercise: i, set: j), kg: 26, reps: 8, seconds: nil)
        let newer = inclinePush(30, 8, at: at(2026, 11, 12, 18))
        let added = await s.update(newer)
        XCTAssertTrue(added)

        clock.date = at(2026, 11, 10, 19)
        let w = try XCTUnwrap(s.finish(note: ""))
        XCTAssertEqual(s.index.workouts.map(\.id), [w.id, newer.id])
        XCTAssertEqual(s.index.exercises["incline-db-press"]?.recent.map(\.day), ["2026-11-10", "2026-11-12"])
        XCTAssertEqual(s.index, WorkoutIndex.build([w, newer], library: s.library))
    }

    /// Ruling W-24: an exercise added during a deload has a third fewer sets too.
    func test_addExerciseDuringDeload() throws {
        let s = makeStore()
        s.startDeload()
        s.start(["push"])
        s.addExercise("lat-pulldown")
        let e = try XCTUnwrap(s.active?.workout.exercises.last)
        XCTAssertEqual(e.exerciseId, "lat-pulldown")
        XCTAssertEqual(e.target?.sets, 2)
        XCTAssertEqual(e.sets.filter { $0.kind != .warmup }.count, 2)
    }
}
