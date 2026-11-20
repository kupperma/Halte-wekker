import Foundation

// 0.38: picking the bus or train you're on faster and more reliably. Four kinds of evidence next to the matcher's own
// (`VehicleMatch`, `ChooseGPS`), each with its own rules here, plain values only so they can be tested:
// - `DepartMatch`: the moment you went from standing at a stop to moving, and which vehicle left that same stop then
//   (by its own GPS or its live times). Strong: it can settle a choice between two buses that drive side by side.
// - `UsualLine`: the line you usually take at this time of day on this kind of day. A tie-breaker only, with
//   hysteresis, and never against a vehicle that fits by its own GPS.
// - `BusStops`: the stopping pattern for buses. Soft: a candidate that drives past a stop where you stood still, or that
//   would have waited at a stop you went through at speed, counts a little worse once that has happened twice.
// - `AskSooner`: two still tied a minute after you left: ask which one, at once.

/// You stood at a stop, then went: where, since when you stood (`stood` seconds), and the moment you left (`t`: your
/// last fix still standing).
struct Departure: Equatable, Sendable {
    let t: Date
    let p: GeoPoint
    let stood: TimeInterval
}

/// What one vehicle's own GPS or live times say about the moment you left: `offBy` the seconds between when it left
/// that stop and when you did (nil: they don't say); `elsewhere` its own GPS put it away from the stop then, or still
/// at it after you had gone.
struct DepartClue: Equatable, Sendable {
    let id: String
    var offBy: TimeInterval? = nil
    var elsewhere = false
    var byGPS = false
}

enum DepartMatch {
    static let standFor: TimeInterval = 15      // s standing…
    static let standDrift = 25.0                // m: …every fix within this of the first one (or 1.5 × its accuracy)
    static let moveAway = 60.0                  // m: and then away from there (or 2 × the fixes' accuracy)…
    static let moveSpeed = 4.0                  // m/s: …and moving at the newest fix (its own speed, or the last step)
    static let maxAccuracy = 60.0               // m: rougher fixes are left out
    static let fresh: TimeInterval = 4 * 60     // s: an older moment says nothing about now
    static let window: TimeInterval = 60        // ± s: it left that stop this close to when you did
    static let notThen: TimeInterval = 90       // s: this far off, it didn't
    static let clearer: TimeInterval = 45       // s: …or this much further off than the one that did
    static let stopNear = 80.0                  // m: a piece of its trip that starts this close to where you stood
    static let gpsNear = 80.0                   // m: its own fix this close to where you stood is at that stop
    static let gpsAway = 300.0                  // m: its own fix this far from it, around the moment, is elsewhere
    static let gpsAround: TimeInterval = 30     // s around the moment for that
    static let stillThere: TimeInterval = 60    // s: its newest fix at the stop this long after you left: it stayed
    static let bonus = 30.0                     // s off its cost while looking for the one you got on
    static let looks = 2                        // looks in a row it passes before the choice settles on it

    /// The latest moment in `fixes` where you went from standing (`standFor` within `standDrift`) to moving: away from
    /// where you stood by `moveAway` and at `moveSpeed` at the newest fix. Nil: none (still standing, never stood).
    static func moment(_ fixes: [Fix]) -> Departure? {
        let f: [Fix] = fixes.filter { x in
            x.accuracy.isFinite && x.accuracy >= 0 && x.accuracy <= maxAccuracy && x.p.lat.isFinite && x.p.lon.isFinite
        }.sorted { $0.t < $1.t }
        guard f.count >= 3, let newest = f.last else { return nil }
        var found: Departure?
        var i = 0
        while i < f.count - 1 {
            let lim: Double = max(standDrift, 1.5 * f[i].accuracy)
            var j = i
            while j + 1 < f.count, Geo.metres(f[j + 1].p, f[i].p) <= lim { j += 1 }
            let stood: TimeInterval = f[j].t.timeIntervalSince(f[i].t)
            if j > i, j < f.count - 1, stood >= standFor {
                found = Departure(t: f[j].t, p: f[i].p, stood: stood)
                i = j + 1
            } else {
                i += 1
            }
        }
        guard let d = found else { return nil }
        let away: Double = Geo.metres(newest.p, d.p)
        guard away >= max(moveAway, 2 * newest.accuracy) else { return nil }
        return moving(f) ? d : nil
    }

