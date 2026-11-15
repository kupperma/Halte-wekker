import Foundation

/// One set of a running workout: the exercise's index in `workout.exercises` and the set's index in its `sets`.
struct SessionCursor: Equatable, Hashable {
    var exercise: Int
    var set: Int
}

/// What a completed set leads to: the "New best" line, if it was one, and the rest that runs now.
struct SetOutcome: Equatable {
    var record: String?
    var rest: RestState?
}

/// Everything planning a workout reads.
struct PlanInput {
    var routines: [Routine]
    var library: [Exercise]
    var ladders: [Ladder]
    var state: WorkoutState
    var index: WorkoutIndex
    var today: DayKey
    var now: Date
    var bodyWeight: Double?
}

/// One exercise in the finish summary: "Pull-up 9 · 9 · 8", "+2 reps", "All sets at 10. Next time 28 kg".
struct FinishLine: Equatable {
    var exerciseId: String
    var text: String
    var change: String?
    var next: String?
}

struct FinishSummary: Equatable {
    var heading: String
    var records: [String]
    var lines: [FinishLine]
}

/// The local notification at the end of a rest.
enum RestAlert {
    static let id = "workout-rest"
}

/// A running workout as a value: planning it, the order of its sets, supersets, rest, records and the summary.
enum Session {
    static let warmupRest = 60

    // MARK: - Planning

    /// The routines one after the other. Optional items, and leg-day-skipped ones on a day with Legs, wait as closed rows.
    static func plan(_ routineIds: [String], _ p: PlanInput) -> ActiveWorkout {
        let legsDay = routineIds.contains("legs")
        var exercises: [LoggedExercise] = []
        var previous: [String: [LoggedSet]] = [:]
        var closed: [ClosedItem] = []
        for (r, id) in routineIds.enumerated() {
            guard let routine = p.routines.first(where: { $0.id == id }) else { continue }
            for item in routine.items {
                guard let planned = resolve(item, p) else { continue }
                var target = planned.target
                if routine.id == "legs", firstLegsWeeks(p) { target.sets = min(target.sets, 2) }
                if p.state.deload.active { target.sets = Deload.sets(target.sets) }

                if item.optional || (item.skipOnLegDays && legsDay) {
                    let reason = item.skipOnLegDays && legsDay ? "Skipped on leg days" : "Optional"
                    closed.append(ClosedItem(id: item.id, routineId: routine.id, exerciseId: planned.exerciseId,
                                             target: target, reason: reason))
                    continue
                }
                var made = makeExercise(exerciseId: planned.exerciseId, ladderId: item.ladderId, routineId: routine.id,
                                        target: target, warmup: item.warmup, p)
                made.exercise.superset = item.superset.map { r * 100 + $0 }
                exercises.append(made.exercise)
                previous[made.exercise.id.uuidString] = made.previous
            }
        }
        let workout = Workout(title: title(routineIds, routines: p.routines), routineIds: routineIds, start: p.now,
                              bodyWeight: p.bodyWeight, deload: p.state.deload.active, exercises: exercises)
        return ActiveWorkout(workout: workout, previous: previous, closed: closed)
    }

