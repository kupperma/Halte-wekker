import XCTest

final class WorkoutProgramTests: XCTestCase {
    private let lib = WorkoutProgram.exercises

    private func ex(_ id: String) throws -> Exercise {
        try XCTUnwrap(WorkoutProgram.exercise(id, in: lib), id)
    }

    private func routine(_ id: String) throws -> Routine {
        try XCTUnwrap(WorkoutProgram.routines.first { $0.id == id }, id)
    }

    private let hevyNames = [
        "Incline Bench Press (Dumbbell)",
        "Bench Press (Dumbbell)",
        "Bench Press (Smith Machine)",
        "Chest Fly (Machine)",
        "Butterfly (Pec Deck)",
        "Cable Fly Crossovers",
        "Triceps Dip Weighted",
        "Triceps Dip",
        "Pike Pushup",
        "Shoulder Press (Dumbbell)",
        "Seated Shoulder Press (Machine)",
        "Lateral Raise (Dumbbell)",
        "Single Arm Lateral Raise (Cable)",
        "Rear Delt Reverse Fly (Cable)",
        "Rear Delt Reverse Fly (Machine)",
        "Reverse Fly Single Arm (Cable)",
        "Shrug (Machine)",
        "Pull Up (Assisted)",
        "Pull Up",
        "Pull Up (Weighted)",
        "Lat Pulldown (Cable)",
        "Seated Cable Row - V Grip (Cable)",
        "Seated Cable Row - Bar Grip",
        "Dead Hang",
        "Bayesian Curl",
        "Bicep Curl (Cable)",
        "Bicep Curl (Dumbbell)",
        "Preacher Curl (Machine)",
        "Hammer Curl (Dumbbell)",
        "Hammer Curl (Cable)",
        "Reverse Curl (Barbell)",
        "Triceps Rope Pushdown",
        "Triceps Pushdown",
        "Tricep Push down V-grip",
        "Tricep Push downs Single Handed",
        "Overhead Triceps Extension (Cable)",
        "Triceps Kickback (Dumbbell)",
        "Seated Palms Up Wrist Curl",
        "Seated Wrist Extension (Barbell)",
        "Behind the Back Bicep Wrist Curl (Barbell)",
        "Leg Press (Machine)",
        "Leg Press Horizontal (Machine)",
        "Squat (Smith Machine)",
        "Squat (Machine)",
        "Romanian Deadlift (Smith Machine)",
        "Lying Leg Curl (Machine)",
        "Seated Leg Curl (Machine)",
        "Leg Extension (Machine)",
        "Hip Abduction (Machine)",
        "Hip Adduction (Machine)",
        "Calf Press (Machine)",
        "Seated Calf Raise",
        "Dragon Flag",
        "Crunch (Machine)",
        "Cable Crunch",
        "Leg Raise Parallel Bars",
        "Hanging Leg Raise",
        "Sit Up (Weighted)",
        "Decline Crunch (Weighted)",
        "Ab Wheel",
        "Walking",
        "Treadmill",
        "Cycling",
        "Stretching",
        "Cat Girl",
        "For Arm Go Brr Between Legs",
    ]

    func test_everyHevyNameMatches() {
        XCTAssertEqual(hevyNames.count, 66)
        for name in hevyNames {
            XCTAssertNotNil(WorkoutProgram.match(hevy: name, in: lib), name)
        }
        let all = lib.flatMap(\.hevyNames).map { $0.lowercased() }
        XCTAssertEqual(all.count, Set(all).count)
        XCTAssertEqual(Set(all), Set(hevyNames.map { $0.lowercased() }))
        XCTAssertEqual(WorkoutProgram.match(hevy: "  incline bench press (dumbbell) ", in: lib)?.id, "incline-db-press")
        XCTAssertNil(WorkoutProgram.match(hevy: "Bench Press (Barbell)", in: lib))
    }

    func test_specificMatches() {
        XCTAssertEqual(WorkoutProgram.match(hevy: "Bench Press (Dumbbell)", in: lib)?.id, "flat-db-press")
        let dip = WorkoutProgram.match(hevy: "Triceps Dip Weighted", in: lib)
        XCTAssertEqual(dip?.id, "weighted-dip")
        XCTAssertEqual(dip?.kind, .weighted)
        XCTAssertEqual(WorkoutProgram.match(hevy: "Pull Up (Assisted)", in: lib)?.kind, .assisted)
        XCTAssertEqual(WorkoutProgram.match(hevy: "Dead Hang", in: lib)?.kind, .time)
        XCTAssertEqual(WorkoutProgram.match(hevy: "Walking", in: lib)?.kind, .cardio)
        XCTAssertEqual(WorkoutProgram.match(hevy: "Pike Pushup", in: lib)?.id, "pike-push-up")
    }

