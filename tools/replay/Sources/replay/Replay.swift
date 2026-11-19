import Foundation

// A leg's GPS points through the app's on-board matcher, look by look, and how it did.

/// What was shown at a moment: the vehicle's key ("305·7821"), nil while nothing is.
struct Shown: Equatable {
    var at: Date
    var key: String?
}

/// How one timeline of what was shown did against the vehicle you were on.
struct Score: Equatable, Codable {
    /// Seconds from the leg's first point until it showed `truth` and kept it to the end; nil: it didn't end on it.
    var settle: Double?
    /// Times it changed from one vehicle to another.
    var flips: Int
    /// Share of the moments it showed `truth` (of all, nothing shown counts as not).
    var onTruth: Double
    /// Seconds until it first showed anything; nil: never.
    var firstShown: Double?
    /// The moments scored.
    var moments: Int
    /// The vehicle it ended on.
    var endedOn: String?

    var settled: Bool { settle != nil }

    static func of(_ timeline: [Shown], truth: String?, start: Date) -> Score {
        var flips = 0, last: String?
        for s in timeline {
            if let k = s.key { if let l = last, l != k { flips += 1 }; last = k }
        }
        var settle: Double?
        if let truth, let lastKey = timeline.last?.key, lastKey == truth {
            var i = timeline.count - 1
            while i > 0, timeline[i - 1].key == truth { i -= 1 }
            settle = max(0, timeline[i].at.timeIntervalSince(start))
        }
        let hits = timeline.filter { truth != nil && $0.key == truth }.count
        let first = timeline.first { $0.key != nil }.map { max(0, $0.at.timeIntervalSince(start)) }
        return Score(settle: settle, flips: flips, onTruth: timeline.isEmpty ? 0 : Double(hits) / Double(timeline.count),
                     firstShown: first, moments: timeline.count, endedOn: timeline.last?.key)
    }
}

/// One look of the replay, for `--looks`.
struct Look: Equatable {
    var at: Date
    var judged: Int
    var passed: [String]
    var outcome: String
}

enum Replayer {
    /// What the app showed: the vehicle tag of each GPS point (it's the ride's vehicle at that moment).
    static func logged(_ leg: ReplayLeg) -> [Shown] {
        leg.fixes.map { Shown(at: Date(timeIntervalSince1970: $0.t), key: vehicleKey($0.veh)) }
    }

    /// The vehicles with a piece around `t` (the app asks for 150 s back, 90 s ahead).
    static func around(_ tracks: [VehicleTrack], _ t: Date) -> [VehicleTrack] {
        let from = t.addingTimeInterval(-150), to = t.addingTimeInterval(90)
        return tracks.filter { v in v.pieces.contains { $0.arrival >= from && $0.departure <= to } }
    }

    /// The on-board matcher, look by look every `every` seconds over the leg's points: the points of the last two
    /// minutes up to the look judged against every vehicle around (`VehicleMatch.judgeAll`), ranked
    /// (`VehicleMatch.rank`, the best 10 and the shown one), and the shown one chosen with the app's hysteresis
    /// (`VehicleMatch.decide`). Not moving (2.5 m/s, as the app) or too few points: no look, what's shown stays.
    static func replay(_ leg: ReplayLeg, tracks: [VehicleTrack], every: TimeInterval = 10, planned: String? = nil,
                       looks: ((Look) -> Void)? = nil) -> [Shown] {
        let fixes = leg.fixes.map(\.fix)
        guard let first = fixes.first, let last = fixes.last else { return [] }
        var out: [Shown] = []
        var shown: String?
        var state = SwitchState()
        var t = first.t.addingTimeInterval(every)
        let lines = Dictionary(tracks.map { ($0.tripId, $0.line) }, uniquingKeysWith: { a, _ in a })
        func key(_ id: String?) -> String? { id.map { FieldFormat.label($0, lines) } }
        while t <= last.t.addingTimeInterval(0.5) {
            defer { t = t.addingTimeInterval(every) }
            let recent = fixes.filter { $0.t <= t && $0.t > t.addingTimeInterval(-120) && $0.accuracy < 150 }
            guard let newest = recent.last, recent.count >= 2 else { out.append(Shown(at: t, key: key(shown))); continue }
            let oldest = recent.first!
            let avg = Geo.metres(oldest.p, newest.p) / max(1, newest.t.timeIntervalSince(oldest.t))
            let speed = max(newest.speed, avg)
            guard speed > 2.5, VehicleMatch.enough(recent) else { out.append(Shown(at: t, key: key(shown))); continue }
            let near = around(tracks, t)
            let judged = VehicleMatch.judgeAll(recent, near)
            let ranked = VehicleMatch.top(VehicleMatch.rank(judged, planned: planned), keep: shown ?? planned)
            let unsure = Set(judged.compactMap { j -> String? in
                if case .failure(let r) = j.result, r.notSure { return j.id }
                return nil
            })
            let live = Set(near.filter(\.realTime).map(\.tripId))
            let d = VehicleMatch.decide(shown: shown, ranked: ranked, liveIds: live, unsure: unsure, state: &state, now: t)
            switch d {
            case .switchTo(let id): shown = id
            case .keep(let id): shown = id
            case .undecided, .none: break
            }
            out.append(Shown(at: t, key: key(shown)))
            looks?(Look(at: t, judged: judged.count, passed: ranked.compactMap { key($0.id) },
                        outcome: FieldFormat.outcome(d, lines: lines, choosing: false)))
        }
        return out
    }
}

/// One leg's result: what the app did (its points' vehicle tags) and what the matcher does now (the replay).
struct LegResult: Codable {
    var install: String
    var ride: String
    var leg: String
    var truth: String?
    var truthFrom: String
    var minutes: Double
    var points: Int
    var vehicles: Int
    var logged: Score
    var replayed: Score?
}

/// All legs together.
struct Summary: Codable, Equatable {
    var legs: Int
    var withTruth: Int
    var settled: Int
    var medianSettle: Double?
    var flips: Int
    var onTruth: Double

    static func of(_ scores: [Score], truths: Int) -> Summary {
        let settles = scores.compactMap(\.settle).sorted()
        let median: Double? = settles.isEmpty ? nil
            : settles.count % 2 == 1 ? settles[settles.count / 2] : (settles[settles.count / 2 - 1] + settles[settles.count / 2]) / 2
        let on = scores.isEmpty ? 0 : scores.map(\.onTruth).reduce(0, +) / Double(scores.count)
        return Summary(legs: scores.count, withTruth: truths, settled: settles.count, medianSettle: median,
                       flips: scores.map(\.flips).reduce(0, +), onTruth: on)
    }
}
