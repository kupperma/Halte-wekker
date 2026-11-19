import Foundation

// Friends (0.28): your class timetable and your start area, as shared with friends (the `timetable` and `area` boxes),
// and the rules of when they go. Plain values, tested without the relay, the calendar or the UI. Foundation only.
//
// timetable (slot `tt`, ttl 21 days): the next two weeks of classes, each its start, end, title and room.
// area (slot `area`, ttl 30 days): the stops nearest your home and its train station, your school (name and place) and
// how early you like to be there. Never your home address.

/// One class, as shared.
struct TimetableClass: Codable, Equatable, Sendable {
    static let maxTitle = 80
    static let maxRoom = 60
    /// A class longer than this isn't one (an all-day block someone put in).
    static let maxLength: TimeInterval = 12 * 3600

    var start: Date
    /// When it ends (nil: not known, e.g. a week of first classes without an end time).
    var end: Date? = nil
    var title: String? = nil
    var room: String? = nil
}

/// The body of a `timetable` box: every class from `from` (the first day's midnight) to `to` (the last day's end),
/// in Amsterdam time. A day in that window without classes has no school; a day outside it isn't known.
struct TimetableShare: Codable, Equatable, Sendable {
    static let maxClasses = 300
    static let maxWindow: TimeInterval = 16 * 86400
    /// How many days ahead the app shares (today counts as the first).
    static let days = 14

    var from: Date
    var to: Date
    var classes: [TimetableClass]
    /// Where it comes from: "calendar" (the calendars you picked) or "week" (the same times every week).
    var src: String? = nil
    /// Taken back (the sender stopped sharing with you): forget their timetable and area.
    var off: Bool? = nil

    var isOff: Bool { off == true }

    /// The box that takes it back.
    static func takenBack(at now: Date) -> TimetableShare { TimetableShare(from: now, to: now, classes: [], off: true) }

    /// As kept: a window of at most 16 days; classes in it, cleaned, sorted, at most 300; ones that don't make sense
    /// (ending before they start, longer than 12 hours, outside the window) are left out. Nil: not a timetable.
    static func valid(_ t: TimetableShare) -> TimetableShare? {
        if t.isOff { return takenBack(at: t.from) }
        guard t.to > t.from, t.to.timeIntervalSince(t.from) <= maxWindow else { return nil }
        var out: [TimetableClass] = []
        for c in t.classes where c.start >= t.from && c.start < t.to {
            var k = c
            if let e = c.end, e <= c.start || e.timeIntervalSince(c.start) > TimetableClass.maxLength { k.end = nil }
            k.title = c.title.map { String(FriendNames.cleanLine($0).prefix(TimetableClass.maxTitle)) }.flatMap { $0.isEmpty ? nil : $0 }
            k.room = c.room.map { String(FriendNames.cleanLine($0).prefix(TimetableClass.maxRoom)) }.flatMap { $0.isEmpty ? nil : $0 }
            out.append(k)
        }
        out.sort { ($0.start, $0.end ?? $0.start) < ($1.start, $1.end ?? $1.start) }
        var v = t
        v.classes = Array(out.prefix(maxClasses))
        return v
    }

    /// Covers that day (yyyy-MM-dd in Amsterdam time).
    func covers(_ day: String) -> Bool {
        guard let d = TimetableDays.date(day) else { return false }
        return d >= from.addingTimeInterval(-60) && d < to
    }
}

/// The body of an `area` box: where your trips start and end, roughly.
struct TimetableArea: Codable, Equatable, Sendable {
    static let maxStops = 4

    /// A train station (with NS's code when it has one).
    struct Station: Codable, Equatable, Sendable {
        var name: String
        var code: String? = nil
        var id: String? = nil
        var lat: Double
        var lon: Double
        var point: GeoPoint { GeoPoint(lat: lat, lon: lon) }
    }

    /// The bus (or tram) stops nearest your home, nearest first (Transitous stop ids).
    var stops: [TripCard.Spot]
    /// The train station nearest your home (within 5 km).
    var station: Station? = nil
    /// Your school: its name and where it is (required).
    var school: TripCard.Spot
    /// You like to be at school this many minutes before class.
    var early: Int? = nil

