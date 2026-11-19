import XCTest

final class ManualWeekLessonsTests: XCTestCase {
    private let ams = TimeZone(identifier: "Europe/Amsterdam")!

    private func date(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)!
    }

    private func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.timeZone = ams; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "EEE HH:mm"
        return f.string(from: d)
    }

    /// Monday 08:30 and Wednesday 10:15; summer time ends on Sunday 26 October 2025.
    private let week = ManualWeek(days: [.init(weekday: 2, minutes: 510), .init(weekday: 4, minutes: 615)])

    func test_nextEightDaysAcrossTheEndOfSummerTime() {
        // Thursday 23 October 2025, 12:00 in Amsterdam (summer time, +02:00)
        let l = week.lessons(from: date("2025-10-23T12:00:00+02:00"), days: 8, tz: ams)
        XCTAssertEqual(l.map(\.day), ["2025-10-27", "2025-10-29"])
        XCTAssertEqual(l.map { clock($0.start) }, ["Mon 08:30", "Wed 10:15"])
        // Monday after the change is winter time (+01:00): 08:30 there is 07:30 UTC
        XCTAssertEqual(l[0].start, date("2025-10-27T07:30:00Z"))
    }

    func test_aDayWithoutClassHasNone() {
        let l = week.lessons(from: date("2025-11-04T06:00:00+01:00"), days: 1, tz: ams)       // a Tuesday
        XCTAssertTrue(l.isEmpty)
    }

    func test_aTimeAlreadyPastTodayIsLeftOut() {
        let mondayNine = date("2025-11-03T09:00:00+01:00")
        let l = week.lessons(from: mondayNine, days: 8, tz: ams)
        XCTAssertEqual(l.map(\.day), ["2025-11-05", "2025-11-10"])
        let mondayEight = date("2025-11-03T08:00:00+01:00")
        XCTAssertEqual(week.lessons(from: mondayEight, days: 1, tz: ams).map(\.day), ["2025-11-03"])
    }

    func test_setAndClearADay() {
        var w = ManualWeek.workdays
        XCTAssertEqual(w.days.count, 5)
        w.set(weekday: 3, minutes: nil)
        XCTAssertNil(w.minutes(weekday: 3))
        w.set(weekday: 7, minutes: 600)
        XCTAssertEqual(w.minutes(weekday: 7), 600)
        XCTAssertEqual(w.days.map(\.weekday), [2, 4, 5, 6, 7])
    }
}

final class SchoolHintsTests: XCTestCase {
    private func matches(_ title: String, _ source: String = "iCloud", events: [String] = [], hints h: SchoolHints) -> Bool {
        SchoolHints.matches(title: title, source: source, eventText: { events }, hints: h)
    }

    func test_legacyHintsAreTodaysLists() {
        let h = SchoolHints.make(profileHints: ProfileLogic.legacyHints, school: ["BUas"])
        XCTAssertEqual(h, SchoolHints.legacy)
        XCTAssertEqual(h.names, ["timeedit", "buas", "rooster", "breda university", "school", "timetable"])
        XCTAssertEqual(h.events, ["timeedit", "buas", "hopmansstraat"])
    }

    func test_legacyCases() {
        let h = SchoolHints.legacy
        XCTAssertTrue(matches("TimeEdit", hints: h))
        XCTAssertTrue(matches("Rooster BUas", hints: h))
        XCTAssertTrue(matches("Calendar", "Breda University", hints: h))
        XCTAssertTrue(matches("Lessen", events: ["https://cloud.timeedit.net/buas/web"], hints: h))
        XCTAssertTrue(matches("Lessen", events: ["Mgr. Hopmansstraat 2, Breda"], hints: h))
        XCTAssertFalse(matches("Home", events: ["Dinner at Ana’s"], hints: h))
        // (0.22's lists: other apps' names in an event don't count on this profile)
        XCTAssertFalse(matches("Lessen", events: ["mytimetable.example.nl"], hints: h))
    }

    func test_genericHintsIgnoreCaseAndAccents() {
        let h = SchoolHints.make(profileHints: ["fontys", "fontys university of applied sciences"], school: ["Fontys"])
        XCTAssertTrue(matches("FONTYS rooster", hints: h))
        XCTAssertTrue(matches("Mijn Lesrooster", hints: h))
        XCTAssertTrue(matches("Planning", events: ["https://fontys.mytimetable.nl/schedule"], hints: h))
        XCTAssertTrue(matches("Planning", events: ["Fóntys R1"], hints: h))
        XCTAssertTrue(matches("XEDULE", hints: h))
        XCTAssertFalse(matches("Work", events: ["Meeting"], hints: h))
    }

