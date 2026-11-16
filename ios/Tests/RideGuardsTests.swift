import XCTest

final class RideGuardsTests: XCTestCase {
    private let t0 = Fx.t0

    /// A ride started without you whose stop is where you are (the Eindhoven bus station) is refused; one further on isn't.
    func test_rideAtItsStopRefused() {
        XCTAssertTrue(RideGuards.startsAtItsStop(targetMetres: 180, accuracy: 20))
        XCTAssertTrue(RideGuards.startsAtItsStop(targetMetres: 600, accuracy: 20))
        XCTAssertFalse(RideGuards.startsAtItsStop(targetMetres: 601, accuracy: 20))
        XCTAssertTrue(RideGuards.startsAtItsStop(targetMetres: 700, accuracy: 300))      // a rough fix widens the margin
        XCTAssertFalse(RideGuards.startsAtItsStop(targetMetres: 2000, accuracy: -1))
        XCTAssertTrue(RideGuards.startsAtItsStop(targetMetres: 500, accuracy: .nan))
        XCTAssertFalse(RideGuards.startsAtItsStop(targetMetres: nil, accuracy: 20))
        XCTAssertFalse(RideGuards.startsAtItsStop(targetMetres: .nan, accuracy: 20))
        XCTAssertFalse(RideGuards.startsAtItsStop(targetMetres: .infinity, accuracy: 20))
    }

    func test_wakeAtStart() {
        XCTAssertEqual(RideGuards.wakeAtStart(targetMetres: 1900, wakeMetres: 2000), .awakeSilently)
        XCTAssertEqual(RideGuards.wakeAtStart(targetMetres: 2000, wakeMetres: 2000), .awakeSilently)
        XCTAssertEqual(RideGuards.wakeAtStart(targetMetres: 2100, wakeMetres: 2000), .sleep)
        XCTAssertEqual(RideGuards.wakeAtStart(targetMetres: nil, wakeMetres: 2000), .sleep)
        XCTAssertEqual(RideGuards.wakeAtStart(targetMetres: .nan, wakeMetres: 2000), .sleep)
    }

    /// Eindhoven, 11:50:10: in on a bus for 90 s at 9 m/s, then 30 s walking 40 m about the bus station among the buses
    /// standing at their stops. Over two minutes that is more than 2.5 m/s, but you're not going now.
    func test_eindhovenWalkAmongBuses() {
        let ride = Fx.fixes(from: 0, speed: 9, count: 45, north: 50)                     // 0…88 s, 0…792 m
        let walk = (0..<16).map { k -> Fix in
            let dt = Double(k) * 2
            return Fix(t: t0 + 90 + dt, p: Fx.east(810 + 40 * dt / 30, north: 50), accuracy: 15, speed: 1.3, course: 90)
        }
        let fixes = ride + walk
        let now = t0 + 120
        let first = fixes[0], last = fixes[fixes.count - 1]
        XCTAssertGreaterThan(Geo.metres(first.p, last.p) / last.t.timeIntervalSince(first.t), 2.5)    // the old 2-minute test
        XCTAssertFalse(RideGuards.movingNow(fixes, now: now))
        XCTAssertEqual(try XCTUnwrap(RideGuards.movedMetres(fixes, now: now)), 40, accuracy: 3)
        XCTAssertFalse(RideGuards.mayTakeAtChange(moving: RideGuards.movingNow(fixes, now: now), fromChangeStop: 90))

        // The matcher's gap this covers: a bus standing at its stop by its times, where you walk about, passes.
        let stand = (0..<16).map { k -> Fix in
            let dt = Double(k) * 2
            return Fix(t: t0 + dt, p: Fx.east(2000 + 20 * sin(dt / 5), north: 50), accuracy: 15, speed: 0.8, course: 90)
        }
        let atStop = TimedPiece(departure: t0 - 300, arrival: t0 - 120, path: [Fx.east(0, north: 50), Fx.east(2000, north: 50)])
        let away = TimedPiece(departure: t0 + 120, arrival: t0 + 400, path: [Fx.east(2000, north: 50), Fx.east(3000, north: 50), Fx.east(5000, north: 50)])
        let bus = VehicleTrack(tripId: "406-4068", line: "406", isTrain: false, realTime: false, pieces: [atStop, away])
        XCTAssertNotNil(Fx.ok(VehicleMatch.judgeAll(stand, [bus]), "406-4068"), "documents the gap: standing with it passes")
        XCTAssertFalse(RideGuards.movingNow(stand, now: t0 + 30))
    }

