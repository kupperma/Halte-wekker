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

    // MARK: 0.34

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// Points every 2 s east along latitude 51.59 at `speed` m/s for `seconds`, from `m0` metres, starting `at` s.
    private func points(from m0: Double, speed: Double, seconds: Int, at: Double = 0, veh: String = "train IC·3624") -> [ExportFix] {
        stride(from: 0, through: seconds, by: 2).map { s in
            let m = m0 + speed * Double(s)
            return ExportFix(t: t0.timeIntervalSince1970 + at + Double(s), lat: 51.59, lon: 4.70 + m / (111_320 * cos(51.59 * .pi / 180)),
                             acc: 10, spd: speed, crs: 90, leg: "1/1", veh: veh, ride: "r")
        }
    }

    private func east(_ m: Double) -> GeoPoint { GeoPoint(lat: 51.59, lon: 4.70 + m / (111_320 * cos(51.59 * .pi / 180))) }

    func test_reckoningOverAGap() {
        // 30 m/s with a 40 s gap (a tunnel): reckoned at the same pace, it's right where the points come back
        let pts = points(from: 0, speed: 30, seconds: 60) + points(from: 30 * 100, speed: 30, seconds: 60, at: 100)
        let leg = ReplayLeg(install: "x", ride: "r", leg: "1/1", fixes: pts, lines: [], truth: "IC·3624", truthFrom: "given")
        let r = ReckonReplay.of(leg)
        XCTAssertEqual(r.gaps, 1)
        XCTAssertLessThan(r.worst ?? .infinity, 30)
        XCTAssertTrue(ReckonReplay.words(r).contains("1 gap"))
        let none = ReckonReplay.of(ReplayLeg(install: "x", ride: "r", leg: "1/1", fixes: points(from: 0, speed: 30, seconds: 60),
                                             lines: [], truth: nil, truthFrom: "given"))
        XCTAssertEqual(none.gaps, 0)
    }

    /// The Intercity through a station at speed, where the Sprinter calls: the Sprinter is out, the Intercity isn't.
    func test_stoppingPatternOnATrainLeg() {
        let pts = points(from: 0, speed: 30, seconds: 200)          // 0 → 6000 m without stopping
        let leg = ReplayLeg(install: "x", ride: "r", leg: "1/1", fixes: pts, lines: [], truth: "IC·3624", truthFrom: "given")
        let start = t0
        func piece(_ a: Double, _ b: Double, _ ta: Double, _ tb: Double) -> TimedPiece {
            TimedPiece(departure: start.addingTimeInterval(ta), arrival: start.addingTimeInterval(tb), path: [east(a), east((a + b) / 2), east(b)])
        }
        let ic = VehicleTrack(tripId: "20261119_x_3624", line: "IC", isTrain: true, realTime: true, pieces: [piece(-1000, 7000, -30, 240)])
        let spr = VehicleTrack(tripId: "20261119_x_6628", line: "SPR", isTrain: true, realTime: true,
                               pieces: [piece(-1000, 3000, -30, 110), piece(3000, 7000, 140, 280)])
        let t = try? XCTUnwrap(TrainReplay.of(leg, tracks: [ic, spr]))
        XCTAssertEqual(t?.through, 1, "through the Sprinter's station at 3000 m")
        XCTAssertEqual(t?.ruledOut, [FieldFormat.label(spr.tripId, [spr.tripId: "SPR"])])
        XCTAssertEqual(t?.truthRuledOut, false)
        XCTAssertNil(TrainReplay.of(ReplayLeg(install: "x", ride: "r", leg: "1/1", fixes: points(from: 0, speed: 10, seconds: 60, veh: "bus 305·1"),
                                              lines: [], truth: nil, truthFrom: "given"), tracks: [ic]), "a bus leg")
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

/// 0.33: when the wake rules would have rung on a leg, from its GPS points.
final class WakeReplayTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// A straight ride east at `speed` m/s for `minutes`, a point every 5 s.
    private func leg(train: Bool, speed: Double, minutes: Double, lines: [LogLine] = []) -> ReplayLeg {
        let n = Int(minutes * 60 / 5)
        let fixes = (0...n).map { i -> ExportFix in
            let east = Double(i) * 5 * speed
            return ExportFix(t: t0.timeIntervalSince1970 + Double(i) * 5, lat: 51.5, lon: 5.0 + east / (cos(51.5 * .pi / 180) * 111_320),
                             acc: 8, spd: speed, crs: 90, leg: "1/1", veh: train ? "train IC·a1b2" : "bus 305·7821", ride: "r1")
        }
        return ReplayLeg(install: "i", ride: "r1", leg: "1/1", fixes: fixes, lines: lines, truth: nil, truthFrom: "none")
    }

    func test_aFastTrainRingsByTimeFirst() {
        // 30 m/s: the 5 km wake point is 167 s from the end, 3 minutes is 180 s
        let w = WakeReplay.of(leg(train: true, speed: 30, minutes: 12))
        XCTAssertTrue(w.isTrain)
        XCTAssertEqual(w.byDistance ?? 0, 165, accuracy: 5)
        XCTAssertEqual(w.byTime ?? 0, 180, accuracy: 5)
        XCTAssertEqual(w.first ?? 0, 180, accuracy: 5)
    }

    func test_aSlowBusRingsByDistanceFirst() {
        // 10 m/s: the 2 km wake point is 200 s from the end, 2 minutes is 120 s
        let w = WakeReplay.of(leg(train: false, speed: 10, minutes: 10))
        XCTAssertFalse(w.isTrain)
        XCTAssertEqual(w.byDistance ?? 0, 200, accuracy: 5)
        XCTAssertEqual(w.byTime ?? 0, 120, accuracy: 5)
        XCTAssertEqual(w.first ?? 0, 200, accuracy: 5)
    }

    func test_theAppsRingLine() {
        let ring = LogLine(at: t0.addingTimeInterval(9 * 60), kind: "ride", text: "ring · by time 3 min (live) · 5400 m · leg 540 s old · started 21600 m")
        let w = WakeReplay.of(leg(train: true, speed: 30, minutes: 12, lines: [ring]))
        XCTAssertEqual(w.logged ?? 0, 180, accuracy: 0.5)
        XCTAssertEqual(w.loggedWhy, "by time 3 min (live)")
        XCTAssertTrue(WakeReplay.words(w).contains("the app rang 3.0 min before (by time 3 min (live))"))
    }
}
