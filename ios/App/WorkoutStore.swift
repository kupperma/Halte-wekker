import Foundation
import Combine

/// Everything a backup holds. Data without `workouts` is not a backup.
struct WorkoutBackup: Codable {
    var version = 1
    var created: Date
    var exercises: [Exercise]
    var ladders: [Ladder]
    var routines: [Routine]
    var state: WorkoutState
    var workouts: [Workout]
}

/// `notSaved`: the history couldn't be read or written (a restore), so the backup is not on the phone.
enum WorkoutStoreError: Error, Equatable { case notABackup, notSaved }

// MARK: - The files

/// What reading one file gave. `corrupt`: it didn't decode, and it was renamed. `unreadable`: it is there but can't be
/// read (the phone hasn't been unlocked since it started), so it is left alone and never written over.
enum FileRead<T> {
    case missing, ok(T), corrupt, unreadable
}

/// The files in Application Support/Workouts. Plain file work, so it also runs off the main actor.
struct WorkoutFiles {
    let root: URL

    var library: URL { root.appendingPathComponent("library.json") }
    var routines: URL { root.appendingPathComponent("routines.json") }
    var state: URL { root.appendingPathComponent("state.json") }
    var current: URL { root.appendingPathComponent("current.json") }
    var index: URL { root.appendingPathComponent("index.json") }
    var history: URL { root.appendingPathComponent("history", isDirectory: true) }

    func month(_ m: String) -> URL { history.appendingPathComponent(m + ".json") }

    func read<T: Decodable>(_ type: T.Type, _ url: URL, stamp: Date) -> FileRead<T> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        if let value = try? JSONDecoder().decode(T.self, from: data) { return .ok(value) }
        // A file that can't be moved aside is left alone, like an unreadable one, so nothing is written over it.
        return keep(url, stamp: stamp) ? .corrupt : .unreadable
    }

    /// Atomic, readable after the first unlock ("Set done" writes while the phone is locked). Creates the folders.
    @discardableResult
    func write<T: Encodable>(_ value: T, to url: URL) -> Bool {
        guard let data = WorkoutFiles.encode(value) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            return false
        }
    }

    func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Renames it to `<stem>.corrupt-<yyyyMMdd-HHmmss>.json` next to it ("-2", "-3" … when that name is taken).
    func keep(_ url: URL, stamp: Date) -> Bool {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyyMMdd-HHmmss"
        let dir = url.deletingLastPathComponent()
        let base = "\(url.deletingPathExtension().lastPathComponent).corrupt-\(f.string(from: stamp))"
        var target = dir.appendingPathComponent(base + ".json")
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = dir.appendingPathComponent("\(base)-\(n).json")
            n += 1
        }
        do {
            try FileManager.default.moveItem(at: url, to: target)
            return true
        } catch {
            return false
        }
    }

    func readMonth(_ m: String, stamp: Date) -> FileRead<[Workout]> {
        switch read(MonthFile.self, month(m), stamp: stamp) {
        case .ok(let file): return .ok(file.workouts)
        case .missing: return .missing
        case .corrupt: return .corrupt
        case .unreadable: return .unreadable
        }
    }

    @discardableResult
    func writeMonth(_ m: String, _ workouts: [Workout]) -> Bool {
        write(MonthFile(month: m, workouts: WorkoutFiles.ordered(workouts)), to: month(m))
    }

    /// index.json, or no index at all when it can't be written: a missing one is rebuilt at the next start, a stale
    /// one would stay.
    func writeIndex(_ value: WorkoutIndex) {
        if !write(value, to: index) { remove(index) }
    }

    /// The index from every month file, written; nil when a month can't be read.
    func rebuildIndex(stamp: Date, library: [Exercise]) -> WorkoutIndex? {
        let all = readAllMonths(stamp: stamp)
        guard all.complete else { return nil }
        let built = WorkoutIndex.build(all.months.values.flatMap { $0 }, library: library)
        writeIndex(built)
        return built
    }

    /// Every month file, changed by `change`: the changed months written, then the index rebuilt from all of them and
    /// written. A month that gains a workout is written before one that only loses some, so a workout that moves is
    /// never in neither. nil, and nothing more written, as soon as a month can't be read or written; after a month
    /// was written, index.json then goes, so the next start rebuilds it from the months. `progress` gets the share of
    /// the changed months written so far, after each one.
    func rewrite(stamp: Date, library: [Exercise], pause: (() -> Void)?, progress: ((Double) -> Void)? = nil,
                 _ change: (inout [String: [Workout]]) -> Void) -> WorkoutIndex? {
        let read = readAllMonths(stamp: stamp)
        guard read.complete else { return nil }
        pause?()
        var changed = read.months
        change(&changed)
        for k in Array(changed.keys) { changed[k] = WorkoutFiles.ordered(changed[k] ?? []) }
        let months = changed
        func onlyLoses(_ k: String) -> Bool {
            Set((months[k] ?? []).map(\.id)).isStrictSubset(of: Set((read.months[k] ?? []).map(\.id)))
        }
        let touched = months.keys.filter { read.months[$0] != months[$0] }.sorted()
        var wrote = 0
        let order = touched.filter({ !onlyLoses($0) }) + touched.filter(onlyLoses)
        for k in order {
            guard writeMonth(k, months[k] ?? []) else {
                if wrote > 0 { remove(index) }
                return nil
            }
            wrote += 1
            progress?(Double(wrote) / Double(order.count))
        }
        let built = WorkoutIndex.build(months.values.flatMap { $0 }, library: library)
        writeIndex(built)
        return built
    }

    /// Every month file. A corrupt one is renamed and skipped; `complete` is false when one couldn't be read.
    func readAllMonths(stamp: Date) -> (months: [String: [Workout]], complete: Bool) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: history.path) else { return ([:], true) }
        guard let names = try? fm.contentsOfDirectory(atPath: history.path) else { return ([:], false) }
        var out: [String: [Workout]] = [:]
        var complete = true
        for name in names.sorted() where WorkoutFiles.isMonth(name) {
            let m = String(name.prefix(7))
            switch readMonth(m, stamp: stamp) {
            case .ok(let list): out[m] = list
            case .missing, .corrupt: break
            case .unreadable: complete = false
            }
        }
        return (out, complete)
    }

    /// "2026-11.json"; not a renamed corrupt one.
    static func isMonth(_ name: String) -> Bool {
        let c = Array(name)
        guard c.count == 12, name.hasSuffix(".json"), c[4] == "-" else { return false }
        return (c[0..<4] + c[5..<7]).allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Oldest first; the same start in id order, as `WorkoutIndex.build` has it.
    static func ordered(_ workouts: [Workout]) -> [Workout] {
        workouts.sorted { a, b in a.start != b.start ? a.start < b.start : a.id.uuidString < b.id.uuidString }
    }

    static func encode<T: Encodable>(_ value: T) -> Data? {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try? e.encode(value)
    }

    /// The months of the 21-day window, today − 20 … today: one or two.
    static func window(today: DayKey) -> [String] {
        let first = String(RecompCalendar.adding(-20, to: today).prefix(7))
        let last = String(today.prefix(7))
        return first == last ? [last] : [first, last]
    }
}

