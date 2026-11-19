import XCTest

/// 0.32's GPS points during rides: what a point looks like when it leaves the phone, what's trimmed from every trip and
/// near your places, what goes in one upload, the put's shape, and the one-time question.
final class GPSShareTests: XCTestCase {
    private let t0 = Fx.t0

    /// A point `m` metres east (and `north` metres north) of the test railway's start, `s` seconds after t0.
    private func at(_ m: Double, north: Double = 0, s: Double, speed: Double = 12) -> SharedFix {
        let p = Fx.east(m, north: north)
        return GPSShareRules.fix(at: t0 + s, lat: p.lat, lon: p.lon, accuracy: 8, speed: speed, course: 90,
                                 leg: "1/2", vehicle: "bus 305·7821", ride: "a1b2c3d4")!
    }

    /// A straight trip east: a point every 30 m (every 3 s at 10 m/s), `metres` long.
    private func trip(_ metres: Double, from start: Double = 0) -> [SharedFix] {
        stride(from: 0.0, through: metres, by: 30).map { at(start + $0, s: $0 / 10) }
    }

    // MARK: one point

    func test_aPointIsRoundedAndTagged() {
        let f = GPSShareRules.fix(at: Date(timeIntervalSince1970: 1_763_534_038.24), lat: 51.690123456, lon: 5.298714999,
                                  accuracy: 8.4, speed: 12.36, course: 87.4, leg: "1/3", vehicle: "bus 305·7821", ride: "3f9a1c2e")!
        XCTAssertEqual(f.t, 1_763_534_038.2)
        XCTAssertEqual(f.lat, 51.69012)
        XCTAssertEqual(f.lon, 5.29871)
        XCTAssertEqual(f.acc, 8)
        XCTAssertEqual(f.spd, 12.4)
        XCTAssertEqual(f.crs, 87)
        XCTAssertEqual(f.leg, "1/3")
        XCTAssertEqual(f.veh, "bus 305·7821")
        // as it goes: 5 decimals, no more
        let json = String(decoding: try! JSONEncoder().encode(f), as: UTF8.self)
        XCTAssertTrue(json.contains("51.69012") && !json.contains("51.690123"), json)
        // the sample Settings shows is a real point's shape
        let sample = try! JSONDecoder().decode(SharedFix.self, from: Data(ShareAsk.sampleFix.utf8))
        XCTAssertEqual(sample, f)
    }

    func test_unknownSpeedAndCourseAreMinusOne() {
        let f = GPSShareRules.fix(at: t0, lat: 51.5, lon: 5.1, accuracy: 20, speed: -1, course: -1, leg: nil, vehicle: nil, ride: nil)!
        XCTAssertEqual(f.spd, -1)
        XCTAssertEqual(f.crs, -1)
        XCTAssertNil(f.veh)
    }

    func test_aRoughOrBrokenFixIsntKept() {
        XCTAssertNil(GPSShareRules.fix(at: t0, lat: 51.5, lon: 5.1, accuracy: 151, speed: 3, course: 0, leg: nil, vehicle: nil, ride: nil))
        XCTAssertNil(GPSShareRules.fix(at: t0, lat: 51.5, lon: 5.1, accuracy: -1, speed: 3, course: 0, leg: nil, vehicle: nil, ride: nil))
        XCTAssertNil(GPSShareRules.fix(at: t0, lat: .nan, lon: 5.1, accuracy: 5, speed: 3, course: 0, leg: nil, vehicle: nil, ride: nil))
        XCTAssertNil(GPSShareRules.fix(at: t0, lat: 0, lon: 0, accuracy: 5, speed: 3, course: 0, leg: nil, vehicle: nil, ride: nil))
        XCTAssertNil(GPSShareRules.fix(at: Date(timeIntervalSince1970: 0), lat: 51.5, lon: 5.1, accuracy: 5, speed: 3, course: 0,
                                       leg: nil, vehicle: nil, ride: nil))
    }

    func test_tagsAreTheLogLinesOwn() {
        XCTAssertEqual(GPSShareRules.leg(index: 0, count: 3), "1/3")
        XCTAssertEqual(GPSShareRules.leg(index: 2, count: 3), "3/3")
        XCTAssertEqual(GPSShareRules.leg(index: 5, count: 3), "3/3")
        XCTAssertNil(GPSShareRules.leg(index: 0, count: 0))
        // the vehicle as FieldFormat writes it in the ride lines
        let v = FieldFormat.vehicle(line: "305", tripId: "trip-xyz-7821", isTrain: false)
        XCTAssertEqual(GPSShareRules.tag(v), "bus 305·7821")
        XCTAssertEqual(GPSShareRules.tag(FieldFormat.vehicle(line: "?", tripId: "a1b2", isTrain: true)), "train ?·a1b2")
        // what the relay wouldn't take becomes "-", and it's at most 40 characters
        XCTAssertEqual(GPSShareRules.tag("bus N3&4·1234"), "bus N3-4·1234")
        XCTAssertEqual(GPSShareRules.tag(String(repeating: "x", count: 60))?.count, 40)
        XCTAssertNil(GPSShareRules.tag("   "))
    }

