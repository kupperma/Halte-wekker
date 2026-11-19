import XCTest

final class MapTapTests: XCTestCase {
    func test_spanKeepsZoomWithinBounds() {
        XCTAssertEqual(MapTap.span(current: nil), 0.012)
        XCTAssertEqual(MapTap.span(current: 0.01), 0.01)
        XCTAssertEqual(MapTap.span(current: 0.5), MapTap.maxSpan)
        XCTAssertEqual(MapTap.span(current: 0.0001), MapTap.minSpan)
        XCTAssertEqual(MapTap.span(current: .nan), 0.012)
    }

    func test_centrePutsItemAboveTheSheet() {
        let c = MapTap.centre(item: GeoPoint(lat: 51.6, lon: 5.5), latDelta: 0.01)
        XCTAssertEqual(c.lon, 5.5)
        XCTAssertLessThan(c.lat, 51.6, "the middle south of it: the item shows in the upper part")
        XCTAssertEqual(c.lat, 51.6 - 0.0022, accuracy: 1e-9)
    }

    func test_usableRegion() {
        XCTAssertTrue(MapTap.usable(centerLat: 51.6, centerLon: 5.5, latDelta: 0.01, lonDelta: 0.02))
        XCTAssertTrue(MapTap.usable(centerLat: 20, centerLon: 0, latDelta: 150, lonDelta: 360), "the globe: usable, the zoom gating keeps it quiet")
        XCTAssertFalse(MapTap.usable(centerLat: .nan, centerLon: 5, latDelta: 0.01, lonDelta: 0.01))
        XCTAssertFalse(MapTap.usable(centerLat: 51, centerLon: 5, latDelta: 0, lonDelta: 0.01))
        XCTAssertFalse(MapTap.usable(centerLat: 51, centerLon: 5, latDelta: 0.01, lonDelta: .infinity))
        XCTAssertFalse(MapTap.usable(centerLat: 51, centerLon: 5, latDelta: 0.01, lonDelta: 400))
    }

    func test_zoomedOutAsksNothing() {
        // the whole globe: no vehicles asked, no stop tiles
        let zoom = MapZoom.level(lonDelta: 360)
        XCTAssertLessThan(zoom, VehiclePick.minZoom)
        XCTAssertLessThan(zoom, StopTiles.minZoom)
        let g = VehiclePick.Gate(enabled: true, visible: true, active: true, lowPower: false, zoom: zoom)
        XCTAssertFalse(VehiclePick.mayAsk(g, last: nil, now: Date()))
        XCTAssertTrue(StopTiles.covering(minLat: -60, minLon: -180, maxLat: 75, maxLon: 180).isEmpty)
        // the Netherlands: still nothing
        XCTAssertLessThan(MapZoom.level(lonDelta: 4), StopTiles.minZoom)
        // and a box asked for is never bigger than the cap
        let b = VehiclePick.box(center: GeoPoint(lat: 52, lon: 5), latDelta: 40, lonDelta: 80)
        XCTAssertLessThanOrEqual(b.maxLat - b.minLat, VehiclePick.maxHalfLat * 2 + 1e-9)
        XCTAssertLessThanOrEqual(b.maxLon - b.minLon, VehiclePick.maxHalfLon * 2 + 1e-9)
        XCTAssertLessThanOrEqual(StopTiles.covering(minLat: 51, minLon: 4, maxLat: 51.3, maxLon: 4.4).count, 6)
    }

    func test_boardIdsDropCoordinatesAndRepeats() {
        XCTAssertEqual(MapTap.boardIds(["nl-OpenOV_NL:S:64553000", "51.6,5.5", "nl-OpenOV_NL:S:64553000", "", "x_1"]),
                       ["nl-OpenOV_NL:S:64553000", "x_1"])
        XCTAssertTrue(MapTap.isCoordinate("51.61, 5.52"))
        XCTAssertFalse(MapTap.isCoordinate("de:08111:6118"))
    }

    func test_awayText() {
        XCTAssertNil(MapTap.awayText(metres: nil))
        XCTAssertEqual(MapTap.awayText(metres: 344), "340 m away · 4 min walk")
        XCTAssertEqual(MapTap.awayText(metres: 2400), "2.4 km away")
        XCTAssertEqual(MapTap.awayText(metres: 123_456), "123 km away")
    }

