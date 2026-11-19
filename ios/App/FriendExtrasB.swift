import Foundation

// Friends extras, part B (0.30): free hours together today, the friends leaderboard and the ride history, as plain
// values and rules, tested without the relay, the trip or the UI. Foundation only. (The live link for people without
// the app is LiveLink.swift.) Platform-neutral: the `scores` box and the rules are written out in
// docs/superpowers/specs/2026-11-18-friends-design.md, "As built (0.30)".

// MARK: free hours together

/// A stretch of free time today that you share with one or more friends (from the shared timetables).
struct FreeTodaySlot: Equatable {
    var start: Date
    var end: Date
    /// The friends free with you then (accounts, sorted).
    var with: [String]
}

enum FreeToday {
    /// At most this many lines on Friends.
    static let maxShown = 3
    /// The morning note comes from this hour (Europe/Amsterdam)…
    static let noteFrom = 6
    /// …until this one (not at or after it).
    static let noteUntil = 11

    /// Today's free time you share with each friend who shared a timetable that covers today: 0.28's "free together"
    /// (the gaps between classes, at least 30 minutes) for you and that friend; only what still ends after `now`;
    /// friends with the very same stretch on one line; by start; at most `maxShown`.
    static func slots(mine: TimetableShare?, friends: [(id: String, share: TimetableShare)], now: Date) -> [FreeTodaySlot] {
        guard let mine else { return [] }
        let key: String = TimetableDays.key(now)
        guard mine.covers(key) else { return [] }
        let myClasses: [TimetableClass] = TimetableDays.byDay(mine.classes)[key] ?? []
        let me = PersonDay(id: "me", known: true, classes: myClasses)
        var out: [FreeTodaySlot] = []
        for f in friends where f.share.covers(key) {
            let theirs = PersonDay(id: f.id, known: true, classes: TimetableDays.byDay(f.share.classes)[key] ?? [])
            let day = CompareDay(key: key, people: [me, theirs])
            for s in Compare.freeTogether(day, limit: 4) where s.end > now {
                if let i = out.firstIndex(where: { $0.start == s.start && $0.end == s.end }) {
                    if !out[i].with.contains(f.id) { out[i].with.append(f.id) }
                    out[i].with.sort()
                } else {
                    out.append(FreeTodaySlot(start: s.start, end: s.end, with: [f.id]))
                }
            }
        }
        out.sort { a, b in a.start != b.start ? a.start < b.start : a.end < b.end }
        return Array(out.prefix(maxShown))
    }

    /// "Today: you and Sam are both free 12:00–13:30", "Today: you, Lisa and Sam are all free 12:00–13:30", and once it
    /// has begun "Now: you and Sam are both free until 13:30".
    static func line(_ s: FreeTodaySlot, names: [String], now: Date) -> String {
        let who: String = CompareWords.names(["you"] + names)
        let both: String = names.count == 1 ? "both" : "all"
        if s.start <= now { return "Now: \(who) are \(both) free until \(TimetableDays.hhmm(s.end))" }
        return "Today: \(who) are \(both) free \(TimetableDays.hhmm(s.start))–\(TimetableDays.hhmm(s.end))"
    }

    /// The morning note's body: each line without "Today: ", one per line ("You and Sam are both free 12:00–13:30").
    static func note(_ slots: [FreeTodaySlot], names: (String) -> String, now: Date) -> String {
        let lines: [String] = slots.map { (s: FreeTodaySlot) -> String in
            let l: String = line(s, names: s.with.map(names), now: now)
            let bare: String = l.hasPrefix("Today: ") ? String(l.dropFirst(7)) : l
            return TravelWords.capitalFirst(bare)
        }
        return lines.joined(separator: "\n")
    }

    /// The once-a-day morning note (off by default): on, not yet today, between `noteFrom` and `noteUntil`, and the
    /// first free time together is still ahead.
    static func noteDue(on: Bool, lastDay: String?, slots: [FreeTodaySlot], now: Date) -> Bool {
        guard on, let first = slots.first, first.start > now else { return false }
        guard lastDay != TimetableDays.key(now) else { return false }
        let h: Int = TimetableDays.calendar.component(.hour, from: now)
        return h >= noteFrom && h < noteUntil
    }
}

// MARK: the friends leaderboard

