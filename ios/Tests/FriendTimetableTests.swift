import XCTest
import CryptoKit

/// Friends 0.28: the timetable and area boxes, byte for byte (docs/superpowers/specs/2026-11-18-friends-design.md,
/// "As built (0.28)"), made with Node's crypto from the spec alone.
final class FriendTimetableVectorTests: XCTestCase {
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

    private var sam: FriendIdentity { FriendIdentity(seed: hex("000102030405060708090a0b0c0d0e0f"))! }
    private var lou: FriendIdentity { FriendIdentity(seed: hex("101112131415161718191a1b1c1d1e1f"))! }

    static let timetablePayload = "{\"b\":{\"classes\":[{\"end\":1800010800,\"room\":\"C1.02\",\"start\":1800004500,\"title\":\"Design\"},{\"end\":1800024300,\"start\":1800016200,\"title\":\"Maths\"}],\"from\":1799967600,\"src\":\"calendar\",\"to\":1801177200},\"f\":\"3c157621a97cf055f5804a9826c6d1e1\",\"k\":\"timetable\",\"n\":\"vector-8\",\"t\":1800000000,\"v\":1}"
    static let timetableSig = "PhtJtWWwYne2jAvNgh5dBivMMs3MYal36jGMHf91URegi3vJOFDnTX0frmmjT9YZbsI9UV-73lkwk2sUBGeMDA"
    static let timetableBox = "AXNoRdVOh94J1rsRSqcELFCkoBW9mQHRoAJvWVZTOhUZCgsMDQ4PEBESExQVUxMTxDR2FAxkJX3qhoNrBCJncUIfOfkfJjntZ0pd8fh1vrOGo-Sys35eTTnNHXM-Az3pzc_CH_XS_TIA9hRe6PMo321YrlGo3tfPC10VxchYYlzyAER-DubzI_Ix_3ALwatYL9PW0TmCATUVWG_UBXAbN7fkj8RioTXAa2EmWbWnpt38MYvc6sVFvYKTru2KsvRPZkqpS4wHmndn0-T4FE0g3Ey_vm4YZcw4i4riTdqYUmRFtHjCEpo7AbXb_MXgb4TgPdfZ-m-yX1YLptvqZXDSLx716k3zFL_Po4whHeR8Ds6q7uTZJpvF9uRnSIQgqG_NXv7C95b89-W3kDlBIc8aPhmKfH03cGrgp6wsvK8P-rPOvKdaYs2e30A4g6bFjnGnHRESID5IJog5ROBAQoG1EkrDeGE1SPudxqn5lSW6dNfGtCC1dXB8kGcHOoHCaBBlrH4fdgSCl77ft98vH1Hd_rfeRg6TYh0IhaM"
    static let areaPayload = "{\"b\":{\"early\":10,\"school\":{\"lat\":51.5866,\"lon\":4.7745,\"name\":\"BUas\"},\"station\":{\"code\":\"EHV\",\"lat\":51.44306,\"lon\":5.47917,\"name\":\"Eindhoven Centraal\"},\"stops\":[{\"id\":\"vector-stop-1\",\"lat\":51.4401,\"lon\":5.4789,\"name\":\"Eindhoven, Station\"}]},\"f\":\"3c157621a97cf055f5804a9826c6d1e1\",\"k\":\"area\",\"n\":\"vector-9\",\"t\":1800000000,\"v\":1}"
    static let areaSig = "Ss9LsAU1yEaX78X0NNGZFVbmMGCXyExL5bWwVVSymzYmKLKb_MhS1ygSw5fsTHnDaCSo7OIwxLpf6-TAM0PDDA"
    static let areaBox = "AU0nvO4xNcSUSyjSfdgJsHvhDDUWDSATHKp-hVdUmNB8FhcYGRobHB0eHyAhU3XtQHq-Kuv74wBPlsCOmaWksIfkUDbPCW0apmIKieezb6cFqAZ63AHeQe4XXFDv76oFbqYeUij9rl0PMQwxkFmNZgK2Mg1oqBp3sDufRowOyjVrcRDaP4obdhOlN9ot0tQ4Iuifd4oCvkFWMc7MhWNZ8eVA0IXLBIlTsRiQoysMZ1CxgTULPogfMBFoCh9g0vu1ZWsd58izUufy1Zl2uL3_X5bnb0_hJuCQrmKMlkzJeIWTVxGQbRiq5ap13GALwBblYhO2Y10ZWjIynlfs1LIFG3E5uKAViR74WGG4inY-wV5asAhgo2VkMJsPV4aLkjZUJxpAF26TVVBXl2K_S95hD66KYH2QqrQp7zy1AnEn6iyP-tz-lg3Rxpf5_8LliKgaRCufXpu0qgq-gJsiiqeHwibhVEBwOQUIZV0couDS9kiCU-tkao2VcGmfgsfxgliM-1R9Dxat4OU8GvYy4t3SwoL6ukAMlKxbSQOArQD2KY5y400LatGpejnkyR_SY9eLh44yqGSg_OrieMUPzKSPwZOd1A"
    static let offPayload = "{\"b\":{\"classes\":[],\"from\":1800000000,\"off\":true,\"to\":1800000000},\"f\":\"3c157621a97cf055f5804a9826c6d1e1\",\"k\":\"timetable\",\"n\":\"vector-10\",\"t\":1800000060,\"v\":1}"

