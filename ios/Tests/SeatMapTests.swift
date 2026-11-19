import XCTest

/// Friends 0.31: the seat (deck and window) in the travel state, the train's decks from NS's types, the window
/// numbers, the words, and what the friend's map frames (docs/superpowers/specs/2026-11-18-friends-design.md,
/// "As built (0.31)").
final class SeatMapTests: XCTestCase {
    private func hex(_ s: String) -> Data {
        var d = Data()
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            d.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return d
    }

    private var sam: FriendIdentity { FriendIdentity(seed: hex("000102030405060708090a0b0c0d0e0f"))! }

    /// 0.26's vector state, with a seat in the coach.
    private func vectorState() -> TravelState {
        var s = TravelState(state: "riding", mode: "train", from: .init(name: "Eindhoven Centraal", lat: 51.44306, lon: 5.47917),
                            to: .init(name: "Breda", lat: 51.59556, lon: 4.78))
        s.line = "IC"
        s.num = "3512"
        s.trip = "vector-trip-3512"
        s.eta = Date(timeIntervalSince1970: 1_800_003_780)
        s.end = Date(timeIntervalSince1970: 1_800_004_200)
        s.pos = .init(lat: 51.5112, lon: 5.2874, acc: 12, at: Date(timeIntervalSince1970: 1_799_999_990))
        s.leg = 2
        s.legs = 2
        s.coach = .init(n: 3, of: 6, front: true, at: "EHV", seat: .init(deck: "upper", w: 8, of: 11))
        return s
    }

    static let payload = "{\"b\":{\"coach\":{\"at\":\"EHV\",\"front\":true,\"n\":3,\"of\":6,\"seat\":{\"deck\":\"upper\",\"of\":11,\"w\":8}},\"end\":1800004200,\"eta\":1800003780,\"from\":{\"lat\":51.44306,\"lon\":5.47917,\"name\":\"Eindhoven Centraal\"},\"leg\":2,\"legs\":2,\"line\":\"IC\",\"mode\":\"train\",\"num\":\"3512\",\"pos\":{\"acc\":12,\"at\":1799999990,\"lat\":51.5112,\"lon\":5.2874},\"state\":\"riding\",\"to\":{\"lat\":51.59556,\"lon\":4.78,\"name\":\"Breda\"},\"trip\":\"vector-trip-3512\"},\"f\":\"3c157621a97cf055f5804a9826c6d1e1\",\"k\":\"travel\",\"n\":\"vector-31\",\"t\":1800000000,\"v\":1}"

    // MARK: the box

    func test_seatVectorByteForByte() throws {
        let p = try FriendBox.payload(.travel(vectorState()), from: sam.account, at: Date(timeIntervalSince1970: 1_800_000_000), id: "vector-31")
        XCTAssertEqual(String(decoding: p, as: UTF8.self), Self.payload)
        let (h, m) = try FriendBox.parse(Data(Self.payload.utf8))
        XCTAssertEqual(h.k, "travel")
        guard case .travel(let s) = m else { return XCTFail("not a travel box") }
        XCTAssertEqual(s.coach?.seat, TravelState.Seat(deck: "upper", w: 8, of: 11))
        XCTAssertEqual(SeatMap.label(try XCTUnwrap(s.coach)), "Coach 3 of 6 · upper deck · 8th window from the back")
    }

    /// 0.26–0.30's coach, as an older app reads it: the seat is skipped.
    private struct OldCoach: Codable, Equatable { var n: Int; var of: Int; var front: Bool; var at: String? }
    private struct OldState: Codable { var coach: OldCoach? }

