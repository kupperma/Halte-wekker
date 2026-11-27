import Foundation

// 0.42.6: the school wake-up adapts to the day. From the field report "The alarm went off when I was already on a trip
// to school. I was meeting friends earlier, so I left two hours earlier and set my own alarm. Maybe add a
// change-arrival-time option?". Plain rules (Foundation only), tested in `SchoolArriveTests`; Android has the same
// rules with the same vectors (`school/SchoolArrive.kt`, `SchoolArriveTest`).

/// "Be there at …" for one school day: a time you pick instead of the timetable's (first class minus how early you
/// want to be there). Per date, never per weekday, and gone once its day is over.
enum SchoolArrive {
    /// UserDefaults: [yyyy-MM-dd: be-there time, seconds since 1970].
    static let key = "school.arrive"

    /// The quick choices, from the timetable's be-there time.
    enum Quick: String, CaseIterable, Equatable {
        case hourEarlier, twoHoursEarlier, halfHourLater

        var minutes: Int {
            switch self {
            case .hourEarlier: return -60
            case .twoHoursEarlier: return -120
            case .halfHourLater: return 30
            }
        }

        var title: String {
            switch self {
            case .hourEarlier: return "1 h earlier"
            case .twoHoursEarlier: return "2 h earlier"
            case .halfHourLater: return "30 min later"
            }
        }
    }

    /// The timetable's be-there time: the first class minus how early you want to be there.
    static func timetable(classStart: Date, early: Int) -> Date {
        classStart.addingTimeInterval(-Double(early) * 60)
    }

    /// The be-there time planning uses for a day: yours when you changed it, else the timetable's.
    static func beThere(classStart: Date, early: Int, override: Date?) -> Date {
        override ?? timetable(classStart: classStart, early: early)
    }

    /// A quick choice's time.
    static func quick(_ q: Quick, timetable: Date) -> Date {
        timetable.addingTimeInterval(Double(q.minutes) * 60)
    }

    /// A time you picked for a day, kept as the day's change: whole minutes; nil when it's the timetable's own minute
    /// (that's no change), or more than 12 hours from the first class (not that day's trip).
    static func normalized(_ t: Date, timetable: Date, classStart: Date) -> Date? {
        let m: Double = (t.timeIntervalSince1970 / 60).rounded(.down) * 60
        let picked = Date(timeIntervalSince1970: m)
        let same: Bool = Int(picked.timeIntervalSince1970 / 60) == Int((timetable.timeIntervalSince1970 / 60).rounded(.down))
        if same { return nil }
        if abs(picked.timeIntervalSince(classStart)) > 12 * 3600 { return nil }
        return picked
    }

    /// The changes still to come (`today` as yyyy-MM-dd; the strings sort as dates): a day's change is gone after it.
    static func prune(_ o: [String: Date], today: String) -> [String: Date] { o.filter { $0.key >= today } }

    /// "Changed: be there 09:00 (class 11:00)"
    static func changedLine(beThere: Date, classStart: Date, clock: (Date) -> String) -> String {
        "Changed: be there \(clock(beThere)) (class \(clock(classStart)))"
    }

    /// The alarm's label and the wake-up notification's text. As before when nothing changed ("Time to get up",
    /// "Leave 07:40 for your 08:45 class"); with a change, the times you picked.
    static func alarmText(leave: Date, classStart: Date, beThere: Date, changed: Bool, clock: (Date) -> String) -> (title: String, body: String) {
        if !changed { return ("Time to get up", "Leave \(clock(leave)) for your \(clock(classStart)) class") }
        return ("Time to get up · be there \(clock(beThere))", "Leave \(clock(leave)) to be there \(clock(beThere)) (class \(clock(classStart)))")
    }

    /// No answer from the planner after a change: the old trip moved by the change, so the alarm follows at once (it's
    /// planned again with live times at the next chance).
    static func shiftedLeave(oldLeave: Date, oldBeThere: Date, newBeThere: Date) -> Date {
        oldLeave.addingTimeInterval(newBeThere.timeIntervalSince(oldBeThere))
    }
}

/// Never ring when you're already going: that morning's school wake-up is skipped when a trip to school started that
/// morning (or runs), when you got to school that day, or when you clearly left home that morning (a trip or ride
/// started and you left home's region or are more than 1 km away). Moving around at home alone never skips it.
enum OnTheWay {
    /// UserDefaults: what was seen this morning (`Seen`).
    static let key = "school.morning"
    /// UserDefaults: [yyyy-MM-dd: why] the days whose alarm was skipped this way.
    static let goingKey = "school.going"
    /// UserDefaults: the days you turned back on after a skip (not skipped again that day).
    static let keepKey = "school.keepRinging"

