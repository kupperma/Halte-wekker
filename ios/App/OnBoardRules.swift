import Foundation

/// The home's "you're on bus …" look (0.26.1). On 2026-11-19, walking at a change in Den Bosch, it picked buses by
/// their timetable alone: "9·8406 timetable 6 s" over "305·7821 gps 14 s", then "15·9583 timetable 15 s". A
/// timetable-only fit says only that a bus's times pass near your track; at walking speed many do.
enum OnBoardRules {
    /// m/s: moving like a bus or train (as `VehicleMatch.planFromSpot`).
    static let vehicleSpeed = 8.0

    /// Timetable-only: no live times and not judged by its own GPS.
    static func timetableOnly(_ j: Judgement) -> Bool { !j.realTime && j.evidence?.gps != true }

    /// s (0.26.2): a train judged by its live times or its timetable, not by its own GPS (NS's train positions), counts
    /// this much worse while another train passed by its own GPS. On 2026-11-19 on an Intercity out of Den Bosch the
    /// look said "SPR·9048 live 20 s | IC·6632 gps 22 s | IC·6558 gps 27 s → best SPR·9048": a Sprinter by its times
    /// beat the Intercity its own GPS put right with you. (Buses keep their order: `ChooseGPS` decides between them.)
    static let trainGPSEdge = VehicleMatch.chooseMargin

    /// The ones that passed, best first, as `VehicleMatch.rank` (with `planned`'s bonus), with `trainGPSEdge`: while
    /// a train passed by its own GPS, every train that passed without one comes `trainGPSEdge` seconds later.
    static func rank(_ judged: [Judgement], planned: String?) -> [Ranked] {
        let trainByGPS: Bool = judged.contains { $0.isTrain && VehicleMatch.passedByGPS($0) }
        guard trainByGPS else { return VehicleMatch.rank(judged, planned: planned) }
        let edged: [Judgement] = judged.map { (j: Judgement) -> Judgement in
            guard j.isTrain, j.evidence?.gps != true, case .success(let c) = j.result else { return j }
            return Judgement(id: j.id, line: j.line, isTrain: j.isTrain, realTime: j.realTime, evidence: j.evidence,
                             result: .success(c + trainGPSEdge))
        }
        return VehicleMatch.rank(edged, planned: planned)
    }

