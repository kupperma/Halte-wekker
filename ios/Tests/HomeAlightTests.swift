import XCTest

/// 0.42.13: off at your own home stop, named in full (the same vectors as Android's `HomeAlightTest`).
final class HomeAlightTests: XCTestCase {
    private let base: Double = 1_795_737_600
    private func hm(_ h: Double, _ m: Double) -> Date { Date(timeIntervalSince1970: base + (h * 60 + m) * 60) }
    // the 306 into Veghel: Den Bosch (got on), Veghel Rembrandtlaan (the planner's, 16:03), Veghel Busstation (16:07)
    private var calls: [HomeAlight.Call] {
        [HomeAlight.Call(id: "dbs", name: "'s-Hertogenbosch, Centraal Station", point: GeoPoint(lat: 51.69, lon: 5.29), arrival: hm(15, 35)),
         HomeAlight.Call(id: "rem", name: "Veghel, Rembrandtlaan", point: GeoPoint(lat: 51.620, lon: 5.530), arrival: hm(16, 3)),
         HomeAlight.Call(id: "bus", name: "Veghel, Busstation", point: GeoPoint(lat: 51.6160, lon: 5.5440), arrival: hm(16, 7)),
         HomeAlight.Call(id: "far", name: "Uden, Busstation", point: GeoPoint(lat: 51.66, lon: 5.62), arrival: hm(16, 25))]
    }
    private let home = GeoPoint(lat: 51.6150, lon: 5.5450)

    func test_fullName() {
        XCTAssertEqual(HomeAlight.fullName(" Veghel, Busstation "), "Veghel, Busstation")
    }

    func test_offAtYourOwnStop() {
        let own = [HomeAlight.Own(id: "bus", point: nil)]
        XCTAssertEqual(HomeAlight.pick(calls: calls, from: 0, plannerTo: 1, own: own, place: home, speed: 1.35), 2)
        // by where it is (another id for the same stop)
        let near = [HomeAlight.Own(id: "x", point: GeoPoint(lat: 51.6162, lon: 5.5441))]
        XCTAssertEqual(HomeAlight.pick(calls: calls, from: 0, plannerTo: 1, own: near, place: home, speed: 1.35), 2)
    }

    func test_keepsThePlannersWhenItIsYoursOrNoneIsCalledAt() {
        XCTAssertNil(HomeAlight.pick(calls: calls, from: 0, plannerTo: 2, own: [HomeAlight.Own(id: "bus", point: nil)], place: home, speed: 1.35))
        XCTAssertNil(HomeAlight.pick(calls: calls, from: 0, plannerTo: 1, own: [HomeAlight.Own(id: "nope", point: nil)], place: home, speed: 1.35))
        XCTAssertNil(HomeAlight.pick(calls: calls, from: 0, plannerTo: 1, own: [], place: home, speed: 1.35))
        // a stop before you got on doesn't count
        XCTAssertNil(HomeAlight.pick(calls: calls, from: 2, plannerTo: 3, own: [HomeAlight.Own(id: "bus", point: nil)], place: home, speed: 1.35))
    }

    func test_theOneWithTheShortestWalk() {
        let both = [HomeAlight.Own(id: "rem", point: nil), HomeAlight.Own(id: "bus", point: nil)]
        XCTAssertEqual(HomeAlight.pick(calls: calls, from: 0, plannerTo: 3, own: both, place: home, speed: 1.35), 2)
        XCTAssertEqual(HomeAlight.walkMinutes(calls[2].point, home, speed: 1.35), 3)
    }

    func test_indexOfTheRidesStops() {
        XCTAssertEqual(HomeAlight.index(of: "dbs", point: nil, in: calls), 0)
        XCTAssertEqual(HomeAlight.index(of: "", point: GeoPoint(lat: 51.6201, lon: 5.5301), in: calls, after: 0), 1)
        XCTAssertNil(HomeAlight.index(of: "", point: GeoPoint(lat: 52.0, lon: 5.0), in: calls))
    }
}