    private func lockCheck(_ payload: String, sig: String, box: String, eph: String, ephPub: String, nonce: String) throws {
        let p = Data(payload.utf8)
        let s = try XCTUnwrap(B64URL.decode(sig))
        XCTAssertTrue(sam.signing.publicKey.isValidSignature(s, for: FriendBox.signed(p, to: lou.account)))
        let e = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex(eph))
        XCTAssertEqual(e.publicKey.rawRepresentation.hexString, ephPub)
        let locked = try FriendBox.lock(s + p, to: lou.card, eph: e, nonce: try ChaChaPoly.Nonce(data: hex(nonce)))
        XCTAssertEqual(B64URL.encode(locked), box)
    }

    func test_timetableBox() throws {
        try lockCheck(Self.timetablePayload, sig: Self.timetableSig, box: Self.timetableBox,
                      eph: "e0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfeff",
                      ephPub: "736845d54e87de09d6bb114aa7042c50a4a015bd9901d1a0026f5956533a1519", nonce: "0a0b0c0d0e0f101112131415")
        let o = try FriendBox.open(try XCTUnwrap(B64URL.decode(Self.timetableBox)), me: lou, from: sam.account, known: { _ in self.sam.card })
        guard case .timetable(let t) = o.message else { return XCTFail("not a timetable") }
        XCTAssertEqual(t.from, Date(timeIntervalSince1970: 1_799_967_600))          // Friday 15 January 2027, 00:00 in Amsterdam
        XCTAssertEqual(t.to, Date(timeIntervalSince1970: 1_801_177_200))            // 14 days on
        XCTAssertEqual(t.src, "calendar")
        XCTAssertEqual(t.classes.count, 2)
        XCTAssertEqual(t.classes[0], TimetableClass(start: Date(timeIntervalSince1970: 1_800_004_500), end: Date(timeIntervalSince1970: 1_800_010_800),
                                                    title: "Design", room: "C1.02"))
        XCTAssertEqual(CompareWords.lesson(t.classes[0]), "10:15–12:00 Design · C1.02")
        XCTAssertEqual(CompareWords.lesson(t.classes[1]), "13:30–15:45 Maths")
        XCTAssertEqual(TimetableShare.valid(t), t)
        XCTAssertTrue(t.covers("2027-01-15"))
        XCTAssertTrue(t.covers("2027-01-28"))
        XCTAssertFalse(t.covers("2027-01-29"))
        XCTAssertFalse(t.covers("2027-01-14"))
    }

    func test_areaBox() throws {
        try lockCheck(Self.areaPayload, sig: Self.areaSig, box: Self.areaBox,
                      eph: "1112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f30",
                      ephPub: "4d27bcee3135c4944b28d27dd809b07be10c35160d20131caa7e85575498d07c", nonce: "161718191a1b1c1d1e1f2021")
        let o = try FriendBox.open(try XCTUnwrap(B64URL.decode(Self.areaBox)), me: lou, from: sam.account, known: { _ in self.sam.card })
        guard case .area(let a) = o.message else { return XCTFail("not an area") }
        XCTAssertEqual(a.school, TripCard.Spot(name: "BUas", lat: 51.5866, lon: 4.7745))
        XCTAssertEqual(a.station, TimetableArea.Station(name: "Eindhoven Centraal", code: "EHV", lat: 51.44306, lon: 5.47917))
        XCTAssertEqual(a.stops, [TripCard.Spot(name: "Eindhoven, Station", id: "vector-stop-1", lat: 51.4401, lon: 5.4789)])
        XCTAssertEqual(a.earlyMinutes, 10)
        XCTAssertEqual(a.start, a.stops.first)
        XCTAssertEqual(TimetableArea.valid(a), a)
    }

    func test_takenBackReads() throws {
        let (h, m) = try FriendBox.parse(Data(Self.offPayload.utf8))
        XCTAssertEqual(h.k, "timetable")
        guard case .timetable(let t) = m else { return XCTFail("not a timetable") }
        XCTAssertTrue(t.isOff)
        XCTAssertEqual(TimetableShare.valid(t)?.isOff, true)
        XCTAssertEqual(TimetableShare.takenBack(at: Date(timeIntervalSince1970: 1_800_000_000)), t)
    }

    func test_newKindsAreKnown() {
        XCTAssertTrue(FriendMessage.known.contains("timetable"))
        XCTAssertTrue(FriendMessage.known.contains("area"))
        XCTAssertGreaterThanOrEqual(FriendMessage.kindsVersion, 4)
    }
}

