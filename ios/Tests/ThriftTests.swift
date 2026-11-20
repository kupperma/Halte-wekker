import XCTest

/// 0.20.7's battery and data rules: each slowdown holds only while nothing is due soon, you stand, or the vehicle is
/// confirmed, and gives way at once on movement, doubt or nearness.
final class ThriftTests: XCTestCase {
    private let t0 = Fx.t0

    // MARK: the positions feed only when in doubt

    func test_feedFetchOnDoubt() {
        XCTAssertFalse(FeedPolicy.fetchOnDoubt(.passes, farLooks: 0, keptByGPS: false))      // confirmed: no fetch
        XCTAssertTrue(FeedPolicy.fetchOnDoubt(.fails, farLooks: 0, keptByGPS: false))        // before a miss counts
        XCTAssertTrue(FeedPolicy.fetchOnDoubt(.notSure, farLooks: 0, keptByGPS: false))
        XCTAssertTrue(FeedPolicy.fetchOnDoubt(.passes, farLooks: 1, keptByGPS: false))       // far from its times
        XCTAssertFalse(FeedPolicy.fetchOnDoubt(.fails, farLooks: 2, keptByGPS: true))        // its GPS kept it already
    }

    func test_feedDue() {
        XCTAssertTrue(FeedPolicy.due(last: nil, every: 120, now: t0))
        XCTAssertFalse(FeedPolicy.due(last: t0, every: 120, now: t0 + 119))
        XCTAssertTrue(FeedPolicy.due(last: t0, every: 120, now: t0 + 120))
        XCTAssertTrue(FeedPolicy.due(last: t0 + 10, every: 120, now: t0))                    // a clock step back
        XCTAssertEqual(FeedPolicy.confirmedEvery, 120)
        XCTAssertLessThan(FeedPolicy.doubtFresh, RealPositions.matchFresh)                   // a doubt fetch is a fresh fix
    }

    // MARK: the moving-but-unsure look

    func test_lookBackoff() {
        var s = LookBackoff.State()
        var waits: [TimeInterval] = []
        for _ in 0..<6 { s = LookBackoff.step(s, key: nil); waits.append(LookBackoff.wait(s)) }
        XCTAssertEqual(waits, [4, 8, 15, 30, 30, 30])
        s = LookBackoff.step(s, key: "305·4779")                     // it sees you with one now: from the start
        XCTAssertEqual(LookBackoff.wait(s), 4)
        s = LookBackoff.step(s, key: "305·4779")
        XCTAssertEqual(LookBackoff.wait(s), 8)
        s = LookBackoff.step(s, key: "306·1111")
        XCTAssertEqual(LookBackoff.wait(s), 4)
        XCTAssertEqual(LookBackoff.wait(LookBackoff.State()), 4)
    }

    func test_mapReuseAtSpeed() {
        // standing: as before (50 m)
        XCTAssertFalse(MapReuse.usable(age: 6, movedMetres: 51, allowed: true))
        // at bus speed the answer of 8 s ago does from 8 s further on (20 m/s: 160 m + 50)
        XCTAssertTrue(MapReuse.usable(age: 8, movedMetres: 200, allowed: true, speed: 20))
        XCTAssertFalse(MapReuse.usable(age: 8, movedMetres: 220, allowed: true, speed: 20))
        XCTAssertFalse(MapReuse.usable(age: 11, movedMetres: 10, allowed: true, speed: 20))  // never older than 10 s
        XCTAssertFalse(MapReuse.usable(age: 5, movedMetres: 10, allowed: false, speed: 20))  // a ride: never
        XCTAssertFalse(MapReuse.usable(age: 5, movedMetres: 80, allowed: true, speed: .nan))
    }

    // MARK: Fastest trip behind the screen

