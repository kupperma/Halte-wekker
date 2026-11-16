import XCTest

final class VehiclePickTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)
    private let on = VehiclePick.Gate(enabled: true, visible: true, active: true, lowPower: false, zoom: 14)

    func test_asksOnlyWhenAllowed() {
        XCTAssertTrue(VehiclePick.mayAsk(on, last: nil, now: now))
        var g = on; g.enabled = false
        XCTAssertFalse(VehiclePick.mayAsk(g, last: nil, now: now), "setting off")
        g = on; g.visible = false
        XCTAssertFalse(VehiclePick.mayAsk(g, last: nil, now: now), "home not on screen")
        g = on; g.active = false
        XCTAssertFalse(VehiclePick.mayAsk(g, last: nil, now: now), "app in the background")
        g = on; g.lowPower = true
        XCTAssertFalse(VehiclePick.mayAsk(g, last: nil, now: now), "Low Power Mode")
        g = on; g.zoom = 12.9
        XCTAssertFalse(VehiclePick.mayAsk(g, last: nil, now: now), "zoomed out past a town")
    }

    func test_atMostEvery15Seconds() {
        XCTAssertFalse(VehiclePick.mayAsk(on, last: now.addingTimeInterval(-14.9), now: now))
        XCTAssertTrue(VehiclePick.mayAsk(on, last: now.addingTimeInterval(-15), now: now))
    }

    func test_shownWhileNotVisibleButNotAsked() {
        var g = on; g.visible = false
        XCTAssertTrue(VehiclePick.shows(g))
        g.zoom = 10
        XCTAssertFalse(VehiclePick.shows(g))
    }

    func test_boxIsCapped() {
        let c = GeoPoint(lat: 51.6, lon: 5.5)
        let small = VehiclePick.box(center: c, latDelta: 0.02, lonDelta: 0.03)
        XCTAssertEqual(small.maxLat - small.minLat, 0.02, accuracy: 1e-9)
        let big = VehiclePick.box(center: c, latDelta: 2, lonDelta: 3)
        XCTAssertEqual(big.maxLat - big.minLat, 2 * VehiclePick.maxHalfLat, accuracy: 1e-9)
        XCTAssertEqual(big.maxLon - big.minLon, 2 * VehiclePick.maxHalfLon, accuracy: 1e-9)
    }

    private struct V { let id: Int; let p: GeoPoint }

    func test_nearestSixtyInTheBox() {
        let c = GeoPoint(lat: 51.6, lon: 5.5)
        var vs: [V] = []
        for i in 0..<100 { vs.append(V(id: i, p: GeoPoint(lat: 51.6 + Double(99 - i) * 0.0002, lon: 5.5))) }
        vs.append(V(id: 999, p: GeoPoint(lat: 52.5, lon: 5.5)))          // far outside
        let box = VehiclePick.box(center: c, latDelta: 0.1, lonDelta: 0.1)
        let picked = VehiclePick.nearest(vs, point: \.p, center: c, box: box)
        XCTAssertEqual(picked.count, 60)
        XCTAssertEqual(picked.first?.id, 99, "nearest first")
        XCTAssertFalse(picked.contains { $0.id == 999 })
        XCTAssertFalse(picked.contains { $0.id == 0 }, "the farthest of the 100 is left out")
        XCTAssertEqual(VehiclePick.nearest([V](), point: \.p, center: c, box: box).count, 0)
    }
}