    func test_everyFewSeconds() {
        let a = at(0, s: 0)
        XCTAssertTrue(GPSShareRules.keep(a, after: nil))
        XCTAssertFalse(GPSShareRules.keep(at(10, s: 1), after: a))
        XCTAssertFalse(GPSShareRules.keep(at(20, s: 2.9), after: a))
        XCTAssertTrue(GPSShareRules.keep(at(30, s: 3), after: a))
        XCTAssertTrue(GPSShareRules.keep(at(30, s: -5), after: a), "a clock that stepped back starts again")
    }

    // MARK: what's trimmed

    func test_theFirstAndLast500mOfATripGo() {
        let fixes = trip(3000)
        let kept = GPSShareRules.trimmed(fixes)
        XCTAssertFalse(kept.isEmpty)
        let first = fixes.first!.point, last = fixes.last!.point
        for f in kept {
            XCTAssertGreaterThan(Geo.metres(f.point, first), 500)
            XCTAssertGreaterThan(Geo.metres(f.point, last), 500)
        }
        // about the middle 2 km is left
        let span = Geo.metres(kept.first!.point, kept.last!.point)
        XCTAssertEqual(span, 2000, accuracy: 70)
    }

    func test_aShortTripSendsNothing() {
        XCTAssertTrue(GPSShareRules.trimmed(trip(900)).isEmpty)
        XCTAssertTrue(GPSShareRules.trimmed(trip(1000)).isEmpty)
        XCTAssertTrue(GPSShareRules.trimmed([]).isEmpty)
        XCTAssertTrue(GPSShareRules.trimmed([at(0, s: 0)]).isEmpty)
    }

    func test_aTripThatComesBackNearItsStartKeepsAway() {
        // 2 km east, then back to 100 m from where it started: nothing within 500 m of either end goes
        var fixes = trip(2000)
        fixes += stride(from: 2000.0, through: 100, by: -30).enumerated().map { i, m in at(m, north: 40, s: 200 + Double(i) * 3) }
        let kept = GPSShareRules.trimmed(fixes)
        XCTAssertFalse(kept.isEmpty)
        for f in kept {
            XCTAssertGreaterThan(Geo.metres(f.point, fixes.first!.point), 500)
            XCTAssertGreaterThan(Geo.metres(f.point, fixes.last!.point), 500)
        }
    }

    func test_jitterWhileStandingDoesntCountAsTravelled() {
        // 10 minutes standing at the start with 20 m of jitter: lots of "distance", but all of it within 500 m of the start
        var fixes = (0..<200).map { i in at(Double(i % 2) * 20, s: Double(i) * 3) }
        fixes += trip(3000).map { var f = $0; f.t += 600; return f }
        for f in GPSShareRules.trimmed(fixes) { XCTAssertGreaterThan(Geo.metres(f.point, fixes.first!.point), 500) }
    }

    func test_nothingNearYourPlaces() {
        let fixes = trip(6000)
        let home = Fx.east(3000, north: 200)
        let kept = GPSShareRules.outsideZones(fixes, zones: [home])
        XCTAssertLessThan(kept.count, fixes.count)
        for f in kept { XCTAssertGreaterThan(Geo.metres(f.point, home), 500) }
        // a place that isn't set (0, 0) keeps nothing away
        XCTAssertEqual(GPSShareRules.outsideZones(fixes, zones: [GeoPoint(lat: 0, lon: 0)]).count, fixes.count)
    }

    func test_aFinishedTripIsTrimmedThenKeptAwayFromPlaces() {
        let ride = GPSShareRide(ride: "a1b2c3d4", fixes: trip(6000))
        let school = Fx.east(3000)
        let out = GPSShareRules.finished(ride, zones: [school])
        XCTAssertFalse(out.isEmpty)
        for f in out {
            XCTAssertGreaterThan(Geo.metres(f.point, school), 500)
            XCTAssertGreaterThan(Geo.metres(f.point, ride.fixes.first!.point), 500)
            XCTAssertGreaterThan(Geo.metres(f.point, ride.fixes.last!.point), 500)
        }
        // oldest first
        XCTAssertEqual(out.map(\.t), out.map(\.t).sorted())
    }

    // MARK: kept on the phone

