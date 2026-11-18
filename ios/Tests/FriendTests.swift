import XCTest
import CryptoKit

final class FriendWordsTests: XCTestCase {
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

    func test_listIsBIP39English() {
        XCTAssertEqual(FriendWords.list.count, 2048)
        XCTAssertEqual(FriendWords.list.first, "abandon")
        XCTAssertEqual(FriendWords.list.last, "zoo")
        XCTAssertEqual(Set(FriendWords.list.map { String($0.prefix(4)) }).count, 2048)
    }

    func test_bip39Vectors() {
        XCTAssertEqual(FriendWords.encode(Data(count: 16)).joined(separator: " "),
                       "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about")
        XCTAssertEqual(FriendWords.encode(hex("7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f")).joined(separator: " "),
                       "legal winner thank year wave sausage worth useful legal winner thank yellow")
        XCTAssertEqual(FriendWords.encode(hex("ffffffffffffffffffffffffffffffff")).joined(separator: " "),
                       "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong")
        XCTAssertEqual(FriendWords.encode(hex("000102030405060708090a0b0c0d0e0f")).joined(separator: " "),
                       "abandon amount liar amount expire adjust cage candy arch gather drum buyer")
    }

    func test_roundTripAndChecksum() {
        for _ in 0..<20 {
            let seed = FriendIdentity.random().seed
            XCTAssertEqual(FriendWords.decode(FriendWords.encode(seed)), seed)
        }
        var w = FriendWords.encode(hex("000102030405060708090a0b0c0d0e0f"))
        w[0] = "ability"
        XCTAssertNil(FriendWords.decode(w), "a wrong word fails the checksum")
        XCTAssertNil(FriendWords.decode(Array(w.prefix(11))))
        XCTAssertNil(FriendWords.decode(["notaword"] + Array(w.dropFirst())))
    }

    func test_typedLoosely() {
        let text = "1. Abandon 2. amou, liar  amount\nexpire-adjust cage candy arch gath drum buyer"
        let words = FriendWords.words(in: text)
        XCTAssertEqual(words.count, 12)
        XCTAssertEqual(FriendWords.decode(words), hex("000102030405060708090a0b0c0d0e0f"))
        XCTAssertEqual(FriendWords.completions("aba"), ["abandon"])
    }
}

final class FriendKeysTests: XCTestCase {
    /// Worked out with Node's crypto (and the relay's own accountIdFor), so the phone and the relay agree.
    func test_knownSeedGivesKnownKeysAndAccount() {
        let me = FriendIdentity(seed: Data((0..<16).map { UInt8($0) }))!
        XCTAssertEqual(me.signing.publicKey.rawRepresentation.hexString, "3e299fe695cc0d9c74ddf561942c1a7d8f62ea29783f5caa3414644025b420c2")
        XCTAssertEqual(me.agreement.publicKey.rawRepresentation.hexString, "e0191e9cfb5e4b2ccc859180133c42543b4f6ec6007e4b5c50608563f7fac134")
        XCTAssertEqual(me.vaultKey.withUnsafeBytes { Data($0) }.hexString, "66cd8d6137776253f8c7b0e625a6fcfb23d7ce0498f85e22f5a2fd51a229e819")
        XCTAssertEqual(me.account, "3c157621a97cf055f5804a9826c6d1e1")
        XCTAssertTrue(FriendIdentity.isAccount(me.account))
        XCTAssertEqual(FriendIdentity(words: me.words)?.account, me.account)
    }

    func test_canonicalRequest() {
        let s = RelaySign.canonical(method: "POST", path: "/f/v1/inbox", account: "ab", device: "cd", time: 1_800_000_000,
                                    nonce: "n0nce", body: Data("{}".utf8))
        XCTAssertEqual(s, "HW1\nPOST\n/f/v1/inbox\nab\ncd\n1800000000\nn0nce\n44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a")
    }

