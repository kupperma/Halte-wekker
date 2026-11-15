import Foundation

// MARK: - Loads

/// Kilos only. A dumbbell weight is per hand, and so is everything worked out from it.
enum Lifts {
    /// What was lifted. weight: kg; weighted: bw + extra; assisted: bw − help; bodyweight: bw; time and cardio: nil.
    /// nil when the body weight is needed but missing.
    static func load(_ s: LoggedSet, _ kind: ExerciseKind, bodyWeight: Double?) -> Double? {
        switch kind {
        case .weight:
            return s.kg
        case .weighted:
            guard let bw = bodyWeight else { return nil }
            return bw + (s.kg ?? 0)
        case .assisted:
            guard let bw = bodyWeight else { return nil }
            return max(0, bw - (s.kg ?? 0))
        case .bodyweight:
            return bodyWeight
        case .time, .cardio:
            return nil
        }
    }

    /// Epley. One rep is the load itself.
    static func e1rm(load: Double, reps: Int) -> Double {
        reps <= 1 ? load : load * (1 + Double(reps) / 30)
    }

    /// Σ kg × reps of the counting sets. Only for weight and weighted, where it is the extra weight (as in Hevy); else 0.
    static func volume(_ sets: [LoggedSet], _ kind: ExerciseKind) -> Double {
        guard kind == .weight || kind == .weighted else { return 0 }
        return sets.filter(\.counts).reduce(0) { $0 + ($1.kg ?? 0) * Double($1.reps ?? 0) }
    }

    /// The session's best counting set: the best e1RM for weight, weighted and assisted; else the most reps (bodyweight,
    /// or no body weight); else the longest.
    static func sessionBest(_ sets: [LoggedSet], _ kind: ExerciseKind, bodyWeight: Double?) -> Double? {
        let counting = sets.filter(\.counts)
        let lifts = counting.compactMap { lift($0, kind, bodyWeight: bodyWeight) }
        if let best = lifts.map({ e1rm(load: $0.load, reps: $0.reps) }).max() { return best }
        if let reps = counting.compactMap(\.reps).filter({ $0 > 0 }).max() { return Double(reps) }
        if let seconds = counting.compactMap(\.seconds).filter({ $0 > 0 }).max() { return Double(seconds) }
        return nil
    }

    /// The Recomp week average ending that day; else the weigh-in nearest to it (the earlier one on a tie).
    static func bodyWeight(on day: DayKey, weights: [Measure]) -> Double? {
        if let average = WeightMath.weekAverage(weights, endingOn: day) { return average }
        let nearest = weights.min { a, b in
            let da = abs(RecompCalendar.daysBetween(a.day, day))
            let db = abs(RecompCalendar.daysBetween(b.day, day))
            return da != db ? da < db : a.day < b.day
        }
        return nearest?.value
    }

    /// Load and reps of a set that lifted something: weight, weighted and assisted, with at least 1 rep.
    fileprivate static func lift(_ s: LoggedSet, _ kind: ExerciseKind, bodyWeight: Double?) -> (load: Double, reps: Int)? {
        guard kind == .weight || kind == .weighted || kind == .assisted,
              let reps = s.reps, reps > 0,
              let l = load(s, kind, bodyWeight: bodyWeight) else { return nil }
        return (l, reps)
    }
}

// MARK: - Records

/// An exercise's records over all its counting sets. bestSet is kg × reps (extra weight for weighted, like volume).
struct Records: Codable, Equatable {
    var heaviest: Double? = nil
    var e1rm: Double? = nil
    var bestSet: Double? = nil
    var mostReps: Int? = nil
    var longest: Int? = nil
    /// "8" → the heaviest load at exactly 8 reps.
    var byReps: [String: Double] = [:]

