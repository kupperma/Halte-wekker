import Foundation

/// Your day, as one timeline: the wake-up alarm, leaving and the rides, your first class (and until when), and the
/// way home. Plain values from the school alarm and the trip, so the order and the wording are tested.
enum DayTimeline {
    struct Ride: Equatable {
        let line: String
        let train: Bool
        let departure: Date
        let to: String
        /// Minutes to change before this ride (nil for the first), and whether that's too tight (by the room it needs).
        var change: Int? = nil
        var tight = false
    }

    struct Input: Equatable {
        var classStart: Date
        var title: String
        var room: String?
        var leave: Date?
        var arrive: Date?
        var alarm: Date?
        /// When the alarm would ring (shown while it's off for this day).
        var wouldWake: Date?
        var lines: String?
        var rides: [Ride] = []
        var classesEnd: Date?
        var homeLeave: Date?
        var homeArrive: Date?
        var skipped = false
    }

    enum Kind: String { case wake, leave, firstClass, leaveHome }

    struct Item: Equatable {
        let kind: Kind
        let time: Date?
        let title: String
        let detail: String?
        var rides: [Ride] = []
    }

    /// The day's items, in time order. `clock` formats a time ("08:52").
    static func items(_ i: Input, clock: (Date) -> String) -> [Item] {
        var out: [Item] = []
        let wake = i.skipped ? i.wouldWake : i.alarm ?? i.wouldWake
        out.append(Item(kind: .wake, time: wake, title: "Wake-up alarm",
                        detail: i.skipped ? "Off for this day" : i.alarm == nil ? "Set once the trip is planned" : nil))
        if let l = i.leave {
            let there = i.arrive.map { "At school \(clock($0))" }
            out.append(Item(kind: .leave, time: l, title: "Leave home", detail: i.rides.isEmpty ? [i.lines, there].compactMap { $0 }.joined(separator: " · ") : there,
                            rides: i.rides))
        }
        let what = [i.title, i.room].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
        let until = i.classesEnd.map { "Classes until \(clock($0))" }
        out.append(Item(kind: .firstClass, time: i.classStart, title: "First class", detail: [what.isEmpty ? nil : what, until].compactMap { $0 }.joined(separator: "\n")))
        if let h = i.homeLeave {
            out.append(Item(kind: .leaveHome, time: h, title: "Leave for home", detail: i.homeArrive.map { "Home around \(clock($0))" }))
        }
        return out
    }

    /// The day to open on: today while today's classes are on (or still ahead), else tomorrow. `end`: when today's
    /// classes end (unknown: six hours after the first).
    static func defaultDay(now: Date, todayFirst: Date?, todayEnd: Date?, cal: Calendar) -> Date {
        let today = cal.startOfDay(for: now)
        if let f = todayFirst, now < (todayEnd ?? f.addingTimeInterval(6 * 3600)) { return today }
        return cal.date(byAdding: .day, value: 1, to: today) ?? today
    }

    /// "Today", "Tomorrow", "Wednesday".
    static func title(_ day: Date, now: Date, cal: Calendar) -> String {
        let d = cal.startOfDay(for: day), t = cal.startOfDay(for: now)
        let n = cal.dateComponents([.day], from: t, to: d).day ?? 0
        if n == 0 { return "Today" }
        if n == 1 { return "Tomorrow" }
        if n == -1 { return "Yesterday" }
        return fmt("EEEE", cal).string(from: day)
    }

    /// "Tue 17 Nov"
    static func label(_ day: Date, cal: Calendar) -> String { fmt("EEE d MMM", cal).string(from: day) }

    static func fmt(_ f: String, _ cal: Calendar) -> DateFormatter {
        let d = DateFormatter()
        d.locale = Locale(identifier: "en_GB"); d.timeZone = cal.timeZone; d.calendar = cal; d.dateFormat = f
        return d
    }
}

/// A day whose wake-up alarm you turned off (Your day's switch): that day only. Plain rules, tested.
enum SchoolSkip {
    static let key = "school.skip"

    /// What planning does with a day's alarm.
    enum Action: Equatable {
        case keep                           // as it is
        case clear                          // turned off for this day: take its alarm away
        case set(Date, schedule: Bool)      // (re)set it to this time; `schedule`: still more than a minute ahead
    }

    /// The day's alarm, planned for `at`: none on a skipped day; kept when it's set for that same minute already;
    /// else set again (and scheduled only when it's more than a minute ahead).
    static func decide(_ at: Date, day: String, skipped: Set<String>, current: Date?, hasId: Bool, now: Date) -> Action {
        if skipped.contains(day) { return current != nil || hasId ? .clear : .keep }
        let same = current.map { Int($0.timeIntervalSince1970 / 60) == Int(at.timeIntervalSince1970 / 60) } ?? false
        if same && hasId { return .keep }
        return .set(at, schedule: at > now.addingTimeInterval(60))
    }