    func test_shortSchoolWordsDontMatchEverything() {
        let h = SchoolHints.make(profileHints: ["uu"], school: ["UU"])
        XCTAssertFalse(h.names.contains("uu"))
        XCTAssertFalse(matches("Vacuum", hints: h))
    }

    func test_eventsAreOnlyReadWhenTheNameDoesntSay() {
        var read = false
        _ = SchoolHints.matches(title: "TimeEdit", source: "", eventText: { read = true; return [] }, hints: .legacy)
        XCTAssertFalse(read)
    }
}

final class SchoolCatalogTests: XCTestCase {
    private var list: [SchoolEntry] = []

    override func setUp() {
        super.setUp()
        let url = Bundle(for: Self.self).url(forResource: "Schools", withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../App/Schools.json")
        list = SchoolCatalog.decode(try? Data(contentsOf: url))
    }

    func test_theBundledListDecodes() {
        XCTAssertGreaterThan(list.count, 50)
        XCTAssertEqual(Set(list.map(\.id)).count, list.count, "ids are unique")
        XCTAssertTrue(list.allSatisfy { !$0.campuses.isEmpty && !$0.short.isEmpty })
    }

    func test_everyCampusIsInTheNetherlands() {
        for s in list { for c in s.campuses { XCTAssertTrue(SchoolCatalog.inNetherlands(c.point), "\(s.id) \(c.name)") } }
    }

    func test_buasIsOnTheCorridor() {
        let b = list.first { $0.id == "buas" }
        XCTAssertNotNil(b)
        let veghel = GeoPoint(lat: 51.6137, lon: 5.5474)
        XCTAssertEqual(b.flatMap { ProfileLogic.corridor(home: veghel, school: $0.campuses[0].point) }, .veghelBreda)
    }

    func test_searchByAlias() {
        XCTAssertEqual(SchoolCatalog.search("tue", in: list).first?.entry.id, "tue")
        XCTAssertEqual(SchoolCatalog.search("TU/e", in: list).first?.entry.id, "tue")
        XCTAssertEqual(SchoolCatalog.search("hva", in: list).first?.entry.id, "hva")
    }

    func test_searchNarrowsTheCampus() {
        let h = SchoolCatalog.search("Fontys Venlo", in: list).first
        XCTAssertEqual(h?.entry.id, "fontys")
        XCTAssertEqual(h?.campuses.map(\.city), ["Venlo"])
        XCTAssertEqual(h?.needsCampusPick, false)
        let all = SchoolCatalog.search("fontys", in: list).first
        XCTAssertEqual(all?.needsCampusPick, true)
        XCTAssertEqual(all?.campuses.count, all?.entry.campuses.count)
    }

    func test_searchIgnoresAccentsAndCase() {
        XCTAssertEqual(SchoolCatalog.search("Hogeschool Inholland", in: list).first?.entry.id, "inholland")
        XCTAssertEqual(SchoolCatalog.search("hogeschool inhölland", in: list).first?.entry.id, "inholland")
        XCTAssertEqual(SchoolCatalog.search("INHOLLAND rotterdam", in: list).first?.campuses.map(\.city), ["Rotterdam"])
    }

    func test_nothingForNonsense() {
        XCTAssertTrue(SchoolCatalog.search("qqqzzz", in: list).isEmpty)
        XCTAssertTrue(SchoolCatalog.search("   ", in: list).isEmpty)
    }

    func test_lenientDecoding() {
        let json = """
        [{"id": "a", "name": "A School", "campuses": [{"name": "X", "city": "Breda", "lat": 51.5, "lon": 4.7}, {"name": "bad"}]},
         {"id": "b", "name": "No campus", "campuses": []},
         {"name": "no id"}]
        """
        let l = SchoolCatalog.decode(Data(json.utf8))
        XCTAssertEqual(l.map(\.id), ["a"])
        XCTAssertEqual(l.first?.short, "A School")
        XCTAssertEqual(l.first?.campuses.count, 1)
        XCTAssertTrue(SchoolCatalog.decode(Data("nope".utf8)).isEmpty)
    }
}

final class SetupLogicTests: XCTestCase {
    private let school = SavedPlace(id: "x", name: "Fontys", kind: .custom, lat: 51.4512, lon: 5.4796)
    private let home = SavedPlace(id: "y", name: "Home", kind: .custom, lat: 51.4416, lon: 5.4697)

