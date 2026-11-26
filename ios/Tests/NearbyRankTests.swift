import XCTest

final class NearbyRankTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let you = GeoPoint(lat: 51.69, lon: 5.30)

    private func stop(_ id: String, _ name: String, metres: Double, rail: Bool = false, north: Double? = nil) -> Nearby.Stop {
        let dLat: Double = (north ?? metres) / 111_320
        return Nearby.Stop(id: id, name: name, lat: you.lat + dLat, lon: you.lon, rail: rail, metres: metres)
    }

    private func at(_ m: Double) -> Date { now.addingTimeInterval(m * 60) }

    // MARK: the stops

    func test_twoSidesOfTheRoad_areOneStop_withBothIds() {
        let s: [Nearby.Stop] = [stop("a1", "Bolkenplein", metres: 400), stop("a2", "Bolkenplein ", metres: 420),
                                stop("b", "Rembrandtlaan", metres: 300)]
        let g: [Nearby.Group] = Nearby.groups(s, within: 1000)
        XCTAssertEqual(g.map(\.name), ["Rembrandtlaan", "Bolkenplein"])
        XCTAssertEqual(g[1].ids, ["a1", "a2"])
    }

    func test_beyondTheRange_isLeftOut_andTheSameNameFarOff_isNotAnother() {
        let s: [Nearby.Stop] = [stop("a", "Centrum", metres: 300), stop("c", "Centrum", metres: 900), stop("x", "Far", metres: 1500)]
        let g: [Nearby.Group] = Nearby.groups(s, within: 1000)
        XCTAssertEqual(g.map(\.id), ["centrum"])
        XCTAssertEqual(g[0].ids, ["a"])
    }

    func test_atMostEightStops_stationsAlwaysAmongThem_andTwelvePlans() {
        var s: [Nearby.Stop] = (0..<12).map { stop("s\($0)", "Stop \($0)", metres: Double(100 + $0 * 50)) }
        s += (0..<12).map { stop("t\($0)", "Stop \($0)", metres: Double(110 + $0 * 50)) }      // their other sides
        s.append(stop("ns", "Station", metres: 950, rail: true))
        let g: [Nearby.Group] = Nearby.groups(s, within: 1000)
        XCTAssertEqual(g.count, Nearby.maxGroups)
        XCTAssertTrue(g.contains { $0.rail }, "the station is planned from though further off")
        let plans: Int = g.reduce(0) { $0 + $1.ids.count }
        XCTAssertEqual(plans, Nearby.maxPlans)
        XCTAssertEqual(g[0].ids.count, 2, "the nearest get their second side first")
        XCTAssertEqual(g.last?.ids.count, 1)
    }

    func test_skip_plansOnlyTheNewOnes() {
        let s: [Nearby.Stop] = [stop("a", "A", metres: 300), stop("b", "B", metres: 1400)]
        let g: [Nearby.Group] = Nearby.groups(s, within: 1600, skip: ["a"])
        XCTAssertEqual(g.map(\.id), ["b"])
    }

    func test_widening_untilThreeUseful_atMostThreeKm() {
        XCTAssertEqual(Nearby.nextRadius(after: 1000, useful: 1), 1600)
        XCTAssertEqual(Nearby.nextRadius(after: 2200, useful: 0), 3000)
        XCTAssertNil(Nearby.nextRadius(after: 3000, useful: 0))
        XCTAssertNil(Nearby.nextRadius(after: 1000, useful: 3))
    }

    func test_walk_isTheStreetsAtThePlannersSpeed() {
        // 400 m straight: 520 m on foot, 7.2 min at 1.2 m/s → 8
        XCTAssertEqual(Nearby.plannedWalk(straight: 400), 8)
        XCTAssertEqual(Nearby.plannedWalk(straight: 0), 1)
        XCTAssertEqual(Nearby.plannedWalk(straight: 400, speed: 1.6), 6)
    }

    // MARK: the window

    func test_window_shiftsWithTheSwitch() {
        let w: Nearby.Window = Nearby.window(.in10, now: now)
        XCTAssertEqual(w.leave, at(10))
        XCTAssertEqual(w.until, at(45))
        XCTAssertTrue(Nearby.catchable(departure: at(16), walk: 6, w))
        XCTAssertFalse(Nearby.catchable(departure: at(15), walk: 6, w), "you can't be there yet")
        XCTAssertFalse(Nearby.catchable(departure: at(52), walk: 6, w), "past the window")
        XCTAssertEqual(Nearby.Leave.allCases.map(\.title), ["Leave now", "In 10 min", "In 20 min"])
    }

    // MARK: how sure

    func test_sure_fromYourRides_whenThereAreEnough() {
        let own: [Double] = [0, 1, 1, 2, 5, 0.5, 1, 1, 1, 1]
        let s: Nearby.Sure = Nearby.sure(own: own, modelLate: 0.5, made: 1, live: false)
        XCTAssertEqual(s.percent, 90)
        XCTAssertEqual(s.source, .yours(rides: 10))
        XCTAssertEqual(s.usual, 1)
        XCTAssertEqual(Nearby.sureWords(s), "on time 90% of your last 10 rides · usually +1 min")
    }

    func test_sure_withoutYourRides_isTheModels_andSaysSo() {
        let s: Nearby.Sure = Nearby.sure(own: [1, 2], modelLate: 0.2, made: 0.9, live: true)
        XCTAssertEqual(s.percent, 72)
        XCTAssertEqual(s.source, .live)
        XCTAssertNil(s.usual)
        XCTAssertEqual(Nearby.sureWords(s), "on time about 72% (by live times)")
        let e: Nearby.Sure = Nearby.sure(own: [], modelLate: 0.1, made: 1, live: false)
        XCTAssertEqual(e.source, .estimate)
    }

    func test_sure_keepsTheLastTwentyRides_andStaysWithin1to99() {
        let own: [Double] = Array(repeating: 10, count: 30) + Array(repeating: 0, count: 20)
        let s: Nearby.Sure = Nearby.sure(own: own, modelLate: 0, made: 1, live: false)
        XCTAssertEqual(s.source, .yours(rides: 20))
        XCTAssertEqual(s.percent, 99)
        XCTAssertNil(s.usual, "usually on time: no +0")
        XCTAssertEqual(Nearby.sure(own: [], modelLate: 1, made: 1, live: false).percent, 1)
    }

    func test_ring_solidDashedNeutral() {
        XCTAssertEqual(Nearby.ring(Nearby.Sure(percent: 90, source: .live, usual: nil)), .solid)
        XCTAssertEqual(Nearby.ring(Nearby.Sure(percent: 70, source: .yours(rides: 8), usual: 2)), .dashed)
        XCTAssertEqual(Nearby.ring(Nearby.Sure(percent: 95, source: .estimate, usual: nil)), .neutral)
        XCTAssertEqual(Nearby.ring(nil), .neutral)
    }

    // MARK: fastest, surest, slower

    private func opt(_ id: String, arrive: Double, leave: Double = 0, walk: Int = 5, pct: Int?) -> Nearby.Option {
        Nearby.Option(id: id, arrival: at(arrive), departure: at(leave), walk: walk,
                      sure: pct.map { Nearby.Sure(percent: $0, source: .live, usual: nil) })
    }

    func test_tags_fastestSurestSlower() {
        let o: [Nearby.Option] = [opt("rembrandt", arrive: 17, pct: 82), opt("bolken", arrive: 19, pct: 98),
                                  opt("bunders", arrive: 22, pct: 74), opt("kempkens", arrive: 31, pct: 61)]
        let t: [String: [Nearby.Tag]] = Nearby.tags(o)
        XCTAssertEqual(t["rembrandt"], [.fastest])
        XCTAssertEqual(t["bolken"], [.surest])
        XCTAssertEqual(t["bunders"], [.slower])
        XCTAssertEqual(t["kempkens"], [.slower])
        XCTAssertEqual(Nearby.ordered(o).map(\.id), ["rembrandt", "bolken", "bunders", "kempkens"])
    }

    func test_fastestThatIsAlsoSurest_getsBoth() {
        let o: [Nearby.Option] = [opt("a", arrive: 17, pct: 95), opt("b", arrive: 18, pct: 95), opt("c", arrive: 19, pct: 80)]
        let t: [String: [Nearby.Tag]] = Nearby.tags(o)
        XCTAssertEqual(t["a"], [.fastest, .surest])
        XCTAssertNil(t["b"], "only a minute later: not slower")
    }

    func test_fastest_onATie_theShorterWalk() {
        let o: [Nearby.Option] = [opt("far", arrive: 20, walk: 9, pct: nil), opt("near", arrive: 20, walk: 3, pct: nil)]
        XCTAssertEqual(Nearby.fastest(o)?.id, "near")
        XCTAssertEqual(Nearby.tags(o)["near"], [.fastest])
        XCTAssertTrue(Nearby.tags([]).isEmpty)
    }

    // MARK: colours and frame

    func test_colours_greenToRed_byArrival() {
        XCTAssertEqual(Nearby.color(0), 0x3DD598)
        XCTAssertEqual(Nearby.color(1), 0xE86F5A)
        XCTAssertEqual(Nearby.color(1.0 / 3), 0xC9D45A)
        XCTAssertEqual(Nearby.fraction(at(18), earliest: at(14), latest: at(28)), 4.0 / 14, accuracy: 0.0001)
        // two minutes apart: the later one is far from red (at least 8 minutes of spread)
        XCTAssertEqual(Nearby.fraction(at(16), earliest: at(14), latest: at(16)), 0.25, accuracy: 0.0001)
    }

    func test_frame_holdsYouAndTheStops_withRoom_andAMinimum() {
        let far = GeoPoint(lat: you.lat + 0.01, lon: you.lon + 0.02)
        let f: Nearby.Frame = Nearby.frame(you: you, stops: [far])
        XCTAssertEqual(f.lat, you.lat + 0.005, accuracy: 1e-9)
        XCTAssertEqual(f.lon, you.lon + 0.01, accuracy: 1e-9)
        XCTAssertEqual(f.latDelta, 0.014, accuracy: 1e-9)
        XCTAssertEqual(f.lonDelta, 0.028, accuracy: 1e-9)
        let alone: Nearby.Frame = Nearby.frame(you: you, stops: [])
        XCTAssertEqual(alone.latDelta, 600 / 111_320, accuracy: 1e-9)
    }

    // MARK: on the line now

    func test_stopsAway_andWords() {
        XCTAssertEqual(Nearby.stopsAway(next: 3, atStop: false, mine: 6), 4)
        XCTAssertEqual(Nearby.stopsAway(next: 6, atStop: true, mine: 6), 0)
        XCTAssertNil(Nearby.stopsAway(next: 7, atStop: false, mine: 6), "past your stop")
        XCTAssertEqual(Nearby.comingWords(minutes: 9, stops: 4), "in 9 min · 4 stops")
        XCTAssertEqual(Nearby.comingWords(minutes: 2, stops: 1), "in 2 min · next stop")
        XCTAssertEqual(Nearby.comingWords(minutes: 14, stops: nil), "in 14 min")
        XCTAssertEqual(Nearby.gpsAge(20), "GPS 20 s")
        XCTAssertEqual(Nearby.gpsAge(75), "GPS 1 min")
    }
}