final class FriendTimetableTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)         // Friday 15 January 2027, 09:00 in Amsterdam
    let midnight = 1_799_967_600.0                              // that day, 00:00
    private let ams = TimeZone(identifier: "Europe/Amsterdam")!

    /// Day `d` after Friday 15 January 2027 at h:m in Amsterdam (no change of summer time in these weeks).
    private func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Date { Date(timeIntervalSince1970: midnight + Double(d * 86400 + h * 3600 + m * 60)) }

    // MARK: the share as kept

    func test_validCleansAndDrops() {
        let w = TimetableDays.window(now: t0)
        XCTAssertEqual(w.from, at(0, 0))
        XCTAssertEqual(w.to, at(14, 0))
        let raw = TimetableShare(from: w.from, to: w.to, classes: [
            TimetableClass(start: at(3, 13), end: at(3, 15), title: "  Maths \n lab ", room: ""),
            TimetableClass(start: at(3, 9), end: at(3, 8), title: "Backwards"),                 // ends before it starts: no end
            TimetableClass(start: at(4, 8), end: at(4, 23), title: "All day"),                 // over 12 hours: no end
            TimetableClass(start: at(20, 9), end: at(20, 10)),                                 // outside the window
            TimetableClass(start: at(-1, 9), end: at(-1, 10)),
        ])
        let v = TimetableShare.valid(raw)!
        XCTAssertEqual(v.classes.map(\.start), [at(3, 9), at(3, 13), at(4, 8)])
        XCTAssertNil(v.classes[0].end)
        XCTAssertEqual(v.classes[1].title, "Maths lab")
        XCTAssertNil(v.classes[1].room)
        XCTAssertNil(v.classes[2].end)
        // a window that doesn't make sense isn't a timetable
        XCTAssertNil(TimetableShare.valid(TimetableShare(from: w.to, to: w.from, classes: [])))
        XCTAssertNil(TimetableShare.valid(TimetableShare(from: w.from, to: at(30, 0), classes: [])))
        // at most 300
        let many = (0..<400).map { TimetableClass(start: w.from.addingTimeInterval(Double($0) * 60)) }
        XCTAssertEqual(TimetableShare.valid(TimetableShare(from: w.from, to: w.to, classes: many))?.classes.count, 300)
    }

    func test_areaNeedsASchool() {
        let s = TripCard.Spot(name: "Stop", id: "x", lat: 51.6, lon: 5.5)
        XCTAssertNil(TimetableArea.valid(TimetableArea(stops: [s], school: TripCard.Spot(name: "BUas"))))
        let a = TimetableArea(stops: [s, s, s, s, s, TripCard.Spot(name: "Nowhere")], school: TripCard.Spot(name: " BUas ", lat: 51.58, lon: 4.77), early: 90)
        let v = TimetableArea.valid(a)!
        XCTAssertEqual(v.stops.count, 4)
        XCTAssertEqual(v.school.name, "BUas")
        XCTAssertEqual(v.early, 60)
        // no stops: the station is where it starts
        let st = TimetableArea(stops: [], station: .init(name: "Veghel", lat: 51.6, lon: 5.5), school: TripCard.Spot(name: "S", lat: 51, lon: 5))
        XCTAssertEqual(st.start?.name, "Veghel")
        XCTAssertEqual(st.earlyMinutes, 10)
    }

    // MARK: your week, with end times (0.28)

    func test_weekWithEndTimesAndTitles() {
        var w = ManualWeek(days: [.init(weekday: 2, minutes: 510), .init(weekday: 4, minutes: 615)])
        w.setEnd(weekday: 2, minutes: 15 * 60 + 30)
        w.setTitle(weekday: 2, "Design ")
        w.setEnd(weekday: 4, minutes: 600)                       // before it starts: none
        w.setEnd(weekday: 3, minutes: 900)                       // no school that day: ignored
        XCTAssertEqual(w.end(weekday: 2), 930)
        XCTAssertNil(w.end(weekday: 4))
        XCTAssertNil(w.end(weekday: 3))
        XCTAssertEqual(w.title(weekday: 2), "Design ", "kept as typed")
        // moving the start keeps the end and title
        w.set(weekday: 2, minutes: 540)
        XCTAssertEqual(w.end(weekday: 2), 930)
        XCTAssertEqual(w.title(weekday: 2), "Design ")
        XCTAssertEqual(SetupLogic.weekWords(w), "Mon 09:00–15:30 · Wed 10:15")
        // the classes it shares: one per school day, today all of it, trimmed title
        let c = w.classes(from: t0, days: 14, tz: ams)
        XCTAssertEqual(c.map(\.start), [at(3, 9), at(5, 10, 15), at(10, 9), at(12, 10, 15)])
        XCTAssertEqual(c[0].end, at(3, 15, 30))
        XCTAssertEqual(c[0].title, "Design")
        XCTAssertNil(c[1].end)
        XCTAssertNil(c[1].title)
    }

    func test_aWeekSavedBefore028StillReads() throws {
        let old = Data("{\"days\":[{\"weekday\":2,\"minutes\":510},{\"weekday\":3,\"minutes\":600}]}".utf8)
        let w = try JSONDecoder().decode(ManualWeek.self, from: old)
        XCTAssertEqual(w.days.map(\.weekday), [2, 3])
        XCTAssertNil(w.end(weekday: 2))
        var n = w
        n.setEnd(weekday: 2, minutes: 900)
        n.setTitle(weekday: 2, "Lab")
        let back = try JSONDecoder().decode(ManualWeek.self, from: JSONEncoder().encode(n))
        XCTAssertEqual(back, n)
        XCTAssertEqual(back.end(weekday: 2), 900)
        // the same week without ends writes what 0.27 wrote (no end, no title keys)
        let plain = String(decoding: try JSONEncoder().encode(ManualWeek(days: [.init(weekday: 2, minutes: 510)])), as: UTF8.self)
        XCTAssertFalse(plain.contains("end"))
        XCTAssertFalse(plain.contains("title"))
        XCTAssertEqual(SetupLogic.weekWords(.workdays), "Mon–Fri 08:30")
        var all = ManualWeek.workdays
        for d in 2...6 { all.setEnd(weekday: d, minutes: 15 * 60) }
        XCTAssertEqual(SetupLogic.weekWords(all), "Mon–Fri 08:30–15:00")
    }

    /// "Test the setup as a new user" keeps your week (end times and titles too): it lives in the profile.
    func test_setupBackupKeepsTheWeek() throws {
        XCTAssertTrue(SetupBackup.keys.contains(ProfileLogic.storageKey))
        var w = ManualWeek.workdays
        w.setEnd(weekday: 2, minutes: 900)
        w.setTitle(weekday: 2, "Studio")
        var p = ProfileLogic.fresh
        p.schedule = .manual(w)
        let data = try XCTUnwrap(ProfileLogic.encode(p))
        let b = SetupBackup.take(read: { $0 == ProfileLogic.storageKey ? data : nil }, now: t0)
        var back: Data?
        b.restore(write: { k, v in if k == ProfileLogic.storageKey { back = v as? Data } })
        XCTAssertEqual(ProfileLogic.decode(back)?.schedule, .manual(w))
    }

    // MARK: when it goes

    func test_dueWhenChangedAtMostEveryThreeHours() {
        let everyone = ["lou", "sam"]
        XCTAssertEqual(TimetableShareRules.due(last: nil, hash: "a", recipients: everyone, at: t0), everyone)
        XCTAssertEqual(TimetableShareRules.due(last: nil, hash: "a", recipients: [], at: t0), [])
        let last = TimetableShareRules.Sent(hash: "a", at: t0, to: everyone)
        // the same: nothing; changed: not before 3 hours
        XCTAssertEqual(TimetableShareRules.due(last: last, hash: "a", recipients: everyone, at: t0 + 3600), [])
        XCTAssertEqual(TimetableShareRules.due(last: last, hash: "b", recipients: everyone, at: t0 + 3600), [])
        XCTAssertEqual(TimetableShareRules.due(last: last, hash: "b", recipients: everyone, at: t0 + 3 * 3600), everyone)
        // once a day anyway
        XCTAssertEqual(TimetableShareRules.due(last: last, hash: "a", recipients: everyone, at: t0 + 20 * 3600), everyone)
        // someone new: at once, only them
        XCTAssertEqual(TimetableShareRules.due(last: last, hash: "b", recipients: everyone + ["kim"], at: t0 + 60), ["kim"])
        // the clock stepped back: again
        XCTAssertEqual(TimetableShareRules.due(last: last, hash: "a", recipients: everyone, at: t0 - 60), everyone)
        // the area: after a week whatever
        XCTAssertEqual(TimetableShareRules.due(last: last, hash: "a", recipients: everyone, at: t0 + 2 * 86400, every: TimetableShareRules.areaRefresh), [])
        XCTAssertEqual(TimetableShareRules.due(last: last, hash: "a", recipients: everyone, at: t0 + 7 * 86400, every: TimetableShareRules.areaRefresh), everyone)
    }

    func test_afterAndTakeBack() {
        let last = TimetableShareRules.Sent(hash: "a", at: t0, to: ["lou", "sam"])
        // only someone new got it: the time and fingerprint stay
        let some = TimetableShareRules.after(last, hash: "b", sent: ["kim"], everyone: ["kim", "lou", "sam"], at: t0 + 60)
        XCTAssertEqual(some, TimetableShareRules.Sent(hash: "a", at: t0, to: ["kim", "lou", "sam"]))
        // everyone: the new one
        let all = TimetableShareRules.after(last, hash: "b", sent: ["lou", "sam"], everyone: ["sam", "lou"], at: t0 + 4 * 3600)
        XCTAssertEqual(all, TimetableShareRules.Sent(hash: "b", at: t0 + 4 * 3600, to: ["lou", "sam"]))
        // a switch went off for Sam: taken back from Sam
        XCTAssertEqual(TimetableShareRules.takeBack(last: last, recipients: ["lou"]), ["sam"])
        XCTAssertEqual(TimetableShareRules.takeBack(last: nil, recipients: ["lou"]), [])
        XCTAssertEqual(TimetableShareRules.afterTakeBack(last, gone: ["sam"])?.to, ["lou"])
    }

    func test_recipients() {
        let r = TimetableShareRules.recipients(friends: ["lou", "sam", "me"], off: ["sam"], groupMembers: ["kim", "sam"], me: "me", on: true)
        XCTAssertEqual(r, ["kim", "lou"])
        XCTAssertEqual(TimetableShareRules.recipients(friends: ["lou"], off: [], groupMembers: ["kim"], me: "me", on: false), [])
    }

    func test_fingerprintIsStable() {
        let a = TimetableShareRules.fingerprint(Data("{\"a\":1}".utf8))
        XCTAssertEqual(a, TimetableShareRules.fingerprint(Data("{\"a\":1}".utf8)))
        XCTAssertNotEqual(a, TimetableShareRules.fingerprint(Data("{\"a\":2}".utf8)))
        XCTAssertEqual(TimetableShareRules.fingerprint(Data()), "cbf29ce484222325")
    }

    // MARK: what comes in

    let sam = FriendIdentity.random(), lou = FriendIdentity.random(), kim = FriendIdentity.random()

    private func box(_ id: Int, _ m: FriendMessage, from: FriendIdentity, at: Date) throws -> RelayBox {
        let d = try FriendBox.seal(m, from: from, to: lou.card, at: at, id: "n\(id)")
        return RelayBox(id: id, from: from.account, slot: "tt", at: Int(at.timeIntervalSince1970), exp: 0, data: B64URL.encode(d))
    }

    private var louBook: FriendBook {
        var b = FriendBook(myName: "Lou")
        b.friends = [Friend(card: sam.card, name: "Sam", since: t0)]
        return b
    }

    private func share(_ title: String) -> TimetableShare {
        let w = TimetableDays.window(now: t0)
        return TimetableShare(from: w.from, to: w.to, classes: [TimetableClass(start: at(3, 9), end: at(3, 11), title: title)], src: "week")
    }

    func test_timetablesFromFriendsAndGroupsOnly() throws {
        let area = TimetableArea(stops: [], school: TripCard.Spot(name: "BUas", lat: 51.58, lon: 4.77))
        let boxes = [
            try box(1, .timetable(share("old")), from: sam, at: t0),
            try box(2, .timetable(share("new")), from: sam, at: t0 + 60),
            try box(3, .area(area), from: sam, at: t0),
            try box(4, .timetable(share("stranger")), from: kim, at: t0),
        ]
        let r = FriendInbox.process(boxes, book: louBook, me: lou, now: t0)
        XCTAssertEqual(r.timetables[sam.account]?.share.classes.first?.title, "new")
        XCTAssertEqual(r.areas[sam.account]?.area, area)
        XCTAssertNil(r.timetables[kim.account])
        XCTAssertEqual(r.ack.sorted(), [1, 2, 3, 4])
        // Kim in a group with Lou: taken
        var g = GroupBook()
        let roster = GroupRoster(name: "Crew", admin: sam.account, rev: 1, members: [
            GroupMember(card: sam.card, name: "Sam"), GroupMember(card: lou.card, name: "Lou"), GroupMember(card: kim.card, name: "Kim"),
        ])
        _ = g.receive(roster, id: "0123456789abcdef01234567", from: sam.account, me: lou.account, isFriend: { _ in true }, senderName: "Sam", now: t0)
        let r2 = FriendInbox.process([try box(5, .timetable(share("kim")), from: kim, at: t0)], book: louBook, groups: g, me: lou, now: t0)
        XCTAssertEqual(r2.timetables[kim.account]?.share.classes.first?.title, "kim")
    }

    func test_takenBack() throws {
        let boxes = [
            try box(1, .timetable(share("x")), from: sam, at: t0),
            try box(2, .timetable(.takenBack(at: t0)), from: sam, at: t0 + 60),
        ]
        let r = FriendInbox.process(boxes, book: louBook, me: lou, now: t0)
        XCTAssertNil(r.timetables[sam.account])
        XCTAssertEqual(r.timetablesOff, [sam.account])
    }
}
