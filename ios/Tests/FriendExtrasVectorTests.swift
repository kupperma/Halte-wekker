import XCTest
import CryptoKit

/// Friends 0.29 (the extras): the wait, campus, buddy and delay boxes and a wait's answer, byte for byte
/// (docs/superpowers/specs/2026-11-18-friends-design.md, "As built (0.29)"), made with Node's crypto from the spec alone.
final class FriendExtrasVectorTests: XCTestCase {
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
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ s: TimeInterval) -> Date { Date(timeIntervalSince1970: s) }
    private let ehv = TripCard.Spot(name: "Eindhoven Centraal", lat: 51.44306, lon: 5.47917)
    private let bd = TripCard.Spot(name: "Breda", lat: 51.59556, lon: 4.78)
    static let waitPayload = "{\"b\":{\"at\":1799999990,\"dist\":300,\"eta\":1800000120,\"id\":\"vector-wait-1\",\"ride\":{\"arr\":1800003720,\"dep\":1800000660,\"from\":{\"lat\":51.44306,\"lon\":5.47917,\"name\":\"Eindhoven Centraal\"},\"line\":\"IC\",\"mode\":\"train\",\"num\":\"3512\",\"to\":{\"lat\":51.59556,\"lon\":4.78,\"name\":\"Breda\"},\"trip\":\"vector-trip-3512\"},\"state\":\"coming\",\"stop\":{\"lat\":51.44306,\"lon\":5.47917,\"name\":\"Eindhoven Centraal\"}},\"f\":\"3c157621a97cf055f5804a9826c6d1e1\",\"k\":\"wait\",\"n\":\"vector-11\",\"t\":1800000000,\"v\":1}"
    static let waitSig = "dvEcw94cpL8gWf9Pk5zYUIs1-BuEqsDFUGLCyxkupqCyiFUZQNQ2u9kTLUICfKy0W_EOElr6dHRbdLfVWwJDBA"
    static let campusPayload = "{\"b\":{\"on\":true,\"school\":\"BUas\",\"since\":1799998500,\"until\":1800034500},\"f\":\"3c157621a97cf055f5804a9826c6d1e1\",\"k\":\"campus\",\"n\":\"vector-12\",\"t\":1800000000,\"v\":1}"
    static let campusSig = "KZJaSU7N-X7-nf4ppDL55RLL8r1QNVvZk4tS_e-5MVXjklHFbv0DrckGuITkgbOQBMkqpwd-ZiiN2NKaHm0IAg"
    static let buddyPayload = "{\"b\":{\"day\":\"2027-01-15\",\"leave\":1799994000,\"on\":true,\"ride\":{\"arr\":1799998320,\"dep\":1799995260,\"from\":{\"lat\":51.44306,\"lon\":5.47917,\"name\":\"Eindhoven Centraal\"},\"line\":\"IC\",\"mode\":\"train\",\"num\":\"3512\",\"to\":{\"lat\":51.59556,\"lon\":4.78,\"name\":\"Breda\"},\"trip\":\"vector-trip-3512\"}},\"f\":\"3c157621a97cf055f5804a9826c6d1e1\",\"k\":\"buddy\",\"n\":\"vector-13\",\"t\":1799992800,\"v\":1}"
    static let buddySig = "Zazseam6h_FFLC8gnZaYfx4ukSG2Dl2YbRSObRDZa9odsX5tHpyA-HpdHZJeZLEg3OQ91RYkIEUGzw8N6jR-Dg"
    static let delayPayload = "{\"b\":{\"late\":6,\"next\":{\"arr\":1800004860,\"dep\":1800001800,\"from\":{\"lat\":51.44306,\"lon\":5.47917,\"name\":\"Eindhoven Centraal\"},\"line\":\"IC\",\"mode\":\"train\",\"num\":\"3516\",\"to\":{\"lat\":51.59556,\"lon\":4.78,\"name\":\"Breda\"},\"trip\":\"vector-trip-3516\"},\"ride\":{\"arr\":1800003420,\"dep\":1800000360,\"from\":{\"lat\":51.44306,\"lon\":5.47917,\"name\":\"Eindhoven Centraal\"},\"line\":\"IC\",\"mode\":\"train\",\"num\":\"3512\",\"sdep\":1800000000,\"to\":{\"lat\":51.59556,\"lon\":4.78,\"name\":\"Breda\"},\"trip\":\"vector-trip-3512\"},\"who\":[\"3c157621a97cf055f5804a9826c6d1e1\",\"65392c81aa86e697083b0960bf107afb\"]},\"f\":\"3c157621a97cf055f5804a9826c6d1e1\",\"k\":\"delay\",\"n\":\"vector-14\",\"t\":1800000000,\"v\":1}"
    static let delaySig = "hvyCU_Sk36bcLvd52FSIHuHI37Ni_qQhs7_Rpnmy5B_2hlbgSa2d47QAXRfYbBzbLV8gMvcS_c4zlVL_wJdZAA"
    static let answerPayload = "{\"b\":{\"answer\":\"wait\",\"re\":\"vector-wait-1\",\"text\":\"I’ll wait\"},\"f\":\"65392c81aa86e697083b0960bf107afb\",\"k\":\"message\",\"n\":\"vector-15\",\"t\":1800000030,\"v\":1}"
    static let answerSig = "quv2P-b4oVOMfuXKCxJIVQIMwkH9zSq25Djgu81cSa7uWyaFt7gjlmcnX5kqidzMy_K-R9OC9PMbuWXzC8xDDA"
    static let waitBox = "AQIz8AbvS-0UTqClu0bHBnx8Ks7F-MyBHz31n9zVrHYUcXJzdHV2d3h5ent8F4o711H-IQXcNO0jPzR1Ejq4_JNB8y8vGAu7V-8zdOX1UD3N50pM00P_1ADbwrE3h2wmhHcHqQEz3aRrX0n3sIOzc-UWOECBBaxHwmpFfUoOHcakg99KDVQeMqmhhAYlfNcUv5s09i7WlXYo67QXcMQAxr5LJm72nq6ZhSNVBXjGtjFHTuuUCl3ilkUa-8nepuYvnJSCbcLXRclEJUDxFeVEBO0-6NXuHP7FBDo7mTMP-TARfC1o7ZDV-dK67xSB-CeKwDJZelbIe7_mUIBbkv8lrXudYV_1qhsBCp-CBR_-XRSu-07ceS9do_vOnz6YQ0DSo-ec87gJn-J9jQlxYOWYhVezq9ZwxIOH-pLym5h0uZeYGhN6PAxlBQRZwJIbRILXFpqypJm36Ly9CjU7nxsZrGRMtrqmDTHxkSQwmbl9UTpgf6yZxz0BzBEAvOcz2ygKb8SITHbSbyaVL4TwQel2xRmpgMVfpe4KwaYlxTXLz6TObtYy6Kmx1urlARXMP2lRhDfH3TGnzA8Qq00AH43ryoWsZGtF4j7E6FSV5Jq1qAtOo7qIFPIx0XttCjdbaCUyfu-U_w0tz8Sh6hapPzAcJCYeI0UOgzsw63llntPRDyN9qb1pNHrKPIbHaSLdFV7tGH11uhMG9r7u92952kkBSFh9EeAuhn1nswYrEnL9vsH-K4aLg8PR1oTtR10ifQ5FF5YVTZWlzrrn66h83XM"
    static let campusBox = "AYgxhrgAtB1c8EKWldqbPMTzKOvNGEpuSC-leMED8Gx3wcLDxMXGx8jJysvM7sUXIpFk66f2MxcXYYb_tMTT0JGE-coRJl94y_gjkkUpyQ_ek_2yhJS6fKfMo-pj9FNhe4peWbLP9HKoM4MKBl28GjWBJwVOwQ4G6cVMY_hDekvjQ95EHvOI39blGlgywHJi9oPKRZ9Ekxmlt8QzpLsk5t7xneAEPe-cObvOIgpDj3rPTKtBac__D4tMib7wYbiF-RVet2Ye-iIf8ku1lYuiCOEuXyBMNYvzEWPO3nv_ROSbsh9G7-jmTcDLepeX-ajit0lGM0KX8xALe_wdEIUXHrqadwbnll2Rvzk-2tVpM2Swb0y6udi-r5frt2Ai"

    private func lockCheck(_ payload: String, sig: String, box: String, eph: String, ephPub: String, nonce: String) throws {
        let p = Data(payload.utf8)
        let s = try XCTUnwrap(B64URL.decode(sig))
        XCTAssertTrue(sam.signing.publicKey.isValidSignature(s, for: FriendBox.signed(p, to: lou.account)))
        let e = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex(eph))
        XCTAssertEqual(e.publicKey.rawRepresentation.hexString, ephPub)
        let locked = try FriendBox.lock(s + p, to: lou.card, eph: e, nonce: try ChaChaPoly.Nonce(data: hex(nonce)))
        XCTAssertEqual(B64URL.encode(locked), box)
    }

    private func ride3512(dep: TimeInterval, arr: TimeInterval) -> TripCard.Ride {
        TripCard.Ride(mode: "train", line: "IC", num: "3512", trip: "vector-trip-3512", from: ehv, to: bd, dep: at(dep), arr: at(arr))
    }

    func test_kindsVersion() {
        for k in ["wait", "delay", "buddy", "campus"] { XCTAssertTrue(FriendMessage.known.contains(k)) }
        XCTAssertEqual(FriendMessage.kindsVersion, 5)
    }

    func test_waitBox() throws {
        let w = WaitFor(id: "vector-wait-1", state: "coming", stop: ehv, ride: ride3512(dep: 1_800_000_660, arr: 1_800_003_720),
                        dist: 300, eta: at(1_800_000_120), at: at(1_799_999_990))
        let p = try FriendBox.payload(.wait(w), from: sam.account, at: t0, id: "vector-11")
        XCTAssertEqual(String(decoding: p, as: UTF8.self), Self.waitPayload)
        try lockCheck(Self.waitPayload, sig: Self.waitSig, box: Self.waitBox,
                      eph: "5152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f70", ephPub: "0233f006ef4bed144ea0a5bb46c7067c7c2acec5f8cc811f3df59fdcd5ac7614", nonce: "7172737475767778797a7b7c")
        let o = try FriendBox.open(try XCTUnwrap(B64URL.decode(Self.waitBox)), me: lou, from: sam.account,
                                   known: { $0 == self.sam.account ? self.sam.card : nil })
        guard case .wait(let got) = o.message else { return XCTFail("not a wait") }
        XCTAssertEqual(got, w)
        XCTAssertEqual(got.phase, .coming)
    }

    func test_campusBox() throws {
        let c = CampusState(on: true, school: "BUas", since: at(1_799_998_500), until: at(1_800_034_500))
        let p = try FriendBox.payload(.campus(c), from: sam.account, at: t0, id: "vector-12")
        XCTAssertEqual(String(decoding: p, as: UTF8.self), Self.campusPayload)
        try lockCheck(Self.campusPayload, sig: Self.campusSig, box: Self.campusBox,
                      eph: "8182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0", ephPub: "883186b800b41d5cf0429695da9b3cc4f328ebcd184a6e482fa578c103f06c77", nonce: "c1c2c3c4c5c6c7c8c9cacbcc")
        let o = try FriendBox.open(try XCTUnwrap(B64URL.decode(Self.campusBox)), me: lou, from: sam.account,
                                   known: { $0 == self.sam.account ? self.sam.card : nil })
        XCTAssertEqual(o.message, .campus(c))
    }

    func test_buddyPayload() throws {
        let b = BuddyPlan(on: true, day: "2027-01-15", leave: at(1_799_994_000), ride: ride3512(dep: 1_799_995_260, arr: 1_799_998_320))
        let p = try FriendBox.payload(.buddy(b), from: sam.account, at: at(1_799_992_800), id: "vector-13")
        XCTAssertEqual(String(decoding: p, as: UTF8.self), Self.buddyPayload)
        let s = try XCTUnwrap(B64URL.decode(Self.buddySig))
        XCTAssertTrue(sam.signing.publicKey.isValidSignature(s, for: FriendBox.signed(p, to: lou.account)))
        let (h, m) = try FriendBox.parse(p)
        XCTAssertEqual(h.k, "buddy")
        XCTAssertEqual(m, .buddy(b))
        // taken back
        let off = try FriendBox.payload(.buddy(BuddyPlan(on: false)), from: sam.account, at: t0, id: "x")
        XCTAssertTrue(String(decoding: off, as: UTF8.self).hasPrefix("{\"b\":{\"on\":false},"))
    }

    func test_delayPayload() throws {
        var ride = ride3512(dep: 1_800_000_360, arr: 1_800_003_420)
        ride.sdep = t0
        let next = TripCard.Ride(mode: "train", line: "IC", num: "3516", trip: "vector-trip-3516", from: ehv, to: bd,
                                 dep: at(1_800_001_800), arr: at(1_800_004_860))
        let d = RideDelay(ride: ride, late: 6, next: next, who: [sam.account, lou.account])
        let p = try FriendBox.payload(.delay(d), from: sam.account, at: t0, id: "vector-14")
        XCTAssertEqual(String(decoding: p, as: UTF8.self), Self.delayPayload)
        let s = try XCTUnwrap(B64URL.decode(Self.delaySig))
        XCTAssertTrue(sam.signing.publicKey.isValidSignature(s, for: FriendBox.signed(p, to: lou.account)))
        XCTAssertEqual(try FriendBox.parse(p).1, .delay(d))
        XCTAssertEqual(DelayWords.title(d), "IC 3512 is 6 min late")
    }

    func test_waitAnswerPayload() throws {
        let body = ChatText(text: WaitAnswer.wait.text, re: "vector-wait-1", answer: "wait")
        let p = try FriendBox.payload(.message(body), from: lou.account, at: at(1_800_000_030), id: "vector-15")
        XCTAssertEqual(String(decoding: p, as: UTF8.self), Self.answerPayload)
        let s = try XCTUnwrap(B64URL.decode(Self.answerSig))
        XCTAssertTrue(lou.signing.publicKey.isValidSignature(s, for: FriendBox.signed(p, to: sam.account)))
    }
}