    /// Counting sets only.
    mutating func add(_ s: LoggedSet, _ kind: ExerciseKind, bodyWeight: Double?) {
        guard s.counts else { return }
        if let lift = Lifts.lift(s, kind, bodyWeight: bodyWeight) {
            heaviest = max(heaviest ?? lift.load, lift.load)
            let e = Lifts.e1rm(load: lift.load, reps: lift.reps)
            e1rm = max(e1rm ?? e, e)
            let key = String(lift.reps)
            byReps[key] = max(byReps[key] ?? lift.load, lift.load)
        }
        if kind == .weight || kind == .weighted, let kg = s.kg, let reps = s.reps, reps > 0 {
            let v = kg * Double(reps)
            if v > 0 { bestSet = max(bestSet ?? v, v) }
        }
        if let reps = s.reps, reps > 0 { mostReps = max(mostReps ?? reps, reps) }
        if let seconds = s.seconds, seconds > 0 { longest = max(longest ?? seconds, seconds) }
    }

    /// A higher e1RM or a heavier load (weight, weighted, assisted), else more reps, else longer.
    /// False when there is nothing to beat yet, and for a warm-up.
    func beaten(by s: LoggedSet, _ kind: ExerciseKind, bodyWeight: Double?) -> Bool {
        guard s.kind != .warmup else { return false }
        let margin = 1e-9
        if let lift = Lifts.lift(s, kind, bodyWeight: bodyWeight), e1rm != nil || heaviest != nil {
            if let best = e1rm, Lifts.e1rm(load: lift.load, reps: lift.reps) > best + margin { return true }
            if let top = heaviest, lift.load > top + margin { return true }
            return false
        }
        if let reps = s.reps, reps > 0, let most = mostReps { return reps > most }
        if let seconds = s.seconds, seconds > 0, let long = longest { return seconds > long }
        return false
    }
}

// MARK: - The index

/// One workout's done sets of one exercise, warm-ups included.
struct Performance: Codable, Equatable {
    var workoutId: UUID
    var start: Date
    var sets: [LoggedSet]
}

struct ExerciseIndex: Codable, Equatable {
    var last: Performance? = nil
    /// Routine id → the last time in that routine.
    var lastByRoutine: [String: Performance] = [:]
    /// Newest last, at most 3. Deload workouts are left out.
    var recent: [SessionBest] = []
    var records = Records()
    /// Workouts with a counting set of this exercise, deloads included.
    var sessions = 0
}

/// What the app reads on launch: per exercise the last time and the records, and every workout's summary.
/// It can always be rebuilt from the month files.
struct WorkoutIndex: Codable, Equatable {
    var version = 1
    var exercises: [String: ExerciseIndex] = [:]
    /// Oldest first.
    var workouts: [WorkoutSummary] = []

    static func build(_ workouts: [Workout], library: [Exercise]) -> WorkoutIndex {
        let sorted = workouts.sorted { a, b in
            a.start != b.start ? a.start < b.start : a.id.uuidString < b.id.uuidString
        }
        var index = WorkoutIndex()
        for w in sorted { index.add(w, library: library) }
        return index
    }

    /// The same result as `build`, for a workout newer than all the others.
    mutating func add(_ w: Workout, library: [Exercise]) {
        let at = workouts.lastIndex { $0.start <= w.start }.map { $0 + 1 } ?? 0
        workouts.insert(WorkoutSummary(w), at: at)

        // The same exercise can be in a workout more than once: its sets go together, in order.
        var ids: [String] = []
        var groups: [String: [LoggedExercise]] = [:]
        for e in w.exercises {
            if groups[e.exerciseId] == nil { ids.append(e.exerciseId) }
            groups[e.exerciseId, default: []].append(e)
        }
        for id in ids {
            let items = groups[id] ?? []
            let all = items.flatMap(\.sets)
            guard all.contains(where: \.counts) else { continue }
            let kind = WorkoutProgram.exercise(id, in: library)?.kind ?? .weight
            var x = exercises[id] ?? ExerciseIndex()

            if x.last.map({ $0.start <= w.start }) ?? true {
                x.last = Performance(workoutId: w.id, start: w.start, sets: all.filter(\.done))
            }
            var routineIds: [String] = []
            for r in items.compactMap(\.routineId) where !routineIds.contains(r) { routineIds.append(r) }
            for r in routineIds {
                let sets = items.filter { $0.routineId == r }.flatMap(\.sets)
                guard sets.contains(where: \.counts), x.lastByRoutine[r].map({ $0.start <= w.start }) ?? true else { continue }
                x.lastByRoutine[r] = Performance(workoutId: w.id, start: w.start, sets: sets.filter(\.done))
            }
            if !w.deload, let best = Lifts.sessionBest(all, kind, bodyWeight: w.bodyWeight) {
                x.recent.append(SessionBest(day: w.day, value: best))
                if x.recent.count > 3 { x.recent.removeFirst(x.recent.count - 3) }
            }
            for s in all { x.records.add(s, kind, bodyWeight: w.bodyWeight) }
            x.sessions += 1
            exercises[id] = x
        }
    }
}

