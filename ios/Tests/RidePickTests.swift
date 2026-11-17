import XCTest

/// The "I'm actually on…" sheet (0.20.5): which vehicles it lists, in which order, what it says, and the lock after a
/// pick by hand.
final class RidePickTests: XCTestCase {
    private let t0 = Fx.t0
    private let here = Fx.east(1000)

    private func evidence(offset: Double, crossTrack: Double = 0, gps: Bool = false) -> Evidence {
        var e = Evidence(fixes: 6, span: 30, crossTrack: crossTrack, accuracy: 20, shaped: true, progress: 300, offset: offset,
                         drift: 0, yourSpeed: 10, itsSpeed: 10, steady: true)
        e.gps = gps
        return e
    }

    private func judged(_ v: VehicleTrack, _ e: Evidence?, passed: Bool) -> Judgement {
        Judgement(id: v.tripId, line: v.line, isTrain: v.isTrain, realTime: v.realTime, evidence: e,
                  result: passed ? .success(10) : .failure(.offItsPath))
    }

    private func bus(_ id: String, line: String = "306", at m0: Double, north: Double = 0) -> VehicleTrack {
        Fx.track(id, line: line, train: false, path: Fx.road(north: north), at: m0, speed: 10)
    }

    private func gps(_ v: VehicleTrack, at p: GeoPoint) -> VehicleTrack {
        var w = v
        w.gps = VehicleGPS(fix: GPSFix(lat: p.lat, lon: p.lon, bearing: 90, at: t0.addingTimeInterval(-20)))
        return w
    }

    /// The one moving with you, one by its own GPS 120 m away, one by its times 300 m away: listed, moving with you
    /// first, then the nearest. One by its times 3 km away isn't, unless it's the one shown or a candidate.
    func test_gatherAndOrder() {
        let mine = bus("trip-0001", at: 1000)                                    // by its times right with you
        let byGPS = gps(bus("trip-0002", line: "305", at: 3000), at: Fx.east(1120))  // its times are far, its GPS is near
        let near = bus("trip-0003", line: "158", at: 1300, north: 0)             // 300 m on by its times
        let far = bus("trip-0004", line: "90", at: 4000)                          // 3 km on
        let shown = bus("trip-0005", line: "305", at: 4500)                       // far, but the one the app shows
        let cand = bus("trip-0006", line: "306", at: 5000)                        // far, but in the running
        let j = [judged(mine, evidence(offset: 40), passed: true)]
        let rows = RidePick.gather(here: here, now: t0, tracks: [far, near, byGPS, mine, shown, cand, mine], judged: j,
                                   candidates: ["trip-0006"], current: "trip-0005")
        XCTAssertEqual(rows.map(\.tripId), ["trip-0001", "trip-0002", "trip-0003", "trip-0005", "trip-0006"])
        XCTAssertTrue(rows[0].moves)
        XCTAssertEqual(try XCTUnwrap(rows[0].metres), 40, accuracy: 0.5)
        XCTAssertFalse(rows[0].byGPS)
        XCTAssertTrue(rows[1].byGPS)
        XCTAssertEqual(try XCTUnwrap(rows[1].metres), 120, accuracy: 2)
        XCTAssertEqual(try XCTUnwrap(rows[2].metres), 300, accuracy: 2)
        XCTAssertFalse(rows[2].byGPS)
        XCTAssertTrue(rows[3].current)
        XCTAssertFalse(rows[3].candidate)
        XCTAssertTrue(rows[4].candidate)
        XCTAssertFalse(rows.map(\.tripId).contains("trip-0004"))
    }

    /// Judged by its own GPS: how far is along and across its road (not straight to an old fix); judged by its times:
    /// the same from the evidence. A vehicle that moves with you is listed however far its times say it is.
    func test_distanceFromEvidence() {
        let a = gps(bus("trip-0001", at: 3000), at: Fx.east(1900))
        let b = bus("trip-0002", at: 3000)
        let j = [judged(a, evidence(offset: 30, crossTrack: 40, gps: true), passed: false),
                 judged(b, evidence(offset: 2500), passed: true)]
        let rows = RidePick.gather(here: here, now: t0, tracks: [a, b], judged: j, candidates: [], current: nil)
        XCTAssertEqual(rows.map(\.tripId), ["trip-0002", "trip-0001"])
        XCTAssertEqual(try XCTUnwrap(rows[1].metres), 50, accuracy: 0.01)
        XCTAssertTrue(rows[1].byGPS)
        XCTAssertEqual(try XCTUnwrap(rows[0].metres), 2500, accuracy: 0.01)
    }

