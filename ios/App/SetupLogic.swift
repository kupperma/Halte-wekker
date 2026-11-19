import Foundation

/// The first-run setup's steps, in order (0.23; "Help improve Haltewekker" before Done since 0.32).
enum SetupStep: Int, CaseIterable, Sendable {
    case welcome, school, home, places, timetable, arrival, improve, done

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .school: return "Your school"
        case .home: return "Your home"
        case .places: return "Other places"
        case .timetable: return "Your timetable"
        case .arrival: return "Mornings"
        case .improve: return "Help improve Haltewekker"
        case .done: return "All set"
        }
    }

    /// School and Home must be set; the rest can wait.
    var required: Bool { self == .school || self == .home }
}

/// Where the setup's timetable comes from.
enum TimetableChoice: String, CaseIterable, Sendable {
    /// A calendar already on this iPhone (TimeEdit's, Google, Outlook…).
    case calendars
    /// A roster or iCal link, subscribed to as a calendar (iOS asks).
    case link
    /// The same first-class time each weekday.
    case manual
    case later
}

/// A stop near home, to pick for the home board: a stop area (all its platforms), or a single stop.
struct SetupStop: Equatable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var metres: Double = 0
    var rail = false
    /// Where it is (for the auto-start's region around it, 0.24).
    var lat: Double? = nil
    var lon: Double? = nil
}

/// One of the stops `/v1/map/stops` lists, as the setup reads it.
struct SetupStopRaw: Equatable, Sendable {
    var id: String
    var name: String
    var parentId: String?
    var metres: Double
    var rail: Bool
    var lat: Double? = nil
    var lon: Double? = nil
}

/// A calendar on the phone, as the setup sees it.
struct SetupCalendar: Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var source: String
    /// A subscribed calendar (a roster link).
    var subscribed: Bool
}

/// What the setup has been told so far. Nothing is saved until Done (`SetupLogic.places`, `.profile`).
struct SetupDraft: Equatable, Sendable {
    var school: SavedPlace?
    var schoolCatalogId: String?
    var campus: String?
    /// The school's names for the calendar hints (its short and full name).
    var schoolNames: [String] = []
    /// The calendar hints kept from before ("Set up again" without a new school keeps them).
    var keptHints: [String]?
    var home: SavedPlace?
    /// How Home was found ("Where you were at 08:12", an address), for the summary.
    var homeLabel: String?
    /// The home board's stops (1–3).
    var board: [SetupStop] = []
    /// The board is the setup's to save: always for a new student; "Set up again" only once you change it (or Home).
    var boardChosen = true
    /// Your other places (Work, Sports…).
    var others: [SavedPlace] = []
    var timetable: TimetableChoice?
    var week: ManualWeek = .workdays
    var calendarIds: Set<String> = []
    var earlyMinutes = 10
    var wakeMinutes = 60
    var wakeOn = false
    /// Help improve Haltewekker (0.32): both off unless turned on.
    var shareLogs = false
    var shareFixes = false

    /// A new student's: nothing yet, today's defaults for the times.
    static let empty = SetupDraft()
}

/// The setup's rules: the order of the steps, what must be filled in, the roster link, the new subscribed calendar,
/// and what Done saves. Plain values, tested.
enum SetupLogic {
    static let maxBoardStops = 3
    static let earlyRange = 0...45
    static let wakeRange = 15...150

    static func next(_ s: SetupStep) -> SetupStep? { SetupStep(rawValue: s.rawValue + 1) }
    static func previous(_ s: SetupStep) -> SetupStep? { SetupStep(rawValue: s.rawValue - 1) }

    /// Can you go on from a step: School and Home need a place, the others can be skipped.
    static func canContinue(_ s: SetupStep, _ d: SetupDraft) -> Bool {
        switch s {
        case .school: return d.school != nil
        case .home: return d.home != nil
        default: return true
        }
    }

    /// Done needs a school and a home.
    static func canFinish(_ d: SetupDraft) -> Bool { d.school != nil && d.home != nil }

    /// The steps still missing something, in order.
    static func missing(_ d: SetupDraft) -> [SetupStep] { SetupStep.allCases.filter { $0.required && !canContinue($0, d) } }

    /// "Step 2 of 6" (the welcome isn't counted; Done is the last).
    static func counter(_ s: SetupStep) -> String? {
        guard s != .welcome else { return nil }
        return "Step \(s.rawValue) of \(SetupStep.allCases.count - 1)"
    }

    // MARK: the roster link

