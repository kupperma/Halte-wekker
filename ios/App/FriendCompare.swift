import Foundation

// Friends (0.28): timetables side by side (you and one friend, or a whole group), per day this week and next: who has
// class when, the free time you have together. Plain values, tested without the relay, the planner or the UI.
// Foundation only. (The rides you can share are `SharedRides`; meeting halfway is `MeetHalfway`.)

/// Someone in a comparison: you, a friend, or someone in the group.
struct ComparePerson: Equatable, Identifiable {
    var id: String
    var name: String
    var isMe: Bool = false
    /// Their shared timetable (nil: not shared with you yet).
    var timetable: TimetableShare?
    /// Their start area (nil: not shared yet).
    var area: TimetableArea?
}

/// One person's day.
struct PersonDay: Equatable {
    var id: String
    /// Their timetable covers this day (else nothing is known about it).
    var known: Bool
    /// The day's classes, by start.
    var classes: [TimetableClass]

    var hasSchool: Bool { known && !classes.isEmpty }
    /// The first class starts.
    var first: Date? { classes.first?.start }
    /// The last class ends: the latest end time, when the last class has one (nil: not known).
    var lastEnd: Date? {
        guard let lastStart = classes.map(\.start).max() else { return nil }
        let ends: [Date] = classes.compactMap(\.end)
        guard let e = ends.max(), e > lastStart else { return nil }
        return e
    }
}

/// One day of the comparison.
struct CompareDay: Equatable, Identifiable {
    var key: String
    var people: [PersonDay]
    var id: String { key }

    func person(_ id: String) -> PersonDay? { people.first { $0.id == id } }
    /// The people with class that day.
    var atSchool: [PersonDay] { people.filter(\.hasSchool) }
    /// At least two of you have class (so there's something to ride together).
    var shared: Bool { atSchool.count >= 2 }
}

/// A stretch of free time two or more of you have, between classes, on a school day.
struct FreeSlot: Equatable {
    var start: Date
    var end: Date
    var ids: [String]
    var minutes: Int { Int((end.timeIntervalSince(start) / 60).rounded()) }
}

enum Compare {
    /// Free time shorter than this isn't worth a line.
    static let minFree: TimeInterval = 30 * 60

    /// The days of this week (from today) and next, Monday to Sunday; Saturday and Sunday only when someone has class.
    static func days(_ people: [ComparePerson], now: Date) -> [CompareDay] {
        let cal = TimetableDays.calendar
        let today = cal.startOfDay(for: now)
        let weekday = cal.component(.weekday, from: today)            // 1 Sunday … 7 Saturday
        let toSunday = (8 - weekday) % 7                                // days left in this week (Sunday: 0)
        let count = toSunday + 1 + 7
        let byPerson: [(ComparePerson, [String: [TimetableClass]])] = people.map { p in
            (p, p.timetable.map { TimetableDays.byDay($0.classes) } ?? [:])
        }
        var out: [CompareDay] = []
        for i in 0..<count {
            guard let d = cal.date(byAdding: .day, value: i, to: today) else { continue }
            let key = TimetableDays.key(d)
            let list: [PersonDay] = byPerson.map { (p, days) in
                let known: Bool = p.timetable.map { $0.covers(key) } ?? false
                return PersonDay(id: p.id, known: known, classes: known ? (days[key] ?? []) : [])
            }
            let wd = cal.component(.weekday, from: d)
            let weekend = wd == 1 || wd == 7
            if weekend && !list.contains(where: \.hasSchool) { continue }
            out.append(CompareDay(key: key, people: list))
        }
        return out
    }

