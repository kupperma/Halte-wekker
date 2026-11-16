import Foundation

// MARK: - Rotation

enum RotationKind: Equatable { case push, pull(legs: Bool) }

struct RotationDay: Equatable {
    var day: DayKey
    var start: Date
    var kind: RotationKind
}

enum NextUp: Equatable { case push, pull(legs: Bool), restThenPush }

/// Push → Pull → rest, counted from what he actually did, not from the calendar. Legs on every second Pull.
enum Rotation {
    /// The workouts that count for the rotation, oldest first. An app workout counts by its routine ids, a Hevy
    /// workout by its title "Push" or "Pull". Legs on the same day as a Pull (an app workout with "legs", or a Hevy
    /// "Legs") make that Pull one with legs. Everything else is only history.
    static func days(_ workouts: [WorkoutSummary]) -> [RotationDay] {
        var out: [RotationDay] = []
        var legsDays = Set<DayKey>()
        for w in workouts.sorted(by: { $0.start < $1.start }) {
            let kind: RotationKind?
            switch w.source {
            case .app:
                if w.routineIds.contains("legs") { legsDays.insert(w.day) }
                if w.routineIds.contains("push") {
                    kind = .push
                } else if w.routineIds.contains("pull") {
                    kind = .pull(legs: w.routineIds.contains("legs"))
                } else {
                    kind = nil
                }
            case .hevy:
                switch w.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "push": kind = .push
                case "pull": kind = .pull(legs: false)
                case "legs":
                    legsDays.insert(w.day)
                    kind = nil
                default: kind = nil
                }
            }
            if let kind { out.append(RotationDay(day: w.day, start: w.start, kind: kind)) }
        }
        return out.map { d in
            guard d.kind.isPull, legsDays.contains(d.day) else { return d }
            var marked = d
            marked.kind = .pull(legs: true)
            return marked
        }
    }

    /// `days` oldest first, as `days(_:)` gives them.
    static func next(_ days: [RotationDay], today: DayKey) -> NextUp {
        guard let last = days.last else { return .push }
        switch last.kind {
        case .push:
            if case .pull(let legs)? = days.dropLast().last(where: { $0.kind.isPull })?.kind {
                return .pull(legs: !legs)
            }
            return .pull(legs: false)
        case .pull:
            return RecompCalendar.daysBetween(last.day, today) <= 1 ? .restThenPush : .push
        }
    }

    /// A Pull now, instead of the Push that is next: with legs when the last Pull had none (none before the first Pull).
    static func pullNow(_ days: [RotationDay]) -> NextUp {
        guard case .pull(let legs)? = days.last(where: { $0.kind.isPull })?.kind else { return .pull(legs: false) }
        return .pull(legs: !legs)
    }

    static func routineIds(_ n: NextUp) -> [String] {
        switch n {
        case .push, .restThenPush: return ["push"]
        case .pull(let legs): return legs ? ["pull", "legs"] : ["pull"]
        }
    }

    static func title(_ n: NextUp) -> String {
        switch n {
        case .push, .restThenPush: return "Push"
        case .pull(let legs): return legs ? "Pull + legs" : "Pull"
        }
    }

    /// Not on a rest day, and not once he trained today.
    static func isTrainingDay(_ n: NextUp, workouts: [WorkoutSummary], today: DayKey) -> Bool {
        if n == .restThenPush { return false }
        return !workouts.contains { $0.day == today }
    }

    /// "Next: Pull + legs · Push 2 days ago", "Rest day. Next: Push · Pull yesterday", "Done today. Next: Push".
    static func cardLine(_ n: NextUp, last: WorkoutSummary?, today: DayKey) -> String {
        if last?.day == today { return "Done today. Next: \(title(n))" }
        var line = n == .restThenPush ? "Rest day. Next: Push" : "Next: \(title(n))"
        if let last {
            line += " · \(last.title) \(WorkoutFormat.ago(days: RecompCalendar.daysBetween(last.day, today)))"
        }
        return line
    }

    /// "Last: Push · Thu 12 Nov · 75 min · 22 sets". The date is the workout's 04:00 day, so 00:30 is still the evening before.
    static func lastLine(_ s: WorkoutSummary, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var parts = ["Last: \(s.title)", WorkoutFormat.day(RecompCalendar.date(of: s.day, calendar: calendar), timeZone: timeZone)]
        if let end = s.end { parts.append(WorkoutFormat.minutes(s.start, end)) }
        parts.append(WorkoutFormat.sets(s.hardSets))
        return parts.joined(separator: " · ")
    }
}

private extension RotationKind {
    var isPull: Bool {
        if case .pull = self { return true }
        return false
    }
}

