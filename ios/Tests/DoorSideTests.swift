import XCTest

/// (0.42.10) Which side you get out: the relay's answer, the line the app shows and how it asks, against
/// docs/door-side-vectors.json (the vectors Android and the relay check too).
final class DoorSideTests: XCTestCase {
    private var v: [String: Any] = [:]

    override func setUpWithError() throws {
        let url = Bundle(for: Self.self).url(forResource: "door-side-vectors", withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../docs/door-side-vectors.json")
        let d = try Data(contentsOf: url)
        v = try XCTUnwrap(JSONSerialization.jsonObject(with: d) as? [String: Any])
    }

    func test_answersAndLines() throws {
        let list = try XCTUnwrap(v["answers"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(list.count, 10)
        for c in list {
            let body: String = c["body"] as? String ?? ""
            let want: String? = c["line"] as? String
            let got: String? = DoorSide.line(DoorSide.parse(body.data(using: .utf8)), track: c["track"] as? String)
            XCTAssertEqual(got, want, body)
        }
        XCTAssertNil(DoorSide.parse(nil))
    }

    func test_query() throws {
        let list = try XCTUnwrap(v["query"] as? [[String: Any]])
        for c in list {
            let f: [Double] = try XCTUnwrap(c["from"] as? [Double])
            let a: [Double] = try XCTUnwrap(c["at"] as? [Double])
            let ask = DoorSide.Ask(station: c["station"] as? String ?? "", track: DoorSide.cleanTrack(c["track"] as? String),
                                   from: GeoPoint(lat: f[0], lon: f[1]), at: GeoPoint(lat: a[0], lon: a[1]))
            XCTAssertEqual(ask.query, c["query"] as? String)
        }
    }

    private func stop(_ lat: Double, _ lon: Double, _ track: String?) -> DoorSide.Stop {
        DoorSide.Stop(point: GeoPoint(lat: lat, lon: lon), track: track)
    }

    func test_whatItAsks() throws {
        let stops: [DoorSide.Stop] = [stop(51.5605, 5.0838, "2"), stop(51.5458, 4.9339, "1"), stop(51.5955, 4.7799, " 4 "),
                                      stop(51.5753, 4.6385, "2")]
        let breda = GeoPoint(lat: 51.5957, lon: 4.7795)
        let a = try XCTUnwrap(DoorSide.ask(train: true, stops: stops, to: breda, code: "bd"))
        XCTAssertEqual(a.station, "BD")
        XCTAssertEqual(a.track, "4")
        XCTAssertEqual(a.query, "station=BD&track=4&from=51.5458,4.9339&at=51.5955,4.7799")
        // a bus, no code, no platform, your stop far from the trip, or first: nothing to ask
        XCTAssertNil(DoorSide.ask(train: false, stops: stops, to: breda, code: "BD"))
        XCTAssertNil(DoorSide.ask(train: true, stops: stops, to: breda, code: nil))
        XCTAssertNil(DoorSide.ask(train: true, stops: stops.map { stop($0.point.lat, $0.point.lon, nil) }, to: breda, code: "BD"))
        XCTAssertNil(DoorSide.ask(train: true, stops: stops, to: GeoPoint(lat: 51.70, lon: 4.90), code: "BD"))
        XCTAssertNil(DoorSide.ask(train: true, stops: stops, to: GeoPoint(lat: 51.5605, lon: 5.0838), code: "TB"))
        // another platform: another question (asked again)
        var moved: [DoorSide.Stop] = stops
        moved[2] = stop(51.5955, 4.7799, "5")
        let b = try XCTUnwrap(DoorSide.ask(train: true, stops: moved, to: breda, code: "BD"))
        XCTAssertNotEqual(a.key, b.key)
    }

    func test_notificationsAndLockScreen() {
        XCTAssertEqual(DoorSide.withLine("Get off at Breda · 2 min", nil), "Get off at Breda · 2 min")
        XCTAssertEqual(DoorSide.withLine("Get off at Breda · 2 min", "Exit on the left"), "Get off at Breda · 2 min\nExit on the left")
        let left = DoorSide.Answer(side: "left", low: false)
        let guess = DoorSide.Answer(side: "both", low: true)
        XCTAssertEqual(DoorSide.lockPlatform("4", left), "4 · exit on the left")
        XCTAssertEqual(DoorSide.lockPlatform("2", guess), "2 · exit on both sides (estimate)")
        XCTAssertEqual(DoorSide.lockPlatform("4", nil), "4")
        XCTAssertNil(DoorSide.lockPlatform(nil, left))
        XCTAssertEqual(LockWords.ride(nextStop: "Vught", delay: 3, platform: DoorSide.lockPlatform("4", left)),
                       "Next: Vught · 3 min late · platform 4 · exit on the left")
    }
}
