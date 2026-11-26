import XCTest

/// 0.42.2: "Fastest trip, zoomed out" said "No bus or train from the stops within 1.6 km" at 23:10 with buses every half
/// hour and the classic Fastest trip showing a way. The window, the plans a search sends, the stop a way leaves from,
/// the ways shown apart overnight, the circles on the map and what the screen says. Synthetic times only.
final class NearbySearchTests: XCTestCase {
    private var utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    /// 2027-01-15 23:10 UTC
    private let now = Date(timeIntervalSince1970: 1_800_000_000 + 15 * 3600 + 10 * 60)
    private let you = GeoPoint(lat: 51.6167, lon: 5.5440)

    private func at(_ m: Double) -> Date { now.addingTimeInterval(m * 60) }

    /// A way: leave your door `door` minutes from now, walking `walk` to the bus, there `ride` minutes after it leaves.
    private func dep(door: Double, walk: Double = 6, ride: Double = 75, wait: Double = 0) -> Nearby.Dep {
        Nearby.Dep(door: at(door), departure: at(door + walk), arrival: at(door + walk + ride), cancelled: false, longestWait: wait * 60)
    }

    // MARK: late evening

    func test_lateEvening_halfHourBuses_in10_stopsGetWays() {
        // buses at 23:11, 23:41, 00:11 (door at -5, 25, 55 minutes from now, 6 min walk)
        let deps: [Nearby.Dep] = [dep(door: -5), dep(door: 25), dep(door: 55)]
        for l in Nearby.Leave.allCases {
            let w: Nearby.Window = Nearby.window(l, now: now)
            let shown: [Int] = Nearby.shown(deps, w)
            XCTAssertGreaterThanOrEqual(shown.count, 2, "\(l.title): the next two at least")
            XCTAssertFalse(shown.contains(0), "\(l.title): the one gone already isn't")
            XCTAssertNotNil(Nearby.best(deps, w), "\(l.title): the stop has a way")
        }
        let w10: Nearby.Window = Nearby.window(.in10, now: now)
        XCTAssertEqual(Nearby.shown(deps, w10), [1, 2])
        XCTAssertEqual(Nearby.best(deps, w10)?.index, 1)
        XCTAssertEqual(Nearby.best(deps, w10)?.ranked, true)
    }

    func test_nextOnes_shownEvenFortyMinutesLater_butNotRanked() {
        // In 10 min: nothing until the door at +55 and +85 (45 and 75 minutes after you set off)
        let deps: [Nearby.Dep] = [dep(door: 55), dep(door: 85)]
        let w: Nearby.Window = Nearby.window(.in10, now: now)
        XCTAssertEqual(Nearby.shown(deps, w), [0, 1])
        let b = Nearby.best(deps, w)
        XCTAssertEqual(b?.index, 0)
        XCTAssertEqual(b?.ranked, false, "outside the window: shown, but no Fastest or Surest")
    }

    func test_window_filteredLocally_withoutAskingAgain() {
        // one answer for every switch: each window takes its own from the same ways
        let deps: [Nearby.Dep] = [dep(door: 2), dep(door: 12), dep(door: 22), dep(door: 32), dep(door: 70)]
        XCTAssertEqual(Nearby.shown(deps, Nearby.window(.now, now: now)), [0, 1, 2, 3])
        XCTAssertEqual(Nearby.shown(deps, Nearby.window(.in10, now: now)), [1, 2, 3])
        XCTAssertEqual(Nearby.shown(deps, Nearby.window(.in20, now: now)), [2, 3])
        XCTAssertEqual(Nearby.best(deps, Nearby.window(.in20, now: now))?.index, 2)
    }

    func test_walk_countedOnce() {
        // an 8-minute walk to a bus that leaves 8 minutes after you set off: you make it (0.42.0 asked the planner from
        // when you'd be there, and the stop from your door, so a walk counted twice would lose it)
        let w: Nearby.Window = Nearby.window(.in10, now: now)
        let d = Nearby.Dep(door: at(10), departure: at(18), arrival: at(90))
        XCTAssertTrue(Nearby.catchable(door: d.door, w))
        XCTAssertEqual(Nearby.shown([d], w), [0])
        XCTAssertEqual(Nearby.planAt(w, walk: 8, now: now), at(17), "asked from when you can be at the stop, less a minute")
        XCTAssertEqual(Nearby.planAt(Nearby.window(.now, now: now), walk: 0, now: now), at(-1))
    }