// MARK: - Double progression

/// What to lift next time. `values` holds one value per planned set: reps, or seconds for `.time`.
struct Suggestion: Equatable {
    var kg: Double?
    var values: [Int]
    var topReached: Bool
    var moveUp: Bool
    var increased: Bool
}

enum Progression {
    /// The exercise's own step, else the setting for its equipment ("weighted" for extra weight or help), else 2.5.
    static func step(_ e: Exercise, settings: WorkoutSettings) -> Double {
        if let s = e.step { return s }
        let key = e.kind == .weighted || e.kind == .assisted ? "weighted" : e.equipment.rawValue
        return settings.steps[key] ?? 2.5
    }

    /// Did all the planned sets reach the top of the range at the RIR target? A set without RIR counts as on target,
    /// except a failure set, which counts as RIR 0.
    static func topReached(_ work: [LoggedSet], _ t: Target, kind: ExerciseKind, rule: MoveUpRule = .standard) -> Bool {
        let sets = workSets(work)
        let values = sets.map { value($0, kind) }
        guard let first = values.first else { return false }
        // Fewer sets than planned (a deload, a short day) is never the top.
        let allAtTop = values.count >= t.sets && values.allSatisfy { $0 >= t.hi }
        switch rule {
        case .standard:
            return allAtTop && sets.allSatisfy { s in
                guard let rir = effectiveRIR(s), let lo = t.rirLo else { return true }
                return rir >= lo
            }
        case .pullUpToWeighted:
            // 12 clean reps in the first set, or every set at the top with 2 or more in reserve.
            return first >= 12 || (allAtTop && sets.allSatisfy { (effectiveRIR($0) ?? 2) >= 2 })
        }
    }

    /// From last time's sets. A planned set beyond what he did last time repeats his last set.
    static func suggest(last work: [LoggedSet], target t: Target, kind: ExerciseKind, step: Double,
                        ladder: (rule: MoveUpRule, isLast: Bool)?, deload: Bool) -> Suggestion {
        let sets = workSets(work)
        let values = sets.map { value($0, kind) }
        let base = sets.compactMap(\.kg).max()
        let count = max(0, t.sets)
        func prior(_ i: Int) -> Int? { values.isEmpty ? nil : values[min(i, values.count - 1)] }
        func each(_ f: (Int) -> Int) -> [Int] { (0..<count).map(f) }

        if deload {
            return Suggestion(kg: base, values: each { prior($0) ?? t.lo }, topReached: false, moveUp: false, increased: false)
        }
        let top = topReached(sets, t, kind: kind, rule: ladder?.rule ?? .standard)
        if top, let ladder, !ladder.isLast {
            return Suggestion(kg: base, values: each { min(prior($0) ?? t.hi, t.hi) }, topReached: true, moveUp: true, increased: false)
        }
        if top {
            switch kind {
            case .weight, .weighted:
                return Suggestion(kg: (base ?? 0) + step, values: each { _ in t.lo }, topReached: true, moveUp: false, increased: true)
            case .assisted where (base ?? 0) > 0:
                return Suggestion(kg: max(0, (base ?? 0) - step), values: each { _ in t.lo }, topReached: true, moveUp: false,
                                  increased: true)
            default:
                return Suggestion(kg: base, values: each { _ in t.hi }, topReached: true, moveUp: false, increased: false)
            }
        }
        let add = kind == .time ? 5 : 1
        return Suggestion(kg: base, values: each { i in prior(i).map { min($0 + add, t.hi) } ?? t.lo },
                          topReached: false, moveUp: false, increased: false)
    }

    /// "All sets at 10. Next time 28 kg", "… +12.5 kg", "… −17.5 kg", or "Ready for tuck reps? Move up".
    static func nextTime(_ s: Suggestion, target t: Target, kind: ExerciseKind, nextStep: String?) -> String? {
        if s.increased, let kg = s.kg {
            let unit = kind == .time ? " s" : ""
            let sign = kind == .weighted ? "+" : (kind == .assisted && kg > 0 ? "\u{2212}" : "")
            return "All sets at \(t.hi)\(unit). Next time \(sign)\(WorkoutFormat.kg(kg)) kg"
        }
        if s.moveUp, let nextStep {
            return "Ready for \(nextStep)? Move up"
        }
        return nil
    }

    /// The done normal and failure sets, in order. Warm-ups and drops don't count.
    private static func workSets(_ sets: [LoggedSet]) -> [LoggedSet] {
        sets.filter { $0.done && ($0.kind == .normal || $0.kind == .failure) }
    }

