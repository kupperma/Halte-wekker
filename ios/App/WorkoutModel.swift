import Foundation

// MARK: - Muscles

enum Muscle: String, Codable, CaseIterable, Sendable {
    case sideDelts, lats, chest, rearDelts, triceps, biceps, frontDelts, core, forearms, traps
    case quads, hamstrings, glutes, calves, adductors, abductors

    var isLeg: Bool {
        switch self {
        case .quads, .hamstrings, .glutes, .calves, .adductors, .abductors: return true
        default: return false
        }
    }

    var title: String {
        switch self {
        case .sideDelts: return "Side delts"
        case .lats: return "Lats & back"
        case .chest: return "Chest"
        case .rearDelts: return "Rear delts"
        case .triceps: return "Triceps"
        case .biceps: return "Biceps"
        case .frontDelts: return "Front delts"
        case .core: return "Core"
        case .forearms: return "Forearms"
        case .traps: return "Traps"
        case .quads: return "Quads"
        case .hamstrings: return "Hamstrings"
        case .glutes: return "Glutes"
        case .calves: return "Calves"
        case .adductors: return "Adductors"
        case .abductors: return "Abductors"
        }
    }
}

/// One row of the weekly sets overview. `legs` is every leg muscle together.
enum SetRow: Hashable, Sendable {
    case muscle(Muscle)
    case legs

    static let main: [SetRow] = [.muscle(.sideDelts), .muscle(.lats), .muscle(.chest), .muscle(.rearDelts),
                                 .muscle(.triceps), .muscle(.biceps), .legs]
    static let more: [SetRow] = [.muscle(.frontDelts), .muscle(.core), .muscle(.forearms), .muscle(.traps),
                                 .muscle(.quads), .muscle(.hamstrings), .muscle(.glutes), .muscle(.calves),
                                 .muscle(.adductors), .muscle(.abductors)]

    func contains(_ m: Muscle) -> Bool {
        switch self {
        case .muscle(let x): return x == m
        case .legs: return m.isLeg
        }
    }

    var title: String {
        switch self {
        case .muscle(let m): return m.title
        case .legs: return "Legs"
        }
    }
}

// MARK: - Enums

enum Equipment: String, Codable, CaseIterable {
    case dumbbell, barbell, cable, machine, smith, bodyweight, other
}

/// weighted: kg is extra weight; assisted: kg is the help; time: seconds; cardio: seconds + km (import only).
enum ExerciseKind: String, Codable, CaseIterable {
    case weight, bodyweight, weighted, assisted, time, cardio
}

enum SetKind: String, Codable, CaseIterable {
    case warmup, normal, failure, drop
}

enum MoveUpRule: String, Codable {
    case standard, pullUpToWeighted
}

enum WorkoutSource: String, Codable {
    case app, hevy
}

// MARK: - Library

/// lo/hi are seconds for `.time`; rest in seconds; rirLo nil = no RIR.
struct Target: Codable, Equatable {
    var sets: Int
    var lo: Int
    var hi: Int
    var rirLo: Int? = nil
    var rirHi: Int? = nil
    var rest: Int
}

struct Exercise: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var equipment: Equipment = .other
    var kind: ExerciseKind = .weight
    var primary: [Muscle] = []
    var secondary: [Muscle] = []
    /// nil = the equipment default from settings.
    var step: Double? = nil
    var hevyNames: [String] = []
    var custom = false
}

struct LadderStep: Codable, Equatable {
    var label: String
    var exerciseId: String
    var target: Target
    var note = ""
    var moveUp: MoveUpRule = .standard
}

struct Ladder: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var steps: [LadderStep]
    var hint: String
    var start: Int
}

/// percent 0 = no load.
struct WarmupRamp: Codable, Equatable {
    var percent: Double
    var reps: Int
}

struct RoutineItem: Codable, Identifiable, Equatable {
    var id = UUID()
    /// Exactly one of exerciseId and ladderId.
    var exerciseId: String? = nil
    var ladderId: String? = nil
    var target: Target
    var note = ""
    var alternatives: [String] = []
    var superset: Int? = nil
    var optional = false
    var skipOnLegDays = false
    var warmup: [WarmupRamp] = []
}