/// The body of a `scores` box (slot `scores`, ttl 14 days): your fastest trips and your rides together this month, to
/// all your friends while "Share my scores" is on (off by default). `on: false` takes it back.
struct ScoresShare: Codable, Equatable {
    /// One route's fastest trip.
    struct Best: Codable, Equatable {
        /// The route's key: "home→school", "school→home" (door to door), or a corridor route's name ("Via Den Bosch").
        var route: String
        /// Going home.
        var home: Bool
        /// Minutes (one decimal) from starting the alarm to the last stop.
        var mins: Double
        /// When that trip ended.
        var at: Date
    }

    var on: Bool
    /// The month `mbest` and `rides` are for ("yyyy-MM", Europe/Amsterdam).
    var month: String? = nil
    /// The fastest trip per route, ever (0–8).
    var best: [Best]? = nil
    /// The fastest trip per route this month (0–8).
    var mbest: [Best]? = nil
    /// Rides together with friends this month (0–1000).
    var rides: Int? = nil

    static let maxRoutes = 8
    static let routeLength = 40

    /// As taken: routes cleaned (as names, at most 40) and not empty, minutes 5–600, at most 8 per list (the rest
    /// dropped); a month that isn't "yyyy-MM" drops `month`, `mbest` and `rides`; rides outside 0–1000 dropped.
    static func valid(_ s: ScoresShare) -> ScoresShare {
        func clean(_ list: [Best]?) -> [Best]? {
            guard let list else { return nil }
            let kept: [Best] = list.compactMap { (b: Best) -> Best? in
                let r: String = String(FriendNames.clean(b.route).prefix(routeLength))
                guard !r.isEmpty, b.mins >= 5, b.mins <= 600 else { return nil }
                return Best(route: r, home: b.home, mins: b.mins, at: b.at)
            }
            return Array(kept.prefix(maxRoutes))
        }
        var v = ScoresShare(on: s.on)
        guard s.on else { return v }
        v.best = clean(s.best)
        if let m = s.month, ScoresRules.isMonth(m) {
            v.month = m
            v.mbest = clean(s.mbest)
            if let r = s.rides, r >= 0, r <= 1000 { v.rides = r }
        }
        return v
    }
}

struct ScoresSeen: Codable, Equatable {
    var share: ScoresShare
    var t: Int
    var got: Date
}

/// A finished trip on your own board (the app's ScoreBook), as the friends board counts it.
struct ScoreTrip: Equatable {
    var route: String
    var home: Bool
    var mins: Double
    var at: Date
}

enum ScoresRules {
    static let slot = "scores"
    static let ttl = 14 * 86400
    /// A change goes out at most this often…
    static let changedGap: TimeInterval = 12 * 3600
    /// …and it goes again after this whatever (the month moves on).
    static let refresh: TimeInterval = 7 * 86400
    static let offTTL = 14 * 86400

    /// "2027-01" for a time (Europe/Amsterdam).
    static func month(_ d: Date) -> String { String(TimetableDays.key(d).prefix(7)) }

