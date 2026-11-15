import XCTest

final class VehicleMatchTests: XCTestCase {
    private let t0 = Fx.t0

    // MARK: - Positions by its times

    func test_tolerancePinsToday() {
        XCTAssertEqual(VehicleMatch.tolerance(isTrain: true, speed: 30), 1800)
        XCTAssertEqual(VehicleMatch.tolerance(isTrain: false, speed: 30), 1000)
        XCTAssertEqual(VehicleMatch.tolerance(isTrain: true, speed: 5), 600)
        XCTAssertEqual(VehicleMatch.tolerance(isTrain: false, speed: 5), 400)
    }

    func test_timePosition() throws {
        let a = TimedPiece(departure: t0, arrival: t0 + 60, path: [Fx.east(0), Fx.east(1000)])
        let b = TimedPiece(departure: t0 + 90, arrival: t0 + 150, path: [Fx.east(1000), Fx.east(2000)])
        let v = VehicleTrack(tripId: "v", line: "IC", isTrain: true, realTime: true, pieces: [a, b])
        XCTAssertEqual(try XCTUnwrap(VehicleMatch.timePosition(v, at: t0 + 30)), 500, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(VehicleMatch.timePosition(v, at: t0 + 75)), 1000, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(VehicleMatch.timePosition(v, at: t0 + 120)), 1500, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(VehicleMatch.timePosition(v, at: t0 + 170)), 2000, accuracy: 0.5)
        XCTAssertNil(VehicleMatch.timePosition(v, at: t0 + 200))
        XCTAssertNil(VehicleMatch.timePosition(v, at: t0 - 40))
    }

    /// Review Focus 1: a piece with departure == arrival (minute-rounded times) gives no NaN and no division by zero.
    func test_zeroDurationPiece() throws {
        let a = TimedPiece(departure: t0, arrival: t0 + 60, path: [Fx.east(0), Fx.east(1000)])
        let b = TimedPiece(departure: t0 + 60, arrival: t0 + 60, path: [Fx.east(1000), Fx.east(1500)])
        let c = TimedPiece(departure: t0 + 60, arrival: t0 + 120, path: [Fx.east(1500), Fx.east(2500)])
        let v = VehicleTrack(tripId: "z", line: "IC", isTrain: true, realTime: true, pieces: [a, b, c])

        let at60 = try XCTUnwrap(VehicleMatch.timePosition(v, at: t0 + 60))
        XCTAssertTrue(at60.isFinite)
        XCTAssertGreaterThanOrEqual(at60, 1000 - 0.01)
        XCTAssertLessThanOrEqual(at60, 1500 + 0.01)
        XCTAssertEqual(try XCTUnwrap(VehicleMatch.timePosition(v, at: t0 + 90)), 2000, accuracy: 1)

        let e = try XCTUnwrap(VehicleMatch.evidence(Fx.fixes(from: 1000, speed: 25, count: 15, start: t0 + 40), v))
        for x in [e.span, e.crossTrack, e.accuracy, e.progress, e.offset, e.drift, e.yourSpeed, e.itsSpeed] {
            XCTAssertTrue(x.isFinite, "\(e)")
        }

        // When the piece that takes no time is the one it's on, it sits at that piece's end.
        let ends = VehicleTrack(tripId: "e", line: "IC", isTrain: true, realTime: true, pieces: [a, b])
        XCTAssertEqual(try XCTUnwrap(VehicleMatch.timePosition(ends, at: t0 + 60)), 1500, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(VehicleMatch.timePosition(ends, at: t0 + 80)), 1500, accuracy: 1)
        let f = try XCTUnwrap(VehicleMatch.evidence(Fx.fixes(from: 1000, speed: 25, count: 15, start: t0 + 40), ends))
        for x in [f.span, f.crossTrack, f.accuracy, f.progress, f.offset, f.drift, f.yourSpeed, f.itsSpeed] {
            XCTAssertTrue(x.isFinite, "\(f)")
        }
    }

    // MARK: - The hard tests, per scenario

