import Foundation

// 0.34: per leg, what the new train and tunnel rules would have said, with the app's own `TrainRules` and `DeadReckon`:
// - trains: the stations you stood at and went through at speed (`TrainRules.seen`), and the trains the stopping
//   pattern rules out (`TrainRules.outByStops`): the one you were on should never be among them;
// - every leg: how dead reckoning (`DeadReckon.along`) would have done over the gaps in the GPS points: the reckoned
//   place against the first good point after each gap, along the track you went.
// (Old bus GPS moved on, 0.34's `RealPositions.advance`, needs the vehicles' own GPS of that moment: not in an export.)

struct TrainLook: Codable, Equatable {
    var stopped: Int
    var through: Int
    var ruledOut: [String]
    var truthRuledOut: Bool
}

struct ReckonLook: Codable, Equatable {
    /// Gaps of more than `DeadReckon.quietAfter` between good points.
    var gaps: Int
    /// Metres the reckoned place was off the first good point after a gap: the worst, and the median.
    var worst: Double?
    var median: Double?
}

enum TrainReplay {
    /// m: calls of two trains this close are the same station.
    static let sameStation = 300.0

    /// Where a track calls: the start of each piece, and the end of its last.
    static func calls(_ v: VehicleTrack) -> [GeoPoint] {
        var out = v.pieces.compactMap { $0.path.first }
        if let e = v.pieces.last?.path.last { out.append(e) }
        return out
    }

    /// The trains around the leg (a piece in its time), with the stopping pattern's view of them.
    static func of(_ leg: ReplayLeg, tracks: [VehicleTrack]) -> TrainLook? {
        guard WakeReplay.isTrain(leg) else { return nil }
        let fixes = leg.fixes.map(\.fix)
        let around = tracks.filter { v in v.isTrain && v.pieces.contains { $0.arrival >= leg.start && $0.departure <= leg.end } }
        guard !around.isEmpty else { return nil }
        // the stations: every call, the same station when within `sameStation` of one already found
        var stations: [GeoPoint] = []
        func station(_ p: GeoPoint) -> Int {
            if let i = stations.firstIndex(where: { Geo.metres($0, p) <= sameStation }) { return i }
            stations.append(p)
            return stations.count - 1
        }
        var calls: [String: Set<String>] = [:]
        for v in around { calls[v.tripId] = Set(Self.calls(v).map { "s\(station($0))" }) }
        var through: [String: Set<String>] = [:]
        for v in around {
            let path = v.pieces.flatMap(\.path)
            through[v.tripId] = Set(stations.indices.filter { i in Geo.project(stations[i], on: path).map { $0.crossTrack <= 150 } ?? false }.map { "s\($0)" })
        }
        var seen: [String: TrainRules.Seen] = [:]
        for (i, p) in stations.enumerated() { if let s = TrainRules.seen(fixes, at: p) { seen["s\(i)"] = s } }
        let out = TrainRules.outByStops(calls: calls, runsThrough: through, seen: seen)
        let lines = Dictionary(around.map { ($0.tripId, $0.line) }, uniquingKeysWith: { a, _ in a })
        let labels = out.sorted().map { FieldFormat.label($0, lines) }
        return TrainLook(stopped: seen.values.filter { $0 == .stopped }.count, through: seen.values.filter { $0 == .passedThrough }.count,
                         ruledOut: labels, truthRuledOut: leg.truth.map { labels.contains($0) } ?? false)
    }

    static func words(_ t: TrainLook) -> String {
        var s = "trains: stood at \(t.stopped) station\(t.stopped == 1 ? "" : "s"), through \(t.through) at speed"
        s += t.ruledOut.isEmpty ? " · the stopping pattern rules none out" : " · it rules out \(t.ruledOut.joined(separator: ", "))"
        if t.truthRuledOut { s += " (WRONG: the one you were on)" }
        return s
    }
}

enum ReckonReplay {
    static func of(_ leg: ReplayLeg) -> ReckonLook {
        let f = leg.fixes.map(\.fix).filter { DeadReckon.good(accuracy: $0.accuracy) }.sorted { $0.t < $1.t }
        guard f.count >= 3 else { return ReckonLook(gaps: 0) }
        var cum = [0.0]
        for i in 1..<f.count { cum.append(cum[i - 1] + Geo.metres(f[i - 1].p, f[i].p)) }
        var misses: [Double] = []
        for i in 1..<f.count where f[i].t.timeIntervalSince(f[i - 1].t) > DeadReckon.quietAfter {
            let a = f[i - 1]
            // its pace: the GPS's own speed, else between the last two good points before the gap
            var pace: Double? = a.speed.isFinite && a.speed >= 0 ? a.speed : nil
            if pace == nil, i >= 2 {
                let dt = a.t.timeIntervalSince(f[i - 2].t)
                if dt > 0 { pace = (cum[i - 1] - cum[i - 2]) / dt }
            }
            let e = DeadReckon.along(from: cum[i - 1], at: a.t, now: f[i].t, pace: pace, gps: nil, times: nil, end: cum.last ?? 0)
            misses.append(abs(e.metres - cum[i]))
        }
        let s = misses.sorted()
        let median: Double? = s.isEmpty ? nil : s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
        return ReckonLook(gaps: misses.count, worst: s.last, median: median)
    }

    static func words(_ r: ReckonLook) -> String {
        guard r.gaps > 0 else { return "reckon: no gaps over \(Int(DeadReckon.quietAfter)) s in the GPS points" }
        return "reckon: \(r.gaps) gap\(r.gaps == 1 ? "" : "s") over \(Int(DeadReckon.quietAfter)) s · the reckoned place off by "
            + "\(Int((r.median ?? 0).rounded())) m (median), \(Int((r.worst ?? 0).rounded())) m at worst"
    }
}