    func test_goPlanWait() {
        XCTAssertEqual(GoPace.planWait(inFront: true, departureIn: 30 * 60, leaveIn: nil), 40)
        XCTAssertEqual(GoPace.planWait(inFront: true, departureIn: 10 * 60, leaveIn: nil), 20)
        XCTAssertEqual(GoPace.planWait(inFront: false, departureIn: 30 * 60, leaveIn: nil), 60)
        XCTAssertEqual(GoPace.planWait(inFront: false, departureIn: 10 * 60, leaveIn: nil), 30)
        XCTAssertEqual(GoPace.planWait(inFront: false, departureIn: nil, leaveIn: nil), 60)
        // "Time to go" is due a minute before you leave: it wakes up for that, not after
        XCTAssertEqual(GoPace.planWait(inFront: false, departureIn: 30 * 60, leaveIn: 100), 41)
        XCTAssertEqual(GoPace.planWait(inFront: false, departureIn: 30 * 60, leaveIn: 61.5), 2.5)
        XCTAssertEqual(GoPace.planWait(inFront: false, departureIn: 30 * 60, leaveIn: 30), 60)  // (already told)
        XCTAssertEqual(GoPace.planWait(inFront: true, departureIn: 10 * 60, leaveIn: 5 * 60), 20)
        XCTAssertTrue(GoPace.extras(inFront: true))
        XCTAssertFalse(GoPace.extras(inFront: false))
    }

    func test_goAutoStop() {
        let dep = t0
        XCTAssertFalse(GoPace.autoStop(watched: dep, deadline: nil, movedMetres: 0, now: dep + 19 * 60))
        XCTAssertTrue(GoPace.autoStop(watched: dep, deadline: nil, movedMetres: 0, now: dep + 20 * 60))
        XCTAssertFalse(GoPace.autoStop(watched: dep, deadline: nil, movedMetres: 300, now: dep + 40 * 60))   // you went
        XCTAssertFalse(GoPace.autoStop(watched: nil, deadline: nil, movedMetres: 0, now: dep + 40 * 60))
        // a planned trip: a later way can still get you there; once its time has passed, nothing is wanted
        XCTAssertFalse(GoPace.autoStop(watched: dep, deadline: dep + 50 * 60, movedMetres: 0, now: dep + 30 * 60))
        XCTAssertTrue(GoPace.autoStop(watched: dep, deadline: dep + 50 * 60, movedMetres: 0, now: dep + 50 * 60))
        XCTAssertFalse(GoPace.autoStop(watched: dep, deadline: nil, movedMetres: .nan, now: dep + 40 * 60))
    }

    func test_goAutoOpenWindow() {
        let leave = t0, first = t0 + 10 * 60
        XCTAssertFalse(GoPace.autoOpen(leave: leave, firstDeparture: first, now: leave - 21 * 60))   // not from the alarm any more
        XCTAssertFalse(GoPace.autoOpen(leave: leave, firstDeparture: first, now: leave - 20 * 60))
        XCTAssertTrue(GoPace.autoOpen(leave: leave, firstDeparture: first, now: leave - 19 * 60))
        XCTAssertTrue(GoPace.autoOpen(leave: leave, firstDeparture: first, now: first + 4 * 60))
        XCTAssertFalse(GoPace.autoOpen(leave: leave, firstDeparture: first, now: first + 5 * 60))
        XCTAssertTrue(GoPace.autoOpen(leave: leave, firstDeparture: first, now: leave - 14 * 60, lead: 15 * 60))
        XCTAssertFalse(GoPace.autoOpen(leave: leave, firstDeparture: first, now: leave - 16 * 60, lead: 15 * 60))
    }

    // MARK: Fastest trip's GPS

    private func fix(_ dt: TimeInterval, east: Double, speed: Double = 0, accuracy: Double = 10) -> Fix {
        Fix(t: t0 + dt, p: Fx.east(east), accuracy: accuracy, speed: speed, course: 90)
    }

    func test_goStanding() {
        let now = t0 + 200
        XCTAssertFalse(GoGPS.standing([], now: now))                                         // not known yet
        XCTAssertTrue(GoGPS.standing([fix(100, east: 0), fix(150, east: 20), fix(190, east: 5)], now: now))
        XCTAssertFalse(GoGPS.standing([fix(100, east: 0), fix(190, east: 5, speed: 2.5)], now: now))   // walking
        XCTAssertFalse(GoGPS.standing([fix(100, east: 0), fix(190, east: 150)], now: now))   // moved off
        // rough fixes jump about: 100 m beyond their accuracy
        XCTAssertTrue(GoGPS.standing([fix(100, east: 0, accuracy: 65), fix(190, east: 150, accuracy: 65)], now: now))
        XCTAssertFalse(GoGPS.standing([fix(100, east: 0, accuracy: 65), fix(190, east: 200, accuracy: 65)], now: now))
        // no new fix for 3 minutes (it comes every 50 m): nothing moved you
        XCTAssertTrue(GoGPS.standing([fix(0, east: 0)], now: t0 + 400))
        XCTAssertFalse(GoGPS.standing([fix(190, east: 0, accuracy: -1)], now: now))          // no usable fix
        XCTAssertTrue(GoGPS.standing([fix(190, east: 0, speed: -1)], now: now))              // speed not known
    }