    /// Moving at the newest fix: its own speed, else the step from the fix before.
    private static func moving(_ f: [Fix]) -> Bool {
        guard let last = f.last else { return false }
        if last.speed.isFinite, last.speed >= 0 { return last.speed >= moveSpeed }
        guard f.count >= 2 else { return false }
        let prev = f[f.count - 2]
        let dt: TimeInterval = last.t.timeIntervalSince(prev.t)
        guard dt > 0 else { return false }
        return Geo.metres(prev.p, last.p) / dt >= moveSpeed
    }

    /// A moment still worth judging by at `now`.
    static func usable(_ d: Departure?, now: Date) -> Departure? {
        guard let d else { return nil }
        let age: TimeInterval = now.timeIntervalSince(d.t)
        return age >= -5 && age <= fresh ? d : nil
    }

    /// What `v` says about the moment you left:
    /// - by its own GPS (its newest fix and the one before): a fix at the stop (`gpsNear`) from `window` before the
    ///   moment to `stillThere` after it: it left about then (`offBy` that fix's time from the moment, `window` at most
    ///   to count); its newest fix at the stop later than that: it stayed (`elsewhere`); `gpsAway` from it within
    ///   `gpsAround` of the moment: elsewhere;
    /// - by its live times (not a timetable-only one: two buses that leave together by the timetable say nothing): a
    ///   piece of its trip that starts within `stopNear` of where you stood, the one leaving nearest the moment.
    /// Its GPS goes first; its times only when its GPS says nothing.
    static func clue(_ v: VehicleTrack, at d: Departure) -> DepartClue {
        var c = DepartClue(id: v.tripId)
        if let g = v.gps {
            let fixes: [GPSFix] = [g.fix] + (g.previous.map { [$0] } ?? [])
            for (k, x) in fixes.enumerated() {
                let dt: TimeInterval = x.at.timeIntervalSince(d.t)
                let m: Double = Geo.metres(x.point, d.p)
                guard dt.isFinite, m.isFinite else { continue }
                if m <= gpsNear {
                    // (only its newest fix says it stayed: an older one is followed by a newer one)
                    if dt > stillThere {
                        if k == 0 { c.elsewhere = true; c.byGPS = true; c.offBy = nil; return c }
                        continue
                    }
                    if dt >= -window {
                        let off = abs(dt)
                        c.offBy = min(c.offBy ?? off, off); c.byGPS = true
                    }
                } else if m >= gpsAway, abs(dt) <= gpsAround {
                    c.elsewhere = true; c.byGPS = true; c.offBy = nil
                    return c
                }
            }
            if c.offBy != nil { return c }
        }
        guard v.realTime else { return c }
        let starts: [TimedPiece] = v.pieces.filter { p in p.path.first.map { Geo.metres($0, d.p) <= stopNear } ?? false }
        let offs: [TimeInterval] = starts.map { abs($0.departure.timeIntervalSince(d.t)) }.filter(\.isFinite)
        if let best = offs.min() { c.offBy = best }
        return c
    }

    /// Left then: within `window`, and not elsewhere.
    static func leftThen(_ c: DepartClue) -> Bool {
        guard !c.elsewhere, let o = c.offBy else { return false }
        return o <= window
    }

    /// Not then: elsewhere, or `notThen` off, or `clearer` further off than `than`.
    static func notThen(_ c: DepartClue, than best: TimeInterval) -> Bool {
        if c.elsewhere { return true }
        guard let o = c.offBy else { return false }
        return o >= notThen || o >= best + clearer
    }

