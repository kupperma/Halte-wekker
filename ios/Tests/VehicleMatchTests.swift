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
}