    func test_cancelled_isNotShown() {
        var d: Nearby.Dep = dep(door: 5)
        d.cancelled = true
        XCTAssertTrue(Nearby.shown([d], Nearby.window(.now, now: now)).isEmpty)
    }

    // MARK: overnight

    func test_overnightWait_shownApart_neverRanked_withTheDay() {
        // 157 → IC → 5 at 23:18, waiting six hours at a change, there at 06:06; the 158 at 23:17, there at 00:49
        let soon = Nearby.Dep(door: at(5), departure: at(7), arrival: at(99))
        let night = Nearby.Dep(door: at(6), departure: at(8), arrival: at(416), longestWait: 6 * 3600)
        let w: Nearby.Window = Nearby.window(.now, now: now)
        XCTAssertFalse(Nearby.late(soon, w))
        XCTAssertTrue(Nearby.late(night, w))
        XCTAssertFalse(Nearby.ranked(night, w))
        let s = Nearby.split([soon, night], w)
        XCTAssertEqual(s.soon, [0])
        XCTAssertEqual(s.later, [1])
        XCTAssertEqual(Nearby.laterTitle(firstArrival: night.arrival, now: now, calendar: utc), "Tomorrow morning")
        // a 99 % sure way overnight is still not Surest (nor Fastest)
        let o: [Nearby.Option] = [
            Nearby.Option(id: "bolken", arrival: soon.arrival, departure: soon.departure, walk: 2,
                          sure: Nearby.Sure(percent: 80, source: .live, usual: nil)),
            Nearby.Option(id: "night", arrival: night.arrival, departure: night.departure, walk: 3,
                          sure: Nearby.Sure(percent: 99, source: .live, usual: nil), ranked: false)]
        let t: [String: [Nearby.Tag]] = Nearby.tags(o)
        XCTAssertEqual(t["bolken"], [.fastest, .surest])
        XCTAssertNil(t["night"])
        XCTAssertEqual(Nearby.ordered(o).map(\.id), ["bolken", "night"])
    }

    func test_dayWord_tonightTomorrowWeekday() {
        XCTAssertNil(Nearby.dayWord(at(20), now: now, calendar: utc), "23:30 today")
        XCTAssertNil(Nearby.dayWord(at(100), now: now, calendar: utc), "00:50 is still tonight")
        XCTAssertEqual(Nearby.dayWord(at(416), now: now, calendar: utc), "tomorrow")
        XCTAssertEqual(Nearby.dayWord(at(48 * 60), now: now, calendar: utc), "Sun", "2027-01-17")
        XCTAssertEqual(Nearby.laterTitle(firstArrival: at(48 * 60), now: now, calendar: utc), "Later · Sun")
    }

    // MARK: surest

    func test_surest_onlyAtSeventyPercentOrMore() {
        let o: [Nearby.Option] = [
            Nearby.Option(id: "a", arrival: at(60), departure: at(5), walk: 3, sure: Nearby.Sure(percent: 55, source: .estimate, usual: nil)),
            Nearby.Option(id: "b", arrival: at(64), departure: at(7), walk: 3, sure: Nearby.Sure(percent: 60, source: .estimate, usual: nil))]
        let t: [String: [Nearby.Tag]] = Nearby.tags(o)
        XCTAssertEqual(t["a"], [.fastest], "on time about 60% isn't Surest")
        XCTAssertNil(t["b"])
        XCTAssertNil(Nearby.surestOf([55, 60], fastest: 0))
        XCTAssertEqual(Nearby.surestOf([55, 80, 80], fastest: 0), 1, "a tie: the earlier one")
        XCTAssertNil(Nearby.surestOf([90, 80], fastest: 0), "the fastest is surest itself")
    }

    // MARK: the plans a search sends

