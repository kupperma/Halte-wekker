import Foundation

// 0.39.1: after the field report of 25 November (the 154 to Schijndel taken for the 306). Plain values only, so they
// can be tested:
// - `TimetableStart`: a leg is never started by its timetable long before the planned one leaves.
// - `WrongBus`: once it's sure you're on another line (or the same line to somewhere else) than planned, it says so,
//   once a ride, with the best way on from where you are.
// - `OtherAtStop`: waiting at your stop, another line's bus stands there before yours: "That's the 154 to Schijndel —
//   not yours. Your 306: 2 min".

/// Starting a leg by the planned one's timetable (no live match, you've clearly left at bus or train speed).
enum TimetableStart {
    /// s before its (live) departure at most: the 305 that leaves at 17:35 isn't the one you're on at 17:24.
    static let before: TimeInterval = 120
    /// s after it: later than this it's another one.
    static let after: TimeInterval = 20 * 60

    /// It may start by its timetable now: from `before` ahead of its departure (live when known) to `after` it.
    static func allowed(now: Date, departure: Date) -> Bool {
        let dt: TimeInterval = now.timeIntervalSince(departure)
        return dt >= -before && dt < after
    }

    /// "wait · not by its timetable: bus 305 leaves 17:35 (in 11 min)": the field log's line while it waits.
    static func waitLine(label: String, leaves: String, minutes: Int) -> String {
        "wait · not by its timetable: \(label) leaves \(leaves) (in \(max(0, minutes)) min) · finding the one you're on"
    }
}

/// "You're on the 154 to Schijndel, not your 306" (0.39.1).
enum WrongBus {
    static let idPrefix = "wrongbus-"
    /// s of the vehicle's own GPS fitting you before it's sure (or the roads parted).
    static let gpsFor: TimeInterval = 75
    /// s: a gap longer than this between two fits starts the run again.
    static let gpsGap: TimeInterval = 180
    /// s: the newest fit at most this old.
    static let fresh: TimeInterval = 120

    /// One vehicle's run of fits by its own GPS: the first and the newest.
    struct Run: Equatable, Sendable {
        var first: Date
        var last: Date
    }

    /// What it says, on the ride screen and as a notification.
    struct Alert: Equatable, Sendable {
        let title: String
        let body: String
        let tripId: String
    }

    /// The runs with this look's fits (`fitted`: the ones that passed by their own GPS) added; runs whose newest fit is
    /// older than `gpsGap` are gone.
    static func note(_ runs: [String: Run], fitted: [String], now: Date) -> [String: Run] {
        var out: [String: Run] = runs.filter { now.timeIntervalSince($0.value.last) <= gpsGap }
        for id in fitted {
            if var r = out[id] {
                r.last = max(r.last, now)
                out[id] = r
            } else {
                out[id] = Run(first: now, last: now)
            }
        }
        return out
    }

    /// Sure it's that one: the roads parted (`split`), or its own GPS has fitted you for `gpsFor`, the newest fit
    /// `fresh`.
    static func sure(_ run: Run?, split: Bool, now: Date) -> Bool {
        if split { return true }
        guard let r = run, now.timeIntervalSince(r.last) <= fresh else { return false }
        return r.last.timeIntervalSince(r.first) >= gpsFor
    }

    /// Another line than planned, or the same line to another destination (both known).
    static func differs(plannedLine: String, plannedTo: String, line: String, to: String) -> Bool {
        let pl = norm(plannedLine), ol = norm(line)
        guard !pl.isEmpty, !ol.isEmpty else { return false }
        if pl != ol { return true }
        let pt = norm(plannedTo), ot = norm(to)
        return !pt.isEmpty && !ot.isEmpty && pt != ot
    }

    /// Tell now: it differs, it's sure, you didn't pick it yourself, and it hasn't told you on this ride.
    static func due(differs: Bool, sure: Bool, byHand: Bool, told: Bool) -> Bool {
        differs && sure && !byHand && !told
    }

    /// "You're on the 154 to Schijndel, not your 306"; a train "You're on the IC to Eindhoven, not your SPR".
    static func title(line: String, to: String, planned: String) -> String {
        let where_: String = to.trimmingCharacters(in: .whitespaces).isEmpty ? "" : " to \(to.trimmingCharacters(in: .whitespaces))"
        return "You’re on the \(line)\(where_), not your \(planned)"
    }