    func test_headersVerify() throws {
        let me = FriendIdentity.random()
        let body = Data(#"{"after":0}"#.utf8)
        let h = try RelaySign.headers(me, device: "dev", path: "/f/v1/inbox", body: body, time: 42, nonce: "abcdefghijklmnop")
        XCTAssertEqual(h["X-HW-Account"], me.account)
        let text = RelaySign.canonical(method: "POST", path: "/f/v1/inbox", account: me.account, device: "dev", time: 42,
                                       nonce: "abcdefghijklmnop", body: body)
        let sig = try XCTUnwrap(B64URL.decode(h["X-HW-Signature"] ?? ""))
        XCTAssertEqual(sig.count, 64)
        XCTAssertTrue(me.signing.publicKey.isValidSignature(sig, for: Data(text.utf8)))
        XCTAssertGreaterThanOrEqual(RelaySign.nonce().count, 16)
        XCTAssertTrue(FriendIdentity.isAccount(RelaySign.newDevice()))
    }

    func test_base64url() {
        let d = Data([0xfb, 0xff, 0xfe, 0x00])
        XCTAssertEqual(B64URL.encode(d), "-__-AA")
        XCTAssertEqual(B64URL.decode("-__-AA"), d)
        XCTAssertNil(B64URL.decode("a b"))
    }

    func test_cardPacksBothKeys() throws {
        let c = FriendIdentity.random().card
        XCTAssertEqual(FriendCard(packed: c.packed), c)
        XCTAssertNil(FriendCard(packed: "short"))
        let json = try JSONEncoder().encode(c)
        XCTAssertEqual(try JSONDecoder().decode(FriendCard.self, from: json), c)
    }
}

final class FriendBoxTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let sam = FriendIdentity.random()
    let lou = FriendIdentity.random()

    func test_requestOpensForItsRecipientOnly() throws {
        let m = FriendMessage.request(FriendIntro(card: sam.card, name: "Sam", note: nil))
        let box = try FriendBox.seal(m, from: sam, to: lou.card, at: t0, id: "x1")
        XCTAssertEqual(box.first, 1)
        let o = try FriendBox.open(box, me: lou, from: sam.account, known: { _ in nil })
        XCTAssertEqual(o.message, m)
        XCTAssertEqual(o.sender, sam.card)
        XCTAssertEqual(o.header.f, sam.account)
        XCTAssertEqual(o.header.t, 1_800_000_000)
        XCTAssertEqual(o.header.n, "x1")
        // someone else can't open it
        let eve = FriendIdentity.random()
        XCTAssertThrowsError(try FriendBox.open(box, me: eve, from: sam.account, known: { _ in nil })) {
            XCTAssertEqual($0 as? FriendBoxError, .cantOpen)
        }
    }

    func test_relayCantChangeTheSender() throws {
        let box = try FriendBox.seal(.request(FriendIntro(card: sam.card, name: "Sam")), from: sam, to: lou.card)
        let eve = FriendIdentity.random()
        XCTAssertThrowsError(try FriendBox.open(box, me: lou, from: eve.account, known: { _ in nil })) {
            XCTAssertEqual($0 as? FriendBoxError, .wrongSender)
        }
    }

    func test_aRequestWithSomeoneElsesCardIsRefused() throws {
        // Eve sends a request claiming Sam's card: the signature is Eve's, so it can't check out as Sam's
        let eve = FriendIdentity.random()
        let box = try FriendBox.seal(.request(FriendIntro(card: sam.card, name: "Sam")), from: eve, to: lou.card)
        XCTAssertThrowsError(try FriendBox.open(box, me: lou, from: eve.account, known: { _ in nil }))
    }

    func test_tamperedBoxFails() throws {
        var box = try FriendBox.seal(.unfriend, from: sam, to: lou.card)
        box[box.count - 20] ^= 0x01
        XCTAssertThrowsError(try FriendBox.open(box, me: lou, from: sam.account, known: { _ in self.sam.card })) {
            XCTAssertEqual($0 as? FriendBoxError, .cantOpen)
        }
    }

    func test_otherKindsNeedAKnownSender() throws {
        let box = try FriendBox.seal(.profile(FriendProfile(name: "Sammy")), from: sam, to: lou.card)
        XCTAssertThrowsError(try FriendBox.open(box, me: lou, from: sam.account, known: { _ in nil })) {
            XCTAssertEqual($0 as? FriendBoxError, .unknownSender)
        }
        let o = try FriendBox.open(box, me: lou, from: sam.account, known: { $0 == self.sam.account ? self.sam.card : nil })
        XCTAssertEqual(o.message, .profile(FriendProfile(name: "Sammy")))
        // the wrong key for a known sender: the signature fails
        XCTAssertThrowsError(try FriendBox.open(box, me: lou, from: sam.account, known: { _ in self.lou.card })) {
            XCTAssertEqual($0 as? FriendBoxError, .badSignature)
        }
    }