    func test_webcalURL() {
        XCTAssertEqual(SetupLogic.webcalURL("https://cloud.timeedit.net/buas/web/ical/abc.ics")?.absoluteString,
                       "webcal://cloud.timeedit.net/buas/web/ical/abc.ics")
        XCTAssertEqual(SetupLogic.webcalURL("http://rooster.example.nl/x.ics?k=1")?.absoluteString, "webcal://rooster.example.nl/x.ics?k=1")
        XCTAssertEqual(SetupLogic.webcalURL("webcal://example.nl/r.ics")?.absoluteString, "webcal://example.nl/r.ics")
        XCTAssertEqual(SetupLogic.webcalURL("  \nhttps://example.nl/r.ics \t")?.absoluteString, "webcal://example.nl/r.ics")
        XCTAssertNil(SetupLogic.webcalURL("just some words"))
        XCTAssertNil(SetupLogic.webcalURL("ftp://example.nl/r.ics"))
        XCTAssertNil(SetupLogic.webcalURL("https://localhost/r.ics"))
        XCTAssertNil(SetupLogic.webcalURL("example.nl/r.ics"))
        XCTAssertNil(SetupLogic.webcalURL(""))
    }

    func test_newSubscription() {
        let before: Set<String> = ["a", "b"]
        let after = [SetupCalendar(id: "a", title: "Home", source: "iCloud", subscribed: false),
                     SetupCalendar(id: "b", title: "Old roster", source: "Subscribed", subscribed: true),
                     SetupCalendar(id: "c", title: "Rooster", source: "Subscribed", subscribed: true),
                     SetupCalendar(id: "d", title: "Work", source: "Google", subscribed: false)]
        XCTAssertEqual(SetupLogic.newSubscription(before: before, after: after).map(\.id), ["c"])
        XCTAssertTrue(SetupLogic.newSubscription(before: ["a", "b", "c", "d"], after: after).isEmpty)
    }

    func test_stepOrderAndWhatsRequired() {
        XCTAssertEqual(SetupStep.allCases, [.welcome, .school, .home, .places, .timetable, .arrival, .improve, .done])
        XCTAssertEqual(SetupLogic.next(.welcome), .school)
        XCTAssertNil(SetupLogic.next(.done))
        XCTAssertNil(SetupLogic.previous(.welcome))
        XCTAssertEqual(SetupLogic.counter(.school), "Step 1 of 7")
        XCTAssertEqual(SetupLogic.counter(.improve), "Step 6 of 7")
        XCTAssertEqual(SetupLogic.counter(.done), "Step 7 of 7")
        XCTAssertEqual(SetupLogic.next(.arrival), .improve)
        XCTAssertTrue(SetupLogic.canContinue(.improve, .empty), "sharing is optional")
        var d = SetupDraft.empty
        XCTAssertFalse(SetupLogic.canContinue(.school, d))
        XCTAssertTrue(SetupLogic.canContinue(.places, d))
        XCTAssertFalse(SetupLogic.canFinish(d))
        XCTAssertEqual(SetupLogic.missing(d), [.school, .home])
        d.school = school
        XCTAssertFalse(SetupLogic.canFinish(d))
        d.home = home
        XCTAssertTrue(SetupLogic.canFinish(d))
        XCTAssertEqual(SetupLogic.missing(d), [])
    }