    func test_requestBudget_onePlan_aSecondOnlyWhenNeeded() {
        XCTAssertEqual(Nearby.nextPlan(done: 0, useful: 0, hasCursor: false, lastFailed: false, cooling: true), 1600,
                       "the first always goes")
        XCTAssertEqual(Nearby.nextPlan(done: 1, useful: 2, hasCursor: true, lastFailed: false, cooling: false), 3000,
                       "fewer than 3 stops: a later page, walking further")
        XCTAssertNil(Nearby.nextPlan(done: 1, useful: 3, hasCursor: true, lastFailed: false, cooling: false), "three stops: enough")
        XCTAssertNil(Nearby.nextPlan(done: 1, useful: 0, hasCursor: false, lastFailed: false, cooling: false), "no later page")
        XCTAssertNil(Nearby.nextPlan(done: 1, useful: 0, hasCursor: true, lastFailed: false, cooling: true), "asked to slow down")
        XCTAssertNil(Nearby.nextPlan(done: 2, useful: 0, hasCursor: true, lastFailed: true, cooling: false), "two at most")
        XCTAssertEqual(Nearby.maxSearchPlans, 2)
        XCTAssertLessThanOrEqual(Nearby.maxConcurrent, 2)
        XCTAssertEqual(Nearby.preTransit(radius: 1600), 29 * 60, "1.6 km straight: 2080 m on foot, 29 min")
        XCTAssertEqual(Nearby.preTransit(radius: 3000), Nearby.maxPreTransit)
    }

    func test_failedPlan_askedOnceMoreWider_andNeverNoBusOrTrain() {
        XCTAssertEqual(Nearby.nextPlan(done: 1, useful: 0, hasCursor: false, lastFailed: true, cooling: false), 3000,
                       "no answer is no reason to stop: once more, wider")
        var s = Nearby.Situation()
        s.planFailed = true
        let failed: String = Nearby.statusLine(s, range: "3 km")?.text ?? ""
        XCTAssertTrue(failed.hasPrefix("Couldn’t check"), failed)
        XCTAssertFalse(failed.contains("No bus or train"))
        s.cooling = true
        XCTAssertTrue((Nearby.statusLine(s, range: "3 km")?.text ?? "").contains("the planner is busy"))
        var some = Nearby.Situation()
        some.options = 2
        some.unchecked = 3
        XCTAssertEqual(Nearby.statusLine(some, range: "1.6 km")?.text,
                       "Couldn’t check 3 stops just now (no answer in time). Tap one to try again.")
        some.unchecked = 0
        XCTAssertNil(Nearby.statusLine(some, range: "1.6 km"))
    }

    func test_noBusOrTrain_onlyWhenThePlannerAnsweredAndYourTripHasNone() {
        var s = Nearby.Situation()
        XCTAssertEqual(Nearby.statusLine(s, range: "1.6 km")?.text,
                       "No bus or train from the stops within 1.6 km in this time. Try later, or see your trip.")
        s.seed = true
        XCTAssertFalse((Nearby.statusLine(s, range: "1.6 km")?.text ?? "").contains("No bus or train"))
        s.fallback = true
        XCTAssertFalse((Nearby.statusLine(s, range: "1.6 km")?.text ?? "").contains("No bus or train"))
        var busy = Nearby.Situation()
        busy.busy = true
        XCTAssertEqual(Nearby.statusLine(busy, range: "1.6 km")?.asking, true)
    }

    // MARK: which stop a way leaves from

    private func group(_ id: String, _ name: String, ids: [String], north: Double, rail: Bool = false) -> Nearby.Group {
        Nearby.Group(id: id, name: name, ids: ids, lat: you.lat + north / 111_320, lon: you.lon, rail: rail, metres: abs(north))
    }

    private func boarding(_ id: String, _ name: String, north: Double?, rail: Bool = false) -> Nearby.Boarding {
        Nearby.Boarding(id: id, name: name, lat: north.map { you.lat + $0 / 111_320 }, lon: north.map { _ in you.lon }, rail: rail)
    }