    func test_idsUniqueAndReferencesResolve() throws {
        let ids = lib.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
        for e in lib { XCTAssertEqual(e.id, WorkoutProgram.slug(e.name), e.name) }
        let ladderIds = Set(WorkoutProgram.ladders.map(\.id))
        for r in WorkoutProgram.routines {
            for item in r.items {
                XCTAssertTrue((item.exerciseId == nil) != (item.ladderId == nil), r.id)
                if let id = item.exerciseId { XCTAssertNotNil(WorkoutProgram.exercise(id, in: lib), id) }
                if let id = item.ladderId { XCTAssertTrue(ladderIds.contains(id), id) }
                for a in item.alternatives { XCTAssertNotNil(WorkoutProgram.exercise(a, in: lib), a) }
            }
        }
        for l in WorkoutProgram.ladders {
            for s in l.steps { XCTAssertNotNil(WorkoutProgram.exercise(s.exerciseId, in: lib), s.exerciseId) }
        }
        let itemIds = WorkoutProgram.routines.flatMap(\.items).map(\.id)
        XCTAssertEqual(itemIds.count, Set(itemIds).count)
    }

    func test_routines() throws {
        let push = try routine("push")
        XCTAssertEqual(push.items.map { $0.exerciseId ?? $0.ladderId }, [
            "dragon-flag-ladder", "pike-ladder", "incline-db-press", "weighted-dip", "flat-db-press",
            "single-arm-cable-lateral-raise", "overhead-triceps-extension-cable",
        ])
        let incline = push.items[2]
        XCTAssertEqual(incline.target, Target(sets: 3, lo: 6, hi: 10, rirLo: 1, rirHi: 2, rest: 150))
        XCTAssertEqual(incline.note, "Upper chest priority")

        let pull = try routine("pull")
        XCTAssertEqual(pull.items.count, 8)
        let lateral = try XCTUnwrap(pull.items.first { $0.exerciseId == "single-arm-cable-lateral-raise" })
        let fly = try XCTUnwrap(pull.items.first { $0.exerciseId == "rear-delt-fly-cable" })
        let hammer = try XCTUnwrap(pull.items.first { $0.exerciseId == "hammer-curl-db" })
        XCTAssertEqual(lateral.superset, 1)
        XCTAssertEqual(fly.superset, 1)
        XCTAssertEqual(lateral.target.rest, 0)
        XCTAssertTrue(hammer.skipOnLegDays)

        let legs = try routine("legs")
        XCTAssertEqual(legs.name, "Legs (add-on)")
        XCTAssertEqual(legs.short, "Legs")
        XCTAssertTrue(try XCTUnwrap(legs.items.first { $0.exerciseId == "lying-leg-curl" }).optional)
        let rdl = try XCTUnwrap(legs.items.first { $0.exerciseId == "romanian-deadlift-smith" })
        XCTAssertTrue(rdl.target.rirLo == 2 && rdl.target.rirHi == 2)
    }

    func test_ladders() throws {
        let dragon = try XCTUnwrap(WorkoutProgram.ladders.first { $0.id == "dragon-flag-ladder" })
        XCTAssertEqual(dragon.steps.map(\.label), ["hollow-body hold", "tuck negatives", "tuck reps", "one-leg",
                                                    "straddle", "full negatives", "full reps"])
        XCTAssertEqual(dragon.start, 1)
        let pull = try XCTUnwrap(WorkoutProgram.ladders.first { $0.id == "pull-up-ladder" })
        XCTAssertEqual(pull.steps.count, 3)
        XCTAssertEqual(pull.steps[1].moveUp, .pullUpToWeighted)
        let pike = try XCTUnwrap(WorkoutProgram.ladders.first { $0.id == "pike-ladder" })
        XCTAssertEqual(pike.steps.count, 5)
        XCTAssertEqual(pike.start, 0)
    }

    func test_ownExercises() throws {
        let cat = try ex("cat-girl")
        XCTAssertTrue(cat.primary.isEmpty && cat.secondary.isEmpty)
        XCTAssertTrue(cat.custom)
        XCTAssertEqual(try ex("for-arm-go-brr-between-legs").primary, [.forearms])
    }

    func test_programMuscles() throws {
        let dip = try ex("weighted-dip")
        XCTAssertEqual(dip.primary, [.chest])
        XCTAssertEqual(dip.secondary, [.triceps, .frontDelts])
        let pull = try ex("pull-up")
        XCTAssertEqual(pull.primary, [.lats])
        XCTAssertEqual(pull.secondary, [.biceps])
        let row = try ex("seated-cable-row-v-grip")
        XCTAssertEqual(row.primary, [.lats])
        XCTAssertEqual(row.secondary, [.rearDelts, .biceps])
        let press = try ex("leg-press")
        XCTAssertEqual(press.primary, [.quads, .glutes])
        XCTAssertEqual(press.secondary, [])
    }

    func test_slug() {
        XCTAssertEqual(WorkoutProgram.slug("Seated cable row (V-grip)"), "seated-cable-row-v-grip")
        XCTAssertEqual(WorkoutProgram.slug("For Arm Go Brr Between Legs"), "for-arm-go-brr-between-legs")
    }
}