    func test_goCoarse() {
        XCTAssertTrue(GoGPS.coarse(leaveIn: 13 * 60, standing: true))
        XCTAssertFalse(GoGPS.coarse(leaveIn: 12 * 60, standing: true))                       // nearly time: the best
        XCTAssertFalse(GoGPS.coarse(leaveIn: 30 * 60, standing: false))                      // moving: the best
        XCTAssertFalse(GoGPS.coarse(leaveIn: nil, standing: true))                           // nothing to catch known
        XCTAssertFalse(GoGPS.coarse(leaveIn: .nan, standing: true))
        // and the plan it gives
        XCTAssertEqual(GPSPolicy.plan(phase: .idle, demo: false, going: true, lineWatch: false, regionLook: false, goCoarse: true), .coarse(50))
        XCTAssertEqual(GPSPolicy.plan(phase: .idle, demo: false, going: true, lineWatch: false, regionLook: false, goCoarse: false), .best(10))
        XCTAssertTrue(GPSPolicy.plan(phase: .idle, demo: false, going: true, lineWatch: false, regionLook: false, goCoarse: true).background)
        // only Fastest trip: a rough Go never reaches a ride, a change, or no Go
        XCTAssertEqual(GPSPolicy.plan(phase: .riding, demo: false, going: true, lineWatch: false, regionLook: false, goCoarse: true), .best(25))
        XCTAssertEqual(GPSPolicy.plan(phase: .transfer, demo: false, going: true, lineWatch: false, regionLook: false, goCoarse: true), .best(25))
        XCTAssertEqual(GPSPolicy.plan(phase: .idle, demo: false, going: false, lineWatch: false, regionLook: false, goCoarse: true), .off)
    }

    // MARK: a ride's network tick

    func test_rideTick() {
        XCTAssertTrue(RideTick.due(last: nil, now: t0))
        XCTAssertFalse(RideTick.due(last: t0, now: t0 + 29))
        XCTAssertTrue(RideTick.due(last: t0, now: t0 + 30))
        XCTAssertEqual(RideTick.etaGap(changeIn: nil), 300)
        XCTAssertEqual(RideTick.etaGap(changeIn: 16 * 60), 300)
        XCTAssertEqual(RideTick.etaGap(changeIn: 15 * 60), 120)
        XCTAssertEqual(RideTick.etaGap(changeIn: 0), 120)
        XCTAssertEqual(RideTick.etaGap(changeIn: .nan), 300)
        XCTAssertEqual(RideTick.musicGap(fast: true, inFront: true), 5)
        XCTAssertEqual(RideTick.musicGap(fast: false, inFront: true), 15)
        XCTAssertEqual(RideTick.musicGap(fast: false, inFront: false), 30)
        XCTAssertGreaterThanOrEqual(RideTick.tripCache, RideTick.vehicleEvery)             // the vehicle and its road share one fetch
    }

    // MARK: the Live Activity

    func test_activityThrottle() {
        XCTAssertFalse(ActivityThrottle.send(changed: true, phaseChanged: false, sinceLast: 29))
        XCTAssertTrue(ActivityThrottle.send(changed: true, phaseChanged: false, sinceLast: 30))
        XCTAssertFalse(ActivityThrottle.send(changed: false, phaseChanged: false, sinceLast: 600))   // nothing new: nothing
        XCTAssertTrue(ActivityThrottle.send(changed: true, phaseChanged: true, sinceLast: 0))       // waking, ringing, a change
        XCTAssertTrue(ActivityThrottle.send(changed: false, phaseChanged: true, sinceLast: 0))
        XCTAssertTrue(ActivityThrottle.send(changed: true, phaseChanged: false, sinceLast: -5))     // a clock step back
        XCTAssertEqual(ActivityThrottle.later(sinceLast: 10), 20)
        XCTAssertEqual(ActivityThrottle.later(sinceLast: 29.5), 1)
        XCTAssertEqual(ActivityThrottle.later(sinceLast: -100), 30)
        XCTAssertEqual(ActivityThrottle.progressStep(0.51), 10)
        XCTAssertEqual(ActivityThrottle.progressStep(0.53), 11)
        XCTAssertEqual(ActivityThrottle.progressStep(.nan), 0)
        XCTAssertEqual(ActivityThrottle.progressStep(2), 20)
    }