    func test_unknownKindsComeBackUnknown() throws {
        let box = try FriendBox.seal(.unknown("travel"), from: sam, to: lou.card)
        let o = try FriendBox.open(box, me: lou, from: sam.account, known: { _ in self.sam.card })
        XCTAssertEqual(o.message, .unknown("travel"))
        XCTAssertFalse(FriendMessage.known.contains("travel"))
    }

    func test_payloadIsVersionedJSON() throws {
        let p = try FriendBox.payload(.profile(FriendProfile(name: "Sam")), from: "abc", at: t0, id: "n1")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: p) as? [String: Any])
        XCTAssertEqual(obj["v"] as? Int, 1)
        XCTAssertEqual(obj["k"] as? String, "profile")
        XCTAssertEqual(obj["f"] as? String, "abc")
        XCTAssertEqual((obj["b"] as? [String: Any])?["name"] as? String, "Sam")
        let newer = Data(#"{"v":2,"k":"profile","f":"abc","t":1,"n":"x","b":{}}"#.utf8)
        XCTAssertThrowsError(try FriendBox.parse(newer)) { XCTAssertEqual($0 as? FriendBoxError, .newerVersion) }
    }

    func test_vaultRoundTrip() throws {
        let plain = Data("the friend list".utf8)
        let v = try FriendVault.seal(plain, me: sam)
        XCTAssertEqual(try FriendVault.open(v, me: sam), plain)
        XCTAssertThrowsError(try FriendVault.open(v, me: lou))
        // the same seed (a restored phone) opens it
        let again = FriendIdentity(seed: sam.seed)!
        XCTAssertEqual(try FriendVault.open(v, me: again), plain)
    }
}

