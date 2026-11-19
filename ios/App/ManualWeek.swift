import Foundation

/// "Same times every week": the first class of each weekday with school, in Amsterdam time. Saved in the profile;
/// the school alarm plans from it (0.23) as it does from a calendar's first class of the day.
struct ManualWeek: Codable, Equatable, Sendable {
    struct Day: Codable, Equatable, Sendable {
        /// Calendar weekday: 1 is Sunday, 2 Monday … 7 Saturday.
        var weekday: Int
        /// The first class, in minutes after midnight.
        var minutes: Int
        /// (0.28) When the last class ends, in minutes after midnight (nil: not said; a week saved before 0.28).
        var end: Int? = nil
        /// (0.28) What it is, if you like ("Design", "Lectures").
        var title: String? = nil
        /// The title as shared: single spaces, trimmed (nil: none).
        var shownTitle: String? {
            guard let t = title else { return nil }
            let s = t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            return s.isEmpty ? nil : s
        }

        init(weekday: Int, minutes: Int, end: Int? = nil, title: String? = nil) {
            self.weekday = weekday; self.minutes = minutes; self.end = end; self.title = title
        }

        // Postel: a week saved before 0.28 has no end or title; an end that isn't after the start is none.
        enum CodingKeys: String, CodingKey { case weekday, minutes, end, title }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            weekday = try c.decode(Int.self, forKey: .weekday)
            minutes = try c.decode(Int.self, forKey: .minutes)
            end = try? c.decodeIfPresent(Int.self, forKey: .end)
            title = try? c.decodeIfPresent(String.self, forKey: .title)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(weekday, forKey: .weekday)
            try c.encode(minutes, forKey: .minutes)
            try c.encodeIfPresent(end, forKey: .end)
            try c.encodeIfPresent(title, forKey: .title)
        }
    }

    static let maxTitle = 40

    /// At most one per weekday, in weekday order.
    private(set) var days: [Day]

    init(days: [Day]) { self.days = Self.clean(days) }

    /// The first class on a weekday, in minutes after midnight (nil: no school that day).
    func minutes(weekday: Int) -> Int? { days.first { $0.weekday == weekday }?.minutes }

    // Postel: days that don't make sense are left out, a weekday given twice keeps the last one.
    enum CodingKeys: String, CodingKey { case days }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        days = Self.clean((try? c.decode([Day].self, forKey: .days)) ?? [])
    }

    private static func clean(_ l: [Day]) -> [Day] {
        var by: [Int: Day] = [:]
        for d in l where (1...7).contains(d.weekday) && (0..<1440).contains(d.minutes) {
            var k = d
            if let e = d.end, !(e > d.minutes && e < 1440) { k.end = nil }
            if let t = d.title {
                // (kept as typed, so a space can be typed; trimmed where it's shared: `shownTitle`)
                let c = String(t.replacingOccurrences(of: "\n", with: " ").prefix(maxTitle))
                k.title = c.isEmpty ? nil : c
            }
            by[d.weekday] = k
        }
        return by.keys.sorted().compactMap { by[$0] }
    }

    /// (0.28) A day's last class ends, in minutes after midnight (nil: not said, or no school).
    func end(weekday: Int) -> Int? { days.first { $0.weekday == weekday }?.end }
    /// (0.28) What a day is called, as typed (nil: not said).
    func title(weekday: Int) -> String? { days.first { $0.weekday == weekday }?.title }

    /// (0.28) Sets a day's end time (nil: none). Ignored for a day without school, or an end not after its start.
    mutating func setEnd(weekday: Int, minutes e: Int?) {
        guard let i = days.firstIndex(where: { $0.weekday == weekday }) else { return }
        var l = days
        l[i].end = e
        days = Self.clean(l)
    }

    /// (0.28) Sets a day's title (empty: none).
    mutating func setTitle(weekday: Int, _ t: String?) {
        guard let i = days.firstIndex(where: { $0.weekday == weekday }) else { return }
        var l = days
        l[i].title = t
        days = Self.clean(l)
    }

    // MARK: the lessons it makes (0.23)

    /// A day's first class from the week: its day (yyyy-MM-dd in the week's time zone, as the school alarm keys days)
    /// and when it starts.
    struct Lesson: Equatable, Sendable {
        let day: String
        let start: Date
    }

    /// The first classes from the start of `now`'s day for `days` days (today counts as the first), in `tz`. A time
    /// that's already past today is left out; the clock time stays the same across a change to or from summer time.
    func lessons(from now: Date, days: Int, tz: TimeZone) -> [Lesson] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let f = DateFormatter()
        f.calendar = cal; f.timeZone = tz; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        let first = cal.startOfDay(for: now)
        var out: [Lesson] = []
        for i in 0..<max(0, days) {
            guard let day = cal.date(byAdding: .day, value: i, to: first),
                  let m = minutes(weekday: cal.component(.weekday, from: day)),
                  let start = cal.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: day),
                  start > now else { continue }
            out.append(Lesson(day: f.string(from: day), start: start))
        }
        return out
    }

    /// Monday to Friday at 08:30: where "Same times every week" starts.
    static let workdays = ManualWeek(days: (2...6).map { Day(weekday: $0, minutes: 8 * 60 + 30) })

    /// Sets (or clears, with nil) a weekday's first class. A day that had an end time and a title keeps them.
    mutating func set(weekday: Int, minutes: Int?) {
        let had = days.first { $0.weekday == weekday }
        var l = days.filter { $0.weekday != weekday }
        if let minutes { l.append(Day(weekday: weekday, minutes: minutes, end: had?.end, title: had?.title)) }
        days = Self.clean(l)
    }

    var isEmpty: Bool { days.isEmpty }
}