    // MARK: the planner's answers

    func test_planMemoKey() {
        let a = Date(timeIntervalSince1970: 1_800_000_000 + 7), b = a + 40, c = a + 60
        XCTAssertEqual(PlanMemo.minute(a), Date(timeIntervalSince1970: 1_800_000_000))         // (a whole minute)
        let k = { (t: Date) in PlanMemo.key(from: "x", to: "y", modes: "BUS", at: t, count: 8, maxTransfers: 0, arriveBy: false) }
        XCTAssertEqual(k(a), k(b))                                    // asked 40 s apart within one minute: one question
        XCTAssertNotEqual(k(a), k(c))
        XCTAssertNotEqual(k(a), PlanMemo.key(from: "x", to: "y", modes: "RAIL", at: a, count: 8, maxTransfers: 0, arriveBy: false))
        XCTAssertNotEqual(k(a), PlanMemo.key(from: "x", to: "y", modes: "BUS", at: a, count: 8, maxTransfers: 0, arriveBy: true))
        XCTAssertNotEqual(k(a), PlanMemo.key(from: "x", to: "y", modes: nil, at: a, count: 8, maxTransfers: 0, arriveBy: false))
        XCTAssertNotEqual(k(a), PlanMemo.key(from: "y", to: "x", modes: "BUS", at: a, count: 8, maxTransfers: 0, arriveBy: false))
        XCTAssertEqual(PlanMemo.unique(["a", "b", "a", "c", "b"]), ["a", "b", "c"])
        XCTAssertEqual(PlanMemo.ttl, 45)
    }

    // MARK: at a change

    func test_changePace() {
        XCTAssertEqual(ChangePace.gap(standingFor: 300, nextIn: 20 * 60), 180)
        XCTAssertEqual(ChangePace.gap(standingFor: 300, nextIn: 10 * 60), 60)             // the next one soon: every minute
        XCTAssertEqual(ChangePace.gap(standingFor: 60, nextIn: 20 * 60), 60)              // just got off, or moving
        XCTAssertEqual(ChangePace.gap(standingFor: nil, nextIn: 20 * 60), 60)
        XCTAssertEqual(ChangePace.gap(standingFor: 300, nextIn: nil), 60)                 // nothing listed: keep looking
    }

    // MARK: the look after leaving a station

    func test_regionLookSkip() {
        let end = (place: "veghel", at: t0)
        XCTAssertTrue(RegionLook.skip(place: "veghel", lastEnd: end, speed: nil, now: t0 + 5 * 60))
        XCTAssertTrue(RegionLook.skip(place: "veghel", lastEnd: end, speed: 1.2, now: t0 + 19 * 60))
        XCTAssertFalse(RegionLook.skip(place: "veghel", lastEnd: end, speed: nil, now: t0 + 20 * 60))
        XCTAssertFalse(RegionLook.skip(place: "ht", lastEnd: end, speed: nil, now: t0 + 60))            // another station
        XCTAssertFalse(RegionLook.skip(place: "veghel", lastEnd: end, speed: 12, now: t0 + 60))         // on a bus: look
        XCTAssertFalse(RegionLook.skip(place: "veghel", lastEnd: nil, speed: nil, now: t0))
        XCTAssertFalse(RegionLook.skip(place: "veghel", lastEnd: end, speed: nil, now: t0 - 60))
    }

    // MARK: the far GPS tier on rides

    private func far(_ m: Double, wasFar: Bool = false, train: Bool = false, speed: Double? = 20, eta: TimeInterval? = 40 * 60,
                     confirmed: Bool = true, asleep: Bool = true, enabled: Bool = true, backstop: Bool = false,
                     accuracy: Double? = 8, age: TimeInterval? = 3, wake: Double? = nil, steady: Bool = false) -> Bool {
        RideGPS.far(RideGPS.Input(enabled: enabled, asleep: asleep, confirmed: confirmed, metresToStop: m, accuracy: accuracy, fixAge: age,
                                  wakeMetres: wake ?? (train ? 5000 : 2000), isTrain: train, speed: speed, secondsToStop: eta,
                                  backstop: backstop, wasFar: wasFar, steady: steady))
    }

