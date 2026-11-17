import XCTest

/// A tiny protobuf writer, to build feeds by hand.
private enum PB {
    static func varint(_ v: UInt64) -> [UInt8] {
        var v = v, out: [UInt8] = []
        repeat {
            var b = UInt8(v & 0x7f); v >>= 7
            if v != 0 { b |= 0x80 }
            out.append(b)
        } while v != 0
        return out
    }
    static func key(_ n: UInt64, _ wire: UInt64) -> [UInt8] { varint(n << 3 | wire) }
    static func uint(_ n: UInt64, _ v: UInt64) -> [UInt8] { key(n, 0) + varint(v) }
    static func bytes(_ n: UInt64, _ b: [UInt8]) -> [UInt8] { key(n, 2) + varint(UInt64(b.count)) + b }
    static func string(_ n: UInt64, _ s: String) -> [UInt8] { bytes(n, Array(s.utf8)) }
    static func float(_ n: UInt64, _ f: Float) -> [UInt8] {
        let b = f.bitPattern
        return key(n, 5) + (0..<4).map { UInt8((b >> (8 * $0)) & 0xff) }
    }
    static func double(_ n: UInt64, _ d: Double) -> [UInt8] {
        let b = d.bitPattern
        return key(n, 1) + (0..<8).map { UInt8((b >> (8 * UInt64($0))) & 0xff) }
    }

    /// A FeedEntity with a VehiclePosition, and (`extra`) unknown fields everywhere.
    static func entity(id: String, trip: String, date: String = "20261117", lat: Float, lon: Float, bearing: Float? = nil,
                       ts: UInt64?, extra: Bool = false) -> [UInt8] {
        var td = string(1, trip) + string(3, date) + string(5, "151894")
        if extra { td += uint(99, 7) }
        var pos = float(1, lat) + float(2, lon)
        if let bearing { pos += float(3, bearing) }
        if extra { pos += double(4, 12345.5) + float(5, 8.2) }
        var vp = bytes(1, td) + bytes(2, pos) + uint(3, 14) + uint(4, 1)
        if let ts { vp += uint(5, ts) }
        if extra { vp += string(7, "4232722") + bytes(8, string(2, "6205")) + bytes(1003, uint(1, 322)) }
        var e = string(1, id) + bytes(4, vp)
        if extra { e += uint(2, 0) + bytes(1500, [1, 2, 3]) }
        return bytes(2, e)
    }

    static func header(ts: UInt64) -> [UInt8] {
        bytes(1, string(1, "1.0") + uint(2, 0) + uint(3, ts) + bytes(1000, uint(1, 42_000_000) + uint(2, 60)))
    }
}

final class RealPositionsTests: XCTestCase {
    let t0: UInt64 = 1_794_918_086         // 2026-11-17 13:21 in the Netherlands

    // MARK: reading the feed

