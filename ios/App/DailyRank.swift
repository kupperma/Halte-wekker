import Foundation

// Today's best and worst trip (0.35), Foundation only: per direction (to school, home) the fastest and the slowest trip
// today among you and the friends who share their scores, or, on your own, your fastest and slowest against your usual.
// The friends' trips come in the 0.30 `scores` box's new `today` list (FriendExtrasB.swift, `ScoresShare.today`);
// written out in docs/superpowers/specs/2026-11-18-friends-design.md, "As built (0.35)". Today is the phone's own day:
// it starts again at local midnight.

/// One of today's trips, as the `scores` box carries it (0.35, additive: an older app ignores the list).
struct DayTrip: Codable, Equatable {
    /// Going home (else to school).
    var home: Bool
    /// Minutes from starting the alarm to the last stop (5–600, one decimal), as the leaderboard has them.
    var mins: Double
    /// When it ended.
    var at: Date
    /// Planned minutes, from starting the alarm to the scheduled arrival (5–600; a planned trip only).
    var plan: Double? = nil
    /// The ride that was latest at your stop ("305", "Intercity"; ≤ 20 characters) and how many minutes (1–600).
    var line: String? = nil
    var late: Double? = nil

    static let maxCount = 12
    static let lineLength = 20

    /// As taken: minutes outside 5–600 drop the trip; a plan outside 5–600 drops the plan; a line cleaned (≤ 20, no
    /// control characters) and a late outside 1–600 drop both; at most 12, the first kept. Nil stays nil.
    static func valid(_ list: [DayTrip]?) -> [DayTrip]? {
        guard let list else { return nil }
        let kept: [DayTrip] = list.compactMap { (t: DayTrip) -> DayTrip? in
            guard t.mins >= 5, t.mins <= 600 else { return nil }
            var v = DayTrip(home: t.home, mins: t.mins, at: t.at)
            if let p = t.plan, p >= 5, p <= 600 { v.plan = p }
            let l: String = clean(t.line ?? "")
            if !l.isEmpty, let m = t.late, m >= 1, m <= 600 { v.line = l; v.late = m }
            return v
        }
        return Array(kept.prefix(maxCount))
    }