struct Routine: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var short: String
    var items: [RoutineItem]
}

// MARK: - Logged data

struct LoggedSet: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: SetKind = .normal
    var kg: Double? = nil
    var reps: Int? = nil
    var seconds: Int? = nil
    var km: Double? = nil
    var rir: Int? = nil
    var done = false
    var doneAt: Date? = nil

    /// A done set that is not a warm-up.
    var counts: Bool { done && kind != .warmup }
}

struct LoggedExercise: Codable, Identifiable, Equatable {
    var id = UUID()
    var exerciseId: String
    var ladderId: String? = nil
    var routineId: String? = nil
    var target: Target? = nil
    var superset: Int? = nil
    var note = ""
    var sets: [LoggedSet] = []
}

struct Workout: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var routineIds: [String] = []
    var start: Date
    var end: Date? = nil
    var note = ""
    var bodyWeight: Double? = nil
    var deload = false
    var source: WorkoutSource = .app
    var hevyKey: String? = nil
    var exercises: [LoggedExercise] = []

    /// Sets that count.
    var hardSets: Int { exercises.reduce(0) { $0 + $1.sets.filter(\.counts).count } }
    var day: DayKey { RecompCalendar.day(for: start) }
    var month: String { String(day.prefix(7)) }
}

struct WorkoutSummary: Codable, Equatable, Identifiable {
    var id: UUID
    var title: String
    var routineIds: [String]
    var start: Date
    var end: Date?
    var day: DayKey
    var hardSets: Int
    var source: WorkoutSource
    var hevyKey: String?
    var deload: Bool
    var exerciseIds: [String]

    init(_ w: Workout) {
        id = w.id
        title = w.title
        routineIds = w.routineIds
        start = w.start
        end = w.end
        day = w.day
        hardSets = w.hardSets
        source = w.source
        hevyKey = w.hevyKey
        deload = w.deload
        exerciseIds = w.exercises.map(\.exerciseId)
    }
}

// MARK: - State

struct DeloadState: Codable, Equatable {
    var active = false
    var left: [String] = []
    var lastDay: DayKey? = nil
    var snoozedUntil: DayKey? = nil
}

struct WorkoutSettings: Codable, Equatable {
    static let defaultSteps: [String: Double] = ["dumbbell": 2, "cable": 2.5, "machine": 2.5, "barbell": 2.5, "smith": 2.5, "weighted": 2.5]
    var restSound = true
    var keepScreenOn = false
    var bodyWeightFromRecomp = true
    var fixedBodyWeight: Double? = nil
    var steps: [String: Double] = WorkoutSettings.defaultSteps
}

struct WorkoutState: Codable, Equatable {
    var version = 1
    var ladderSteps: [String: Int] = [:]
    var deload = DeloadState()
    var firstLegsDay: DayKey? = nil
    var firstAppDay: DayKey? = nil
    var settings = WorkoutSettings()
}

struct RestState: Codable, Equatable {
    var started: Date
    var ends: Date
}

/// id = the routine item's id.
struct ClosedItem: Codable, Identifiable, Equatable {
    var id: UUID
    var routineId: String
    var exerciseId: String
    var target: Target
    var reason: String
}

struct ActiveWorkout: Codable, Equatable {
    var version = 1
    var workout: Workout
    /// LoggedExercise.id.uuidString -> last time's sets.
    var previous: [String: [LoggedSet]] = [:]
    var closed: [ClosedItem] = []
    var rest: RestState? = nil
    var focus: UUID? = nil
    var lastRecord: String? = nil
}

struct MonthFile: Codable {
    var version = 1
    var month: String
    var workouts: [Workout]
}

struct LibraryFile: Codable {
    var version = 1
    var exercises: [Exercise]
    var ladders: [Ladder]
}

struct RoutinesFile: Codable {
    var version = 1
    var routines: [Routine]
}

// MARK: - Tolerant decoding

private struct WorkoutKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private extension KeyedDecodingContainer where K == WorkoutKey {
    /// The value, or the default when the key is missing or null.
    func get<T: Decodable>(_ key: String, _ fallback: @autoclosure () -> T) throws -> T {
        try decodeIfPresent(T.self, forKey: WorkoutKey(key)) ?? fallback()
    }

