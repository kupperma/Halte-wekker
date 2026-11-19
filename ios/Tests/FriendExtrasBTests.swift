import XCTest
import CryptoKit

/// Friends 0.30 (extras, part B): free hours together, the friends leaderboard (the `scores` box, byte for byte) and the
/// ride history, as plain rules (docs/superpowers/specs/2026-11-18-friends-design.md, "As built (0.30)").
final class FriendExtrasBTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)          // Friday 15 January 2027, 09:00 in Amsterdam
    let midnight = Date(timeIntervalSince1970: 1_799_967_600)    // that day's 00:00
    private func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    private func at(_ s: TimeInterval) -> Date { Date(timeIntervalSince1970: s) }

    private func hex(_ s: String) -> Data {
        var d = Data()
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            d.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return d
    }

    /// Classes today, as (start, end) seconds after 09:00.
    private func share(_ classes: [(TimeInterval, TimeInterval)], days: Int = 14) -> TimetableShare {
        let cs: [TimetableClass] = classes.map { TimetableClass(start: t($0.0), end: t($0.1)) }
        return TimetableShare(from: midnight, to: midnight.addingTimeInterval(Double(days) * 86400), classes: cs)
    }

    // MARK: free hours together

    // you: 10:15–12:00, 13:30–15:45 · Sam: 09:00–11:30, 13:00–14:00 · Lisa and Kim: 10:00–12:00, 13:30–16:00
    private var mine: TimetableShare { share([(4500, 10800), (16200, 24300)]) }
    private var sam: TimetableShare { share([(0, 9000), (14400, 18000)]) }
    private var lisa: TimetableShare { share([(3600, 10800), (16200, 25200)]) }

    func test_freeToday() {
        let s = FreeToday.slots(mine: mine, friends: [(id: "sam", share: sam), (id: "lisa", share: lisa)], now: t0)
        XCTAssertEqual(s, [FreeTodaySlot(start: t(10800), end: t(14400), with: ["sam"]),
                           FreeTodaySlot(start: t(10800), end: t(16200), with: ["lisa"])])
        XCTAssertEqual(FreeToday.line(s[0], names: ["Sam"], now: t0), "Today: you and Sam are both free 12:00–13:00")
        XCTAssertEqual(FreeToday.line(s[1], names: ["Lisa"], now: t0), "Today: you and Lisa are both free 12:00–13:30")
        XCTAssertEqual(FreeToday.note(s, names: { $0 == "sam" ? "Sam" : "Lisa" }, now: t0),
                       "You and Sam are both free 12:00–13:00\nYou and Lisa are both free 12:00–13:30")
    }

    func test_freeTodayTogetherAndLater() {
        let s = FreeToday.slots(mine: mine, friends: [(id: "lisa", share: lisa), (id: "kim", share: lisa)], now: t0)
        XCTAssertEqual(s, [FreeTodaySlot(start: t(10800), end: t(16200), with: ["kim", "lisa"])])
        XCTAssertEqual(FreeToday.line(s[0], names: ["Kim", "Lisa"], now: t0), "Today: you, Kim and Lisa are all free 12:00–13:30")
        // 12:30: under way; 13:15: Sam's is over
        let mid = FreeToday.slots(mine: mine, friends: [(id: "sam", share: sam)], now: t(12600))
        XCTAssertEqual(FreeToday.line(mid[0], names: ["Sam"], now: t(12600)), "Now: you and Sam are both free until 13:00")
        XCTAssertEqual(FreeToday.slots(mine: mine, friends: [(id: "sam", share: sam), (id: "lisa", share: lisa)], now: t(15300)).map(\.with), [["lisa"]])
    }

    func test_freeTodayNothing() {
        XCTAssertEqual(FreeToday.slots(mine: nil, friends: [(id: "sam", share: sam)], now: t0), [])
        // their timetable doesn't reach today / they have no class today / under 30 minutes together
        let old = TimetableShare(from: midnight.addingTimeInterval(-20 * 86400), to: midnight.addingTimeInterval(-6 * 86400), classes: [])
        XCTAssertEqual(FreeToday.slots(mine: mine, friends: [(id: "x", share: old)], now: t0), [])
        XCTAssertEqual(FreeToday.slots(mine: mine, friends: [(id: "x", share: share([]))], now: t0), [])
        let short = share([(0, 11400), (13200, 18000)])           // free 12:10–12:40: 30 min with you, kept; 12:15–12:40 not
        XCTAssertEqual(FreeToday.slots(mine: mine, friends: [(id: "x", share: short)], now: t0).count, 1)
        let shorter = share([(0, 11700), (13200, 18000)])
        XCTAssertEqual(FreeToday.slots(mine: mine, friends: [(id: "x", share: shorter)], now: t0), [])
    }

    func test_freeTodayNote() {
        let s = FreeToday.slots(mine: mine, friends: [(id: "sam", share: sam)], now: t0)
        XCTAssertTrue(FreeToday.noteDue(on: true, lastDay: nil, slots: s, now: t0))
        XCTAssertTrue(FreeToday.noteDue(on: true, lastDay: "2027-01-14", slots: s, now: t(-3 * 3600)))     // 06:00
        XCTAssertFalse(FreeToday.noteDue(on: true, lastDay: nil, slots: s, now: t(-3 * 3600 - 60)))      // 05:59
        XCTAssertFalse(FreeToday.noteDue(on: true, lastDay: nil, slots: s, now: t(2 * 3600)))            // 11:00
        XCTAssertFalse(FreeToday.noteDue(on: true, lastDay: "2027-01-15", slots: s, now: t0))
        XCTAssertFalse(FreeToday.noteDue(on: false, lastDay: nil, slots: s, now: t0))
        XCTAssertFalse(FreeToday.noteDue(on: true, lastDay: nil, slots: [], now: t0))
    }

    // MARK: the friends leaderboard

    private var myTrips: [ScoreTrip] {
        [ScoreTrip(route: "home→school", home: false, mins: 52.34, at: at(1_799_391_600)),     // last week
         ScoreTrip(route: "home→school", home: false, mins: 48.5, at: at(1_799_996_400)),      // this morning
         ScoreTrip(route: "school→home", home: true, mins: 52, at: at(1_799_910_000)),
         ScoreTrip(route: "school→home", home: true, mins: 55, at: at(1_798_000_000)),          // December
         ScoreTrip(route: "home→school", home: false, mins: 3, at: at(1_799_996_000))]          // too short to count
    }

    func test_scoresBuild() {
        let s = ScoresRules.build(trips: myTrips, rides: 14, now: t0)
        XCTAssertEqual(s.month, "2027-01")
        XCTAssertEqual(s.best, [ScoresShare.Best(route: "home→school", home: false, mins: 48.5, at: at(1_799_996_400)),
                                ScoresShare.Best(route: "school→home", home: true, mins: 52, at: at(1_799_910_000))])
        XCTAssertEqual(s.mbest, [ScoresShare.Best(route: "home→school", home: false, mins: 48.5, at: at(1_799_996_400)),
                                 ScoresShare.Best(route: "school→home", home: true, mins: 52, at: at(1_799_910_000))])
        XCTAssertEqual(s.rides, 14)
        XCTAssertEqual(ScoresRules.month(at(1_798_000_000)), "2026-12")
        XCTAssertTrue(ScoresRules.isMonth("2027-01"))
        XCTAssertFalse(ScoresRules.isMonth("2027-13"))
        XCTAssertFalse(ScoresRules.isMonth("27-01"))
    }

    func test_scoresValid() {
        var s = ScoresShare(on: true, month: "2027-1", best: [ScoresShare.Best(route: "  Via\tDen  Bosch ", home: false, mins: 40, at: t0),
                                                             ScoresShare.Best(route: "", home: false, mins: 40, at: t0),
                                                             ScoresShare.Best(route: "x", home: true, mins: 601, at: t0)],
                            mbest: [ScoresShare.Best(route: "x", home: true, mins: 30, at: t0)], rides: 3)
        var v = ScoresShare.valid(s)
        XCTAssertEqual(v.best, [ScoresShare.Best(route: "Via Den Bosch", home: false, mins: 40, at: t0)])
        XCTAssertNil(v.month)
        XCTAssertNil(v.mbest)
        XCTAssertNil(v.rides)
        s.month = "2027-01"
        s.rides = 5000
        s.best = Array(repeating: ScoresShare.Best(route: "r", home: false, mins: 20, at: t0), count: 12)
        v = ScoresShare.valid(s)
        XCTAssertEqual(v.best?.count, 8)
        XCTAssertEqual(v.mbest?.count, 1)
        XCTAssertNil(v.rides)
        XCTAssertEqual(ScoresShare.valid(ScoresShare(on: false, month: "2027-01", rides: 2)), ScoresShare(on: false))
    }

    func test_scoresDue() {
        let friends = ["b", "a"]
        XCTAssertEqual(ScoresRules.due(last: nil, hash: "h1", friends: friends, now: t0), ["a", "b"])
        XCTAssertEqual(ScoresRules.due(last: nil, hash: "h1", friends: [], now: t0), [])
        let sent = TimetableShareRules.Sent(hash: "h1", at: t0, to: ["a", "b"])
        XCTAssertEqual(ScoresRules.due(last: sent, hash: "h1", friends: friends, now: t(3600)), [])
        XCTAssertEqual(ScoresRules.due(last: sent, hash: "h2", friends: friends, now: t(3600)), [])               // changed, too soon
        XCTAssertEqual(ScoresRules.due(last: sent, hash: "h2", friends: friends, now: t(12 * 3600)), ["a", "b"])
        XCTAssertEqual(ScoresRules.due(last: sent, hash: "h1", friends: friends + ["c"], now: t(3600)), ["c"])  // a new friend at once
        XCTAssertEqual(ScoresRules.due(last: sent, hash: "h1", friends: friends, now: t(7 * 86400)), ["a", "b"])
        XCTAssertNotEqual(ScoresRules.fingerprint(ScoresRules.build(trips: myTrips, rides: 14, now: t0)),
                          ScoresRules.fingerprint(ScoresRules.build(trips: myTrips, rides: 15, now: t0)))
    }

    func test_scoreBoard() {
        let me = ScoresPerson(id: "me", share: ScoresRules.build(trips: myTrips, rides: 14, now: t0))
        let sam = ScoresPerson(id: "sam", share: ScoresShare(on: true, month: "2027-01",
            best: [ScoresShare.Best(route: "home→school", home: false, mins: 39.5, at: at(1_799_000_000)),
                   ScoresShare.Best(route: "Via Den Bosch", home: false, mins: 61, at: at(1_799_000_000))],
            mbest: [ScoresShare.Best(route: "home→school", home: false, mins: 44, at: at(1_799_900_000))], rides: 20))
        let lou = ScoresPerson(id: "lou", share: ScoresShare(on: true, month: "2026-12",
            best: [ScoresShare.Best(route: "school→home", home: true, mins: 50, at: at(1_798_000_000))],
            mbest: [ScoresShare.Best(route: "school→home", home: true, mins: 50, at: at(1_798_000_000))], rides: 30))
        let off = ScoresPerson(id: "off", share: ScoresShare(on: false))
        let all: [ScoresPerson] = [me, sam, lou, off]
        let ever = ScoreBoard.groups(all, month: nil)
        XCTAssertEqual(ever.map(\.id), ["false|home→school", "false|Via Den Bosch", "true|school→home"])
        XCTAssertEqual(ever[0].rows.map(\.who), ["sam", "me"])
        XCTAssertEqual(ever[2].rows.map(\.who), ["lou", "me"])
        let month = ScoreBoard.groups(all, month: "2027-01")
        XCTAssertEqual(month.map(\.id), ["false|home→school", "true|school→home"])
        XCTAssertEqual(month[0].rows.map(\.mins), [44, 48.5])
        XCTAssertEqual(month[1].rows.map(\.who), ["me"])                       // Lou's are December's
        XCTAssertEqual(ScoreBoard.rides(all, month: "2027-01"), [RidesRow(who: "sam", n: 20), RidesRow(who: "me", n: 14)])
    }

    // the `scores` box from Sam to Lou (keys as in 0.25), made with Node's crypto from the spec
    static let scoresPayload = "{\"b\":{\"best\":[{\"at\":1799996400,\"home\":false,\"mins\":48.5,\"route\":\"home→school\"},{\"at\":1799910000,\"home\":true,\"mins\":52,\"route\":\"school→home\"}],\"mbest\":[{\"at\":1799996400,\"home\":false,\"mins\":48.5,\"route\":\"home→school\"}],\"month\":\"2027-01\",\"on\":true,\"rides\":14},\"f\":\"3c157621a97cf055f5804a9826c6d1e1\",\"k\":\"scores\",\"n\":\"vector-16\",\"t\":1800000000,\"v\":1}"
    static let scoresSig = "6rLh_QChtON4H7TK4hzq8a0UxhBkm55Zq67PCwiZFCholCtVlWmo5R_13XRlGu7Vb3wcZU9wVpqMKxKcSoqcDQ"
    static let scoresBox = "AZzO11GzAbvRbE-43t3YLxiSXXHtkMhE-gFY-EWw-n9L0dLT1NXW19jZ2tvd2yVEWneoEWqLeQL9E6U4tx_P1PQUZHFE0SJnGsrRekEFLdfQJJ5WTl07a8y-r1W9TrD3wY0xRFCfEXBmplz4mbB53BKkqZiLX1r8JAtjw4gc3cCshJuxPi5wI6VyWk0syVe7ZR6lvKJVRH9hMzJtULbGBPzrLoZSB9OXwcj5PnVuQUZcc6tJiAi8C6pFIfu05GXTXY97-zshmL0FOGC7GmeF2WBWojbxnt4SHwxt0VX4zc625bdH-6DVzm-mNejIBbheioXp_XLn39U4-tf3dhUMB8aarwPDxeQKawwjQjgXC2ZMVveb5jvkKqLEvjEv7zSVITyNma_T9cjEgvmZQi1Drlfv5TGcVOzF8Zlli2sWQFAtU6tdXEiqw_PW-jqIYHH7psu0FGzeLPbO_HWKJ__71nlMtqW9VptFYoHTdOjNjDHStEm5x8fMsXwAOW2thjzBvyctDHCJk0LZCgHQBCGgAt45xCgHTDViqG97IYH-qzRN6VNIavLbEhvui4514nG_Usol_5kP2S0j2gpM_B59rPMkNF4cTFLygK7GN9AXWtLKkTO5zMqD0dF4V4vm"

    func test_scoresBox() throws {
        XCTAssertTrue(FriendMessage.known.contains("scores"))
        XCTAssertEqual(FriendMessage.kindsVersion, 6)
        let sam = FriendIdentity(seed: hex("000102030405060708090a0b0c0d0e0f"))!
        let lou = FriendIdentity(seed: hex("101112131415161718191a1b1c1d1e1f"))!
        let body = ScoresRules.build(trips: myTrips, rides: 14, now: t0)
        let p = try FriendBox.payload(.scores(body), from: sam.account, at: t0, id: "vector-16")
        XCTAssertEqual(String(decoding: p, as: UTF8.self), Self.scoresPayload)
        let s = try XCTUnwrap(B64URL.decode(Self.scoresSig))
        XCTAssertTrue(sam.signing.publicKey.isValidSignature(s, for: FriendBox.signed(p, to: lou.account)))
        let eph = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex("9192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeafb0"))
        XCTAssertEqual(eph.publicKey.rawRepresentation.hexString, "9cced751b301bbd16c4fb8deddd82f18925d71ed90c844fa0158f845b0fa7f4b")
        let locked = try FriendBox.lock(s + p, to: lou.card, eph: eph, nonce: try ChaChaPoly.Nonce(data: hex("d1d2d3d4d5d6d7d8d9dadbdd")))
        XCTAssertEqual(B64URL.encode(locked), Self.scoresBox)
        // Lou opens it
        let opened = try FriendBox.open(try XCTUnwrap(B64URL.decode(Self.scoresBox)), me: lou, from: sam.account, known: { $0 == sam.account ? sam.card : nil })
        XCTAssertEqual(opened.message, .scores(body))
        // and reads it from a friend only
        var book = FriendBook(myName: "Lou")
        let box = RelayBox(id: 1, from: sam.account, slot: "scores", at: 1_800_000_001, exp: 1_801_000_000, data: Self.scoresBox)
        XCTAssertTrue(FriendInbox.process([box], book: book, me: lou, now: t0).scores.isEmpty)
        book.friends = [Friend(card: sam.card, name: "Sam", since: t0)]
        let r = FriendInbox.process([box], book: book, me: lou, now: t0)
        XCTAssertEqual(r.scores[sam.account]?.share, body)
        XCTAssertEqual(r.ack, [1])
    }

    // MARK: ride history together

    private let ehv = TravelState.Spot(name: "Eindhoven Centraal", lat: 51.44306, lon: 5.47917)
    private let bd = TravelState.Spot(name: "Breda", lat: 51.59556, lon: 4.78)

    private func travel(_ trip: String, _ stage: String = "riding") -> TravelState {
        TravelState(state: stage, mode: "train", line: "IC", num: "3512", trip: trip, from: ehv, to: bd)
    }

    private func card(_ trip: String) -> TripCard {
        let a = TripCard.Spot(name: "Eindhoven Centraal"), b = TripCard.Spot(name: "Breda")
        return TripCard(rides: [TripCard.Ride(mode: "bus", line: "6", trip: "bus-6", from: a, to: a, dep: t0, arr: t(600)),
                                TripCard.Ride(mode: "train", line: "IC", trip: trip, from: a, to: b, dep: t(660), arr: t(3720))], to: b)
    }

    func test_ridersTogether() {
        let tr: [(from: String, state: TravelState)] = [(from: "sam", state: travel("ic-3512")), (from: "lisa", state: travel("ic-3512", "waiting")),
                                                         (from: "tom", state: travel("ic-3516"))]
        XCTAssertEqual(RideHistory.riders(trip: "ic-3512", travel: tr, cards: [], me: "me"), ["sam"])
        let cards: [(card: TripCard, riders: [String])] = [(card: card("ic-3512"), riders: ["kim", "sam"]), (card: card("ic-3520"), riders: ["tom"])]
        XCTAssertEqual(RideHistory.riders(trip: "ic-3512", travel: tr, cards: cards, me: "me"), ["kim", "sam"])
        XCTAssertEqual(RideHistory.riders(trip: "bus-6", travel: tr, cards: cards, me: "me"), [])      // a card's shared ride is its train
        XCTAssertEqual(RideHistory.riders(trip: "", travel: tr, cards: cards, me: "me"), [])
    }

    private func ride(_ trip: String, _ day: String, dep: Date, with: [String]) -> RideTogether {
        RideTogether(trip: trip, day: day, label: "IC 3512", from: "Eindhoven Centraal", to: "Breda", dep: dep, with: with)
    }

    func test_rideHistory() {
        var h: [RideTogether] = []
        h = RideHistory.add(h, ride("ic-3512", "2027-01-15", dep: t0, with: ["sam"]), now: t0)
        h = RideHistory.add(h, ride("ic-3512", "2027-01-15", dep: t0, with: ["kim", "sam"]), now: t(60))      // same ride: merged
        h = RideHistory.add(h, ride("ic-3520", "2027-01-14", dep: t(-86400), with: ["sam"]), now: t0)
        h = RideHistory.add(h, ride("ic-3500", "2026-12-20", dep: at(1_797_750_000), with: ["sam"]), now: t0)
        h = RideHistory.add(h, ride("ic-1", "2027-01-15", dep: t0, with: []), now: t0)                         // nobody: not kept
        XCTAssertEqual(h.count, 3)
        XCTAssertEqual(h[0].with, ["kim", "sam"])
        XCTAssertEqual(RideHistory.count(h, with: "sam", now: t0), 2)
        XCTAssertEqual(RideHistory.count(h, with: "kim", now: t0), 1)
        XCTAssertEqual(RideHistory.count(h, now: t0), 2)
        XCTAssertEqual(RideHistory.last(h, with: "sam").map(\.trip), ["ic-3512", "ic-3520", "ic-3500"])
        XCTAssertEqual(RideHistory.last(h, with: "sam", limit: 1).map(\.trip), ["ic-3512"])
        // a year and more later, the old ones go
        XCTAssertEqual(RideHistory.add(h, ride("x", "2028-03-01", dep: t(410 * 86400), with: ["sam"]), now: t(410 * 86400)).map(\.trip), ["x"])
        // someone no longer a friend
        XCTAssertEqual(RideHistory.keep(h, friends: ["kim"]).map(\.trip), ["ic-3512"])
        XCTAssertEqual(RideHistoryWords.month(14), "You rode together 14 times this month")
        XCTAssertEqual(RideHistoryWords.month(1), "You rode together once this month")
        XCTAssertEqual(RideHistoryWords.month(0), "No rides together this month yet")
        XCTAssertEqual(RideHistoryWords.row(h[0]), "Fri 15 Jan · 09:00 · IC 3512 · Eindhoven Centraal → Breda")
    }
}