/// One history write at a time: a finish on the main actor, or a rewrite off it.
final class HistoryLock: @unchecked Sendable {
    private let lock = NSLock()

    func run<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// A count made inside a history rewrite, off the main actor, and read after it.
private final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func set(_ n: Int) {
        lock.lock()
        count = n
        lock.unlock()
    }
}

// MARK: - The store

/// The library, the routines, the state, the index and the running workout, in JSON files: one per month for the
/// history. Every action writes only the files it changed.
///
/// A file that exists but can't be read (before the first unlock after a restart) is never renamed or written over:
/// `available` is false and the store saves nothing until `refresh()` (or any action) finds every file readable.
///
/// History rewrites (update, delete, restore, import) run one after the other, off the main actor. A finish takes the
/// same lock for its month, and a rewrite that sees a finish happened while it ran reads the files again rather than
/// publishing its older snapshot.
@MainActor
final class WorkoutStore: ObservableObject {
    static let shared = WorkoutStore()

    nonisolated static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Workouts", isDirectory: true)
    }

    /// The body weight on a day. The app points it at Recomp.
    var bodyWeight: (Date) -> Double? = { _ in nil }

    @Published private(set) var library: [Exercise]
    @Published private(set) var ladders: [Ladder]
    @Published private(set) var routines: [Routine]
    @Published private(set) var state: WorkoutState
    @Published private(set) var index: WorkoutIndex
    @Published private(set) var active: ActiveWorkout?
    /// The workouts of the months that hold today − 20 … today, oldest first.
    @Published private(set) var recent: [Workout]
    /// False while a file can't be read (a start before the first unlock): what was in that file shows the program's
    /// defaults, and nothing is saved.
    @Published private(set) var available: Bool

    /// Tests only: runs inside a history rewrite, right after the months are read.
    var rewritePause: (@Sendable () -> Void)?

    private let files: WorkoutFiles
    private let now: () -> Date
    /// The month files read so far: the recent ones.
    private var months: [String: [Workout]]
    private let historyLock = HistoryLock()
    /// The last history rewrite asked for; each one waits for the one before.
    private var historyTask: Task<Bool, Never>?
    private var pendingRewrites = 0
    /// Bumped by every month write outside a rewrite (a finish), so a rewrite knows its snapshot is older.
    private var generation = 0
    private var locked: Bool { !available }

    init(directory: URL = WorkoutStore.defaultDirectory, now: @escaping () -> Date = Date.init) {
        let files = WorkoutFiles(root: directory)
        let l = Self.load(files, now: now())
        self.files = files
        self.now = now
        self.library = l.library
        self.ladders = l.ladders
        self.routines = l.routines
        self.state = l.state
        self.index = l.index
        self.active = l.active
        self.recent = l.recent
        self.months = l.months
        self.available = !l.locked
    }

    /// Reads every file again when one couldn't be read. The app calls it when it becomes active.
    func refresh() {
        if locked { reload() }
    }

    // MARK: - Reading

    var today: DayKey { RecompCalendar.day(for: now()) }

    var nextUp: NextUp { Rotation.next(Rotation.days(index.workouts), today: today) }

    /// The exercises of the last rotation Push and Pull whose best set fell two sessions running. Sessions on or before
    /// the last deload's day never count (Ruling W-6).
    var flagged: [String] {
        let days = Rotation.days(index.workouts)
        let picked = [days.last { $0.kind == .push }, days.last { $0.kind != .push }].compactMap { $0 }
        var ids: [String] = []
        for d in picked.sorted(by: { $0.start < $1.start }) {
            for w in index.workouts where w.start == d.start && w.day == d.day {
                for id in w.exerciseIds where !ids.contains(id) { ids.append(id) }
            }
        }
        let after = state.deload.lastDay
        return ids.filter { id in index.exercises[id].map { Deload.flagged($0.recent, after: after) } ?? false }
    }

    var deloadLine: DeloadLine? {
        Deload.line(flagNames: flagged.map { exercise($0)?.name ?? $0 }, state: state.deload,
                    firstAppDay: state.firstAppDay, today: today)
    }

    var weeklySets: [SetRow: RowCount] { WeeklySets.count(recent, library: library, today: today) }

    var targets: [SetRow: Int] { WeeklySets.targets(routines, ladders: ladders, state: state, library: library) }

    var bodyWeightNow: Double? { weight(at: now()) }

    /// From Recomp (else the fixed one) or the fixed one, as the settings say.
    private func weight(at date: Date) -> Double? {
        let s = state.settings
        return s.bodyWeightFromRecomp ? bodyWeight(date) ?? s.fixedBodyWeight : s.fixedBodyWeight
    }

    var lastWorkout: WorkoutSummary? { index.workouts.last }

    func exercise(_ id: String) -> Exercise? { WorkoutProgram.exercise(id, in: library) }

    func ladder(_ id: String) -> Ladder? { ladders.first { $0.id == id } }

    func planInput() -> PlanInput {
        PlanInput(routines: routines, library: library, ladders: ladders, state: state, index: index, today: today,
                  now: now(), bodyWeight: bodyWeightNow)
    }

    /// The plan, not saved.
    func preview(_ routineIds: [String]) -> ActiveWorkout { Session.plan(routineIds, planInput()) }

    // MARK: - A running workout (every change writes current.json)

    /// Ignored while one runs.
    func start(_ routineIds: [String]) {
        guard writable(), active == nil else { return }
        active = Session.plan(routineIds, planInput())
        if state.firstAppDay == nil {
            state.firstAppDay = today
            saveState()
        }
        saveCurrent()
    }

    /// The one tap, and "Set done" on the Live Activity. With a `setId` it completes the next set only when that is
    /// the set, so a Live Activity that lags never logs another one (Ruling W-20). False when nothing is left, no
    /// workout runs, or the set isn't the next one.
    @discardableResult
    func completeNext(setId: UUID? = nil) -> Bool {
        guard writable(), var a = active, let c = Session.next(a) else { return false }
        if let setId, a.workout.exercises[c.exercise].sets[c.set].id != setId { return false }
        Session.complete(&a, c, kg: nil, reps: nil, seconds: nil, index: index, library: library, now: now())
        active = a
        saveCurrent()
        return true
    }

    /// nil keeps the planned value.
    func complete(_ c: SessionCursor, kg: Double?, reps: Int?, seconds: Int?) {
        change { a in
            Session.complete(&a, c, kg: kg, reps: reps, seconds: seconds, index: index, library: library, now: now())
        }
    }

    /// Values only: no rest and no record. nil keeps the value there is.
    func edit(_ c: SessionCursor, kg: Double?, reps: Int?, seconds: Int?) {
        change { a in
            guard Self.valid(c, a) else { return }
            if let kg { a.workout.exercises[c.exercise].sets[c.set].kg = kg }
            if let reps { a.workout.exercises[c.exercise].sets[c.set].reps = reps }
            if let seconds { a.workout.exercises[c.exercise].sets[c.set].seconds = seconds }
        }
    }

    /// nil is "as planned"; 4 is "4+".
    func setRIR(_ c: SessionCursor, _ rir: Int?) {
        change { a in
            guard Self.valid(c, a) else { return }
            a.workout.exercises[c.exercise].sets[c.set].rir = rir.map { min(4, max(0, $0)) }
        }
    }

    func setKind(_ c: SessionCursor, _ k: SetKind) {
        change { a in
            guard Self.valid(c, a) else { return }
            a.workout.exercises[c.exercise].sets[c.set].kind = k
        }
    }

    /// A copy of its last set, not done.
    func addSet(exercise i: Int) {
        change { a in
            guard a.workout.exercises.indices.contains(i) else { return }
            var s = a.workout.exercises[i].sets.last ?? LoggedSet()
            s.id = UUID()
            s.done = false
            s.doneAt = nil
            s.rir = nil
            a.workout.exercises[i].sets.append(s)
        }
    }

    func removeSet(_ c: SessionCursor) {
        change { a in
            guard Self.valid(c, a) else { return }
            a.workout.exercises[c.exercise].sets.remove(at: c.set)
        }
    }

    /// At the end, with the target (and warm-ups) of its first place in the routines, else a ladder step's, else
    /// 3 × 8–12 (3 × 20–40 s for a hold, 1 for cardio).
    /// During a deload it has a third fewer sets, as the planned ones.
    func addExercise(_ id: String) {
        let planned = plannedTarget(id)
        var target = planned.target
        if state.deload.active { target.sets = Deload.sets(target.sets) }
        change { a in
            let made = Session.makeExercise(exerciseId: id, ladderId: nil, routineId: nil, target: target,
                                            warmup: planned.warmup, planInput())
            a.workout.exercises.append(made.exercise)
            a.previous[made.exercise.id.uuidString] = made.previous
        }
    }

    /// A closed row ("Optional", "Skipped on leg days") joins the workout after the last exercise of its routine.
    func addClosed(_ itemId: UUID) {
        change { a in
            guard let k = a.closed.firstIndex(where: { $0.id == itemId }) else { return }
            let c = a.closed[k]
            let item = routines.first { $0.id == c.routineId }?.items.first { $0.id == c.id }
            var made = Session.makeExercise(exerciseId: c.exerciseId, ladderId: item?.ladderId, routineId: c.routineId,
                                            target: c.target, warmup: item?.warmup ?? [], planInput())
            if let g = item?.superset, let r = a.workout.routineIds.firstIndex(of: c.routineId) {
                made.exercise.superset = r * 100 + g
            }
            let at = a.workout.exercises.lastIndex { $0.routineId == c.routineId }.map { $0 + 1 }
                ?? a.workout.exercises.count
            a.workout.exercises.insert(made.exercise, at: at)
            a.previous[made.exercise.id.uuidString] = made.previous
            a.closed.remove(at: k)
        }
    }

    func removeExercise(_ i: Int) {
        change { a in
            guard a.workout.exercises.indices.contains(i) else { return }
            let e = a.workout.exercises.remove(at: i)
            a.previous[e.id.uuidString] = nil
            if a.focus == e.id { a.focus = nil }
        }
    }

    /// As SwiftUI's `onMove`: `to` is an offset in the list before the move.
    func moveExercise(from: IndexSet, to: Int) {
        change { a in
            let picked = Array(from).filter { a.workout.exercises.indices.contains($0) }
            guard !picked.isEmpty else { return }
            let moving = picked.map { a.workout.exercises[$0] }
            for i in picked.reversed() { a.workout.exercises.remove(at: i) }
            let at = min(max(0, to), a.workout.exercises.count + picked.count) - picked.filter { $0 < to }.count
            a.workout.exercises.insert(contentsOf: moving, at: min(max(0, at), a.workout.exercises.count))
        }
    }

    /// The done sets stay on the old exercise and the new one follows with the sets that are left; with none done it
    /// takes its place. It stays on the ladder (with that step's target) only when it is one of the ladder's steps.
    func replaceExercise(_ i: Int, with id: String) {
        change { a in
            guard a.workout.exercises.indices.contains(i) else { return }
            let old = a.workout.exercises[i]
            let kept = old.sets.filter(\.done)
            let left = old.sets.filter { !$0.done && $0.kind != .warmup }.count
            let step = old.ladderId.flatMap { ladder($0) }?.steps.first { $0.exerciseId == id }
            var target = step?.target ?? old.target ?? plannedTarget(id).target
            target.sets = max(1, left)
            let warmup = kept.isEmpty && old.sets.contains(where: { $0.kind == .warmup }) ? routineWarmup(old) : []
            var made = Session.makeExercise(exerciseId: id, ladderId: step == nil ? nil : old.ladderId,
                                            routineId: old.routineId, target: target, warmup: warmup, planInput())
            made.exercise.superset = old.superset
            made.exercise.note = kept.isEmpty ? old.note : ""
            a.previous[made.exercise.id.uuidString] = made.previous
            if kept.isEmpty {
                a.previous[old.id.uuidString] = nil
                a.workout.exercises[i] = made.exercise
            } else {
                a.workout.exercises[i].sets = kept
                a.workout.exercises.insert(made.exercise, at: i + 1)
            }
            if a.focus == old.id { a.focus = made.exercise.id }
        }
    }

    func setExerciseNote(_ i: Int, _ note: String) {
        change { a in
            guard a.workout.exercises.indices.contains(i) else { return }
            a.workout.exercises[i].note = note
        }
    }

    /// nil: back to the set order.
    func focus(_ i: Int?) {
        change { a in
            a.focus = i.flatMap { a.workout.exercises.indices.contains($0) ? a.workout.exercises[$0].id : nil }
        }
    }

    func adjustRest(by seconds: Int) {
        change { a in Session.adjustRest(&a, by: seconds, now: now()) }
    }

    func skipRest() {
        change { a in a.rest = nil }
    }

    /// Saves the done sets: the month file, the index and the state, and current.json goes. nil when no hard set is
    /// done (Ruling W-19), or when the month can't be read or written: then nothing else is touched and the workout
    /// keeps running, current.json as it was.
    @discardableResult
    func finish(note: String, end: Date? = nil) -> Workout? {
        guard writable(), let a = active, let w = Session.finished(a, end: end ?? now(), note: note) else { return nil }
        let m = w.month, stamp = now(), files = self.files, library = self.library
        // Built again from the files when the workout can't simply go at the end: saved already (a crash before
        // current.json went), not the newest (an import or restore while it ran), or a rewrite still running.
        let rebuild = pendingRewrites > 0 || index.workouts.contains { $0.id == w.id }
            || index.workouts.last.map { w.start <= $0.start } == true
        var next = index
        // The month is read again rather than taken from memory: a rewrite may just have changed it.
        let saved: [Workout]? = historyLock.run {
            var list: [Workout]
            switch files.readMonth(m, stamp: stamp) {
            case .ok(let l): list = l
            case .missing, .corrupt: list = []
            case .unreadable: return nil
            }
            // The same id again only after a crash before current.json was gone: it replaces the first.
            list.removeAll { $0.id == w.id }
            list.append(w)
            guard files.writeMonth(m, list) else { return nil }
            if rebuild, let built = files.rebuildIndex(stamp: stamp, library: library) {
                next = built
            } else {
                next.add(w, library: library)
                files.writeIndex(next)
            }
            return WorkoutFiles.ordered(list)
        }
        guard let saved else { return nil }
        generation += 1
        index = next
        months[m] = saved

        if w.routineIds.contains("legs"), state.firstLegsDay == nil { state.firstLegsDay = w.day }
        if state.deload.active { Deload.finished(&state.deload, routineIds: w.routineIds, day: w.day) }
        saveState()

        active = nil
        files.remove(files.current)
        publishRecent()
        return w
    }

    func discard() {
        guard writable() else { return }
        active = nil
        files.remove(files.current)
    }

    // MARK: - Between workouts

    func workouts(month: String) async -> [Workout] {
        let files = self.files, stamp = now()
        return await Task.detached(priority: .userInitiated) { () -> [Workout] in
            if case .ok(let list) = files.readMonth(month, stamp: stamp) { return WorkoutFiles.ordered(list) }
            return []
        }.value
    }

    /// Oldest first.
    func allWorkouts() async -> [Workout] {
        let files = self.files, stamp = now()
        return await Task.detached(priority: .userInitiated) {
            WorkoutFiles.ordered(files.readAllMonths(stamp: stamp).months.values.flatMap { $0 })
        }.value
    }

    /// Replaces the workout with the same id (it may move to another month), then rebuilds the index. False when the
    /// history couldn't be read or written: the index and the screens stay as they were.
    @discardableResult
    func update(_ w: Workout) async -> Bool {
        let m = w.month
        return await rewriteHistory { months in
            for k in Array(months.keys) { months[k]?.removeAll { $0.id == w.id } }
            months[m, default: []].append(w)
        }
    }

    /// Then rebuilds the index, so no record or "last time" points at it any more. False as for `update`.
    @discardableResult
    func delete(_ id: UUID) async -> Bool {
        await rewriteHistory { months in
            for k in Array(months.keys) { months[k]?.removeAll { $0.id == id } }
        }
    }

    /// A new routine with the workout's exercises, in order, each with its target (or one made from its sets).
    func saveAsRoutine(_ w: Workout, name: String) {
        guard writable() else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? w.title : trimmed
        let slug = WorkoutProgram.slug(title)
        let id = Self.unique("routine-" + (slug.isEmpty ? "custom" : slug), taken: Set(routines.map(\.id)))
        let items = w.exercises.filter { !$0.exerciseId.isEmpty }.map { e -> RoutineItem in
            let target = e.target ?? Self.target(from: e.sets, kind: exercise(e.exerciseId)?.kind ?? .weight)
            if let l = e.ladderId, ladder(l) != nil {
                return RoutineItem(ladderId: l, target: target, superset: e.superset)
            }
            return RoutineItem(exerciseId: e.exerciseId, target: target, superset: e.superset)
        }
        routines.append(Routine(id: id, name: title, short: title, items: items))
        saveRoutineFile()
    }

    func moveUp(_ ladderId: String) {
        guard writable(), let l = ladder(ladderId) else { return }
        Ladders.moveUp(l, state: &state)
        saveState()
    }

    func stepBack(_ ladderId: String) {
        guard writable(), let l = ladder(ladderId) else { return }
        Ladders.stepBack(l, state: &state)
        saveState()
    }

    func startDeload() {
        guard writable() else { return }
        Deload.start(&state.deload)
        saveState()
    }

    func cancelDeload() {
        guard writable() else { return }
        state.deload.active = false
        state.deload.left = []
        saveState()
    }

    /// "Not yet": a week.
    func snoozeDeload() {
        guard writable() else { return }
        Deload.snooze(&state.deload, today: today)
        saveState()
    }

    /// Refused while the store shows defaults: the routines handed in were built from them.
    func saveRoutines(_ r: [Routine]) {
        guard writableWithRealData() else { return }
        routines = r
        saveRoutineFile()
    }

    /// Replaces the exercise with its id, or adds it. Records and session bests depend on its kind, so a new kind
    /// rebuilds the index. Refused while the store shows defaults.
    func saveExercise(_ e: Exercise) {
        guard writableWithRealData() else { return }
        let kindChanged = exercise(e.id).map { $0.kind != e.kind } ?? false
        if let i = library.firstIndex(where: { $0.id == e.id }) {
            library[i] = e
        } else {
            library.append(e)
        }
        saveLibrary()
        if kindChanged { scheduleRewrite { _ in } }
    }

    /// A custom exercise with id "custom-" + slug(name), "-2", "-3" … when that is taken.
    func newExercise(name: String, kind: ExerciseKind, equipment: Equipment) -> Exercise {
        // First, so the id is unique in the real library.
        let ok = writable()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = WorkoutProgram.slug(trimmed)
        let id = Self.unique("custom-" + (slug.isEmpty ? "exercise" : slug), taken: Set(library.map(\.id)))
        let e = Exercise(id: id, name: trimmed.isEmpty ? "Exercise" : trimmed, equipment: equipment, kind: kind,
                         custom: true)
        guard ok else { return e }
        library.append(e)
        saveLibrary()
        return e
    }

    /// Refused while the store shows defaults: the settings handed in were built from them.
    func updateSettings(_ s: WorkoutSettings) {
        guard writableWithRealData() else { return }
        state.settings = s
        saveState()
    }

    /// The library, the routines, the state and every workout, as JSON.
    func backup() async -> Data {
        let files = self.files, stamp = now()
        let head = WorkoutBackup(created: stamp, exercises: library, ladders: ladders, routines: routines, state: state,
                                 workouts: [])
        return await Task.detached(priority: .userInitiated) { () -> Data in
            var b = head
            b.workouts = WorkoutFiles.ordered(files.readAllMonths(stamp: stamp).months.values.flatMap { $0 })
            return WorkoutFiles.encode(b) ?? Data()
        }.value
    }

    /// Adds the backup's workouts (one with the same id is replaced; nothing is deleted) and takes its exercises,
    /// ladders, routines and state. The running workout stays as it is. Throws `.notSaved` when the history can't be
    /// read or written; then the library, routines and state stay as they were.
    func restore(_ data: Data) async throws {
        let b = try await Task.detached(priority: .userInitiated) { () throws -> WorkoutBackup in
            do {
                return try JSONDecoder().decode(WorkoutBackup.self, from: data)
            } catch {
                throw WorkoutStoreError.notABackup
            }
        }.value
        guard writable() else { throw WorkoutStoreError.notSaved }
        // Exercises and ladders only on this phone stay, because workouts here may use them.
        let exerciseIds = Set(b.exercises.map(\.id))
        let newLibrary = b.exercises + library.filter { !exerciseIds.contains($0.id) }
        let ladderIds = Set(b.ladders.map(\.id))
        let newLadders = b.ladders + ladders.filter { !ladderIds.contains($0.id) }
        let incoming = b.workouts
        let merged = await rewriteHistory(library: newLibrary) { months in
            let ids = Set(incoming.map(\.id))
            for k in Array(months.keys) { months[k]?.removeAll { ids.contains($0.id) } }
            for w in incoming { months[w.month, default: []].append(w) }
        }
        guard merged else { throw WorkoutStoreError.notSaved }
        library = newLibrary
        ladders = newLadders
        routines = b.routines
        state = b.state
        let saved = [saveLibrary(), saveRoutineFile(), saveState()]
        guard !saved.contains(false) else { throw WorkoutStoreError.notSaved }
    }

    /// Builds the file's new workouts (`HevyCSV.workouts`, against the index), each with the body weight on its start
    /// (Recomp's, else the fixed one, as for `bodyWeightNow`), and first adds the exercises kept as is to the library. Then one history rewrite, after the ones asked for
    /// before it: it checks again against the months as they are then (a Hevy key or id already there, or a start
    /// during an app workout there), so a file imported twice at once still adds each workout once, writes the months
    /// that gain workouts with `progress` after each (on the main actor), and rebuilds the index. The state, and so
    /// `firstAppDay`, is never touched. Returns how many workouts were added. Throws `.notSaved` when the library or
    /// the history can't be read or written: then the index and `recent` stay as they were, and importing the file
    /// again adds only what isn't in the months yet.
    func importHevy(_ f: HevyFile, choices: HevyChoices,
                    progress: @escaping (Double) -> Void = { _ in }) async throws -> Int {
        guard writable() else { throw WorkoutStoreError.notSaved }
        let made = HevyCSV.workouts(f, library: library, existing: index.workouts, choices: choices)
        guard !made.workouts.isEmpty else { return 0 }
        var incoming = made.workouts
        for i in incoming.indices { incoming[i].bodyWeight = weight(at: incoming[i].start) }
        let have = Set(library.map(\.id))
        let extra = made.newExercises.filter { !have.contains($0.id) }
        if !extra.isEmpty {
            let before = library
            library = before + extra
            guard saveLibrary() else {
                library = before
                throw WorkoutStoreError.notSaved
            }
        }
        let built = incoming, added = Tally()
        let (stream, sink) = AsyncStream.makeStream(of: Double.self)
        let task = scheduleRewrite(library: library, progress: { sink.yield($0) }) { months in
            let present = months.values.flatMap { $0 }.map { WorkoutSummary($0) }
            let fresh = HevyCSV.unseen(built, existing: present)
            for w in fresh { months[w.month, default: []].append(w) }
            added.set(fresh.count)
        }
        Task {
            _ = await task.value
            sink.finish()
        }
        // On the main actor, as the rewrite writes each month.
        for await share in stream { progress(share) }
        guard await task.value else { throw WorkoutStoreError.notSaved }
        return added.value
    }

    /// Waits until the history rewrites asked for so far are done.
    func waitForHistory() async {
        while let t = historyTask {
            _ = await t.value
            if historyTask == t { return }
        }
    }

    // MARK: - Helpers

    /// Changes the running workout, and writes current.json when something changed.
    private func change(_ body: (inout ActiveWorkout) -> Void) {
        guard writable(), var a = active else { return }
        let before = a
        body(&a)
        guard a != before else { return }
        active = a
        saveCurrent()
    }

    /// A history rewrite (`WorkoutFiles.rewrite`), after the ones asked for before it. False when the history couldn't
    /// be read or written: then the index and `recent` stay as they were.
    @discardableResult
    private func rewriteHistory(library lib: [Exercise]? = nil,
                                _ change: @escaping @Sendable (inout [String: [Workout]]) -> Void) async -> Bool {
        await scheduleRewrite(library: lib, change).value
    }

    /// `progress` runs off the main actor, after each month written.
    @discardableResult
    private func scheduleRewrite(library lib: [Exercise]? = nil, progress: (@Sendable (Double) -> Void)? = nil,
                                 _ change: @escaping @Sendable (inout [String: [Workout]]) -> Void) -> Task<Bool, Never> {
        let previous = historyTask
        pendingRewrites += 1
        let task = Task { () -> Bool in
            _ = await previous?.value
            let ok = await self.performRewrite(library: lib, progress: progress, change)
            self.pendingRewrites -= 1
            return ok
        }
        historyTask = task
        return task
    }

    private func performRewrite(library lib: [Exercise]?, progress: (@Sendable (Double) -> Void)?,
                                _ change: @escaping @Sendable (inout [String: [Workout]]) -> Void) async -> Bool {
        guard writable() else { return false }
        let files = self.files, stamp = now(), library = lib ?? self.library
        let lock = historyLock, pause = rewritePause
        var seen = generation
        let written = await Task.detached(priority: .userInitiated) { () -> WorkoutIndex? in
            lock.run { files.rewrite(stamp: stamp, library: library, pause: pause, progress: progress, change) }
        }.value
        guard written != nil else { return false }
        // A finish wrote a month meanwhile, so this snapshot is older than the files: they are read again. If that
        // fails, the index the finish made stays.
        var newest = written
        while generation != seen, newest != nil {
            seen = generation
            newest = await Task.detached(priority: .userInitiated) { () -> WorkoutIndex? in
                lock.run { files.rebuildIndex(stamp: stamp, library: library) }
            }.value
        }
        if let newest { index = newest }
        months = [:]
        publishRecent()
        return true
    }

    /// Reads the months of the window that aren't read yet, and forgets the others.
    private func publishRecent() {
        let wanted = WorkoutFiles.window(today: today)
        for m in wanted where months[m] == nil {
            switch files.readMonth(m, stamp: now()) {
            case .ok(let list): months[m] = WorkoutFiles.ordered(list)
            case .missing, .corrupt: months[m] = []
            case .unreadable: break
            }
        }
        months = months.filter { wanted.contains($0.key) }
        recent = WorkoutFiles.ordered(wanted.flatMap { months[$0] ?? [] })
    }

    /// After a start before the first unlock, the files are read again as soon as they can be.
    private func writable() -> Bool {
        refresh()
        return !locked
    }

    /// For a setter handed a whole value built from what the store showed: refused when the store showed defaults as
    /// the call came, even if the files can be read now.
    private func writableWithRealData() -> Bool {
        let wasLocked = locked
        return writable() && !wasLocked
    }

    private func reload() {
        let l = Self.load(files, now: now())
        library = l.library
        ladders = l.ladders
        routines = l.routines
        state = l.state
        index = l.index
        active = l.active
        recent = l.recent
        months = l.months
        available = !l.locked
    }

    @discardableResult
    private func saveLibrary() -> Bool { files.write(LibraryFile(exercises: library, ladders: ladders), to: files.library) }
    @discardableResult
    private func saveRoutineFile() -> Bool { files.write(RoutinesFile(routines: routines), to: files.routines) }
    @discardableResult
    private func saveState() -> Bool { files.write(state, to: files.state) }

    private func saveCurrent() {
        if let a = active {
            files.write(a, to: files.current)
        } else {
            files.remove(files.current)
        }
    }

    private static func valid(_ c: SessionCursor, _ a: ActiveWorkout) -> Bool {
        a.workout.exercises.indices.contains(c.exercise) && a.workout.exercises[c.exercise].sets.indices.contains(c.set)
    }

    /// Its first place in the routines (with the warm-ups there), else a ladder step's target, else by kind.
    private func plannedTarget(_ id: String) -> (target: Target, warmup: [WarmupRamp]) {
        for r in routines {
            if let item = r.items.first(where: { $0.exerciseId == id }) { return (item.target, item.warmup) }
        }
        for l in ladders {
            if let step = l.steps.first(where: { $0.exerciseId == id }) { return (step.target, []) }
        }
        switch exercise(id)?.kind ?? .weight {
        case .time: return (Target(sets: 3, lo: 20, hi: 40, rest: 120), [])
        case .cardio: return (Target(sets: 1, lo: 1, hi: 1, rest: 0), [])
        default: return (Target(sets: 3, lo: 8, hi: 12, rest: 120), [])
        }
    }

    /// The warm-ups of the routine item the exercise came from.
    private func routineWarmup(_ e: LoggedExercise) -> [WarmupRamp] {
        guard let r = routines.first(where: { $0.id == e.routineId }) else { return [] }
        let item = r.items.first { item in
            if let l = e.ladderId { return item.ladderId == l }
            return item.exerciseId == e.exerciseId
        }
        return item?.warmup ?? []
    }

    /// For a saved routine from a workout without targets (an import): its work sets, their lowest and highest reps
    /// (seconds for a hold), and 2:00 rest.
    private static func target(from sets: [LoggedSet], kind: ExerciseKind) -> Target {
        let work = sets.filter { $0.kind != .warmup }
        let values = work.compactMap { kind == .time ? $0.seconds : $0.reps }
        return Target(sets: max(1, work.count), lo: values.min() ?? 8, hi: values.max() ?? 12, rest: 120)
    }

    private static func unique(_ base: String, taken: Set<String>) -> String {
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    // MARK: - Loading

    private struct Loaded {
        var library: [Exercise]
        var ladders: [Ladder]
        var routines: [Routine]
        var state: WorkoutState
        var index: WorkoutIndex
        var active: ActiveWorkout?
        var recent: [Workout]
        var months: [String: [Workout]]
        var locked: Bool
    }

    /// Reads every file. A missing or corrupt library, routines or state file is seeded and written; seed exercises and
    /// ladders missing from a saved library are added. A missing, corrupt or older index is rebuilt from the months and
    /// written. Nothing is written when any file can't be read.
    private static func load(_ files: WorkoutFiles, now: Date) -> Loaded {
        var locked = false

        var exercises = WorkoutProgram.exercises
        var ladders = WorkoutProgram.ladders
        var writeLibrary = false
        switch files.read(LibraryFile.self, files.library, stamp: now) {
        case .ok(let f):
            let haveExercises = Set(f.exercises.map(\.id))
            let haveLadders = Set(f.ladders.map(\.id))
            let newExercises = WorkoutProgram.exercises.filter { !haveExercises.contains($0.id) }
            let newLadders = WorkoutProgram.ladders.filter { !haveLadders.contains($0.id) }
            exercises = f.exercises + newExercises
            ladders = f.ladders + newLadders
            writeLibrary = !newExercises.isEmpty || !newLadders.isEmpty
        case .missing, .corrupt: writeLibrary = true
        case .unreadable: locked = true
        }

        var routines = WorkoutProgram.routines
        var writeRoutines = false
        switch files.read(RoutinesFile.self, files.routines, stamp: now) {
        case .ok(let f): routines = f.routines
        case .missing, .corrupt: writeRoutines = true
        case .unreadable: locked = true
        }

        var state = WorkoutState()
        var writeState = false
        switch files.read(WorkoutState.self, files.state, stamp: now) {
        case .ok(let s): state = s
        case .missing, .corrupt: writeState = true
        case .unreadable: locked = true
        }

        var index = WorkoutIndex()
        var all: [String: [Workout]]?
        switch files.read(WorkoutIndex.self, files.index, stamp: now) {
        case .ok(let i) where i.version >= WorkoutIndex().version:
            index = i
        case .unreadable:
            locked = true
        default:
            let read = files.readAllMonths(stamp: now)
            if !read.complete { locked = true }
            index = WorkoutIndex.build(read.months.values.flatMap { $0 }, library: exercises)
            all = read.months
        }

        var active: ActiveWorkout?
        switch files.read(ActiveWorkout.self, files.current, stamp: now) {
        case .ok(var a):
            if let r = a.rest, r.ends < now { a.rest = nil }
            active = a
        case .unreadable: locked = true
        case .missing, .corrupt: break
        }

        let wanted = WorkoutFiles.window(today: RecompCalendar.day(for: now))
        var months: [String: [Workout]] = [:]
        for m in wanted {
            if let list = all?[m] {
                months[m] = WorkoutFiles.ordered(list)
                continue
            }
            switch files.readMonth(m, stamp: now) {
            case .ok(let list): months[m] = WorkoutFiles.ordered(list)
            case .missing, .corrupt: months[m] = []
            case .unreadable: locked = true
            }
        }

        if !locked {
            if writeLibrary { files.write(LibraryFile(exercises: exercises, ladders: ladders), to: files.library) }
            if writeRoutines { files.write(RoutinesFile(routines: routines), to: files.routines) }
            if writeState { files.write(state, to: files.state) }
            if all != nil { files.writeIndex(index) }
        }
        return Loaded(library: exercises, ladders: ladders, routines: routines, state: state, index: index,
                      active: active, recent: WorkoutFiles.ordered(wanted.flatMap { months[$0] ?? [] }),
                      months: months, locked: locked)
    }
}

// MARK: - Tolerant decoding

private struct StoreKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

extension WorkoutBackup {
    /// Every field but `workouts` falls back to a default: the program's library, ladders and routines, a new state.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: StoreKey.self)
        func get<T: Decodable>(_ key: String, _ fallback: T) throws -> T {
            try c.decodeIfPresent(T.self, forKey: StoreKey(key)) ?? fallback
        }
        version = try get("version", 1)
        created = try get("created", Date(timeIntervalSince1970: 0))
        exercises = try get("exercises", WorkoutProgram.exercises)
        ladders = try get("ladders", WorkoutProgram.ladders)
        routines = try get("routines", WorkoutProgram.routines)
        state = try get("state", WorkoutState())
        workouts = try c.decode([Workout].self, forKey: StoreKey("workouts"))
    }
}
