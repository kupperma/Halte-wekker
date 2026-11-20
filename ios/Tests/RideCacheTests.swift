import XCTest

/// 0.39: the trip's rides saved on the phone for stretches without signal: bounded, for the running trip only, and
/// what the ride takes from them.
final class RideCacheTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ m: Double) -> Date { t0.addingTimeInterval(m * 60) }

    private func ride(_ id: String, stops n: Int = 4, shape: Int = 10, saved: Date? = nil, live: Bool = true) -> SavedRide {
        let stops: [SavedRide.Stop] = (0..<n).map { i in
            SavedRide.Stop(name: "S\(i)", lat: 51.6 + Double(i) * 0.01, lon: 5.3, arrival: at(Double(i) * 5 + 1),
                           departure: at(Double(i) * 5 + 2), scheduled: at(Double(i) * 5), platform: i == n - 1 ? "5" : nil)
        }
        let path: [GeoPoint] = (0..<shape).map { GeoPoint(lat: 51.6 + Double($0) * 0.001, lon: 5.3) }
        return SavedRide(tripId: id, line: "IC", isTrain: true, live: live, savedAt: saved ?? t0, stops: stops, shape: path)
    }

    func test_thinKeepsTheEndsAndTheBound() {
        let path: [GeoPoint] = (0..<1000).map { GeoPoint(lat: Double($0), lon: 0) }
        let t = RideCache.thin(path, limit: 50)
        XCTAssertEqual(t.count, 50)
        XCTAssertEqual(t.first, path.first)
        XCTAssertEqual(t.last, path.last)
        XCTAssertEqual(RideCache.thin(Array(path.prefix(30)), limit: 50).count, 30, "short enough already")
    }

    func test_boundedStopsAndShape() {
        let b = RideCache.bounded(ride("a", stops: 300, shape: 5000))
        XCTAssertEqual(b.stops.count, RideCache.maxStops)
        XCTAssertEqual(b.shape.count, RideCache.maxShape)
    }

    func test_putReplacesKeepsTheNewestAndDropsAnotherTrip() {
        var s = RideCache.put(ride("a"), into: nil, trip: t0)
        s = RideCache.put(ride("b"), into: s, trip: t0)
        s = RideCache.put(ride("a", saved: at(3)), into: s, trip: t0)
        XCTAssertEqual(s.rides.map(\.tripId), ["b", "a"])
        XCTAssertEqual(s.rides.last?.savedAt, at(3))
        for k in 0..<6 { s = RideCache.put(ride("x\(k)"), into: s, trip: t0) }
        XCTAssertEqual(s.rides.count, RideCache.maxRides)
        XCTAssertEqual(s.rides.last?.tripId, "x5")
        let other = RideCache.put(ride("c"), into: s, trip: at(60))
        XCTAssertEqual(other.rides.map(\.tripId), ["c"], "another trip's copy goes")
    }

    func test_rideOnlyForTheRunningTripAndNotTooOld() {
        let s = RideCache.put(ride("a"), into: nil, trip: t0)
        XCTAssertNotNil(RideCache.ride("a", in: s, trip: t0, now: at(10)))
        XCTAssertNil(RideCache.ride("a", in: s, trip: at(1), now: at(10)), "not this trip's")
        XCTAssertNil(RideCache.ride("a", in: s, trip: nil, now: at(10)), "no trip")
        XCTAssertNil(RideCache.ride("b", in: s, trip: t0, now: at(10)))
        XCTAssertNil(RideCache.ride("a", in: s, trip: t0, now: t0.addingTimeInterval(RideCache.maxAge + 1)))
        XCTAssertTrue(RideCache.keep(s, trip: t0, now: at(10)))
        XCTAssertFalse(RideCache.keep(s, trip: nil, now: at(10)))
    }

    func test_encodeStaysWithinBytes() throws {
        var s = SavedTrip(trip: t0)
        for k in 0..<RideCache.maxRides { s = RideCache.put(ride("r\(k)", stops: 120, shape: 400), into: s, trip: t0) }
        let d = try XCTUnwrap(RideCache.encode(s))
        XCTAssertLessThanOrEqual(d.count, RideCache.maxBytes)
        let back = try JSONDecoder().decode(SavedTrip.self, from: d)
        XCTAssertGreaterThanOrEqual(back.rides.count, 1)
        XCTAssertEqual(back.rides.last, s.rides.last, "the newest ride is kept")
    }

    func test_timesStopsAndDelay() {
        let r = ride("a")
        let t = RideCache.times(r)
        XCTAssertEqual(t.first ?? nil, at(2), "it leaves the first one")
        XCTAssertEqual(t.last ?? nil, at(16), "it gets to the rest")
        XCTAssertEqual(RideCache.stop(near: GeoPoint(lat: 51.63, lon: 5.3), in: r), 3)
        XCTAssertNil(RideCache.stop(near: GeoPoint(lat: 52.5, lon: 5.3), in: r))
        XCTAssertNil(RideCache.stop(near: GeoPoint(lat: 51.6, lon: 5.3), in: r, after: 3))
        XCTAssertEqual(RideCache.delay(r, at: 3), 1)
        XCTAssertEqual(RideCache.delay(r, at: 0), 2)
        XCTAssertNil(RideCache.delay(ride("b", live: false), at: 3))
        XCTAssertEqual(r.stops[3].platform, "5")
    }

    func test_dueAndBackOnline() {
        XCTAssertTrue(RideCache.due(lastSaved: nil, now: t0))
        XCTAssertFalse(RideCache.due(lastSaved: t0, now: at(1)))
        XCTAssertTrue(RideCache.due(lastSaved: t0, now: at(2)))
        XCTAssertTrue(RideCache.backOnline(wasOffline: true, online: true))
        XCTAssertFalse(RideCache.backOnline(wasOffline: false, online: true))
        XCTAssertFalse(RideCache.backOnline(wasOffline: true, online: false))
    }
}