    /// The one you're on, of those that passed (cheapest first, as `rank`), or nil:
    /// - when one passed by its own GPS, a timetable-only one never comes before it (they're left out);
    /// - a timetable-only best counts only while you move like a vehicle (`vehicleSpeed`): your speed along its path
    ///   (or, with one fix, `yourSpeed`, the GPS's own).
    static func best(_ judged: [Judgement], yourSpeed: Double) -> String? {
        let byId = Dictionary(judged.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var ranked: [Ranked] = rank(judged, planned: nil)
        let anyGPS: Bool = judged.contains { VehicleMatch.passedByGPS($0) }
        if anyGPS { ranked = ranked.filter { r in byId[r.id].map { !timetableOnly($0) } ?? false } }
        guard let first = ranked.first, let j = byId[first.id] else { return nil }
        if timetableOnly(j) {
            let along: Double = j.evidence.map { $0.fixes > 1 ? $0.yourSpeed : max($0.yourSpeed, yourSpeed) } ?? yourSpeed
            guard along.isFinite, along >= vehicleSpeed else { return nil }
        }
        return first.id
    }

    /// The home may start a trip on the bus or train it found you on: no trip on (a running one is never restarted,
    /// least of all on the same one), and not one a trip already started on by itself or that you ended a ride on.
    static func mayAutoStart(_ tripId: String, idle: Bool, running: String?, blocked: Set<String>) -> Bool {
        idle && running != tripId && !blocked.contains(tripId)
    }

    // MARK: moving like a bus or train, by your track (0.26.2)

    static let trackWindow: TimeInterval = 60       // s: your fixes of the last minute…
    static let trackSpan: TimeInterval = 20         // …spanning at least this…
    static let trackAccuracy = 100.0                // …of this accuracy or better…
    static let trackSpeed = 5.0                     // m/s: …first to newest at least this fast…
    static let trackSteady = 3.5                    // m/s: …both halves at least this (one GPS jump isn't a ride)…
    static let trackMargin = 100.0                  // m: …and further apart than both accuracies and this

    /// Moving like a bus or train by where your fixes went, not by the GPS's own speed. On 2026-11-19 on an Intercity
    /// the home never looked for the train you were on for 14 minutes: in a train the GPS's speed is often unknown
    /// or unsure, and the other test (two positions 20 s apart) never had them, as the home asks on every fix.
    /// `speed`: first to newest at least this fast (`trackSpeed`; Fastest trip's "faster than a bike": 8).
    static func movingByTrack(_ fixes: [Fix], now: Date, speed: Double = trackSpeed) -> Bool {
        let w: [Fix] = fixes.filter { f in
            let age = now.timeIntervalSince(f.t)
            return age >= -1 && age <= trackWindow && f.accuracy.isFinite && f.accuracy >= 0 && f.accuracy <= trackAccuracy
        }.sorted { $0.t < $1.t }
        guard w.count >= 3, let a = w.first, let b = w.last else { return false }
        let span = b.t.timeIntervalSince(a.t)
        guard span >= trackSpan else { return false }
        let m = w[w.count / 2]
        func v(_ p: Fix, _ q: Fix) -> Double { Geo.metres(p.p, q.p) / max(1, q.t.timeIntervalSince(p.t)) }
        let d = Geo.metres(a.p, b.p)
        return d / span >= speed && d > a.accuracy + b.accuracy + trackMargin && v(a, m) >= trackSteady && v(m, b) >= trackSteady
    }

    static let lookEvery = 300.0                    // m: not on board, the home looks again this far from its last look…
    static let lookAtMost: TimeInterval = 20        // s: …but not sooner than this after it (at train speed 300 m is 10 s)

    /// The home looks again before its minute is up: you just started moving like a bus or train; or, not on board,
    /// you're `lookEvery` from where it last looked and that was `lookAtMost` ago or more (nil: no look yet).
    static func lookDue(startedMoving: Bool, onBoard: Bool, movedMetres: Double?, sinceLast: TimeInterval?) -> Bool {
        if startedMoving { return true }
        guard !onBoard, let m = movedMetres, m.isFinite, m > lookEvery else { return false }
        guard let s = sinceLast else { return true }
        return s >= lookAtMost
    }

    // MARK: the home's next-trip card while you move (0.26.2)

    static let movedLately: TimeInterval = 180      // s: at bus or train speed this recently (as the home's look)
    static let atItsStop = 300.0                    // m: from the first ride's stop, you're there

    /// No "time to leave" for a trip from somewhere you aren't, while you're on a bus or train: the one the home found
    /// you on, or at bus or train speed in the last 3 minutes and not at the first ride's stop (`firstStopMetres`; nil:
    /// not known). On 2026-11-19 on the Intercity: "Now · time to leave · SPR 08:21 from Eindhoven".
    static func leaveCardHidden(onBoard: Bool, vehicleMovedAgo: TimeInterval?, firstStopMetres: Double?) -> Bool {
        if onBoard { return true }
        guard let a = vehicleMovedAgo, a >= 0, a < movedLately else { return false }
        guard let m = firstStopMetres, m.isFinite, m >= 0 else { return true }
        return m > atItsStop
    }
}

/// A trip you ended by hand before its last leg (0.26.2): on 2026-11-19 the trip to BUas (bus, train, bus) was ended
/// at the change in Den Bosch to reach the home, and the train after it was a trip from scratch. For a while the home
/// offers to go on with it, from the next leg, with its own look for the one you get on.
enum TripResume {
    static let within: TimeInterval = 30 * 60       // s after it ended
    static let nearItsStop = 1000.0                 // m from the leg's first stop: at the change still

    /// The leg it goes on with: at a change the next one; on a leg before the last, that leg. Nil: none (it had
    /// finished, or it ended on its last leg).
    static func leg(atChange: Bool, finished: Bool, index: Int, count: Int) -> Int? {
        guard !finished, index >= 0 else { return nil }
        if atChange { return index + 1 < count ? index + 1 : nil }
        return index + 1 < count ? index : nil
    }

    /// Offered while no trip runs, within `within` of the end, while you're on the way: moving like a bus or train, or
    /// within `nearItsStop` of that leg's first stop (`metresToItsStop`; nil: not known).
    static func offer(endedAt: Date, now: Date, idle: Bool, moving: Bool, metresToItsStop: Double?) -> Bool {
        guard idle else { return false }
        let ago = now.timeIntervalSince(endedAt)
        guard ago >= 0, ago <= within else { return false }
        if moving { return true }
        guard let m = metresToItsStop, m.isFinite, m >= 0 else { return false }
        return m <= nearItsStop
    }
}