    /// The one of `ids` that left the stop with you: exactly one left then, and every other one of `ids` clearly
    /// didn't (one the evidence says nothing about leaves it open: nil).
    static func pick(_ clues: [DepartClue], ids: [String]) -> String? {
        let byId = Dictionary(clues.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let near: [DepartClue] = ids.compactMap { byId[$0] }.filter(leftThen)
        guard near.count == 1, let one = near.first, let o = one.offBy, ids.count > 1 else { return nil }
        let others: [String] = ids.filter { $0 != one.id }
        let clear: Bool = others.allSatisfy { id -> Bool in
            guard let c = byId[id] else { return false }
            return notThen(c, than: o)
        }
        return clear ? one.id : nil
    }

    /// While looking for the one you got on: `bonus` seconds off the one that alone left then (others may say nothing).
    static func bonuses(_ clues: [DepartClue], ids: [String]) -> [String: Double] {
        let set = Set(ids)
        let near: [DepartClue] = clues.filter { set.contains($0.id) && leftThen($0) }
        guard near.count == 1, let one = near.first else { return [:] }
        return [one.id: -bonus]
    }

    /// "depart · stood 40 s, left 07:42:25 · 305·7821 left then (live 5 s) · 306·7954 not then (gps elsewhere)".
    static func logLine(_ d: Departure, _ clues: [DepartClue], lines: [String: String], calendar: Calendar) -> String {
        let c = calendar.dateComponents([.hour, .minute, .second], from: d.t)
        let at = String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        let parts: [String] = clues.map { x -> String in
            let how = x.byGPS ? "gps" : "live"
            let label = FieldFormat.label(x.id, lines)
            if x.elsewhere { return "\(label) not then (gps elsewhere)" }
            guard let o = x.offBy else { return "\(label) no word" }
            let s = Int(o.rounded())
            return "\(label) \(o <= window ? "left then" : "not then") (\(how) \(s) s)"
        }
        return "depart · stood \(Int(d.stood.rounded())) s, left \(at)" + (parts.isEmpty ? "" : " · " + parts.joined(separator: " · "))
    }
}

// MARK: - your usual line

/// One ride on a line, as learned (`HabitBook.lines`): the line, bus or train, the planned departure's minute of the
/// day, weekend or not, and how much it counts (a confirmed ride 1, the one you said you're on 2, the one you said
/// you're not on −1).
struct LineRide: Codable, Equatable, Sendable {
    let line: String
    let train: Bool
    let minute: Int
    let weekend: Bool
    let weight: Int
}

enum UsualLine {
    static let slot = 20                        // minutes either side of the time that count as the same ride
    static let needed = 3                       // what the rides of a line add up to before it's your usual one…
    static let share = 0.7                      // …and this share of all of this slot's rides among the lines here
    static let keep = 150                       // rides kept
    static let enterGap = 15.0                  // s: the usual one within this of the best: it breaks the tie…
    static let exitGap = 40.0                   // s: …and keeps it while within this (hysteresis)
    static let bonus = 20.0                     // s off its cost while it holds
    static let confirmed = 1, said = 2, notThis = -1