    func opt<T: Decodable>(_ key: String) throws -> T? {
        try decodeIfPresent(T.self, forKey: WorkoutKey(key))
    }
}

private let defaultTarget = Target(sets: 3, lo: 8, hi: 12, rest: 120)

/// An unknown raw value decodes as `fallback`.
private func decodeRaw<E: RawRepresentable>(_ decoder: Decoder, fallback: E) throws -> E where E.RawValue == String {
    let raw = try decoder.singleValueContainer().decode(String.self)
    return E(rawValue: raw) ?? fallback
}

extension Muscle {
    init(from decoder: Decoder) throws { self = try decodeRaw(decoder, fallback: Muscle.sideDelts) }
}
extension Equipment {
    init(from decoder: Decoder) throws { self = try decodeRaw(decoder, fallback: Equipment.dumbbell) }
}
extension ExerciseKind {
    init(from decoder: Decoder) throws { self = try decodeRaw(decoder, fallback: ExerciseKind.weight) }
}
extension SetKind {
    init(from decoder: Decoder) throws { self = try decodeRaw(decoder, fallback: SetKind.normal) }
}
extension MoveUpRule {
    init(from decoder: Decoder) throws { self = try decodeRaw(decoder, fallback: MoveUpRule.standard) }
}
extension WorkoutSource {
    init(from decoder: Decoder) throws { self = try decodeRaw(decoder, fallback: WorkoutSource.app) }
}

extension Target {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: WorkoutKey.self)
        sets = try c.get("sets", 3)
        lo = try c.get("lo", 8)
        hi = try c.get("hi", 12)
        rirLo = try c.opt("rirLo")
        rirHi = try c.opt("rirHi")
        rest = try c.get("rest", 120)
    }
}

extension Exercise {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: WorkoutKey.self)
        id = try c.get("id", UUID().uuidString)
        name = try c.get("name", "")
        equipment = try c.get("equipment", Equipment.other)
        kind = try c.get("kind", ExerciseKind.weight)
        primary = try c.get("primary", [Muscle]())
        secondary = try c.get("secondary", [Muscle]())
        step = try c.opt("step")
        hevyNames = try c.get("hevyNames", [String]())
        custom = try c.get("custom", false)
    }
}

extension LadderStep {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: WorkoutKey.self)
        label = try c.get("label", "")
        exerciseId = try c.get("exerciseId", "")
        target = try c.get("target", defaultTarget)
        note = try c.get("note", "")
        moveUp = try c.get("moveUp", MoveUpRule.standard)
    }
}

extension Ladder {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: WorkoutKey.self)
        id = try c.get("id", UUID().uuidString)
        name = try c.get("name", "")
        steps = try c.get("steps", [LadderStep]())
        hint = try c.get("hint", "")
        start = try c.get("start", 0)
    }
}

extension WarmupRamp {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: WorkoutKey.self)
        percent = try c.get("percent", 0.0)
        reps = try c.get("reps", 5)
    }
}

extension RoutineItem {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: WorkoutKey.self)
        id = try c.get("id", UUID())
        exerciseId = try c.opt("exerciseId")
        ladderId = try c.opt("ladderId")
        target = try c.get("target", defaultTarget)
        note = try c.get("note", "")
        alternatives = try c.get("alternatives", [String]())
        superset = try c.opt("superset")
        optional = try c.get("optional", false)
        skipOnLegDays = try c.get("skipOnLegDays", false)
        warmup = try c.get("warmup", [WarmupRamp]())
    }
}

extension Routine {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: WorkoutKey.self)
        id = try c.get("id", UUID().uuidString)
        name = try c.get("name", "")
        short = try c.get("short", "")
        items = try c.get("items", [RoutineItem]())
    }
}

extension LoggedSet {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: WorkoutKey.self)
        id = try c.get("id", UUID())
        kind = try c.get("kind", SetKind.normal)
        kg = try c.opt("kg")
        reps = try c.opt("reps")
        seconds = try c.opt("seconds")
        km = try c.opt("km")
        rir = try c.opt("rir")
        done = try c.get("done", false)
        doneAt = try c.opt("doneAt")
    }
}