    private static func value(_ s: LoggedSet, _ kind: ExerciseKind) -> Int {
        (kind == .time ? s.seconds : s.reps) ?? 0
    }

    /// The logged RIR; a failure set without one had nothing left.
    private static func effectiveRIR(_ s: LoggedSet) -> Int? {
        s.rir ?? (s.kind == .failure ? 0 : nil)
    }
}

// MARK: - Ladders

enum Ladders {
    /// The stored step, or the ladder's start, kept within its steps.
    static func current(_ l: Ladder, state: WorkoutState) -> Int {
        clamp(state.ladderSteps[l.id] ?? l.start, l)
    }

    /// Never past the last step.
    static func moveUp(_ l: Ladder, state: inout WorkoutState) {
        state.ladderSteps[l.id] = clamp(current(l, state: state) + 1, l)
    }

    /// Never below the first step.
    static func stepBack(_ l: Ladder, state: inout WorkoutState) {
        state.ladderSteps[l.id] = clamp(current(l, state: state) - 1, l)
    }

    /// "Dragon flag · tuck negatives (2 of 7)".
    static func title(_ l: Ladder, step: Int) -> String {
        guard !l.steps.isEmpty else { return l.name }
        let i = clamp(step, l)
        return "\(l.name) · \(l.steps[i].label) (\(i + 1) of \(l.steps.count))"
    }

    private static func clamp(_ step: Int, _ l: Ladder) -> Int {
        min(max(step, 0), max(l.steps.count - 1, 0))
    }
}

// MARK: - Deload

/// An exercise's best work set of one session: e1RM for load, reps for bodyweight.
struct SessionBest: Codable, Equatable {
    var day: DayKey
    var value: Double
}

extension SessionBest {
    private enum Key: String, CodingKey { case day, value }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        day = try c.decodeIfPresent(DayKey.self, forKey: .day) ?? ""
        value = try c.decodeIfPresent(Double.self, forKey: .value) ?? 0
    }
}

enum DeloadLine: Equatable { case flags([String]), planned(weeks: Int) }

enum Deload {
    /// ⅓ fewer, rounded, at least 1: 4 → 3, 3 → 2, 2 → 1, 1 → 1.
    static func sets(_ n: Int) -> Int {
        max(1, n - max(1, Int((Double(n) / 3).rounded())))
    }

    /// A fall is more than 1 % down, so a body weight a few hundred grams lighter on a weighted lift is not one.
    static let fallMargin = 0.99

    /// Fell two sessions running: the last three, oldest first, each more than 1 % below the one before. With `after`
    /// (the last deload's day), only sessions after that day count, so the falls that led to a deload don't flag again
    /// right after it.
    static func flagged(_ recent: [SessionBest], after: DayKey? = nil) -> Bool {
        let counted = after.map { a in recent.filter { $0.day > a } } ?? recent
        let v = counted.suffix(3).map(\.value)
        return v.count == 3 && v[1] < v[0] * fallMargin && v[2] < v[1] * fallMargin
    }

    /// Nothing while a deload runs or "Not yet" holds. Two or more flags, else week 6 or later since the last deload,
    /// or since the first workout in the app when there was none (never from the import).
    static func line(flagNames: [String], state: DeloadState, firstAppDay: DayKey?, today: DayKey) -> DeloadLine? {
        if state.active { return nil }
        if let until = state.snoozedUntil, today < until { return nil }
        if flagNames.count >= 2 { return .flags(flagNames) }
        guard let from = state.lastDay ?? firstAppDay else { return nil }
        let weeks = RecompCalendar.daysBetween(from, today) / 7
        return weeks >= 6 ? .planned(weeks: weeks) : nil
    }

    static func text(_ l: DeloadLine) -> String {
        switch l {
        case .flags(let names): return "Reps fell two sessions running on \(WorkoutFormat.names(names)). Deload this cycle?"
        case .planned(let weeks): return "Week \(weeks) since your last deload. Take one this cycle?"
        }
    }

    /// One Push and one Pull with fewer sets.
    static func start(_ s: inout DeloadState) {
        s.active = true
        s.left = ["push", "pull"]
    }

    /// Ticks off the routines of a finished workout. After the last one the deload ends on that day.
    static func finished(_ s: inout DeloadState, routineIds: [String], day: DayKey) {
        guard s.active else { return }
        s.left.removeAll { routineIds.contains($0) }
        guard s.left.isEmpty else { return }
        s.active = false
        s.lastDay = day
        s.snoozedUntil = nil
    }

    /// "Not yet": hides the line for a week.
    static func snooze(_ s: inout DeloadState, today: DayKey) {
        s.snoozedUntil = RecompCalendar.adding(7, to: today)
    }
}
