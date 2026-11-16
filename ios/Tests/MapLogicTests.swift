import XCTest

final class MapLogicTests: XCTestCase {
    func test_zoomLevel() {
        // a phone's width of streets (about 1.7 km) is zoom 15, a town (7 km) 13
        XCTAssertEqual(MapZoom.level(lonDelta: 0.01714), 15, accuracy: 0.05)
        XCTAssertEqual(MapZoom.level(lonDelta: 0.06857), 13, accuracy: 0.05)
        XCTAssertEqual(MapZoom.level(lonDelta: 0), 20)
    }

    func test_tileRoundTrip() {
        let t = StopTiles.tile(lat: 51.6137, lon: 5.5474)
        let c = StopTiles.center(t)
        XCTAssertEqual(StopTiles.tile(lat: c.lat, lon: c.lon), t)
        XCTAssertLessThan(abs(c.lat - 51.6137), StopTiles.latSize)
        XCTAssertLessThan(abs(c.lon - 5.5474), StopTiles.lonSize)
        // west of Greenwich and south of the equator still floor
        XCTAssertEqual(StopTiles.tile(lat: -0.001, lon: -0.001), StopTile(x: -1, y: -1))
    }

    func test_coveringNearestFirstAndLimited() {
        let all = StopTiles.covering(minLat: 51.58, minLon: 5.50, maxLat: 51.64, maxLon: 5.60, limit: 100)
        XCTAssertEqual(Set(all).count, all.count)
        XCTAssertGreaterThan(all.count, 4)
        let mid = StopTiles.tile(lat: 51.61, lon: 5.55)
        XCTAssertEqual(all.first, mid)
        XCTAssertEqual(StopTiles.covering(minLat: 51.58, minLon: 5.50, maxLat: 51.64, maxLon: 5.60, limit: 3).count, 3)
        XCTAssertEqual(StopTiles.covering(minLat: 2, minLon: 0, maxLat: 1, maxLon: 1), [])
        XCTAssertEqual(StopTiles.covering(minLat: 40, minLon: 0, maxLat: 60, maxLon: 20), [], "a whole country: nothing")
    }

    func test_dueAndMayLook() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let a = StopTile(x: 1, y: 1), b = StopTile(x: 2, y: 1), c = StopTile(x: 3, y: 1)
        let asked = [a: now.addingTimeInterval(-60), b: now.addingTimeInterval(-StopTiles.ttl - 1)]
        XCTAssertEqual(StopTiles.due([a, b, c], asked: asked, now: now), [b, c])
        XCTAssertTrue(StopTiles.mayLook(zoom: 15, visible: true, last: nil, now: now))
        XCTAssertFalse(StopTiles.mayLook(zoom: 15, visible: false, last: nil, now: now))
        XCTAssertFalse(StopTiles.mayLook(zoom: 12.9, visible: true, last: nil, now: now))
        XCTAssertFalse(StopTiles.mayLook(zoom: 15, visible: true, last: now.addingTimeInterval(-19), now: now))
        XCTAssertTrue(StopTiles.mayLook(zoom: 15, visible: true, last: now.addingTimeInterval(-20), now: now))
    }

    private struct S { let id: String; let p: GeoPoint; let rail: Bool }

    func test_stopsDrawnByZoom() {
        let c = GeoPoint(lat: 51.6, lon: 5.5)
        var stops = [S(id: "st", p: GeoPoint(lat: 51.7, lon: 5.5), rail: true)]
        for i in 0..<100 { stops.append(S(id: "b\(i)", p: GeoPoint(lat: 51.6 + Double(i) * 0.0005, lon: 5.5), rail: false)) }
        let far = MapStopsDraw.pick(stops, id: \.id, point: \.p, rail: \.rail, center: c, zoom: 10)
        XCTAssertEqual(far.ids, [])
        let town = MapStopsDraw.pick(stops, id: \.id, point: \.p, rail: \.rail, center: c, zoom: 12)
        XCTAssertEqual(town.ids, ["st"])
        XCTAssertFalse(town.names)
        let close = MapStopsDraw.pick(stops, id: \.id, point: \.p, rail: \.rail, center: c, zoom: 14.5)
        XCTAssertEqual(close.ids.count, 1 + MapStopsDraw.maxStops)
        XCTAssertEqual(close.ids[1], "b0", "nearest bus stop first")
        XCTAssertFalse(close.ids.contains("b99"))
        XCTAssertTrue(MapStopsDraw.pick(stops, id: \.id, point: \.p, rail: \.rail, center: c, zoom: 16).names)
    }
}