    /// Nearest first; one whose distance isn't known last; the one shown before another just as near; then by id.
    func test_rank() {
        func row(_ id: String, _ m: Double?, moves: Bool = false, current: Bool = false) -> RidePick.Row {
            RidePick.Row(tripId: id, line: "1", isTrain: false, metres: m, byGPS: false, moves: moves, current: current, candidate: false)
        }
        let r = RidePick.rank([row("e", nil), row("d", 100), row("c", 100, current: true), row("b", 50), row("a", 900, moves: true)])
        XCTAssertEqual(r.map(\.tripId), ["a", "b", "c", "d", "e"])
    }

    /// At most `limit` rows: the one shown and the candidates always among them.
    func test_limitKeepsShownAndCandidates() {
        var tracks: [VehicleTrack] = []
        for k in 0..<12 { tracks.append(bus(String(format: "trip-%04d", k), at: 1000 + Double(k) * 40)) }
        tracks.append(bus("trip-shown", at: 6000))
        tracks.append(bus("trip-cand", at: 6500))
        let rows = RidePick.gather(here: here, now: t0, tracks: tracks, judged: [], candidates: ["trip-cand"], current: "trip-shown", limit: 5)
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows.map(\.tripId), ["trip-0000", "trip-0001", "trip-0002", "trip-shown", "trip-cand"])
    }

    /// Where its times put it: along the piece by time, at the start up to 30 s before it leaves, at the stop between
    /// two pieces, nowhere long before or after.
    func test_timesPoint() throws {
        let a = TimedPiece(departure: t0, arrival: t0 + 100, path: [Fx.east(0), Fx.east(1000)])
        let b = TimedPiece(departure: t0 + 160, arrival: t0 + 260, path: [Fx.east(1000), Fx.east(2000)])
        let v = VehicleTrack(tripId: "x", line: "1", isTrain: false, realTime: true, pieces: [b, a])
        XCTAssertEqual(Geo.metres(try XCTUnwrap(RidePick.timesPoint(v, at: t0 + 25)), Fx.east(250)), 0, accuracy: 1)
        XCTAssertEqual(Geo.metres(try XCTUnwrap(RidePick.timesPoint(v, at: t0 + 130)), Fx.east(1000)), 0, accuracy: 1)
        XCTAssertEqual(Geo.metres(try XCTUnwrap(RidePick.timesPoint(v, at: t0 + 210)), Fx.east(1500)), 0, accuracy: 1)
        XCTAssertEqual(Geo.metres(try XCTUnwrap(RidePick.timesPoint(v, at: t0 - 20)), Fx.east(0)), 0, accuracy: 1)
        XCTAssertEqual(Geo.metres(try XCTUnwrap(RidePick.timesPoint(v, at: t0 + 280)), Fx.east(2000)), 0, accuracy: 1)
        XCTAssertNil(RidePick.timesPoint(v, at: t0 - 60))
        XCTAssertNil(RidePick.timesPoint(v, at: t0 + 400))
        XCTAssertNil(RidePick.timesPoint(VehicleTrack(tripId: "y", line: "1", isTrain: false, realTime: true, pieces: []), at: t0))
    }

    func test_words() {
        XCTAssertEqual(RidePick.title(line: "306", isTrain: false, headsign: "Uden"), "Bus 306 to Uden")
        XCTAssertEqual(RidePick.title(line: "IC", isTrain: true, headsign: "Breda"), "Intercity to Breda")
        XCTAssertEqual(RidePick.title(line: "SPR", isTrain: true, headsign: " "), "Sprinter")
        XCTAssertEqual(RidePick.title(line: "", isTrain: false, headsign: ""), "Bus ?")
        XCTAssertEqual(RidePick.detail(metres: 118, byGPS: true), "120 m from you · GPS")
        XCTAssertEqual(RidePick.detail(metres: 1430, byGPS: false), "1.4 km from you · by its times")
        XCTAssertEqual(RidePick.detail(metres: nil, byGPS: false), "by its times")
        XCTAssertEqual(RidePick.detail(metres: .nan, byGPS: true), "GPS")
        XCTAssertEqual(RidePick.stillOn(line: "306", isTrain: false), "Still on bus 306?")
        XCTAssertEqual(RidePick.stillOn(line: "IC", isTrain: true), "Still on the Intercity?")
        XCTAssertEqual(RidePick.joined([]), "")
        XCTAssertEqual(RidePick.joined(["a"]), "a")
        XCTAssertEqual(RidePick.joined(["a", "b", "c"]), "a, b and c")
        XCTAssertEqual(RidePick.doesntGo("Bus 306", to: "BUas", getOff: "Uden, Centrum", then: ["bus 3 at 08:12"], end: "BUas at 08:31"),
                       "Bus 306 doesn’t go to BUas: you’d get off at Uden, Centrum, then bus 3 at 08:12. BUas at 08:31.")
        XCTAssertEqual(RidePick.doesntGo("Bus 306", to: "BUas", getOff: "Uden", then: [], end: nil),
                       "Bus 306 doesn’t go to BUas: you’d get off at Uden.")
        XCTAssertTrue(RidePick.doesntGo("Bus 306", to: "BUas", getOff: nil, then: [], end: nil).hasPrefix("Bus 306 doesn’t go to BUas, and no way on"))
    }

    // MARK: the lock after a pick by hand

    /// No lock, or one from another leg: the matcher may switch by itself. A lock on this leg: never.
    func test_lockHoldsForItsLeg() {
        XCTAssertTrue(HandLock.autoSwitch(nil, leg: 0))
        XCTAssertFalse(HandLock.autoSwitch(HandLock(tripId: "a", leg: 1), leg: 1))
        XCTAssertFalse(HandLock.autoSwitch(HandLock(tripId: nil, leg: 0), leg: 0))      // "none of these" locks too
        XCTAssertTrue(HandLock.autoSwitch(HandLock(tripId: "a", leg: 0), leg: 1))
    }

    /// Off its road (300 m from a bus's) look after look: asked once after 3 minutes, never a switch; asked once only.
    func test_asksOnceAfterThreeMinutesOff() {
        var lock = HandLock(tripId: "a", leg: 0)
        XCTAssertEqual(lock.look(metres: 40, isTrain: false, now: t0), .keep)
        XCTAssertNil(lock.offSince)
        for s in stride(from: 30.0, through: 180, by: 30) {
            XCTAssertEqual(lock.look(metres: 420, isTrain: false, now: t0 + s), .keep, "at \(s) s")
        }
        XCTAssertEqual(lock.offFor(now: t0 + 180), 150)
        XCTAssertEqual(lock.look(metres: 420, isTrain: false, now: t0 + 210), .ask)
        XCTAssertTrue(lock.asked)
        XCTAssertEqual(lock.look(metres: 900, isTrain: false, now: t0 + 400), .keep)
        XCTAssertEqual(lock.look(metres: 900, isTrain: false, now: t0 + 900), .keep)
    }

    /// Back on its road the time starts again; a look whose road isn't known says nothing; a train has 700 m.
    func test_offTimeRestartsOnItsRoad() {
        var lock = HandLock(tripId: "a", leg: 0)
        _ = lock.look(metres: 400, isTrain: false, now: t0)
        _ = lock.look(metres: 400, isTrain: false, now: t0 + 150)
        XCTAssertEqual(lock.look(metres: 100, isTrain: false, now: t0 + 170), .keep)        // back on it
        XCTAssertNil(lock.offSince)
        _ = lock.look(metres: 400, isTrain: false, now: t0 + 200)
        XCTAssertEqual(lock.look(metres: nil, isTrain: false, now: t0 + 300), .keep)        // not known: no change
        XCTAssertEqual(lock.offSince, t0 + 200)
        XCTAssertEqual(lock.look(metres: .nan, isTrain: false, now: t0 + 350), .keep)
        XCTAssertEqual(lock.look(metres: 400, isTrain: false, now: t0 + 379), .keep)
        XCTAssertEqual(lock.look(metres: 400, isTrain: false, now: t0 + 380), .ask)

        var train = HandLock(tripId: "ic", leg: 1)
        XCTAssertEqual(train.look(metres: 600, isTrain: true, now: t0), .keep)
        XCTAssertEqual(train.look(metres: 600, isTrain: true, now: t0 + 400), .keep)        // within 700 m: on its line
        XCTAssertNil(train.offSince)
        _ = train.look(metres: 800, isTrain: true, now: t0 + 400)
        XCTAssertEqual(train.look(metres: 800, isTrain: true, now: t0 + 580), .ask)
    }

    /// "Yes, still on it": not asked again for this pick. "None of these" has no road: it never asks.
    func test_confirmedAndNoneNeverAsk() {
        var lock = HandLock(tripId: "a", leg: 0)
        _ = lock.look(metres: 500, isTrain: false, now: t0)
        lock.confirmed()
        XCTAssertNil(lock.offSince)
        _ = lock.look(metres: 500, isTrain: false, now: t0 + 10)
        XCTAssertEqual(lock.look(metres: 500, isTrain: false, now: t0 + 600), .keep)

        var none = HandLock(tripId: nil, leg: 0)
        XCTAssertEqual(none.look(metres: 5000, isTrain: false, now: t0), .keep)
        XCTAssertEqual(none.look(metres: 5000, isTrain: false, now: t0 + 600), .keep)
        XCTAssertNil(none.offSince)
    }

    /// The lock never turns the matcher's ride into another one: whatever the looks, they only keep or ask.
    func test_lookNeverSwitches() {
        var lock = HandLock(tripId: "a", leg: 0)
        var asks = 0
        for k in 0..<100 {
            let m: Double? = k % 7 == 0 ? nil : Double((k * 137) % 1500)
            if lock.look(metres: m, isTrain: k % 2 == 0, now: t0 + Double(k) * 30) == .ask { asks += 1 }
        }
        XCTAssertLessThanOrEqual(asks, 1)
    }
}