    static func clean(_ s: String) -> String {
        let words: [String] = s.split(whereSeparator: { $0.isWhitespace }).map { w in
            String(String.UnicodeScalarView(w.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        }
        return String(words.filter { !$0.isEmpty }.joined(separator: " ").prefix(lineLength)).trimmingCharacters(in: .whitespaces)
    }
}

enum DailyRank {
    /// "Usual" is the median of your trips that way in the 28 days before today, from 3 trips on.
    static let usualDays = 28
    static let usualFrom = 3
    /// The slowest trip says why when its ride was this late, or it took this much longer than planned (minutes).
    static let lateFrom = 3.0
    static let overPlanFrom = 5.0
    /// Within this of your usual is "about your usual" (minutes).
    static let aboutUsual = 2.0

    /// Today, by `calendar` (the phone's own: local midnight to midnight).
    static func isToday(_ d: Date, now: Date, calendar: Calendar) -> Bool { calendar.isDate(d, inSameDayAs: now) }

    /// Your board's trips today, as the box sends them: newest first, at most 12.
    static func today(_ trips: [TripScore], now: Date, calendar: Calendar) -> [DayTrip] {
        let list: [DayTrip] = trips.filter { isToday($0.at, now: now, calendar: calendar) && $0.at <= now.addingTimeInterval(60) }
            .sorted { $0.at > $1.at }
            .map { (t: TripScore) -> DayTrip in
                DayTrip(home: t.home, mins: (t.mins * 10).rounded() / 10, at: t.at, plan: t.plan, line: t.lateLine, late: t.late)
            }
        return DayTrip.valid(list) ?? []
    }

    /// Your usual minutes that way: the median of your trips in the 28 days before today (nil: under 3 of them).
    static func usual(_ trips: [TripScore], home: Bool, now: Date, calendar: Calendar) -> Double? {
        let todayStart: Date = calendar.startOfDay(for: now)
        guard let from = calendar.date(byAdding: .day, value: -usualDays, to: todayStart) else { return nil }
        let xs: [Double] = trips.filter { $0.home == home && $0.at >= from && $0.at < todayStart }.map(\.mins).sorted()
        guard xs.count >= usualFrom else { return nil }
        let m = xs.count / 2
        return xs.count % 2 == 1 ? xs[m] : (xs[m - 1] + xs[m]) / 2
    }

    struct Pick: Equatable {
        /// "me", or a friend's account.
        var who: String
        var trip: DayTrip
    }

    /// One direction today.
    struct Row: Equatable {
        var home: Bool
        var fastest: Pick
        /// Nil when there's only one trip that way today.
        var slowest: Pick?
        /// Only your own trips that way today (no friend's): the words compare with your usual.
        var mine: Bool
        /// Your usual that way (only when `mine`).
        var usual: Double?
        var count: Int
    }

    /// Per direction (to school first, then home): the fastest and the slowest trip today among `people` ("me" and the
    /// friends who share, each with the trips their box has; only trips that ended today count). Ties: the earlier trip,
    /// then "me", then by account.
    static func rows(_ people: [(id: String, trips: [DayTrip])], mine: [TripScore], now: Date, calendar: Calendar) -> [Row] {
        var out: [Row] = []
        for home in [false, true] {
            var all: [Pick] = []
            for p in people {
                for t in p.trips where t.home == home && isToday(t.at, now: now, calendar: calendar) && t.mins >= 5 {
                    all.append(Pick(who: p.id, trip: t))
                }
            }
            guard !all.isEmpty else { continue }
            func before(_ a: Pick, _ b: Pick) -> Bool {
                if a.trip.at != b.trip.at { return a.trip.at < b.trip.at }
                if (a.who == "me") != (b.who == "me") { return a.who == "me" }
                return a.who < b.who
            }
            let fast: Pick = all.min { a, b in a.trip.mins != b.trip.mins ? a.trip.mins < b.trip.mins : before(a, b) }!
            let slow: Pick = all.min { a, b in a.trip.mins != b.trip.mins ? a.trip.mins > b.trip.mins : before(a, b) }!
            let onlyMine: Bool = all.allSatisfy { $0.who == "me" }
            out.append(Row(home: home, fastest: fast, slowest: all.count > 1 ? slow : nil, mine: onlyMine,
                           usual: onlyMine ? usual(mine, home: home, now: now, calendar: calendar) : nil, count: all.count))
        }
        return out
    }

    // MARK: words

    /// "41 min", "1 h", "1 h 05", "1 h 12".
    static func duration(_ mins: Double) -> String {
        let m = Int(mins.rounded())
        guard m >= 60 else { return "\(m) min" }
        let h = m / 60, r = m % 60
        return r == 0 ? "\(h) h" : "\(h) h \(r < 10 ? "0" : "")\(r)"
    }

    /// Why a slow trip was slow: " — the 305 was 18 min late", " — 20 min more than planned", or nothing.
    static func why(_ t: DayTrip) -> String {
        if let l = t.line, let m = t.late, m >= lateFrom { return " — the \(l) was \(Int(m.rounded())) min late" }
        if let p = t.plan, t.mins - p >= overPlanFrom { return " — \(Int((t.mins - p).rounded())) min more than planned" }
        return ""
    }

    /// Against your usual: " · 7 min quicker than usual", " · 5 min slower than usual", " · about your usual".
    static func vsUsual(_ mins: Double, usual: Double?) -> String {
        guard let u = usual else { return "" }
        let d = mins - u
        if abs(d) < aboutUsual { return " · about your usual" }
        return " · \(Int(abs(d).rounded())) min \(d < 0 ? "quicker" : "slower") than usual"
    }

    /// The row's lines. With friends: "🏆 Fastest today: Sam, 41 min", "🐌 Slowest today: Tom, 1 h 12 — the 305 was 18 min
    /// late" (you are "you"). On your own: "🏆 Fastest today: 41 min · 7 min quicker than usual", "🐌 Slowest today: 1 h 12
    /// — the 305 was 18 min late"; one trip: "Today: 41 min · about your usual". `name`: a friend's name by account.
    static func lines(_ r: Row, name: (String) -> String) -> [String] {
        func who(_ p: Pick) -> String { p.who == "me" ? "you" : name(p.who) }
        if r.mine {
            guard let s = r.slowest else { return ["Today: \(duration(r.fastest.trip.mins))\(vsUsual(r.fastest.trip.mins, usual: r.usual))"] }
            return ["🏆 Fastest today: \(duration(r.fastest.trip.mins))\(vsUsual(r.fastest.trip.mins, usual: r.usual))",
                    "🐌 Slowest today: \(duration(s.trip.mins))\(why(s.trip))"]
        }
        var out: [String] = ["🏆 Fastest today: \(who(r.fastest)), \(duration(r.fastest.trip.mins))"]
        if let s = r.slowest { out.append("🐌 Slowest today: \(who(s)), \(duration(s.trip.mins))\(why(s.trip))") }
        return out
    }
}
