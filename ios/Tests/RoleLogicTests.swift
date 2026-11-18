import XCTest

final class RoleLogicTests: XCTestCase {
    private let boardIds = ["nl-OpenOV_NL:S:64553000", "nl-OpenOV_4219829"]

    /// Today's seed (0.21 `PlacesStore.seed`): Home at Veghel bus station with the board stops, School at BUas.
    private var seededHome: SavedPlace {
        SavedPlace(id: "home", name: "Home", kind: .home, lat: 51.6137, lon: 5.5474, stopIds: boardIds)
    }
    private var seededSchool: SavedPlace {
        SavedPlace(id: "school", name: "BUas", kind: .school, lat: 51.5907, lon: 4.7932, stopIds: ["51.5907,4.7932"])
    }
    private func inputs(home: SavedPlace? = nil, school: SavedPlace? = nil, board: [String]? = nil,
                        corridor: Corridor? = .veghelBreda) -> RoleInputs {
        RoleInputs(home: home ?? seededHome, school: school ?? seededSchool, boardIds: board ?? boardIds, corridor: corridor,
                   calendarHints: ProfileLogic.legacyHints)
    }
    private func north(_ s: SavedPlace, _ m: Double) -> SavedPlace { var p = s; p.lat += m / 110_540; return p }

    /// The legacy home and school are 0.21's `Place.veghel` and `Place.buas`, field by field.
    func test_legacyHomeAndSchoolAreTodaysPlaces() {
        let r = RoleLogic.roles(inputs())
        XCTAssertTrue(r.homeIsLegacy)
        XCTAssertTrue(r.schoolIsLegacy)
        XCTAssertEqual(r.home.key, "veghel")
        XCTAssertEqual(r.home.name, "Veghel, Busstation")
        XCTAssertEqual(r.home.short, "Veghel")
        XCTAssertEqual(r.home.ids, ["nl-OpenOV_NL:S:64553000", "nl-OpenOV_4219829"])
        XCTAssertEqual(r.home.lat, 51.6137)
        XCTAssertEqual(r.home.lon, 5.5474)
        XCTAssertEqual(r.home.spoken, "Veghel")
        XCTAssertEqual(r.school.key, "buas")
        XCTAssertEqual(r.school.name, "Breda University (BUas)")
        XCTAssertEqual(r.school.short, "BUas")
        XCTAssertEqual(r.school.ids, ["51.5907,4.7932"])
        XCTAssertEqual(r.school.lat, 51.5907)
        XCTAssertEqual(r.school.lon, 4.7932)
        XCTAssertEqual(r.school.spoken, "Breda University")
        XCTAssertEqual(r.words, RoleWords.legacy)
        XCTAssertEqual(r.corridor, .veghelBreda)
    }

    /// Before the stores said anything, and with Home and School renamed or a stop across the road: still today's.
    func test_legacyBeforeTheStoresAndNearby() {
        XCTAssertEqual(RoleLogic.roles(.legacy).home, RoleLogic.legacyHome)
        XCTAssertEqual(RoleLogic.roles(.legacy).school, RoleLogic.legacySchool)
        var h = north(seededHome, 300); h.name = "Thuis"
        var s = north(seededSchool, 390); s.name = "Uni"
        let r = RoleLogic.roles(inputs(home: h, school: s))
        XCTAssertEqual(r.home, RoleLogic.legacyHome)
        XCTAssertEqual(r.school, RoleLogic.legacySchool)
    }

    /// The board's stops replace today's home's ids for trips from home (0.21's `StopsStore.veghel`).
    func test_boardIdsReplaceHomeIds() {
        let r = RoleLogic.roles(inputs(board: ["a", "b", "c"]))
        XCTAssertEqual(r.homeBoard.ids, ["a", "b", "c"])
        XCTAssertEqual(r.homeBoard.key, "veghel")
        XCTAssertEqual(r.homeBoard.name, "Veghel, Busstation")
        XCTAssertEqual(r.homeBoard.short, "Veghel")
        XCTAssertEqual(r.homeBoard.lat, 51.6137)
        XCTAssertEqual(r.homeBoard.lon, 5.5474)
        XCTAssertEqual(r.homeBoard.spoken, "Veghel")
        XCTAssertEqual(r.home.ids, ["nl-OpenOV_NL:S:64553000", "nl-OpenOV_4219829"])
        // no board stops: today's ids
        XCTAssertEqual(RoleLogic.roles(inputs(board: [])).homeBoard.ids, ["nl-OpenOV_NL:S:64553000", "nl-OpenOV_4219829"])
    }

    /// A Home moved 401 m is your own place, still with key "veghel"; its own stops start the trips.
    func test_movedHomeIsBuiltFromThePlace() {
        var h = north(seededHome, 401); h.stopIds = ["stop-x"]
        let r = RoleLogic.roles(inputs(home: h, board: ["a", "b"]))
        XCTAssertFalse(r.homeIsLegacy)
        XCTAssertTrue(r.schoolIsLegacy)
        XCTAssertEqual(r.home, RolePlace(key: "veghel", name: "Home", short: "Home", ids: ["stop-x"], lat: h.lat, lon: h.lon, spoken: "Home"))
        XCTAssertEqual(r.homeBoard, r.home)
    }

    func test_movedSchoolWithoutStopsIsItsSpot() {
        var s = north(seededSchool, 2000); s.name = "Avans"; s.stopIds = []
        let r = RoleLogic.roles(inputs(school: s, corridor: nil))
        XCTAssertEqual(r.school.key, "buas")
        XCTAssertEqual(r.school.ids, ["\(s.lat),\(s.lon)"])
        XCTAssertEqual(r.school.short, "Avans")
        XCTAssertEqual(r.words.school, "Avans")
        XCTAssertFalse(r.words.onCorridor)
    }

    /// Without the corridor nothing is today's place, even right at Veghel.
    func test_noCorridorNoLegacy() {
        let r = RoleLogic.roles(inputs(corridor: nil))
        XCTAssertFalse(r.homeIsLegacy)
        XCTAssertFalse(r.schoolIsLegacy)
        XCTAssertEqual(r.home.name, "Home")
        XCTAssertEqual(r.home.ids, boardIds)
        XCTAssertEqual(r.school.name, "BUas")
    }

    func test_corridorStationsAreTodaysPlaces() {
        XCTAssertEqual(Corridor.veghelBreda.stations.map(\.key), ["ht", "ehv", "bd"])
        XCTAssertEqual(Corridor.veghelBreda.hubs.map(\.key), ["ht", "ehv"])
        XCTAssertEqual(Corridor.denBosch, RolePlace(key: "ht", name: "’s-Hertogenbosch Centraal", short: "Den Bosch",
                                                    ids: ["de-DELFI_000008400319"], lat: 51.6905, lon: 5.2936, spoken: "Den Bosch"))
        XCTAssertEqual(Corridor.eindhoven, RolePlace(key: "ehv", name: "Eindhoven Centraal", short: "Eindhoven",
                                                     ids: ["de-DELFI_000008400206"], lat: 51.4432, lon: 5.4812, spoken: "Eindhoven Central"))
        XCTAssertEqual(Corridor.breda, RolePlace(key: "bd", name: "Breda station", short: "Breda",
                                                 ids: ["nl-OpenOV_stoparea:17911"], lat: 51.5955, lon: 4.7797, spoken: "Breda station"))
    }
}
