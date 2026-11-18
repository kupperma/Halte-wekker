import XCTest

final class RoleWordsTests: XCTestCase {
    func test_legacyWordsAreTodays() {
        let w = RoleWords.make(school: "BUas", corridor: .veghelBreda, hints: ProfileLogic.legacyHints)
        XCTAssertEqual(w, RoleWords.legacy)
        XCTAssertEqual(w.school, "BUas")
        XCTAssertEqual(w.homeTown, "Veghel")
        XCTAssertEqual(w.toSchoolWord, "Breda")
        XCTAssertEqual(w.atSchool("08:41"), "At BUas 08:41")
        XCTAssertEqual(w.atSchoolLower("08:41"), "at BUas 08:41")
        XCTAssertEqual(w.directionWord, "BREDA")
        XCTAssertEqual(w.toSchoolMenu, "To school (BUas)")
        XCTAssertEqual(w.homeMenu, "Home (Veghel)")
        XCTAssertEqual(w.homeStops, "your Veghel stops")
        XCTAssertEqual(w.homeToTown, "home to Veghel")
        XCTAssertEqual(w.homeName, "Veghel")
        XCTAssertEqual(w.atHomeToast, "You’re in Veghel, so it’s set to going to Breda.")
        XCTAssertEqual(w.atSchoolTownToast, "You’re in Breda, so it’s set to going home.")
        XCTAssertEqual(w.autoHomeToast, "You’re at BUas, so it switched to Home. Tap the big button to switch back.")
        XCTAssertEqual(w.fromTimetable, "From your TimeEdit timetable")
        XCTAssertEqual(w.pickCalendar, "Pick only the calendar TimeEdit fills.")
    }

    func test_genericWords() {
        let w = RoleWords.make(school: "Fontys", corridor: nil, hints: [])
        XCTAssertEqual(w.atSchool("08:41"), "At Fontys 08:41")
        XCTAssertEqual(w.toSchoolWord, "Fontys")
        XCTAssertEqual(w.directionWord, "FONTYS")
        XCTAssertEqual(w.homeMenu, "Home")
        XCTAssertEqual(w.toSchoolMenu, "To school (Fontys)")
        XCTAssertEqual(w.homeStops, "your home stops")
        XCTAssertEqual(w.homeToTown, "home")
        XCTAssertEqual(w.homeName, "Home")
        XCTAssertEqual(w.atHomeToast, "You’re home, so it’s set to going to Fontys.")
        XCTAssertEqual(w.atSchoolTownToast, "You’re at Fontys, so it’s set to going home.")
        XCTAssertEqual(w.fromTimetable, "From your school timetable")
        XCTAssertEqual(w.pickCalendar, "Pick only the calendar your school timetable is in.")
        XCTAssertEqual(RoleWords.make(school: "TU/e", corridor: nil, hints: ["MyTimetable"]).fromTimetable, "From your MyTimetable timetable")
    }

    func test_endpoints() {
        XCTAssertEqual(RoleWords.legacy.endpoint("END"), "BUas")
        XCTAssertEqual(RoleWords.legacy.endpoint("START"), "BUas")
        XCTAssertNil(RoleWords.legacy.endpoint("Breda, Centraal Station"))
        XCTAssertEqual(RoleWords.make(school: "Fontys", corridor: nil, hints: []).endpoint("END"), "Fontys")
    }
}