    static func isMonth(_ s: String) -> Bool {
        let parts: [Substring] = s.split(separator: "-")
        guard s.count == 7, parts.count == 2, parts[0].count == 4, parts[1].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }), let m = Int(parts[1]) else { return false }
        return (1...12).contains(m)
    }

    /// Yours: the fastest trip per route ever and this month (to school first, then the fastest), and your rides
    /// together this month.
    static func build(trips: [ScoreTrip], rides: Int, now: Date) -> ScoresShare {
        let m: String = month(now)
        let thisMonth: [ScoreTrip] = trips.filter { month($0.at) == m }
        return ScoresShare(on: true, month: m, best: bests(trips), mbest: bests(thisMonth), rides: max(0, min(1000, rides)))
    }

    static func bests(_ trips: [ScoreTrip]) -> [ScoresShare.Best] {
        var by: [String: ScoreTrip] = [:]
        for t in trips where t.mins >= 5 && t.mins <= 600 && !t.route.isEmpty {
            let k: String = "\(t.home)|\(t.route)"
            if let had = by[k], had.mins <= t.mins { continue }
            by[k] = t
        }
        let list: [ScoreTrip] = by.values.sorted { a, b in
            if a.home != b.home { return !a.home }
            if a.mins != b.mins { return a.mins < b.mins }
            return a.route < b.route
        }
        return list.prefix(ScoresShare.maxRoutes).map { (t: ScoreTrip) -> ScoresShare.Best in
            ScoresShare.Best(route: String(t.route.prefix(ScoresShare.routeLength)), home: t.home, mins: (t.mins * 10).rounded() / 10, at: t.at)
        }
    }

    /// The fingerprint of what goes (not when it was made): FNV-1a 64 over the body's JSON (sorted keys).
    static func fingerprint(_ s: ScoresShare) -> String {
        let d: Data = (try? FriendJSON.encoder.encode(s)) ?? Data()
        return TimetableShareRules.fingerprint(d)
    }

    /// Who gets yours now: every friend when it changed and the last went `changedGap` ago, or `refresh` ago whatever;
    /// else only friends who haven't had it. (0.28's `Sent`.)
    static func due(last: TimetableShareRules.Sent?, hash: String, friends: [String], now: Date) -> [String] {
        guard !friends.isEmpty else { return [] }
        guard let last else { return friends.sorted() }
        let age: TimeInterval = now.timeIntervalSince(last.at)
        if age < 0 || age >= refresh || (hash != last.hash && age >= changedGap) { return friends.sorted() }
        let had = Set(last.to)
        return friends.filter { !had.contains($0) }.sorted()
    }
}

/// Someone on the friends board: you or a friend who shares their scores.
struct ScoresPerson: Equatable {
    var id: String
    var share: ScoresShare
}

struct ScoreRow: Equatable {
    var who: String
    var mins: Double
    var at: Date
}

/// One route on the friends board.
struct ScoreGroup: Equatable, Identifiable {
    var home: Bool
    var route: String
    var rows: [ScoreRow]
    var id: String { "\(home)|\(route)" }
}

struct RidesRow: Equatable {
    var who: String
    var n: Int
}

enum ScoreBoard {
    /// Per route: everyone's fastest on it, fastest first (then the earliest). Routes to school first, then home; within
    /// each, the most people first, then by name. `month`: this month's only (someone whose `month` isn't it has none).
    static func groups(_ people: [ScoresPerson], month: String?) -> [ScoreGroup] {
        var by: [String: ScoreGroup] = [:]
        for p in people where p.share.on {
            let list: [ScoresShare.Best]
            if let month {
                guard p.share.month == month else { continue }
                list = p.share.mbest ?? []
            } else {
                list = p.share.best ?? []
            }
            for b in list {
                let k: String = "\(b.home)|\(b.route)"
                var g: ScoreGroup = by[k] ?? ScoreGroup(home: b.home, route: b.route, rows: [])
                if let i = g.rows.firstIndex(where: { $0.who == p.id }) {
                    if b.mins < g.rows[i].mins { g.rows[i] = ScoreRow(who: p.id, mins: b.mins, at: b.at) }
                } else {
                    g.rows.append(ScoreRow(who: p.id, mins: b.mins, at: b.at))
                }
                by[k] = g
            }
        }
        var out: [ScoreGroup] = Array(by.values)
        for i in out.indices {
            out[i].rows.sort { a, b in a.mins != b.mins ? a.mins < b.mins : a.at < b.at }
        }
        out.sort { a, b in
            if a.home != b.home { return !a.home }
            if a.rows.count != b.rows.count { return a.rows.count > b.rows.count }
            return a.route < b.route
        }
        return out
    }

    /// The most rides together this month: everyone with one or more (their `month` is this one), the most first.
    static func rides(_ people: [ScoresPerson], month: String) -> [RidesRow] {
        let rows: [RidesRow] = people.compactMap { (p: ScoresPerson) -> RidesRow? in
            guard p.share.on, p.share.month == month, let n = p.share.rides, n > 0 else { return nil }
            return RidesRow(who: p.id, n: n)
        }
        return rows.sorted { a, b in a.n != b.n ? a.n > b.n : a.who < b.who }
    }
}

// MARK: ride history together

/// A ride you shared with friends, kept on this phone only (Friends/together.json): one per vehicle per day.
struct RideTogether: Codable, Equatable, Identifiable {
    /// The vehicle's trip id (as the live data names it).
    var trip: String
    /// The day (yyyy-MM-dd, Europe/Amsterdam).
    var day: String
    /// "Bus 305", "IC 3512".
    var label: String
    var from: String
    var to: String
    /// When it left where you got on.
    var dep: Date
    /// Who was on it with you (accounts, sorted).
    var with: [String]