    func test_olderAppsIgnoreTheSeat_andNoSeatIsLeftOut() throws {
        let j = #"{"coach":{"at":"EHV","front":true,"n":3,"of":6,"seat":{"deck":"upper","of":11,"w":8}}}"#
        let old = try FriendJSON.decoder.decode(OldState.self, from: Data(j.utf8))
        XCTAssertEqual(old.coach, OldCoach(n: 3, of: 6, front: true, at: "EHV"))
        // without a seat the coach is 0.26's, byte for byte
        let c = TravelState.Coach(n: 3, of: 6, front: true, at: "EHV")
        XCTAssertEqual(String(decoding: try FriendJSON.encoder.encode(c), as: UTF8.self), #"{"at":"EHV","front":true,"n":3,"of":6}"#)
        // an old coach reads with no seat
        let back = try FriendJSON.decoder.decode(TravelState.Coach.self, from: Data(#"{"front":false,"n":2,"of":4}"#.utf8))
        XCTAssertNil(back.seat)
        // a newer deck reads as one deck; a window outside the coach is dropped
        let odd = TravelState.Seat(deck: "middle", w: 3, of: 11)
        XCTAssertEqual(SeatMap.deck(odd), .none)
        XCTAssertNil(SeatMap.valid(.init(deck: "upper", w: 12, of: 11)))
        XCTAssertNil(SeatMap.valid(.init(deck: "upper", w: 0, of: 11)))
        XCTAssertEqual(SeatMap.label(.init(n: 3, of: 6, front: true, at: nil, seat: .init(deck: "upper", w: 0, of: 11))), "Coach 3 of 6 · front")
    }

    // MARK: the train

    func test_decksFromNSTypes() {
        XCTAssertEqual(SeatMap.doubleDeck(kind: "VIRM-6"), true)
        XCTAssertEqual(SeatMap.doubleDeck(kind: "virmm1_4"), true)
        XCTAssertEqual(SeatMap.doubleDeck(kind: "DDZ-4"), true)
        XCTAssertEqual(SeatMap.doubleDeck(kind: "SNG-3"), false)
        XCTAssertEqual(SeatMap.doubleDeck(kind: "SLT_6"), false)
        XCTAssertEqual(SeatMap.doubleDeck(kind: "nsr_flirt_4"), false)
        XCTAssertEqual(SeatMap.doubleDeck(kind: "ICM-4"), false, "the Koploper has one deck")
        XCTAssertEqual(SeatMap.doubleDeck(kind: "ICNG-8"), false)
        XCTAssertNil(SeatMap.doubleDeck(kind: ""))
        XCTAssertNil(SeatMap.doubleDeck(kind: "XYZ-9"))
        XCTAssertTrue(SeatMap.defaultDouble(line: "IC"))
        XCTAssertTrue(SeatMap.defaultDouble(line: "ICD"))
        XCTAssertFalse(SeatMap.defaultDouble(line: "SPR"))
        XCTAssertFalse(SeatMap.defaultDouble(line: nil))
    }

    func test_trainFromNSDrawing() {
        // a VIRM of 4 and an SLT of 4 (coaches listed), the front drawn on the left
        let units: [CoachMap.Unit] = [.init(x: 0, w: 0.5, cars: 4), .init(x: 0.5, w: 0.5, cars: 4)]
        let t = SeatMap.train(units: units, kinds: ["VIRM-4", "SLT-4"], totalCars: 8, dir: "left", line: "IC")
        XCTAssertTrue(t.fromNS)
        XCTAssertEqual(t.count, 8)
        XCTAssertEqual(t.coaches.map(\.double), [true, true, true, true, false, false, false, false])
        XCTAssertEqual(t.coaches.map(\.n), [1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertTrue(t.coaches.allSatisfy(\.front))
        // the front on the right: numbered from the right
        let r = SeatMap.train(units: units, kinds: ["VIRM-4", "SLT-4"], totalCars: 8, dir: "right", line: "IC")
        XCTAssertEqual(r.coaches.map(\.n), [8, 7, 6, 5, 4, 3, 2, 1])
        // no direction: from the left, not "from the front"
        let u = SeatMap.train(units: units, kinds: [], totalCars: 8, dir: nil, line: "SPR")
        XCTAssertEqual(u.coaches.map(\.n), [1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertFalse(u.coaches.contains(where: \.front))
        XCTAssertFalse(u.anyDouble, "no types: a Sprinter's single deck")
    }

    func test_trainWithoutNS() {
        // NS's length only (or nothing): its count (or 6), the front on the right; decks by the line
        let ic = SeatMap.train(units: [], kinds: [], totalCars: 0, dir: nil, line: "IC")
        XCTAssertFalse(ic.fromNS)
        XCTAssertEqual(ic.count, 6)
        XCTAssertEqual(ic.dir, "right")
        XCTAssertEqual(ic.coaches.map(\.n), [6, 5, 4, 3, 2, 1])
        XCTAssertTrue(ic.coaches.allSatisfy { $0.double && $0.front })
        let spr = SeatMap.train(units: [], kinds: [], totalCars: 4, dir: nil, line: "SPR")
        XCTAssertEqual(spr.count, 4)
        XCTAssertFalse(spr.anyDouble)
    }

    // MARK: the windows

    func test_windowsCountFromTheBack() {
        // the front on the right: the back is on the left, so the left window is the 1st from the back
        XCTAssertEqual(SeatMap.window(drawn: 0, dir: "right"), 1)
        XCTAssertEqual(SeatMap.window(drawn: 7, dir: "right"), 8)
        // the front on the left: the right window is the 1st from the back
        XCTAssertEqual(SeatMap.window(drawn: 10, dir: "left"), 1)
        XCTAssertEqual(SeatMap.window(drawn: 3, dir: "left"), 8)
        // not known: from the left
        XCTAssertEqual(SeatMap.window(drawn: 3, dir: nil), 4)
        for dir in ["left", "right", nil] as [String?] {
            for i in 0..<SeatMap.windows {
                XCTAssertEqual(SeatMap.drawnWindow(SeatMap.window(drawn: i, dir: dir), dir: dir), i)
            }
        }
        XCTAssertNil(SeatMap.drawnWindow(12, dir: "right"))
        // two rows: top the upper deck, bottom the lower; one row: no deck
        XCTAssertEqual(SeatMap.seat(drawn: 7, row: 0, double: true, dir: "right"), .init(deck: "upper", w: 8, of: 11))
        XCTAssertEqual(SeatMap.seat(drawn: 7, row: 1, double: true, dir: "right"), .init(deck: "lower", w: 8, of: 11))
        XCTAssertEqual(SeatMap.seat(drawn: 5, row: 0, double: false, dir: "left"), .init(deck: "none", w: 6, of: 11))
        XCTAssertEqual(SeatMap.row(.init(deck: "lower", w: 2, of: 11), double: true), 1)
        XCTAssertEqual(SeatMap.row(.init(deck: "lower", w: 2, of: 11), double: false), 0)
        // a friend's app that drew 22 windows: the 16th of 22 is the 8th of 11
        XCTAssertEqual(SeatMap.drawnWindow(.init(deck: "none", w: 16, of: 22), dir: "right"), 7)
    }

    func test_words() {
        XCTAssertEqual([1, 2, 3, 4, 11, 12, 13, 21, 22].map { SeatMap.ordinal($0) },
                       ["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd"])
        XCTAssertEqual(SeatMap.label(.init(n: 2, of: 4, front: true, at: nil, seat: .init(deck: "none", w: 6, of: 11))),
                       "Coach 2 of 4 · 6th window from the back")
        XCTAssertEqual(SeatMap.label(.init(n: 2, of: 4, front: false, at: "EHV", seat: .init(deck: "lower", w: 1, of: 11))),
                       "Coach 2 of 4 · lower deck · 1st window from the left")
        XCTAssertEqual(SeatMap.label(.init(n: 2, of: 4, front: true, at: nil)), "Coach 2 of 4 · front")
        XCTAssertEqual(SeatMap.spoken(coach: 3, deck: .upper, window: 8, front: true), "Coach 3, upper deck, window 8 from the back")
        XCTAssertEqual(SeatMap.spoken(coach: 2, deck: .none, window: 6, front: true), "Coach 2, window 6 from the back")
    }

    // MARK: the map (0.31's fix: a friend's page frames their trip)

    func test_friendMapFramesTheTrip() throws {
        // the test friend's pretend Sprinter, Best to 's-Hertogenbosch, half way
        var s = TravelState(state: "riding", mode: "train", from: .init(name: "Best", lat: 51.50972, lon: 5.39),
                            to: .init(name: "'s-Hertogenbosch", lat: 51.69048, lon: 5.29362))
        s.pos = .init(lat: 51.6, lon: 5.34, acc: 12, at: Date(timeIntervalSince1970: 1_800_000_000))
        let pts = MapFrame.points(s)
        XCTAssertEqual(pts.count, 3)
        // a map 1.2 times as high as wide, the sheet over its bottom 45 %
        let r = try XCTUnwrap(MapFrame.fit(pts, aspect: 1.2, cover: 0.45))
        for p in pts { XCTAssertTrue(r.contains(p), "\(p) in \(r)") }
        // the points sit in the free top part: all of them north of the line the sheet starts at
        let sheetTop: Double = r.lat + r.latDelta / 2 - r.latDelta * 0.55
        for p in pts { XCTAssertGreaterThan(p.lat, sheetTop) }
        // nowhere near Limburg (Maastricht 50.85, Sittard 51.0), and not zoomed out to the country
        XCTAssertGreaterThan(r.lat - r.latDelta / 2, 51.0)
        XCTAssertLessThan(r.latDelta, 1.0)
        // the longitude span fits the map's width (equal scale)
        let k = cos((51.50972 + 51.69048) / 2 * Double.pi / 180)
        XCTAssertEqual(r.latDelta, r.lonDelta * k * 1.2, accuracy: 1e-9)
    }

    func test_mapSkipsMissingPlaces_andZoomsOutOfAStreet() throws {
        // Home goes without a place; a 0,0 position is a missing one
        var s = TravelState(state: "waiting", mode: "bus", from: .init(name: "Veghel, Busstation", lat: 51.6167, lon: 5.5486),
                            to: .init(name: "Home"))
        s.pos = .init(lat: 0, lon: 0, acc: nil, at: Date())
        let pts = MapFrame.points(s)
        XCTAssertEqual(pts, [GeoPoint(lat: 51.6167, lon: 5.5486)])
        let r = try XCTUnwrap(MapFrame.fit(pts, aspect: 1, cover: 0))
        XCTAssertEqual(r.lat, 51.6167, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(r.latDelta * 111_320, 1600 - 1)
        XCTAssertNil(MapFrame.fit([], aspect: 1))
        XCTAssertNil(MapFrame.fit([GeoPoint(lat: .nan, lon: 5)], aspect: 1))
    }

    func test_routeIsTheBitTheyRide() {
        var s = TravelState(state: "riding", mode: "train", from: .init(name: "B", lat: 51.1, lon: 5.1), to: .init(name: "D", lat: 51.3, lon: 5.3))
        s.pos = .init(lat: 51.2, lon: 5.2, acc: nil, at: Date())
        let path: [GeoPoint] = (0...5).map { GeoPoint(lat: 51.0 + Double($0) * 0.1, lon: 5.0 + Double($0) * 0.1) }
        XCTAssertEqual(MapFrame.route(s, path: path), Array(path[1...3]))
        // no shape: from, where they are, to
        XCTAssertEqual(MapFrame.route(s, path: []), [GeoPoint(lat: 51.1, lon: 5.1), GeoPoint(lat: 51.2, lon: 5.2), GeoPoint(lat: 51.3, lon: 5.3)])
        // nothing to draw with one point
        let lone = TravelState(state: "riding", mode: "bus", from: .init(name: "Here"), to: .init(name: "Home"))
        XCTAssertEqual(MapFrame.route(lone, path: []), [])
    }
}
