import XCTest

final class PowerTests: XCTestCase {
    /// The speed on screen changes only when it's worth drawing again, not on every fix.
    func test_speedPublish() {
        XCTAssertFalse(SpeedPublish.worth(old: nil, new: nil))
        XCTAssertTrue(SpeedPublish.worth(old: nil, new: 0))
        XCTAssertTrue(SpeedPublish.worth(old: 3, new: nil))
        XCTAssertFalse(SpeedPublish.worth(old: 8.2, new: 8.5))
        XCTAssertTrue(SpeedPublish.worth(old: 8.2, new: 8.7))
        XCTAssertTrue(SpeedPublish.worth(old: 0.9, new: 1.1))            // "standing still" ⇄ a speed on the ride screen
        XCTAssertFalse(SpeedPublish.worth(old: 0.2, new: 0.6))
    }

    /// The regions iOS watches already are left alone when they're the ones wanted; any difference registers them again.
    func test_regionsSame() {
        let a = [RegionSpec(id: "school", lat: 51.59, lon: 4.78, radius: 400, entry: true, exit: false),
                 RegionSpec(id: "veghel", lat: 51.61, lon: 5.54, radius: 350, entry: false, exit: true)]
        XCTAssertTrue(RegionPlan.same(wanted: a, current: a.reversed()))
        XCTAssertTrue(RegionPlan.same(wanted: [], current: []))
        XCTAssertFalse(RegionPlan.same(wanted: a, current: [a[0]]))
        XCTAssertFalse(RegionPlan.same(wanted: [], current: [a[0]]))
        var moved = a; moved[1] = RegionSpec(id: "veghel", lat: 51.62, lon: 5.54, radius: 350, entry: false, exit: true)
        XCTAssertFalse(RegionPlan.same(wanted: a, current: moved))
        var wider = a; wider[1] = RegionSpec(id: "veghel", lat: 51.61, lon: 5.54, radius: 300, entry: false, exit: true)
        XCTAssertFalse(RegionPlan.same(wanted: a, current: wider))
        var told = a; told[0] = RegionSpec(id: "school", lat: 51.59, lon: 4.78, radius: 400, entry: true, exit: true)
        XCTAssertFalse(RegionPlan.same(wanted: a, current: told))
        let unknown = RegionSpec(id: "school", lat: .nan, lon: .nan, radius: -1, entry: true, exit: false)
        XCTAssertFalse(RegionPlan.same(wanted: [a[0]], current: [unknown]))
        XCTAssertFalse(RegionPlan.same(wanted: a, current: [a[0], a[0]]))         // the same id twice
    }

    private let t0 = Fx.t0

    private func plan(_ phase: GPSPolicy.Phase, demo: Bool = false, going: Bool = false, lineWatch: Bool = false,
                      regionLook: Bool = false, still: Bool = false) -> GPSPolicy.Plan {
        GPSPolicy.plan(phase: phase, demo: demo, going: going, lineWatch: lineWatch, regionLook: regionLook, transferStill: still)
    }

    /// On a leg GPS is always the best, whatever else is open; idle it's off once nothing needs it (the look after a
    /// station ended, Fastest trip closed, no line watch): the old `watchLeft` left it on for good.
    func test_gpsPolicyMatrix() {
        for going in [false, true] {
            for lineWatch in [false, true] {
                for regionLook in [false, true] {
                    for still in [false, true] {
                        XCTAssertEqual(plan(.riding, going: going, lineWatch: lineWatch, regionLook: regionLook, still: still), .best(25))
                        XCTAssertEqual(plan(.finished, going: going, lineWatch: lineWatch, regionLook: regionLook, still: still), .off)
                        XCTAssertEqual(plan(.riding, demo: true, going: going, lineWatch: lineWatch, regionLook: regionLook), .off)
                    }
                }
            }
        }
        XCTAssertTrue(plan(.riding).background)
        XCTAssertEqual(plan(.idle), .off)
        XCTAssertFalse(plan(.idle).background)
        XCTAssertEqual(plan(.idle, regionLook: true), .best(25))
        XCTAssertEqual(plan(.idle, lineWatch: true), .coarse(30))
        XCTAssertEqual(plan(.idle, lineWatch: true, regionLook: true), .best(25))
        XCTAssertEqual(plan(.idle, going: true), .best(10))
        XCTAssertEqual(plan(.idle, going: true, lineWatch: true, regionLook: true), .best(10))
        XCTAssertEqual(plan(.idle, still: true), .off)
        XCTAssertEqual(plan(.transfer), .best(25))
        XCTAssertEqual(plan(.transfer, still: true), .coarse(50))
        XCTAssertTrue(plan(.transfer, still: true).background)
    }

