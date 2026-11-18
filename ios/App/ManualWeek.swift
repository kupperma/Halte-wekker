import Foundation

/// "Same times every week": the first class of each weekday with school, in Amsterdam time. Saved in the profile;
/// the school alarm plans from it (0.23) as it does from a calendar's first class of the day.
struct ManualWeek: Codable, Equatable, Sendable {
    struct Day: Codable, Equatable, Sendable {
        /// Calendar weekday: 1 is Sunday, 2 Monday … 7 Saturday.
        var weekday: Int
        /// The first class, in minutes after midnight.
        var minutes: Int
    }

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
        for d in l where (1...7).contains(d.weekday) && (0..<1440).contains(d.minutes) { by[d.weekday] = d }
        return by.keys.sorted().compactMap { by[$0] }
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

    /// Sets (or clears, with nil) a weekday's first class.
    mutating func set(weekday: Int, minutes: Int?) {
        var l = days.filter { $0.weekday != weekday }
        if let minutes { l.append(Day(weekday: weekday, minutes: minutes)) }
        days = Self.clean(l)
    }

    var isEmpty: Bool { days.isEmpty }
}
