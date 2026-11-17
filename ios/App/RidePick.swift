import Foundation

/// The "I'm actually on…" sheet (0.20.5): during a ride, the buses and trains that could be the one you're on right
/// now, so you can correct the app when it picked the wrong one. Plain values, so the gathering and the order are tested.
enum RidePick {
    static let near = 600.0             // m: one of the map pieces around you this close (by its own GPS, else by its times)
    static let limit = 8                // rows at most (the one it shows and the matcher's candidates are always there)
    static let slack: TimeInterval = 30 // s before its first piece and after its last its times still put it at that end

    struct Row: Equatable, Sendable, Identifiable {
        let tripId: String
        let line: String
        let isTrain: Bool
        var mode = ""
        var headsign = ""               // where it's going, as the screens write a place ("" not known yet)
        let metres: Double?             // how far from you (nil: not known)
        let byGPS: Bool                 // …by its own GPS fix (else by its times)
        let moves: Bool                 // it passed the matcher's tests on your fixes: it moves with you
        let current: Bool               // the one the app thinks you're on
        let candidate: Bool             // the matcher has it in the running
        var id: String { tripId }
    }

    /// The rows to list, best first (`rank`):
    /// - the one it shows (`current`) and the matcher's candidates, always;
    /// - of the others (the vehicles of the live map pieces around you), the ones that move with you, and the ones within
    ///   `near` (600 m) of you, by their own GPS fix when they have a fresh one, else by their times;
    /// - at most `limit`, the one it shows and the candidates kept first.
    /// How far: by its GPS when it was judged by it (along its road and across it, at your newest fix), else straight
    /// to its fix; without one by its times the same way (judged: along and across its road; not: straight to where its
    /// times put it now). `judged`: the matcher's judgements on your fixes (one that passed moves with you).
    static func gather(here: GeoPoint, now: Date, tracks: [VehicleTrack], judged: [Judgement], candidates: [String],
                       current: String?, modes: [String: String] = [:], near: Double = RidePick.near,
                       limit: Int = RidePick.limit) -> [Row] {
        let byId = Dictionary(judged.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let wanted = Set(candidates)
        var seen = Set<String>()
        var rows: [Row] = []
        for v in tracks where seen.insert(v.tripId).inserted {
            let j = byId[v.tripId]
            let e = j?.evidence
            var metres: Double?
            var gps = false
            if let e, e.gps {
                metres = apart(e); gps = true
            } else if let g = v.gps {
                metres = Geo.metres(here, g.fix.point); gps = true
            } else if let e {
                metres = apart(e)
            } else if let p = timesPoint(v, at: now) {
                metres = Geo.metres(here, p)
            }
            if let m = metres, !m.isFinite { metres = nil }
            var moves = false
            if case .success? = j?.result { moves = true }
            let isCurrent = v.tripId == current, isCandidate = wanted.contains(v.tripId)
            guard isCurrent || isCandidate || moves || (metres.map { $0 <= near } ?? false) else { continue }
            rows.append(Row(tripId: v.tripId, line: v.line, isTrain: v.isTrain, mode: modes[v.tripId] ?? "", metres: metres,
                            byGPS: gps, moves: moves, current: isCurrent, candidate: isCandidate))
        }
        let ranked = rank(rows)
        guard ranked.count > limit else { return ranked }
        let kept = ranked.filter { $0.current || $0.candidate }
        let rest = ranked.filter { !($0.current || $0.candidate) }.prefix(max(0, limit - kept.count))
        return rank(kept + rest)
    }

    /// Best first: the ones that move with you, then the nearest (one whose distance isn't known last), then the one
    /// it shows, then by trip id.
    static func rank(_ rows: [Row]) -> [Row] {
        rows.sorted { a, b in
            if a.moves != b.moves { return a.moves }
            let ma = a.metres ?? .infinity, mb = b.metres ?? .infinity
            if ma != mb { return ma < mb }
            if a.current != b.current { return a.current }
            return a.tripId < b.tripId
        }
    }

    /// How far apart you and it are by the evidence: along its road and across it.
    private static func apart(_ e: Evidence) -> Double {
        (e.offset * e.offset + e.crossTrack * e.crossTrack).squareRoot()
    }

    /// Where its times put it at `t`: inside a piece by time along its road; waiting at a stop between two pieces at
    /// the earlier one's end; up to `slack` before its first or after its last at that end. Nil otherwise.
    static func timesPoint(_ v: VehicleTrack, at t: Date) -> GeoPoint? {
        let ps = v.pieces.filter { !$0.path.isEmpty }.sorted { $0.departure < $1.departure }
        guard let first = ps.first, let last = ps.last else { return nil }
        if let p = ps.last(where: { $0.departure <= t && t <= $0.arrival }) {
            let d = p.arrival.timeIntervalSince(p.departure)
            let f = d > 0 ? min(1, max(0, t.timeIntervalSince(p.departure) / d)) : 1
            return point(on: p.path, at: f)
        }
        if t < first.departure { return t >= first.departure.addingTimeInterval(-slack) ? first.path.first : nil }
        if t > last.arrival { return t <= last.arrival.addingTimeInterval(slack) ? last.path.last : nil }
        return ps.last(where: { $0.arrival <= t })?.path.last
    }

    /// The point `fraction` (0…1) of the way along a path.
    static func point(on path: [GeoPoint], at fraction: Double) -> GeoPoint? {
        guard let start = path.first else { return nil }
        let total = Geo.length(path)
        guard path.count > 1, total > 0, fraction.isFinite else { return start }
        var want = min(1, max(0, fraction)) * total
        for i in 1..<path.count {
            let l = Geo.metres(path[i - 1], path[i])
            if want <= l || i == path.count - 1 {
                let u = l > 0 ? min(1, want / l) : 0
                let a = path[i - 1], b = path[i]
                return GeoPoint(lat: a.lat + (b.lat - a.lat) * u, lon: a.lon + (b.lon - a.lon) * u)
            }
            want -= l
        }
        return path.last
    }

    // MARK: what the sheet says

    /// "Bus 306", "Intercity", "Sprinter", "IC 2": as the ride screens name it.
    static func what(line: String, isTrain: Bool) -> String {
        if isTrain { return line == "IC" ? "Intercity" : line == "SPR" ? "Sprinter" : line.isEmpty ? "Train" : line }
        return "Bus \(line.isEmpty ? "?" : line)"
    }

    /// "Bus 306 to Uden" (without a known headsign: "Bus 306").
    static func title(line: String, isTrain: Bool, headsign: String) -> String {
        let w = what(line: line, isTrain: isTrain)
        let h = headsign.trimmingCharacters(in: .whitespaces)
        return h.isEmpty ? w : "\(w) to \(h)"
    }

    /// "120 m from you · GPS", "1.4 km from you · by its times"; not known: "GPS" or "by its times" alone.
    static func detail(metres: Double?, byGPS: Bool) -> String {
        let how = byGPS ? "GPS" : "by its times"
        guard let m = metres, m.isFinite, m >= 0 else { return how }
        let far = m < 1000 ? "\(Int((m / 10).rounded()) * 10) m" : String(format: "%.1f km", m / 1000)
        return "\(far) from you · \(how)"
    }

    /// The question after a pick by hand, off its road a while: "Still on bus 306?", "Still on the Intercity?".
    static func stillOn(line: String, isTrain: Bool) -> String {
        isTrain ? "Still on the \(what(line: line, isTrain: true))?" : "Still on bus \(line.isEmpty ? "?" : line)?"
    }

    /// "bus 3 at 08:12", "bus 3 at 08:12 and the Intercity at 08:40", "a, b and c".
    static func joined(_ parts: [String]) -> String {
        guard let last = parts.last else { return "" }
        return parts.count == 1 ? last : parts.dropLast().joined(separator: ", ") + " and " + last
    }

    /// What it says before switching to one that doesn't go to this leg's stop (`to`): where you'd get off by the plan
    /// again from it, and what then (`then`, `end`: "BUas at 08:31"); without a plan, that it still wakes you for `to`
    /// by your location.
    static func doesntGo(_ what: String, to: String, getOff: String?, then: [String], end: String?) -> String {
        guard let getOff, !getOff.isEmpty else {
            return "\(what) doesn’t go to \(to), and no way on from it was found just now. Pick it anyway and it still wakes you for \(to) by your location."
        }
        let rest = then.isEmpty ? "" : ", then \(joined(then))"
        let there = end.map { ". \($0)" } ?? ""
        return "\(what) doesn’t go to \(to): you’d get off at \(getOff)\(rest)\(there)."
    }
}

/// After you said by hand which one you're on during a ride (the "I'm actually on…" sheet, 0.20.5): the matcher keeps
/// looking, and its "same bus" looks still go in the field log, but it never switches away by itself for the rest of
/// that leg. Once your GPS has been clearly off that one's road (today's road check, `VehicleMatch.offRoad`: 300 m from
/// a bus's road, 700 m from a train's) for 3 minutes, it asks you once whether you're still on it. Nothing else changes:
/// the alarm, the arrival by GPS, the change and its rules go on as before.
struct HandLock: Equatable, Sendable {
    let tripId: String?             // the one you picked; nil: "none of these: just use my location"
    let leg: Int                    // the leg you picked it on: it holds for that leg only
    var offSince: Date? = nil       // off its road, look by look, since then
    var asked = false               // the question was asked (once a pick)