    /// A day turned back on: its alarm right away from the trip already planned for it (no planning needed), when
    /// that's still more than a minute ahead.
    static func restore(leave: Date?, wakeMinutes: Int, now: Date) -> Date? {
        guard let l = leave else { return nil }
        let at = l.addingTimeInterval(-Double(wakeMinutes) * 60)
        return at > now.addingTimeInterval(60) ? at : nil
    }

    /// The skipped days still to come (`today` as yyyy-MM-dd; the strings sort as dates).
    static func prune(_ s: Set<String>, today: String) -> Set<String> { s.filter { $0 >= today } }
}

/// Coming up: the school dates the timetable shows. It's imported a few weeks ahead and breaks are just empty space, so:
/// runs of weekdays without any class within the weeks it covers, plus all-day events and ones named like a break,
/// project week or exam. Plain values, tested.
enum ComingUp {
    struct Event: Equatable {
        let title: String
        let start: Date
        let end: Date
        let allDay: Bool
        let cancelled: Bool
    }

    enum Kind: String { case free, event }

    struct Item: Equatable {
        let kind: Kind
        let start: Date
        let last: Date              // the last day
        let title: String
        let when: String            // "Mon 24 – Fri 28 Nov"
    }

    struct Result: Equatable {
        let items: [Item]
        let knownUntil: Date?       // the day of the timetable's last event
    }

    static let keywords = ["vakantie", "break", "projectweek", "project week", "tentamen", "exam", "toets"]

    static func isNamedDate(_ title: String) -> Bool {
        let t = title.lowercased()
        return keywords.contains { t.contains($0) }
    }

    static func build(_ events: [Event], now: Date, cal: Calendar, limit: Int = 5) -> Result {
        guard let lastStart = events.map(\.start).max() else { return Result(items: [], knownUntil: nil) }
        let today = cal.startOfDay(for: now), lastDay = cal.startOfDay(for: lastStart)
        let classDays = Set(events.filter { !$0.allDay && !$0.cancelled }.map { cal.startOfDay(for: $0.start) })
        var items: [Item] = []
        // free weekdays, a weekend in between doesn't end a run
        // which weekdays normally have classes: on most of the known weeks (a single free day counts only on those)
        var seenDays: [Int: Int] = [:], classOn: [Int: Int] = [:]
        var d = today
        while d <= lastDay {
            let wd = cal.component(.weekday, from: d)
            seenDays[wd, default: 0] += 1
            if classDays.contains(d) { classOn[wd, default: 0] += 1 }
            guard let n = cal.date(byAdding: .day, value: 1, to: d) else { break }
            d = n
        }
        func usual(_ wd: Int) -> Bool { let c = classOn[wd] ?? 0; return c > 0 && c * 2 >= (seenDays[wd] ?? 0) }
        var runStart: Date?, runLast: Date?, runDays = 0
        func close() {
            if let a = runStart, let b = runLast, runDays >= 2 || usual(cal.component(.weekday, from: a)) {
                items.append(Item(kind: .free, start: a, last: b, title: "No classes", when: range(a, b, cal)))
            }
            runStart = nil; runLast = nil; runDays = 0
        }
        d = today
        while d <= lastDay {
            let wd = cal.component(.weekday, from: d)            // 1 Sunday … 7 Saturday
            if wd != 1 && wd != 7 {
                if classDays.contains(d) { close() } else { if runStart == nil { runStart = d }; runLast = d; runDays += 1 }
            }
            guard let n = cal.date(byAdding: .day, value: 1, to: d) else { break }
            d = n
        }
        close()
        // all-day events, and timed ones named like a break, project week or exam
        var seen = Set<String>()
        for e in events.sorted(by: { $0.start < $1.start }) where !e.cancelled && (e.allDay || isNamedDate(e.title)) {
            let first = cal.startOfDay(for: e.start)
            let last = cal.startOfDay(for: e.allDay ? max(e.start, e.end.addingTimeInterval(-1)) : e.end)
            guard last >= today, seen.insert("\(e.title)|\(first.timeIntervalSince1970)").inserted else { continue }
            items.append(Item(kind: .event, start: first, last: last, title: e.title, when: range(first, last, cal)))
        }
        items.sort { $0.start != $1.start ? $0.start < $1.start : $0.kind == .event && $1.kind == .free }
        return Result(items: Array(items.prefix(limit)), knownUntil: lastDay)
    }

    /// "Wed 26 Nov", "Mon 24 – Fri 28 Nov", "Mon 29 Dec – Fri 2 Jan".
    static func range(_ a: Date, _ b: Date, _ cal: Calendar) -> String {
        let one = DayTimeline.fmt("EEE d MMM", cal)
        if cal.isDate(a, inSameDayAs: b) { return one.string(from: a) }
        let sameMonth = cal.component(.month, from: a) == cal.component(.month, from: b) && cal.component(.year, from: a) == cal.component(.year, from: b)
        return "\((sameMonth ? DayTimeline.fmt("EEE d", cal) : one).string(from: a)) – \(one.string(from: b))"
    }
}