    /// The minute of the day (0–1439) at `d`.
    static func minute(_ d: Date, calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// Saturday or Sunday.
    static func weekend(_ d: Date, calendar: Calendar) -> Bool {
        let w = calendar.component(.weekday, from: d)
        return w == 1 || w == 7
    }

    /// The rides kept: at most `keep`, the oldest go first; a line without a name isn't kept.
    static func add(_ r: LineRide, to rides: [LineRide]) -> [LineRide] {
        guard !r.line.trimmingCharacters(in: .whitespaces).isEmpty, r.minute >= 0, r.minute < 1440 else { return rides }
        return Array((rides + [r]).suffix(keep))
    }

    /// What the rides of `line` in this slot (same kind, same kind of day, within `slot` minutes) add up to.
    static func score(line: String, train: Bool, minute: Int, weekend: Bool, _ rides: [LineRide]) -> Int {
        let k = line.lowercased()
        return rides.reduce(0) { sum, r in
            guard r.train == train, r.weekend == weekend, r.line.lowercased() == k, abs(r.minute - minute) <= slot else { return sum }
            return sum + r.weight
        }
    }

    /// Of `cands` (id, line, bus or train), the one of your usual line in this slot: its rides add up to `needed` and to
    /// `share` of the positive totals of the lines here, and it's the only one of that line among them (two 306s: the
    /// line can't tell them apart). Nil: none.
    static func usual(_ cands: [(id: String, line: String, train: Bool)], minute: Int, weekend: Bool, _ rides: [LineRide]) -> String? {
        var scores: [String: Int] = [:]
        for c in cands {
            let key = "\(c.train ? "t" : "b"):\(c.line.lowercased())"
            if scores[key] == nil { scores[key] = score(line: c.line, train: c.train, minute: minute, weekend: weekend, rides) }
        }
        let total: Int = scores.values.filter { $0 > 0 }.reduce(0, +)
        guard let best = scores.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }), best.value >= needed,
              Double(best.value) >= share * Double(total) else { return nil }
        let of: [String] = cands.filter { "\($0.train ? "t" : "b"):\($0.line.lowercased())" == best.key }.map(\.id)
        return of.count == 1 ? of[0] : nil
    }

    /// One candidate as the tie-breaker sees it: its cost this look, and whether it passed by its own GPS.
    struct Cand: Equatable, Sendable {
        let id: String
        let cost: Double
        let byGPS: Bool
    }

    /// The tie-breaker, with hysteresis: the usual one (`usual`) when it passed, within `enterGap` of the best one
    /// (within `exitGap` while it already `held`), and no other one passed by its own GPS while it didn't. Nil: no tie
    /// to break (or it may not), and a `held` one lets go.
    static func tieBreak(_ cands: [Cand], usual: String?, held: String?) -> String? {
        guard let u = usual, let mine = cands.first(where: { $0.id == u }), let best = cands.map(\.cost).min() else { return nil }
        if !mine.byGPS, cands.contains(where: { $0.id != u && $0.byGPS }) { return nil }
        let gap: Double = mine.cost - best
        let room: Double = held == u ? exitGap : enterGap
        return gap <= room ? u : nil
    }

    /// "305 at 07:41 on weekdays": your usual lines, most ridden first (lines adding up to `needed`, per slot of an hour).
    static func words(_ rides: [LineRide], limit: Int = 2) -> [String] {
        struct Key: Hashable { let line: String; let train: Bool; let hour: Int; let weekend: Bool }
        var n: [Key: Int] = [:]
        var minutes: [Key: [Int]] = [:]
        for r in rides {
            let k = Key(line: r.line, train: r.train, hour: r.minute / 60, weekend: r.weekend)
            n[k, default: 0] += r.weight
            if r.weight > 0 { minutes[k, default: []].append(r.minute) }
        }
        let good: [Key] = n.keys.filter { (n[$0] ?? 0) >= needed && !(minutes[$0] ?? []).isEmpty }
        let sorted: [Key] = good.sorted { a, b in
            let na = n[a] ?? 0, nb = n[b] ?? 0
            if na != nb { return na > nb }
            if a.hour != b.hour { return a.hour < b.hour }
            return a.line < b.line
        }
        return sorted.prefix(limit).map { k -> String in
            let ms: [Int] = (minutes[k] ?? [0]).sorted()
            let m: Int = ms[ms.count / 2]
            let what: String = k.train ? (k.line == "IC" ? "Intercity" : k.line == "SPR" ? "Sprinter" : k.line) : k.line
            let hhmm = String(format: "%02d:%02d", m / 60, m % 60)
            return "\(what) at \(hhmm) \(k.weekend ? "at weekends" : "on weekdays")"
        }
    }
}