    /// S1: on the train; a bus on the road 200 m beside the railway, nearer by its times.
    func test_S1_busOnRoadBesideRailway() throws {
        let you = Fx.fixes(from: 2000, speed: 30, count: 15)
        let train = Fx.track("T", path: Fx.railway, at: 1100, speed: 30)
        let bus = Fx.track("B", line: "306", train: false, path: Fx.road(north: 200), at: 2300, speed: 12)
        let j = VehicleMatch.judgeAll(you, [train, bus])
        XCTAssertEqual(Fx.why(j, "B"), .offItsPath)
        XCTAssertEqual(try XCTUnwrap(Fx.ok(j, "T")), 30, accuracy: 1)
        XCTAssertEqual(VehicleMatch.rank(j, planned: nil).map(\.id), ["T"])
    }

    /// S1b: the same, with the bus on a road only 50 m away: it doesn't keep up with you.
    func test_S1b_busOnCloseRoad() {
        let you = Fx.fixes(from: 2000, speed: 30, count: 15)
        let train = Fx.track("T", path: Fx.railway, at: 1100, speed: 30)
        let bus = Fx.track("B", line: "306", train: false, path: Fx.road(north: 50), at: 2300, speed: 12)
        let j = VehicleMatch.judgeAll(you, [train, bus])
        XCTAssertEqual(Fx.why(j, "B"), .drifting)
        XCTAssertNotNil(Fx.ok(j, "T"))
    }

    func test_busTooFast() {
        let you = Fx.fixes(from: 2000, speed: 35, count: 15, north: 50)
        let bus = Fx.track("B", line: "306", train: false, path: Fx.road(north: 50), at: 2000, speed: 35)
        XCTAssertEqual(Fx.why(VehicleMatch.judgeAll(you, [bus]), "B"), .implausibleSpeed)
    }

    /// S2: on the bus; a train passes beside it.
    func test_S2_trainPassingYourBus() {
        let you = Fx.fixes(from: 2000, speed: 12, count: 15, north: 50)
        let bus = Fx.track("B", line: "306", train: false, path: Fx.road(north: 50), at: 1900, speed: 12)
        let train = Fx.track("T", path: Fx.railway, at: 1500, speed: 30)
        let j = VehicleMatch.judgeAll(you, [bus, train])
        XCTAssertEqual(Fx.why(j, "T"), .drifting)
        XCTAssertEqual(VehicleMatch.rank(j, planned: nil).map(\.id), ["B"])
    }

    /// S3: two trains on the double track, opposite ways, and no GPS course on any fix.
    func test_S3_oppositeTrainsWithoutCourse() throws {
        let you = Fx.fixes(from: 2000, speed: 30, count: 15, course: -1)
        let east = Fx.track("A", path: Fx.railway, at: 1400, speed: 30)
        let west = Fx.track("B", path: Fx.railway.reversed(), at: Geo.length(Fx.railway) - 2200, speed: 30)
        let j = VehicleMatch.judgeAll(you, [east, west])
        XCTAssertEqual(Fx.why(j, "B"), .wrongWay)
        XCTAssertEqual(try XCTUnwrap(Fx.ok(j, "A")), 20, accuracy: 1)
    }

    /// S4: a bus and a train leave the same station; you speed up along the railway, the bus's road turns away.
    func test_S4_leavingAStation() {
        func x(_ t: Double) -> Double { t <= 30 ? 2000 + t * t / 6 : 2150 + 10 * (t - 30) }
        func you(until end: Double) -> [Fix] {
            stride(from: 0.0, through: end, by: 2).map { t in
                Fix(t: Fx.t0 + t, p: Fx.east(x(t)), accuracy: 20, speed: t <= 30 ? t / 3 : 10, course: 90)
            }
        }
        let train = Fx.track("T", path: Fx.railway, at: 2000, speed: 10)
        let turn = 50 * Double.pi / 180, d = 3000.0          // heading 50°: 40° left of the railway
        let road = [Fx.east(0), Fx.east(2050), Fx.east(2050 + d * sin(turn), north: d * cos(turn))]
        let bus = Fx.track("B", line: "306", train: false, path: road, at: 2000, speed: 10)

        let early = VehicleMatch.judgeAll(you(until: 4), [train, bus])
        XCTAssertEqual(Fx.why(early, "T"), .tooFewFixes)
        XCTAssertEqual(Fx.why(early, "B"), .tooFewFixes)

        let later = VehicleMatch.judgeAll(you(until: 40), [train, bus])
        XCTAssertEqual(Fx.why(later, "B"), .offItsPath)
        XCTAssertNotNil(Fx.ok(later, "T"), "\(later)")
        XCTAssertEqual(later.first { $0.id == "T" }?.evidence?.steady, false)     // speeding up: no drift or ratio test
    }