    func test_ways_groupedByTheirFirstBoardingStop() {
        let gs: [Nearby.Group] = [group("bolkenplein", "Bolkenplein", ids: ["b1", "b2"], north: 300),
                                  group("markt", "Markt", ids: ["m1"], north: -500),
                                  group("rail:s", "Station", ids: ["s"], north: 2000, rail: true)]
        XCTAssertEqual(Nearby.groupIndex(boarding("b2", "Bolkenplein", north: 310), in: gs), 0, "by its id")
        XCTAssertEqual(Nearby.groupIndex(boarding("b9", "Bolkenplein", north: 420), in: gs), 0, "by its name, the other side")
        XCTAssertEqual(Nearby.groupIndex(boarding("x", "Markt, perron A", north: -560), in: gs), 1, "within 120 m")
        XCTAssertEqual(Nearby.groupIndex(boarding("p3", "Station perron 3", north: 2250, rail: true), in: gs), 2, "a station: 400 m")
        XCTAssertNil(Nearby.groupIndex(boarding("c", "Busstation", north: 900), in: gs))
        XCTAssertNil(Nearby.groupIndex(boarding("b7", "Bolkenplein", north: 1400), in: gs), "the same name far off is another stop")
    }

    func test_seedsStop_notAmongTheStopsAround_getsItsOwn() {
        // Fastest trip's own way gets on at a stop beyond the eight drawn: it's drawn too, with its walk
        let gs: [Nearby.Group] = [group("bolkenplein", "Bolkenplein", ids: ["b1"], north: 300)]
        let b: Nearby.Boarding = boarding("c1", "Busstation", north: 900)
        XCTAssertNil(Nearby.groupIndex(b, in: gs))
        let g: Nearby.Group? = Nearby.newGroup(b, here: you, taken: Set(gs.map(\.id)))
        XCTAssertEqual(g?.id, "busstation")
        XCTAssertEqual(g?.ids, ["c1"])
        XCTAssertEqual(g?.metres ?? 0, 900, accuracy: 15)
        let far: Nearby.Group? = Nearby.newGroup(boarding("b7", "Bolkenplein", north: 1400), here: you, taken: ["bolkenplein"])
        XCTAssertEqual(far?.id, "bolkenplein@b7", "told apart from the one of that name nearby")
        XCTAssertNil(Nearby.newGroup(boarding("z", "Nowhere", north: nil), here: you, taken: []))
    }

    // MARK: the map

    func test_circlesThatWouldOverlap_areOne_theEarliestThere() {
        let pins: [Nearby.Pin] = [Nearby.Pin(id: "late", lat: you.lat, lon: you.lon, arrival: at(66)),
                                  Nearby.Pin(id: "early", lat: you.lat + 20 / 111_320, lon: you.lon, arrival: at(49)),
                                  Nearby.Pin(id: "apart", lat: you.lat + 400 / 111_320, lon: you.lon, arrival: at(70))]
        let c: [Nearby.Cluster] = Nearby.merge(pins, within: 60)
        XCTAssertEqual(c.map(\.id), ["early", "apart"])
        XCTAssertEqual(c[0].members, ["early", "late"])
        for a in c { for b in c where a.id != b.id {
            XCTAssertGreaterThanOrEqual(Geo.metres(GeoPoint(lat: a.lat, lon: a.lon), GeoPoint(lat: b.lat, lon: b.lon)), 60)
        } }
        XCTAssertEqual(Nearby.merge(pins, within: 5).count, 3, "zoomed in: each its own")
    }

    // MARK: the field log

    func test_logLine() {
        XCTAssertEqual(Nearby.logLine(radius: 1600, stops: 9, plans: 1, pages: 1, ways: 6, failed: 0, seconds: 0.84, bytes: 320 * 1024),
                       "nearby · r 1.6 km · stops 9 · plans 1 (+1 page) · ways 6 · 0 failed · 0.8 s · 320 KB")
        XCTAssertEqual(Nearby.logLine(radius: 3000, stops: 4, plans: 2, pages: 0, ways: 1, failed: 1, seconds: 10, bytes: 0, note: "cooling"),
                       "nearby · r 3.0 km · stops 4 · plans 2 · ways 1 · 1 failed · 10.0 s · 0 KB · cooling")
        XCTAssertEqual(Nearby.stopLogLine(planned: true, failed: false, ways: 3, board: 12, seconds: 0.9, bytes: 150 * 1024),
                       "nearby stop · plan · ways 3 · times 12 · 0.9 s · 150 KB")
        XCTAssertEqual(Nearby.stopLogLine(planned: false, failed: false, ways: 2, board: nil, seconds: 0.2, bytes: 4096),
                       "nearby stop · ways 2 · 0.2 s · 4 KB")
    }
}
