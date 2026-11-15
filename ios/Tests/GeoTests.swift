import XCTest

final class GeoTests: XCTestCase {
    func test_metres() {
        XCTAssertEqual(Geo.metres(Fx.east(0), Fx.east(6900)), 6900, accuracy: 10)
    }

    func test_projectMiddle() throws {
        let p = try XCTUnwrap(Geo.project(Fx.east(500, north: 50), on: [Fx.east(0), Fx.east(1000)]))
        XCTAssertEqual(p.crossTrack, 50, accuracy: 1)
        XCTAssertEqual(p.along, 500, accuracy: 2)
        XCTAssertEqual(p.fraction, 0.5, accuracy: 0.01)
        XCTAssertEqual(p.bearing, 90, accuracy: 0.5)
    }

    func test_projectBeyondEnd() throws {
        let p = try XCTUnwrap(Geo.project(Fx.east(1100), on: [Fx.east(0), Fx.east(1000)]))
        XCTAssertEqual(p.along, 1000, accuracy: 1)
        XCTAssertEqual(p.fraction, 1)
        XCTAssertEqual(p.crossTrack, 100, accuracy: 1)
    }

    func test_degenerate() {
        XCTAssertNil(Geo.project(Fx.east(10), on: [Fx.east(0)]))
        XCTAssertNil(Geo.project(Fx.east(10), on: [Fx.east(0), Fx.east(0)]))
        XCTAssertNil(Geo.project(Fx.east(10), on: []))
    }

    func test_pointAtMetres() throws {
        let path = [Fx.east(0), Fx.east(1000)]
        let p = try XCTUnwrap(Geo.point(atMetres: 250, on: path))
        XCTAssertEqual(Geo.metres(p, Fx.east(250)), 0, accuracy: 0.5)
        XCTAssertEqual(Geo.point(atMetres: 5000, on: path), Fx.east(1000))
        XCTAssertEqual(Geo.point(atMetres: -10, on: path), Fx.east(0))
        XCTAssertNil(Geo.point(atMetres: 250, on: []))
    }

    func test_bearing() {
        let o = Fx.east(0)
        XCTAssertEqual(Geo.bearing(o, Fx.east(0, north: 100)), 0, accuracy: 0.5)
        XCTAssertEqual(Geo.bearing(o, Fx.east(100)), 90, accuracy: 0.5)
        XCTAssertEqual(Geo.bearing(o, Fx.east(0, north: -100)), 180, accuracy: 0.5)
        XCTAssertEqual(Geo.bearing(o, Fx.east(-100)), 270, accuracy: 0.5)
    }
}