    /// The best way on from here, as the planner has it: off at the vehicle's next stop and back ("Get off at
    /// Kloosterstraat — 306 back at 17:52"), or on to where the planner changes ("Stay on to Schijndel — 306 from there
    /// at 18:11"). Nil `then`: off at that stop with nothing planned after it (it's where you're going).
    static func fix(getOff stop: String, nextStop: Bool, then: String?, at: String?) -> String {
        guard let then, let at else { return "Stay on to \(stop): it gets you there" }
        if nextStop { return "Get off at \(stop) — \(then) back at \(at)" }
        return "Stay on to \(stop) — \(then) from there at \(at)"
    }

    /// No plan from here could be had: what to do.
    static let noFix = "Get off at the next stop, and plan again from there"

    /// The notification's identifier: one a ride.
    static func id(tripStart: Date) -> String { idPrefix + String(Int(tripStart.timeIntervalSince1970)) }

    /// "wrong bus · on 154·0855 to Schijndel, planned 306 · Stay on to Schijndel — 306 from there at 18:11".
    static func logLine(label: String, to: String, planned: String, fix: String) -> String {
        let where_: String = to.isEmpty ? "" : " to \(to)"
        return "wrong bus · on \(label)\(where_), planned \(planned) · \(fix)"
    }

    static func norm(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces).lowercased() }
}

/// Waiting at the stop you get on at: another line's bus stands there before yours (by its own GPS).
enum OtherAtStop {
    static let idPrefix = "otherbus-"
    /// m: you this close to the stop (else it keeps quiet).
    static let near = 150.0
    /// m: its own GPS this close to you: it's at your stop.
    static let atYou = 80.0
    /// s: its fix at most this old.
    static let fixFresh: TimeInterval = 120
    /// s: your bus leaves within this.
    static let within: TimeInterval = 10 * 60
    /// s: its own departure from your stop this close to now: it's here to leave, not passing hours later.
    static let leaving: TimeInterval = 5 * 60

    /// A departure from the stop's board, with its own GPS: how far from you (nil: no fix), how old.
    struct Seen: Equatable, Sendable {
        let tripId: String
        let line: String
        let to: String
        let departure: Date
        let metres: Double?
        let fixAge: TimeInterval?
    }

    /// Yours: the line to say, its (live) departure, and every line that's yours here (your own routes: 305 and 306).
    struct Yours: Equatable, Sendable {
        let line: String
        let departure: Date
        let lines: Set<String>
    }

    /// The other line's bus at your stop now, or nil: you within `near` of the stop; yours leaving within `within`
    /// (and not gone a minute ago); of another line, its own fresh GPS within `atYou` of you, leaving about now
    /// (`leaving`) and before yours (a minute's slack). The nearest.
    static func pick(_ seen: [Seen], yours: Yours?, youToStop: Double?, now: Date) -> Seen? {
        guard let y = yours, let d = youToStop, d.isFinite, d <= near else { return nil }
        let wait: TimeInterval = y.departure.timeIntervalSince(now)
        guard wait >= -60, wait <= within else { return nil }
        let mine: Set<String> = Set(y.lines.map(WrongBus.norm)).union([WrongBus.norm(y.line)])
        let here: [Seen] = seen.filter { s -> Bool in
            guard !mine.contains(WrongBus.norm(s.line)), !WrongBus.norm(s.line).isEmpty else { return false }
            guard let m = s.metres, let a = s.fixAge, m.isFinite, m <= atYou, a >= -60, a <= fixFresh else { return false }
            let off: TimeInterval = abs(s.departure.timeIntervalSince(now))
            return off <= leaving && s.departure <= y.departure.addingTimeInterval(60)
        }
        return here.min { ($0.metres ?? 0) != ($1.metres ?? 0) ? ($0.metres ?? 0) < ($1.metres ?? 0) : $0.tripId < $1.tripId }
    }

    /// "That's the 154 to Schijndel — not yours" and "Your 306: 2 min" ("Your 306: due" within the minute).
    static func words(_ s: Seen, yours y: Yours, now: Date) -> (title: String, body: String) {
        let to: String = s.to.trimmingCharacters(in: .whitespaces)
        let title: String = "That’s the \(s.line)\(to.isEmpty ? "" : " to \(to)") — not yours"
        let m = Int((y.departure.timeIntervalSince(now) / 60).rounded(.down))
        let when: String = m < 1 ? "due" : "\(m) min"
        return (title, "Your \(y.line): \(when)")
    }

    static func id(_ tripId: String) -> String { idPrefix + tripId }
}