    /// One exercise, prefilled with what to lift today, its warm-ups in front. Without `exerciseId` it is the ladder's
    /// current step. `previous` is last time's sets.
    static func makeExercise(exerciseId: String?, ladderId: String?, routineId: String?, target: Target,
                             warmup: [WarmupRamp], _ p: PlanInput) -> (exercise: LoggedExercise, previous: [LoggedSet]) {
        let ladder = ladderId.flatMap { id in p.ladders.first { $0.id == id && !$0.steps.isEmpty } }
        let id = exerciseId ?? ladder.map { $0.steps[Ladders.current($0, state: p.state)].exerciseId } ?? ""
        let exercise = WorkoutProgram.exercise(id, in: p.library)
        let kind = exercise?.kind ?? .weight
        let step = exercise.map { Progression.step($0, settings: p.state.settings) } ?? 2.5
        var rung: (rule: MoveUpRule, isLast: Bool)?
        if let l = ladder, let at = ladderStep(l, exerciseId: id, state: p.state) {
            rung = (l.steps[at].moveUp, at == l.steps.count - 1)
        }

        let previous = Previous.sets(p.index.exercises[id], routineId: routineId)
        let s = Progression.suggest(last: previous, target: target, kind: kind, step: step, ladder: rung,
                                    deload: p.state.deload.active)
        let work = s.values.map { v -> LoggedSet in
            switch kind {
            case .time: return LoggedSet(kind: .normal, kg: s.kg, seconds: v)
            case .cardio: return LoggedSet(kind: .normal)
            default: return LoggedSet(kind: .normal, kg: s.kg, reps: v)
            }
        }
        let sets = Warmup.sets(warmup, workKg: s.kg, step: step) + work
        let logged = LoggedExercise(exerciseId: id, ladderId: ladderId, routineId: routineId, target: target, sets: sets)
        return (logged, previous)
    }

    /// "Pull + legs": the first routine's short name, then the others' in lower case. "Workout" without one.
    static func title(_ routineIds: [String], routines: [Routine]) -> String {
        let names = routineIds.compactMap { id -> String? in
            guard let r = routines.first(where: { $0.id == id }) else { return nil }
            return r.short.isEmpty ? r.name : r.short
        }.filter { !$0.isEmpty }
        guard let first = names.first else { return "Workout" }
        return ([first] + names.dropFirst().map { $0.lowercased() }).joined(separator: " + ")
    }

    // MARK: - The order of the sets

    /// Exercise by exercise, warm-ups first. A superset group goes at its first member's place: all their warm-ups,
    /// then their work sets round by round.
    static func order(_ w: Workout) -> [SessionCursor] {
        var out: [SessionCursor] = []
        var placed = Set<Int>()
        for (i, e) in w.exercises.enumerated() {
            let members: [Int]
            if let g = e.superset {
                guard !placed.contains(g) else { continue }
                placed.insert(g)
                members = w.exercises.indices.filter { w.exercises[$0].superset == g }
            } else {
                members = [i]
            }
            for m in members {
                out += warmups(w.exercises[m]).map { SessionCursor(exercise: m, set: $0) }
            }
            let work = members.map { workSets(w.exercises[$0]) }
            for round in 0..<(work.map(\.count).max() ?? 0) {
                for (k, m) in members.enumerated() where round < work[k].count {
                    out.append(SessionCursor(exercise: m, set: work[k][round]))
                }
            }
        }
        return out
    }

    /// The first undone set. The focused exercise's group goes first while it has one left.
    static func next(_ a: ActiveWorkout) -> SessionCursor? {
        let w = a.workout
        let all = order(w)
        if let f = a.focus, let i = w.exercises.firstIndex(where: { $0.id == f }) {
            let members = group(i, w)
            if let c = all.first(where: { members.contains($0.exercise) && !isDone($0, w) }) { return c }
        }
        return all.first { !isDone($0, w) }
    }

    // MARK: - Completing a set