    private func fix(_ dt: TimeInterval, east: Double, speed: Double = 0, accuracy: Double = 10) -> Fix {
        Fix(t: t0 + dt, p: Fx.east(east), accuracy: accuracy, speed: speed, course: 90)
    }

    /// Standing at a change: the anchor holds through jitter, a walk or a ride moves it; still after 2 minutes, and only
    /// while the next one is more than 3 minutes off.
    func test_transferStill() {
        var a: TransferPolicy.Anchor?
        a = TransferPolicy.update(a, with: fix(0, east: 0))
        XCTAssertEqual(a?.since, t0)
        for k in 1...12 { a = TransferPolicy.update(a, with: fix(Double(k) * 10, east: Double(k % 3) * 15, speed: 0.3)) }
        XCTAssertEqual(a?.since, t0)                                        // jitter of 30 m: still standing
        a = TransferPolicy.update(a, with: fix(125, east: 40, speed: -1, accuracy: 65))
        XCTAssertEqual(a?.since, t0)                                        // a rough fix 40 m off: still standing
        a = TransferPolicy.update(a, with: fix(126, east: 10, accuracy: -1))
        XCTAssertEqual(a?.since, t0)                                        // no accuracy: says nothing
        let dep = t0 + 600
        XCTAssertFalse(TransferPolicy.still(anchor: a, nextDeparture: dep, now: t0 + 119))
        XCTAssertTrue(TransferPolicy.still(anchor: a, nextDeparture: dep, now: t0 + 120))
        XCTAssertTrue(TransferPolicy.still(anchor: a, nextDeparture: dep, now: dep - 181))
        XCTAssertFalse(TransferPolicy.still(anchor: a, nextDeparture: dep, now: dep - 180))       // the best again in time
        XCTAssertFalse(TransferPolicy.still(anchor: a, nextDeparture: nil, now: t0 + 300))        // none known: best
        XCTAssertFalse(TransferPolicy.still(anchor: nil, nextDeparture: dep, now: t0 + 300))
        // walking (a known speed over 2 km/h) or 70 m off: moving again, from that fix
        let walk = TransferPolicy.update(a, with: fix(130, east: 5, speed: 1.2))
        XCTAssertEqual(walk?.since, t0 + 130)
        let off = TransferPolicy.update(a, with: fix(130, east: 70, speed: 0))
        XCTAssertEqual(off?.since, t0 + 130)
        let rough = TransferPolicy.update(a, with: fix(130, east: 100, speed: -1, accuracy: 100))
        XCTAssertEqual(rough?.since, t0)                                    // 100 m with ±100: not enough to tell
        XCTAssertEqual(TransferPolicy.update(a, with: fix(130, east: 200, speed: -1, accuracy: 100))?.since, t0 + 130)
    }

    /// The next one: the earliest that hasn't left (a minute's grace).
    func test_nextDeparture() {
        XCTAssertEqual(TransferPolicy.nextDeparture([t0 + 600, t0 - 30, t0 - 120, t0 + 300], now: t0), t0 - 30)
        XCTAssertEqual(TransferPolicy.nextDeparture([t0 + 600, t0 - 120, t0 + 300], now: t0), t0 + 300)
        XCTAssertNil(TransferPolicy.nextDeparture([t0 - 120], now: t0))
        XCTAssertNil(TransferPolicy.nextDeparture([], now: t0))
    }

