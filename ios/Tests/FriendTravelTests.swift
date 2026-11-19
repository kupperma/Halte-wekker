import XCTest
import CryptoKit

/// Friends 0.26: the travel state, how old it may be, when it's shared and with whom, its words, and the coach sums.
final class FriendTravelTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let utc = TimeZone(identifier: "UTC")!

    private func state(_ stage: String = "riding", mode: String = "train", line: String? = "IC", num: String? = "3512",
                       eta: Date? = nil, end: Date? = nil) -> TravelState {
        var s = TravelState(state: stage, mode: mode, from: .init(name: "Eindhoven Centraal", lat: 51.44, lon: 5.48),
                            to: .init(name: "Breda", lat: 51.59, lon: 4.78))
        s.line = line
        s.num = num
        s.eta = eta
        s.end = end
        return s
    }

    // MARK: the state

    func test_jsonIsPlainAndRoundTrips() throws {
        var s = state(eta: t0.addingTimeInterval(600))
        s.pos = .init(lat: 51.5, lon: 5.2, acc: 10, at: t0)
        s.coach = .init(n: 2, of: 4, front: true, at: "EHV")
        let d = try FriendJSON.encoder.encode(s)
        let j = String(decoding: d, as: UTF8.self)
        XCTAssertTrue(j.contains(#""eta":1800000600"#), j)
        XCTAssertTrue(j.contains(#""state":"riding""#), j)
        XCTAssertFalse(j.contains("dest"), "an empty optional is left out: \(j)")
        XCTAssertEqual(try FriendJSON.decoder.decode(TravelState.self, from: d), s)
    }

    func test_readsWhatANewerAppMightWrite() throws {
        let j = #"{"state":"boarding-soon","mode":"tram","from":{"name":"A"},"to":{"name":"B"},"extra":{"x":1},"line":null}"#
        let s = try FriendJSON.decoder.decode(TravelState.self, from: Data(j.utf8))
        XCTAssertEqual(s.stage, .riding, "an unknown stage reads as riding")
        XCTAssertNil(s.line)
        XCTAssertEqual(TravelWords.vehicle(s), "Tram")
    }

    // MARK: how old

    func test_freshness() {
        let exp = t0.addingTimeInterval(360)
        XCTAssertEqual(TravelAge.freshness(sent: t0, exp: exp, end: nil, now: t0.addingTimeInterval(60)), .fresh)
        XCTAssertEqual(TravelAge.freshness(sent: t0, exp: exp, end: nil, now: t0.addingTimeInterval(150)), .fresh)
        XCTAssertEqual(TravelAge.freshness(sent: t0, exp: exp, end: nil, now: t0.addingTimeInterval(200)), .stale)
        XCTAssertEqual(TravelAge.freshness(sent: t0, exp: exp, end: nil, now: t0.addingTimeInterval(360)), .gone, "the relay's expiry")
        XCTAssertEqual(TravelAge.freshness(sent: t0, exp: nil, end: nil, now: t0.addingTimeInterval(601)), .gone)
        XCTAssertEqual(TravelAge.freshness(sent: t0, exp: nil, end: t0.addingTimeInterval(-21 * 60), now: t0.addingTimeInterval(10)), .gone,
                       "long past its arrival")
        XCTAssertEqual(TravelAge.freshness(sent: t0, exp: nil, end: t0.addingTimeInterval(-5 * 60), now: t0.addingTimeInterval(10)), .fresh,
                       "a few minutes late is still on its way")
    }

    func test_due() {
        XCTAssertTrue(TravelAge.due(last: nil, now: t0))
        XCTAssertFalse(TravelAge.due(last: t0, now: t0.addingTimeInterval(30)))
        XCTAssertTrue(TravelAge.due(last: t0, now: t0.addingTimeInterval(55)))
    }

    // MARK: when, and with whom

    func test_confirmedOnBoard() {
        typealias S = TravelShareRules.Signals
        let auto = S(running: true)
        XCTAssertFalse(TravelShareRules.confirmed(before: false, auto), "started by itself, nothing matched yet")
        XCTAssertTrue(TravelShareRules.confirmed(before: false, S(running: true, startedByHand: true)))
        XCTAssertTrue(TravelShareRules.confirmed(before: false, S(running: true, vehicleMatched: true)))
        XCTAssertTrue(TravelShareRules.confirmed(before: false, S(running: true, pickedByHand: true)))
        XCTAssertTrue(TravelShareRules.confirmed(before: true, auto), "once confirmed, for the whole trip")
        XCTAssertFalse(TravelShareRules.confirmed(before: true, S(running: false, startedByHand: true)), "no trip, nothing")
        XCTAssertFalse(TravelShareRules.confirmed(before: true, S(running: true, demo: true, startedByHand: true)), "never the demo")
    }

    func test_decide() {
        let two: [(id: String, on: Bool)] = [(id: "a", on: true), (id: "b", on: false)]
        XCTAssertEqual(TravelShareRules.decide(consent: true, paused: false, confirmed: true, friends: two, sentBefore: false), .share(["a"]))
        XCTAssertEqual(TravelShareRules.decide(consent: nil, paused: false, confirmed: true, friends: two, sentBefore: false), .ask)
        XCTAssertEqual(TravelShareRules.decide(consent: nil, paused: false, confirmed: false, friends: two, sentBefore: false), .none,
                       "not on board: no question yet")
        XCTAssertEqual(TravelShareRules.decide(consent: true, paused: true, confirmed: true, friends: two, sentBefore: true), .clear)
        XCTAssertEqual(TravelShareRules.decide(consent: true, paused: true, confirmed: true, friends: two, sentBefore: false), .none)
        XCTAssertEqual(TravelShareRules.decide(consent: false, paused: false, confirmed: true, friends: two, sentBefore: false), .none)
        XCTAssertEqual(TravelShareRules.decide(consent: true, paused: false, confirmed: false, friends: two, sentBefore: true), .clear,
                       "the trip ended")
        XCTAssertEqual(TravelShareRules.decide(consent: true, paused: false, confirmed: true, friends: [], sentBefore: false), .none)
        XCTAssertEqual(TravelShareRules.decide(consent: true, paused: false, confirmed: true, friends: [(id: "b", on: false)], sentBefore: true), .clear,
                       "the last friend's switch went off")
    }

    func test_toClear() {
        XCTAssertEqual(TravelShareRules.toClear(sentTo: ["a", "b", "c"], now: ["a", "c"]), ["b"])
        XCTAssertEqual(TravelShareRules.toClear(sentTo: [], now: ["a"]), [])
    }

    func test_showTripsSwitchIsKeptInTheList() throws {
        let me = FriendIdentity.random(), sam = FriendIdentity.random()
        var b = FriendBook(myName: "Lou")
        b.friends = [Friend(card: sam.card, name: "Sam", since: t0)]
        XCTAssertTrue(b.friends[0].showsTrips, "on by default")
        b.showTrips(sam.account, false)
        XCTAssertFalse(b.friends[0].showsTrips)
        let j = String(decoding: try FriendJSON.encoder.encode(b.friends[0]), as: UTF8.self)
        XCTAssertTrue(j.contains(#""trips":false"#), j)
        b.showTrips(sam.account, true)
        XCTAssertNil(b.friends[0].trips, "on again is the default")
        let old = try FriendJSON.decoder.decode(Friend.self, from: try FriendJSON.encoder.encode(b.friends[0]))
        XCTAssertTrue(old.showsTrips)
        _ = me
    }

    // MARK: reading friends' states

    private func relayState(_ s: TravelState, from: FriendIdentity, to: FriendIdentity, at: Int, exp: Int, t: Date? = nil) throws -> RelayState {
        let d = try FriendBox.seal(.travel(s), from: from, to: to.card, at: t ?? Date(timeIntervalSince1970: TimeInterval(at)))
        return RelayState(from: from.account, at: at, exp: exp, data: B64URL.encode(d))
    }

    func test_readStates() throws {
        let me = FriendIdentity.random(), sam = FriendIdentity.random(), eve = FriendIdentity.random()
        var b = FriendBook(myName: "Lou")
        b.friends = [Friend(card: sam.card, name: "Sam", since: t0)]
        b.incoming = [FriendRequest(card: eve.card, name: "Eve", at: t0)]
        let now = t0.addingTimeInterval(30)
        let at = Int(t0.timeIntervalSince1970)
        let list = [
            try relayState(state(), from: sam, to: me, at: at, exp: at + 360),
            try relayState(state(line: "SPR"), from: eve, to: me, at: at, exp: at + 360),             // not a friend (yet)
        ]
        let seen = FriendInbox.readStates(list, book: b, me: me, now: now)
        XCTAssertEqual(Array(seen.keys), [sam.account])
        XCTAssertEqual(seen[sam.account]?.state.line, "IC")
        XCTAssertEqual(seen[sam.account]?.sent, t0)
        // expired, or for someone else: not shown
        let old = try relayState(state(), from: sam, to: me, at: at - 400, exp: at - 40)
        XCTAssertTrue(FriendInbox.readStates([old], book: b, me: me, now: now).isEmpty)
        let other = try relayState(state(), from: sam, to: eve, at: at, exp: at + 360)
        XCTAssertTrue(FriendInbox.readStates([other], book: b, me: me, now: now).isEmpty)
        // a clock ahead of the relay counts from when the relay got it
        let ahead = try relayState(state(), from: sam, to: me, at: at, exp: at + 360, t: t0.addingTimeInterval(200))
        XCTAssertEqual(FriendInbox.readStates([ahead], book: b, me: me, now: now)[sam.account]?.sent, t0)
    }

    func test_travelBoxInTheMailboxChangesNothing() throws {
        let me = FriendIdentity.random(), sam = FriendIdentity.random()
        var b = FriendBook(myName: "Lou")
        b.friends = [Friend(card: sam.card, name: "Sam", since: t0)]
        let d = try FriendBox.seal(.travel(state()), from: sam, to: me.card)
        let r = FriendInbox.process([RelayBox(id: 7, from: sam.account, slot: nil, at: 0, exp: 0, data: B64URL.encode(d))], book: b, me: me, now: t0)
        XCTAssertEqual(r.book, b)
        XCTAssertEqual(r.ack, [7])
        XCTAssertTrue(FriendMessage.known.contains("travel"))
        XCTAssertGreaterThanOrEqual(FriendMessage.kindsVersion, 2)
    }

    // MARK: words

    func test_words() {
        let eta = t0.addingTimeInterval(43 * 60)                 // 08:43 UTC
        XCTAssertEqual(TravelWords.summary(state(eta: eta), zone: utc), "IC 3512 to Breda · arrives 08:43")
        XCTAssertEqual(TravelWords.summary(state(mode: "bus", line: "306", num: nil), zone: utc), "Bus 306 to Breda")
        XCTAssertEqual(TravelWords.summary(state("waiting", mode: "bus", line: "306", num: nil)), "Waiting for bus 306 at Eindhoven Centraal")
        XCTAssertEqual(TravelWords.summary(state("waiting", mode: "bus", line: nil, num: nil)), "Waiting for the bus at Eindhoven Centraal")
        XCTAssertEqual(TravelWords.summary(state("waiting")), "Waiting for the IC 3512 at Eindhoven Centraal")
        XCTAssertEqual(TravelWords.summary(state("change", line: nil, num: nil)), "Changing at Eindhoven Centraal")
        XCTAssertEqual(TravelWords.summary(state("change", line: "SPR", num: nil)), "Changing at Eindhoven Centraal · then SPR to Breda")
        XCTAssertEqual(TravelWords.vehicle(state(line: nil, num: nil)), "Train")
        var s = state(end: eta)
        XCTAssertNil(TravelWords.ending(s, zone: utc))
        s.dest = .init(name: "BUas")
        XCTAssertEqual(TravelWords.ending(s, zone: utc), "To BUas, there around 08:43")
        let seen = FriendTravelSeen(from: "x", state: s, sent: t0, exp: t0.addingTimeInterval(360))
        XCTAssertNil(TravelWords.age(seen, now: t0.addingTimeInterval(60)))
        XCTAssertEqual(TravelWords.age(seen, now: t0.addingTimeInterval(200), zone: utc), "Last update 08:00 · may have moved on")
    }

    // MARK: the coach

    func test_coachSpots() {
        // two units: 4 coaches and 2 coaches, drawn left to right
        let units = [CoachMap.Unit(x: 0, w: 0.6, cars: 4), CoachMap.Unit(x: 0.6, w: 0.4, cars: 2)]
        let all = CoachMap.spots(units)
        XCTAssertEqual(all.count, 6)
        XCTAssertEqual(all[0].x0, 0, accuracy: 1e-9)
        XCTAssertEqual(all[3].x1, 0.6, accuracy: 1e-9)
        XCTAssertEqual(all[5].mid, 0.9, accuracy: 1e-9)
        XCTAssertEqual(all.map(\.drawn), [0, 1, 2, 3, 4, 5])
        // coaches not listed: the train's length shared out by length, at least one a unit
        XCTAssertEqual(CoachMap.spots([CoachMap.Unit(x: 0, w: 0.5, cars: 0), CoachMap.Unit(x: 0.5, w: 0.5, cars: 0)], totalCars: 8).count, 8)
        XCTAssertEqual(CoachMap.spots([CoachMap.Unit(x: 0, w: 1, cars: 0)]).count, 1)
    }

    func test_coachNumbersFromTheFront() {
        XCTAssertTrue(CoachMap.number(drawn: 0, of: 6, dir: "left") == (1, true))
        XCTAssertTrue(CoachMap.number(drawn: 0, of: 6, dir: "right") == (6, true))
        XCTAssertTrue(CoachMap.number(drawn: 2, of: 6, dir: nil) == (3, false))
        let c = TravelState.Coach(n: 3, of: 6, front: true, at: "EHV")
        XCTAssertEqual(CoachMap.drawn(c, total: 6, dir: "left", station: "BD"), 2)
        XCTAssertEqual(CoachMap.drawn(c, total: 6, dir: "right", station: "BD"), 3)
        XCTAssertNil(CoachMap.drawn(c, total: 6, dir: nil, station: "BD"), "which way it goes isn't known")
        XCTAssertNil(CoachMap.drawn(c, total: 4, dir: "left", station: "BD"), "another length: another train")
        let drawnOnly = TravelState.Coach(n: 3, of: 6, front: false, at: "EHV")
        XCTAssertEqual(CoachMap.drawn(drawnOnly, total: 6, dir: nil, station: "EHV"), 2, "the same drawing")
        XCTAssertNil(CoachMap.drawn(drawnOnly, total: 6, dir: nil, station: "BD"))
    }

    func test_coachLabels() {
        XCTAssertEqual(CoachMap.label(.init(n: 3, of: 6, front: true)), "Coach 3 of 6 · front")
        XCTAssertEqual(CoachMap.label(.init(n: 4, of: 6, front: true)), "Coach 4 of 6 · back")
        XCTAssertEqual(CoachMap.label(.init(n: 3, of: 5, front: true)), "Coach 3 of 5 · middle")
        XCTAssertEqual(CoachMap.label(.init(n: 3, of: 6, front: false)), "Coach 3 of 6")
        XCTAssertEqual(CoachMap.part(1, of: 1), "middle")
    }

    func test_platformHint() {
        let units = [CoachMap.Unit(x: 0, w: 0.5, cars: 3), CoachMap.Unit(x: 0.5, w: 0.5, cars: 3)]
        let letters: [(letter: String, x: Double)] = [("A", 0.05), ("B", 0.3), ("C", 0.55), ("D", 0.85)]
        let c = TravelState.Coach(n: 2, of: 6, front: true, at: "EHV")
        // leaving to the left: coach 2 from the front is the second from the left (0.17-0.33): near B
        XCTAssertEqual(CoachMap.platformHint(c, units: units, totalCars: 6, letters: letters, dir: "left", station: "BD"),
                       "Wait near B, at the front end of the platform")
        // leaving to the right: it's the fifth from the left (0.67-0.83): near D
        XCTAssertEqual(CoachMap.platformHint(c, units: units, totalCars: 6, letters: letters, dir: "right", station: "BD"),
                       "Wait near D, at the front end of the platform")
        XCTAssertEqual(CoachMap.platformHint(c, units: units, totalCars: 6, letters: [], dir: "left", station: "BD"), "Coach 2 from the front")
        XCTAssertEqual(CoachMap.platformHint(c, units: units, totalCars: 6, letters: letters, dir: nil, station: "BD"), "Coach 2 from the front")
        XCTAssertNil(CoachMap.platformHint(.init(n: 2, of: 6, front: false, at: "EHV"), units: units, totalCars: 6, letters: letters, dir: nil, station: "BD"))
        XCTAssertEqual(CoachMap.platformHint(.init(n: 2, of: 6, front: false, at: "BD"), units: units, totalCars: 6, letters: letters, dir: nil, station: "BD"),
                       "Wait near B on the platform")
    }
}