    /// A person's free time on a day: the gaps between their classes (overlapping classes count as one), from the end
    /// of one (when known) to the start of the next.
    static func free(_ p: PersonDay) -> [(start: Date, end: Date)] {
        guard p.hasSchool else { return [] }
        var blocks: [(start: Date, end: Date?)] = []
        for c in p.classes.sorted(by: { $0.start < $1.start }) {
            if var last = blocks.last, let e = last.end, c.start < e {
                // overlapping: one block, to the later end
                last.end = max(c.end ?? e, e)
                blocks[blocks.count - 1] = last
            } else if var last = blocks.last, last.end == nil {
                // the one before has no end: it runs into this one
                last.end = c.end
                blocks[blocks.count - 1] = last
            } else {
                blocks.append((c.start, c.end))
            }
        }
        var gaps: [(start: Date, end: Date)] = []
        for i in 0..<(max(0, blocks.count - 1)) {
            guard let e = blocks[i].end else { continue }
            let next = blocks[i + 1].start
            if next.timeIntervalSince(e) >= 1 { gaps.append((e, next)) }
        }
        return gaps
    }

    /// The free time two or more of you have together on a day (at least `minFree`), the most of you first, then the
    /// longest; at most `limit`, then in time order.
    static func freeTogether(_ d: CompareDay, limit: Int = 2) -> [FreeSlot] {
        let gaps: [(id: String, start: Date, end: Date)] = d.atSchool.flatMap { p in free(p).map { (id: p.id, start: $0.start, end: $0.end) } }
        guard gaps.count >= 2 else { return [] }
        let cuts: [Date] = Array(Set(gaps.flatMap { [$0.start, $0.end] })).sorted()
        var segs: [FreeSlot] = []
        for i in 0..<(max(0, cuts.count - 1)) {
            let a = cuts[i], b = cuts[i + 1]
            let free: [String] = gaps.filter { $0.start <= a && $0.end >= b }.map { $0.id }
            let ids: [String] = Array(Set(free)).sorted()
            guard ids.count >= 2 else { continue }
            if var last = segs.last, last.end == a, last.ids == ids {
                last.end = b
                segs[segs.count - 1] = last
            } else {
                segs.append(FreeSlot(start: a, end: b, ids: ids))
            }
        }
        let long: [FreeSlot] = segs.filter { $0.end.timeIntervalSince($0.start) >= minFree }
        let best: [FreeSlot] = long.sorted { a, b in
            if a.ids.count != b.ids.count { return a.ids.count > b.ids.count }
            return a.end.timeIntervalSince(a.start) > b.end.timeIntervalSince(b.start)
        }
        return Array(best.prefix(limit)).sorted { $0.start < $1.start }
    }

    /// The first school day from now (today counts while someone's first class is still ahead) that two or more of you
    /// have: the one the compare screen looks up rides for by itself.
    static func nextShared(_ days: [CompareDay], now: Date) -> String? {
        for d in days where d.shared {
            let starts: [Date] = d.atSchool.compactMap(\.first)
            if let latest = starts.max(), latest > now { return d.key }
        }
        return nil
    }
}

/// The words of the compare screen.
enum CompareWords {
    /// "you, Sam and Lisa"
    static func names(_ list: [String]) -> String {
        guard list.count > 1 else { return list.first ?? "" }
        return list.dropLast().joined(separator: ", ") + " and " + list.last!
    }

    /// One person's day: "08:45–15:30 · 4 classes", "From 08:30", "No classes", "Not shared".
    static func day(_ p: PersonDay) -> String {
        guard p.known else { return "Not shared" }
        guard let f = p.first else { return "No classes" }
        let n = p.classes.count
        let count = n == 1 ? "1 class" : "\(n) classes"
        if let e = p.lastEnd { return "\(TimetableDays.hhmm(f))–\(TimetableDays.hhmm(e)) · \(count)" }
        return "From \(TimetableDays.hhmm(f)) · \(count)"
    }

    /// "Free together 12:30–13:45 · you and Sam"
    static func free(_ s: FreeSlot, name: (String) -> String) -> String {
        "Free together \(TimetableDays.hhmm(s.start))–\(TimetableDays.hhmm(s.end)) · \(names(s.ids.map(name)))"
    }

    /// One class: "08:45–10:30 Design · C1.02"
    static func lesson(_ c: TimetableClass) -> String {
        var s = TimetableDays.hhmm(c.start)
        if let e = c.end { s += "–" + TimetableDays.hhmm(e) }
        if let t = c.title { s += " " + t }
        if let r = c.room { s += " · " + r }
        return s
    }
}
