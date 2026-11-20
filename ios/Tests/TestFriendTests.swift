import XCTest

/// Test friend (0.30.1): the bot's brain as plain rules: what it says back, its timetable and scores near yours, its
/// pretend trip and wait, and that your vault never holds it (docs/superpowers/specs/2026-11-18-friends-design.md,
/// "As built (0.30.1)").
final class TestFriendTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)          // Friday 15 January 2027, 09:00 in Amsterdam
    let midnight = Date(timeIntervalSince1970: 1_799_967_600)    // that day's 00:00
    private func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private func seed(_ first: UInt8) -> Data { Data((0..<16).map { first + UInt8($0) }) }

    // MARK: what it says back

    func test_replies() {
        XCTAssertEqual(TestFriendBrain.reply(to: "Running 5 min late"), "No problem, I’ll wait. See you in a bit!")
        XCTAssertEqual(TestFriendBrain.reply(to: "Save me a seat"), "Saved you one by the window.")
        XCTAssertEqual(TestFriendBrain.reply(to: "Wait for me"), "Sure, I’ll wait for you!")
        XCTAssertEqual(TestFriendBrain.reply(to: "I’m at the stop"), "Great, I’m almost there!")
        XCTAssertEqual(TestFriendBrain.reply(to: "i'm at the stop "), "Great, I’m almost there!")
        XCTAssertEqual(TestFriendBrain.reply(to: "On the 305"), "Nice, I’ll look out for you on the 305.")
        XCTAssertEqual(TestFriendBrain.reply(to: "Hello"), "Hi! Test friend here. Your message came through, locked end to end.")
        XCTAssertEqual(TestFriendBrain.reply(to: "Where are you?"),
                       "Good question! I’m only a test friend, so I can’t really answer, but your message came through fine.")
        XCTAssertEqual(TestFriendBrain.reply(to: "See you at the station"), "You said: “See you at the station”. Got it, locked end to end.")
        XCTAssertNil(TestFriendBrain.reply(to: "  \n "))
        let long = String(repeating: "a", count: 120)
        XCTAssertEqual(TestFriendBrain.reply(to: long), "You said: “\(String(repeating: "a", count: 80))…”. Got it, locked end to end.")
        XCTAssertEqual(TestFriendBrain.reply(toAnswer: "wait"), "Thanks for waiting! Nearly there.")
        XCTAssertEqual(TestFriendBrain.reply(toAnswer: "next"), "OK, let’s take the next one together.")
        XCTAssertNil(TestFriendBrain.reply(toAnswer: "something-new"))
        XCTAssertEqual(TestFriendBrain.reply(toWait: "w1"), ChatText(text: "I’ll wait", re: "w1", answer: "wait"))
        XCTAssertEqual(TestFriendBrain.groupHello("Uni crew"), "Hi everyone! I’m the test friend. Thanks for adding me to “Uni crew”. I answer here too.")
    }

    func test_tripCard() {
        let ride = TripCard.Ride(mode: "train", line: "IC", num: "3512", trip: "vector-trip-3512",
                                 from: TripCard.Spot(name: "Eindhoven Centraal"), to: TripCard.Spot(name: "Breda"), dep: t0, arr: t(3000))
        let card = TripCard(rides: [ride], to: TripCard.Spot(name: "BUas"))
        let out: [ChatText] = TestFriendBrain.replies(toTrip: card, n: "n1")
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0], ChatText(text: "I’m in", re: "n1", answer: "in"))
        XCTAssertEqual(out[1].text, "See you on the IC 3512 at 09:00!")
        XCTAssertNil(out[1].answer)
    }

    // MARK: its timetable and scores

    func test_timetable() throws {
        let tt = TestFriendBrain.timetable(mine: nil, now: t0)
        XCTAssertEqual(tt.from, midnight)
        XCTAssertEqual(tt.to, midnight.addingTimeInterval(14 * 86400))
        XCTAssertNotNil(TimetableShare.valid(tt))
        // 10 weekdays in the two weeks from Friday, two of them Wednesdays (no afternoon)
        XCTAssertEqual(tt.classes.count, 28)
        XCTAssertEqual(tt.classes.first?.start, midnight.addingTimeInterval(10.5 * 3600))     // Friday 10:30
        XCTAssertEqual(tt.classes.first?.end, midnight.addingTimeInterval(12 * 3600))
        let monday = midnight.addingTimeInterval(3 * 86400)
        let mon: [TimetableClass] = tt.classes.filter { TimetableDays.key($0.start) == TimetableDays.key(monday) }
        XCTAssertEqual(mon.map(\.start), [monday.addingTimeInterval(8.75 * 3600), monday.addingTimeInterval(10.75 * 3600),
                                          monday.addingTimeInterval(13.25 * 3600)])
        let wed = midnight.addingTimeInterval(5 * 86400)
        XCTAssertEqual(tt.classes.filter { TimetableDays.key($0.start) == TimetableDays.key(wed) }.count, 2)
        XCTAssertTrue(tt.classes.allSatisfy { TimetableDays.calendar.component(.weekday, from: $0.start) != 1 })
        // near yours: your Monday starts at 09:30, so does its
        let mine = TimetableShare(from: midnight, to: midnight.addingTimeInterval(14 * 86400),
                                  classes: [TimetableClass(start: monday.addingTimeInterval(9.5 * 3600), end: monday.addingTimeInterval(11 * 3600))])
        let near = TestFriendBrain.timetable(mine: mine, now: t0)
        let first: Date? = near.classes.filter { TimetableDays.key($0.start) == TimetableDays.key(monday) }.first?.start
        XCTAssertEqual(first, monday.addingTimeInterval(9.5 * 3600))
    }

    func test_scores() {
        let none = TestFriendBrain.scores(mine: [], rides: 2, now: t0)
        XCTAssertTrue(none.on)
        XCTAssertEqual(none.month, "2027-01")
        XCTAssertEqual(none.best?.map(\.route), ["home→school", "school→home"])
        XCTAssertEqual(none.best?.map(\.mins), [46.5, 51.2])
        XCTAssertEqual(none.mbest, none.best)
        XCTAssertEqual(none.rides, 2)
        let mine = [ScoreTrip(route: "home→school", home: false, mins: 40, at: t(-86400)),
                    ScoreTrip(route: "school→home", home: true, mins: 50, at: t(-86400))]
        let near = TestFriendBrain.scores(mine: mine, rides: 0, now: t0)
        XCTAssertEqual(near.best?.map(\.mins), [42, 48])
        XCTAssertEqual(near.today, [DayTrip(home: false, mins: 52.4, at: t(-3600), plan: 45, line: "305", late: 7)])
    }

    func test_buddy() {
        let from = TripCard.Spot(name: "Eindhoven Centraal", lat: 51.44306, lon: 5.47917)
        let to = TripCard.Spot(name: "Eindhoven Strijp-S", lat: 51.4497, lon: 5.4580)
        let ride = TestFriendBrain.ride(from: from, to: to, train: true, now: t0, inMinutes: 4, id: "test-1")
        XCTAssertEqual(ride.dep, t(240))
        XCTAssertEqual(ride.line, "SPR")
        let plan = TestFriendBrain.buddy(now: t0, ride: ride)
        XCTAssertEqual(plan, BuddyPlan(on: true, day: "2027-01-15", leave: t(-360), ride: ride, left: nil))
        // your phone tells you now: 5 minutes after it should have left, not moving
        XCTAssertTrue(BuddyRules.alert(leave: plan.leave!, ride: plan.ride, moving: false, told: nil, today: "2027-01-15", now: t0))
    }

    // MARK: its pretend trip and wait

    func test_tripSim() throws {
        let stops: [TestTripSim.RealStop] = [
            .init(name: "A", lat: 51.0, lon: 5.0, time: t(120)),
            .init(name: "B", lat: 51.01, lon: 5.02, time: t(420)),
            .init(name: "C", lat: 51.02, lon: 5.04, time: t(720)),
            .init(name: "D", lat: 51.03, lon: 5.06, time: t(120 + 30 * 60)),          // past 25 minutes: not taken
        ]
        let trip = try XCTUnwrap(TestTripSim.make(mode: "train", line: "SPR", num: nil, trip: "x", stops: stops, dest: "Zwolle", start: t0))
        XCTAssertEqual(trip.stops.map(\.name), ["A", "B", "C"])
        XCTAssertEqual(trip.stops.map(\.at), [0, 300, 600])
        XCTAssertEqual(trip.dest, "Zwolle")
        // a minute waiting at the first stop
        let w = try XCTUnwrap(TestTripSim.state(trip, now: t(30)))
        XCTAssertEqual(w.state, "waiting")
        XCTAssertEqual(w.from.name, "A")
        XCTAssertEqual(w.to.name, "C")
        XCTAssertEqual(w.pos?.lat, 51.0)
        XCTAssertNil(w.coach)
        XCTAssertEqual(w.eta, t(660))
        // then on board, half way from A to B, with a coach
        let r = try XCTUnwrap(TestTripSim.state(trip, now: t(60 + 150)))
        XCTAssertEqual(r.state, "riding")
        XCTAssertEqual(r.pos?.lat ?? 0, 51.005, accuracy: 0.00001)
        XCTAssertEqual(r.pos?.lon ?? 0, 5.01, accuracy: 0.00001)
        // (0.31) and a window: a Sprinter has one deck
        XCTAssertEqual(r.coach, TravelState.Coach(n: 3, of: 6, front: true, at: nil, seat: .init(deck: "none", w: 6, of: 11)))
        XCTAssertEqual(TestTripSim.coach(line: "IC").seat, .init(deck: "upper", w: 8, of: 11))
        XCTAssertEqual(r.trip, "x")
        XCTAssertEqual(r.dest?.name, "Zwolle")
        // over at the last stop
        XCTAssertNil(TestTripSim.state(trip, now: t(660)))
        XCTAssertTrue(TestTripSim.over(trip, now: t(660)))
        XCTAssertNil(TestTripSim.state(trip, now: t(-1)))
        // without times: by distance; one stop isn't a trip; a headsign that is the last stop isn't a "then on to"
        let untimed: [TestTripSim.RealStop] = stops.prefix(3).map { TestTripSim.RealStop(name: $0.name, lat: $0.lat, lon: $0.lon, time: nil) }
        let d = try XCTUnwrap(TestTripSim.make(mode: "bus", line: "300", num: nil, trip: "y", stops: untimed, dest: "C", start: t0))
        XCTAssertEqual(d.stops.first?.at, 0)
        XCTAssertEqual(d.stops.last?.at, 600)
        XCTAssertEqual(d.stops[1].at, 300, accuracy: 5)
        XCTAssertNil(d.dest)
        XCTAssertNil(TestTripSim.state(d, now: t(300))?.coach)
        XCTAssertNil(TestTripSim.make(mode: "bus", line: "300", num: nil, trip: "z", stops: [stops[0]], dest: nil, start: t0))
    }

    func test_tripFallback() throws {
        let stations = [NSStation(code: "A", uic: "", name: "Alpha", lat: 51.0, lon: 5.0),
                        NSStation(code: "B", uic: "", name: "Beta", lat: 51.02, lon: 5.0),
                        NSStation(code: "C", uic: "", name: "Gamma", lat: 51.005, lon: 5.0),
                        NSStation(code: "D", uic: "", name: "Delta", lat: 51.1, lon: 5.0)]
        let trip = try XCTUnwrap(TestTripSim.fallback(home: GeoPoint(lat: 51.001, lon: 5.0), stations: stations, start: t0))
        XCTAssertEqual(trip.stops.map(\.name), ["Alpha", "Beta"])
        XCTAssertEqual(trip.trip, "test-friend-A-B")
        XCTAssertTrue(trip.isTrain)
        XCTAssertNil(TestTripSim.fallback(home: GeoPoint(lat: 53.5, lon: 7.5), stations: stations, start: t0))
    }

    func test_waitSim() {
        let stop = TripCard.Spot(name: "Eindhoven Centraal", lat: 51.44306, lon: 5.47917)
        let w = TestWait(id: "w1", stop: stop, start: t0)
        let a = TestWaitSim.body(w, now: t0)
        XCTAssertEqual(a.phase, .coming)
        XCTAssertEqual(a.dist, 650)
        XCTAssertEqual(a.eta, t(300))
        XCTAssertNotNil(WaitFor.valid(a))
        XCTAssertEqual(TestWaitSim.body(w, now: t(150)).dist, 330)
        let b = TestWaitSim.body(w, now: t(300))
        XCTAssertEqual(b.phase, .there)
        XCTAssertEqual(b.dist, 0)
        XCTAssertFalse(TestWaitSim.over(w, now: t(599)))
        XCTAssertTrue(TestWaitSim.over(w, now: t(600)))
        XCTAssertEqual(TestWaitSim.body(w, now: t(600)).phase, .off)
    }

    // MARK: never in your backup

    func test_vaultScrub() throws {
        let sam = try XCTUnwrap(FriendIdentity(seed: seed(0x00)))
        let lou = try XCTUnwrap(FriendIdentity(seed: seed(0x10)))
        let bot = try XCTUnwrap(FriendIdentity(seed: seed(0x40)))
        var book = FriendBook(myName: "Sam")
        book.friends = [Friend(card: lou.card, name: "Lou", since: t0), Friend(card: bot.card, name: "Test friend", since: t0)]
        book.incoming = [FriendRequest(card: bot.card, name: "Test friend", at: t0)]
        let roster = GroupRoster(name: "Crew", admin: sam.account, rev: 1,
                                 members: [GroupMember(card: sam.card, name: "Sam"), GroupMember(card: bot.card, name: "Test friend")])
        let c = FriendVaultContents(book: book, picture: nil, groups: [FriendGroup(id: "g1", roster: roster, since: t0)],
                                    timetable: TimetableSettings(off: [bot.account, lou.account]), extras: ExtrasSettings(buddy: [bot.account]))
        let v = TestFriendBrain.scrub(c, bot: bot.account)
        XCTAssertEqual(v.book.friends.map(\.id), [lou.account])
        XCTAssertTrue(v.book.incoming.isEmpty)
        XCTAssertEqual(v.groups?.first?.roster.members.map(\.id), [sam.account])
        XCTAssertEqual(v.timetable?.off, [lou.account])
        XCTAssertNil(v.extras?.buddy)
        let plain = String(decoding: try FriendJSON.encoder.encode(v), as: UTF8.self)
        XCTAssertFalse(plain.contains(bot.account))
        XCTAssertFalse(plain.contains(B64URL.encode(bot.card.signKey)))
        // nothing to take out: the same
        XCTAssertEqual(TestFriendBrain.scrub(v, bot: bot.account), v)
    }
}
