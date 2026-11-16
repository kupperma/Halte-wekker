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
        // a fix from the future (a clock step) doesn't count
        let ahead = walk + [Fix(t: now + 10, p: Fx.east(1500, north: 50), accuracy: 10, speed: 9, course: 90)]
        XCTAssertEqual(try XCTUnwrap(RideGuards.movedMetres(ahead, now: now)), 40, accuracy: 3)
        XCTAssertFalse(RideGuards.movingNow(ahead, now: now))

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

    /// Away from the stop you got off at means past its arrival radius and margin (600 m): "You're at …" came at 450 m,
    /// and you may still be on the bus you came in on.
    func test_mayTakeAtChange() {
        XCTAssertEqual(RideGuards.awayFromChange, 600)
        XCTAssertFalse(RideGuards.mayTakeAtChange(moving: true, fromChangeStop: 250))
        XCTAssertFalse(RideGuards.mayTakeAtChange(moving: true, fromChangeStop: 450))
        XCTAssertFalse(RideGuards.mayTakeAtChange(moving: true, fromChangeStop: 600))
        XCTAssertTrue(RideGuards.mayTakeAtChange(moving: true, fromChangeStop: 650))
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

    /// Its road never known: the pick holds (it holds only on a leg, where the alarm for its stop is armed).
    func test_pickWithoutItsRoad() {
        func at(_ s: Double) -> Date { t0 + s }
        XCTAssertFalse(RideGuards.pickRuledOut((0..<12).map { (at(Double($0) * 10), nil) }, isTrain: true))
        XCTAssertFalse(RideGuards.pickRuledOut([(at(0), 40), (at(10), nil), (at(40), nil), (at(70), nil)], isTrain: true))
        XCTAssertFalse(RideGuards.pickRuledOut([(at(0), .nan), (at(30), .infinity)], isTrain: true))
    }

    /// The Intercity at a change, the reviewer's case: the planned one missed, you're on the next Intercity to Breda,
    /// and the one to Den Bosch passes twice on the track they share. Nothing you picked is at stake there: it plans
    /// again from what it sees (and arms that leg's alarm), it never waits at the change. A pick of yours held at a
    /// change would start the next leg instead; on a leg, where the alarm is armed, your pick holds on its road.
    func test_otherVehicle() {
        XCTAssertEqual(RideGuards.onOtherVehicle(atChange: true, picked: false, ruledOut: false), .replan)
        XCTAssertEqual(RideGuards.onOtherVehicle(atChange: true, picked: true, ruledOut: false), .startNextLeg)
        XCTAssertEqual(RideGuards.onOtherVehicle(atChange: true, picked: true, ruledOut: true), .replan)
        XCTAssertEqual(RideGuards.onOtherVehicle(atChange: false, picked: true, ruledOut: false), .keepPick)
        XCTAssertEqual(RideGuards.onOtherVehicle(atChange: false, picked: true, ruledOut: true), .replan)
        XCTAssertEqual(RideGuards.onOtherVehicle(atChange: false, picked: false, ruledOut: false), .replan)
        // never waiting at a change, whatever the looks say
        for p in [false, true] { for r in [false, true] {
            XCTAssertNotEqual(RideGuards.onOtherVehicle(atChange: true, picked: p, ruledOut: r), .keepPick)
        } }
        // the picked Breda one on the shared track to Boxtel (30 m, 60 m from its road): kept; after the split
        // (900 m, 1200 m, 25 s apart): it gives way
        let shared: [(at: Date, metres: Double?)] = [(t0, 30), (t0 + 25, 60)]
        let parted: [(at: Date, metres: Double?)] = [(t0, 900), (t0 + 25, 1200)]
        XCTAssertEqual(RideGuards.onOtherVehicle(atChange: false, picked: true, ruledOut: RideGuards.pickRuledOut(shared, isTrain: true)), .keepPick)
        XCTAssertEqual(RideGuards.onOtherVehicle(atChange: false, picked: true, ruledOut: RideGuards.pickRuledOut(parted, isTrain: true)), .replan)
    }

    // MARK: - At a change, the planned one's line when you're on its road

    /// Metres east and north of Eindhoven on a flat map.
    private func pt(_ x: Double, _ y: Double) -> GeoPoint {
        GeoPoint(lat: 51.44 + y / 110_540, lon: 5.48 + x / (111_320 * cos(51.44 * .pi / 180)))
    }
    /// Eindhoven to Boxtel 20 km along the shared track; from Boxtel the Breda line 45° to one side, the Den Bosch line
    /// (11 km) 45° to the other.
    private var boxtel: Double { 20_000 }
    private var bredaRoad: [GeoPoint] { [pt(0, 0), pt(boxtel, 0), pt(boxtel + 30_000 * cos(.pi / 4), -30_000 * sin(.pi / 4))] }
    private func onDenBoschLine(_ along: Double) -> GeoPoint {
        along <= boxtel ? pt(along, 0) : pt(boxtel + (along - boxtel) * cos(.pi / 4), (along - boxtel) * sin(.pi / 4))
    }
    private func onBredaLine(_ along: Double) -> GeoPoint {
        along <= boxtel ? pt(along, 0) : pt(boxtel + (along - boxtel) * cos(.pi / 4), -(along - boxtel) * sin(.pi / 4))
    }
    private func fromBredaRoad(_ p: GeoPoint) -> Double { Geo.project(p, on: bredaRoad)!.crossTrack }

    func test_atChangeDecision() {
        XCTAssertEqual(RideGuards.atChange(plannedRoadMetres: 40, isTrain: true), .startNextLeg)
        XCTAssertEqual(RideGuards.atChange(plannedRoadMetres: 700, isTrain: true), .startNextLeg)
        XCTAssertEqual(RideGuards.atChange(plannedRoadMetres: 701, isTrain: true), .replan)
        XCTAssertEqual(RideGuards.atChange(plannedRoadMetres: 250, isTrain: false), .startNextLeg)
        XCTAssertEqual(RideGuards.atChange(plannedRoadMetres: 350, isTrain: false), .replan)
        // its road unknown (it couldn't be had): plan again from what it sees, as before
        XCTAssertEqual(RideGuards.atChange(plannedRoadMetres: nil, isTrain: true), .replan)
        XCTAssertEqual(RideGuards.atChange(plannedRoadMetres: .nan, isTrain: true), .replan)
        XCTAssertEqual(RideGuards.atChange(plannedRoadMetres: .infinity, isTrain: true), .replan)
    }

    /// On the next Intercity to Breda (the planned one missed), the Den Bosch one 7632 seen at the change: you're on the
    /// planned one's road, so the Breda leg starts (its alarm armed), and the hold never gives way on the Breda line.
    func test_onTheBredaIntercity() {
        XCTAssertEqual(RideGuards.atChange(plannedRoadMetres: fromBredaRoad(onBredaLine(1200)), isTrain: true), .startNextLeg)
        var looks: [(at: Date, metres: Double?)] = []
        for k in 0..<220 {                                           // a look every 7 s at 30 m/s, 1.2 km to 47 km (its road: 50)
            let along = 1200 + Double(k) * 210
            looks.append((at: t0 + Double(k) * 7, metres: fromBredaRoad(onBredaLine(along))))
            XCTAssertEqual(RideGuards.onOtherVehicle(atChange: false, picked: true,
                                                     ruledOut: RideGuards.pickRuledOut(looks, isTrain: true, fromPlan: true)), .keepPick, "\(along)")
        }
    }

    /// Really on 7632 to Den Bosch: the change takes it as the Breda line (the shared track), and the hold gives way
    /// 1–2 km past Boxtel, where the lines part: planned again from 7632, Den Bosch armed with 9 km or more to go.
    func test_reallyOnTheDenBoschIntercity() throws {
        XCTAssertEqual(RideGuards.atChange(plannedRoadMetres: fromBredaRoad(onDenBoschLine(1200)), isTrain: true), .startNextLeg)
        var looks: [(at: Date, metres: Double?)] = []
        var gaveWay: Double?
        for k in 0..<200 {
            let along = 1200 + Double(k) * 210
            looks.append((at: t0 + Double(k) * 7, metres: fromBredaRoad(onDenBoschLine(along))))
            if RideGuards.onOtherVehicle(atChange: false, picked: true,
                                         ruledOut: RideGuards.pickRuledOut(looks, isTrain: true, fromPlan: true)) == .replan {
                gaveWay = along; break
            }
        }
        let past = try XCTUnwrap(gaveWay) - boxtel
        XCTAssertGreaterThanOrEqual(past, 1000); XCTAssertLessThanOrEqual(past, 2000)
        XCTAssertGreaterThanOrEqual(11_000 - past, 9000)
    }

    /// A hold from the plan whose road can't be had (its fetch failing) gives way after a minute; a pick of yours holds.
    func test_planHoldWithoutItsRoad() {
        let failing: [(at: Date, metres: Double?)] = (0...9).map { (at: t0 + Double($0) * 7, metres: nil) }      // 63 s
        XCTAssertTrue(RideGuards.pickRuledOut(failing, isTrain: true, fromPlan: true))
        XCTAssertFalse(RideGuards.pickRuledOut(failing, isTrain: true))
        XCTAssertFalse(RideGuards.pickRuledOut(Array(failing.prefix(8)), isTrain: true, fromPlan: true))                 // 49 s
        // a look that had it in between starts the minute again
        var mixed = failing; mixed[5] = (at: mixed[5].at, metres: 40)
        XCTAssertFalse(RideGuards.pickRuledOut(mixed, isTrain: true, fromPlan: true))
        // off its road twice, 20 s apart, still gives way too
        XCTAssertTrue(RideGuards.pickRuledOut([(at: t0, metres: 900), (at: t0 + 25, metres: 1200)], isTrain: true, fromPlan: true))
    }

    /// Your own route (Veghel–Eindhoven–Breda by the big button) plans nothing for the next leg: the road to go by is the
    /// listed one that left since you got off (the newest), else the first after you got there.
    func test_roadReferenceOnYourOwnRoute() {
        let arrived = t0                                                       // off the 306 at Eindhoven, 08:30
        let ics = [t0 - 600, t0 + 180, t0 + 1080, t0 + 1980]                    // 08:20 (gone before), 08:33, 08:48, 09:03
        XCTAssertEqual(RideGuards.roadReference(ics, arrived: arrived, now: t0 + 60), 1)       // none left yet: the 08:33
        XCTAssertEqual(RideGuards.roadReference(ics, arrived: arrived, now: t0 + 240), 1)      // going at 08:34: the 08:33
        XCTAssertEqual(RideGuards.roadReference(ics, arrived: arrived, now: t0 + 1140), 2)     // the 08:33 missed: the 08:48
        XCTAssertEqual(RideGuards.roadReference(ics.reversed(), arrived: arrived, now: t0 + 1140), 1)  // (by time, not order)
        XCTAssertEqual(RideGuards.roadReference([t0 - 90, t0 + 900], arrived: arrived, now: t0 + 30), 0)  // a late one, listed by its live time
        XCTAssertEqual(RideGuards.roadReference([t0 - 600], arrived: arrived, now: t0 + 60), nil)       // only ones before you got there
        XCTAssertNil(RideGuards.roadReference([], arrived: arrived, now: t0))
        // and on its road (the Intercity to Breda, a train: 700 m), the next leg starts, its alarm armed, as for a planned trip
        XCTAssertEqual(RideGuards.atChange(plannedRoadMetres: fromBredaRoad(onBredaLine(1500)), isTrain: true), .startNextLeg)
        XCTAssertEqual(RideGuards.atChange(plannedRoadMetres: 2400, isTrain: true), .replan)
    }
}
