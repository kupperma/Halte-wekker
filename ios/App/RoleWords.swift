import Foundation

/// How the app names your school and home in its sentences. On the Veghel ⇄ BUas corridor these are today's (0.21)
/// words exactly: "BUas", "Veghel", "Breda", "TimeEdit". Without a corridor they come from your places.
struct RoleWords: Equatable, Sendable {
    /// Your school, short: "BUas".
    var school: String
    /// Your home town: "Veghel"; without a corridor, "home".
    var homeTown: String
    /// Where going to school takes you: "Breda" (the station's town); without a corridor, the school.
    var toSchoolWord: String
    /// The app that fills your school calendar, if the profile knows it: "TimeEdit".
    var timetableApp: String?
    /// On a corridor (the town names are real towns).
    var onCorridor: Bool

    static let legacy = RoleWords(school: "BUas", homeTown: "Veghel", toSchoolWord: "Breda", timetableApp: "TimeEdit", onCorridor: true)

    /// Timetable apps by the hint that names them.
    static let timetableApps = ["timeedit": "TimeEdit", "mytimetable": "MyTimetable", "xedule": "Xedule", "untis": "Untis"]

    /// The words for a school (its short name), a corridor and the calendar hints.
    static func make(school: String, corridor: Corridor?, hints: [String]) -> RoleWords {
        let app = hints.first.flatMap { timetableApps[$0.lowercased()] }
        switch corridor {
        case .veghelBreda?:
            return RoleWords(school: school, homeTown: "Veghel", toSchoolWord: "Breda", timetableApp: app, onCorridor: true)
        case nil:
            return RoleWords(school: school, homeTown: "home", toSchoolWord: school, timetableApp: app, onCorridor: false)
        }
    }

    // MARK: the sentences

    /// "At BUas 08:41"
    func atSchool(_ time: String) -> String { "At \(school) \(time)" }
    /// "at BUas 08:41"
    func atSchoolLower(_ time: String) -> String { "at \(school) \(time)" }
    /// The big direction word on the old home: "BREDA".
    var directionWord: String { toSchoolWord.uppercased() }
    /// The destination menus: "To school (BUas)", "Home (Veghel)".
    var toSchoolMenu: String { "To school (\(school))" }
    var homeMenu: String { onCorridor ? "Home (\(homeTown))" : "Home" }
    /// Where a trip home or to school starts: "your Veghel stops", "your home stops".
    var homeStops: String { onCorridor ? "your \(homeTown) stops" : "your home stops" }
    /// Home as a destination's name: "Veghel", "Home".
    var homeName: String { onCorridor ? homeTown : "Home" }
    /// "home to Veghel", "home"
    var homeToTown: String { onCorridor ? "home to \(homeTown)" : "home" }
    /// The direction you're set to, as it guesses from where you are.
    var atHomeToast: String {
        onCorridor ? "You’re in \(homeTown), so it’s set to going to \(toSchoolWord)." : "You’re home, so it’s set to going to \(school)."
    }
    var atSchoolTownToast: String {
        onCorridor ? "You’re in \(toSchoolWord), so it’s set to going home." : "You’re at \(school), so it’s set to going home."
    }
    /// Reaching school switches to going home.
    var autoHomeToast: String { "You’re at \(school), so it switched to Home. Tap the big button to switch back." }
    /// "From your TimeEdit timetable", "From your school timetable".
    var fromTimetable: String { "From your \(timetableApp ?? "school") timetable" }
    /// "Pick only the calendar TimeEdit fills."
    var pickCalendar: String {
        timetableApp.map { "Pick only the calendar \($0) fills." } ?? "Pick only the calendar your school timetable is in."
    }

    /// The planner calls a trip's coordinate end "END" (or "START"): that's your school.
    func endpoint(_ name: String) -> String? { name == "END" || name == "START" ? school : nil }
}
