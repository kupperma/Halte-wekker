import Foundation

/// How reliable a change is (0.34), from your own history of it: per change (line A → line B at a station) and time of
/// day, whether you made it, one outcome per day. "this change worked on 9 of 10 days" on the plan's options and the Go
/// card once there are 3 days; the ranking (`Risk.miss`) leans on it the more days there are.
struct ChangeBook: Codable, Equatable, Sendable {
    static let daysKept = 30
    static let keysKept = 200

    /// change key → day ("20261119") → made it (the day's last outcome)
    var days: [String: [String: Bool]] = [:]

    mutating func record(_ key: String, day: String, made: Bool) {
        guard !key.isEmpty, !day.isEmpty else { return }
        var d = days[key] ?? [:]
        d[day] = made
        if d.count > Self.daysKept {
            d = Dictionary(uniqueKeysWithValues: d.sorted { $0.key > $1.key }.prefix(Self.daysKept).map { ($0.key, $0.value) })
        }
        days[key] = d
        if days.count > Self.keysKept {
            // the changes seen least lately go first
            let newest: [(String, String)] = days.map { ($0.key, $0.value.keys.max() ?? "") }
            let keep = Set(newest.sorted { $0.1 > $1.1 }.prefix(Self.keysKept).map(\.0))
            days = days.filter { keep.contains($0.key) }
        }
    }

    func tally(_ key: String) -> (made: Int, days: Int) {
        let d = days[key] ?? [:]
        return (d.values.filter { $0 }.count, d.count)
    }
}

enum ChangeOdds {
    static let needed = 3                   // days before it says anything
    static let weightDays = 5.0             // the history counts days / (days + this) against the model
    static let hopeless = 0.9               // a change the model says you can't make stays one

    /// "IC>SPR@tilburg|wd-am": from line A to line B at the station, at that time of the week.
    static func key(from a: String, to b: String, at station: String, time: Date, calendar: Calendar) -> String {
        "\(a)>\(b)@\(station.trimmingCharacters(in: .whitespaces).lowercased())|\(bucket(time, calendar: calendar))"
    }

    /// Weekday or weekend, and early (before 7), am (7–9), day (9–16), pm (16–19), eve.
    static func bucket(_ t: Date, calendar: Calendar) -> String {
        let h = calendar.component(.hour, from: t)
        let part = h < 7 ? "early" : h < 9 ? "am" : h < 16 ? "day" : h < 19 ? "pm" : "eve"
        return "\(calendar.isDateInWeekend(t) ? "we" : "wd")-\(part)"
    }

    /// "20261119" in `calendar`'s time zone.
    static func day(_ t: Date, calendar: Calendar) -> String {
        let d = calendar.dateComponents([.year, .month, .day], from: t)
        return String(format: "%04d%02d%02d", d.year ?? 0, d.month ?? 0, d.day ?? 0)
    }

    /// "this change worked on 9 of 10 days"; nil under `needed` days.
    static func words(made: Int, days: Int) -> String? {
        guard days >= needed, made >= 0, made <= days else { return nil }
        return "this change worked on \(made) of \(days) days"
    }

    /// The chance you'd miss it: the model's (`Risk.miss`), leaning on your own days once there are `needed`
    /// (days / (days + `weightDays`) of it); a change the model says you can't make stays one.
    static func missChance(model: Double, made: Int, days: Int) -> Double {
        guard days >= needed, model < hopeless else { return model }
        let w = Double(days) / (Double(days) + weightDays)
        let missed = Double(days - min(made, days)) / Double(days)
        return (1 - w) * model + w * missed
    }

    /// Did you make the change: you got on the one planned, or one that left within a minute of it (the one alongside,
    /// or its id changed); a later one: missed. Nil: no telling (another one, its departure not known).
    static func made(plannedTrip: String, plannedDeparture: Date, boardedTrip: String, boardedDeparture: Date?) -> Bool? {
        if boardedTrip == plannedTrip { return true }
        guard let d = boardedDeparture else { return nil }
        return d.timeIntervalSince(plannedDeparture) <= 60
    }
}
