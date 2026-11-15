import Foundation

/// "yyyy-MM-dd" of a recomp day. A day runs from 04:00 to 04:00 local time.
typealias DayKey = String

enum RecompCalendar {
    /// Gregorian, weeks start on Monday, local time zone.
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2
        c.timeZone = TimeZone.current
        return c
    }

    private static func keyFormatter(_ calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    /// The recomp day a moment belongs to: before 04:00 local it is still the previous calendar day.
    static func day(for date: Date, calendar: Calendar = RecompCalendar.calendar) -> DayKey {
        let hour = calendar.component(.hour, from: date)
        var d = date
        if hour < 4 {
            let startOfDay = calendar.startOfDay(for: date)
            // noon of the previous calendar day
            let prev = calendar.date(byAdding: .day, value: -1, to: startOfDay) ?? startOfDay
            d = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: prev) ?? prev
        }
        return keyFormatter(calendar).string(from: d)
    }

    /// 12:00 local on that day.
    static func date(of day: DayKey, calendar: Calendar = RecompCalendar.calendar) -> Date {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return Date(timeIntervalSince1970: 0) }
        var c = DateComponents()
        c.year = parts[0]; c.month = parts[1]; c.day = parts[2]; c.hour = 12
        return calendar.date(from: c) ?? Date(timeIntervalSince1970: 0)
    }

    static func adding(_ days: Int, to day: DayKey, calendar: Calendar = RecompCalendar.calendar) -> DayKey {
        let noon = date(of: day, calendar: calendar)
        let moved = calendar.date(byAdding: .day, value: days, to: noon) ?? noon
        return keyFormatter(calendar).string(from: moved)
    }

    /// The Monday of the week that day is in.
    static func monday(of day: DayKey, calendar: Calendar = RecompCalendar.calendar) -> DayKey {
        let weekday = calendar.component(.weekday, from: date(of: day, calendar: calendar))
        let offset = (weekday - 2 + 7) % 7
        return adding(-offset, to: day, calendar: calendar)
    }

    /// b − a, in days.
    static func daysBetween(_ a: DayKey, _ b: DayKey, calendar: Calendar = RecompCalendar.calendar) -> Int {
        calendar.dateComponents([.day], from: date(of: a, calendar: calendar), to: date(of: b, calendar: calendar)).day ?? 0
    }

    /// "16 Nov"
    static func shortText(_ day: DayKey, locale: Locale = Locale(identifier: "en_GB")) -> String {
        let cal = calendar
        let f = DateFormatter()
        f.locale = locale
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.dateFormat = "d MMM"
        return f.string(from: date(of: day, calendar: cal))
    }
}