    func test_readsAHandBuiltFeed() {
        // the smallest feed, byte by byte: header { timestamp 1000 } entity { id "a" vehicle { trip { trip_id "7" }
        // position { 51.5, 5.25 } timestamp 990 } }
        let lat = Float(51.5).bitPattern, lon = Float(5.25).bitPattern
        func le(_ x: UInt32) -> [UInt8] { (0..<4).map { UInt8((x >> (8 * $0)) & 0xff) } }
        let pos: [UInt8] = [0x0d] + le(lat) + [0x15] + le(lon)              // 10 bytes
        let vp: [UInt8] = [0x0a, 0x03, 0x0a, 0x01, 0x37, 0x12, 0x0a] + pos + [0x28, 0xde, 0x07]
        let ent: [UInt8] = [0x0a, 0x01, 0x61, 0x22, UInt8(vp.count)] + vp
        let bytes: [UInt8] = [0x0a, 0x03, 0x18, 0xe8, 0x07, 0x12, UInt8(ent.count)] + ent
        let feed = RealPositions.parse(Data(bytes))
        XCTAssertEqual(feed.timestamp, Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(feed.entities, 1)
        let f = feed.fixes["7"]
        XCTAssertEqual(f?.lat, 51.5)
        XCTAssertEqual(f?.lon, 5.25)
        XCTAssertNil(f?.bearing)
        XCTAssertEqual(f?.at, Date(timeIntervalSince1970: 990))
    }

    func test_skipsUnknownFieldsAndExtensions() {
        let data = PB.header(ts: t0)
            + PB.entity(id: "2026-11-17:QBUZZ:m090:1017", trip: "395867263", lat: 51.929, lon: 4.892, bearing: 270, ts: t0 - 12, extra: true)
            + PB.bytes(1200, [9, 9, 9])                                      // an unknown top-level field
            + PB.entity(id: "x", trip: "398181886", lat: 52.365, lon: 4.885, ts: t0 - 7)
        let feed = RealPositions.parse(Data(data))
        XCTAssertEqual(feed.timestamp, Date(timeIntervalSince1970: TimeInterval(t0)))
        XCTAssertEqual(feed.fixes.count, 2)
        let a = feed.fixes["395867263"]
        XCTAssertEqual(a?.lat ?? 0, 51.929, accuracy: 1e-5)
        XCTAssertEqual(a?.lon ?? 0, 4.892, accuracy: 1e-5)
        XCTAssertEqual(a?.bearing, 270)
        XCTAssertEqual(a?.at, Date(timeIntervalSince1970: TimeInterval(t0 - 12)))
        XCTAssertEqual(a?.startDate, "20261117")
        XCTAssertEqual(a?.stopSequence, 14)
        XCTAssertEqual(a?.stopped, true)
        XCTAssertNotNil(feed.fixes["398181886"])
    }

    func test_truncatedFeedKeepsWhatWasWhole() {
        let whole = PB.header(ts: t0) + PB.entity(id: "a", trip: "1", lat: 51.6, lon: 5.3, ts: t0)
            + PB.entity(id: "b", trip: "2", lat: 51.7, lon: 5.4, ts: t0)
        let full = RealPositions.parse(Data(whole))
        XCTAssertEqual(Set(full.fixes.keys), ["1", "2"])
        // every cut: never a crash, never a fix that wasn't in the feed, and the first whole once the second starts
        let firstEnd = (PB.header(ts: t0) + PB.entity(id: "a", trip: "1", lat: 51.6, lon: 5.3, ts: t0)).count
        for cut in 0..<whole.count {
            let f = RealPositions.parse(Data(whole.prefix(cut)))
            XCTAssertTrue(Set(f.fixes.keys).isSubset(of: ["1", "2"]))
            if cut >= firstEnd { XCTAssertNotNil(f.fixes["1"], "cut at \(cut)") }
            XCTAssertNil(f.fixes["2"], "the second is cut short at \(cut)")
        }
    }

    func test_garbageNeverCrashes() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let n = Int.random(in: 0..<200, using: &rng)
            let junk = (0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) }
            _ = RealPositions.parse(Data(junk))
        }
        // a varint that never ends, a length past the end, a group, field number 0
        XCTAssertTrue(RealPositions.parse(Data([0x08] + Array(repeating: 0xff, count: 20))).fixes.isEmpty)
        XCTAssertTrue(RealPositions.parse(Data([0x12, 0xff, 0xff, 0x03, 0x01])).fixes.isEmpty)
        XCTAssertTrue(RealPositions.parse(Data([0x13, 0x14])).fixes.isEmpty)
        XCTAssertTrue(RealPositions.parse(Data([0x00, 0x01])).fixes.isEmpty)
        XCTAssertEqual(RealPositions.parse(Data()).fixes.count, 0)
    }

    func test_leavesOutVehiclesWithoutTripOrPosition_andKeepsTheNewest() {
        let noTrip = PB.bytes(2, PB.string(1, "n") + PB.bytes(4, PB.bytes(2, PB.float(1, 51.5) + PB.float(2, 5.2)) + PB.uint(5, t0)))
        let noPos = PB.bytes(2, PB.string(1, "p") + PB.bytes(4, PB.bytes(1, PB.string(1, "9")) + PB.uint(5, t0)))
        let zero = PB.entity(id: "z", trip: "8", lat: 0, lon: 0, ts: t0)
        let older = PB.entity(id: "o", trip: "5", lat: 51.1, lon: 5.1, ts: t0 - 60)
        let newer = PB.entity(id: "q", trip: "5", lat: 51.2, lon: 5.2, ts: t0 - 10)
        let noTime = PB.entity(id: "t", trip: "6", lat: 51.3, lon: 5.3, ts: nil)
        let feed = RealPositions.parse(Data(PB.header(ts: t0) + noTrip + noPos + zero + newer + older + noTime))
        XCTAssertEqual(Set(feed.fixes.keys), ["5", "6"])
        XCTAssertEqual(feed.fixes["5"]?.lat ?? 0, 51.2, accuracy: 1e-5, "the newest fix of a trip")
        XCTAssertEqual(feed.fixes["6"]?.at, Date(timeIntervalSince1970: TimeInterval(t0)), "no time of its own: the feed's")
        XCTAssertEqual(feed.entities, 6)
    }

    // MARK: which fix is a trip's

    func test_keyAndServiceDate() {
        XCTAssertEqual(RealPositions.key("20261117_11:57_nl-OpenOV_374105578"), "374105578")
        XCTAssertNil(RealPositions.key("20261117_11:57_nl-NS_12345"))
        XCTAssertNil(RealPositions.key("20261117_11:57_nl-OpenOV_"))
        XCTAssertEqual(RealPositions.serviceDate("20261117_11:57_nl-OpenOV_374105578"), "20261117")
        XCTAssertNil(RealPositions.serviceDate("abc_nl-OpenOV_1"))
    }

    func test_usableOnlyWhenFreshAndToday() {
        let now = Date(timeIntervalSince1970: TimeInterval(t0))
        let id = "20261117_11:57_nl-OpenOV_374105578"
        func fix(_ age: TimeInterval, date: String? = "20261117") -> [String: GPSFix] {
            ["374105578": GPSFix(lat: 51.6, lon: 5.3, bearing: nil, at: now.addingTimeInterval(-age), startDate: date)]
        }
        XCTAssertNotNil(RealPositions.usable(fix(40), tripId: id, now: now))
        XCTAssertNotNil(RealPositions.usable(fix(180), tripId: id, now: now))
        XCTAssertNil(RealPositions.usable(fix(181), tripId: id, now: now), "older than 3 minutes")
        XCTAssertNil(RealPositions.usable(fix(-120), tripId: id, now: now), "well ahead of the clock")
        XCTAssertNil(RealPositions.usable(fix(40, date: "20261116"), tripId: id, now: now), "another day's trip")
        XCTAssertNotNil(RealPositions.usable(fix(40, date: nil), tripId: id, now: now))
        XCTAssertNil(RealPositions.usable(fix(40), tripId: "20261117_11:57_nl-OpenOV_999", now: now), "not in the feed")
        XCTAssertNil(RealPositions.usable(fix(40), tripId: "20261117_11:57_de-DELFI_374105578", now: now), "not OpenOV")
        // a trip of last week whose fix is somehow fresh
        let old = "20261110_11:57_nl-OpenOV_374105578"
        XCTAssertNil(RealPositions.usable(fix(40, date: "20261110"), tripId: old, now: now))
        // a night bus after midnight: yesterday's service date
        let night = Date(timeIntervalSince1970: 1_794_960_000)          // 2026-11-18 01:00 Dutch time
        XCTAssertEqual(RealPositions.day(night), "20261118")
        let nf = ["1": GPSFix(lat: 51.6, lon: 5.3, bearing: nil, at: night.addingTimeInterval(-30), startDate: "20261117")]
        XCTAssertNotNil(RealPositions.usable(nf, tripId: "20261117_25:20_nl-OpenOV_1", now: night))
    }

    // MARK: putting it on its road

    /// A straight road east from (51.6, 5.3): pieces of 600 m, 2 minutes each (5 m/s), a minute at each stop.
    private func road(_ start: Date, pieces n: Int = 3) -> [RealPositions.Leg] {
        let kx = cos(51.6 * .pi / 180) * 111_320
        func p(_ m: Double) -> GeoPoint { GeoPoint(lat: 51.6, lon: 5.3 + m / kx) }
        return RealPositions.chained((0..<n).map { k in
            let d = start.addingTimeInterval(Double(k) * 180)
            return (path: [p(Double(k) * 600), p(Double(k) * 600 + 300), p(Double(k + 1) * 600)], departure: d, arrival: d.addingTimeInterval(120))
        })
    }
    private func at(_ m: Double, north: Double = 0, age: TimeInterval, _ now: Date) -> GPSFix {
        let kx = cos(51.6 * .pi / 180) * 111_320
        return GPSFix(lat: 51.6 + north / 110_540, lon: 5.3 + m / kx, bearing: 90, at: now.addingTimeInterval(-age))
    }

    func test_snapsOnTheRoadOnlyWhenNearIt() {
        let t = Date(timeIntervalSince1970: 1_794_900_000), legs = road(t)
        let s = RealPositions.snap(at(900, north: 40, age: 0, t), on: legs)
        XCTAssertEqual(s?.leg, 1)
        XCTAssertEqual(s?.along ?? 0, 300, accuracy: 2)
        XCTAssertEqual(s?.crossTrack ?? 0, 40, accuracy: 2)
        XCTAssertNil(RealPositions.snap(at(900, north: 160, age: 0, t), on: legs), "more than 150 m from its road")
        XCTAssertNil(RealPositions.snap(at(900, age: 0, t), on: []))
    }

    func test_movesOnAtItsSpeed_atMostAMinute() {
        let t = Date(timeIntervalSince1970: 1_794_900_000), legs = road(t)
        // 200 m into the first piece, 20 s ago: 100 m further (5 m/s)
        let now = t.addingTimeInterval(60)
        let a = RealPositions.place(at(200, age: 20, now), on: legs, now: now)
        XCTAssertEqual(a?.metres ?? 0, 300, accuracy: 2)
        // 90 s old: moved on 60 s only
        let b = RealPositions.place(at(100, age: 90, now), on: legs, now: now)
        XCTAssertEqual(b?.metres ?? 0, 400, accuracy: 2)
        // a fix from the future (the phone's clock behind): where it is
        let c = RealPositions.place(at(100, age: -10, now), on: legs, now: now)
        XCTAssertEqual(c?.metres ?? 0, 100, accuracy: 2)
    }

    func test_neverPastTheNextStopBeforeItLeaves() {
        let t = Date(timeIntervalSince1970: 1_794_900_000), legs = road(t)
        // 550 m (50 m before the stop at 600 m), 30 s ago, at t+100: the stop is reached and it leaves at t+180
        var now = t.addingTimeInterval(100)
        var p = RealPositions.place(at(550, age: 30, now), on: legs, now: now)
        XCTAssertEqual(p?.metres ?? 0, 600, accuracy: 1)
        XCTAssertEqual(p?.spot.leg, 0)
        // after it leaves there (t+180): 20 s on the next piece
        now = t.addingTimeInterval(200)
        p = RealPositions.place(at(550, age: 50, now), on: legs, now: now)
        XCTAssertEqual(p?.metres ?? 0, 700, accuracy: 2)
        XCTAssertEqual(p?.spot.leg, 1)
        // a late bus: standing at the stop at the start of a piece it should have left: it goes now
        now = t.addingTimeInterval(400)
        p = RealPositions.place(at(1200, age: 20, now), on: legs, now: now)
        XCTAssertEqual(p?.metres ?? 0, 1300, accuracy: 2)
        // early at a stop: it waits for its departure
        now = t.addingTimeInterval(150)
        p = RealPositions.place(at(600, age: 20, now), on: legs, now: now)
        XCTAssertEqual(p?.metres ?? 0, 600, accuracy: 1)
    }

    func test_aRoadThatPassesTwice_takesThePassNearItsTimes() {
        // out east 600 m and back west along the same street
        let t = Date(timeIntervalSince1970: 1_794_900_000)
        let kx = cos(51.6 * .pi / 180) * 111_320
        func p(_ m: Double, _ n: Double = 0) -> GeoPoint { GeoPoint(lat: 51.6 + n / 110_540, lon: 5.3 + m / kx) }
        let legs = RealPositions.chained([
            (path: [p(0), p(600)], departure: t, arrival: t.addingTimeInterval(120)),
            (path: [p(600, 10), p(0, 10)], departure: t.addingTimeInterval(180), arrival: t.addingTimeInterval(300)),
        ])
        let out = RealPositions.snap(GPSFix(lat: 51.6 + 5 / 110_540, lon: 5.3 + 300 / kx, bearing: nil, at: t.addingTimeInterval(60)), on: legs)
        XCTAssertEqual(out?.leg, 0)
        let back = RealPositions.snap(GPSFix(lat: 51.6 + 5 / 110_540, lon: 5.3 + 300 / kx, bearing: nil, at: t.addingTimeInterval(240)), on: legs)
        XCTAssertEqual(back?.leg, 1)
        XCTAssertEqual(back?.along ?? 0, 300, accuracy: 2)
    }

    func test_timeMetres() {
        let t = Date(timeIntervalSince1970: 1_794_900_000), legs = road(t)
        XCTAssertEqual(RealPositions.timeMetres(legs, at: t.addingTimeInterval(-50)), 0)
        XCTAssertEqual(RealPositions.timeMetres(legs, at: t.addingTimeInterval(60)) ?? 0, 300, accuracy: 1e-6)
        XCTAssertEqual(RealPositions.timeMetres(legs, at: t.addingTimeInterval(150)) ?? 0, 600, accuracy: 1e-6, "standing at the stop")
        XCTAssertEqual(RealPositions.timeMetres(legs, at: t.addingTimeInterval(9999)) ?? 0, 1800, accuracy: 1e-6)
        XCTAssertNil(RealPositions.timeMetres([], at: t))
    }

    func test_pointAndBearing() {
        let t = Date(timeIntervalSince1970: 1_794_900_000), legs = road(t)
        let p = RealPositions.point(RealPositions.Spot(leg: 1, along: 300, crossTrack: 0), on: legs)
        XCTAssertEqual(p?.bearing ?? 0, 90, accuracy: 1, "east")
        XCTAssertEqual(Geo.metres(p!.point, GeoPoint(lat: 51.6, lon: 5.3 + 900 / (cos(51.6 * .pi / 180) * 111_320))), 0, accuracy: 1)
        XCTAssertEqual(RealPositions.point(RealPositions.Spot(leg: 0, along: 600, crossTrack: 0), on: legs)?.bearing ?? 0, 90, accuracy: 1, "at the end too")
        XCTAssertNil(RealPositions.point(RealPositions.Spot(leg: 7, along: 0, crossTrack: 0), on: legs))
    }

    func test_spotAtMetres() {
        let t = Date(timeIntervalSince1970: 1_794_900_000), legs = road(t)
        XCTAssertEqual(RealPositions.spot(atMetres: 900, on: legs)?.leg, 1)
        XCTAssertEqual(RealPositions.spot(atMetres: 900, on: legs)?.along ?? 0, 300, accuracy: 0.01)
        XCTAssertEqual(RealPositions.spot(atMetres: -5, on: legs)?.leg, 0)
        XCTAssertEqual(RealPositions.spot(atMetres: 5000, on: legs)?.along ?? 0, 600, accuracy: 1e-6)
        XCTAssertEqual(RealPositions.spot(atMetres: 5000, on: legs)?.leg, 2)
        XCTAssertNil(RealPositions.spot(atMetres: 1, on: []))
    }

    func test_holdsALittleBack_notABigCorrection() {
        XCTAssertEqual(RealPositions.hold(shown: nil, new: 100), 100)
        XCTAssertEqual(RealPositions.hold(shown: 100, new: 120), 120)
        XCTAssertEqual(RealPositions.hold(shown: 100, new: 70), 100, "a new fix a little behind: it waits")
        XCTAssertEqual(RealPositions.hold(shown: 100, new: 20), 20, "a real correction")
    }

    // MARK: fetching

    func test_backoff() {
        XCTAssertEqual(RealPositions.backoff(failures: 0), 30)
        XCTAssertEqual(RealPositions.backoff(failures: 1), 60)
        XCTAssertEqual(RealPositions.backoff(failures: 2), 120)
        XCTAssertEqual(RealPositions.backoff(failures: 3), 240)
        XCTAssertEqual(RealPositions.backoff(failures: 4), 300)
        XCTAssertEqual(RealPositions.backoff(failures: 400), 300)
    }

    func test_logLinesHoldNoPlaces() {
        XCTAssertEqual(RealPositions.fetchLine(status: 200, bytes: 189_000, vehicles: 3856, parseMs: 84.6, next: 30),
                       "vehiclePositions.pb · 200 · 184.6 KB · 3856 vehicles · parse 85 ms")
        XCTAssertEqual(RealPositions.fetchLine(status: 304, bytes: 0, vehicles: 3856, parseMs: nil, next: 30),
                       "vehiclePositions.pb · 304 · kept 3856 vehicles")
        XCTAssertEqual(RealPositions.fetchLine(status: nil, error: -1001, bytes: 0, vehicles: 0, parseMs: nil, next: 120),
                       "vehiclePositions.pb · error -1001 · again in 120 s")
        XCTAssertEqual(RealPositions.fetchLine(status: 503, bytes: 10, vehicles: 0, parseMs: nil, next: 60),
                       "vehiclePositions.pb · 503 · again in 60 s")
        XCTAssertEqual(RealPositions.usedLine(vehicle: FieldFormat.vehicle(line: "306", tripId: "20261117_11:57_nl-OpenOV_374105578", isTrain: false),
                                              age: 41.6, metres: 274, behind: true),
                       "real position · bus 306·5578 · GPS 42 s old · 270 m from its times (behind)")
    }
    // MARK: 0.20.3: the matcher's freshness, the fix before, trains

    func test_usableForTheMatcher_isFresher() {
        let now = Date(timeIntervalSince1970: TimeInterval(t0))
        let id = "20261117_11:57_nl-OpenOV_374105578"
        let f = GPSFix(lat: 51.6, lon: 5.5, bearing: nil, at: now.addingTimeInterval(-120), startDate: "20261117")
        XCTAssertNotNil(RealPositions.usable(["374105578": f], tripId: id, now: now))
        XCTAssertNil(RealPositions.usable(["374105578": f], tripId: id, now: now, fresh: RealPositions.matchFresh))
        let g = GPSFix(lat: 51.6, lon: 5.5, bearing: nil, at: now.addingTimeInterval(-80), startDate: "20261117")
        XCTAssertNotNil(RealPositions.usable(["374105578": g], tripId: id, now: now, fresh: RealPositions.matchFresh))
        // a train's fix (no date of its own): the trip's date must be today or yesterday
        let t = GPSFix(lat: 51.6, lon: 5.5, bearing: nil, at: now.addingTimeInterval(-20))
        XCTAssertNotNil(RealPositions.usable(t, tripId: id, now: now, fresh: RealPositions.matchFresh))
        XCTAssertNil(RealPositions.usable(t, tripId: "20261110_11:57_nl-OpenOV_374105578", now: now, fresh: RealPositions.matchFresh))
    }

    func test_previousFix_isKept() {
        let a = Date(timeIntervalSince1970: 1000)
        func f(_ s: TimeInterval) -> GPSFix { GPSFix(lat: 51, lon: 5, bearing: nil, at: a.addingTimeInterval(s)) }
        // a new fix: the old one becomes the one before
        XCTAssertEqual(RealPositions.previous(old: ["x": f(0)], previous: [:], new: ["x": f(30)]), ["x": f(0)])
        // the same fix again (not updated yet): the one before stays
        XCTAssertEqual(RealPositions.previous(old: ["x": f(30)], previous: ["x": f(0)], new: ["x": f(30)]), ["x": f(0)])
        // gone from the feed: forgotten; new to it: none before
        XCTAssertEqual(RealPositions.previous(old: ["x": f(0)], previous: ["x": f(-30)], new: ["y": f(30)]), [:])
        XCTAssertEqual(RealPositions.previous(old: [1: f(0)], previous: [:], new: [1: f(20)]), [1: f(0)])
    }

    func test_isRail() {
        for m in ["REGIONAL_RAIL", "HIGHSPEED_RAIL", "RAIL", "LONG_DISTANCE", "SUBURBAN", "regional_fast_rail", "NIGHT_RAIL"] {
            XCTAssertTrue(RealPositions.isRail(mode: m), m)
        }
        for m in ["BUS", "COACH", "TRAM", "SUBWAY", "METRO", "FERRY", "", "OTHER"] { XCTAssertFalse(RealPositions.isRail(mode: m), m) }
    }

    func test_trainNumber() {
        XCTAssertEqual(RealPositions.trainNumber("3561"), 3561)
        XCTAssertEqual(RealPositions.trainNumber("IC 3561"), 3561)
        XCTAssertEqual(RealPositions.trainNumber(" 2416 "), 2416)
        XCTAssertNil(RealPositions.trainNumber(""))
        XCTAssertNil(RealPositions.trainNumber("Sprinter"))
        XCTAssertNil(RealPositions.trainNumber("0"))
        XCTAssertNil(RealPositions.trainNumber("1234567"))
    }

    func test_parseTrains() throws {
        let at = Date(timeIntervalSince1970: TimeInterval(t0))
        let json = """
        {"payload":{"treinen":[
          {"treinNummer":2416,"ritId":"2416","lat":51.69,"lng":5.29,"snelheid":72.0,"richting":45.0,"horizontaleNauwkeurigheid":10,"type":"SPR","bron":"KV6"},
          {"treinNummer":"3561","lat":"51.44","lng":"5.48","snelheid":"0"},
          {"ritId":"1126","lat":51.5,"lng":5.3},
          {"treinNummer":77,"lat":51.5},
          {"treinNummer":78,"lat":0,"lng":0},
          {"lat":51.5,"lng":5.3},
          "nonsense",
          {"treinNummer":79,"lat":51.5,"lng":5.3,"snelheid":-5,"richting":400}
        ]}}
        """
        let trains = try XCTUnwrap(RealPositions.parseTrains(Data(json.utf8), at: at))
        XCTAssertEqual(Set(trains.keys), [2416, 3561, 1126, 79])
        let s = try XCTUnwrap(trains[2416])
        XCTAssertEqual(s.lat, 51.69, accuracy: 1e-9)
        XCTAssertEqual(s.lon, 5.29, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(s.speed), 20, accuracy: 1e-9, "72 km/h")
        XCTAssertEqual(s.bearing, 45)
        XCTAssertEqual(s.at, at)
        XCTAssertNil(s.startDate)
        XCTAssertEqual(trains[3561]?.speed, 0)
        XCTAssertEqual(trains[3561]?.lat ?? 0, 51.44, accuracy: 1e-9)
        XCTAssertNil(trains[1126]?.speed)
        XCTAssertNil(trains[79]?.speed)
        XCTAssertNil(trains[79]?.bearing)
        // not such an answer: nil (no train fixes)
        XCTAssertNil(RealPositions.parseTrains(Data("not json".utf8), at: at))
        XCTAssertNil(RealPositions.parseTrains(Data("{\"message\":\"Resource not found\"}".utf8), at: at))
        XCTAssertNil(RealPositions.parseTrains(Data("[1,2]".utf8), at: at))
        XCTAssertEqual(RealPositions.parseTrains(Data("{\"payload\":{\"treinen\":[]}}".utf8), at: at), [:])
    }

    func test_trainsFetchLine() {
        XCTAssertEqual(RealPositions.fetchLine(status: 200, bytes: 120_000, vehicles: 812, parseMs: 12, next: 30, feed: "ns/vehicles", unit: "trains"),
                       "ns/vehicles · 200 · 117.2 KB · 812 trains · parse 12 ms")
        XCTAssertEqual(RealPositions.fetchLine(status: 404, bytes: 0, vehicles: 0, parseMs: nil, next: 600, feed: "ns/vehicles", unit: "trains"),
                       "ns/vehicles · 404 · again in 600 s")
    }
}