    /// As kept: at most four stops with a place, names cleaned, a school with a place, `early` 0–60. Nil: not an area.
    static func valid(_ a: TimetableArea) -> TimetableArea? {
        guard a.school.point != nil else { return nil }
        var v = a
        v.stops = Array(a.stops.filter { $0.point != nil && !$0.name.isEmpty }.prefix(maxStops))
        v.school.name = FriendNames.clean(a.school.name).isEmpty ? "School" : FriendNames.clean(a.school.name)
        if let e = a.early { v.early = min(60, max(0, e)) }
        return v
    }

    /// Where a trip from home starts: the nearest stop, else the station.
    var start: TripCard.Spot? {
        if let s = stops.first { return s }
        if let st = station { return TripCard.Spot(name: st.name, id: st.id, lat: st.lat, lon: st.lon) }
        return nil
    }

    /// How early you like to be there (10 minutes when not said).
    var earlyMinutes: Int { early ?? 10 }
}

/// A friend's timetable as this phone keeps it: what came, their time on it, when it came.
struct TimetableSeen: Codable, Equatable, Sendable {
    var share: TimetableShare
    /// The box's `t` (the sender's clock).
    var t: Int
    var at: Date
}

/// A friend's start area as this phone keeps it.
struct AreaSeen: Codable, Equatable, Sendable {
    var area: TimetableArea
    var t: Int
    var at: Date
}

/// Days as the timetables key them: yyyy-MM-dd in Amsterdam time.
enum TimetableDays {
    static let zone = TimeZone(identifier: "Europe/Amsterdam") ?? .current

    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        c.firstWeekday = 2
        return c
    }

    private static let keyFormat: DateFormatter = {
        let f = DateFormatter()
        f.calendar = calendar; f.timeZone = zone; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func key(_ d: Date) -> String { keyFormat.string(from: d) }
    static func date(_ key: String) -> Date? { keyFormat.date(from: key) }

    /// The window a share covers from `now`: today's midnight to the end of the 14th day.
    static func window(now: Date, days: Int = TimetableShare.days) -> (from: Date, to: Date) {
        let cal = calendar
        let a = cal.startOfDay(for: now)
        let b = cal.date(byAdding: .day, value: days, to: a) ?? a.addingTimeInterval(Double(days) * 86400)
        return (a, b)
    }

    /// The classes of a share by day.
    static func byDay(_ classes: [TimetableClass]) -> [String: [TimetableClass]] {
        var out: [String: [TimetableClass]] = [:]
        for c in classes { out[key(c.start), default: []].append(c) }
        return out.mapValues { $0.sorted { $0.start < $1.start } }
    }

    /// "Mon 24", "Tue 25".
    static func short(_ key: String) -> String {
        guard let d = date(key) else { return key }
        let f = DateFormatter()
        f.calendar = calendar; f.timeZone = zone; f.locale = Locale(identifier: "en_GB"); f.dateFormat = "EEE d"
        return f.string(from: d)
    }

    /// "Tue", "Wed".
    static func weekday(_ key: String) -> String {
        guard let d = date(key) else { return key }
        let f = DateFormatter()
        f.calendar = calendar; f.timeZone = zone; f.locale = Locale(identifier: "en_GB"); f.dateFormat = "EEE"
        return f.string(from: d)
    }

    static func hhmm(_ d: Date) -> String { TripCardWords.hhmm(d) }
}