extension LoggedExercise {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: WorkoutKey.self)
        id = try c.get("id", UUID())
        exerciseId = try c.get("exerciseId", "")
        ladderId = try c.opt("ladderId")
        routineId = try c.opt("routineId")
        target = try c.opt("target")
        superset = try c.opt("superset")
        note = try c.get("note", "")
        sets = try c.get("sets", [LoggedSet]())
    }
}

extension Workout {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: WorkoutKey.self)
        id = try c.get("id", UUID())
        title = try c.get("title", "")
        routineIds = try c.get("routineIds", [String]())
        start = try c.get("start", Date(timeIntervalSince1970: 0))
        end = try c.opt("end")
        note = try c.get("note", "")
        bodyWeight = try c.opt("bodyWeight")
        deload = try c.get("deload", false)
        source = try c.get("source", WorkoutSource.app)
        hevyKey = try c.opt("hevyKey")
        exercises = try c.get("exercises", [LoggedExercise]())
    }
}

extension WorkoutSummary {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: WorkoutKey.self)
        id = try c.get("id", UUID())
        title = try c.get("title", "")
        routineIds = try c.get("routineIds", [String]())
        let s: Date = try c.get("start", Date(timeIntervalSince1970: 0))
        start = s
        end = try c.opt("end")
        day = try c.get("day", RecompCalendar.day(for: s))
        hardSets = try c.get("hardSets", 0)
        source = try c.get("source", WorkoutSource.app)
        hevyKey = try c.opt("hevyKey")
        deload = try c.get("deload", false)
        exerciseIds = try c.get("exerciseIds", [String]())
    }
}

extension DeloadState {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: WorkoutKey.self)
        active = try c.get("active", false)
        left = try c.get("left", [String]())
        lastDay = try c.opt("lastDay")
        snoozedUntil = try c.opt("snoozedUntil")
    }
}

extension WorkoutSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: WorkoutKey.self)
        restSound = try c.get("restSound", true)
        keepScreenOn = try c.get("keepScreenOn", false)
        bodyWeightFromRecomp = try c.get("bodyWeightFromRecomp", true)
        fixedBodyWeight = try c.opt("fixedBodyWeight")
        steps = try c.get("steps", WorkoutSettings.defaultSteps)
    }
}

extension WorkoutState {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: WorkoutKey.self)
        version = try c.get("version", 1)
        ladderSteps = try c.get("ladderSteps", [String: Int]())
        deload = try c.get("deload", DeloadState())
        firstLegsDay = try c.opt("firstLegsDay")
        firstAppDay = try c.opt("firstAppDay")
        settings = try c.get("settings", WorkoutSettings())
    }
}

extension RestState {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: WorkoutKey.self)
        let now = Date()
        started = try c.get("started", now)
        ends = try c.get("ends", now)
    }
}

extension ClosedItem {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: WorkoutKey.self)
        id = try c.get("id", UUID())
        routineId = try c.get("routineId", "")
        exerciseId = try c.get("exerciseId", "")
        target = try c.get("target", defaultTarget)
        reason = try c.get("reason", "")
    }
}

extension ActiveWorkout {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: WorkoutKey.self)
        version = try c.get("version", 1)
        // The one thing without a sensible default: a file without it is not an active workout.
        workout = try c.decode(Workout.self, forKey: WorkoutKey("workout"))
        previous = try c.get("previous", [String: [LoggedSet]]())
        closed = try c.get("closed", [ClosedItem]())
        rest = try c.opt("rest")
        focus = try c.opt("focus")
        lastRecord = try c.opt("lastRecord")
    }
}

extension MonthFile {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: WorkoutKey.self)
        version = try c.get("version", 1)
        month = try c.get("month", "")
        workouts = try c.get("workouts", [Workout]())
    }
}

extension LibraryFile {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: WorkoutKey.self)
        version = try c.get("version", 1)
        exercises = try c.get("exercises", [Exercise]())
        ladders = try c.get("ladders", [Ladder]())
    }
}

extension RoutinesFile {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: WorkoutKey.self)
        version = try c.get("version", 1)
        routines = try c.get("routines", [Routine]())
    }
}