    /// 0.33: Motion & Fitness says automotive, steadily: the far tier comes on sooner (no kilometre more to switch on,
    /// 6 minutes at full speed instead of 8), and only then; everything else holds as it was.
    func test_rideFarSoonerWhenSteadilyInAVehicle() {
        // a bus: 2 km + 12 km (+1 km to switch on); steady: 2 km + 9 km
        XCTAssertFalse(far(14_500))
        XCTAssertTrue(far(14_500, steady: true))
        XCTAssertTrue(far(11_100, steady: true))
        XCTAssertFalse(far(10_900, steady: true))
        XCTAssertEqual(RideGPS.farFrom(wakeMetres: 2000, isTrain: false, speed: 10, steady: true), 11_000, accuracy: 0.1)
        // still only confirmed, asleep, with the setting, no backstop, not due within 10 minutes, a good fresh fix
        XCTAssertFalse(far(30_000, confirmed: false, steady: true))
        XCTAssertFalse(far(30_000, asleep: false, steady: true))
        XCTAssertFalse(far(30_000, enabled: false, steady: true))
        XCTAssertFalse(far(30_000, backstop: true, steady: true))
        XCTAssertFalse(far(30_000, eta: 600, steady: true))
        XCTAssertFalse(far(30_000, accuracy: 120, steady: true))
        // and never within 6 minutes at full speed of the wake point
        for train in [false, true] {
            var m = 60_000.0, on = true
            while m > 0 {
                on = far(m, wasFar: on, train: train, speed: nil, eta: nil, steady: true)
                if on { XCTAssertGreaterThanOrEqual(m - (train ? 5000 : 2000), (train ? 39 : 25) * 360 - 0.001) }
                m -= 75
            }
            XCTAssertFalse(on)
        }
    }

    func test_rideFarLine() {
        // the wake distance plus 8 minutes at full speed: a bus 2 km + 12 km, a train 5 km + 18.7 km
        XCTAssertEqual(RideGPS.farFrom(wakeMetres: 2000, isTrain: false, speed: 10), 14_000, accuracy: 0.1)
        XCTAssertEqual(RideGPS.farFrom(wakeMetres: 5000, isTrain: true, speed: 20), 23_720, accuracy: 0.1)
        // faster than that (a train at 160 km/h): further
        XCTAssertEqual(RideGPS.farFrom(wakeMetres: 5000, isTrain: true, speed: 44.4), 5000 + 44.4 * 480, accuracy: 0.1)
        XCTAssertEqual(RideGPS.farFrom(wakeMetres: 2000, isTrain: false, speed: .nan), 14_000, accuracy: 0.1)
        XCTAssertEqual(RideGPS.farFrom(wakeMetres: 2000, isTrain: false, speed: nil), 14_000, accuracy: 0.1)
        // the backstop is well inside the far line, and well outside the wake point
        for (w, train) in [(2000.0, false), (5000.0, true), (500.0, false), (10_000.0, true)] {
            let b = RideGPS.backstopRadius(wakeMetres: w)
            XCTAssertGreaterThanOrEqual(b - w, 4000)
            XCTAssertLessThan(b, RideGPS.farFrom(wakeMetres: w, isTrain: train, speed: nil))
        }
    }

    func test_rideFarTier() {
        XCTAssertTrue(far(15_500))                                   // a bus 15.5 km out, confirmed, 40 min to go
        XCTAssertFalse(far(14_500))                                  // within the line plus the kilometre to switch on
        XCTAssertTrue(far(14_500, wasFar: true))                     // on already: it stays until the line
        XCTAssertFalse(far(13_900, wasFar: true))                    // past the line: the best, at once
        XCTAssertTrue(far(25_000, train: true))
        XCTAssertFalse(far(24_000, train: true))                     // a train's line is 23.7 km (+1 km)
        // only with the vehicle confirmed, asleep, the setting on, no backstop
        XCTAssertFalse(far(30_000, confirmed: false))
        XCTAssertFalse(far(30_000, asleep: false))
        XCTAssertFalse(far(30_000, enabled: false))
        XCTAssertFalse(far(30_000, wasFar: true, backstop: true))
        // a fresh, good fix
        XCTAssertFalse(far(30_000, accuracy: 120))
        XCTAssertFalse(far(30_000, accuracy: nil))
        XCTAssertFalse(far(30_000, accuracy: -1))
        XCTAssertFalse(far(30_000, age: 301))
        XCTAssertFalse(far(30_000, age: nil))
        XCTAssertTrue(far(30_000, age: 300))
        // the stop due within 10 minutes (when its time is known): the best, however far
        XCTAssertFalse(far(30_000, eta: 600))
        XCTAssertFalse(far(30_000, wasFar: true, eta: 9 * 60))
        XCTAssertTrue(far(30_000, eta: 601))
        XCTAssertTrue(far(30_000, eta: nil))
        XCTAssertFalse(far(30_000, eta: .nan))
        // faster than full speed: the line moves out with you
        XCTAssertFalse(far(20_000, wasFar: true, speed: 40))         // 2 km + 40 m/s × 8 min = 21.2 km
        XCTAssertTrue(far(22_000, wasFar: true, speed: 40))
        // nonsense in: the best
        XCTAssertFalse(far(.nan))
        XCTAssertFalse(far(-5))
        XCTAssertFalse(far(30_000, wake: .nan))
        XCTAssertFalse(far(30_000, wake: -1))
    }