    /// An hour after the change (or after the next one was planned to leave, when later), standing about: the trip ends.
    func test_transferGiveUp() {
        XCTAssertFalse(TransferPolicy.giveUp(since: t0, nextPlanned: nil, moving: false, now: t0 + 3599))
        XCTAssertTrue(TransferPolicy.giveUp(since: t0, nextPlanned: nil, moving: false, now: t0 + 3600))
        XCTAssertFalse(TransferPolicy.giveUp(since: t0, nextPlanned: nil, moving: true, now: t0 + 7200))       // on the move
        XCTAssertFalse(TransferPolicy.giveUp(since: t0, nextPlanned: t0 + 1200, moving: false, now: t0 + 4000))
        XCTAssertTrue(TransferPolicy.giveUp(since: t0, nextPlanned: t0 + 1200, moving: false, now: t0 + 4800))
        XCTAssertTrue(TransferPolicy.giveUp(since: t0, nextPlanned: t0 - 600, moving: false, now: t0 + 3600))   // planned before you got there
    }

    func test_afterArrival() {
        XCTAssertFalse(AfterArrival.quiet(finishedAt: t0, now: t0 + 19))
        XCTAssertTrue(AfterArrival.quiet(finishedAt: t0, now: t0 + 20))
        XCTAssertFalse(AfterArrival.end(finishedAt: t0, now: t0 + 599))
        XCTAssertTrue(AfterArrival.end(finishedAt: t0, now: t0 + 600))
        XCTAssertLessThan(AfterArrival.quietAfter, AfterArrival.endAfter)
    }

    /// The lock screen: distance and progress every 30 s while far, every 8 s near the stop (3 km, 5 minutes); a forced
    /// update or a change of what it says goes at once.
    func test_activityThrottle() {
        func send(force: Bool = false, changed: Bool = true, say: Bool = false, since: TimeInterval, d: Double?, s: TimeInterval?) -> Bool {
            ActivityThrottle.send(force: force, changed: changed, phaseChanged: say, sinceLast: since, metresToStop: d, secondsToStop: s)
        }
        XCTAssertFalse(send(since: 20, d: 12_000, s: 900))
        XCTAssertTrue(send(since: 31, d: 12_000, s: 900))
        XCTAssertFalse(send(changed: false, since: 60, d: 12_000, s: 900))           // nothing changed: nothing to send
        XCTAssertTrue(send(since: 9, d: 2_500, s: 900))                               // within 3 km: as before
        XCTAssertFalse(send(since: 7, d: 2_500, s: 900))
        XCTAssertTrue(send(since: 9, d: 12_000, s: 240))                              // under 5 minutes: as before
        XCTAssertTrue(send(since: 9, d: 3_000, s: nil))
        XCTAssertFalse(send(since: 9, d: 3_001, s: nil))
        XCTAssertTrue(send(since: 9, d: nil, s: nil))                                 // not known: as before
        XCTAssertTrue(send(force: true, changed: false, since: 0, d: 12_000, s: 900))  // the alarm, a phase, the vehicle
        XCTAssertTrue(send(changed: true, say: true, since: 1, d: 12_000, s: 900))      // awake, the kicker, the title
        XCTAssertEqual(ActivityThrottle.gap(metresToStop: 12_000, secondsToStop: 900), 30)
        XCTAssertEqual(ActivityThrottle.gap(metresToStop: .nan, secondsToStop: 900), 8)
    }

    /// The same map answer for a look within 10 s and 50 m, only where it's allowed.
    func test_mapReuse() {
        XCTAssertTrue(MapReuse.usable(age: 6, movedMetres: 20, allowed: true))
        XCTAssertTrue(MapReuse.usable(age: 10, movedMetres: 50, allowed: true))
        XCTAssertFalse(MapReuse.usable(age: 10.5, movedMetres: 20, allowed: true))
        XCTAssertFalse(MapReuse.usable(age: 6, movedMetres: 51, allowed: true))      // a bus at 9 m/s moves 54 m in 6 s
        XCTAssertFalse(MapReuse.usable(age: 6, movedMetres: 20, allowed: false))     // on a ride, at a change
        XCTAssertFalse(MapReuse.usable(age: -1, movedMetres: 20, allowed: true))     // a clock step back
        XCTAssertFalse(MapReuse.usable(age: 6, movedMetres: .nan, allowed: true))
    }
}