// MARK: - Previous values

enum Previous {
    /// The last time in the same routine, else the last time anywhere.
    static func sets(_ e: ExerciseIndex?, routineId: String?) -> [LoggedSet] {
        guard let e else { return [] }
        if let r = routineId, let p = e.lastByRoutine[r] { return p.sets }
        return e.last?.sets ?? []
    }

    /// The number-th (0-based) warm-up, or the number-th work set (anything but a warm-up).
    static func row(_ previous: [LoggedSet], warmup: Bool, number: Int) -> LoggedSet? {
        let rows = previous.filter { ($0.kind == .warmup) == warmup }
        return rows.indices.contains(number) ? rows[number] : nil
    }
}

// MARK: - Sets per week

/// Sets per week: direct for a primary muscle, indirect (½ each) for a secondary one.
struct RowCount: Equatable {
    var direct: Double
    var indirect: Double
}

enum WeeklySets {
    static let priority: Set<SetRow> = [.muscle(.sideDelts), .muscle(.lats)]
    static let priorityFloor = 12

    private static var rows: [SetRow] { SetRow.main + SetRow.more }

    /// The weekly average over the workouts whose 04:00 day is in [today − (days − 1), today]. Every counting set counts
    /// once per row: 1 when a primary muscle is in the row, else ½ when a secondary one is. Every row is in the result.
    static func count(_ workouts: [Workout], library: [Exercise], today: DayKey, days: Int = 21) -> [SetRow: RowCount] {
        var direct: [SetRow: Double] = [:]
        var indirect: [SetRow: Double] = [:]
        if days > 0 {
            let from = RecompCalendar.adding(-(days - 1), to: today)
            for w in workouts {
                let day = w.day
                guard day >= from, day <= today else { continue }
                for e in w.exercises {
                    guard let ex = WorkoutProgram.exercise(e.exerciseId, in: library) else { continue }
                    let n = Double(e.sets.filter(\.counts).count)
                    guard n > 0 else { continue }
                    for row in rows {
                        if ex.primary.contains(where: { row.contains($0) }) {
                            direct[row, default: 0] += n
                        } else if ex.secondary.contains(where: { row.contains($0) }) {
                            indirect[row, default: 0] += n * 0.5
                        }
                    }
                }
            }
        }
        let weeks = Double(max(days, 1)) / 7
        var out: [SetRow: RowCount] = [:]
        for row in rows {
            out[row] = RowCount(direct: (direct[row] ?? 0) / weeks, indirect: (indirect[row] ?? 0) / weeks)
        }
        return out
    }

    /// From the routines: per row the planned sets of the items with a primary muscle in it (optional and leg-day-skipped
    /// ones too; a ladder item by its current step), × 1 for Push and Pull and × ½ for Legs, × 7 / 3. Zero rows are left out.
    static func targets(_ routines: [Routine], ladders: [Ladder], state: WorkoutState, library: [Exercise]) -> [SetRow: Int] {
        var sum: [SetRow: Double] = [:]
        for routine in routines {
            let weight = self.weight(routine.id)
            guard weight > 0 else { continue }
            for item in routine.items {
                guard let p = planned(item, ladders: ladders, state: state),
                      let ex = WorkoutProgram.exercise(p.exerciseId, in: library) else { continue }
                for row in rows where ex.primary.contains(where: { row.contains($0) }) {
                    sum[row, default: 0] += Double(max(0, p.sets)) * weight
                }
            }
        }
        var out: [SetRow: Int] = [:]
        for (row, v) in sum {
            let n = Int((v * 7 / 3).rounded())
            if n > 0 { out[row] = n }
        }
        return out
    }