    /// S6: a bus standing at your stop while you set off on another, a fix every 1.25 s (Fastest trip: one every 10 m).
    func test_S6_busStandingAtYourStop() {
        let you = Fx.fixes(from: 2000, speed: 8, count: 17, every: 1.25, north: 50)
        let before = TimedPiece(departure: t0 - 205, arrival: t0 - 5, path: [Fx.east(0, north: 50), Fx.east(2000, north: 50)])
        let after = TimedPiece(departure: t0 + 20, arrival: t0 + 510,
                               path: [Fx.east(2000, north: 50), Fx.east(3000, north: 50), Fx.east(6900, north: 50)])
        let standing = VehicleTrack(tripId: "S", line: "306", isTrain: false, realTime: true, pieces: [before, after])
        XCTAssertEqual(Fx.why(VehicleMatch.judgeAll(you, [standing]), "S"), .standing)
    }

    /// S7: a fix 20 s old is compared with where its times put it then, not now.
    func test_S7_oldFixUsesItsOwnTime() {
        let fix = Fix(t: t0 - 20, p: Fx.east(2000), accuracy: 20, speed: 30, course: 90)
        let train = Fx.track("T", path: Fx.railway, at: 2000, speed: 30, start: t0 - 20)
        let j = VehicleMatch.judgeOne(fix, train, tolerance: 1800)
        guard case .success(let cost) = j.result else { return XCTFail("\(j.result)") }
        XCTAssertLessThan(cost, 1)
    }

    /// S5: a timetable-only bus far from its times fails by its times, but a candidate keeps it.
    func test_timetableOnlyKeptAsCandidate() {
        let you = Fx.fixes(from: 2000, speed: 12, count: 15, north: 50)
        let bus = Fx.track("A", line: "306", train: false, live: false, path: Fx.road(north: 50), at: 5000, speed: 12)
        XCTAssertEqual(Fx.why(VehicleMatch.judgeAll(you, [bus], strictTimes: true), "A"), .tooFarFromTimes)
        XCTAssertNotNil(Fx.ok(VehicleMatch.judgeAll(you, [bus], strictTimes: false), "A"))
    }

    /// Review Focus 2: 150 m off a straight chord between stops is still on its path; 150 m off a shaped path isn't.
    func test_unshapedPathLenient() {
        let you = Fx.fixes(from: 2000, speed: 12, count: 15, north: 150)
        let chord = Fx.track("C", line: "306", train: false, path: [Fx.east(0), Fx.east(6900)], at: 2000, speed: 12)
        let shaped = Fx.track("C", line: "306", train: false, path: Fx.railway, at: 2000, speed: 12)
        let onChord = VehicleMatch.judgeAll(you, [chord])
        XCTAssertNotEqual(Fx.why(onChord, "C"), .offItsPath)
        XCTAssertNotNil(Fx.ok(onChord, "C"))
        XCTAssertEqual(Fx.why(VehicleMatch.judgeAll(you, [shaped]), "C"), .offItsPath)
    }

    /// Review Focus 3: a 500 m-accuracy fix 2 km away among good ones changes nothing.
    func test_badFixesIgnored() {
        let you = Fx.fixes(from: 2000, speed: 30, count: 15)
        var noisy = you
        noisy.insert(Fix(t: t0 + 15, p: Fx.east(2400, north: 2000), accuracy: 500, speed: 30, course: 90), at: 8)
        let vehicles = [Fx.track("T", path: Fx.railway, at: 1100, speed: 30),
                        Fx.track("B", line: "306", train: false, path: Fx.road(north: 200), at: 2300, speed: 12),
                        Fx.track("C", line: "306", train: false, path: Fx.road(north: 50), at: 2300, speed: 12)]
        XCTAssertEqual(VehicleMatch.judgeAll(noisy, vehicles), VehicleMatch.judgeAll(you, vehicles))
    }