    /// Marks the set done (nil keeps the prefilled value), ends any rest and starts the next one. A stale or done
    /// cursor changes nothing.
    @discardableResult
    static func complete(_ a: inout ActiveWorkout, _ c: SessionCursor, kg: Double?, reps: Int?, seconds: Int?,
                         index: WorkoutIndex, library: [Exercise], now: Date) -> SetOutcome {
        guard isValid(c, a.workout), !isDone(c, a.workout) else { return SetOutcome(record: nil, rest: a.rest) }
        let id = a.workout.exercises[c.exercise].exerciseId
        let kind = self.kind(id, library)
        var set = a.workout.exercises[c.exercise].sets[c.set]
        if let kg { set.kg = kg }
        if let reps { set.reps = reps }
        if let seconds { set.seconds = seconds }
        set.done = true
        set.doneAt = now

        // Before the set is in: the records with this workout's earlier sets of the exercise added.
        var record: String?
        if var records = index.exercises[id]?.records {
            for e in a.workout.exercises where e.exerciseId == id {
                for s in e.sets where s.counts { records.add(s, kind, bodyWeight: a.workout.bodyWeight) }
            }
            if records.beaten(by: set, kind, bodyWeight: a.workout.bodyWeight) {
                record = "New best: \(WorkoutFormat.set(set, kind))"
            }
        }
        a.workout.exercises[c.exercise].sets[c.set] = set
        if let record { a.lastRecord = record }

        if let f = a.focus {
            if let i = a.workout.exercises.firstIndex(where: { $0.id == f }) {
                if allDone(group(i, a.workout), a.workout) { a.focus = nil }
            } else {
                a.focus = nil
            }
        }

        a.rest = nil
        if let pause = rest(after: c, a.workout), pause > 0 {
            a.rest = RestState(started: now, ends: now.addingTimeInterval(TimeInterval(pause)))
        }
        return SetOutcome(record: record, rest: a.rest)
    }

    /// Moves the end of the rest, never before now.
    static func adjustRest(_ a: inout ActiveWorkout, by seconds: Int, now: Date) {
        guard var r = a.rest else { return }
        r.ends = max(now, r.ends.addingTimeInterval(TimeInterval(seconds)))
        a.rest = r
    }

    /// The rest after a set that was just done: a minute after a warm-up; none on to the next member of a superset;
    /// else the exercise's own (a superset's last member's); none after the very last set.
    private static func rest(after c: SessionCursor, _ w: Workout) -> Int? {
        let all = order(w)
        guard all.contains(where: { !isDone($0, w) }) else { return nil }
        if w.exercises[c.exercise].sets[c.set].kind == .warmup { return warmupRest }
        let members = group(c.exercise, w)
        if let at = all.firstIndex(of: c),
           let n = all[(at + 1)...].first(where: { !isDone($0, w) }),
           let from = members.firstIndex(of: c.exercise), let to = members.firstIndex(of: n.exercise), to > from {
            return nil
        }
        let owner = members.last ?? c.exercise
        return w.exercises[owner].target?.rest
    }

    // MARK: - Lines

    /// Minutes, to the nearest 5: 5 minutes of warming up, 40 s per exercise to set up, and a minute per work set plus
    /// its rest (none for a superset member before the last).
    static func estimate(_ w: Workout) -> Int {
        var seconds = 300 + 40 * w.exercises.count
        for (i, e) in w.exercises.enumerated() {
            let members = group(i, w)
            let rest = members.last == i ? max(0, e.target?.rest ?? 0) : 0
            seconds += workSets(e).count * (60 + rest)
        }
        return Int((Double(seconds) / 300).rounded()) * 5
    }

    /// "9 exercises · 25 sets · about 70 min".
    static func planLine(_ a: ActiveWorkout) -> String {
        let w = a.workout
        let n = w.exercises.count
        let sets = w.exercises.reduce(0) { $0 + workSets($1).count }
        return "\(n == 1 ? "1 exercise" : "\(n) exercises") · \(WorkoutFormat.sets(sets)) · about \(estimate(w)) min"
    }

    /// "Dragon flag · Pull-up · Lat pulldown · Seated cable row (V-grip) · …". A ladder goes by its own name.
    static func namesLine(_ a: ActiveWorkout, library: [Exercise], ladders: [Ladder], max: Int = 4) -> String {
        let names = a.workout.exercises.map { e in
            e.ladderId.flatMap { id in ladders.first { $0.id == id }?.name } ?? name(e.exerciseId, library)
        }
        guard names.count > max else { return names.joined(separator: " · ") }
        return (names.prefix(Swift.max(0, max)) + ["…"]).joined(separator: " · ")
    }

