import XCTest
@testable import replay

/// The replay on the made-up fixture (fixtures/synthetic.json, from make-fixture.mjs): it finds the legs, the vehicle
/// you were on, what the app showed, and runs the matcher.
final class ReplayTests: XCTestCase {
    private func fixture() throws -> Export {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../fixtures/synthetic.json")
        return try Export.read(Data(contentsOf: url))
    }

    func test_theFixturesLegsAndTruth() throws {
        let e = try fixture()
        let legs = Rides.legs(e)
        XCTAssertEqual(legs.map(\.leg), ["1/2", "2/2"])
        XCTAssertEqual(legs[0].truth, "305·7821")
        XCTAssertEqual(legs[0].truthFrom, "hand pick")
        XCTAssertEqual(legs[1].truth, "400·1111")
        XCTAssertEqual(legs[1].truthFrom, "ended on")
        // the lines' own clock is the phone's (UTC+1): they line up with the points
        XCTAssertTrue(legs[0].lines.contains { $0.text.hasPrefix("hand pick") })
        XCTAssertTrue(legs[1].lines.contains { $0.text.hasPrefix("start · next leg") })
    }

    func test_whatTheAppShowedIsScored() throws {
        let legs = Rides.legs(try fixture())
        let s = Score.of(Replayer.logged(legs[0]), truth: legs[0].truth, start: legs[0].start)
        XCTAssertEqual(s.flips, 1, "306 first, then 305 by hand")
        XCTAssertNotNil(s.settle)
        XCTAssertGreaterThan(s.settle!, 60)
        XCTAssertLessThan(s.onTruth, 1)
        let s2 = Score.of(Replayer.logged(legs[1]), truth: legs[1].truth, start: legs[1].start)
        XCTAssertEqual(s2.flips, 0)
        XCTAssertEqual(s2.settle, 0)
    }

    func test_theMatcherSettlesOnTheOneYouWereOn() throws {
        let e = try fixture()
        let tracks = e.tracks.map(\.track)
        for leg in Rides.legs(e) {
            let timeline = Replayer.replay(leg, tracks: tracks)
            let s = Score.of(timeline, truth: leg.truth, start: leg.start)
            XCTAssertEqual(s.endedOn, leg.truth, leg.leg)
            XCTAssertEqual(s.flips, 0, leg.leg)
            XCTAssertNotNil(s.settle, leg.leg)
            XCTAssertLessThanOrEqual(s.settle ?? .infinity, 60, leg.leg)
        }
    }

    func test_scoring() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func tl(_ keys: [String?]) -> [Shown] { keys.enumerated().map { Shown(at: t0 + Double($0.offset) * 10, key: $0.element) } }
        var s = Score.of(tl([nil, "a", "b", "b"]), truth: "b", start: t0)
        XCTAssertEqual(s.settle, 20)
        XCTAssertEqual(s.flips, 1)
        XCTAssertEqual(s.onTruth, 0.5)
        XCTAssertEqual(s.firstShown, 10)
        s = Score.of(tl(["b", "a"]), truth: "b", start: t0)
        XCTAssertNil(s.settle, "it didn't end on it")
        s = Score.of(tl(["a", nil, "a"]), truth: "a", start: t0)
        XCTAssertEqual(s.flips, 0, "nothing shown for a moment isn't a flip")
        XCTAssertEqual(s.settle, 20)
        let sum = Summary.of([Score.of(tl(["a"]), truth: "a", start: t0), Score.of(tl(["b"]), truth: "a", start: t0)], truths: 2)
        XCTAssertEqual(sum.settled, 1)
        XCTAssertEqual(sum.medianSettle, 0)
    }

    func test_linesAndKeys() {
        XCTAssertEqual(vehicleKey("bus 305·7821"), "305·7821")
        XCTAssertEqual(vehicleKey("train IC·a1b2"), "IC·a1b2")
        XCTAssertNil(vehicleKey(nil))
        XCTAssertEqual(Rides.handPicked("hand pick · bus 306·4942 (was 305·4779) · 120 m · gps"), "306·4942")
        XCTAssertNil(Rides.handPicked("hand pick · none of these: by your location (was 305·4779)"))
        XCTAssertNil(Rides.handPicked("hand pick · still on bus 306·4942: yes"))
        let l = LogLine.parse("2026-11-19 07:33:58 ride start · x", tz: 3600)
        XCTAssertEqual(l?.kind, "ride")
        XCTAssertEqual(l?.text, "start · x")
        XCTAssertEqual(l?.at.timeIntervalSince1970, 1_795_073_638 - 3600, "07:33:58 at UTC+1 is 06:33:58 UTC")
    }

    func test_thePolylineAsTheAppDecodesIt() {
        // Google's example polyline
        let p = Fetch.polyline("_p~iF~ps|U_ulLnnqC_mqNvxq`@")
        XCTAssertEqual(p.count, 3)
        XCTAssertEqual(p[0].lat, 38.5, accuracy: 1e-9)
        XCTAssertEqual(p[0].lon, -120.2, accuracy: 1e-9)
        XCTAssertEqual(p[2].lat, 43.252, accuracy: 1e-9)
    }
}