    func test_theQueueKeepsATripThenItsTrimmedPoints() {
        var q = GPSShareQueue()
        var made = 0
        for f in trip(3000) { q.heard(f, newRide: { made += 1; return "0000000\(made)" }) }
        XCTAssertEqual(made, 1, "one trip, one id")
        XCTAssertEqual(q.current?.fixes.count, trip(3000).count)
        XCTAssertTrue(q.current!.fixes.allSatisfy { $0.ride == "00000001" })
        XCTAssertTrue(q.ready.isEmpty, "nothing goes before the trip ends")
        q.finishRide(zones: [])
        XCTAssertNil(q.current)
        XCTAssertFalse(q.ready.isEmpty)
        let n = q.ready.count
        q.sent(2)
        XCTAssertEqual(q.ready.count, n - 2)
        q.sent(10_000)
        XCTAssertTrue(q.ready.isEmpty)
        // a new trip gets a new id
        q.heard(at(0, s: 1000), newRide: { "bbbbbbbb" })
        XCTAssertEqual(q.current?.ride, "bbbbbbbb")
        // kept as it's saved
        let back = GPSShareQueue.decode(try! JSONEncoder().encode(q))
        XCTAssertEqual(back, q)
        XCTAssertEqual(GPSShareQueue.decode(Data("nonsense".utf8)), GPSShareQueue())
        XCTAssertEqual(GPSShareQueue.decode(nil), GPSShareQueue())
    }

    func test_theQueueKeepsEveryFewSecondsAndHasCaps() {
        var q = GPSShareQueue()
        for i in 0..<30 { q.heard(at(Double(i), s: Double(i)), newRide: { "a" }) }
        XCTAssertEqual(q.current?.fixes.count, 10, "one every 3 s of 30 s")
        var long = GPSShareQueue()
        for i in 0..<(GPSShareRules.maxRide + 50) { long.heard(at(Double(i), s: Double(i) * 3), newRide: { "a" }) }
        XCTAssertEqual(long.current?.fixes.count, GPSShareRules.maxRide)
        var full = GPSShareQueue(current: nil, ready: Array(repeating: at(0, s: 0), count: GPSShareRules.maxReady))
        full.current = GPSShareRide(ride: "bbbbbbbb", fixes: trip(3000).map { f in var g = f; g.ride = "bbbbbbbb"; return g })
        full.finishRide(zones: [])
        XCTAssertEqual(full.ready.count, GPSShareRules.maxReady, "the oldest go")
        XCTAssertEqual(full.ready.last?.ride, "bbbbbbbb")
        XCTAssertEqual(full.ready.first?.ride, "a1b2c3d4")
    }

    // MARK: one upload

    func test_aBatchFitsItsBudget() {
        let fixes = trip(6000)
        let one = GPSShareRules.size(fixes[0])
        XCTAssertGreaterThan(one, 60)
        XCTAssertLessThan(one, 200)
        let ten = fixes.prefix(10).map { GPSShareRules.size($0) }.reduce(0, +)
        let b = GPSShareRules.batch(fixes, budget: ten + 5)
        XCTAssertEqual(b.fixes.count, 10)
        XCTAssertTrue(b.more)
        XCTAssertEqual(b.bytes, ten)
        let all = GPSShareRules.batch(fixes, budget: 10_000_000)
        XCTAssertEqual(all.fixes.count, fixes.count)
        XCTAssertFalse(all.more)
        XCTAssertTrue(GPSShareRules.batch(fixes, budget: 0).fixes.isEmpty)
        // a whole day's commute fits one upload
        let hour = (0..<1200).map { at(Double($0) * 30, s: Double($0) * 3) }
        XCTAssertFalse(GPSShareRules.batch(hour, budget: GPSShareRules.perUpload).more)
    }

    private func state(day: String = "2027-01-15", fixBytes: Int? = nil) -> LogShareState {
        var s = LogShareState(install: String(repeating: "a", count: 32), secret: String(repeating: "b", count: 64), through: t0)
        s.day = day
        s.fixBytesToday = fixBytes
        return s
    }

    func test_pointsHaveTheirOwnDailyBudget() {
        let today = "2027-01-15"
        XCTAssertEqual(GPSShareRules.budget(state(), today: today), 600 * 1024)
        XCTAssertEqual(GPSShareRules.budget(state(fixBytes: GPSShareRules.perDay - 100), today: today), 100)
        XCTAssertEqual(GPSShareRules.budget(state(fixBytes: GPSShareRules.perDay), today: today), 0)
        XCTAssertEqual(GPSShareRules.budget(state(day: "2027-01-14", fixBytes: GPSShareRules.perDay), today: today), 600 * 1024)
        var s = LogShareRules.sent(state(fixBytes: 1000), LogShareBatch(), fixBytes: 500, now: t0, today: today)
        XCTAssertEqual(s.fixBytesToday, 1500)
        XCTAssertEqual(s.sentToday, 0)
        XCTAssertTrue(s.sentEver)
        s = LogShareRules.sent(s, LogShareBatch(), fixBytes: 200, now: t0 + 90_000, today: "2027-01-16")
        XCTAssertEqual(s.fixBytesToday, 200, "a new day starts at 0")
    }

