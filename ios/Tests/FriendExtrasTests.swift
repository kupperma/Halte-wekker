import XCTest

/// Friends 0.29 (the extras): "Wait for me", the delay alarm for shared rides, the wake-up buddy and who's on campus,
/// as plain rules (docs/superpowers/specs/2026-11-18-friends-design.md, "As built (0.29)").
final class FriendExtrasTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)          // Friday 15 January 2027, 09:00 in Amsterdam
    let ehv = TripCard.Spot(name: "Eindhoven Centraal", lat: 51.44306, lon: 5.47917)
    let bd = TripCard.Spot(name: "Breda", lat: 51.59556, lon: 4.78)
    let tb = TripCard.Spot(name: "Tilburg", lat: 51.56056, lon: 5.08333)

    private func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private func ride(_ trip: String, line: String = "IC", num: String? = "3512", from: TripCard.Spot? = nil, to: TripCard.Spot? = nil,
                      dep: TimeInterval, arr: TimeInterval, bus: Bool = false) -> TripCard.Ride {
        TripCard.Ride(mode: bus ? "bus" : "train", line: line, num: num, trip: trip, from: from ?? ehv, to: to ?? bd, dep: t(dep), arr: t(arr))
    }

    private func wait(_ state: String = "coming", dist: Int? = 300, eta: TimeInterval? = 120, at: TimeInterval = 0,
                      ride r: TripCard.Ride? = nil) -> WaitFor {
        WaitFor(id: "w1", state: state, stop: ehv, ride: r, dist: dist, eta: eta.map(t), at: t(at))
    }

    // MARK: wait for me

    func test_waitIds() {
        XCTAssertTrue(WaitRules.validId("vector-wait-1"))
        XCTAssertTrue(WaitRules.validId("Ab_9-"))
        XCTAssertFalse(WaitRules.validId(""))
        XCTAssertFalse(WaitRules.validId(String(repeating: "a", count: 33)))
        XCTAssertFalse(WaitRules.validId("no spaces"))
        XCTAssertFalse(WaitRules.validId("slash/"))
    }

    func test_waitValid() {
        XCTAssertNotNil(WaitFor.valid(wait()))
        var w = wait()
        w.id = "bad id"
        XCTAssertNil(WaitFor.valid(w))
        w = wait()
        w.stop = TripCard.Spot(name: "Somewhere")
        XCTAssertNil(WaitFor.valid(w), "a stop without a place")
        w = wait(dist: -5)
        XCTAssertNil(WaitFor.valid(w)?.dist)
        w = wait(ride: ride("", dep: 600, arr: 3600))
        XCTAssertNil(WaitFor.valid(w)?.ride, "a ride without a trip id goes")
        XCTAssertEqual(wait("later").phase, .coming, "an unknown state reads as coming")
    }

    func test_waitPhase() {
        XCTAssertEqual(WaitRules.phase(dist: 300, started: t0, rideDep: t(600), now: t(60)), .coming)
        XCTAssertEqual(WaitRules.phase(dist: 35, started: t0, rideDep: t(600), now: t(60)), .there)
        XCTAssertEqual(WaitRules.phase(dist: nil, started: t0, rideDep: nil, now: t(60)), .coming)
        XCTAssertNil(WaitRules.phase(dist: 300, started: t0, rideDep: nil, now: t(31 * 60)), "over after 30 minutes")
        XCTAssertNil(WaitRules.phase(dist: 300, started: t0, rideDep: t(600), now: t(600 + 121)), "over 2 minutes after the ride left")
        XCTAssertEqual(WaitRules.phase(dist: 300, started: t0, rideDep: t(600), now: t(600 + 119)), .coming)
    }

    func test_waitEta() {
        // 300 m: a third longer by the streets at 1.2 m/s, whole minutes up: 6 min
        XCTAssertEqual(WaitRules.eta(dist: 300, now: t0), t(6 * 60))
        XCTAssertEqual(WaitRules.eta(dist: 30, now: t0), t0)
        XCTAssertEqual(WaitRules.eta(dist: 41, now: t0), t(60))
    }

    func test_waitDue() {
        let a = wait(dist: 300)
        XCTAssertTrue(WaitRules.due(last: nil, lastSent: nil, next: a, now: t0))
        XCTAssertTrue(WaitRules.due(last: a, lastSent: t0, next: wait("there", dist: 20), now: t(5)), "a new phase goes at once")
        XCTAssertFalse(WaitRules.due(last: a, lastSent: t0, next: wait(dist: 200), now: t(10)), "not within 20 s")
        XCTAssertTrue(WaitRules.due(last: a, lastSent: t0, next: wait(dist: 270), now: t(30)), "moved 30 m")
        XCTAssertFalse(WaitRules.due(last: a, lastSent: t0, next: wait(dist: 290), now: t(30)), "moved 10 m")
        XCTAssertTrue(WaitRules.due(last: a, lastSent: t0, next: wait(dist: 300, eta: 200), now: t(30)), "there a minute later")
        XCTAssertTrue(WaitRules.due(last: a, lastSent: t0, next: a, now: t(60)), "again after a minute")
    }

    func test_waitWords() {
        XCTAssertEqual(WaitWords.line("Sam", wait(dist: 300, eta: 120), now: t0), "Sam is 2 min from the stop (300 m)")
        XCTAssertEqual(WaitWords.line("Sam", wait(dist: 80, eta: 30), now: t0), "Sam is 1 min from the stop (80 m)")
        XCTAssertEqual(WaitWords.line("Sam", wait(dist: 80, eta: 0), now: t0), "Sam is under a minute from the stop (80 m)")
        XCTAssertEqual(WaitWords.line("Sam", wait(dist: 300, eta: nil), now: t0), "Sam is 300 m from the stop")
        XCTAssertEqual(WaitWords.line("Sam", wait(dist: nil, eta: nil), now: t0), "Sam is on the way to the stop")
        XCTAssertEqual(WaitWords.line("Sam", wait("there", dist: 10), now: t0), "Sam is at the stop")
        XCTAssertEqual(WaitWords.metres(295), "300 m")
        XCTAssertEqual(WaitWords.metres(1234), "1.2 km")
        let r = ride("ic-3512", dep: 60, arr: 3000)
        XCTAssertEqual(WaitWords.detail("Sam", wait(eta: 120, ride: r)),
                       "At Eindhoven Centraal · for the IC 3512 at 09:01 · it leaves before Sam gets there")
        XCTAssertEqual(WaitWords.detail("Sam", wait(eta: 30, ride: r)), "At Eindhoven Centraal · for the IC 3512 at 09:01")
        XCTAssertEqual(WaitWords.mine("Lisa", wait(dist: 300)), "Asked Lisa to wait · you’re 300 m from the stop")
        XCTAssertEqual(WaitWords.mine("Lisa", wait("there", dist: 5)), "Asked Lisa to wait · you’re at the stop")
        XCTAssertEqual(WaitAnswer.wait.text, "I’ll wait")
        XCTAssertEqual(WaitAnswer(rawValue: "next"), .next)
    }

    func test_waitAge() {
        let s = WaitSeen(from: "sam", chat: "sam", wait: wait(at: 0), t: 1_800_000_000, got: t0)
        XCTAssertEqual(WaitAge.freshness(s, now: t(60)), .fresh)
        XCTAssertEqual(WaitAge.freshness(s, now: t(120)), .stale)
        XCTAssertEqual(WaitAge.freshness(s, now: t(16 * 60)), .gone)
        var off = s
        off.wait.state = "off"
        XCTAssertEqual(WaitAge.freshness(off, now: t(10)), .gone)
        var left = s
        left.wait.ride = ride("ic", dep: 0, arr: 3000)
        XCTAssertEqual(WaitAge.freshness(left, now: t(4 * 60)), .stale)
        XCTAssertEqual(WaitAge.freshness(left, now: t(6 * 60)), .gone, "its ride left 5 minutes ago")
    }

    func test_waitNext() {
        let far = TripCard.Spot(name: "Elsewhere", lat: 51.50, lon: 5.40)
        func way(_ trip: String, line: String, from: TripCard.Spot, dep: TimeInterval) -> Way {
            let l = WayLeg(trip: trip, mode: "train", line: line, from: from, to: bd, dep: t(dep), arr: t(dep + 3000))
            return Way(legs: [l], start: t(dep - 120), end: t(dep + 3000))
        }
        let ways: [Way] = [
            way("missed", line: "IC", from: ehv, dep: 300),
            way("spr", line: "SPR", from: ehv, dep: 600),
            way("ic-next", line: "IC", from: ehv, dep: 1200),
            way("far", line: "IC", from: far, dep: 400),
        ]
        let stop = GeoPoint(lat: 51.44306, lon: 5.47917)
        // the same line when it comes within 15 minutes of the first
        XCTAssertEqual(WaitNext.pick(ways, stop: stop, after: t(200), exclude: "missed", line: "IC")?.legs.first?.trip, "ic-next")
        XCTAssertEqual(WaitNext.pick(ways, stop: stop, after: t(200), exclude: "missed", line: nil)?.legs.first?.trip, "spr")
        XCTAssertEqual(WaitNext.pick(ways, stop: stop, after: t(200), exclude: nil, line: "IC")?.legs.first?.trip, "missed")
        XCTAssertNil(WaitNext.pick(ways, stop: stop, after: t(1300), exclude: nil, line: nil))
    }

    // MARK: the delay alarm

    func test_shouldTell() {
        XCTAssertFalse(DelayAlarm.shouldTell(late: 2, cancelled: false, told: nil))
        XCTAssertTrue(DelayAlarm.shouldTell(late: 3, cancelled: false, told: nil))
        let told = DelayTold(late: 4, cancelled: false, at: t0)
        XCTAssertFalse(DelayAlarm.shouldTell(late: 5, cancelled: false, told: told))
        XCTAssertTrue(DelayAlarm.shouldTell(late: 6, cancelled: false, told: told))
        XCTAssertTrue(DelayAlarm.shouldTell(late: 0, cancelled: true, told: told))
        XCTAssertFalse(DelayAlarm.shouldTell(late: 0, cancelled: true, told: DelayTold(late: 0, cancelled: true, at: t0)))
        XCTAssertFalse(DelayAlarm.shouldTell(late: 1, cancelled: false, told: told), "back on time isn't an alarm")
    }

    func test_watchedAndLookDue() {
        XCTAssertTrue(DelayAlarm.watched(ride("a", dep: 3600, arr: 7200), now: t0))
        XCTAssertFalse(DelayAlarm.watched(ride("a", dep: 100 * 60, arr: 9000), now: t0), "more than 90 minutes ahead")
        XCTAssertTrue(DelayAlarm.watched(ride("a", dep: -600, arr: 600), now: t0), "on it")
        XCTAssertFalse(DelayAlarm.watched(ride("a", dep: -1200, arr: -60), now: t0), "in already")
        XCTAssertTrue(DelayAlarm.lookDue(last: nil, now: t0))
        XCTAssertFalse(DelayAlarm.lookDue(last: t0, now: t(100)))
        XCTAssertTrue(DelayAlarm.lookDue(last: t0, now: t(120)))
    }

    private func stop(_ s: TripCard.Spot, dep: TimeInterval?, sched: TimeInterval?, cancelled: Bool = false) -> BoardAt.Stop {
        var x = BoardAt.Stop(id: s.name, name: s.name, point: s.point!, departure: dep.map(t))
        x.scheduledDeparture = sched.map(t)
        x.cancelled = cancelled
        return x
    }

    func test_delayRead() throws {
        let stops = [stop(ehv, dep: 360, sched: 0), stop(tb, dep: 1800, sched: 1320), stop(bd, dep: nil, sched: nil)]
        let a = try XCTUnwrap(DelayAlarm.read(stops, board: ehv, now: t0))
        XCTAssertEqual(a.late, 6)
        XCTAssertFalse(a.cancelled)
        XCTAssertEqual(a.dep, t(360))
        // past your stop (on it): at its next stop
        let b = try XCTUnwrap(DelayAlarm.read(stops, board: ehv, now: t(600)))
        XCTAssertEqual(b.late, 8)
        // by name when the place doesn't match
        let c = try XCTUnwrap(DelayAlarm.read(stops, board: TripCard.Spot(name: "Tilburg"), now: t0))
        XCTAssertEqual(c.late, 8)
        // cancelled at your stop, or everywhere
        let d = [stop(ehv, dep: 0, sched: 0, cancelled: true), stop(bd, dep: 3000, sched: 3000)]
        XCTAssertEqual(DelayAlarm.read(d, board: ehv, now: t0)?.cancelled, true)
        let e = [stop(ehv, dep: 0, sched: 0, cancelled: true), stop(bd, dep: 3000, sched: 3000, cancelled: true)]
        XCTAssertEqual(DelayAlarm.read(e, board: TripCard.Spot(name: "Nowhere"), now: t0)?.cancelled, true)
        XCTAssertNil(DelayAlarm.read(stops, board: TripCard.Spot(name: "Nowhere"), now: t0))
        XCTAssertNil(DelayAlarm.read([], board: ehv, now: t0))
    }

    func test_nextTogether() {
        func way(_ legs: [(String, TripCard.Spot, TimeInterval)]) -> Way {
            let l: [WayLeg] = legs.map { WayLeg(trip: $0.0, mode: "train", line: "IC", from: $0.1, to: bd, dep: t($0.2), arr: t($0.2 + 2400)) }
            return Way(legs: l, start: t(legs[0].2 - 60), end: t(legs[0].2 + 2400))
        }
        let me = PersonWays(id: "me", ways: [way([("bad", ehv, 360)]), way([("ic-3516", ehv, 1800)]), way([("ic-3520", ehv, 3600)])], bound: t(60))
        let lisa = PersonWays(id: "lisa", ways: [way([("bad", ehv, 360)]), way([("ic-3516", ehv, 1800)]), way([("ic-3520", ehv, 3600)])], bound: t(60))
        let sam = PersonWays(id: "sam", ways: [way([("bad", tb, 1500)]), way([("ic-3520", tb, 4900)])], bound: t(60))
        // everyone on 3520; 3516 has only two of you
        XCTAssertEqual(DelayAlarm.next([me, lisa, sam], exclude: "bad", after: t(120))?.trip, "ic-3520")
        XCTAssertEqual(DelayAlarm.next([me, lisa], exclude: "bad", after: t(120))?.trip, "ic-3516")
        XCTAssertEqual(DelayAlarm.next([me, lisa], exclude: "bad", after: t(120))?.riders.count, 2)
        XCTAssertNil(DelayAlarm.next([me], exclude: "bad", after: t(120)))
    }

    func test_sharedRides() {
        let mine = [ride("ic-3512", dep: 600, arr: 3600)]
        var lisa = TravelState(state: "waiting", mode: "train", from: TravelState.Spot(name: "Eindhoven Centraal", lat: 51.44306, lon: 5.47917),
                               to: TravelState.Spot(name: "Breda"))
        lisa.trip = "ic-3512"
        var other = lisa
        other.trip = "elsewhere"
        let card = TripCard(rides: [ride("b305", line: "305", num: nil, dep: 300, arr: 500, bus: true), ride("ic-3512", from: tb, dep: 1500, arr: 3600)],
                            to: bd)
        let refs = DelayAlarm.shared(mine: mine, travel: [(from: "lisa", state: lisa), (from: "tom", state: other)],
                                     cards: [(card: card, riders: ["sam", "lisa"])], me: "me", now: t0)
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(refs.first?.ride.trip, "ic-3512")
        XCTAssertEqual(refs.first?.ride.from.name, "Eindhoven Centraal", "your own ride when your trip has it")
        XCTAssertEqual(refs.first?.riders, ["lisa", "sam"])
        XCTAssertEqual(refs.first?.spots["sam"]?.first?.name, "Tilburg")
        // a card's shared ride (its first train) by itself
        let only = DelayAlarm.shared(mine: [], travel: [], cards: [(card: card, riders: ["sam"])], me: "me", now: t0)
        XCTAssertEqual(only.first?.ride.from.name, "Tilburg")
        // nobody else on it: nothing
        XCTAssertTrue(DelayAlarm.shared(mine: mine, travel: [], cards: [], me: "me", now: t0).isEmpty)
    }

    func test_cardRiders() {
        XCTAssertEqual(DelayAlarm.riders(sender: "me", answers: ["lisa": .yes, "tom": .no], me: "me"), ["lisa"])
        XCTAssertEqual(DelayAlarm.riders(sender: "sam", answers: ["me": .yes, "lisa": .yes], me: "me"), ["sam", "lisa"])
        XCTAssertNil(DelayAlarm.riders(sender: "sam", answers: ["me": .no], me: "me"), "you're not in")
        XCTAssertNil(DelayAlarm.riders(sender: "sam", answers: [:], me: "me"))
    }

    func test_delayWords() {
        var d = RideDelay(ride: ride("ic-3512", dep: 360, arr: 3600), late: 6)
        d.next = ride("ic-3516", num: "3516", dep: 1800, arr: 4800)
        XCTAssertEqual(DelayWords.title(d), "IC 3512 is 6 min late")
        XCTAssertEqual(DelayWords.body(d, names: ["you", "Lisa", "Sam"]),
                       "You, Lisa and Sam are on it. It now leaves Eindhoven Centraal at 09:06. Next you can all take: IC 3516 at 09:30 from Eindhoven Centraal.")
        var c = RideDelay(ride: ride("b305", line: "305", num: nil, dep: 0, arr: 600, bus: true), late: 0, cancelled: true)
        XCTAssertEqual(DelayWords.title(c), "Bus 305 is cancelled")
        XCTAssertEqual(DelayWords.body(c, names: ["Lisa"]), "Lisa is on it. Look for another way in Fastest trip.")
        c.who = Array(repeating: "x", count: 30)
        XCTAssertEqual(RideDelay.valid(c)?.who?.count, 20)
        XCTAssertNil(RideDelay.valid(RideDelay(ride: ride("", dep: 0, arr: 60), late: 4)))
    }

    // MARK: the wake-up buddy

    func test_buddyPlan() throws {
        let today = TimetableDays.key(t0)
        XCTAssertEqual(today, "2027-01-15")
        let r = ride("ic-3512", dep: -4740, arr: -1680)
        let b = BuddyPlan(on: true, day: today, leave: t(-6000), ride: r)
        let p = try XCTUnwrap(BuddyRules.plan(b, cards: [], today: today))
        XCTAssertEqual(p.leave, t(-6000))
        XCTAssertEqual(p.ride?.trip, "ic-3512")
        // another day, or off: not this one
        XCTAssertNil(BuddyRules.plan(BuddyPlan(on: true, day: "2027-01-14", leave: t(-90000)), cards: [], today: today))
        XCTAssertNil(BuddyRules.plan(BuddyPlan(on: false, day: today, leave: t(-6000)), cards: [], today: today))
        // a card they sent: its start; one they're in on: 15 minutes before the shared ride
        var card = TripCard(rides: [ride("ic-3512", dep: 1200, arr: 4000)], to: bd)
        card.start = t(600)
        XCTAssertEqual(BuddyRules.plan(nil, cards: [(card: card, sent: true)], today: today)?.leave, t(600))
        XCTAssertEqual(BuddyRules.plan(nil, cards: [(card: card, sent: false)], today: today)?.leave, t(300))
        // their own plan first
        XCTAssertEqual(BuddyRules.plan(b, cards: [(card: card, sent: true)], today: today)?.leave, t(-6000))
    }

    func test_buddyAlert() {
        let today = TimetableDays.key(t0)
        let leave = t(0)
        let r = ride("ic", dep: 1260, arr: 4000)
        XCTAssertFalse(BuddyRules.alert(leave: leave, ride: r, moving: false, told: nil, today: today, now: t(4 * 60)), "within 5 minutes")
        XCTAssertTrue(BuddyRules.alert(leave: leave, ride: r, moving: false, told: nil, today: today, now: t(5 * 60)))
        XCTAssertTrue(BuddyRules.alert(leave: leave, ride: r, moving: false, told: nil, today: today, now: t(1260 + 600)))
        XCTAssertFalse(BuddyRules.alert(leave: leave, ride: r, moving: false, told: nil, today: today, now: t(1260 + 601)), "too late to matter")
        XCTAssertFalse(BuddyRules.alert(leave: leave, ride: r, moving: true, told: nil, today: today, now: t(600)))
        XCTAssertFalse(BuddyRules.alert(leave: leave, ride: r, moving: false, told: today, today: today, now: t(600)), "once a morning")
        XCTAssertTrue(BuddyRules.alert(leave: leave, ride: r, moving: false, told: "2027-01-14", today: today, now: t(600)))
        XCTAssertFalse(BuddyRules.alert(leave: t(-86400), ride: nil, moving: false, told: nil, today: today, now: t(600)), "another day's plan")
        // without a ride: until 15 minutes after leaving
        XCTAssertTrue(BuddyRules.alert(leave: leave, ride: nil, moving: false, told: nil, today: today, now: t(900)))
        XCTAssertFalse(BuddyRules.alert(leave: leave, ride: nil, moving: false, told: nil, today: today, now: t(901)))
    }

    func test_buddyMovingAndDue() {
        XCTAssertTrue(BuddyRules.moving(left: t(-600), seen: [], leave: t0))
        XCTAssertFalse(BuddyRules.moving(left: t(-4000), seen: [], leave: t0), "yesterday's leaving doesn't count")
        XCTAssertTrue(BuddyRules.moving(left: nil, seen: [t(-60)], leave: t0), "a trip of theirs came")
        XCTAssertFalse(BuddyRules.moving(left: nil, seen: [], leave: t0))
        let p = BuddyPlan(on: true, day: "2027-01-15", leave: t0)
        XCTAssertTrue(BuddyRules.due(last: nil, lastAt: nil, next: p, now: t0))
        XCTAssertFalse(BuddyRules.due(last: p, lastAt: t0, next: p, now: t(3600)))
        XCTAssertTrue(BuddyRules.due(last: p, lastAt: t0, next: p, now: t(12 * 3600)))
        var left = p
        left.left = t(60)
        XCTAssertTrue(BuddyRules.due(last: p, lastAt: t0, next: left, now: t(120)), "leaving goes at once")
    }

    func test_buddyWords() {
        let r = ride("ic", dep: -4740, arr: -1680)
        XCTAssertEqual(BuddyWords.title("Lisa", leave: t(-6000), ride: r), "Lisa isn’t moving yet — their train is at 07:41")
        XCTAssertEqual(BuddyWords.title("Lisa", leave: t(-6000), ride: nil), "Lisa isn’t moving yet — they planned to leave at 07:20")
        XCTAssertEqual(BuddyWords.body("Lisa", leave: t(-6000), ride: r),
                       "Lisa planned to leave at 07:20 for the IC 3512 from Eindhoven Centraal. Maybe send a message?")
    }

    // MARK: who's on campus

    func test_campusInside() {
        XCTAssertEqual(CampusRules.inside(distance: 300, radius: 350, was: false), true)
        XCTAssertEqual(CampusRules.inside(distance: 450, radius: 350, was: true), true, "at the edge: as it was")
        XCTAssertEqual(CampusRules.inside(distance: 450, radius: 350, was: false), false)
        XCTAssertEqual(CampusRules.inside(distance: 501, radius: 350, was: true), false)
        XCTAssertNil(CampusRules.inside(distance: nil, radius: 350, was: true))
    }

    func test_campusDecide() {
        let friends = ["lisa", "tom"]
        XCTAssertEqual(CampusRules.decide(on: true, inside: true, since: t0, posted: nil, friends: friends, now: t(60)),
                       .post(since: t0, to: friends))
        XCTAssertEqual(CampusRules.decide(on: false, inside: true, since: t0, posted: nil, friends: friends, now: t(60)), .none, "off by default")
        XCTAssertEqual(CampusRules.decide(on: true, inside: false, since: nil, posted: nil, friends: friends, now: t(60)), .none)
        XCTAssertEqual(CampusRules.decide(on: true, inside: nil, since: nil, posted: nil, friends: friends, now: t(60)), .none)
        let p = CampusPosted(since: t0, until: CampusRules.until(since: t0), to: ["lisa"])
        XCTAssertEqual(CampusRules.decide(on: true, inside: true, since: t0, posted: p, friends: friends, now: t(60)),
                       .post(since: t0, to: ["tom"]), "a new friend gets it too")
        XCTAssertEqual(CampusRules.decide(on: true, inside: nil, since: t0, posted: p, friends: ["lisa"], now: t(60)), .none, "not known: as it was")
        XCTAssertEqual(CampusRules.decide(on: true, inside: false, since: nil, posted: p, friends: friends, now: t(60)), .clear(["lisa"]))
        XCTAssertEqual(CampusRules.decide(on: false, inside: true, since: t0, posted: p, friends: friends, now: t(60)), .clear(["lisa"]))
        XCTAssertEqual(CampusRules.decide(on: true, inside: true, since: t0, posted: p, friends: friends, now: t(10 * 3600)), .clear(["lisa"]),
                       "after 10 hours")
        XCTAssertEqual(CampusRules.decide(on: true, inside: true, since: t0, posted: nil, friends: friends, now: t(10 * 3600 + 60)), .none,
                       "not again until you've left")
    }

    func test_campusSeen() {
        let s = CampusState(on: true, school: "BUas", since: t(-3300), until: CampusRules.until(since: t(-3300)))
        let seen = CampusSeen(state: s, t: 1_800_000_000, got: t0)
        XCTAssertTrue(CampusRules.here(seen, now: t0))
        XCTAssertFalse(CampusRules.here(seen, now: t(10 * 3600)))
        XCTAssertFalse(CampusRules.here(CampusSeen(state: CampusState(on: false), t: 1_800_000_000, got: t0), now: t0))
        let long = CampusSeen(state: CampusState(on: true, since: t(-60), until: t(20 * 3600)), t: 1_800_000_000, got: t0)
        XCTAssertFalse(CampusRules.here(long, now: t0), "a stay over 10 hours isn't taken")
        XCTAssertEqual(CampusWords.since(s), "At BUas since 08:05")
        XCTAssertEqual(CampusWords.since(CampusState(on: true)), "At school")
        XCTAssertEqual(CampusWords.list(["Tom", "Lisa"]), "On campus now: Tom and Lisa")
        XCTAssertEqual(CampusRules.ttl(until: t(3600), now: t0), 3600)
        XCTAssertEqual(CampusRules.ttl(until: t(10), now: t0), 60)
        XCTAssertEqual(CampusRules.ttl(until: t(20 * 3600), now: t0), 36000)
    }

    // MARK: School's region for "at school"

    func test_campusRegion() {
        let school = GeoPoint(lat: 51.5866, lon: 4.7745)
        let base = [RegionSpec(id: "school", lat: 51.5866, lon: 4.7745, radius: 350, entry: true, exit: false),
                    RegionSpec(id: "home.0", lat: 51.6, lon: 5.5, radius: 350, entry: false, exit: true)]
        let w = RoleRegions.withCampus(base, school: school, radius: 350)
        XCTAssertEqual(w.count, 2)
        XCTAssertEqual(w.first { $0.id == "school" }?.exit, true)
        XCTAssertEqual(w.first { $0.id == "school" }?.entry, true)
        XCTAssertEqual(w.last, base.last)
        XCTAssertFalse(RoleRegions.exitStartsTrip("school", base: base), "only 'at school' asked for School's exit")
        XCTAssertTrue(RoleRegions.exitStartsTrip("home.0", base: base))
        let none = RoleRegions.withCampus([], school: school, radius: 350)
        XCTAssertEqual(none, [RegionSpec(id: "school", lat: 51.5866, lon: 4.7745, radius: 350, entry: true, exit: true)])
    }

    // MARK: reading them

    func test_inboxReadsTheExtras() throws {
        let sam = FriendIdentity.random()
        let lou = FriendIdentity.random()
        let stranger = FriendIdentity.random()
        var book = FriendBook(myName: "Lou")
        book.friends.append(Friend(card: sam.card, name: "Sam", since: t0))
        func box(_ id: Int, _ m: FriendMessage, from: FriendIdentity, at: Date) throws -> RelayBox {
            let d = try FriendBox.seal(m, from: from, to: lou.card, at: at)
            return RelayBox(id: id, from: from.account, slot: nil, at: Int(at.timeIntervalSince1970), exp: 0, data: B64URL.encode(d))
        }
        let w = wait()
        let older = WaitFor(id: "w1", state: "coming", stop: ehv, dist: 500, at: t(-60))
        let answer = ChatText(text: "I’ll wait", re: "w9", answer: "wait")
        let r = FriendInbox.process([
            try box(1, .wait(w), from: sam, at: t0),
            try box(2, .wait(older), from: sam, at: t(-60)),
            try box(3, .campus(CampusState(on: true, school: "BUas", since: t0, until: t(3600))), from: sam, at: t0),
            try box(4, .buddy(BuddyPlan(on: true)), from: sam, at: t0),
            try box(5, .delay(RideDelay(ride: ride("ic", dep: 0, arr: 600), late: 4)), from: sam, at: t0),
            try box(6, .wait(w), from: stranger, at: t0),
            try box(7, .message(answer), from: sam, at: t0),
        ], book: book, me: lou, now: t0)
        XCTAssertEqual(r.waits[sam.account]?.wait.dist, 300, "the newest by their time")
        XCTAssertEqual(r.waits[sam.account]?.chat, sam.account)
        XCTAssertNil(r.waits[stranger.account], "only from a friend")
        XCTAssertEqual(r.campus[sam.account]?.state.school, "BUas")
        XCTAssertEqual(r.buddies[sam.account]?.plan.on, true)
        XCTAssertEqual(r.delays.first?.delay.late, 4)
        XCTAssertEqual(Set(r.ack), Set([1, 2, 3, 4, 5, 6, 7]))
        guard case .line(let m)? = r.chat.first?.what, let text = m.text else { return XCTFail("no answer line") }
        XCTAssertEqual(text.answer, "wait", "a wait's answer keeps what it answers")
        XCTAssertEqual(text.re, "w9")
        var chats = ChatBook()
        chats.add(m, to: sam.account)
        XCTAssertEqual(chats.waitAnswers(to: "w9", in: sam.account), [sam.account: .wait])
        XCTAssertTrue(chats.answers(to: "w9", in: sam.account).isEmpty, "not a trip card's answer")
    }
}
