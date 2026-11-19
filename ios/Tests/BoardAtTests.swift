import XCTest

/// Where to get on (0.25.1): the 158 to Den Bosch from Veghel, as Transitous has it (bus station 07:13, Bolkenplein
/// 07:14, Wilgenstraat 07:16, Gasthuisstraat 07:18, …, Den Bosch Centraal 08:00).
final class BoardAtTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 4_000_000)          // 07:00
    private func at(_ min: Double) -> Date { t0.addingTimeInterval(min * 60) }

    private let busstation = GeoPoint(lat: 51.613922, lon: 5.547144)
    private let bolkenplein = GeoPoint(lat: 51.617294, lon: 5.546145)
    private let wilgenstraat = GeoPoint(lat: 51.622112, lon: 5.54671)
    private let gasthuisstraat = GeoPoint(lat: 51.62253, lon: 5.541744)
    private let denBosch = GeoPoint(lat: 51.6905, lon: 5.2935)
    /// In town north of the bus station: about 500 m from it, 130 m from Bolkenplein.
    private let inTown = GeoPoint(lat: 51.6185, lon: 5.5458)
    /// At home, next to the bus station.
    private let atHome = GeoPoint(lat: 51.6141, lon: 5.5468)

    private func trip158(bolkenplein bolk: Date? = nil) -> [BoardAt.Stop] {
        [BoardAt.Stop(id: "nl-OpenOV_4219854", name: "Veghel, Busstation", point: busstation, departure: at(13), track: "A", scheduledTrack: "A"),
         BoardAt.Stop(id: "nl-OpenOV_4219829", name: "Veghel, Bolkenplein", point: bolkenplein, departure: bolk ?? at(14)),
         BoardAt.Stop(id: "nl-OpenOV_4219880", name: "Veghel, Wilgenstraat", point: wilgenstraat, departure: at(16)),
         BoardAt.Stop(id: "nl-OpenOV_4219861", name: "Veghel, Gasthuisstraat", point: gasthuisstraat, departure: at(18)),
         BoardAt.Stop(id: "nl-OpenOV_dbcs", name: "'s-Hertogenbosch, Centraal Station", point: denBosch, departure: nil)]
    }

    private func better(_ stops: [BoardAt.Stop], you: GeoPoint, now: Date, fromId: String = "nl-OpenOV_4219854") -> BoardAt.Choice? {
        BoardAt.better(stops, fromId: fromId, from: busstation, departure: at(13), to: denBosch,
                       toName: "'s-Hertogenbosch, Centraal Station", you: you, now: now)
    }

    // MARK: the field case

    func test_inTown_boardsAtBolkenpleinNotTheBusStation() throws {
        // 07:01, walking in town: the 158 at 07:13 from the bus station (9 min walk) also calls at Bolkenplein at 07:14
        let c = try XCTUnwrap(better(trip158(), you: inTown, now: at(1)))
        XCTAssertEqual(c.stop.name, "Veghel, Bolkenplein")
        XCTAssertEqual(c.index, 1)
        XCTAssertEqual(c.walk, 3, "about 130 m")
        XCTAssertLessThan(c.walk, 9)
    }

    func test_atHome_nextToTheBusStation_keepsIt() {
        XCTAssertNil(better(trip158(), you: atHome, now: at(1)), "the bus station is the nearest: it stays")
    }

    func test_closerStopTooLate_keepsTheOneItHad() {
        // 07:11:30: Bolkenplein's 07:14 needs 3 min walk and a minute to spare: 07:15:30, too late
        XCTAssertNil(better(trip158(), you: inTown, now: at(11.5)))
    }

    func test_justInTime_withAMinuteToSpare() {
        // 07:10 + 3 min walk + 1 min = 07:14: still makes it
        XCTAssertEqual(better(trip158(), you: inTown, now: at(10))?.index, 1)
    }

    func test_liveTimes_count() {
        // the bus is running early: at Bolkenplein 07:04 (live): from 07:01 that's 3 min walk plus one: not there;
        // Wilgenstraat further on (still closer than the bus station) is
        XCTAssertEqual(better(trip158(bolkenplein: at(4)), you: inTown, now: at(1))?.index, 2)
        // running late, it makes it again later on
        XCTAssertEqual(better(trip158(bolkenplein: at(20)), you: inTown, now: at(15))?.index, 1)
    }

    func test_neverAStopItHasLeft() {
        var stops = trip158()
        stops[1] = BoardAt.Stop(id: stops[1].id, name: stops[1].name, point: bolkenplein, departure: at(-2))
        XCTAssertEqual(better(stops, you: inTown, now: at(1))?.index, 2, "not Bolkenplein, where it has been")
        stops[2] = BoardAt.Stop(id: stops[2].id, name: stops[2].name, point: wilgenstraat, departure: at(0.5))
        XCTAssertNil(better(stops, you: inTown, now: at(1)))
    }

    func test_notWhereYouCannotGetOn() {
        var stops = trip158()
        stops[1].boarding = false
        XCTAssertEqual(better(stops, you: inTown, now: at(1))?.index, 2, "not Bolkenplein")
        stops[2].boarding = false
        XCTAssertNil(better(stops, you: inTown, now: at(1)))
    }

    func test_theClosestOfThoseYouMake() {
        // right by Wilgenstraat: that one, not Bolkenplein (also closer than the bus station)
        let byWilgen = GeoPoint(lat: 51.6219, lon: 5.5466)
        let c = better(trip158(), you: byWilgen, now: at(1))
        XCTAssertEqual(c?.stop.name, "Veghel, Wilgenstraat")
        XCTAssertEqual(c?.walk, 1)
    }

    func test_neverAtOrAfterWhereYouGetOff() {
        // getting off at Wilgenstraat: Gasthuisstraat (after it) is never a place to get on
        let byGasthuis = GeoPoint(lat: 51.6225, lon: 5.5418)
        let c = BoardAt.better(trip158(), fromId: "nl-OpenOV_4219854", from: busstation, departure: at(13), to: wilgenstraat,
                               toName: "Veghel, Wilgenstraat", you: byGasthuis, now: at(0))
        XCTAssertEqual(c?.index, 1, "Bolkenplein, before it: 12 min walk, in time for 07:14")
        XCTAssertNil(BoardAt.better(trip158(), fromId: "nl-OpenOV_4219854", from: busstation, departure: at(13), to: wilgenstraat,
                                    toName: "Veghel, Wilgenstraat", you: byGasthuis, now: at(3)), "nothing before it in time: the bus station stays")
    }

    func test_anEarlierStopOnTheTrip_whenYouMakeIt() {
        // it had Bolkenplein; you're at the bus station with time: the bus station, its first stop
        let c = BoardAt.better(trip158(), fromId: "nl-OpenOV_4219829", from: bolkenplein, departure: at(14), to: denBosch,
                               toName: "'s-Hertogenbosch, Centraal Station", you: atHome, now: at(1))
        XCTAssertEqual(c?.index, 0)
        // …not once the bus has left it (07:13), however close
        XCTAssertNil(BoardAt.better(trip158(), fromId: "nl-OpenOV_4219829", from: bolkenplein, departure: at(14), to: denBosch,
                                    toName: "'s-Hertogenbosch, Centraal Station", you: atHome, now: at(12.5)))
    }

    func test_nearATie_keepsTheOneItHad() {
        // halfway between the two: neither is clearly closer
        let between = GeoPoint(lat: 51.6156, lon: 5.5466)
        XCTAssertNil(better(trip158(), you: between, now: at(1)))
    }

    func test_choosingAgain_staysPut() {
        // once on Bolkenplein, asking again from the same spot keeps it (no flip back to the bus station)
        XCTAssertNil(BoardAt.better(trip158(), fromId: "nl-OpenOV_4219829", from: bolkenplein, departure: at(14), to: denBosch,
                                    toName: "'s-Hertogenbosch, Centraal Station", you: inTown, now: at(1)))
    }

    // MARK: finding the ride on its trip

    func test_boardingIndex_byIdElseByPlace() {
        let s = trip158()
        XCTAssertEqual(BoardAt.boardingIndex(s, fromId: "nl-OpenOV_4219829", from: nil, departure: at(14)), 1)
        XCTAssertEqual(BoardAt.boardingIndex(s, fromId: "parent-or-other", from: busstation, departure: at(13)), 0)
        XCTAssertNil(BoardAt.boardingIndex(s, fromId: "nope", from: GeoPoint(lat: 51.7, lon: 5.0), departure: at(13)))
    }

    func test_boardingIndex_aLoopTakesTheCallAtItsTime() {
        var s = trip158()
        s.append(BoardAt.Stop(id: "nl-OpenOV_4219854", name: "Veghel, Busstation", point: busstation, departure: at(70)))
        XCTAssertEqual(BoardAt.boardingIndex(s, fromId: "nl-OpenOV_4219854", from: nil, departure: at(70)), 5)
        XCTAssertEqual(BoardAt.boardingIndex(s, fromId: "nl-OpenOV_4219854", from: nil, departure: at(13)), 0)
    }

    func test_alightingIndex_byPlaceElseName() {
        let s = trip158()
        XCTAssertEqual(BoardAt.alightingIndex(s, after: 0, to: denBosch, toName: ""), 4)
        XCTAssertEqual(BoardAt.alightingIndex(s, after: 0, to: nil, toName: "Veghel, Gasthuisstraat"), 3)
        XCTAssertNil(BoardAt.alightingIndex(s, after: 0, to: GeoPoint(lat: 52.0, lon: 4.0), toName: "Nowhere"))
        XCTAssertNil(BoardAt.alightingIndex(s, after: 4, to: denBosch, toName: ""))
    }

    func test_noWayToTell_keeps() {
        XCTAssertNil(better([], you: inTown, now: at(1)))
        XCTAssertNil(BoardAt.better(trip158(), fromId: "x", from: nil, departure: at(13), to: denBosch, toName: "", you: inTown, now: at(1)))
    }

    func test_walkMinutes() {
        XCTAssertEqual(BoardAt.walkMinutes(metres: 0), 1)
        XCTAssertEqual(BoardAt.walkMinutes(metres: 130), 3)
        XCTAssertEqual(BoardAt.walkMinutes(metres: 500), 10)
    }
}