// MARK: - the stopping pattern for buses

enum BusStops {
    enum Seen: Equatable, Sendable { case stood, through }

    static let standFor: TimeInterval = 15      // s standing…
    static let standNear = 40.0                 // m: …this close to the stop (or the fix's accuracy, up to 60 m)…
    static let standDrift = 25.0                // m: …every fix within this of the first (or 1.5 × its accuracy)
    static let throughFrom = 120.0              // m: through it: from this far before it to this far after it…
    static let throughNear = 40.0               // m: …passing this close…
    static let throughSpeed = 4.0               // m/s: …every step at least this fast…
    static let throughGap: TimeInterval = 15    // s: …with fixes at most this far apart (else no telling)
    static let maxAccuracy = 50.0               // m: rougher fixes are left out
    static let serves = 60.0                    // m: one of its stops this close to it: it serves it
    static let passes = 40.0                    // m: its road this close: it drives past it
    static let dwell: TimeInterval = 45         // s its times have it wait at a stop (a timing stop): it halts there
    static let needed = 2                       // observations against it before it counts
    static let penalty = 20.0                   // s per observation once it counts…
    static let maxPenalty = 60.0                // …this much at most

    /// What your fixes say you did at a bus stop: stood there (`standFor` within `standNear`), went through it at
    /// speed (from `throughFrom` before to `throughFrom` after, passing within `throughNear`, every step `throughSpeed`
    /// or more), or nil (not by it, not past it yet, or no telling).
    static func seen(_ fixes: [Fix], at s: GeoPoint) -> Seen? {
        let f: [Fix] = fixes.filter { $0.accuracy.isFinite && $0.accuracy >= 0 && $0.accuracy <= maxAccuracy }.sorted { $0.t < $1.t }
        guard f.count >= 3 else { return nil }
        let d: [Double] = f.map { Geo.metres($0.p, s) }
        for i in f.indices where d[i] <= max(standNear, min(60, f[i].accuracy)) {
            let lim: Double = max(standDrift, 1.5 * f[i].accuracy)
            var j = i
            while j + 1 < f.count, Geo.metres(f[j + 1].p, f[i].p) <= lim { j += 1 }
            if j > i, f[j].t.timeIntervalSince(f[i].t) >= standFor { return .stood }
        }
        guard let k = d.indices.min(by: { d[$0] < d[$1] }), d[k] <= throughNear else { return nil }
        guard let a = (0..<k).last(where: { d[$0] >= throughFrom }),
              let b = ((k + 1)..<f.count).first(where: { d[$0] >= throughFrom }) else { return nil }
        for i in a..<b {
            let dt: TimeInterval = f[i + 1].t.timeIntervalSince(f[i].t)
            guard dt > 0, dt <= throughGap else { return nil }
            guard Geo.metres(f[i].p, f[i + 1].p) / dt >= throughSpeed else { return nil }
        }
        for i in a...b where f[i].speed.isFinite && f[i].speed >= 0 && f[i].speed < throughSpeed { return nil }
        return .through
    }

    /// A bus stop of the choice (any candidate's), with what each candidate does there: `served` the ones that call
    /// there, `waits` those whose times have them wait there `dwell` or longer, `passing` those whose road passes it.
    struct Stop: Equatable, Sendable {
        let key: String
        let point: GeoPoint
        var served: Set<String> = []
        var waits: Set<String> = []
        var passing: Set<String> = []
    }

