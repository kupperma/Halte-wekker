import XCTest

final class VehicleKindTests: XCTestCase {
    // MARK: by line, on a train

    func test_intercityLines() {
        for l in ["IC", "ICE", "ICD", "ICNG", "Intercity", "Intercity direct", "EuroCity", "EC", "Eurostar", "ICE International", "ic"] {
            XCTAssertEqual(VehicleKind.of(mode: "RAIL", line: l, isTrain: true), .ic, l)
        }
    }

    func test_sprinterLines() {
        for l in ["SPR", "Sprinter", "stoptrein", "Stop", "spr"] {
            XCTAssertEqual(VehicleKind.of(mode: "RAIL", line: l, isTrain: true), .sprinter, l)
        }
    }

    func test_unknownTrain_isTrain() {
        XCTAssertEqual(VehicleKind.of(mode: "RAIL", line: "", isTrain: true), .train)
        XCTAssertEqual(VehicleKind.of(mode: "REGIONAL_RAIL", line: "RS 18", isTrain: true), .train)
        XCTAssertEqual(VehicleKind.of(mode: "", line: "", isTrain: true), .train)
    }

    // MARK: by mode

    func test_modes() {
        XCTAssertEqual(VehicleKind.of(mode: "BUS", line: "306", isTrain: false), .bus)
        XCTAssertEqual(VehicleKind.of(mode: "COACH", line: "", isTrain: false), .bus)
        XCTAssertEqual(VehicleKind.of(mode: "TRAM", line: "1", isTrain: true), .tram)
        XCTAssertEqual(VehicleKind.of(mode: "SUBWAY", line: "E", isTrain: true), .metro)
        XCTAssertEqual(VehicleKind.of(mode: "METRO", line: "52", isTrain: true), .metro)
        XCTAssertEqual(VehicleKind.of(mode: "", line: "306", isTrain: false), .bus, "no mode: by isTrain")
    }

    func test_busModeWins_overATrainLikeLine() {
        XCTAssertEqual(VehicleKind.of(mode: "BUS", line: "IC", isTrain: false), .bus)
    }

    // MARK: stored in the state

    func test_stored_emptyOrUnknown_fallsBackOnIsTrain() {
        XCTAssertEqual(VehicleKind.stored("", isTrain: true), .train)
        XCTAssertEqual(VehicleKind.stored("", isTrain: false), .bus)
        XCTAssertEqual(VehicleKind.stored("hovercraft", isTrain: false), .bus)
        for k in VehicleKind.allCases { XCTAssertEqual(VehicleKind.stored(k.rawValue, isTrain: false), k) }
    }

    func test_rawValues() {
        XCTAssertEqual(VehicleKind.allCases.map(\.rawValue), ["bus", "ic", "sprinter", "tram", "metro", "train"])
    }

    // MARK: the pill

    func test_pillText() {
        XCTAssertEqual(VehicleKind.pillText(line: "5", kind: .bus), "5")
        XCTAssertEqual(VehicleKind.pillText(line: "306", kind: .bus), "306")
        XCTAssertEqual(VehicleKind.pillText(line: "", kind: .bus), "Bus")
        XCTAssertEqual(VehicleKind.pillText(line: "IC", kind: .ic), "IC")
        XCTAssertEqual(VehicleKind.pillText(line: "ICD", kind: .ic), "ICD")
        XCTAssertEqual(VehicleKind.pillText(line: "Intercity", kind: .ic), "IC")
        XCTAssertEqual(VehicleKind.pillText(line: "Euro", kind: .ic), "IC")
        XCTAssertEqual(VehicleKind.pillText(line: "SPR", kind: .sprinter), "SPR")
        XCTAssertEqual(VehicleKind.pillText(line: "stop", kind: .sprinter), "SPR")
        XCTAssertEqual(VehicleKind.pillText(line: "", kind: .train), "Train")
    }

    // MARK: the Live Activity's state

    func test_state_withoutTheNewerFields_stillDecodes() throws {
        let json = """
        {"legTitle":"Intercity to Breda","isTrain":true,"distanceText":"9.6 km","finalName":"Breda","awake":false,
         "goingHome":false,"kicker":"NOW RIDING","stopName":"Breda","progress":0.4,"songPlaying":false}
        """
        let s = try JSONDecoder().decode(TripAttributes.ContentState.self, from: Data(json.utf8))
        XCTAssertEqual(s.vehicle, "")
        XCTAssertEqual(s.line, "")
        XCTAssertEqual(s.stops, [])
        XCTAssertFalse(s.ringing)
        XCTAssertEqual(s.kind, .train)
    }

    func test_state_roundTrips() throws {
        let s = TripAttributes.ContentState(
            legTitle: "Bus 5 to Breda", isTrain: false, distanceText: "2.1 km", arrival: Date(timeIntervalSince1970: 4_000_000),
            finalName: "BUas", nextText: "Then bus 5 at 16:27", awake: true, goingHome: false, kicker: "WAKE UP",
            stopName: "Breda", progress: 0.8, legFrom: nil, legTo: Date(timeIntervalSince1970: 3_999_000), song: "A song",
            artist: nil, songPlaying: true, musicApp: "Spotify", stops: [0.2, 0.5], ringing: true, vehicle: "bus", line: "5")
        let back = try JSONDecoder().decode(TripAttributes.ContentState.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        XCTAssertEqual(back.kind, .bus)
    }
}