    /// "Set 2 of 3 · 57.5 kg × 8" or "Warm-up 1 of 2 · 14 kg × 8" for the next set; nil when nothing is left.
    static func doneLabel(_ a: ActiveWorkout, library: [Exercise]) -> String? {
        guard let c = next(a) else { return nil }
        let e = a.workout.exercises[c.exercise]
        let p = position(c, a.workout)
        let set = WorkoutFormat.set(e.sets[c.set], kind(e.exerciseId, library))
        return "\(p.warmup ? "Warm-up" : "Set") \(p.number) of \(p.count) · \(set)"
    }

    /// The next set, for the Live Activity; with nothing left, the last done set.
    static func liveState(_ a: ActiveWorkout, library: [Exercise], now: Date) -> WorkoutLiveState {
        let w = a.workout
        let upcoming = next(a)
        var state = WorkoutLiveState(title: w.title, started: w.start, exercise: "", exerciseNumber: 0,
                                     exerciseCount: w.exercises.count, setNumber: 0, setCount: 0, warmup: false,
                                     planned: "", plannedShort: "", last: nil, restStarted: nil, restEnds: nil,
                                     allDone: upcoming == nil)
        if let c = upcoming ?? lastDone(w) {
            let e = w.exercises[c.exercise]
            let kind = self.kind(e.exerciseId, library)
            let set = e.sets[c.set]
            let p = position(c, w)
            state.exercise = name(e.exerciseId, library)
            state.exerciseNumber = c.exercise + 1
            state.setNumber = p.number
            state.setCount = p.count
            state.warmup = p.warmup
            state.planned = WorkoutFormat.set(set, kind)
            state.plannedShort = WorkoutFormat.set(set, kind, .short)
            state.last = Previous.row(a.previous[e.id.uuidString] ?? [], warmup: p.warmup, number: p.number - 1)
                .map { WorkoutFormat.set($0, kind, .short) }
            state.setId = upcoming == nil ? nil : set.id
        }
        if let r = a.rest, r.ends > now {
            state.restStarted = r.started
            state.restEnds = r.ends
        }
        return state.clipped
    }

    // MARK: - Finishing

    /// Only the done sets, and only exercises that have one. nil without a done work set: warm-ups alone are not
    /// saved, so they don't move the rotation.
    static func finished(_ a: ActiveWorkout, end: Date, note: String) -> Workout? {
        var w = a.workout
        w.exercises = w.exercises.compactMap { e in
            var kept = e
            kept.sets = e.sets.filter(\.done)
            return kept.sets.isEmpty ? nil : kept
        }
        guard w.hardSets > 0 else { return nil }
        w.end = end
        w.note = note
        return w
    }

    /// The heading, the new bests against `before` (the index without this workout), and per exercise the change
    /// since last time and what to do next time. A deload compares nothing and suggests nothing.
    static func summary(_ w: Workout, before: WorkoutIndex, library: [Exercise], ladders: [Ladder],
                        state: WorkoutState) -> FinishSummary {
        var heading = [w.title]
        if let end = w.end { heading.append(WorkoutFormat.minutes(w.start, end)) }
        heading.append(WorkoutFormat.sets(w.hardSets))

        // In the order they were done, each against the records so far, as "New best" said it during the workout.
        var done: [(exercise: Int, set: Int, at: Date)] = []
        for (i, e) in w.exercises.enumerated() {
            for (j, s) in e.sets.enumerated() where s.counts { done.append((i, j, s.doneAt ?? .distantFuture)) }
        }
        done.sort { $0.at != $1.at ? $0.at < $1.at : ($0.exercise, $0.set) < ($1.exercise, $1.set) }
        var records: [String] = []
        var running: [String: Records] = [:]
        for d in done {
            let e = w.exercises[d.exercise]
            guard var r = running[e.exerciseId] ?? before.exercises[e.exerciseId]?.records else { continue }
            let kind = self.kind(e.exerciseId, library)
            let s = e.sets[d.set]
            if r.beaten(by: s, kind, bodyWeight: w.bodyWeight) {
                records.append("\(name(e.exerciseId, library)) \(WorkoutFormat.set(s, kind))")
            }
            r.add(s, kind, bodyWeight: w.bodyWeight)
            running[e.exerciseId] = r
        }

        let lines = w.exercises.map { e -> FinishLine in
            let kind = self.kind(e.exerciseId, library)
            let sets = e.sets.filter(\.counts)
            let compact = sets.map { WorkoutFormat.set($0, kind, .compact) }.joined(separator: " · ")
            let name = self.name(e.exerciseId, library)
            var line = FinishLine(exerciseId: e.exerciseId, text: compact.isEmpty ? name : name + " " + compact)
            guard !w.deload, !sets.isEmpty else { return line }
            let last = Previous.sets(before.exercises[e.exerciseId], routineId: e.routineId).filter(\.counts)
            line.change = change(sets, last, kind)
            line.next = next(e, kind: kind, library: library, ladders: ladders, state: state)
            return line
        }
        return FinishSummary(heading: heading.joined(separator: " · "), records: records, lines: lines)
    }