    // MARK: - Fix round 1

    /// R-rel-9: a bus comes into the station along the road it leaves by. You're on it, going out: each fix goes on the
    /// pass nearest its times (the outgoing one), not the first one found.
    func test_sameRoadInAndOut() throws {
        let inbound = TimedPiece(departure: t0 - 230, arrival: t0 - 30,
                                 path: [Fx.east(4000, north: 50), Fx.east(3000, north: 50), Fx.east(2000, north: 50)])
        let outbound = TimedPiece(departure: t0, arrival: t0 + 2000 / 12.0,
                                  path: [Fx.east(2000, north: 50), Fx.east(3000, north: 50), Fx.east(4000, north: 50)])
        let bus = VehicleTrack(tripId: "R", line: "306", isTrain: false, realTime: true, pieces: [inbound, outbound])
        let you = Fx.fixes(from: 2000, speed: 12, count: 15, north: 50)
        let j = VehicleMatch.judgeAll(you, [bus])
        XCTAssertNotEqual(Fx.why(j, "R"), .wrongWay)
        XCTAssertNotEqual(Fx.why(j, "R"), .drifting)
        XCTAssertEqual(try XCTUnwrap(Fx.ok(j, "R")), 0, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(j.first?.evidence?.progress), 288, accuracy: 1)    // from the 2nd fix's time to the 14th's

        // one fix, going out: the outgoing pass's direction, not the incoming one's
        let one = Fix(t: t0 + 10, p: Fx.east(2120, north: 50), accuracy: 20, speed: 12, course: 90)
        let r = VehicleMatch.judgeOne(one, bus, tolerance: 400).result
        XCTAssertEqual(r.map { $0 < 1 }, .success(true), "\(r)")
    }

    /// R-rel-10: standing in the station with ±25 m GPS jitter (30 m accuracy) while the train stands there by its times.
    /// The jitter looks like going back 25 m, or forward 45 m: neither is "the wrong way" or "standing while you go". The
    /// bus beside the station that leaves the other way doesn't win over it.
    func test_jitterAtStation() {
        let rail = VehicleTrack(tripId: "T", line: "IC", isTrain: true, realTime: true, pieces: [
            TimedPiece(departure: t0 - 320, arrival: t0 - 20, path: [Fx.east(0), Fx.east(3000)]),
            TimedPiece(departure: t0 + 60, arrival: t0 + 450, path: [Fx.east(3000), Fx.east(6900)])])
        let road = Array(Fx.road(north: 30).reversed())       // westbound: 6900 → 3000 → 0
        let bus = VehicleTrack(tripId: "W", line: "306", isTrain: false, realTime: true, pieces: [
            TimedPiece(departure: t0 - 414, arrival: t0 - 30, path: [road[0], Fx.east(3060, north: 30)]),
            TimedPiece(departure: t0 + 60, arrival: t0 + 366, path: [Fx.east(3060, north: 30), road[1], road[2]])])
        func jitter(_ east: [Double], _ north: [Double]) -> [Fix] {
            (0..<east.count).map { k in
                Fix(t: t0 + Double(k) * 2, p: Fx.east(3000 + east[k], north: 10 + north[k]), accuracy: 30, speed: 0, course: -1)
            }
        }
        let north: [Double] = [5, -8, 12, -3, 9, -12, 4, -6, 10, -9, 2, -5, 7, -10, 3]
        let back = jitter([12, -5, 20, -18, 8, -22, 15, 3, -10, 24, -15, 6, -20, 10, -13], north)   // 25 m back
        let ahead = jitter([-22, -25, -20, 18, -5, 12, 0, -15, 20, -5, 25, -18, 23, 20, 25], north)  // 45 m ahead
        for (name, you) in [("back", back), ("ahead", ahead)] {
            let j = VehicleMatch.judgeAll(you, [rail, bus])
            XCTAssertNotNil(Fx.ok(j, "T"), "\(name): \(j)")
            XCTAssertEqual(VehicleMatch.rank(j, planned: nil).first?.id, "T", name)
        }
    }

