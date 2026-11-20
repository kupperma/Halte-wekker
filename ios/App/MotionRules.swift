import Foundation

// 0.33: Motion & Fitness (the phone's motion coprocessor, CMMotionActivityManager in Motion.swift) for three things,
// each only ever a hint next to your GPS, never instead of it:
// - noticing you got on sooner: "automotive" (medium or high) counts as moving like a bus or train at once, for the
//   home's on-board look and a trip's look for the one you got on;
// - battery: waiting at a stop or a change while it says stationary or walking, the trip's GPS is the rough one (as
//   Fastest trip's while you stand); riding while it says automotive steadily, the far tier comes on sooner;
// - fewer false "on the move": walking quickly, running or cycling (medium or high, below vehicle speeds) isn't a
//   vehicle.
// Without the permission (or with the setting off) nothing here is asked: everything is as before 0.33. The alarm, the
// wake distance and the backup alarm never depend on it. Plain values, so the rules can be tested.

/// What the coprocessor says you're doing. (CMMotionActivity can say several at once: in a bus at a stop "automotive"
/// and "stationary"; it's read as one, automotive first.)
enum MotionKind: String, Sendable { case stationary, walking, running, cycling, automotive, unknown }

enum MotionConfidence: Int, Comparable, Sendable {
    case low, medium, high
    static func < (a: MotionConfidence, b: MotionConfidence) -> Bool { a.rawValue < b.rawValue }
}

/// One activity as it was reported: from when.
struct MotionSample: Equatable, Sendable {
    let t: Date
    let kind: MotionKind
    let confidence: MotionConfidence
}

/// What it says now: the latest activity, how sure, and since when it has said that kind.
struct MotionNow: Equatable, Sendable {
    let kind: MotionKind
    let confidence: MotionConfidence
    let since: Date
    let at: Date
}

enum MotionRules {
    /// Without live updates (a history answer after a wake-up), the latest activity older than this says nothing.
    static let stale: TimeInterval = 5 * 60
    /// Automotive this long is "steadily".
    static let steadyFor: TimeInterval = 180
    /// m/s (43 km/h): faster than this, walking or cycling is you in the aisle of a moving train, not your own speed.
    static let afootTop = 12.0
    /// s between a trip's looks for the one you got on while you stand or walk about at the stop (the fixes still move it on).
    static let slowLook: TimeInterval = 15
    /// m: further from the stop it's going to than its wake distance and this, the rough GPS may do while you wait.
    static let waitMargin = 2000.0
    /// s: the first look after you leave one of your stations: soon in a vehicle, else as before.
    static let regionLookSoon: TimeInterval = 12
    static let regionLookUsual: TimeInterval = 35
    /// s of samples kept.
    static let keep: TimeInterval = 15 * 60

    /// What it says at `at`: the latest sample by then. `since`: back over the samples of the same kind (a different
    /// one of low confidence in between doesn't break the run). `live`: updates are coming in, so the latest holds
    /// until the next; else it's from a history answer and holds `stale` at most.
    static func now(_ samples: [MotionSample], at: Date, live: Bool) -> MotionNow? {
        let past = samples.filter { $0.t <= at.addingTimeInterval(1) }.sorted { $0.t < $1.t }
        guard let last = past.last else { return nil }
        if !live && at.timeIntervalSince(last.t) > stale { return nil }
        var since = last.t
        for s in past.reversed().dropFirst() {
            if s.kind == last.kind { since = s.t; continue }
            if s.confidence == .low { continue }
            break
        }
        return MotionNow(kind: last.kind, confidence: last.confidence, since: since, at: last.t)
    }

    private static func sure(_ m: MotionNow?) -> MotionNow? { m.flatMap { $0.confidence >= .medium ? $0 : nil } }

    /// In a car, bus or train, by its word (medium or high).
    static func inVehicle(_ m: MotionNow?) -> Bool { sure(m)?.kind == .automotive }

    /// In a vehicle for `steadyFor` or longer.
    static func steadyVehicle(_ m: MotionNow?, now: Date) -> Bool {
        guard inVehicle(m), let m else { return false }
        return now.timeIntervalSince(m.since) >= steadyFor
    }

    /// On your own feet or wheels: walking, running or cycling.
    static func afoot(_ m: MotionNow?) -> Bool {
        guard let k = sure(m)?.kind else { return false }
        return k == .walking || k == .running || k == .cycling
    }

    /// Standing or walking about.
    static func still(_ m: MotionNow?) -> Bool {
        guard let k = sure(m)?.kind else { return false }
        return k == .stationary || k == .walking
    }

    /// Not a vehicle, whatever the fixes say: afoot, at a speed you can do yourself (`speed`: yours; nil: not known).
    static func notAVehicle(_ m: MotionNow?, speed: Double?) -> Bool {
        guard afoot(m) else { return false }
        let v = speed.flatMap { $0.isFinite ? $0 : nil } ?? 0
        return v < afootTop
    }

    /// Moving like a bus or train: it says automotive, or the fixes say so and it doesn't say you're afoot.
    static func movingLikeVehicle(byFixes: Bool, motion m: MotionNow?, speed: Double?) -> Bool {
        if inVehicle(m) { return true }
        return byFixes && !notAVehicle(m, speed: speed)
    }

    /// A trip's next look for the one you got on, `base` seconds from now as before; standing or walking about (and
    /// the fixes not moving) `slowLook`. (Automotive starts one at once: `Motion.kick`.)
    static func lookWait(base: TimeInterval, motion m: MotionNow?, movingByFixes: Bool) -> TimeInterval {
        guard still(m), !movingByFixes else { return base }
        return max(base, slowLook)
    }

    /// The trip's rough GPS while you wait for the one you get on (at a stop, or at a change): you stand or walk about,
    /// the fixes don't say you move, and the stop it's going to is further than its wake distance and `waitMargin`.
    static func waitLow(waiting: Bool, motion m: MotionNow?, movingByFixes: Bool, metresToStop: Double?, wakeMetres: Double) -> Bool {
        guard waiting, still(m), !movingByFixes else { return false }
        guard let d = metresToStop, d.isFinite, wakeMetres.isFinite else { return false }
        return d > wakeMetres + waitMargin
    }

    /// The first look after leaving one of your stations.
    static func firstRegionLook(_ m: MotionNow?) -> TimeInterval { inVehicle(m) ? regionLookSoon : regionLookUsual }

    /// The samples worth keeping: those of the last `keep`, and the one before them (what was going on then).
    static func trim(_ samples: [MotionSample], now: Date) -> [MotionSample] {
        let sorted = samples.sorted { $0.t < $1.t }
        let from = now.addingTimeInterval(-keep)
        let recent = sorted.filter { $0.t >= from }
        guard let before = sorted.last(where: { $0.t < from }) else { return recent }
        return [before] + recent
    }
}
