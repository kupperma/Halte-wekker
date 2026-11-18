import Foundation

/// A daily route the app knows by heart: its fixed routes via the hubs, the home panels, the friend's train, auto-start
/// by station names, the scoreboard and the metro map. Only Veghel ⇄ BUas for now (0.22). Without one, the app runs
/// door to door (Fastest trip, the school alarm's trip, Plan), and those corridor features are hidden.
enum Corridor: String, Codable, Sendable, CaseIterable {
    case veghelBreda

    /// Where its home and school are: Veghel bus station and the BUas campus (the 0.21 places, to the digit).
    var homeAnchor: GeoPoint { GeoPoint(lat: 51.6137, lon: 5.5474) }
    var schoolAnchor: GeoPoint { GeoPoint(lat: 51.5907, lon: 4.7932) }
    /// A home this close to the anchor rides the corridor's buses (Veghel and around it).
    static let homeRadius = 6000.0
    /// A school this close to the anchor is the corridor's school (the campus, not just Breda).
    static let schoolRadius = 400.0
}

/// Where the school alarm finds your first class of each day.
enum ScheduleSource: Equatable, Sendable {
    /// Calendars on this iPhone that you pick (TimeEdit, a subscribed roster link, Google, Outlook…): today's flow.
    case calendars
    /// The same first-class time each weekday.
    case manual(ManualWeek)
    /// Not set up (later).
    case none
}

extension ScheduleSource: Codable {
    private enum CodingKeys: String, CodingKey { case kind, week }

    // Postel: an unknown kind (from a newer version) or a manual week that doesn't read is "not set up".
    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { self = ScheduleSource.none; return }
        switch (try? c.decode(String.self, forKey: .kind)) ?? "" {
        case "calendars": self = .calendars
        case "manual": self = (try? c.decode(ManualWeek.self, forKey: .week)).map { ScheduleSource.manual($0) } ?? ScheduleSource.none
        default: self = ScheduleSource.none
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .calendars: try c.encode("calendars", forKey: .kind)
        case .manual(let w): try c.encode("manual", forKey: .kind); try c.encode(w, forKey: .week)
        case .none: try c.encode("none", forKey: .kind)
        }
    }
}

/// Who you are to the app, besides your places (those are `PlacesStore`'s, under `places.v1`: no second copy of a
/// coordinate here). Saved under `profile.v1`.
struct Profile: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    /// The first-run setup is done (or wasn't needed: you used the app before 0.22).
    var setupDone: Bool
    /// The school you picked from the bundled list, and its campus (0.23).
    var schoolCatalogId: String?
    var campus: String?
    /// The route the app knows by heart, if yours is one (nil: door to door only).
    var corridor: Corridor?
    var schedule: ScheduleSource
    /// Words that mark a calendar (or its events) as your school timetable.
    var calendarHints: [String]

    init(version: Int = Profile.currentVersion, setupDone: Bool, schoolCatalogId: String? = nil, campus: String? = nil,
         corridor: Corridor?, schedule: ScheduleSource, calendarHints: [String]) {
        self.version = version; self.setupDone = setupDone; self.schoolCatalogId = schoolCatalogId; self.campus = campus
        self.corridor = corridor; self.schedule = schedule; self.calendarHints = calendarHints
    }

    // Postel, as `SavedPlace`: an older or newer copy still reads. A missing or unknown corridor is none, an unknown
    // schedule is "not set up", a missing setupDone is done (a saved profile means the app was used already).
    enum CodingKeys: String, CodingKey { case version, setupDone, schoolCatalogId, campus, corridor, schedule, calendarHints }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? Profile.currentVersion
        setupDone = (try? c.decode(Bool.self, forKey: .setupDone)) ?? true
        schoolCatalogId = try? c.decodeIfPresent(String.self, forKey: .schoolCatalogId)
        campus = try? c.decodeIfPresent(String.self, forKey: .campus)
        corridor = (try? c.decodeIfPresent(String.self, forKey: .corridor)).flatMap { Corridor(rawValue: $0) }
        schedule = (try? c.decode(ScheduleSource.self, forKey: .schedule)) ?? ScheduleSource.none
        calendarHints = (try? c.decode([String].self, forKey: .calendarHints)) ?? []
    }
}

/// The rules of the profile: telling a user of an older version from a new install, the profile they get, and which
/// corridor a home and school are on.
enum ProfileLogic {
    static let storageKey = "profile.v1"

    /// Today's (0.21) school calendar hints, for the BUas timetable in TimeEdit.
    static let legacyHints = ["timeedit", "buas", "breda university", "hopmansstraat"]

    /// Saved keys any earlier version writes once it's been used: one of them there means you're not new.
    static let existingUserKeys: Set<String> = [
        "places.v1", "school.on", "dir", "boardStops", "savedStops", "trips", "kmMem", "sound", "ui.newLook",
        "customDest", "noticeLog",
    ]

    static func isExistingUser(keys: Set<String>) -> Bool { !keys.isDisjoint(with: existingUserKeys) }

    /// Which corridor a home and school are on: a home within 6 km of Veghel and a school within 400 m of BUas is
    /// Veghel ⇄ BUas (so a reinstall that picks BUas and a Veghel home gets everything back).
    static func corridor(home: GeoPoint, school: GeoPoint) -> Corridor? {
        for c in Corridor.allCases
        where Geo.metres(home, c.homeAnchor) < Corridor.homeRadius && Geo.metres(school, c.schoolAnchor) < Corridor.schoolRadius {
            return c
        }
        return nil
    }

    /// The profile of someone who used the app before profiles (0.21 and older): set up, on the corridor their saved
    /// Home and School are on (no places saved yet: Veghel ⇄ BUas, today's defaults), their picked calendars.
    static func legacy(places: [SavedPlace]?) -> Profile {
        var corridor: Corridor? = .veghelBreda
        if let l = places, let h = l.first(where: { $0.kind == .home }), let s = l.first(where: { $0.kind == .school }) {
            corridor = self.corridor(home: h.point, school: s.point)
        }
        return Profile(setupDone: true, corridor: corridor, schedule: .calendars, calendarHints: legacyHints)
    }

    /// A new student's profile before setup (0.23: the setup flow starts from it, so does "Test the setup").
    static let fresh = Profile(setupDone: false, corridor: nil, schedule: ScheduleSource.none, calendarHints: [])

    static func decode(_ data: Data?) -> Profile? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(Profile.self, from: data)
    }

    static func encode(_ p: Profile) -> Data? { try? JSONEncoder().encode(p) }

    /// The profile at launch: the saved one; none saved, an earlier version's user gets the legacy profile, set up,
    /// and a new install (0.23) starts from `fresh`: the first-run setup opens.
    static func load(data: Data?, existing: Bool, places: [SavedPlace]? = nil) -> Profile {
        if let p = decode(data) { return p }
        return existing ? legacy(places: places) : fresh
    }
}