    /// A pasted roster or iCal link as a `webcal://` link iOS subscribes to: http(s) becomes webcal, webcal stays,
    /// spaces around it go; anything that isn't a web link to a host is nil.
    static func webcalURL(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(where: { $0.isWhitespace }), var c = URLComponents(string: t),
              let scheme = c.scheme?.lowercased(), ["http", "https", "webcal", "webcals"].contains(scheme),
              let host = c.host, host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".") else { return nil }
        c.scheme = "webcal"
        return c.url
    }

    /// The calendars a subscription added: subscribed ones that weren't there before.
    static func newSubscription(before: Set<String>, after: [SetupCalendar]) -> [SetupCalendar] {
        after.filter { $0.subscribed && !before.contains($0.id) }
    }

    // MARK: the home board

    /// The stops near home to choose from: one per stop area (a bus station's platforms are one), else one per name
    /// (both sides of the road), the nearest first, at most `limit`.
    static func stopChoices(_ raw: [SetupStopRaw], limit: Int = 8) -> [SetupStop] {
        var out: [SetupStop] = [], seen = Set<String>()
        for r in raw.sorted(by: { $0.metres < $1.metres }) {
            let key = r.parentId.map { "p:\($0)" } ?? "n:\(r.name.lowercased())"
            guard seen.insert(key).inserted else { continue }
            out.append(SetupStop(id: r.parentId ?? r.id, name: r.name, metres: r.metres, rail: r.rail, lat: r.lat, lon: r.lon))
            if out.count == limit { break }
        }
        return out
    }

    /// Picks or drops a stop for the board (at most three; a fourth is ignored).
    static func toggle(_ s: SetupStop, in board: [SetupStop]) -> [SetupStop] {
        if board.contains(where: { $0.id == s.id }) { return board.filter { $0.id != s.id } }
        return board.count < maxBoardStops ? board + [s] : board
    }

    // MARK: what Done saves

    /// The schedule source the draft makes.
    static func schedule(_ d: SetupDraft) -> ScheduleSource {
        switch d.timetable {
        case .calendars?, .link?: return .calendars
        case .manual?: return d.week.isEmpty ? ScheduleSource.none : .manual(d.week)
        case .later?, nil: return ScheduleSource.none
        }
    }

    /// The calendar hints: kept from before, else the school's own names.
    static func hints(_ d: SetupDraft) -> [String] {
        if let k = d.keptHints { return k }
        var seen = Set<String>()
        return d.schoolNames.map { $0.lowercased() }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Your places: Home and School (with these ids, so they stay the same places), then the others.
    static func places(_ d: SetupDraft) -> [SavedPlace] {
        var out: [SavedPlace] = []
        if var h = d.home {
            h.id = "home"; h.kind = .home
            if d.boardChosen, !d.board.isEmpty { h.stopIds = d.board.map(\.id) }
            out.append(h)
        }
        if var s = d.school {
            s.id = "school"; s.kind = .school
            if s.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { s.name = "School" }
            out.append(s)
        }
        var ids = Set(out.map(\.id))
        for var p in d.others {
            p.kind = .custom
            if !ids.insert(p.id).inserted { p.id = PlacesLogic.newId(out, seed: p.id); ids.insert(p.id) }
            out.append(p)
        }
        return out
    }

    /// The profile Done saves: set up, with the school from the list (if it came from there), the corridor its Home
    /// and School are on, the timetable's source and the hints.
    static func profile(_ d: SetupDraft) -> Profile {
        var corridor: Corridor?
        if let h = d.home, let s = d.school { corridor = ProfileLogic.corridor(home: h.point, school: s.point) }
        return Profile(setupDone: true, schoolCatalogId: d.schoolCatalogId, campus: d.campus, corridor: corridor,
                       schedule: schedule(d), calendarHints: hints(d))
    }

    /// The home board Done saves (its stops and lines: a new board shows every line), or nil to leave it as it is.
    static func board(_ d: SetupDraft) -> (stops: [SetupStop], lines: [String])? {
        d.boardChosen ? (Array(d.board.prefix(maxBoardStops)), []) : nil
    }

    /// The school alarm's calendars after Done: those picked for a calendar or a link, else none.
    static func calendarIds(_ d: SetupDraft) -> Set<String> {
        switch d.timetable {
        case .calendars?, .link?: return d.calendarIds
        default: return []
        }
    }

    // MARK: words

    /// "Mon–Fri 08:30", "Mon 08:30 · Wed 10:15", with an end time "Mon–Fri 08:30–15:00" (0.28).
    static func weekWords(_ w: ManualWeek) -> String {
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let clock = { (m: Int) in String(format: "%02d:%02d", m / 60, m % 60) }
        let span = { (d: ManualWeek.Day) -> String in d.end.map { clock(d.minutes) + "–" + clock($0) } ?? clock(d.minutes) }
        guard !w.days.isEmpty else { return "No days yet" }
        let times = Set(w.days.map(span))
        let wds = w.days.map(\.weekday)
        if times.count == 1, wds.count >= 3, wds == Array(wds.first!...wds.last!) {
            return "\(names[wds.first! - 1])–\(names[wds.last! - 1]) \(span(w.days[0]))"
        }
        return w.days.map { "\(names[$0.weekday - 1]) \(span($0))" }.joined(separator: " · ")
    }

    /// The sharing line of the summary (0.32).
    static func shareWords(_ d: SetupDraft) -> String {
        switch (d.shareLogs, d.shareFixes) {
        case (false, false): return "Nothing shared"
        case (true, false): return "Ride logs"
        case (false, true): return "GPS points during rides"
        case (true, true): return "Ride logs and GPS points during rides"
        }
    }

    /// The timetable line of the summary.
    static func timetableWords(_ d: SetupDraft) -> String {
        let n = d.calendarIds.count
        let cals = n == 0 ? "no calendar picked yet" : n == 1 ? "1 calendar" : "\(n) calendars"
        switch d.timetable {
        case .calendars?: return "On this iPhone · \(cals)"
        case .link?: return "Roster link · \(cals)"
        case .manual?: return "Same times every week · \(weekWords(d.week))"
        case .later?, nil: return "Later"
        }
    }
}