    /// R-rel-14/15: standing in the station with the train, each fix up to 25 m off on each axis (30 m accuracy), 200
    /// windows for each of 3 fixed seeds. The ends are the medians of 3 fixes, which jitter can move at most 50 m apart,
    /// and only going back further than twice the accuracy (60 m) is the wrong way: never `wrongWay`, never `standing`.
    func test_jitterWindows() {
        let rail = VehicleTrack(tripId: "T", line: "IC", isTrain: true, realTime: true, pieces: [
            TimedPiece(departure: t0 - 320, arrival: t0 - 20, path: [Fx.east(0), Fx.east(3000)]),
            TimedPiece(departure: t0 + 60, arrival: t0 + 450, path: [Fx.east(3000), Fx.east(6900)])])
        for seed: UInt64 in [1, 2026, 42] {
            var random = SplitMix(seed: seed)
            for window in 0..<200 {
                let you = (0..<15).map { k -> Fix in
                    let dx = random.next() * 50 - 25, dy = random.next() * 50 - 25
                    return Fix(t: t0 + Double(k) * 2, p: Fx.east(3000 + dx, north: dy), accuracy: 30, speed: 0, course: -1)
                }
                let why = Fx.why(VehicleMatch.judgeAll(you, [rail]), "T")
                XCTAssertNil(why, "seed \(seed), window \(window)")
            }
        }
        // one wild fix at each end, 40 m off either way (the end fixes alone would say 80 m back): the medians of 3 don't
        let wild: [Double] = [40, 5, -8, 3, -2, 9, -6, 0, 4, -9, 7, -3, 8, -5, -40]
        let you = wild.enumerated().map { k, dx in
            Fix(t: t0 + Double(k) * 2, p: Fx.east(3000 + dx), accuracy: 30, speed: 0, course: -1)
        }
        XCTAssertNil(Fx.why(VehicleMatch.judgeAll(you, [rail]), "T"))
    }

    /// Fixes bunched in the middle of the window (t = 0, 12, 13, 14, 15, 27 s) leave only 3 s between the middle fixes
    /// of the two ends: the speeds and the drift come from the end fixes and the whole span, so the right vehicle,
    /// moving with its times, isn't called drifting.
    func test_irregularSamplingFallsBack() {
        var random = SplitMix(seed: 7)
        let times: [Double] = [0, 12, 13, 14, 15, 27]
        let you = times.map { dt -> Fix in
            let dx = random.next() * 30 - 15, dy = random.next() * 30 - 15
            return Fix(t: t0 + dt, p: Fx.east(2000 + 15 * dt + dx, north: dy), accuracy: 20, speed: 15, course: 90)
        }
        let bus = Fx.track("V", line: "306", train: false, path: Fx.railway, at: 2000, speed: 15)
        let j = VehicleMatch.judgeAll(you, [bus])
        XCTAssertNil(Fx.why(j, "V"), "\(j)")
        if let e = j.first?.evidence { XCTAssertEqual(e.yourSpeed, 15, accuracy: 3, "\(e)") }
    }

    func test_newMatcherIsDefault() {
        let d = UserDefaults(suiteName: UUID().uuidString)!
        XCTAssertFalse(MatchSettings.classic(d))
        d.set(true, forKey: MatchSettings.key)
        XCTAssertTrue(MatchSettings.classic(d))
    }

    /// R-rel-13: across a 2 km gap between pieces that don't meet, its times run along the connector: the bus that
    /// crosses it with you passes; one whose times cross it at half your speed doesn't.
    func test_acrossAGap() {
        func bus(_ id: String, speed: Double) -> VehicleTrack {
            let reach = t0 - 500 / speed                 // at the gap's start (1000 m); 1500 m along at t0
            return VehicleTrack(tripId: id, line: "306", isTrain: false, realTime: true, pieces: [
                TimedPiece(departure: reach - 1000 / speed, arrival: reach, path: [Fx.east(0), Fx.east(500), Fx.east(1000)]),
                TimedPiece(departure: reach + 2000 / speed, arrival: reach + 3000 / speed,
                           path: [Fx.east(3000), Fx.east(3500), Fx.east(4000)])])
        }
        let you = Fx.fixes(from: 1500, speed: 12, count: 15)
        let j = VehicleMatch.judgeAll(you, [bus("R", speed: 12), bus("S", speed: 6)])
        XCTAssertEqual(try XCTUnwrap(Fx.ok(j, "R")), 0, accuracy: 1)
        XCTAssertEqual(Fx.why(j, "S"), .drifting)
        XCTAssertEqual(try XCTUnwrap(VehicleMatch.timePosition(bus("R", speed: 12), at: t0)), 1500, accuracy: 0.5)
    }

