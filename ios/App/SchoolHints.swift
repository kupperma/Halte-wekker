import Foundation

/// Does a calendar look like your school timetable? Words in its name (or its account's), else in its events' links,
/// notes and rooms. The school alarm marks those calendars and picks them for you when none is picked yet.
///
/// On the Veghel ⇄ BUas profile the words are exactly 0.22's (TimeEdit, BUas, Hopmansstraat); for anyone else the
/// timetable apps Dutch schools use, plus their own school's names. Plain values, tested.
struct SchoolHints: Equatable, Sendable {
    /// Words looked for in the calendar's name and its account's name.
    var names: [String]
    /// Words looked for in its events (link, notes, room).
    var events: [String]

    /// 0.22's lists, to the word.
    static let legacy = SchoolHints(names: ["timeedit", "buas", "rooster", "breda university", "school", "timetable"],
                                    events: ["timeedit", "buas", "hopmansstraat"])

    /// The timetable apps and the words any school's timetable calendar tends to be called.
    static let generic = ["timeedit", "mytimetable", "xedule", "untis", "rooster", "lesrooster", "timetable", "school"]
    /// The apps that fill a timetable calendar (their names show up in the events' links).
    static let apps = ["timeedit", "mytimetable", "xedule", "untis"]

    /// Shorter than this, a school's own word ("UU", "HvA") would match too much ("chrome", "vhv").
    static let minimumLength = 4

    /// The words for a profile's hints and the school's names (its short name and full name).
    static func make(profileHints: [String], school: [String]) -> SchoolHints {
        if profileHints == ProfileLogic.legacyHints { return legacy }
        let own = (profileHints + school).map(fold).filter { $0.count >= minimumLength }
        return SchoolHints(names: unique(generic + own), events: unique(apps + own))
    }

    /// Lower case, without accents ("Hogeschool Inhölland" reads as "hogeschool inholland").
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A calendar by its title and its account's name, then (only if those don't say) the text of its events, asked
    /// for only when needed (reading events is slow).
    static func matches(title: String, source: String, eventText: () -> [String], hints: SchoolHints) -> Bool {
        let name = fold(title + " " + source)
        if hints.names.contains(where: { name.contains($0) }) { return true }
        return eventText().contains { t in
            let f = fold(t)
            return hints.events.contains { f.contains($0) }
        }
    }

    private static func unique(_ l: [String]) -> [String] {
        var seen = Set<String>()
        return l.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