    func test_whatDoneSaves() {
        var d = SetupDraft.empty
        d.school = school; d.home = home; d.schoolCatalogId = "fontys"; d.campus = "Eindhoven, Rachelsmolen"
        d.schoolNames = ["Fontys", "Fontys University of Applied Sciences"]
        d.board = [SetupStop(id: "s1", name: "Eindhoven, Centraal"), SetupStop(id: "s2", name: "Eindhoven, Fuutlaan")]
        d.others = [SavedPlace(id: "p-work", name: "Work", kind: .home, lat: 51.4, lon: 5.4)]
        let places = SetupLogic.places(d)
        XCTAssertEqual(places.map(\.id), ["home", "school", "p-work"])
        XCTAssertEqual(places.map(\.kind), [.home, .school, .custom])
        XCTAssertEqual(places[0].stopIds, ["s1", "s2"])
        XCTAssertEqual(places[1].stopIds, [])
        let p = SetupLogic.profile(d)
        XCTAssertTrue(p.setupDone)
        XCTAssertNil(p.corridor)
        XCTAssertEqual(p.schoolCatalogId, "fontys")
        XCTAssertEqual(p.calendarHints, ["fontys", "fontys university of applied sciences"])
        XCTAssertEqual(p.schedule, ScheduleSource.none)
        XCTAssertEqual(SetupLogic.board(d)?.stops.map(\.id), ["s1", "s2"])
        XCTAssertEqual(SetupLogic.board(d)?.lines, [])
    }

    func test_buasAndAVeghelHomeAreTheCorridor() {
        var d = SetupDraft.empty
        d.school = SavedPlace(id: "school", name: "BUas", kind: .school, lat: 51.59019, lon: 4.79427)
        d.home = SavedPlace(id: "home", name: "Home", kind: .home, lat: 51.62, lon: 5.54)
        XCTAssertEqual(SetupLogic.profile(d).corridor, .veghelBreda)
    }

    func test_scheduleAndCalendars() {
        var d = SetupDraft.empty
        d.calendarIds = ["c"]
        XCTAssertEqual(SetupLogic.schedule(d), ScheduleSource.none)
        XCTAssertEqual(SetupLogic.calendarIds(d), [])
        d.timetable = .link
        XCTAssertEqual(SetupLogic.schedule(d), .calendars)
        XCTAssertEqual(SetupLogic.calendarIds(d), ["c"])
        d.timetable = .manual
        XCTAssertEqual(SetupLogic.schedule(d), .manual(.workdays))
        XCTAssertEqual(SetupLogic.calendarIds(d), [])
        d.week = ManualWeek(days: [])
        XCTAssertEqual(SetupLogic.schedule(d), ScheduleSource.none)
    }

    func test_setUpAgainKeepsTheBoardAndHintsUntilChanged() {
        var d = SetupDraft.empty
        d.home = SavedPlace(id: "home", name: "Home", kind: .home, lat: 51.6, lon: 5.5, stopIds: ["old"])
        d.board = [SetupStop(id: "b1", name: "Stop")]
        d.boardChosen = false
        d.keptHints = ProfileLogic.legacyHints
        XCTAssertNil(SetupLogic.board(d))
        XCTAssertEqual(SetupLogic.places(d).first?.stopIds, ["old"])
        XCTAssertEqual(SetupLogic.hints(d), ProfileLogic.legacyHints)
    }

    func test_stopChoices() {
        let raw = [SetupStopRaw(id: "p1", name: "Veghel, Busstation", parentId: "area", metres: 120, rail: false),
                   SetupStopRaw(id: "p2", name: "Veghel, Busstation", parentId: "area", metres: 90, rail: false),
                   SetupStopRaw(id: "b2", name: "Veghel, Bolkenplein", parentId: nil, metres: 300, rail: false),
                   SetupStopRaw(id: "b1", name: "Veghel, Bolkenplein", parentId: nil, metres: 250, rail: false)]
        let c = SetupLogic.stopChoices(raw)
        XCTAssertEqual(c.map(\.id), ["area", "b1"])
        XCTAssertEqual(c.map(\.metres), [90, 250])
        var board: [SetupStop] = []
        for i in 0..<5 { board = SetupLogic.toggle(SetupStop(id: "\(i)", name: "\(i)"), in: board) }
        XCTAssertEqual(board.map(\.id), ["0", "1", "2"])
        board = SetupLogic.toggle(SetupStop(id: "1", name: "1"), in: board)
        XCTAssertEqual(board.map(\.id), ["0", "2"])
    }