    /// R-rel-11: the straight line joining pieces that don't meet has no road shape: 150 m beside it is on its path,
    /// and it doesn't give the one-fix direction.
    func test_connectorLenient() throws {
        let first = TimedPiece(departure: t0 - 300, arrival: t0 - 200, path: [Fx.east(0), Fx.east(500), Fx.east(1000)])
        let middle = TimedPiece(departure: t0 - 200, arrival: t0 + 200, path: [Fx.east(1000), Fx.east(2000), Fx.east(3000)])
        let last = TimedPiece(departure: t0 + 200, arrival: t0 + 300, path: [Fx.east(3000), Fx.east(3500), Fx.east(4000)])
        let gap = VehicleTrack(tripId: "K", line: "306", isTrain: false, realTime: true, pieces: [first, last])
        let whole = VehicleTrack(tripId: "K", line: "306", isTrain: false, realTime: true, pieces: [first, middle, last])

        let you = Fx.fixes(from: 1500, speed: 12, count: 15, north: 150)
        let onGap = VehicleMatch.judgeAll(you, [gap])
        XCTAssertNotEqual(Fx.why(onGap, "K"), .offItsPath)
        XCTAssertEqual(onGap.first?.evidence?.shaped, false)
        XCTAssertEqual(Fx.why(VehicleMatch.judgeAll(you, [whole]), "K"), .offItsPath)

        let west = Fix(t: t0, p: Fx.east(2000), accuracy: 20, speed: 12, course: 270)
        XCTAssertNotNil(try? VehicleMatch.judgeOne(west, gap, tolerance: 4000).result.get())
        XCTAssertEqual(VehicleMatch.judgeOne(west, whole, tolerance: 4000).result, .failure(.wrongWay))
        let beside = Fix(t: t0, p: Fx.east(2000, north: 150), accuracy: 20, speed: 12, course: 90)
        XCTAssertNotEqual(VehicleMatch.judgeOne(beside, gap, tolerance: 4000).result, .failure(.offItsPath))
        XCTAssertEqual(VehicleMatch.judgeOne(beside, whole, tolerance: 4000).result, .failure(.offItsPath))
    }

    /// The steady gate: speeding up out of the station, a train whose times go 15 m/s drifts 7 m/s from you, but drift
    /// isn't judged while you aren't steady. The same evidence, steady, would be `drifting`.
    func test_steadyGate() throws {
        func x(_ t: Double) -> Double { t <= 30 ? 2000 + t * t / 6 : 2150 + 10 * (t - 30) }
        func v(_ t: Double) -> Double { t <= 30 ? t / 3 : 10 }
        let you = stride(from: 0.0, through: 40, by: 2).map { t in
            Fix(t: Fx.t0 + t, p: Fx.east(x(t)), accuracy: 20, speed: v(t), course: 90)
        }
        let train = Fx.track("T", path: Fx.railway, at: 2000, speed: 15)
        let j = VehicleMatch.judgeAll(you, [train])
        XCTAssertNotNil(Fx.ok(j, "T"), "\(j)")
        let e = try XCTUnwrap(j.first?.evidence)
        XCTAssertFalse(e.steady)
        XCTAssertGreaterThan(abs(e.drift), max(VehicleMatch.driftMin, VehicleMatch.driftShare * e.yourSpeed))
        let steady = Evidence(fixes: e.fixes, span: e.span, crossTrack: e.crossTrack, accuracy: e.accuracy, shaped: e.shaped,
                              progress: e.progress, offset: e.offset, drift: e.drift, yourSpeed: e.yourSpeed,
                              itsSpeed: e.itsSpeed, steady: true)
        XCTAssertEqual(VehicleMatch.judge(steady, isTrain: true, realTime: true), .failure(.drifting))
    }