    static let askAfter: TimeInterval = 180

    /// The matcher may change the ride's vehicle by itself (switch, choose between some, plan again from another):
    /// without a lock, or with a lock from another leg.
    static func autoSwitch(_ lock: HandLock?, leg: Int) -> Bool {
        guard let lock else { return true }
        return lock.leg != leg
    }

    enum Look: Equatable, Sendable { case keep, ask }

    /// One look at the one you picked: `metres` your last fix from its road (nil, or not a number: its road not known,
    /// which says nothing). Never a switch: keep it, or, once it has been off its road `askAfter` (3 minutes), ask.
    /// Back on its road, the time off it starts again. "None of these" has no road to be off: it never asks.
    mutating func look(metres: Double?, isTrain: Bool, now: Date) -> Look {
        guard tripId != nil, let m = metres, m.isFinite else { return .keep }
        guard VehicleMatch.offRoad(m, isTrain: isTrain) else { offSince = nil; return .keep }
        let since = offSince ?? now
        offSince = since
        guard !asked, now.timeIntervalSince(since) >= Self.askAfter else { return .keep }
        asked = true
        return .ask
    }

    /// How long it has been off its road at `now` (0 while on it).
    func offFor(now: Date) -> TimeInterval { offSince.map { max(0, now.timeIntervalSince($0)) } ?? 0 }

    /// "Yes, I'm still on it": not asked again for this pick; the time off its road starts again.
    mutating func confirmed() { offSince = nil; asked = true }
}