    func test_words() {
        XCTAssertEqual(SetupLogic.weekWords(.workdays), "Mon–Fri 08:30")
        XCTAssertEqual(SetupLogic.weekWords(ManualWeek(days: [.init(weekday: 2, minutes: 510), .init(weekday: 4, minutes: 615)])),
                       "Mon 08:30 · Wed 10:15")
        var d = SetupDraft.empty
        XCTAssertEqual(SetupLogic.timetableWords(d), "Later")
        d.timetable = .calendars; d.calendarIds = ["a"]
        XCTAssertEqual(SetupLogic.timetableWords(d), "On this iPhone · 1 calendar")
    }
}

final class SetupBackupTests: XCTestCase {
    /// The current user's saved values (made-up, but the kinds UserDefaults holds).
    private func ownDefaults() -> [String: Any] {
        [
            "profile.v1": Data("{\"setupDone\":true,\"corridor\":\"veghelBreda\"}".utf8),
            "places.v1": Data("[{\"id\":\"home\"}]".utf8),
            "boardStops": Data("[{\"id\":\"a\",\"name\":\"Stop\"}]".utf8),
            "boardLines": ["305", "306", "158"],
            "school.on": true,
            "school.cals": ["cal-1"],
            "school.early": 10,
            "kmMem": ["bus:veghel": 1.5, "train:bd": 4.0],
            "lastMode": ["veghel": "bus"],
            "school.homeLat": 51.61,
            "dir": "toSchool",
        ]
    }

    private func take(_ d: [String: Any]) -> SetupBackup {
        SetupBackup.take(read: { d[$0] }, now: Date(timeIntervalSince1970: 1_000))
    }

    private func restore(_ b: SetupBackup, into d: inout [String: Any]) {
        var out = d
        b.restore { k, v in out[k] = v }
        d = out
    }

    func test_roundTripGivesIdenticalStoredValues() {
        let own = ownDefaults()
        let b = take(own)
        XCTAssertFalse(b.live)
        XCTAssertNil(b.values["dir"], "only the setup's keys")
        XCTAssertNil(b.values["school.wake"], "a key that wasn't there isn't made up")
        let back = SetupBackup(stored: b.stored)
        XCTAssertNotNil(back)
        XCTAssertTrue(back!.sameValues(as: b))
        var d: [String: Any] = [:]
        restore(back!, into: &d)
        XCTAssertTrue(NSDictionary(dictionary: d).isEqual(to: own.filter { $0.key != "dir" }))
    }

    func test_restoreAfterAPartialTest() {
        let own = ownDefaults()
        let b = SetupBackup(stored: take(own).stored)!
        // the test got halfway: a new profile and places, the board cleared, a wake time added, the learnt ones gone
        var d = own
        d["profile.v1"] = Data("{\"setupDone\":false}".utf8)
        d["places.v1"] = Data("[]".utf8)
        d["boardStops"] = Data("[]".utf8)
        d["school.wake"] = 75
        d["school.cals"] = nil
        d["kmMem"] = nil
        d["dir"] = "home"
        restore(b, into: &d)
        var want = own
        want["dir"] = "home"                   // (not the setup's: left as the test left it)
        XCTAssertTrue(NSDictionary(dictionary: d).isEqual(to: want))
        XCTAssertNil(d["school.wake"])
    }

    func test_liveAndLaunch() {
        var b = take(ownDefaults())
        XCTAssertEqual(SetupBackup.atLaunch(nil), .nothing)
        XCTAssertEqual(SetupBackup.atLaunch(b), .restore)
        b.live = true
        let back = SetupBackup(stored: b.stored)
        XCTAssertEqual(back?.live, true)
        XCTAssertEqual(SetupBackup.atLaunch(back), .keepTesting)
        XCTAssertEqual(back?.made, Date(timeIntervalSince1970: 1_000))
    }

    func test_unreadableIsNone() {
        XCTAssertNil(SetupBackup(stored: nil))
        XCTAssertNil(SetupBackup(stored: "x"))
        XCTAssertNil(SetupBackup(stored: ["version": 99, "covered": [String](), "values": [String: Any]()]))
    }

    func test_theKeysAreTheSetupsAndTheLearnt() {
        XCTAssertTrue(SetupBackup.keys.contains(ProfileLogic.storageKey))
        XCTAssertTrue(SetupBackup.keys.contains(PlacesLogic.storageKey))
        for k in ["boardStops", "boardLines", "school.on", "school.cals", "school.early", "school.wake", "kmMem", "lastMode",
                  "school.homeLat", "school.homeLon", "ui.homeStyle", "logShare.on", "gpsShare.on", ShareAsk.askedKey] { XCTAssertTrue(SetupBackup.keys.contains(k), k) }
        XCTAssertFalse(SetupBackup.keys.contains(SetupBackup.storageKey))
    }
}