    /// Against last time's counting sets; nil without a last time.
    /// - weight and weighted: "+2 kg" for a heavier top set, else the reps;
    /// - assisted: "2.5 kg less help" / "2.5 kg more help" for the top set (the one with the least help), else the reps;
    /// - time: "+10 s" / "−5 s" for the longest hold, nothing else;
    /// - the reps: "+2 reps" / "−1 rep" for a different total.
    private static func change(_ today: [LoggedSet], _ last: [LoggedSet], _ kind: ExerciseKind) -> String? {
        guard !today.isEmpty, !last.isEmpty else { return nil }
        switch kind {
        case .time:
            guard let now = today.compactMap(\.seconds).max(), let then = last.compactMap(\.seconds).max(),
                  now != then else { return nil }
            return "\(now > then ? "+" : "\u{2212}")\(abs(now - then)) s"
        case .assisted:
            // No kg is no help.
            let now = today.map { $0.kg ?? 0 }.min() ?? 0
            let then = last.map { $0.kg ?? 0 }.min() ?? 0
            if abs(now - then) > 1e-9 {
                return "\(WorkoutFormat.kg(abs(now - then))) kg \(now < then ? "less" : "more") help"
            }
        case .weight, .weighted:
            if let top = today.compactMap(\.kg).max() {
                let before = last.compactMap(\.kg).max() ?? 0
                if top > before + 1e-9 { return "+\(WorkoutFormat.kg(top - before)) kg" }
            }
        case .bodyweight, .cardio:
            break
        }
        let diff = today.reduce(0) { $0 + ($1.reps ?? 0) } - last.reduce(0) { $0 + ($1.reps ?? 0) }
        guard diff != 0 else { return nil }
        let n = abs(diff)
        return "\(diff > 0 ? "+" : "\u{2212}")\(n) \(n == 1 ? "rep" : "reps")"
    }

    /// What today's sets suggest for next time, with the next ladder step's name.
    private static func next(_ e: LoggedExercise, kind: ExerciseKind, library: [Exercise], ladders: [Ladder],
                             state: WorkoutState) -> String? {
        guard let target = e.target else { return nil }
        let step = WorkoutProgram.exercise(e.exerciseId, in: library).map { Progression.step($0, settings: state.settings) } ?? 2.5
        let ladder = e.ladderId.flatMap { id in ladders.first { $0.id == id } }
        let at = ladder.flatMap { ladderStep($0, exerciseId: e.exerciseId, state: state) }
        var info: (rule: MoveUpRule, isLast: Bool)?
        var nextStep: String?
        if let ladder, let at {
            info = (ladder.steps[at].moveUp, at == ladder.steps.count - 1)
            nextStep = at + 1 < ladder.steps.count ? ladder.steps[at + 1].label : nil
        }
        let s = Progression.suggest(last: e.sets, target: target, kind: kind, step: step, ladder: info, deload: false)
        return Progression.nextTime(s, target: target, kind: kind, nextStep: nextStep)
    }

