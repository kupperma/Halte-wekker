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

// MARK: - Typed input

enum RecompInput {
    /// Trims, drops a trailing "kg"/"cm"/"g" (any case), accepts "," or ".", at most one separator.
    static func number(_ text: String) -> Double? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for suffix in ["kg", "cm", "g"] where s.hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count))
            break
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard !s.isEmpty else { return nil }
        guard s.allSatisfy({ ($0 >= "0" && $0 <= "9") || $0 == "." }) else { return nil }
        guard s.filter({ $0 == "." }).count <= 1 else { return nil }
        guard s.contains(where: { $0 >= "0" && $0 <= "9" }) else { return nil }
        if s.hasSuffix(".") { s.removeLast() }
        if s.hasPrefix(".") { s = "0" + s }
        return Double(s)
    }

    private static func ranged(_ text: String, _ range: ClosedRange<Double>) -> Double? {
        guard let v = number(text), range.contains(v) else { return nil }
        return v
    }

    static func weight(_ text: String) -> Double? { ranged(text, 30...300) }
    static func waist(_ text: String) -> Double? { ranged(text, 40...200) }
    /// Grams of protein per pack, from a label.
    static func protein(_ text: String) -> Double? { ranged(text, 0.1...300) }
}

// MARK: - Protein maths

enum ProteinMath {
    static let packFractions: [Double] = [0.25, 0.5, 0.75, 1]

    /// "¼" "½" "¾" "1" "1½" "3"
    static func amountText(_ amount: Double) -> String {
        let whole = Int(amount.rounded(.down))
        let frac = amount - Double(whole)
        let fracText: String
        if abs(frac) < 0.01 {
            return "\(whole)"
        } else if abs(frac - 0.25) < 0.01 {
            fracText = "¼"
        } else if abs(frac - 0.5) < 0.01 {
            fracText = "½"
        } else if abs(frac - 0.75) < 0.01 {
            fracText = "¾"
        } else if abs(frac - 1) < 0.01 {
            return "\(whole + 1)"
        } else {
            let f = NumberFormatter()
            f.locale = Locale(identifier: "en_GB")
            f.numberStyle = .decimal
            f.minimumFractionDigits = 0
            f.maximumFractionDigits = 1
            return f.string(from: NSNumber(value: amount)) ?? "\(amount)"
        }
        return whole == 0 ? fracText : "\(whole)\(fracText)"
    }

    /// amount ≤ 1 uses the singular unit: "¾ tub", "3 eggs".
    static func amountLabel(_ amount: Double, unit: String, units: String) -> String {
        "\(amountText(amount)) \(amount <= 1 ? unit : units)"
    }

    /// Grams of protein in a whole pack. nil when a value is missing or ≤ 0.
    static func perPack(proteinPer100: Double?, quantity: Double?, unit: String?) -> Double? {
        guard let p = proteinPer100, let q = quantity, p > 0, q > 0 else { return nil }
        let u = unit?.lowercased()
        let amount = (u == "kg" || u == "l") ? q * 1000 : q
        return p * amount / 100
    }

    static func percent(total: Double, goal: Double) -> Int {
        guard goal > 0 else { return 0 }
        return Int((total / goal * 100).rounded())
    }

    static func toGo(total: Double, goal: Double) -> String? {
        guard total < goal else { return nil }
        return "\(RecompFormat.grams(goal - total)) protein to go"
    }

    static func rideLine(total: Double, goal: Double) -> String? {
        guard let t = toGo(total: total, goal: goal) else { return nil }
        return t + " today"
    }
}

// MARK: - Formatting

enum RecompFormat {
    private static func oneDecimal(_ v: Double, _ locale: Locale) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.minimumFractionDigits = 1
        f.maximumFractionDigits = 1
        f.usesGroupingSeparator = false
        return f.string(from: NSNumber(value: v)) ?? String(format: "%.1f", v)
    }

    /// "88,1 kg" in nl_NL.
    static func kg(_ v: Double, locale: Locale = .current) -> String {
        oneDecimal(v, locale) + " kg"
    }

    /// "↓ 0,3" / "↑ 0,2" / "± 0,0". The arrow carries the sign.
    static func change(_ v: Double, locale: Locale = .current) -> String {
        let a = abs(v)
        if (a * 10).rounded() == 0 { return "± " + oneDecimal(0, locale) }
        return (v < 0 ? "↓ " : "↑ ") + oneDecimal(a, locale)
    }

    /// "20 g"
    static func grams(_ v: Double) -> String {
        "\(Int(v.rounded())) g"
    }
}