    var id: String { "\(day)|\(trip)" }
}

enum RideHistory {
    /// Kept this long, and at most this many.
    static let keepDays = 400
    static let maxKept = 1000
    /// A friend's page lists the last this many.
    static let shownLast = 10
    /// Trip cards from this long ago still count.
    static let cardAge: TimeInterval = 24 * 3600

    /// Who's on this vehicle with you now: friends whose trip is on it and who are on board (their `travel` state
    /// riding with that trip id), and the others in on a trip card you're in (you sent it, or said "I'm in") whose
    /// shared ride is this vehicle. Sorted, without you.
    static func riders(trip: String, travel: [(from: String, state: TravelState)], cards: [(card: TripCard, riders: [String])],
                       me: String) -> [String] {
        guard !trip.isEmpty else { return [] }
        var out = Set<String>()
        for t in travel where t.state.trip == trip && t.state.stage == .riding { out.insert(t.from) }
        for c in cards {
            guard let s = TripTake.shared(c.card), s.trip == trip else { continue }
            for r in c.riders { out.insert(r) }
        }
        out.remove(me)
        return out.sorted()
    }

    /// The ride's record added, or the riders added to the one for that vehicle that day; the oldest go past
    /// `keepDays` and `maxKept`. Newest first.
    static func add(_ list: [RideTogether], _ r: RideTogether, now: Date) -> [RideTogether] {
        guard !r.with.isEmpty, !r.trip.isEmpty else { return list }
        var out: [RideTogether] = list
        if let i = out.firstIndex(where: { $0.id == r.id }) {
            out[i].with = Array(Set(out[i].with).union(r.with)).sorted()
        } else {
            var n = r
            n.with = Array(Set(r.with)).sorted()
            out.append(n)
        }
        let oldest: Date = now.addingTimeInterval(-Double(keepDays) * 86400)
        out = out.filter { $0.dep >= oldest }
        out.sort { a, b in a.dep != b.dep ? a.dep > b.dep : a.trip < b.trip }
        return Array(out.prefix(maxKept))
    }

    /// Times you rode with `friend` in the month of `now`.
    static func count(_ list: [RideTogether], with friend: String, now: Date) -> Int {
        let m: String = ScoresRules.month(now)
        return list.filter { $0.day.hasPrefix(m) && $0.with.contains(friend) }.count
    }

    /// Your rides with any friend in the month of `now`.
    static func count(_ list: [RideTogether], now: Date) -> Int {
        let m: String = ScoresRules.month(now)
        return list.filter { $0.day.hasPrefix(m) }.count
    }

    /// The last rides with `friend`, newest first.
    static func last(_ list: [RideTogether], with friend: String, limit: Int = shownLast) -> [RideTogether] {
        let mine: [RideTogether] = list.filter { $0.with.contains(friend) }.sorted { $0.dep > $1.dep }
        return Array(mine.prefix(limit))
    }

    /// Only friends stay in the records; a record with nobody left goes.
    static func keep(_ list: [RideTogether], friends: Set<String>) -> [RideTogether] {
        list.compactMap { (r: RideTogether) -> RideTogether? in
            var x = r
            x.with = r.with.filter { friends.contains($0) }
            return x.with.isEmpty ? nil : x
        }
    }
}

enum RideHistoryWords {
    /// "You rode together 14 times this month", "You rode together once this month", "No rides together this month yet".
    static func month(_ n: Int) -> String {
        switch n {
        case 0: return "No rides together this month yet"
        case 1: return "You rode together once this month"
        case 2: return "You rode together twice this month"
        default: return "You rode together \(n) times this month"
        }
    }

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = TimetableDays.zone
        f.dateFormat = "EEE d MMM"
        return f
    }()

    /// "Fri 15 Jan · 09:11 · IC 3512 · Eindhoven Centraal → Breda".
    static func row(_ r: RideTogether) -> String {
        "\(dayFormat.string(from: r.dep)) · \(TimetableDays.hhmm(r.dep)) · \(r.label) · \(r.from) → \(r.to)"
    }
}