    // MARK: - Helpers

    /// A ladder item's exercise and target: its current step. nil for an item without one.
    private static func resolve(_ item: RoutineItem, _ p: PlanInput) -> (exerciseId: String, target: Target)? {
        if let id = item.ladderId, let ladder = p.ladders.first(where: { $0.id == id }), !ladder.steps.isEmpty {
            let step = ladder.steps[Ladders.current(ladder, state: p.state)]
            return (step.exerciseId, step.target)
        }
        guard let id = item.exerciseId else { return nil }
        return (id, item.target)
    }

    /// Two sets an exercise in Legs during the first two weeks, counted from the first Legs in the app.
    private static func firstLegsWeeks(_ p: PlanInput) -> Bool {
        guard let first = p.state.firstLegsDay else { return true }
        return p.today < RecompCalendar.adding(14, to: first)
    }

    /// The step of the ladder that is this exercise: the current one if it is, else the first that is.
    private static func ladderStep(_ l: Ladder, exerciseId: String, state: WorkoutState) -> Int? {
        guard !l.steps.isEmpty else { return nil }
        let current = Ladders.current(l, state: state)
        if l.steps[current].exerciseId == exerciseId { return current }
        return l.steps.firstIndex { $0.exerciseId == exerciseId }
    }

    /// The exercise's superset group in workout order, or just the exercise.
    private static func group(_ i: Int, _ w: Workout) -> [Int] {
        guard let g = w.exercises[i].superset else { return [i] }
        return w.exercises.indices.filter { w.exercises[$0].superset == g }
    }

    private static func warmups(_ e: LoggedExercise) -> [Int] {
        e.sets.indices.filter { e.sets[$0].kind == .warmup }
    }

    private static func workSets(_ e: LoggedExercise) -> [Int] {
        e.sets.indices.filter { e.sets[$0].kind != .warmup }
    }

    /// 1-based, among the exercise's warm-ups or among its work sets.
    private static func position(_ c: SessionCursor, _ w: Workout) -> (warmup: Bool, number: Int, count: Int) {
        let e = w.exercises[c.exercise]
        let warmup = e.sets[c.set].kind == .warmup
        let same = warmup ? warmups(e) : workSets(e)
        return (warmup, (same.firstIndex(of: c.set) ?? 0) + 1, same.count)
    }

    /// The set done last; on a tie, or without times, the later one in order.
    private static func lastDone(_ w: Workout) -> SessionCursor? {
        var best: (cursor: SessionCursor, at: Date)?
        for c in order(w) {
            let s = w.exercises[c.exercise].sets[c.set]
            guard s.done else { continue }
            let at = s.doneAt ?? .distantPast
            if best.map({ at >= $0.at }) ?? true { best = (c, at) }
        }
        return best?.cursor
    }

    private static func isValid(_ c: SessionCursor, _ w: Workout) -> Bool {
        w.exercises.indices.contains(c.exercise) && w.exercises[c.exercise].sets.indices.contains(c.set)
    }

    private static func isDone(_ c: SessionCursor, _ w: Workout) -> Bool {
        w.exercises[c.exercise].sets[c.set].done
    }

    private static func allDone(_ exercises: [Int], _ w: Workout) -> Bool {
        exercises.allSatisfy { w.exercises[$0].sets.allSatisfy(\.done) }
    }

    private static func kind(_ id: String, _ library: [Exercise]) -> ExerciseKind {
        WorkoutProgram.exercise(id, in: library)?.kind ?? .weight
    }

    private static func name(_ id: String, _ library: [Exercise]) -> String {
        WorkoutProgram.exercise(id, in: library)?.name ?? id
    }
}
