import Foundation

/// The library, the ladders and the three routines of the user's Push/Pull/Legs program. Pure data.
enum WorkoutProgram {
    /// Lowercase, runs of non-alphanumerics become "-", trimmed: "Seated cable row (V-grip)" -> "seated-cable-row-v-grip".
    static func slug(_ name: String) -> String {
        var out = ""
        var pendingDash = false
        for ch in name.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                if pendingDash && !out.isEmpty { out.append("-") }
                pendingDash = false
                out.append(ch)
            } else {
                pendingDash = true
            }
        }
        return out
    }

    static func exercise(_ id: String, in list: [Exercise]) -> Exercise? {
        list.first { $0.id == id }
    }

    /// A Hevy exercise title: trimmed, case-insensitive, against `hevyNames`.
    static func match(hevy title: String, in list: [Exercise]) -> Exercise? {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return nil }
        return list.first { ex in ex.hevyNames.contains { $0.lowercased() == t } }
    }

    // MARK: - Library

    private static func ex(_ name: String, _ equipment: Equipment, _ kind: ExerciseKind,
                           _ primary: [Muscle], _ secondary: [Muscle] = [],
                           hevy: [String] = [], custom: Bool = false) -> Exercise {
        Exercise(id: slug(name), name: name, equipment: equipment, kind: kind, primary: primary,
                 secondary: secondary, step: nil, hevyNames: hevy, custom: custom)
    }

    private static func ex(_ name: String, _ equipment: Equipment,
                           _ primary: [Muscle], _ secondary: [Muscle] = [],
                           hevy: [String] = [], custom: Bool = false) -> Exercise {
        ex(name, equipment, .weight, primary, secondary, hevy: hevy, custom: custom)
    }

    static let exercises: [Exercise] = [
        // Chest
        ex("Incline DB press", .dumbbell, [.chest], [.frontDelts, .triceps], hevy: ["Incline Bench Press (Dumbbell)"]),
        ex("Flat DB press", .dumbbell, [.chest], hevy: ["Bench Press (Dumbbell)"]),
        ex("Smith bench press", .smith, [.chest], [.frontDelts, .triceps], hevy: ["Bench Press (Smith Machine)"]),
        ex("Machine chest fly", .machine, [.chest], hevy: ["Chest Fly (Machine)"]),
        ex("Pec deck", .machine, [.chest], hevy: ["Butterfly (Pec Deck)"]),
        ex("Cable fly crossover", .cable, [.chest], hevy: ["Cable Fly Crossovers"]),
        ex("Weighted dip", .bodyweight, .weighted, [.chest], [.triceps, .frontDelts], hevy: ["Triceps Dip Weighted"]),
        ex("Dip", .bodyweight, .bodyweight, [.chest], [.triceps, .frontDelts], hevy: ["Triceps Dip"]),

        // Shoulders
        ex("Pike push-up", .bodyweight, .bodyweight, [.frontDelts], [.triceps], hevy: ["Pike Pushup"]),
        ex("Feet-elevated pike push-up", .bodyweight, .bodyweight, [.frontDelts], [.triceps]),
        ex("Wall HSPU negatives", .bodyweight, .bodyweight, [.frontDelts], [.triceps]),
        ex("Partial wall HSPU", .bodyweight, .bodyweight, [.frontDelts], [.triceps]),
        ex("Wall HSPU", .bodyweight, .bodyweight, [.frontDelts], [.triceps]),
        ex("Chest-to-wall handstand hold", .bodyweight, .time, [.frontDelts], [.triceps, .core]),
        ex("DB shoulder press", .dumbbell, [.frontDelts], [.sideDelts, .triceps], hevy: ["Shoulder Press (Dumbbell)"]),
        ex("Machine shoulder press", .machine, [.frontDelts], [.sideDelts, .triceps], hevy: ["Seated Shoulder Press (Machine)"]),
        ex("DB lateral raise", .dumbbell, [.sideDelts], hevy: ["Lateral Raise (Dumbbell)"]),
        ex("Single-arm cable lateral raise", .cable, [.sideDelts], hevy: ["Single Arm Lateral Raise (Cable)"]),
        ex("Rear delt fly (cable)", .cable, [.rearDelts], hevy: ["Rear Delt Reverse Fly (Cable)"]),
        ex("Rear delt fly (machine)", .machine, [.rearDelts], hevy: ["Rear Delt Reverse Fly (Machine)"]),
        ex("Single-arm rear delt fly", .other, [.rearDelts], hevy: ["Reverse Fly Single Arm (Cable)"]),
        ex("Machine shrug", .machine, [.traps], hevy: ["Shrug (Machine)"]),

        // Back
        ex("Assisted pull-up", .bodyweight, .assisted, [.lats], [.biceps], hevy: ["Pull Up (Assisted)"]),
        ex("Pull-up", .bodyweight, .bodyweight, [.lats], [.biceps], hevy: ["Pull Up"]),
        ex("Weighted pull-up", .bodyweight, .weighted, [.lats], [.biceps], hevy: ["Pull Up (Weighted)"]),
        ex("Lat pulldown", .cable, [.lats], hevy: ["Lat Pulldown (Cable)"]),
        ex("Single-arm cable pulldown", .cable, [.lats]),
        ex("Seated cable row (V-grip)", .cable, [.lats], [.rearDelts, .biceps], hevy: ["Seated Cable Row - V Grip (Cable)"]),
        ex("Seated cable row (bar grip)", .cable, [.lats], [.rearDelts, .biceps], hevy: ["Seated Cable Row - Bar Grip"]),
        ex("Dead hang", .bodyweight, .time, [.lats], [.forearms], hevy: ["Dead Hang"]),

        // Arms
        ex("Bayesian curl", .cable, [.biceps], hevy: ["Bayesian Curl"]),
        ex("Cable curl", .cable, [.biceps], hevy: ["Bicep Curl (Cable)"]),
        ex("DB curl", .dumbbell, [.biceps], hevy: ["Bicep Curl (Dumbbell)"]),
        ex("Machine preacher curl", .machine, [.biceps], hevy: ["Preacher Curl (Machine)"]),
        ex("Hammer curl (DB)", .dumbbell, [.biceps], hevy: ["Hammer Curl (Dumbbell)"]),
        ex("Hammer curl (cable)", .cable, [.biceps], hevy: ["Hammer Curl (Cable)"]),
        ex("Barbell reverse curl", .barbell, [.forearms], [.biceps], hevy: ["Reverse Curl (Barbell)"]),
        ex("Rope pushdown", .cable, [.triceps], hevy: ["Triceps Rope Pushdown"]),
        ex("Pushdown", .cable, [.triceps], hevy: ["Triceps Pushdown"]),
        ex("V-grip pushdown", .cable, [.triceps], hevy: ["Tricep Push down V-grip"]),
        ex("Single-arm pushdown", .cable, [.triceps], hevy: ["Tricep Push downs Single Handed"]),
        ex("Overhead triceps extension (cable)", .cable, [.triceps], hevy: ["Overhead Triceps Extension (Cable)"]),
        ex("Overhead triceps extension (DB)", .dumbbell, [.triceps]),
        ex("DB kickback", .dumbbell, [.triceps], hevy: ["Triceps Kickback (Dumbbell)"]),

        // Forearms
        ex("Seated palms-up wrist curl", .dumbbell, [.forearms], hevy: ["Seated Palms Up Wrist Curl"]),
        ex("Seated barbell wrist extension", .barbell, [.forearms], hevy: ["Seated Wrist Extension (Barbell)"]),
        ex("Behind-the-back barbell wrist curl", .barbell, [.forearms], hevy: ["Behind the Back Bicep Wrist Curl (Barbell)"]),

        // Legs
        ex("Leg press", .machine, [.quads, .glutes], hevy: ["Leg Press (Machine)"]),
        ex("Horizontal leg press", .machine, [.quads, .glutes], hevy: ["Leg Press Horizontal (Machine)"]),
        ex("Hack squat", .machine, [.quads, .glutes]),
        ex("Goblet squat", .dumbbell, [.quads, .glutes]),
        ex("Smith squat", .smith, [.quads, .glutes], hevy: ["Squat (Smith Machine)"]),
        ex("Machine squat", .machine, [.quads, .glutes], hevy: ["Squat (Machine)"]),
        ex("Romanian deadlift (Smith)", .smith, [.hamstrings, .glutes], hevy: ["Romanian Deadlift (Smith Machine)"]),
        ex("Romanian deadlift (barbell)", .barbell, [.hamstrings, .glutes]),
        ex("Lying leg curl", .machine, [.hamstrings], hevy: ["Lying Leg Curl (Machine)"]),
        ex("Seated leg curl", .machine, [.hamstrings], hevy: ["Seated Leg Curl (Machine)"]),
        ex("Leg extension", .machine, [.quads], hevy: ["Leg Extension (Machine)"]),
        ex("Hip abduction", .machine, [.abductors], hevy: ["Hip Abduction (Machine)"]),
        ex("Hip adduction", .machine, [.adductors], hevy: ["Hip Adduction (Machine)"]),
        ex("Calf press", .machine, [.calves], hevy: ["Calf Press (Machine)"]),
        ex("Seated calf raise", .machine, [.calves], hevy: ["Seated Calf Raise"]),

        // Core
        ex("Hollow-body hold", .bodyweight, .time, [.core]),
        ex("Dragon flag (tuck negatives)", .bodyweight, .bodyweight, [.core]),
        ex("Dragon flag (tuck)", .bodyweight, .bodyweight, [.core]),
        ex("Dragon flag (one-leg)", .bodyweight, .bodyweight, [.core]),
        ex("Dragon flag (straddle)", .bodyweight, .bodyweight, [.core]),
        ex("Dragon flag (negatives)", .bodyweight, .bodyweight, [.core]),
        ex("Dragon flag", .bodyweight, .bodyweight, [.core], hevy: ["Dragon Flag"]),
        ex("Machine crunch", .machine, [.core], hevy: ["Crunch (Machine)"]),
        ex("Cable crunch", .cable, [.core], hevy: ["Cable Crunch"]),
        ex("Parallel-bar leg raise", .bodyweight, .bodyweight, [.core], hevy: ["Leg Raise Parallel Bars"]),
        ex("Hanging leg raise", .bodyweight, .bodyweight, [.core], hevy: ["Hanging Leg Raise"]),
        ex("Weighted sit-up", .other, [.core], hevy: ["Sit Up (Weighted)"]),
        ex("Weighted decline crunch", .other, [.core], hevy: ["Decline Crunch (Weighted)"]),
        ex("Ab wheel", .bodyweight, .bodyweight, [.core], hevy: ["Ab Wheel"]),

        // Other
        ex("Walking", .other, .cardio, [], hevy: ["Walking"]),
        ex("Treadmill", .other, .cardio, [], hevy: ["Treadmill"]),
        ex("Cycling", .other, .cardio, [], hevy: ["Cycling"]),
        ex("Stretching", .other, .time, [], hevy: ["Stretching"]),

        // His own
        ex("Cat Girl", .other, [], hevy: ["Cat Girl"], custom: true),
        ex("For Arm Go Brr Between Legs", .other, [.forearms], hevy: ["For Arm Go Brr Between Legs"], custom: true),
    ]

    // MARK: - Ladders

    private static func step(_ label: String, _ id: String, _ target: Target, _ note: String = "",
                             moveUp: MoveUpRule = .standard) -> LadderStep {
        LadderStep(label: label, exerciseId: id, target: target, note: note, moveUp: moveUp)
    }

    static let ladders: [Ladder] = [
        Ladder(id: "dragon-flag-ladder", name: "Dragon flag", steps: [
            step("hollow-body hold", "hollow-body-hold", Target(sets: 3, lo: 20, hi: 40, rest: 120)),
            step("tuck negatives", "dragon-flag-tuck-negatives", Target(sets: 3, lo: 5, hi: 5, rest: 120), "5–8 s lowering"),
            step("tuck reps", "dragon-flag-tuck", Target(sets: 3, lo: 3, hi: 6, rest: 120)),
            step("one-leg", "dragon-flag-one-leg", Target(sets: 3, lo: 3, hi: 6, rest: 120)),
            step("straddle", "dragon-flag-straddle", Target(sets: 3, lo: 3, hi: 6, rest: 120)),
            step("full negatives", "dragon-flag-negatives", Target(sets: 3, lo: 3, hi: 6, rest: 120)),
            step("full reps", "dragon-flag", Target(sets: 3, lo: 3, hi: 6, rest: 120)),
        ], hint: "Lower back arching or hips piking? Go back one step.", start: 1),
        Ladder(id: "pull-up-ladder", name: "Pull-up", steps: [
            step("assisted", "assisted-pull-up", Target(sets: 3, lo: 5, hi: 10, rirLo: 1, rirHi: 2, rest: 150), "With 3–5 s negatives"),
            step("bodyweight", "pull-up", Target(sets: 3, lo: 5, hi: 10, rirLo: 1, rirHi: 2, rest: 150), moveUp: .pullUpToWeighted),
            step("weighted", "weighted-pull-up", Target(sets: 3, lo: 5, hi: 8, rirLo: 1, rirHi: 2, rest: 150)),
        ], hint: "Fewer than 5 strict reps? Go back one step.", start: 1),
        Ladder(id: "pike-ladder", name: "Pike push-up", steps: [
            step("floor", "pike-push-up", Target(sets: 3, lo: 10, hi: 10, rirLo: 1, rirHi: 2, rest: 150)),
            step("feet-elevated", "feet-elevated-pike-push-up", Target(sets: 3, lo: 8, hi: 10, rirLo: 1, rirHi: 2, rest: 150)),
            step("wall negatives", "wall-hspu-negatives", Target(sets: 3, lo: 5, hi: 5, rest: 150), "Slow"),
            step("partial wall", "partial-wall-hspu", Target(sets: 3, lo: 5, hi: 10, rirLo: 1, rirHi: 2, rest: 150), "Onto a pad"),
            step("wall", "wall-hspu", Target(sets: 3, lo: 5, hi: 10, rirLo: 1, rirHi: 2, rest: 150)),
        ], hint: "Can’t control the way down? Go back one step.", start: 0),
    ]

    // MARK: - Routines

    /// Fixed ids, so the routines are the same on every launch.
    private static func uid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "7A0C0000-0000-4000-8000-%012d", n))!
    }

    private static func ladderItem(_ n: Int, _ id: String, warmup: [WarmupRamp] = []) -> RoutineItem {
        RoutineItem(id: uid(n), ladderId: id, target: Target(sets: 3, lo: 3, hi: 6, rest: 120), warmup: warmup)
    }

    private static func item(_ n: Int, _ id: String, _ target: Target, _ note: String = "",
                             alt: [String] = [], superset: Int? = nil, optional: Bool = false,
                             skipOnLegDays: Bool = false, warmup: [WarmupRamp] = []) -> RoutineItem {
        RoutineItem(id: uid(n), exerciseId: id, target: target, note: note, alternatives: alt,
                    superset: superset, optional: optional, skipOnLegDays: skipOnLegDays, warmup: warmup)
    }

    static let routines: [Routine] = [
        Routine(id: "push", name: "Push", short: "Push", items: [
            ladderItem(1, "dragon-flag-ladder"),
            ladderItem(2, "pike-ladder"),
            item(3, "incline-db-press", Target(sets: 3, lo: 6, hi: 10, rirLo: 1, rirHi: 2, rest: 150), "Upper chest priority",
                 warmup: [WarmupRamp(percent: 0.5, reps: 8), WarmupRamp(percent: 0.75, reps: 4)]),
            item(4, "weighted-dip", Target(sets: 3, lo: 6, hi: 10, rirLo: 1, rirHi: 2, rest: 150)),
            item(5, "flat-db-press", Target(sets: 2, lo: 8, hi: 12, rirLo: 1, rirHi: 1, rest: 120), "Drop first if recovery suffers"),
            item(6, "single-arm-cable-lateral-raise", Target(sets: 4, lo: 12, hi: 20, rirLo: 0, rirHi: 1, rest: 75),
                 "Optional lengthened partials after the last full rep", alt: ["db-lateral-raise"]),
            item(7, "overhead-triceps-extension-cable", Target(sets: 3, lo: 10, hi: 15, rirLo: 0, rirHi: 1, rest: 75), "Long head",
                 alt: ["overhead-triceps-extension-db"]),
        ]),
        Routine(id: "pull", name: "Pull", short: "Pull", items: [
            ladderItem(11, "dragon-flag-ladder"),
            ladderItem(12, "pull-up-ladder", warmup: [WarmupRamp(percent: 0, reps: 5)]),
            item(13, "lat-pulldown", Target(sets: 3, lo: 8, hi: 12, rirLo: 0, rirHi: 1, rest: 120), "1–1.5× shoulder width",
                 alt: ["single-arm-cable-pulldown"]),
            item(14, "seated-cable-row-v-grip", Target(sets: 3, lo: 8, hi: 12, rirLo: 1, rirHi: 1, rest: 120),
                 "V-grip, or wide grip with elbows flared", alt: ["seated-cable-row-bar-grip"]),
            item(15, "single-arm-cable-lateral-raise", Target(sets: 3, lo: 12, hi: 20, rirLo: 0, rirHi: 1, rest: 0),
                 alt: ["db-lateral-raise"], superset: 1),
            item(16, "rear-delt-fly-cable", Target(sets: 3, lo: 12, hi: 20, rirLo: 0, rirHi: 1, rest: 75),
                 alt: ["rear-delt-fly-machine", "single-arm-rear-delt-fly"], superset: 1),
            item(17, "bayesian-curl", Target(sets: 3, lo: 10, hi: 15, rirLo: 0, rirHi: 1, rest: 75)),
            item(18, "hammer-curl-db", Target(sets: 2, lo: 8, hi: 12, rirLo: 0, rirHi: 1, rest: 60),
                 alt: ["hammer-curl-cable"], skipOnLegDays: true),
        ]),
        Routine(id: "legs", name: "Legs (add-on)", short: "Legs", items: [
            item(21, "leg-press", Target(sets: 3, lo: 8, hi: 12, rirLo: 1, rirHi: 2, rest: 120),
                 alt: ["hack-squat", "goblet-squat"], warmup: [WarmupRamp(percent: 0.5, reps: 10)]),
            item(22, "romanian-deadlift-smith", Target(sets: 3, lo: 6, hi: 10, rirLo: 2, rirHi: 2, rest: 120), "Straps after pulling",
                 alt: ["romanian-deadlift-barbell"]),
            item(23, "lying-leg-curl", Target(sets: 2, lo: 10, hi: 15, rirLo: 1, rirHi: 1, rest: 75),
                 alt: ["seated-leg-curl", "calf-press", "seated-calf-raise"], optional: true),
        ]),
    ]
}