    func test_dueWithPointsWaiting() {
        let today = "2027-01-15"
        var used = state()
        used.sentToday = LogShareRules.perDay
        // the day's lines used up: not due for lines, but due when points wait (and their own budget is left)
        XCTAssertFalse(LogShareRules.due(used, enabled: true, trigger: .tripEnded, tripRunning: false, lowPower: false, now: t0, today: today))
        XCTAssertTrue(LogShareRules.due(used, enabled: true, trigger: .tripEnded, tripRunning: false, lowPower: false, now: t0, today: today,
                                        fixes: true))
        used.fixBytesToday = GPSShareRules.perDay
        XCTAssertFalse(LogShareRules.due(used, enabled: true, trigger: .tripEnded, tripRunning: false, lowPower: false, now: t0, today: today,
                                         fixes: true))
        // never during a trip, nor in Low Power Mode
        XCTAssertFalse(LogShareRules.due(state(), enabled: true, trigger: .tripEnded, tripRunning: true, lowPower: false, now: t0, today: today,
                                         fixes: true))
        XCTAssertFalse(LogShareRules.due(state(), enabled: true, trigger: .tripEnded, tripRunning: false, lowPower: true, now: t0, today: today,
                                         fixes: true))
    }

    func test_aStateSavedBeforePointsStillReads() {
        let old = #"{"install":"\#(String(repeating: "a", count: 32))","secret":"\#(String(repeating: "b", count: 64))","day":"2027-01-15","sentToday":10,"sentEver":true}"#
        let s = LogShareState.decode(Data(old.utf8))
        XCTAssertNotNil(s)
        XCTAssertNil(s?.fixBytesToday)
        XCTAssertEqual(s?.sentToday, 10)
    }

    func test_thePutsShape() throws {
        let s = state()
        var put = LogSharePut(install: s.install, secret: s.secret, app: "0.32.0 (123)", lines: ["a line"])
        var o = try JSONSerialization.jsonObject(with: JSONEncoder().encode(put)) as! [String: Any]
        XCTAssertEqual(Set(o.keys), ["install", "secret", "app", "lines"], "without points: as before")
        put.fixes = [at(0, s: 0)]
        put.tz = 3600
        o = try JSONSerialization.jsonObject(with: JSONEncoder().encode(put)) as! [String: Any]
        XCTAssertEqual(Set(o.keys), ["install", "secret", "app", "lines", "fixes", "tz"])
        let f = (o["fixes"] as! [[String: Any]])[0]
        XCTAssertEqual(Set(f.keys), ["t", "lat", "lon", "acc", "spd", "crs", "leg", "veh", "ride"])
        XCTAssertEqual(o["tz"] as? Int, 3600)
    }

    func test_aRideIdIs8Hex() {
        XCTAssertEqual(GPSShareRules.rideId(random: { Array(repeating: 0xAB, count: $0) }), "abababab")
        XCTAssertEqual(GPSShareRules.rideId().count, 8)
    }

    // MARK: the question

    func test_theCardShowsOnceAfterASetupThatDidntAsk() {
        XCTAssertTrue(ShareAsk.showCard(setupDone: true, asked: false, testLive: false))
        XCTAssertFalse(ShareAsk.showCard(setupDone: true, asked: true, testLive: false), "answered or put away")
        XCTAssertFalse(ShareAsk.showCard(setupDone: false, asked: false, testLive: false), "the setup asks itself")
        XCTAssertFalse(ShareAsk.showCard(setupDone: true, asked: false, testLive: true), "not in a test setup")
    }

    func test_theWordsNameWhoGetsIt() {
        XCTAssertEqual(Maker.name, "Nana")
        for t in [ShareAsk.intro, ShareAsk.who] { XCTAssertTrue(t.contains(Maker.name), t) }
        XCTAssertTrue(ShareAsk.fixesText.contains("500 m"))
        XCTAssertTrue(ShareAsk.who.contains("Delete what I sent"))
    }

    func test_theSetupsStepIsOffUnlessTurnedOn() {
        let d = SetupDraft.empty
        XCTAssertFalse(d.shareLogs)
        XCTAssertFalse(d.shareFixes)
        XCTAssertEqual(SetupLogic.shareWords(d), "Nothing shared")
        var both = d
        both.shareLogs = true; both.shareFixes = true
        XCTAssertEqual(SetupLogic.shareWords(both), "Ride logs and GPS points during rides")
        XCTAssertEqual(SetupStep.improve.title, "Help improve Haltewekker")
    }
}