final class FriendBookTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let sam = FriendIdentity.random()
    let lou = FriendIdentity.random()

    func test_requestAcceptBothSides() {
        var s = FriendBook(myName: "Sam"), l = FriendBook(myName: "Lou")
        let (added, e1) = s.add(lou.card, name: "Lou", myCard: sam.card, now: t0)
        XCTAssertEqual(added, .sent)
        XCTAssertEqual(s.outgoing.map(\.id), [lou.account])
        XCTAssertEqual(e1, [.send(lou.card, .request(FriendIntro(card: sam.card, name: "Sam")))])
        let (e2, news) = l.receive(.request(FriendIntro(card: sam.card, name: "Sam")), from: sam.card, myCard: lou.card, now: t0)
        XCTAssertEqual(e2, [])
        XCTAssertEqual(news, .request("Sam"))
        XCTAssertEqual(l.incoming.map(\.name), ["Sam"])
        let e3 = l.accept(sam.account, myCard: lou.card, now: t0)
        XCTAssertEqual(e3, [.send(sam.card, .accept(FriendIntro(card: lou.card, name: "Lou")))])
        XCTAssertEqual(l.friends.map(\.id), [sam.account])
        XCTAssertTrue(l.incoming.isEmpty)
        let (e4, news2) = s.receive(.accept(FriendIntro(card: lou.card, name: "Lou")), from: lou.card, myCard: sam.card, now: t0)
        XCTAssertEqual(e4, [])
        XCTAssertEqual(news2, .accepted("Lou"))
        XCTAssertEqual(s.friends.map(\.name), ["Lou"])
        XCTAssertTrue(s.outgoing.isEmpty)
    }

    func test_bothAskedMeansFriends() {
        var s = FriendBook(myName: "Sam")
        _ = s.add(lou.card, name: "Lou", myCard: sam.card, now: t0)
        let (e, news) = s.receive(.request(FriendIntro(card: lou.card, name: "Lou")), from: lou.card, myCard: sam.card, now: t0)
        XCTAssertEqual(news, .accepted("Lou"))
        XCTAssertEqual(e, [.send(lou.card, .accept(FriendIntro(card: sam.card, name: "Sam")))])
        XCTAssertTrue(s.isFriend(lou.account))
    }

    func test_scanningSomeoneWhoAskedAccepts() {
        var s = FriendBook(myName: "Sam")
        _ = s.receive(.request(FriendIntro(card: lou.card, name: "Lou")), from: lou.card, myCard: sam.card, now: t0)
        let (r, e) = s.add(lou.card, name: "Lou", myCard: sam.card, now: t0)
        XCTAssertEqual(r, .accepted)
        XCTAssertEqual(e.count, 1)
        XCTAssertTrue(s.isFriend(lou.account))
        XCTAssertEqual(s.add(lou.card, name: "Lou", myCard: sam.card, now: t0).0, .alreadyFriends)
        XCTAssertEqual(s.add(sam.card, name: "Me", myCard: sam.card, now: t0).0, .yourself)
    }

    func test_anAcceptNobodyAskedForIsIgnored() {
        var s = FriendBook(myName: "Sam")
        let (e, news) = s.receive(.accept(FriendIntro(card: lou.card, name: "Lou")), from: lou.card, myCard: sam.card, now: t0)
        XCTAssertEqual(e, [])
        XCTAssertNil(news)
        XCTAssertTrue(s.friends.isEmpty)
    }

    func test_removeDropsThenTells() {
        var s = FriendBook(myName: "Sam")
        _ = s.receive(.request(FriendIntro(card: lou.card, name: "Lou")), from: lou.card, myCard: sam.card, now: t0)
        _ = s.accept(lou.account, myCard: sam.card, now: t0)
        let e = s.remove(lou.account)
        XCTAssertEqual(e, [.drop(lou.account), .send(lou.card, .unfriend)])
        XCTAssertTrue(s.friends.isEmpty)
        // and on the other side
        var l = FriendBook(myName: "Lou")
        _ = l.add(sam.card, name: "Sam", myCard: lou.card, now: t0)
        _ = l.receive(.accept(FriendIntro(card: sam.card, name: "Sam")), from: sam.card, myCard: lou.card, now: t0)
        XCTAssertTrue(l.isFriend(sam.account))
        _ = l.receive(.unfriend, from: sam.card, myCard: lou.card, now: t0)
        XCTAssertFalse(l.isFriend(sam.account))
    }

    func test_declineIsQuietAndCanBlock() {
        var s = FriendBook(myName: "Sam")
        _ = s.receive(.request(FriendIntro(card: lou.card, name: "Lou")), from: lou.card, myCard: sam.card, now: t0)
        XCTAssertEqual(s.decline(lou.account, block: false), [.drop(lou.account)])
        _ = s.receive(.request(FriendIntro(card: lou.card, name: "Lou")), from: lou.card, myCard: sam.card, now: t0)
        XCTAssertEqual(s.decline(lou.account, block: true), [.block(lou.account)])
        XCTAssertTrue(s.incoming.isEmpty)
    }

    func test_cancelAndRename() {
        var s = FriendBook(myName: "Sam")
        _ = s.add(lou.card, name: "Lou", myCard: sam.card, now: t0)
        XCTAssertEqual(s.cancel(lou.account), [.drop(lou.account), .send(lou.card, .unfriend)])
        XCTAssertTrue(s.outgoing.isEmpty)
        _ = s.receive(.request(FriendIntro(card: lou.card, name: "Lou")), from: lou.card, myCard: sam.card, now: t0)
        _ = s.accept(lou.account, myCard: sam.card, now: t0)
        XCTAssertEqual(s.rename("  Sam   J  "), [.send(lou.card, .profile(FriendProfile(name: "Sam J")))])
        XCTAssertEqual(s.myName, "Sam J")
        XCTAssertEqual(s.rename("Sam J"), [])
    }

    func test_bookSurvivesJSON() throws {
        var s = FriendBook(myName: "Sam")
        _ = s.add(lou.card, name: "Lou", myCard: sam.card, now: t0)
        let d = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(FriendBook.self, from: d), s)
    }

    func test_names() {
        XCTAssertEqual(FriendNames.clean(" Sam\n\tJansen "), "Sam Jansen")
        XCTAssertEqual(FriendNames.clean(String(repeating: "a", count: 60)).count, 40)
        XCTAssertEqual(FriendNames.initials("Sam Jansen"), "SJ")
        XCTAssertEqual(FriendNames.initials(""), "?")
    }
}

final class FriendLinkTests: XCTestCase {
    let sam = FriendIdentity.random()

