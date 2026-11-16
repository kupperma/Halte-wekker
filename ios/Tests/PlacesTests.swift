import XCTest

final class PlacesTests: XCTestCase {
    private let home = SavedPlace(id: "home", name: "Home", kind: .home, lat: 51.61, lon: 5.55, stopIds: ["a", "b"])
    private let school = SavedPlace(id: "school", name: "School", kind: .school, lat: 51.59, lon: 4.79)
    private var seed: [SavedPlace] { PlacesLogic.seed(home: home, school: school) }

    func test_nothingSavedGivesTheSeed() {
        XCTAssertEqual(PlacesLogic.load(nil, seed: seed).map(\.id), ["home", "school"])
        XCTAssertEqual(PlacesLogic.load(Data("not json".utf8), seed: seed).map(\.id), ["home", "school"])
        XCTAssertEqual(PlacesLogic.load(PlacesLogic.encode([]), seed: seed).map(\.id), ["home", "school"])
    }

    func test_seedSetsKinds() {
        let s = PlacesLogic.seed(home: SavedPlace(id: "h", name: "H", kind: .custom, lat: 1, lon: 2),
                                 school: SavedPlace(id: "s", name: "S", kind: .custom, lat: 3, lon: 4))
        XCTAssertEqual(s.map(\.kind), [.home, .school])
    }

    func test_roundTripKeepsOrderAndStops() {
        let pin = SavedPlace(id: "p-1", name: "Gym", kind: .custom, lat: 51.6, lon: 5.5, stopIds: ["x"])
        let back = PlacesLogic.load(PlacesLogic.encode([school, pin, home]), seed: seed)
        XCTAssertEqual(back, [school, pin, home])
    }

    func test_missingHomeComesBackAndDoublesBecomePins() {
        let s2 = SavedPlace(id: "s2", name: "Other school", kind: .school, lat: 1, lon: 1)
        let back = PlacesLogic.load(PlacesLogic.encode([school, s2]), seed: seed)
        XCTAssertEqual(back.map(\.id), ["home", "school", "s2"])
        XCTAssertEqual(back.map(\.kind), [.home, .school, .custom])
    }

    func test_duplicateIdsAndBadNumbersDropped() {
        let dup = SavedPlace(id: "home", name: "Again", kind: .custom, lat: 1, lon: 1)
        let bad = SavedPlace(id: "nan", name: "Bad", kind: .custom, lat: .nan, lon: 1)
        let back = PlacesLogic.load(PlacesLogic.encode([home, school, dup, bad]), seed: seed)
        XCTAssertEqual(back.map(\.id), ["home", "school"])
    }

    /// An unknown kind and a missing stop list still read (an older or newer copy).
    func test_lenientDecoding() {
        let json = #"[{"id":"x","name":"Shop","kind":"weird","lat":1.5,"lon":2.5}]"#
        let list = PlacesLogic.decode(Data(json.utf8))
        XCTAssertEqual(list?.first?.kind, .custom)
        XCTAssertEqual(list?.first?.stopIds, [])
    }

    func test_chipsOrder() {
        let a = SavedPlace(id: "a", name: "A", kind: .custom, lat: 0, lon: 0)
        let b = SavedPlace(id: "b", name: "B", kind: .custom, lat: 0, lon: 0)
        XCTAssertEqual(PlacesLogic.chips([home, school, a, b]).map(\.id), ["home", "school", "a", "b"])
        // moved in Settings: the chips follow
        XCTAssertEqual(PlacesLogic.chips([a, school, b, home]).map(\.id), ["a", "school", "b", "home"])
        XCTAssertEqual(PlacesLogic.chips([home, school, a, b], max: 3).map(\.id), ["home", "school", "a"])
    }

    func test_chipLabelAndMinutes() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(PlacesLogic.minutesNow(arrival: now.addingTimeInterval(44 * 60 + 10), now: now), 44)
        XCTAssertNil(PlacesLogic.minutesNow(arrival: now.addingTimeInterval(-60), now: now))
        XCTAssertNil(PlacesLogic.minutesNow(arrival: nil, now: now))
        XCTAssertEqual(PlacesLogic.chipLabel("Home", minutes: 44), "Home · 44 min")
        XCTAssertEqual(PlacesLogic.chipLabel("BUas", minutes: 65), "BUas · 1 h 05")
        XCTAssertEqual(PlacesLogic.chipLabel("Gym", minutes: nil), "Gym")
    }

    func test_newIdMoveRemove() {
        let a = SavedPlace(id: "p-x", name: "A", kind: .custom, lat: 0, lon: 0)
        let list = [home, school, a]
        XCTAssertEqual(PlacesLogic.newId(list, seed: "x"), "p-x-1")
        XCTAssertEqual(PlacesLogic.newId(list, seed: "y"), "p-y")
        XCTAssertEqual(PlacesLogic.move(list, from: 2, to: 0).map(\.id), ["p-x", "home", "school"])
        XCTAssertEqual(PlacesLogic.move(list, from: 0, to: 3).map(\.id), ["school", "p-x", "home"])
        XCTAssertEqual(PlacesLogic.move(list, from: 9, to: 0).map(\.id), ["home", "school", "p-x"])
        XCTAssertEqual(PlacesLogic.remove(list, id: "p-x").map(\.id), ["home", "school"])
        XCTAssertEqual(PlacesLogic.remove(list, id: "home").map(\.id), ["home", "school", "p-x"])
    }
}