    /// The ratio test: steady at 4 m/s, you can't be on a bus whose times go 15 m/s.
    func test_ratioTest() {
        let you = Fx.fixes(from: 2000, speed: 4, count: 15, north: 50)
        let bus = Fx.track("B", line: "306", train: false, path: Fx.road(north: 50), at: 2000, speed: 15)
        XCTAssertEqual(Fx.why(VehicleMatch.judgeAll(you, [bus]), "B"), .implausibleSpeed)
    }

    func test_judgeOne() {
        let train = Fx.track("T", path: Fx.railway, at: 2000, speed: 30)
        func one(_ course: Double, speed: Double = 30, accuracy: Double = 20, at m: Double = 2000) -> Fix {
            Fix(t: t0, p: Fx.east(m), accuracy: accuracy, speed: speed, course: course)
        }
        XCTAssertEqual(VehicleMatch.judgeOne(one(270), train, tolerance: 1800).result, .failure(.wrongWay))
        XCTAssertNotNil(try? VehicleMatch.judgeOne(one(150), train, tolerance: 1800).result.get())        // 60° off
        XCTAssertNotNil(try? VehicleMatch.judgeOne(one(-1), train, tolerance: 1800).result.get())         // no course
        XCTAssertNotNil(try? VehicleMatch.judgeOne(one(270, speed: -1), train, tolerance: 1800).result.get())  // no speed
        XCTAssertEqual(VehicleMatch.judgeOne(one(90, accuracy: 200), train, tolerance: 1800).result, .failure(.tooFewFixes))
        XCTAssertEqual(VehicleMatch.judgeOne(one(90, at: 3500), train, tolerance: 1000).result, .failure(.tooFarFromTimes))

        // the course and its road on either side of north
        let north = [Fx.east(2000), Fx.east(2000 - 17.45, north: 1000)]       // bearing about 359°
        let up = Fx.track("N", path: north, at: 0, speed: 30)
        let wrapped = Fix(t: t0, p: Fx.east(2000), accuracy: 20, speed: 30, course: 1)
        XCTAssertNotNil(try? VehicleMatch.judgeOne(wrapped, up, tolerance: 1800).result.get())

        // a bus can't go 35 m/s
        let bus = Fx.track("B", line: "306", train: false, path: Fx.railway, at: 2000, speed: 30)
        XCTAssertEqual(VehicleMatch.judgeOne(one(90, speed: 35), bus, tolerance: 1000).result, .failure(.implausibleSpeed))
    }

    /// R-rel-5: one usable fix is too few; `noTimes` only when no fix has a time position on it.
    func test_tooFewFixesVsNoTimes() {
        let train = Fx.track("T", path: Fx.railway, at: 1100, speed: 30)
        let once = Fx.fixes(from: 2000, speed: 30, count: 1)
        XCTAssertEqual(Fx.why(VehicleMatch.judgeAll(once, [train]), "T"), .tooFewFixes)
        XCTAssertEqual(Fx.why(VehicleMatch.judgeAll([], [train]), "T"), .tooFewFixes)
        let blurred = Fx.fixes(from: 2000, speed: 30, count: 15, accuracy: 500)
        XCTAssertEqual(Fx.why(VehicleMatch.judgeAll(blurred, [train]), "T"), .tooFewFixes)
        let later = Fx.track("L", path: Fx.railway, at: 1100, speed: 30, start: t0 + 3600)
        XCTAssertEqual(Fx.why(VehicleMatch.judgeAll(Fx.fixes(from: 2000, speed: 30, count: 15), [later]), "L"), .noTimes)
        XCTAssertNil(VehicleMatch.evidence(once, train))
    }

    // MARK: - Ranking and tracks

    func test_S10_plannedBonus() {
        let p = Judgement(id: "p", line: "IC", isTrain: true, realTime: true, evidence: nil, result: .success(70))
        let o = Judgement(id: "o", line: "IC", isTrain: true, realTime: true, evidence: nil, result: .success(40))
        XCTAssertEqual(VehicleMatch.rank([p, o], planned: "p"), [Ranked(id: "p", cost: 25), Ranked(id: "o", cost: 40)])
    }