    func test_busLeavingIsMoving() {
        let off = Fx.fixes(from: 0, speed: 6, count: 13, start: t0)                       // 150 m in 24 s
        XCTAssertTrue(RideGuards.movingNow(off, now: t0 + 25))
        let short = Fx.fixes(from: 0, speed: 15, count: 6, start: t0)                     // 150 m in 10 s: span < 20 s
        XCTAssertFalse(RideGuards.movingNow(short, now: t0 + 11))
        XCTAssertNil(RideGuards.movedMetres(short, now: t0 + 11))
        // fixes older than 30 s don't count: the ride in, then standing
        let old = Fx.fixes(from: 0, speed: 10, count: 20, start: t0) + Fx.fixes(from: 400, speed: 0, count: 15, start: t0 + 50)
        XCTAssertFalse(RideGuards.movingNow(old, now: t0 + 79))
        // fixes worse than 150 m are left out
        let rough = Fx.fixes(from: 0, speed: 6, count: 13, accuracy: 200, start: t0)
        XCTAssertFalse(RideGuards.movingNow(rough, now: t0 + 25))
    }

    func test_mayTakeAtChange() {
        XCTAssertFalse(RideGuards.mayTakeAtChange(moving: true, fromChangeStop: 250))
        XCTAssertFalse(RideGuards.mayTakeAtChange(moving: true, fromChangeStop: 300))
        XCTAssertTrue(RideGuards.mayTakeAtChange(moving: true, fromChangeStop: 350))
        XCTAssertFalse(RideGuards.mayTakeAtChange(moving: false, fromChangeStop: 2000))
        XCTAssertTrue(RideGuards.mayTakeAtChange(moving: true, fromChangeStop: nil))
    }

    /// The Intercity to Breda you picked, on the track it shares with the one to Den Bosch from Eindhoven to Boxtel: it
    /// holds until the roads part.
    func test_pickHeldOnSharedTrack() {
        func at(_ s: Double) -> Date { t0 + s }
        XCTAssertFalse(RideGuards.pickRuledOut([(at(0), 30), (at(25), 60)], isTrain: true))
        XCTAssertFalse(RideGuards.pickRuledOut([(at(0), 900)], isTrain: true))
        XCTAssertTrue(RideGuards.pickRuledOut([(at(0), 900), (at(25), 1200)], isTrain: true))
        XCTAssertFalse(RideGuards.pickRuledOut([(at(0), 900), (at(10), 1200)], isTrain: true))            // too close together
        XCTAssertFalse(RideGuards.pickRuledOut([(at(0), 900), (at(12), 40), (at(25), 1200)], isTrain: true))  // back on it between
        XCTAssertFalse(RideGuards.pickRuledOut([(at(0), 900), (at(25), 650)], isTrain: true))             // a train: 700 m
        XCTAssertTrue(RideGuards.pickRuledOut([(at(0), 350), (at(25), 400)], isTrain: false))             // a bus: 300 m
        XCTAssertFalse(RideGuards.pickRuledOut([(at(0), 250), (at(25), 400)], isTrain: false))
        // given out of order: the same
        XCTAssertTrue(RideGuards.pickRuledOut([(at(25), 1200), (at(0), 900)], isTrain: true))
        // a look before both on its road doesn't matter
        XCTAssertTrue(RideGuards.pickRuledOut([(at(-30), 20), (at(0), 900), (at(25), 1200)], isTrain: true))
        // looks without its road say nothing
        XCTAssertFalse(RideGuards.pickRuledOut([(at(0), nil), (at(25), nil)], isTrain: true))
        XCTAssertTrue(RideGuards.pickRuledOut([(at(0), 900), (at(12), nil), (at(25), 1200)], isTrain: true))
        XCTAssertFalse(RideGuards.pickRuledOut([], isTrain: true))
    }

    /// Its road never known: after a minute (3 looks or more) it can't hold you; a known look in between starts over.
    func test_pickWithoutItsRoad() {
        func at(_ s: Double) -> Date { t0 + s }
        XCTAssertFalse(RideGuards.pickRuledOut([(at(0), nil), (at(30), nil), (at(55), nil)], isTrain: true))
        XCTAssertTrue(RideGuards.pickRuledOut([(at(0), nil), (at(30), nil), (at(60), nil)], isTrain: true))
        XCTAssertFalse(RideGuards.pickRuledOut([(at(0), nil), (at(60), nil)], isTrain: true))
        XCTAssertFalse(RideGuards.pickRuledOut([(at(0), nil), (at(20), 40), (at(40), nil), (at(60), nil)], isTrain: true))
        XCTAssertTrue(RideGuards.pickRuledOut([(at(0), 40), (at(10), nil), (at(40), nil), (at(70), nil)], isTrain: true))
    }
}
