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
                      regionLook: Bool = false) -> GPSPolicy.Plan {
        GPSPolicy.plan(phase: phase, demo: demo, going: going, lineWatch: lineWatch, regionLook: regionLook)
    }

    /// On a leg and at a change GPS is always the best, whatever else is open (standing still at a change too: a
    /// coarse fix could see the one you get on more than a look later); idle it's off once nothing needs it (the look
    /// after a station ended, Fastest trip closed, no line watch): the old `watchLeft` left it on for good.
    func test_gpsPolicyMatrix() {
        for going in [false, true] {
            for lineWatch in [false, true] {
                for regionLook in [false, true] {
                    XCTAssertEqual(plan(.riding, going: going, lineWatch: lineWatch, regionLook: regionLook), .best(25))
                    XCTAssertEqual(plan(.transfer, going: going, lineWatch: lineWatch, regionLook: regionLook), .best(25))
                    XCTAssertEqual(plan(.finished, going: going, lineWatch: lineWatch, regionLook: regionLook), .off)
                    XCTAssertEqual(plan(.riding, demo: true, going: going, lineWatch: lineWatch, regionLook: regionLook), .off)
                }
            }
        }
        XCTAssertTrue(plan(.riding).background)
        XCTAssertTrue(plan(.transfer).background)
        XCTAssertEqual(plan(.idle), .off)
        XCTAssertFalse(plan(.idle).background)
        XCTAssertEqual(plan(.idle, regionLook: true), .best(25))
        XCTAssertEqual(plan(.idle, lineWatch: true), .coarse(30))
        XCTAssertEqual(plan(.idle, lineWatch: true, regionLook: true), .best(25))
        XCTAssertEqual(plan(.idle, going: true), .best(10))
        XCTAssertEqual(plan(.idle, going: true, lineWatch: true, regionLook: true), .best(10))
    }

    /// 0.33: waiting for the one you get on (a leg's first stop, or a change) while Motion & Fitness says you stand or
    /// walk about: the rough GPS, as Fastest trip's while you stand; on a ride it's never that.
    func test_waitingLowTier() {
        XCTAssertEqual(GPSPolicy.plan(phase: .riding, demo: false, going: false, lineWatch: false, regionLook: false, waitLow: true), .coarse(50))
        XCTAssertEqual(GPSPolicy.plan(phase: .transfer, demo: false, going: false, lineWatch: false, regionLook: false, waitLow: true), .coarse(50))
        XCTAssertTrue(GPSPolicy.plan(phase: .transfer, demo: false, going: false, lineWatch: false, regionLook: false, waitLow: true).background)
        XCTAssertEqual(GPSPolicy.plan(phase: .riding, demo: false, going: false, lineWatch: false, regionLook: false, waitLow: false), .best(25))
        XCTAssertEqual(GPSPolicy.plan(phase: .idle, demo: false, going: false, lineWatch: false, regionLook: false, waitLow: true), .off)
        XCTAssertEqual(GPSPolicy.plan(phase: .finished, demo: false, going: false, lineWatch: false, regionLook: false, waitLow: true), .off)
        XCTAssertEqual(GPSPolicy.plan(phase: .riding, demo: true, going: false, lineWatch: false, regionLook: false, waitLow: true), .off)
    }

    private func fix(_ dt: TimeInterval, east: Double, speed: Double = 0, accuracy: Double = 10) -> Fix {
        Fix(t: t0 + dt, p: Fx.east(east), accuracy: accuracy, speed: speed, course: 90)
    }

    /// Standing at a change: the anchor holds through jitter; a walk or a ride moves it.
    func test_transferAnchor() {
        var a: TransferPolicy.Anchor?
        a = TransferPolicy.update(a, with: fix(0, east: 0))
        XCTAssertEqual(a?.since, t0)
        for k in 1...12 { a = TransferPolicy.update(a, with: fix(Double(k) * 10, east: Double(k % 3) * 15, speed: 0.3)) }
        XCTAssertEqual(a?.since, t0)                                        // jitter of 30 m: still standing
        a = TransferPolicy.update(a, with: fix(125, east: 40, speed: -1, accuracy: 65))
        XCTAssertEqual(a?.since, t0)                                        // a rough fix 40 m off: still standing
        a = TransferPolicy.update(a, with: fix(126, east: 10, accuracy: -1))
        XCTAssertEqual(a?.since, t0)                                        // no accuracy: says nothing
        // walking (a known speed over 2 km/h) or 70 m off: moving again, from that fix
        XCTAssertEqual(TransferPolicy.update(a, with: fix(130, east: 5, speed: 1.2))?.since, t0 + 130)
        XCTAssertEqual(TransferPolicy.update(a, with: fix(130, east: 70, speed: 0))?.since, t0 + 130)
        XCTAssertEqual(TransferPolicy.update(a, with: fix(130, east: 100, speed: -1, accuracy: 100))?.since, t0)   // ±100: can't tell
        XCTAssertEqual(TransferPolicy.update(a, with: fix(130, east: 200, speed: -1, accuracy: 100))?.since, t0 + 130)
    }

    private func at(_ hh: Int, _ mm: Int) -> Date { t0 + Double(hh * 3600 + mm * 60) }

    /// The hour's end at a change counts from the latest it could still go on: on your own route (nothing planned) from
    /// the first one listed after you got there, and only while you've stood there for 10 minutes.
    func test_transferGiveUpOwnRoute() {
        let arrived = at(23, 40)
        // the first live list after you got off: the last bus left before you got there, the first after it at 00:45
        let list = [TransferPolicy.Listed(id: "late-2310", departure: at(23, 10)),
                    TransferPolicy.Listed(id: "night-0045", departure: at(24, 45)),
                    TransferPolicy.Listed(id: "night-0145", departure: at(25, 45))]
        var first = TransferPolicy.firstListed(nil, live: list, arrived: arrived, listFrom: at(23, 10))
        XCTAssertEqual(first?.id, "night-0045")
        // a later list (asked at 01:20, so from 00:50): it has left the list (aged out), the clock doesn't slide on to the 01:45
        first = TransferPolicy.firstListed(first, live: Array(list.suffix(1)), arrived: arrived, listFrom: at(24, 50))
        XCTAssertEqual(first?.departure, at(24, 45))
        let standing = at(23, 45)
        XCTAssertFalse(TransferPolicy.giveUp(since: arrived, firstKnown: first?.departure, standingSince: standing, now: at(24, 40)))
        XCTAssertFalse(TransferPolicy.giveUp(since: arrived, firstKnown: first?.departure, standingSince: standing, now: at(25, 44)))
        XCTAssertTrue(TransferPolicy.giveUp(since: arrived, firstKnown: first?.departure, standingSince: standing, now: at(25, 45)))
        // not standing at the change (moving in the last 10 minutes), or no fix to tell by: it doesn't end
        XCTAssertFalse(TransferPolicy.giveUp(since: arrived, firstKnown: first?.departure, standingSince: at(25, 40), now: at(25, 46)))
        XCTAssertFalse(TransferPolicy.giveUp(since: arrived, firstKnown: first?.departure, standingSince: nil, now: at(27, 0)))
        // nothing listed at all: an hour from when you got there
        XCTAssertTrue(TransferPolicy.giveUp(since: arrived, firstKnown: nil, standingSince: standing, now: at(24, 40)))
        XCTAssertNil(TransferPolicy.firstListed(nil, live: [list[0]], arrived: arrived, listFrom: at(23, 10)))
    }

    /// A planned train 70 minutes late: it follows its live time while it's listed, and the trip doesn't end early.
    func test_transferGiveUpPlannedLate() {
        let arrived = at(23, 50)
        var planned: TransferPolicy.Listed? = TransferPolicy.Listed(id: "ic-0000", departure: at(24, 0))
        let live = [TransferPolicy.Listed(id: "spr-0015", departure: at(24, 15)), TransferPolicy.Listed(id: "ic-0000", departure: at(25, 10))]
        planned = TransferPolicy.firstListed(planned, live: live, arrived: arrived, listFrom: at(23, 20))
        XCTAssertEqual(planned?.departure, at(25, 10))
        let first = TransferPolicy.firstListed(nil, live: live, arrived: arrived, listFrom: at(23, 20))
        XCTAssertEqual(first?.id, "spr-0015")
        planned = TransferPolicy.firstListed(planned, live: [], arrived: arrived, listFrom: at(24, 50))    // gone from the list
        XCTAssertEqual(planned?.departure, at(25, 10))
        planned = TransferPolicy.firstListed(planned, live: [], arrived: arrived, listFrom: at(25, 30))    // …and aged out
        XCTAssertEqual(planned?.departure, at(25, 10))
        let known = [planned?.departure, first?.departure].compactMap { $0 }.max()
        XCTAssertFalse(TransferPolicy.giveUp(since: arrived, firstKnown: known, standingSince: arrived, now: at(25, 5)))
        XCTAssertFalse(TransferPolicy.giveUp(since: arrived, firstKnown: known, standingSince: arrived, now: at(26, 9)))
        XCTAssertTrue(TransferPolicy.giveUp(since: arrived, firstKnown: known, standingSince: arrived, now: at(26, 10)))
        // by the planned time alone it would have ended at 01:00
        XCTAssertTrue(TransferPolicy.giveUp(since: arrived, firstKnown: at(24, 0), standingSince: arrived, now: at(25, 0)))
    }

    /// A cancelled departure (the planner leaves it out) doesn't keep the clock at its time: the next one listed after
    /// it counts. Off at 08:30, the 08:33 Intercity listed, then cancelled: the 09:45 is still to come.
    func test_transferGiveUpCancelled() {
        let arrived = at(8, 30), standing = at(8, 31)
        let ic0833 = TransferPolicy.Listed(id: "ic-0833", departure: at(8, 33)), ic0945 = TransferPolicy.Listed(id: "ic-0945", departure: at(9, 45))
        var first = TransferPolicy.firstListed(nil, live: [ic0833, ic0945], arrived: arrived, listFrom: at(8, 0))
        XCTAssertEqual(first, ic0833)
        var planned: TransferPolicy.Listed? = ic0833
        // asked at 08:35 (from 08:05): the 08:33 isn't in it any more, and it isn't old: cancelled
        first = TransferPolicy.firstListed(first, live: [ic0945], arrived: arrived, listFrom: at(8, 5))
        planned = TransferPolicy.firstListed(planned, live: [ic0945], arrived: arrived, listFrom: at(8, 5))
        XCTAssertEqual(first, ic0945)
        XCTAssertEqual(planned, ic0945)
        let known = [planned?.departure, first?.departure].compactMap { $0 }.max()
        XCTAssertFalse(TransferPolicy.giveUp(since: arrived, firstKnown: known, standingSince: standing, now: at(9, 33)))
        XCTAssertFalse(TransferPolicy.giveUp(since: arrived, firstKnown: known, standingSince: standing, now: at(10, 44)))
        XCTAssertTrue(TransferPolicy.giveUp(since: arrived, firstKnown: known, standingSince: standing, now: at(10, 45)))
        // nothing listed after it any more: it stays as it was
        XCTAssertEqual(TransferPolicy.firstListed(ic0833, live: [], arrived: arrived, listFrom: at(8, 5)), ic0833)
        // one listed now between you getting there and the cancelled one: the clock never moves back before it
        let spr0835 = TransferPolicy.Listed(id: "spr-0835", departure: at(8, 35))
        XCTAssertEqual(TransferPolicy.firstListed(TransferPolicy.Listed(id: "ic-0840", departure: at(8, 40)), live: [spr0835, ic0945],
                                                  arrived: arrived, listFrom: at(8, 5)), ic0945)
        // only ones before it: it stays too (not moved back)
        let early = TransferPolicy.Listed(id: "spr-0820", departure: at(8, 20))
        XCTAssertEqual(TransferPolicy.firstListed(ic0833, live: [early], arrived: arrived, listFrom: at(8, 5)), ic0833)
    }

    /// Never from a minute before to 3 minutes after one listed for the next leg leaves: you may be sitting on it.
    func test_transferGiveUpNearDeparture() {
        let arrived = at(8, 0), standing = at(8, 1), bus = at(9, 30)
        XCTAssertTrue(TransferPolicy.giveUp(since: arrived, firstKnown: nil, standingSince: standing, listed: [bus], now: at(9, 28)))
        XCTAssertFalse(TransferPolicy.giveUp(since: arrived, firstKnown: nil, standingSince: standing, listed: [bus], now: at(9, 29)))
        XCTAssertFalse(TransferPolicy.giveUp(since: arrived, firstKnown: nil, standingSince: standing, listed: [bus], now: at(9, 33)))
        XCTAssertTrue(TransferPolicy.giveUp(since: arrived, firstKnown: nil, standingSince: standing, listed: [bus], now: at(9, 34)))
    }

    func test_afterArrival() {
        XCTAssertFalse(AfterArrival.quiet(finishedAt: t0, now: t0 + 19))
        XCTAssertTrue(AfterArrival.quiet(finishedAt: t0, now: t0 + 20))
        XCTAssertFalse(AfterArrival.end(finishedAt: t0, now: t0 + 599))
        XCTAssertTrue(AfterArrival.end(finishedAt: t0, now: t0 + 600))
        XCTAssertLessThan(AfterArrival.quietAfter, AfterArrival.endAfter)
    }

    /// The lock screen (0.20.7, `ThriftTests.test_activityThrottle`): real changes only, at most every 30 s, what it
    /// says you should do at once.

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