    func test_groupSharedPieces() {
        let early = TimedPiece(departure: t0, arrival: t0 + 60, path: [Fx.east(0), Fx.east(1000)])
        let late = TimedPiece(departure: t0 + 90, arrival: t0 + 150, path: [Fx.east(1000), Fx.east(2000)])
        let x1 = MapPiece(tripId: "x", line: "IC", isTrain: true, realTime: false, piece: early)
        let x2 = MapPiece(tripId: "x", line: "IC", isTrain: true, realTime: true, piece: late)
        let y = MapPiece(tripId: "y", line: "SPR", isTrain: true, realTime: false, piece: early)
        let tracks = VehicleTrack.group([x2, x1, x1, y])
        XCTAssertEqual(tracks.count, 2)
        let x = tracks.first { $0.tripId == "x" }
        XCTAssertEqual(x?.pieces, [early, late])
        XCTAssertEqual(x?.realTime, true)
        XCTAssertEqual(tracks.first { $0.tripId == "y" }?.pieces, [early])
        XCTAssertEqual(tracks.first { $0.tripId == "y" }?.realTime, false)
    }

    // MARK: - By the road you're on

    /// A track's pieces as the live map gives them.
    private func pieces(_ v: VehicleTrack) -> [MapPiece] {
        v.pieces.map { MapPiece(tripId: v.tripId, line: v.line, isTrain: v.isTrain, realTime: v.realTime, piece: $0) }
    }

    /// S7: how late it is, is against the fix's own time (20 s ago), not now.
    func test_byRoadUsesFixTime() throws {
        let fix = Fix(t: t0 - 20, p: Fx.east(2000), accuracy: 20, speed: 30, course: 90)
        let train = Fx.track("T", path: Fx.railway, at: 2000, speed: 30, start: t0 - 20)
        let hits = VehicleMatch.byRoad(fix, pieces(train))
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.tripId, "T")
        XCTAssertEqual(try XCTUnwrap(hits.first?.late), 0, accuracy: 2)
    }

    func test_byRoadSkipsOtherWay() {
        let fix = Fix(t: t0 - 20, p: Fx.east(2000), accuracy: 20, speed: 30, course: 90)
        let back = Fx.track("T", path: Fx.railway.reversed(), at: Geo.length(Fx.railway) - 2000, speed: 30, start: t0 - 20)
        XCTAssertEqual(VehicleMatch.byRoad(fix, pieces(back)), [])
    }

    /// Per trip the least late of its pieces; more than 12 minutes off its times doesn't count; least late first.
    func test_byRoadLeastLateFirst() {
        let fix = Fix(t: t0, p: Fx.east(2000), accuracy: 20, speed: 30, course: 90)
        let late = Fx.track("L", path: Fx.railway, at: 2000, speed: 30, start: t0 - 120)                 // here 2 min ago
        let later = Fx.track("L", path: Fx.railway, at: 2000, speed: 30, start: t0 - 300)                // the same trip, 5 min
        let early = Fx.track("E", line: "SPR", path: Fx.railway, at: 2000, speed: 30, start: t0 + 30)    // here in half a minute
        let gone = Fx.track("G", path: Fx.railway, at: 2000, speed: 30, start: t0 - 800)
        let hits = VehicleMatch.byRoad(fix, pieces(later) + pieces(late) + pieces(early) + pieces(gone))
        XCTAssertEqual(hits.map(\.tripId), ["E", "L"])
        guard hits.count == 2 else { return }
        XCTAssertEqual(hits[0].late, -30, accuracy: 2)
        XCTAssertEqual(hits[0].line, "SPR")
        XCTAssertEqual(hits[1].late, 120, accuracy: 2)
    }

    func test_otherKindPossible() {
        XCTAssertTrue(VehicleMatch.otherKindPossible(.implausibleSpeed))
        XCTAssertTrue(VehicleMatch.otherKindPossible(.drifting))
        XCTAssertFalse(VehicleMatch.otherKindPossible(.offItsPath))
        XCTAssertFalse(VehicleMatch.otherKindPossible(nil))
    }
}

/// A small deterministic random source (SplitMix64), so random-looking tests are the same on every run.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    /// The next number in 0..<1.
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(UInt64(1) << 53)
    }
}
