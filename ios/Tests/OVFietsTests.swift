import XCTest

/// 0.37: OV-fiets at the station — the relay's answer (as it came on 2026-11-20 for Breda), NS's own, the words, and
/// which station of a trip.
final class OVFietsTests: XCTestCase {
    private let relay = """
    {"station":"BD","locations":[{"name":"BD - OV-fiets - Breda Belcrum","code":"bd002","bikes":193,"lat":51.596338,"lon":4.77892,"open":"No"},
    {"name":"BD - OV-fiets - Breda Centrum","code":"Bd003","bikes":225,"lat":51.59502,"lon":4.779437,"open":"No"}]}
    """

    func test_relayAnswer() throws {
        let a = try XCTUnwrap(OVFiets.parse(Data(relay.utf8), station: "BD"))
        XCTAssertEqual(a.station, "BD")
        XCTAssertEqual(a.points.map(\.code), ["bd002", "Bd003"])
        XCTAssertEqual(a.total, 418)
        XCTAssertEqual(a.closed, true)
        XCTAssertEqual(OVFiets.text(a), "OV-fiets: 418 left · closed now")
    }

    func test_nsOwnAnswer() throws {
        let ns = """
        {"links":{},"payload":[{"type":"stationfacility","name":"OV-fiets","locations":[
          {"name":"Breda Belcrum","stationCode":"BD","lat":51.5,"lng":4.7,"open":"Yes","extra":{"rentalBikes":"12","locationCode":"bd002"}},
          {"name":"Utrecht","stationCode":"UT","lat":52,"lng":5,"extra":{"rentalBikes":"300","locationCode":"ut001"}},
          {"name":"Breda Centrum","stationCode":"BD","lat":51.5,"lng":4.7,"extra":{"locationCode":"bd003"}}]}]}
        """
        let a = try XCTUnwrap(OVFiets.parse(Data(ns.utf8), station: "bd"))
        XCTAssertEqual(a.points.count, 2)
        XCTAssertEqual(a.total, 12)
        XCTAssertEqual(a.closed, false)
        XCTAssertEqual(OVFiets.text(a), "OV-fiets: 12 left")
    }

    func test_words() {
        func ans(_ b: [Int?], open: Bool? = nil) -> OVFiets.Answer {
            OVFiets.Answer(station: "TB", points: b.enumerated().map { OVFiets.Point(name: "p\($0.offset)", code: "c\($0.offset)", bikes: $0.element, open: open) })
        }
        XCTAssertEqual(OVFiets.text(ans([1])), "OV-fiets: 1 left")
        XCTAssertEqual(OVFiets.text(ans([0, 0])), "OV-fiets: none left")
        XCTAssertNil(OVFiets.text(ans([nil])), "no count: no line")
        XCTAssertNil(OVFiets.text(ans([])), "no OV-fiets there")
        XCTAssertTrue(OVFiets.low(ans([3, 2])))
        XCTAssertFalse(OVFiets.low(ans([6])))
        XCTAssertNil(ans([4]).closed)
    }

    func test_badAnswers() {
        XCTAssertNil(OVFiets.parse(Data("nope".utf8), station: "BD"))
        XCTAssertNil(OVFiets.parse(Data("[]".utf8), station: "BD"))
        XCTAssertEqual(OVFiets.parse(Data(#"{"station":"VGL","locations":[]}"#.utf8), station: "VGL")?.total, nil)
        XCTAssertEqual(OVFiets.parse(Data(#"{"locations":[{"bikes":-3},{"bikes":"7"}]}"#.utf8), station: "x")?.total, 7)
    }

    func test_cacheFiveMinutes() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(OVFiets.fresh(t, now: t.addingTimeInterval(299)))
        XCTAssertFalse(OVFiets.fresh(t, now: t.addingTimeInterval(301)))
        XCTAssertFalse(OVFiets.fresh(t, now: t.addingTimeInterval(-120)), "a clock that went back: ask again")
    }

    func test_whichStation() {
        let bus = OVFiets.Ride(train: false, toCode: nil)
        // bus to Den Bosch, train to Breda, then a walk to school: Breda
        XCTAssertEqual(OVFiets.station([bus, .init(train: true, toCode: "BD")], walkAfter: 15), "BD")
        // …ending at the station: none
        XCTAssertNil(OVFiets.station([bus, .init(train: true, toCode: "BD")], walkAfter: 2))
        // the last train's station, with a bus on after it
        XCTAssertEqual(OVFiets.station([.init(train: true, toCode: "HT"), .init(train: true, toCode: "EHV"), bus], walkAfter: 0), "EHV")
        // no train, or a station NS doesn't know
        XCTAssertNil(OVFiets.station([bus, bus], walkAfter: 20))
        XCTAssertNil(OVFiets.station([.init(train: true, toCode: nil)], walkAfter: 20))
    }
}