    /// Riding toward the stop the far tier is off well before the wake point: at least 8 minutes at full speed.
    func test_rideFarNeverNearTheWakePoint() {
        for train in [false, true] {
            for wake in [500.0, 2000, 5000, 10_000] {
                for v in [0.0, 5, 15, 25, 39, 50] {
                    var m = 60_000.0, on = true
                    while m > 0 {
                        on = far(m, wasFar: on, train: train, speed: v, eta: nil, wake: wake)
                        if on { XCTAssertGreaterThanOrEqual(m - wake, max(train ? 39 : 25, v) * 480 - 0.001) }
                        m -= 75
                    }
                    XCTAssertFalse(on)
                }
            }
        }
        XCTAssertEqual(GPSPolicy.plan(phase: .riding, demo: false, going: false, lineWatch: false, regionLook: false, rideFar: true), .ten(75))
        XCTAssertTrue(GPSPolicy.plan(phase: .riding, demo: false, going: false, lineWatch: false, regionLook: false, rideFar: true).background)
        XCTAssertEqual(GPSPolicy.plan(phase: .transfer, demo: false, going: false, lineWatch: false, regionLook: false, rideFar: true), .best(25))
        XCTAssertEqual(GPSPolicy.plan(phase: .riding, demo: true, going: false, lineWatch: false, regionLook: false, rideFar: true), .off)
    }

    func test_rideFarSetting() {
        let d = UserDefaults(suiteName: "thrift-\(UUID().uuidString)")!
        XCTAssertTrue(RideGPS.enabled(d))                                     // on unless turned off
        d.set(false, forKey: RideGPS.settingKey)
        XCTAssertFalse(RideGPS.enabled(d))
        d.set(true, forKey: RideGPS.settingKey)
        XCTAssertTrue(RideGPS.enabled(d))
    }

    // MARK: the home's on-board look backs off (0.28)

    /// Six looks in a row that find nothing (in a car, say): then one every two minutes, until you stop or start again.
    func test_onBoardBackoff() {
        var s = OnBoardBackoff.State()
        var t = t0
        for k in 1...5 {
            s = OnBoardBackoff.looked(s, found: false, at: t)
            XCTAssertEqual(s.empty, k)
            XCTAssertFalse(OnBoardBackoff.holding(s, now: t + 20), "only \(k) empty looks: every 20 s still")
            t += 20
        }
        s = OnBoardBackoff.looked(s, found: false, at: t)
        XCTAssertEqual(s.empty, 6)
        XCTAssertTrue(OnBoardBackoff.holding(s, now: t + 20))
        XCTAssertTrue(OnBoardBackoff.holding(s, now: t + 119))
        XCTAssertFalse(OnBoardBackoff.holding(s, now: t + 120))          // two minutes on: the next look
        XCTAssertFalse(OnBoardBackoff.holding(s, now: t - 5))            // the clock stepped back: don't hold
        // the next empty one keeps it slow
        s = OnBoardBackoff.looked(s, found: false, at: t + 120)
        XCTAssertTrue(OnBoardBackoff.holding(s, now: t + 180))
        // found one: from scratch
        let found = OnBoardBackoff.looked(s, found: true, at: t + 240)
        XCTAssertEqual(found.empty, 0)
        XCTAssertFalse(OnBoardBackoff.holding(found, now: t + 250))
        // stopped (or started) moving: from scratch
        XCTAssertEqual(OnBoardBackoff.reset(), OnBoardBackoff.State())
        XCTAssertFalse(OnBoardBackoff.holding(OnBoardBackoff.reset(), now: t + 250))
    }
}
