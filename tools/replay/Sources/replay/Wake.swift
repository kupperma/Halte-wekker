import Foundation

// 0.33: when each wake rule would have rung on a leg, by the app's own `WakeRule`, from its GPS points.

/// When the rules ring on one leg, in seconds before its last GPS point (taken as its stop: a leg's points end where
/// it ended, at the stop when it ended there). By time it goes by your speed only (an export has no live arrivals),
/// along the track you went (the true distance left along the route).
struct WakeTimes: Codable, Equatable {
    var isTrain: Bool
    /// The distance rule (the bus's 2 km, the train's 5 km), and how far it was then.
    var byDistance: Double?
    var distanceMetres: Double?
    /// The time rule alone (3 min a train, 2 a bus), and how far it was then.
    var byTime: Double?
    var timeMetres: Double?
    /// The app's own ring line in the leg's log, and what it says fired ("by time 3 min (live)", "by distance").
    var logged: Double?
    var loggedWhy: String?

    /// Whichever comes first: what the app does by time.
    var first: Double? { [byDistance, byTime].compactMap { $0 }.max() }
}

enum WakeReplay {
    /// The leg is by train: one of its points' vehicles is a train ("train IC·a1b2").
    static func isTrain(_ leg: ReplayLeg) -> Bool {
        leg.fixes.contains { $0.veh?.hasPrefix("train") == true } || leg.lines.contains { $0.text.contains("train ") && $0.text.hasPrefix("start") }
    }

    static func of(_ leg: ReplayLeg, settings: WakeSettings = WakeSettings(), busMetres: Double = 2000, trainMetres: Double = 5000) -> WakeTimes {
        let train = isTrain(leg)
        let wake = train ? trainMetres : busMetres
        var out = WakeTimes(isTrain: train)
        let fixes = leg.fixes.map(\.fix).filter { $0.accuracy >= 0 && $0.accuracy < 250 }
        guard let start = fixes.first, let end = fixes.last, fixes.count >= 2 else { return out }
        // the track left from each point to the end
        var left = [Double](repeating: 0, count: fixes.count)
        for i in stride(from: fixes.count - 2, through: 0, by: -1) { left[i] = left[i + 1] + Geo.metres(fixes[i].p, fixes[i + 1].p) }
        var smoother = SpeedSmoother()
        var previous: Fix?
        for (i, f) in fixes.enumerated() {
            if f.accuracy < 100 {
                if let v = SpeedSmoother.reading(f, previous: previous) { smoother.add(v, at: f.t) }
                previous = f
            }
            // (within 20 s of the leg's start the app wakes silently: no ring)
            guard f.t.timeIntervalSince(start.t) >= 20 else { continue }
            let d = Geo.metres(f.p, end.p)
            let before = end.t.timeIntervalSince(f.t)
            if out.byDistance == nil, d <= wake { out.byDistance = before; out.distanceMetres = d }
            if out.byTime == nil {
                // (the time rule alone: a wake distance it never reaches)
                let input = WakeRule.Input(by: .time, minutes: settings.minutes(isTrain: train), isTrain: train, metres: d,
                                           routeMetres: left[i], wakeMetres: -1, liveArrival: nil, liveAge: nil,
                                           speed: smoother.speed(now: f.t), fromStartMetres: Geo.metres(f.p, start.p), now: f.t)
                if case .time? = WakeRule.decide(input) { out.byTime = before; out.timeMetres = d }
            }
        }
        if let ring = leg.lines.first(where: { $0.kind == "ride" && $0.text.hasPrefix("ring · ") }) {
            out.logged = end.t.timeIntervalSince(ring.at)
            out.loggedWhy = ring.text.components(separatedBy: " · ").dropFirst().first
        }
        return out
    }

    /// "distance rule 2.8 min before the end (2000 m) · time rule 3.0 min (5400 m) · the app rang 2.8 min before (by distance)"
    static func words(_ w: WakeTimes) -> String {
        func m(_ s: Double?) -> String { s.map { String(format: "%.1f min", $0 / 60) } ?? "never" }
        func at(_ d: Double?) -> String { d.map { " (\(Int($0.rounded())) m)" } ?? "" }
        var s = "\(w.isTrain ? "train" : "bus"): distance rule \(m(w.byDistance))\(at(w.distanceMetres)) · time rule \(m(w.byTime))\(at(w.timeMetres))"
        s += " before the end"
        if let l = w.logged { s += " · the app rang \(m(l)) before (\(w.loggedWhy ?? "?"))" } else { s += " · no ring in its log" }
        return s
    }
}
