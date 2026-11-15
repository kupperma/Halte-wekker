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

    /// Which passes lie beyond the path's ends, by the segment and where on it the foot falls (a repeated end point
    /// doesn't count as a segment).
    func test_passEnds() throws {
        let path = [Fx.east(0), Fx.east(0), Fx.east(500), Fx.east(1000), Fx.east(1000)]
        func at(_ m: Double, north: Double = 0) throws -> Geo.Pass { try XCTUnwrap(Geo.pass(Fx.east(m, north: north), on: path, near: nil, within: 0)) }
        let before = try at(-200)
        XCTAssertTrue(before.beforeStart); XCTAssertFalse(before.beyondEnd)
        XCTAssertEqual(before.projection.along, 0, accuracy: 0.001); XCTAssertEqual(before.projection.crossTrack, 200, accuracy: 1)
        XCTAssertTrue(try at(0, north: 50).beforeStart)                 // beside the start
        let inside = try at(20, north: 50)
        XCTAssertFalse(inside.beforeStart); XCTAssertFalse(inside.beyondEnd)
        XCTAssertFalse(try at(500, north: 30).beforeStart)              // the corner between the two stretches
        XCTAssertFalse(try at(500, north: 30).beyondEnd)
        let beyond = try at(1300)
        XCTAssertTrue(beyond.beyondEnd); XCTAssertFalse(beyond.beforeStart)
        XCTAssertEqual(beyond.projection.along, 1000, accuracy: 1)
        XCTAssertFalse(try at(980, north: 10).beyondEnd)
        // one stretch: before its start and beyond its end
        XCTAssertTrue(try XCTUnwrap(Geo.pass(Fx.east(-5), on: [Fx.east(0), Fx.east(100)], near: nil, within: 0)).beforeStart)
        XCTAssertTrue(try XCTUnwrap(Geo.pass(Fx.east(105), on: [Fx.east(0), Fx.east(100)], near: nil, within: 0)).beyondEnd)
    }

    func test_degenerate() {
        XCTAssertNil(Geo.project(Fx.east(10), on: [Fx.east(0)]))
        XCTAssertNil(Geo.project(Fx.east(10), on: [Fx.east(0), Fx.east(0)]))
        XCTAssertNil(Geo.project(Fx.east(10), on: []))
    }

    /// A path that goes out and comes back along the same road passes a point twice; `pass` picks the one nearest
    /// `near`, and without it the first of the nearest.
    func test_passTwice() throws {
        let path = [Fx.east(0), Fx.east(1000), Fx.east(1000, north: 10), Fx.east(0, north: 10)]
        let p = Fx.east(300, north: 5)
        XCTAssertEqual(Geo.passes(p, on: path).filter { $0.projection.crossTrack < 50 }.count, 2)   // (and the turn, 700 m off)
        let out = try XCTUnwrap(Geo.pass(p, on: path, near: 250, within: 20))
        XCTAssertEqual(out.projection.along, 300, accuracy: 1)
        XCTAssertEqual(out.projection.bearing, 90, accuracy: 0.5)
        let back = try XCTUnwrap(Geo.pass(p, on: path, near: 1800, within: 20))
        XCTAssertEqual(back.projection.along, 1710, accuracy: 1)
        XCTAssertEqual(back.projection.bearing, 270, accuracy: 0.5)
        XCTAssertEqual(Geo.pass(p, on: path, near: nil, within: 20)?.projection.along ?? 0, 300, accuracy: 1)
        // equally near `near`: the one nearest the previous fix's, else the first
        XCTAssertEqual(try XCTUnwrap(Geo.pass(p, on: path, near: 1005, within: 20, previous: 1730)).projection.along, 1710, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(Geo.pass(p, on: path, near: 1005, within: 20, previous: 280)).projection.along, 300, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(Geo.pass(p, on: path, near: 1005, within: 20)).projection.along, 300, accuracy: 1)
        // a pass further than `within` beyond the nearest doesn't count
        let far = Fx.east(300, north: -30)
        XCTAssertEqual(try XCTUnwrap(Geo.pass(far, on: path, near: 1800, within: 5)).projection.along, 300, accuracy: 1)
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