    func test_couldBeOnOnlyIdleAndFresh() {
        XCTAssertEqual(MapTap.couldBeOn(vehicleTrip: "t2", firstRides: ["t1", "t2"], fresh: true, idle: true, metresFromYou: 40), 1)
        XCTAssertNil(MapTap.couldBeOn(vehicleTrip: "t2", firstRides: ["t1", "t2"], fresh: false, idle: true, metresFromYou: 40), "a saved answer: not from here")
        XCTAssertNil(MapTap.couldBeOn(vehicleTrip: "t2", firstRides: ["t1", "t2"], fresh: true, idle: false, metresFromYou: 40), "a trip runs")
        XCTAssertNil(MapTap.couldBeOn(vehicleTrip: "t9", firstRides: ["t1", "t2"], fresh: true, idle: true, metresFromYou: 40))
        XCTAssertNil(MapTap.couldBeOn(vehicleTrip: "", firstRides: [""], fresh: true, idle: true, metresFromYou: 40))
        XCTAssertNil(MapTap.couldBeOn(vehicleTrip: "t2", firstRides: ["t1", "t2"], fresh: true, idle: true, metresFromYou: 5000), "across town")
        XCTAssertNil(MapTap.couldBeOn(vehicleTrip: "t2", firstRides: ["t1", "t2"], fresh: true, idle: true, metresFromYou: nil), "where you are isn't known")
    }

    /// 0.26.2 · 08:20 on 2026-11-19, on an Intercity: the home's trips were planned from the spot (an SPR from Eindhoven),
    /// so the Intercity marker right at your position offered no "I'm on this one". Now it does, planned from on board.
    func test_couldBeCarryingYou() {
        // the field case: moving, the IC 40 m from your fix of 3 s ago, the first ride of none of your trips
        XCTAssertNil(MapTap.couldBeOn(vehicleTrip: "IC6632", firstRides: ["SPR8531"], fresh: true, idle: true, metresFromYou: 40))
        XCTAssertTrue(MapTap.couldBeCarrying(vehicleTrip: "IC6632", isTrain: true, idle: true, onBoardTrip: nil, moving: true,
                                             metresFromYou: 40, fixAge: 3))
        // a train's marker lags more: 500 m still; a bus's not
        XCTAssertTrue(MapTap.couldBeCarrying(vehicleTrip: "IC", isTrain: true, idle: true, onBoardTrip: nil, moving: true, metresFromYou: 500, fixAge: 3))
        XCTAssertFalse(MapTap.couldBeCarrying(vehicleTrip: "305", isTrain: false, idle: true, onBoardTrip: nil, moving: true, metresFromYou: 500, fixAge: 3))
        XCTAssertTrue(MapTap.couldBeCarrying(vehicleTrip: "305", isTrain: false, idle: true, onBoardTrip: nil, moving: true, metresFromYou: 250, fixAge: 3))
        // the one the home found you on: always, moving or standing at a station
        XCTAssertTrue(MapTap.couldBeCarrying(vehicleTrip: "IC", isTrain: true, idle: true, onBoardTrip: "IC", moving: false, metresFromYou: nil, fixAge: nil))
    }

    func test_notCarryingYou() {
        // standing on a platform as it passes, a trip running, an old fix, far, nothing known
        XCTAssertFalse(MapTap.couldBeCarrying(vehicleTrip: "IC", isTrain: true, idle: true, onBoardTrip: nil, moving: false, metresFromYou: 20, fixAge: 3))
        XCTAssertFalse(MapTap.couldBeCarrying(vehicleTrip: "IC", isTrain: true, idle: false, onBoardTrip: "IC", moving: true, metresFromYou: 20, fixAge: 3))
        XCTAssertFalse(MapTap.couldBeCarrying(vehicleTrip: "IC", isTrain: true, idle: true, onBoardTrip: nil, moving: true, metresFromYou: 20, fixAge: 120))
        XCTAssertFalse(MapTap.couldBeCarrying(vehicleTrip: "IC", isTrain: true, idle: true, onBoardTrip: nil, moving: true, metresFromYou: 2000, fixAge: 3))
        XCTAssertFalse(MapTap.couldBeCarrying(vehicleTrip: "IC", isTrain: true, idle: true, onBoardTrip: nil, moving: true, metresFromYou: nil, fixAge: 3))
        XCTAssertFalse(MapTap.couldBeCarrying(vehicleTrip: "", isTrain: true, idle: true, onBoardTrip: "", moving: true, metresFromYou: 20, fixAge: 3))
    }