    func test_bothFormsParse() throws {
        let app = FriendLink.app(sam.card, name: "Sam & Co+1 é")
        XCTAssertEqual(app.scheme, "haltewekker")
        XCTAssertEqual(app.host, "friend")
        let a = try XCTUnwrap(FriendLink.parse(app.absoluteString))
        XCTAssertEqual(a.card, sam.card)
        XCTAssertEqual(a.name, "Sam & Co+1 é")
        let web = FriendLink.share(sam.card, name: "Sam")
        XCTAssertTrue(web.absoluteString.hasPrefix("https://haltewekker-relay.tsfaw1.workers.dev/add#v=1&k="))
        let w = try XCTUnwrap(FriendLink.parse(web.absoluteString))
        XCTAssertEqual(w.card, sam.card)
        XCTAssertEqual(w.name, "Sam")
    }

    func test_notAFriendCode() {
        XCTAssertNil(FriendLink.parse("https://example.com/add#v=1&k=abc"))
        XCTAssertNil(FriendLink.parse("haltewekker://spotify?code=1"))
        XCTAssertNil(FriendLink.parse("haltewekker://friend?v=1&k=tooShort"))
        XCTAssertNil(FriendLink.parse("haltewekker://friend?v=2&k=\(sam.card.packed)"))
        XCTAssertNil(FriendLink.parse("hello"))
    }
}

final class FriendInboxTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let sam = FriendIdentity.random()
    let lou = FriendIdentity.random()

    private func relayBox(_ id: Int, _ m: FriendMessage, from: FriendIdentity, to: FriendCard) throws -> RelayBox {
        let d = try FriendBox.seal(m, from: from, to: to, at: t0)
        return RelayBox(id: id, from: from.account, slot: nil, at: 0, exp: 0, data: B64URL.encode(d))
    }

    func test_aBatchIsReadInOrder() throws {
        let book = FriendBook(myName: "Lou")
        let boxes = [
            try relayBox(1, .request(FriendIntro(card: sam.card, name: "Sam")), from: sam, to: lou.card),
            try relayBox(2, .profile(FriendProfile(name: "Sammy")), from: sam, to: lou.card),   // not a friend yet: dropped
            try relayBox(3, .unknown("travel"), from: sam, to: lou.card),                       // known (asking), a newer kind: kept
            RelayBox(id: 4, from: sam.account, slot: nil, at: 0, exp: 0, data: "!!"),           // garbage: dropped
        ]
        let r = FriendInbox.process(boxes, book: book, me: lou, now: t0)
        XCTAssertEqual(r.book.incoming.map(\.name), ["Sam"])
        XCTAssertEqual(r.news, [.request("Sam")])
        XCTAssertEqual(r.ack, [1, 2, 4])
        XCTAssertEqual(r.kept, [3])
    }

    func test_acceptedThenProfile() throws {
        var book = FriendBook(myName: "Lou")
        _ = book.add(sam.card, name: "Sam", myCard: lou.card, now: t0)
        let boxes = [
            try relayBox(7, .accept(FriendIntro(card: sam.card, name: "Sam")), from: sam, to: lou.card),
            try relayBox(8, .profile(FriendProfile(name: "Sammy")), from: sam, to: lou.card),
        ]
        let r = FriendInbox.process(boxes, book: book, me: lou, now: t0)
        XCTAssertEqual(r.book.friends.map(\.name), ["Sammy"])
        XCTAssertEqual(r.news, [.accepted("Sam")])
        XCTAssertEqual(r.ack, [7, 8])
        XCTAssertEqual(FriendInbox.banner(.accepted("Sam")).title, "You and Sam are friends")
    }

    func test_relayAnswersDecode() throws {
        let j = Data(#"{"boxes":[{"id":3,"from":"ab","slot":null,"at":1,"exp":2,"data":"AQ"}],"cursor":3,"more":false}"#.utf8)
        let i = try JSONDecoder().decode(RelayInbox.self, from: j)
        XCTAssertEqual(i.boxes.first?.id, 3)
        XCTAssertNil(i.boxes.first?.slot)
        let s = try JSONDecoder().decode(RelaySent.self, from: Data(#"{"results":[{"to":"ab","ok":false,"error":"unknown_account"}]}"#.utf8))
        XCTAssertEqual(s.results.first?.error, "unknown_account")
    }
}