    /// Every third day is a rest day and Legs come on every second Pull.
    private static func weight(_ routineId: String) -> Double {
        switch routineId {
        case "push", "pull": return 1
        case "legs": return 0.5
        default: return 0
        }
    }

    private static func planned(_ item: RoutineItem, ladders: [Ladder], state: WorkoutState) -> (exerciseId: String, sets: Int)? {
        if let id = item.ladderId {
            guard let ladder = ladders.first(where: { $0.id == id }), !ladder.steps.isEmpty else { return nil }
            let step = ladder.steps[Ladders.current(ladder, state: state)]
            return (step.exerciseId, step.target.sets)
        }
        guard let id = item.exerciseId else { return nil }
        return (id, item.target.sets)
    }
}

// MARK: - Warm-ups

enum Warmup {
    /// One warm-up per ramp: the percentage of the work weight, rounded down to the step, at least one step.
    /// No kg when the ramp is 0 % or there is no work weight.
    static func sets(_ ramps: [WarmupRamp], workKg: Double?, step: Double) -> [LoggedSet] {
        ramps.map { r in LoggedSet(kind: .warmup, kg: kg(r.percent, workKg, step), reps: r.reps, done: false) }
    }

    private static func kg(_ percent: Double, _ work: Double?, _ step: Double) -> Double? {
        guard percent > 0, let work, work.isFinite else { return nil }
        guard step > 0 else { return work * percent }
        // The small nudge keeps 0.6 × 50 / 2.5 from flooring to one step less.
        return max(step, (work * percent / step + 1e-9).rounded(.down) * step)
    }
}

// MARK: - Plates

enum Plates {
    static let bar = 20.0
    static let sizes: [Double] = [25, 20, 15, 10, 5, 2.5, 1.25]

    /// "20 + 2 × 15", "20 + 2 × (25 + 1.25)" or "Bar only". nil below the bar, or when the plates can't make it.
    static func text(_ total: Double) -> String? {
        guard total.isFinite, total <= 1000 else { return nil }
        let margin = 1e-6
        if abs(total - bar) < margin { return "Bar only" }
        guard total > bar else { return nil }
        var left = (total - bar) / 2
        var plates: [Double] = []
        for size in sizes {
            while left >= size - margin {
                plates.append(size)
                left -= size
            }
        }
        guard abs(left) < margin, !plates.isEmpty else { return nil }
        let names = plates.map(WorkoutFormat.kg)
        let side = names.count == 1 ? names[0] : "(" + names.joined(separator: " + ") + ")"
        return "\(WorkoutFormat.kg(bar)) + 2 × \(side)"
    }
}

// MARK: - Chart series

/// One workout's done sets of one exercise.
struct ExerciseSession: Equatable {
    var start: Date
    var sets: [LoggedSet]
    var bodyWeight: Double?
}

enum ChartMetric: String, CaseIterable {
    case bestSet, e1rm, volume, reps

    var title: String {
        switch self {
        case .bestSet: return "Best set"
        case .e1rm: return "e1RM"
        case .volume: return "Volume"
        case .reps: return "Reps"
        }
    }
}

enum ChartPeriod: String, CaseIterable {
    case threeMonths, year, all

    var title: String {
        switch self {
        case .threeMonths: return "3 months"
        case .year: return "1 year"
        case .all: return "All"
        }
    }
}

struct ChartPoint: Equatable, Identifiable {
    var date: Date
    var value: Double
    var id: Date { date }
}

