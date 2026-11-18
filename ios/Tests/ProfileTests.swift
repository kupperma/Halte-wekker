import XCTest

final class ProfileTests: XCTestCase {
    private let veghel = GeoPoint(lat: 51.6137, lon: 5.5474)
    private let buas = GeoPoint(lat: 51.5907, lon: 4.7932)

    /// A point `m` metres north of `p` (on Geo's flat earth, exactly).
    private func north(_ p: GeoPoint, _ m: Double) -> GeoPoint { GeoPoint(lat: p.lat + m / 110_540, lon: p.lon) }

    private func places(home: GeoPoint, school: GeoPoint) -> [SavedPlace] {
        [SavedPlace(id: "home", name: "Home", kind: .home, lat: home.lat, lon: home.lon, stopIds: ["a"]),
         SavedPlace(id: "school", name: "BUas", kind: .school, lat: school.lat, lon: school.lon)]
    }

    func test_newInstallIsNotAnExistingUser() {
        XCTAssertFalse(ProfileLogic.isExistingUser(keys: []))
        XCTAssertFalse(ProfileLogic.isExistingUser(keys: ["AppleLanguages", "NSInterfaceStyle", "watchdog.last"]))
    }

    func test_anyListedKeyIsAnExistingUser() {
        for k in ["places.v1", "school.on", "dir", "boardStops", "savedStops", "trips", "kmMem", "sound", "ui.newLook",
                  "customDest", "noticeLog"] {
            XCTAssertTrue(ProfileLogic.isExistingUser(keys: ["AppleLanguages", k]), k)
        }
    }

    func test_existingUserGetsTheLegacyProfileSetUp() {
        let p = ProfileLogic.load(data: nil, existing: true)
        XCTAssertTrue(p.setupDone)
        XCTAssertEqual(p.corridor, .veghelBreda)
        XCTAssertEqual(p.schedule, .calendars)
        XCTAssertEqual(p.calendarHints, ["timeedit", "buas", "breda university", "hopmansstraat"])
        XCTAssertEqual(p.version, Profile.currentVersion)
        XCTAssertNil(p.schoolCatalogId)
    }

    /// 0.22: a new install still rides today's defaults; only the flag says it wasn't set up.
    func test_newInstallGetsTodaysDefaultsNotSetUp() {
        let p = ProfileLogic.load(data: nil, existing: false)
        XCTAssertFalse(p.setupDone)
        XCTAssertEqual(p.corridor, .veghelBreda)
        XCTAssertFalse(ProfileLogic.fresh.setupDone)
        XCTAssertNil(ProfileLogic.fresh.corridor)
    }

    func test_legacyCorridorFollowsTheSavedPlaces() {
        XCTAssertEqual(ProfileLogic.legacy(places: places(home: veghel, school: buas)).corridor, .veghelBreda)
        XCTAssertEqual(ProfileLogic.legacy(places: nil).corridor, .veghelBreda)
        XCTAssertEqual(ProfileLogic.legacy(places: []).corridor, .veghelBreda)
        // Home moved to Eindhoven in Your places: no corridor
        XCTAssertNil(ProfileLogic.legacy(places: places(home: GeoPoint(lat: 51.4416, lon: 5.4697), school: buas)).corridor)
    }

    func test_corridorEdges() {
        XCTAssertEqual(ProfileLogic.corridor(home: veghel, school: buas), .veghelBreda)
        XCTAssertEqual(ProfileLogic.corridor(home: north(veghel, 5990), school: buas), .veghelBreda)
        XCTAssertNil(ProfileLogic.corridor(home: north(veghel, 6010), school: buas))
        XCTAssertEqual(ProfileLogic.corridor(home: veghel, school: north(buas, 395)), .veghelBreda)
        XCTAssertNil(ProfileLogic.corridor(home: veghel, school: north(buas, 405)))
    }

    func test_savedProfileWins() {
        var p = ProfileLogic.fresh
        p.schoolCatalogId = "fontys"; p.campus = "Eindhoven"
        p.schedule = .manual(ManualWeek(days: [.init(weekday: 2, minutes: 510)]))
        let back = ProfileLogic.load(data: ProfileLogic.encode(p), existing: true)
        XCTAssertEqual(back, p)
        XCTAssertFalse(back.setupDone)
    }

    func test_legacyProfileRoundTrips() {
        let p = ProfileLogic.legacy(places: nil)
        XCTAssertEqual(ProfileLogic.decode(ProfileLogic.encode(p)), p)
    }

    func test_unreadableDataIsLikeNone() {
        XCTAssertNil(ProfileLogic.decode(Data("not json".utf8)))
        XCTAssertTrue(ProfileLogic.load(data: Data("[1,2]".utf8), existing: true).setupDone)
    }

    /// Postel: an unknown schedule is "not set up", a missing or unknown corridor is none, missing fields have defaults.
    func test_lenientDecoding() {
        let a = ProfileLogic.decode(Data(#"{"version":3,"setupDone":false,"schedule":{"kind":"ical"},"corridor":"mars"}"#.utf8))
        XCTAssertEqual(a?.schedule, ScheduleSource.none)
        XCTAssertNil(a?.corridor)
        XCTAssertEqual(a?.version, 3)
        XCTAssertEqual(a?.setupDone, false)
        let b = ProfileLogic.decode(Data("{}".utf8))
        XCTAssertNil(b?.corridor)
        XCTAssertEqual(b?.schedule, ScheduleSource.none)
        XCTAssertEqual(b?.calendarHints, [])
        XCTAssertEqual(b?.setupDone, true)
        let c = ProfileLogic.decode(Data(#"{"corridor":"veghelBreda","schedule":{"kind":"manual","week":"nope"}}"#.utf8))
        XCTAssertEqual(c?.corridor, .veghelBreda)
        XCTAssertEqual(c?.schedule, ScheduleSource.none)
    }

    func test_manualWeekKeepsSensibleDays() {
        let w = ManualWeek(days: [.init(weekday: 2, minutes: 510), .init(weekday: 9, minutes: 500), .init(weekday: 3, minutes: 2000),
                                  .init(weekday: 2, minutes: 540), .init(weekday: 1, minutes: 600)])
        XCTAssertEqual(w.days.map(\.weekday), [1, 2])
        XCTAssertEqual(w.minutes(weekday: 2), 540)
        XCTAssertNil(w.minutes(weekday: 3))
        let back = try? JSONDecoder().decode(ManualWeek.self, from: JSONEncoder().encode(w))
        XCTAssertEqual(back, w)
    }
}
