import XCTest

/// Friends 0.28: timetables side by side, free time together, the rides you can share, and meeting halfway. The
/// worked example is the one in the spec's "As built (0.28)": Monday 18 January 2027, you from Veghel (bus to
/// Eindhoven, then the IC), Lisa from Eindhoven and Sam from Tilburg on the same IC to Breda; Tom starts at 10:45.
final class FriendCompareTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)         // Friday 15 January 2027, 09:00 in Amsterdam
    let midnight = 1_799_967_600.0

    private func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Date { Date(timeIntervalSince1970: midnight + Double(d * 86400 + h * 3600 + m * 60)) }

    private func spot(_ name: String, _ lat: Double, _ lon: Double, id: String? = nil) -> TripCard.Spot {
        TripCard.Spot(name: name, id: id, lat: lat, lon: lon)
    }

    private lazy var veghel = spot("Veghel, Busstation", 51.6137, 5.5474)
    private lazy var eindhoven = spot("Eindhoven Centraal", 51.4432, 5.4812, id: "ehv")
    private lazy var tilburg = spot("Tilburg", 51.5605, 5.0838, id: "tb")
    private lazy var breda = spot("Breda", 51.5955, 4.7797, id: "bd")
    private lazy var helmond = spot("Helmond", 51.4755, 5.6618, id: "hm")

    private func leg(_ trip: String, _ line: String, bus: Bool = false, num: String? = nil, _ from: TripCard.Spot, _ dep: Date,
                     _ to: TripCard.Spot, _ arr: Date) -> WayLeg {
        WayLeg(trip: trip, mode: bus ? "bus" : "train", line: line, num: num, from: from, to: to, dep: dep, arr: arr)
    }

    private func way(_ legs: [WayLeg], walkAfter: Int = 13) -> Way {
        Way(legs: legs, start: legs[0].dep.addingTimeInterval(-5 * 60), end: legs[legs.count - 1].arr.addingTimeInterval(Double(walkAfter) * 60))
    }

    private func timetable(_ classes: [TimetableClass]) -> TimetableShare {
        let w = TimetableDays.window(now: t0)
        return TimetableShare(from: w.from, to: w.to, classes: classes)
    }

    private func c(_ d: Int, _ h: Int, _ m: Int, _ eh: Int, _ em: Int) -> TimetableClass {
        TimetableClass(start: at(d, h, m), end: at(d, eh, em))
    }

    // MARK: the week

    func test_daysThisWeekAndNext() {
        let me = ComparePerson(id: "me", name: "You", isMe: true, timetable: timetable([c(3, 9, 0, 12, 0), c(8, 10, 0, 12, 0)]))
        let sam = ComparePerson(id: "sam", name: "Sam", timetable: timetable([c(3, 9, 0, 15, 0)]))
        let tom = ComparePerson(id: "tom", name: "Tom")
        let days = Compare.days([me, sam, tom], now: t0)
        // Friday (today), then Monday to Friday next week; Saturday 23 has a class, so it shows; the other weekends don't
        XCTAssertEqual(days.map(\.key), ["2027-01-15", "2027-01-18", "2027-01-19", "2027-01-20", "2027-01-21", "2027-01-22", "2027-01-23"])
        let monday = days[1]
        XCTAssertTrue(monday.shared)
        XCTAssertEqual(monday.person("me")?.first, at(3, 9))
        XCTAssertEqual(monday.person("sam")?.lastEnd, at(3, 15))
        XCTAssertEqual(monday.person("tom")?.known, false)
        XCTAssertEqual(CompareWords.day(monday.person("sam")!), "09:00–15:00 · 1 class")
        XCTAssertEqual(CompareWords.day(monday.person("tom")!), "Not shared")
        XCTAssertEqual(CompareWords.day(days[2].person("sam")!), "No classes")
        XCTAssertEqual(Compare.nextShared(days, now: t0), "2027-01-18")
        XCTAssertEqual(TimetableDays.short("2027-01-18"), "Mon 18")
    }

    func test_freeTogether() {
        let me = PersonDay(id: "me", known: true, classes: [c(3, 9, 0, 10, 30), c(3, 13, 0, 15, 0)])          // free 10:30–13:00
        let sam = PersonDay(id: "sam", known: true, classes: [c(3, 9, 0, 11, 0), c(3, 12, 0, 15, 0)])         // free 11:00–12:00
        let lisa = PersonDay(id: "lisa", known: true, classes: [c(3, 8, 30, 10, 0), c(3, 12, 45, 16, 0)])     // free 10:00–12:45
        let day = CompareDay(key: "2027-01-18", people: [me, sam, lisa])
        let free = Compare.freeTogether(day)
        XCTAssertEqual(free.count, 2)
        XCTAssertEqual(free[0], FreeSlot(start: at(3, 11), end: at(3, 12), ids: ["lisa", "me", "sam"]))
        XCTAssertEqual(free[1], FreeSlot(start: at(3, 12), end: at(3, 12, 45), ids: ["lisa", "me"]))
        XCTAssertEqual(CompareWords.free(free[0], name: { $0 == "me" ? "you" : $0.capitalized }), "Free together 11:00–12:00 · Lisa, you and Sam")
        // overlapping classes are one block; a class without an end runs into the next
        let odd = PersonDay(id: "x", known: true, classes: [c(3, 9, 0, 11, 0), c(3, 10, 0, 10, 30), TimetableClass(start: at(3, 12)), c(3, 14, 0, 15, 0)])
        let gaps = Compare.free(odd)
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps[0].start, at(3, 11))
        XCTAssertEqual(gaps[0].end, at(3, 12))
    }

    // MARK: rides together (the worked example)

    /// To school, Monday: first class 09:00 for you, Sam and Lisa (there by 08:50), 10:45 for Tom.
    private var school: [PersonWays] {
        let me = PersonWays(id: "me", ways: [
            way([leg("b305-0", "305", bus: true, veghel, at(3, 6, 35), eindhoven, at(3, 7, 5)),
                 leg("ic-3510", "IC", num: "3510", eindhoven, at(3, 7, 11), breda, at(3, 8, 2))]),
            way([leg("b305-1", "305", bus: true, veghel, at(3, 7, 5), eindhoven, at(3, 7, 35)),
                 leg("ic-3512", "IC", num: "3512", eindhoven, at(3, 7, 41), breda, at(3, 8, 32))]),
        ], bound: at(3, 8, 50))
        let lisa = PersonWays(id: "lisa", ways: [way([leg("ic-3512", "IC", num: "3512", eindhoven, at(3, 7, 41), breda, at(3, 8, 32))])],
                              bound: at(3, 8, 50))
        let sam = PersonWays(id: "sam", ways: [way([leg("ic-3512", "IC", num: "3512", tilburg, at(3, 8, 3), breda, at(3, 8, 32))])],
                             bound: at(3, 8, 50))
        let tom = PersonWays(id: "tom", ways: [way([leg("ic-3520", "IC", num: "3520", eindhoven, at(3, 9, 41), breda, at(3, 10, 32))])],
                             bound: at(3, 10, 35))
        return [me, lisa, sam, tom]
    }

    func test_sharedRideToSchool() {
        let rides = SharedRides.match(school, .toSchool)
        XCTAssertEqual(rides.first?.trip, "ic-3512")
        XCTAssertEqual(rides.first?.ids, ["lisa", "me", "sam"])
        XCTAssertEqual(rides.count, 1, "nobody shares the bus or Tom's train")
        let r = rides[0]
        XCTAssertEqual(r.rider("sam")?.board.name, "Tilburg")
        XCTAssertEqual(r.rider("me")?.way, 1, "your way that leaves latest and has it")
        XCTAssertEqual(SharedRides.together(r), 29 * 60, "08:03 to 08:32")
        let name: (String) -> String = { $0 == "me" ? "you" : $0.capitalized }
        XCTAssertEqual(RideWords.headline(r), "IC 3512 · 07:41 from Eindhoven Centraal")
        XCTAssertEqual(RideWords.riders(r, name: name), "Lisa, you and Sam (gets on at Tilburg 08:03)")
        let tom = PersonDay(id: "tom", known: true, classes: [c(3, 10, 45, 13, 0)])
        XCTAssertEqual(RideWords.missing(tom, .toSchool, name: "Tom", hasArea: true), "Tom starts 10:45")
        XCTAssertEqual(RideWords.missing(tom, .home, name: "Tom", hasArea: true), "Tom ends 13:00")
        XCTAssertEqual(RideWords.missing(PersonDay(id: "x", known: true, classes: []), .toSchool, name: "Kim", hasArea: true), "Kim: no classes")
        XCTAssertEqual(RideWords.missing(PersonDay(id: "x", known: false, classes: []), .toSchool, name: "Kim", hasArea: true), "Kim hasn’t shared this day")
        XCTAssertEqual(RideWords.missing(tom, .toSchool, name: "Tom", hasArea: false), "Tom: no start area yet")
    }

    func test_tooEarlyIsntUsable() {
        // a way an hour before your latest one isn't one you'd take (45 minutes at most)
        let p = PersonWays(id: "me", ways: [
            way([leg("a", "IC", eindhoven, at(3, 6, 41), breda, at(3, 7, 32))]),
            way([leg("b", "IC", eindhoven, at(3, 7, 41), breda, at(3, 8, 32))]),
            way([leg("c", "IC", eindhoven, at(3, 8, 41), breda, at(3, 9, 32))]),       // too late
        ], bound: at(3, 8, 50))
        XCTAssertEqual(SharedRides.usable(p, .toSchool), [1])
    }

    func test_sharedRideHome() {
        // after 15:45: you and Sam on the 16:13; Lisa's last class ends 17:00
        let me = PersonWays(id: "me", ways: [way([leg("ic-3555", "IC", breda, at(3, 16, 13), eindhoven, at(3, 17, 4))]),
                                             way([leg("ic-3559", "IC", breda, at(3, 16, 43), eindhoven, at(3, 17, 34))])], bound: at(3, 15, 45))
        let sam = PersonWays(id: "sam", ways: [way([leg("ic-3555", "IC", breda, at(3, 16, 13), tilburg, at(3, 16, 35))])], bound: at(3, 15, 45))
        let lisa = PersonWays(id: "lisa", ways: [way([leg("ic-3563", "IC", breda, at(3, 17, 13), eindhoven, at(3, 18, 4))])], bound: at(3, 17, 0))
        let rides = SharedRides.match([me, sam, lisa], .home)
        XCTAssertEqual(rides.map(\.trip), ["ic-3555"])
        XCTAssertEqual(rides[0].ids, ["me", "sam"])
    }

    func test_shownKeepsOnlyNewCompany() {
        let r: (String, [String]) -> SharedRide = { trip, ids in
            SharedRide(trip: trip, mode: "train", line: "IC", num: nil, riders: ids.map {
                Rider(id: $0, way: 0, leg: 0, board: self.breda, dep: self.at(3, 8), alight: self.breda, arr: self.at(3, 9))
            })
        }
        let shown = SharedRides.shown([r("a", ["me", "sam", "lisa"]), r("b", ["me", "sam"]), r("c", ["tom", "kim"]), r("d", ["me", "tom"])])
        XCTAssertEqual(shown.map(\.trip), ["a", "c", "d"])
    }

    // MARK: meet halfway

    func test_meetHalfwaySameTrainEachFromTheirStop() {
        let plans = MeetHalfway.plans(Array(school.prefix(3)))
        XCTAssertEqual(plans.first?.ride.trip, "ic-3512")
        XCTAssertEqual(plans.first?.missing, [])
        XCTAssertEqual(plans.first?.kind, .sameRide, "Sam gets on at Tilburg")
        XCTAssertEqual(MeetWords.title(plans[0]), "Same train: IC 3512 at 07:41")
    }

    func test_meetAtAStationFirst() {
        // you by bus from Veghel and Lisa by Sprinter from Helmond, both onto the IC at Eindhoven
        let me = school[0]
        let lisa = PersonWays(id: "lisa", ways: [way([leg("spr-hm", "SPR", helmond, at(3, 7, 20), eindhoven, at(3, 7, 33)),
                                                      leg("ic-3512", "IC", num: "3512", eindhoven, at(3, 7, 41), breda, at(3, 8, 32))])],
                              bound: at(3, 8, 50))
        let plans = MeetHalfway.plans([me, lisa])
        XCTAssertEqual(plans.first?.ride.trip, "ic-3512")
        XCTAssertEqual(plans.first?.kind, .meetAt(eindhoven, at(3, 7, 35)), "when the last of you gets there (your bus, 07:35)")
        XCTAssertEqual(MeetWords.title(plans[0]), "Meet at Eindhoven Centraal 07:35, then IC 3512 together")
    }

    /// Kim starts by Tilburg station and goes near Breda station, but her own way is a later train: she gets onto
    /// yours at Tilburg (a walk there) and walks from Breda.
    func test_meetHalfwayOntoYourTrain() throws {
        let route: [RouteStop] = [
            RouteStop(name: "Eindhoven Centraal", id: "ehv", point: eindhoven.point!, dep: at(3, 7, 41), arr: at(3, 7, 39)),
            RouteStop(name: "Tilburg", id: "tb", point: tilburg.point!, dep: at(3, 8, 3), arr: at(3, 8, 1)),
            RouteStop(name: "Breda", id: "bd", point: breda.point!, dep: nil, arr: at(3, 8, 32)),
        ]
        let mine = school[0]
        let kimStart = tilburg.point!
        let kimDest = GeoPoint(lat: 51.5930, lon: 4.7790)
        let kimOwn = [way([leg("ic-3516", "IC", tilburg, at(3, 8, 33), breda, at(3, 8, 51))])]
        var plans = MeetHalfway.plans([mine, PersonWays(id: "kim", ways: kimOwn, bound: at(3, 8, 50))])
        XCTAssertTrue(plans.isEmpty, "no way of hers shares a vehicle with yours")
        // step 1 had nothing: your main ride, to get the others onto
        let ride = SharedRide(trip: "ic-3512", mode: "train", line: "IC", num: "3512", riders: [
            Rider(id: "me", way: 1, leg: 1, board: eindhoven, dep: at(3, 7, 41), alight: breda, arr: at(3, 8, 32)),
        ])
        plans = [MeetPlan(kind: .sameRide, ride: ride, ways: ["me": mine.ways[1]], missing: ["kim"])]
        let joins = MeetHalfway.joins(route: route, ride: ride, start: kimStart, dest: kimDest, deadline: at(3, 8, 50), own: kimOwn, now: at(3, 6))
        XCTAssertEqual(joins.first, MeetJoin(board: 1, alight: 2, walkAfter: 6, rest: []), "on at Tilburg, a 6 minute walk from Breda")
        let template = mine.ways[1].legs[1]
        let w = try XCTUnwrap(MeetHalfway.joined(joins[0], ride: ride, template: template, route: route, start: kimStart, before: nil, deadline: at(3, 8, 50)))
        XCTAssertEqual(w.legs.count, 1)
        XCTAssertEqual(w.legs[0].from.name, "Tilburg")
        XCTAssertEqual(w.legs[0].dep, at(3, 8, 3))
        XCTAssertEqual(w.end, at(3, 8, 38))
        let plan = MeetHalfway.adding(plans[0], id: "kim", way: w, trip: "ic-3512")
        XCTAssertEqual(plan.missing, [])
        XCTAssertEqual(plan.ride.ids, ["me", "kim"])
        XCTAssertEqual(plan.kind, .sameRide)
        // too late for her deadline: nothing
        XCTAssertNil(MeetHalfway.joined(joins[0], ride: ride, template: template, route: route, start: kimStart, before: nil, deadline: at(3, 8, 30)))
        // the card for her chat: her way, there by her deadline
        let card = MeetHalfway.card(w, to: spot("BUas", 51.5866, 4.7745), by: at(3, 8, 50),
                                    note: MeetWords.note(plan, name: { $0 == "me" ? "you" : "Kim" }, me: "me"))
        XCTAssertNotNil(TripCard.valid(card))
        XCTAssertEqual(card.rides.first?.trip, "ic-3512")
        XCTAssertEqual(card.note, "Meet halfway: IC 3512 together · Kim gets on at Tilburg 08:03")
        XCTAssertEqual(TripTake.shared(card)?.trip, "ic-3512", "“Take this trip” finds the shared ride")
    }

    /// Off the shared train where her own way goes on (a change in time), not only by a walk.
    func test_joinOntoTheRestOfYourOwnWay() {
        let route: [RouteStop] = [
            RouteStop(name: "Eindhoven Centraal", id: "ehv", point: eindhoven.point!, dep: at(3, 7, 41), arr: nil),
            RouteStop(name: "Tilburg", id: "tb", point: tilburg.point!, dep: at(3, 8, 3), arr: at(3, 8, 1)),
            RouteStop(name: "Breda", id: "bd", point: breda.point!, dep: nil, arr: at(3, 8, 32)),
        ]
        let ride = SharedRide(trip: "ic-3512", mode: "train", line: "IC", num: "3512", riders: [
            Rider(id: "me", way: 0, leg: 0, board: eindhoven, dep: at(3, 7, 41), alight: breda, arr: at(3, 8, 32)),
        ])
        // her own way: bus to Tilburg, then a bus from Tilburg at 08:10 to Oisterwijk (far from the route's end)
        let far = GeoPoint(lat: 51.58, lon: 5.19)
        let own = [way([leg("bus-1", "141", bus: true, helmond, at(3, 7, 0), tilburg, at(3, 7, 55)),
                        leg("bus-2", "142", bus: true, tilburg, at(3, 8, 10), spot("Oisterwijk", 51.58, 5.19), at(3, 8, 30))])]
        let joins = MeetHalfway.joins(route: route, ride: ride, start: eindhoven.point!, dest: far, deadline: at(3, 8, 50), own: own, now: at(3, 6))
        XCTAssertEqual(joins.first?.board, 0)
        XCTAssertEqual(joins.first?.alight, 1)
        XCTAssertEqual(joins.first?.rest.map(\.trip), ["bus-2"])
    }

    func test_requestBudget() {
        var b = RequestBudget(limit: RequestBudget.meet)
        XCTAssertEqual(b.left, 12)
        XCTAssertTrue(b.take(10))
        XCTAssertFalse(b.take(3))
        XCTAssertTrue(b.take(2))
        XCTAssertFalse(b.take())
        XCTAssertEqual(b.used, 12)
        XCTAssertEqual(RequestBudget.compare, 24)
    }
}
