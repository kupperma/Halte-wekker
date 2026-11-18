import XCTest

final class RoleMoveTests: XCTestCase {
    private let home = SavedPlace(id: "home", name: "Home", kind: .home, lat: 51.6137, lon: 5.5474, stopIds: ["a"])
    private let school = SavedPlace(id: "school", name: "BUas", kind: .school, lat: 51.5907, lon: 4.7932)
    private func north(_ s: SavedPlace, _ m: Double) -> SavedPlace { var p = s; p.lat += m / 110_540; return p }

    func test_underFourHundredMetresNothingMoves() {
        XCTAssertEqual(RoleMove.moves(from: [home, school], to: [north(home, 390), north(school, 100)]), [])
        XCTAssertEqual(RoleMove.moves(from: [home, school], to: [home, school]), [])
        var renamed = home; renamed.name = "Thuis"; renamed.stopIds = ["b"]
        XCTAssertEqual(RoleMove.moves(from: [home, school], to: [renamed, school]), [])
    }

    func test_whichRoleMoved() {
        XCTAssertEqual(RoleMove.moves(from: [home, school], to: [north(home, 410), school]), [.home])
        XCTAssertEqual(RoleMove.moves(from: [home, school], to: [home, north(school, 5000)]), [.school])
        XCTAssertEqual(RoleMove.moves(from: [home, school], to: [north(home, 1000), north(school, 1000)]), [.home, .school])
        // a pinned place moving is no role's move; a role missing on one side isn't one either
        let pin = SavedPlace(id: "p", name: "Gym", kind: .custom, lat: 51, lon: 5)
        XCTAssertEqual(RoleMove.moves(from: [home, school, pin], to: [home, school, north(pin, 9000)]), [])
        XCTAssertEqual(RoleMove.moves(from: [school], to: [north(home, 9000), school]), [])
    }

    func test_keysToClear() {
        let km = ["bus:veghel": 2.5, "train:veghel": 4, "bus:buas": 1, "bus:ht": 3, "train:bd": 6, "bus:s:x|1,2": 1]
        XCTAssertEqual(RoleMove.keepKm(km, clearing: [.home]), ["bus:buas": 1, "bus:ht": 3, "train:bd": 6, "bus:s:x|1,2": 1])
        XCTAssertEqual(RoleMove.keepKm(km, clearing: [.school]), ["bus:veghel": 2.5, "train:veghel": 4, "bus:ht": 3, "train:bd": 6, "bus:s:x|1,2": 1])
        XCTAssertEqual(RoleMove.keepKm(km, clearing: []), km)
        let modes = ["veghel": "train", "buas": "bus", "ht": "bus"]
        XCTAssertEqual(RoleMove.keepModes(modes, clearing: [.home]), ["buas": "bus", "ht": "bus"])
        XCTAssertEqual(RoleMove.keepModes(modes, clearing: [.home, .school]), ["ht": "bus"])
        XCTAssertEqual(RoleMove.defaultsKeys(clearing: [.home]), ["school.homeLat", "school.homeLon"])
        XCTAssertEqual(RoleMove.defaultsKeys(clearing: [.school]), [])
    }
}