enum Series {
    /// Oldest first; only workouts with a counting set of the exercise.
    static func sessions(_ workouts: [Workout], exerciseId: String) -> [ExerciseSession] {
        workouts.sorted { $0.start < $1.start }.compactMap { w -> ExerciseSession? in
            let sets = w.exercises.filter { $0.exerciseId == exerciseId }.flatMap(\.sets).filter(\.done)
            guard sets.contains(where: \.counts) else { return nil }
            return ExerciseSession(start: w.start, sets: sets, bodyWeight: w.bodyWeight)
        }
    }

    /// One point per session in the period that has a value for the metric.
    static func points(_ s: [ExerciseSession], kind: ExerciseKind, metric: ChartMetric, period: ChartPeriod,
                       now: Date) -> [ChartPoint] {
        let from = start(period, now: now)
        return s.compactMap { x -> ChartPoint? in
            if let from, x.start < from { return nil }
            return value(x, kind, metric).map { ChartPoint(date: x.start, value: $0) }
        }
    }

    private static func start(_ period: ChartPeriod, now: Date) -> Date? {
        let calendar = RecompCalendar.calendar
        switch period {
        case .threeMonths: return calendar.date(byAdding: .month, value: -3, to: now)
        case .year: return calendar.date(byAdding: .year, value: -1, to: now)
        case .all: return nil
        }
    }

    /// Best set: the heaviest load (the most reps for bodyweight, the longest for time). e1RM: the best one, for loads.
    /// Volume: as `Lifts.volume`, for weight and weighted. Reps: the most in one set.
    private static func value(_ x: ExerciseSession, _ kind: ExerciseKind, _ metric: ChartMetric) -> Double? {
        let sets = x.sets.filter(\.counts)
        let lifts = sets.compactMap { Lifts.lift($0, kind, bodyWeight: x.bodyWeight) }
        let reps = sets.compactMap(\.reps).filter { $0 > 0 }.max().map { Double($0) }
        let seconds = sets.compactMap(\.seconds).filter { $0 > 0 }.max().map { Double($0) }
        switch metric {
        case .bestSet:
            switch kind {
            case .weight, .weighted, .assisted: return lifts.map { $0.load }.max()
            case .bodyweight: return reps
            case .time, .cardio: return seconds
            }
        case .e1rm:
            return lifts.map { Lifts.e1rm(load: $0.load, reps: $0.reps) }.max()
        case .volume:
            return kind == .weight || kind == .weighted ? Lifts.volume(sets, kind) : nil
        case .reps:
            return reps
        }
    }
}

// MARK: - Tolerant decoding

private struct StatsKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private extension KeyedDecodingContainer where K == StatsKey {
    /// The value, or the default when the key is missing or null.
    func get<T: Decodable>(_ key: String, _ fallback: @autoclosure () -> T) throws -> T {
        try decodeIfPresent(T.self, forKey: StatsKey(key)) ?? fallback()
    }

    func opt<T: Decodable>(_ key: String) throws -> T? {
        try decodeIfPresent(T.self, forKey: StatsKey(key))
    }
}

extension Records {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: StatsKey.self)
        heaviest = try c.opt("heaviest")
        e1rm = try c.opt("e1rm")
        bestSet = try c.opt("bestSet")
        mostReps = try c.opt("mostReps")
        longest = try c.opt("longest")
        byReps = try c.get("byReps", [String: Double]())
    }
}

extension Performance {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: StatsKey.self)
        workoutId = try c.get("workoutId", UUID())
        start = try c.get("start", Date(timeIntervalSince1970: 0))
        sets = try c.get("sets", [LoggedSet]())
    }
}

extension ExerciseIndex {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: StatsKey.self)
        last = try c.opt("last")
        lastByRoutine = try c.get("lastByRoutine", [String: Performance]())
        recent = try c.get("recent", [SessionBest]())
        records = try c.get("records", Records())
        sessions = try c.get("sessions", 0)
    }
}

extension WorkoutIndex {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: StatsKey.self)
        version = try c.get("version", 1)
        exercises = try c.get("exercises", [String: ExerciseIndex]())
        workouts = try c.get("workouts", [WorkoutSummary]())
    }
}