extension FriendNames {
    /// One line of text from someone else (a class's title, a room): no control characters, single spaces, trimmed.
    static func cleanLine(_ s: String) -> String {
        let words: [Substring] = s.split(whereSeparator: { $0.isWhitespace })
        let kept: [String] = words.map { w in
            String(String.UnicodeScalarView(w.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        }
        return kept.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

// MARK: from your own timetable

extension ManualWeek {
    /// The week's classes from the start of `now`'s day for `days` days (today counts, all of it), in `tz`: one per
    /// school day, from its first class to its end time (when the week has one), with its title.
    func classes(from now: Date, days: Int, tz: TimeZone) -> [TimetableClass] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let first = cal.startOfDay(for: now)
        var out: [TimetableClass] = []
        for i in 0..<max(0, days) {
            guard let day = cal.date(byAdding: .day, value: i, to: first),
                  let d = self.days.first(where: { $0.weekday == cal.component(.weekday, from: day) }),
                  let start = cal.date(bySettingHour: d.minutes / 60, minute: d.minutes % 60, second: 0, of: day) else { continue }
            var end: Date?
            if let e = d.end, e > d.minutes { end = cal.date(bySettingHour: e / 60, minute: e % 60, second: 0, of: day) }
            out.append(TimetableClass(start: start, end: end, title: d.shownTitle, room: nil))
        }
        return out
    }
}

// MARK: when it's shared

/// Your switches for it, as kept on this phone and in the vault (`"timetable"`): the one-time screen answered,
/// "Share my timetable" for everyone, the people it's off for, and the groups you share it with.
struct TimetableSettings: Codable, Equatable, Sendable {
    var answered: Bool? = nil
    var on: Bool? = nil
    var off: [String]? = nil
    var groups: [String]? = nil
}

/// When your timetable (and area) go to friends: when they changed, but at most every `minGap` (a few times a day);
/// to someone who hasn't had them yet at once; and once a day anyway (the two weeks move on).
enum TimetableShareRules {
    static let minGap: TimeInterval = 3 * 3600
    static let refresh: TimeInterval = 20 * 3600
    /// The area changes rarely: again after a week whatever.
    static let areaRefresh: TimeInterval = 7 * 86400
    /// The app looks whether it's due at most this often (it reads the calendar for it).
    static let lookEvery: TimeInterval = 30 * 60
    static let timetableTTL = 21 * 86400
    static let areaTTL = 30 * 86400
    static let timetableSlot = "tt"
    static let areaSlot = "area"

    struct Sent: Codable, Equatable {
        /// A fingerprint of what went (`fingerprint`).
        var hash: String
        var at: Date
        /// Who had it.
        var to: [String]
    }

    /// Who gets it now: everyone it goes to (`now`) if it changed and the last went `minGap` ago, or `refresh` ago
    /// whatever; else only those who haven't had it. Empty: nothing to send.
    static func due(last: Sent?, hash: String, recipients now: [String], at: Date, every: TimeInterval = refresh) -> [String] {
        guard !now.isEmpty else { return [] }
        guard let last else { return now.sorted() }
        let age = at.timeIntervalSince(last.at)
        if age < 0 || age >= every || (hash != last.hash && age >= minGap) { return now.sorted() }
        let had = Set(last.to)
        return now.filter { !had.contains($0) }.sorted()
    }

    /// After sending to `to`: what's remembered (the whole list when everyone got it; else those added).
    static func after(_ last: Sent?, hash: String, sent to: [String], everyone: [String], at: Date) -> Sent {
        if let last, Set(to) != Set(everyone) || to.isEmpty {
            // only the new ones: the time and fingerprint stay those of the last full send
            return Sent(hash: last.hash, at: last.at, to: Array(Set(last.to).union(to)).sorted())
        }
        return Sent(hash: hash, at: at, to: everyone.sorted())
    }

    /// Who had it and doesn't get it any more (a switch went off, they left the group): it's taken back from them.
    static func takeBack(last: Sent?, recipients now: [String]) -> [String] {
        guard let last else { return [] }
        let keep = Set(now)
        return last.to.filter { !keep.contains($0) }.sorted()
    }

    /// After taking it back from `gone`.
    static func afterTakeBack(_ last: Sent?, gone: [String]) -> Sent? {
        guard var l = last else { return nil }
        let g = Set(gone)
        l.to = l.to.filter { !g.contains($0) }
        return l
    }

    /// A short fingerprint of what goes (the classes and area, not when it was made): FNV-1a 64 over the JSON.
    static func fingerprint(_ data: Data) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in data { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    /// Who your timetable goes to: friends with the switch on (unless it's off for everyone), and the people in the
    /// groups you share it with who aren't your friends. Never yourself.
    static func recipients(friends: [String], off: Set<String>, groupMembers: [String], me: String, on: Bool) -> [String] {
        guard on else { return [] }
        var out = Set(friends.filter { !off.contains($0) })
        for m in groupMembers where !off.contains(m) { out.insert(m) }
        out.remove(me)
        return out.sorted()
    }
}