    /// Only from 03:00 on the day ("that morning": a trip last night doesn't count).
    static let morningHour = 3
    /// A trip whose last stop is this close to school goes to school.
    static let schoolTripMetres: Double = 1500
    /// This close to school (a fresh fix): you're there.
    static let atSchoolMetres: Double = 400
    /// Further than this from home (a fresh fix), with a trip or ride: you've left.
    static let farMetres: Double = 1000
    /// Closer than this to home (a fresh fix): you're home, nothing is skipped (unless a trip to school runs).
    static let homeMetres: Double = 500
    /// A fix this old or newer counts.
    static let freshFix: TimeInterval = 15 * 60

    /// What was seen on one day (kept, so a wake-up in the background knows it).
    struct Seen: Codable, Equatable {
        var day: String
        var tripAt: Date? = nil             // the first trip or ride that started that morning (anywhere)
        var schoolTripAt: Date? = nil       // the first one of them toward school
        var atSchool: Date? = nil           // got to school
        var leftHome: Date? = nil           // left home's region
    }

    /// Where you are now and what runs.
    struct Live: Equatable {
        var running = false                 // a trip runs now
        var runningToSchool = false         // …toward school
        var homeMetres: Double? = nil       // the last fix's distance from home
        var fixAt: Date? = nil              // …when it was
    }

    enum Reason: Equatable {
        case onTheWay(trip: Date)
        case atSchool(Date)
    }

    enum Decision: Equatable {
        case ring
        case skip(Reason)
    }

    /// The day's record: the one kept when it's that day's, else a new one.
    static func fresh(_ s: Seen?, day: String) -> Seen {
        if let s, s.day == day { return s }
        return Seen(day: day)
    }

    /// Does a trip go to school? Your fixed route to school, or its last stop within 1.5 km of school.
    static func towardSchool(lastStopMetres: Double?, fixedToSchool: Bool) -> Bool {
        if fixedToSchool { return true }
        guard let m = lastStopMetres else { return false }
        return m <= schoolTripMetres
    }

    /// At school: a fresh fix within 400 m of it.
    static func atSchool(metres: Double?, fixAt: Date?, now: Date) -> Bool {
        guard let m = metres, let f = fixAt else { return false }
        return m <= atSchoolMetres && now.timeIntervalSince(f) <= freshFix
    }

    /// The decision for a day's alarm. `day`/`today` as yyyy-MM-dd; `morning`: 03:00 of that day; `alarm`: when it
    /// rings (nil: none set). Only today's alarm, only while it's still to ring.
    static func decide(day: String, today: String, alarm: Date?, now: Date, morning: Date, seen: Seen, live: Live) -> Decision {
        guard day == today, seen.day == day, let a = alarm, a > now else { return .ring }
        func thisMorning(_ d: Date?) -> Date? {
            guard let d, d >= morning, d <= now else { return nil }
            return d
        }
        let fresh: Bool = live.fixAt.map { now.timeIntervalSince($0) <= freshFix } ?? false
        let home: Double = live.homeMetres ?? .infinity
        let nearHome: Bool = fresh && home < homeMetres
        let far: Bool = fresh && home > farMetres
        // (a) a trip to school: it runs, or it started this morning and you're not back home
        if let t = thisMorning(seen.schoolTripAt), live.runningToSchool || !nearHome { return .skip(.onTheWay(trip: t)) }
        if nearHome { return .ring }
        // (b) already at school today
        if let s = thisMorning(seen.atSchool) { return .skip(.atSchool(s)) }
        // (c) left home this morning: a trip or ride started, and home's region left or more than 1 km away
        if let t = thisMorning(seen.tripAt), thisMorning(seen.leftHome) != nil || far { return .skip(.onTheWay(trip: t)) }
        return .ring
    }

    /// "already on the way (trip 07:12)", "already at school (08:40)"
    static func words(_ r: Reason, clock: (Date) -> String) -> String {
        switch r {
        case .onTheWay(let t): return "already on the way (trip \(clock(t)))"
        case .atSchool(let t): return "already at school (\(clock(t)))"
        }
    }

    /// The field log's line.
    static func logLine(_ r: Reason, clock: (Date) -> String) -> String { "school alarm · skipped: \(words(r, clock: clock))" }

    /// The days still to come (today and later) of a day-keyed list.
    static func prune<V>(_ m: [String: V], today: String) -> [String: V] { m.filter { $0.key >= today } }
}