    /// How many times each of `ids` was against what you did (`seen`, by stop key):
    /// - you stood at a stop its road passes without it calling there;
    /// - you went through, at speed, a stop where its times have it wait (it would have halted).
    /// (Going through a stop it calls at says nothing: a bus passes a stop where nobody waits or gets off.)
    static func against(_ stops: [Stop], seen: [String: Seen], ids: [String]) -> [String: Int] {
        var n: [String: Int] = [:]
        for s in stops {
            guard let what = seen[s.key] else { continue }
            for id in ids {
                switch what {
                case .stood: if s.passing.contains(id), !s.served.contains(id) { n[id, default: 0] += 1 }
                case .through: if s.waits.contains(id) { n[id, default: 0] += 1 }
                }
            }
        }
        return n
    }

    /// Seconds added to each one's cost: for the observations against it beyond the fewest any of `ids` has (never all
    /// of them), once that's `needed` or more: `penalty` each, `maxPenalty` at most.
    static func penalties(_ against: [String: Int], ids: [String]) -> [String: Double] {
        guard ids.count > 1 else { return [:] }
        let least: Int = ids.map { against[$0] ?? 0 }.min() ?? 0
        var out: [String: Double] = [:]
        for id in ids {
            let extra = (against[id] ?? 0) - least
            if extra >= needed { out[id] = min(maxPenalty, penalty * Double(extra)) }
        }
        return out
    }
}

// MARK: - asking sooner

enum AskSooner {
    static let after: TimeInterval = 60         // s after you left: two still tied, ask
    static let afterHabit: TimeInterval = 180   // …your usual line breaks the tie meanwhile: not before this

    /// Ask now which one: exactly two in the running, not asked yet for this choice, `movingFor` (since you left the
    /// stop) at least `after` (`afterHabit` while your usual line breaks the tie).
    static func due(alive: [String], movingFor: TimeInterval, asked: Bool, tieBroken: Bool) -> Bool {
        guard !asked, alive.count == 2, movingFor.isFinite else { return false }
        return movingFor >= (tieBroken ? afterHabit : after)
    }

    /// The two differ in a way you can answer: another line, or another destination (two of the same line to the same
    /// place have the same stops: no need to ask).
    static func worthAsking(lines: (String, String), destinations: (String, String)) -> Bool {
        let l0 = lines.0.trimmingCharacters(in: .whitespaces).lowercased(), l1 = lines.1.trimmingCharacters(in: .whitespaces).lowercased()
        if !l0.isEmpty, !l1.isEmpty, l0 != l1 { return true }
        let d0 = destinations.0.trimmingCharacters(in: .whitespaces).lowercased()
        let d1 = destinations.1.trimmingCharacters(in: .whitespaces).lowercased()
        return !d0.isEmpty && !d1.isEmpty && d0 != d1
    }

    /// One button: a bus by its line ("Bus 305"; with its destination when both are the same line: "Bus 306 to Uden");
    /// a train as `TrainRules.answer` ("IC to 's-Hertogenbosch").
    static func answer(line: String, to: String, train: Bool, sameLine: Bool) -> String {
        if train { return TrainRules.answer(line: line, to: to) }
        let bus = "Bus \(line.isEmpty ? "?" : line)"
        return sameLine && !to.isEmpty ? "\(bus) to \(to)" : bus
    }

    /// The question: "305 or 306?", "306 to Uden or 306 to Den Bosch?", "IC to 's-Hertogenbosch or IC to Eindhoven?".
    static func title(_ a: (line: String, to: String), _ b: (line: String, to: String), train: Bool) -> String {
        if train { return TrainRules.askTitle(a, b) }
        let same = a.line.lowercased() == b.line.lowercased()
        func one(_ x: (line: String, to: String)) -> String { same && !x.to.isEmpty ? "\(x.line) to \(x.to)" : x.line }
        return "\(one(a)) or \(one(b))?"
    }

    /// The card's and the notification's line under the question.
    static func body(train: Bool) -> String {
        train ? "Two trains run on the same track here. Which one are you on? Then it wakes you at the right stop."
              : "Two buses drive the same road here. Which one are you on? Then it wakes you at the right stop."
    }
}