    func test_aheadStops() {
        XCTAssertEqual(MapTap.ahead(next: 2, count: 10, done: false), 3..<7)
        XCTAssertEqual(MapTap.ahead(next: 8, count: 10, done: false), 9..<10)
        XCTAssertEqual(MapTap.ahead(next: 9, count: 10, done: false), 0..<0)
        XCTAssertEqual(MapTap.ahead(next: 2, count: 10, done: true), 0..<0)
    }

    func test_delayText() {
        let s = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(MapTap.delayText(at: s.addingTimeInterval(180), scheduled: s), "+3 min")
        XCTAssertEqual(MapTap.delayText(at: s.addingTimeInterval(-120), scheduled: s), "2 min early")
        XCTAssertEqual(MapTap.delayText(at: s.addingTimeInterval(20), scheduled: s), "on time")
        XCTAssertNil(MapTap.delayText(at: s, scheduled: nil))
    }

    func test_wakeKmSteps() {
        XCTAssertEqual(MapTap.wakeKm(1.5, by: 0.5, bus: true), 2)
        XCTAssertEqual(MapTap.wakeKm(0.5, by: -0.5, bus: true), 0.5)
        XCTAssertEqual(MapTap.wakeKm(10, by: 0.5, bus: true), 10)
        XCTAssertEqual(MapTap.wakeKm(10, by: 0.5, bus: false), 10.5)
        XCTAssertEqual(MapTap.wakeKm(15, by: 0.5, bus: false), 15)
        XCTAssertEqual(MapTap.wakeKm(1.3, by: 0.5, bus: false), 2, "an odd remembered value lands on a half km")
    }

    // MARK: follow me

    func test_followNotHandWhileSettlingOrFree() {
        XCTAssertFalse(MapFollow.handMoved(following: true, settling: true, centreToUser: 5000, viewMetres: 1400, span: 0.1, baseline: 0.01))
        XCTAssertFalse(MapFollow.handMoved(following: false, settling: false, centreToUser: 5000, viewMetres: 1400, span: 0.1, baseline: 0.01))
    }

    func test_followPanAwayIsHand() {
        XCTAssertTrue(MapFollow.handMoved(following: true, settling: false, centreToUser: 600, viewMetres: 1400, span: 0.012, baseline: 0.012))
        XCTAssertFalse(MapFollow.handMoved(following: true, settling: false, centreToUser: 50, viewMetres: 1400, span: 0.012, baseline: 0.012),
                       "the map following you as you walk: its middle stays on you")
        XCTAssertFalse(MapFollow.handMoved(following: true, settling: false, centreToUser: 200, viewMetres: 1400, span: 0.012, baseline: 0.012),
                       "a fix a little behind: within a fifth of the view")
    }

    func test_followZoomIsHand() {
        XCTAssertTrue(MapFollow.handMoved(following: true, settling: false, centreToUser: 10, viewMetres: 1400, span: 0.03, baseline: 0.012))
        XCTAssertTrue(MapFollow.handMoved(following: true, settling: false, centreToUser: nil, viewMetres: 1400, span: 0.005, baseline: 0.012))
        XCTAssertFalse(MapFollow.handMoved(following: true, settling: false, centreToUser: nil, viewMetres: 1400, span: 0.0125, baseline: 0.012))
        XCTAssertFalse(MapFollow.handMoved(following: true, settling: false, centreToUser: nil, viewMetres: 1400, span: 0.03, baseline: nil),
                       "no baseline yet: not judged")
    }

    func test_fitSettlingIsNotAHand() {
        let t = Date(timeIntervalSince1970: 5000)
        XCTAssertFalse(MapFollow.handMovedSinceFit(lastFit: nil, now: t), "the map's first look, before any fit")
        XCTAssertFalse(MapFollow.handMovedSinceFit(lastFit: t.addingTimeInterval(-1.2), now: t), "its own 1.2 s fit ending")
        XCTAssertTrue(MapFollow.handMovedSinceFit(lastFit: t.addingTimeInterval(-3), now: t))
    }
}
