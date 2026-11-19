import XCTest
import CryptoKit

/// Friends 0.27: the chat, group and trip boxes, byte for byte (docs/superpowers/specs/2026-11-18-friends-design.md,
/// "As built (0.27)"), made with Node's crypto from the spec alone. Kim is a third account (seed 20…2f) who is in
/// Sam's group but not Lou's friend: Lou checks Kim's line with the card from the group's list.
final class FriendChatVectorTests: XCTestCase {
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
    private var kim: FriendIdentity { FriendIdentity(seed: hex("202122232425262728292a2b2c2d2e2f"))! }
    private let group = "0123456789abcdef01234567"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static let messagePayload = "{\"b\":{\"text\":\"On the 305\"},\"f\":\"3c157621a97cf055f5804a9826c6d1e1\",\"k\":\"message\",\"n\":\"vector-3\",\"t\":1800000000,\"v\":1}"
    static let rosterPayload = "{\"b\":{\"admin\":\"3c157621a97cf055f5804a9826c6d1e1\",\"members\":[{\"card\":{\"a\":\"4BkenPteSyzMhZGAEzxCVDtPbsYAfktcUGCFY_f6wTQ\",\"s\":\"Pimf5pXMDZx03fVhlCwafY9i6il4P1yqNBRkQCW0IMI\"},\"name\":\"Sam\"},{\"card\":{\"a\":\"mJcwSQIqMduIElgAV4WiNQyNWrNO9pXpcmuy_ro-H14\",\"s\":\"jovYuOL-kNKocNr5m2ZGyLdEWYo8qECxLRmVm84HQ_8\"},\"name\":\"Lou\"},{\"card\":{\"a\":\"hJSg_nl1Q_a3QwcIgBVBmLQc5cpx3Ms_dPHOjgUNOkw\",\"s\":\"Qtw5rLliG2yuURUMcKjC0IvUhAYP4Rvx-ZpKIdyflYI\"},\"name\":\"Kim\"}],\"name\":\"Uni crew\",\"rev\":1},\"f\":\"3c157621a97cf055f5804a9826c6d1e1\",\"g\":\"0123456789abcdef01234567\",\"k\":\"group\",\"n\":\"vector-4\",\"t\":1800000000,\"v\":1}"
    static let gmsgPayload = "{\"b\":{\"text\":\"Save me a seat\"},\"f\":\"9bc64cbb2dab5f14d76c61166b324b98\",\"g\":\"0123456789abcdef01234567\",\"k\":\"message\",\"n\":\"vector-5\",\"t\":1800000060,\"v\":1}"
    static let tripPayload = "{\"b\":{\"by\":1800006000,\"end\":1800005400,\"note\":\"Take the 07:41 with me?\",\"rides\":[{\"arr\":1800004200,\"dep\":1800001260,\"from\":{\"id\":\"vector-stop-ehv\",\"lat\":51.44306,\"lon\":5.47917,\"name\":\"Eindhoven Centraal\"},\"line\":\"IC\",\"mode\":\"train\",\"name\":\"Intercity\",\"num\":\"3512\",\"plat\":\"4\",\"to\":{\"lat\":51.59556,\"lon\":4.78,\"name\":\"Breda\"},\"trip\":\"vector-trip-3512\"}],\"start\":1800000900,\"to\":{\"lat\":51.5866,\"lon\":4.7745,\"name\":\"BUas\"}},\"f\":\"3c157621a97cf055f5804a9826c6d1e1\",\"k\":\"trip\",\"n\":\"vector-6\",\"t\":1800000000,\"v\":1}"
    static let answerPayload = "{\"b\":{\"answer\":\"in\",\"re\":\"vector-6\",\"text\":\"I’m in\"},\"f\":\"65392c81aa86e697083b0960bf107afb\",\"k\":\"message\",\"n\":\"vector-7\",\"t\":1800000120,\"v\":1}"
    static let messageSig = "C-Wt4CDWC_JyBVNuBtPk1-FVV0yP9g5FRScvJjRJ0SgkyfRf6VjOUIxh-SOHDwcn9Gwb0HB3yYABiE1vVttEDg"
    static let messageBox = "AWBacl0qSt_usaKeF-3WIcG3WT7ozbxErGxKtuL4BdI8wMHCw8TFxsfIycrLRqFOo-EkGjQPOnM4XKXDadlG8WQ5tpTwi_0U5Uns-Z1xBiFtYMaIN79Cr8oXgKvrJKpNshS2dROPnVqMF4ZKWKh9X26BUeS2PAG57uU0JIwrOkT31H0vHyJLExZLEdgc8G8V6vIfcUMGLzBBzlP3F08iDF01gGFFCVZ1wpQLZ_rebRG0027r_zRGQrqduN2jMcme7z31aWLls0bxjcI1WO7CRPhIz51mRqY6BHNTiftUnyUDY3ZU2HUHj3EBO1Y2cDIbJg"
    static let rosterLouSig = "pBsY4bQds41vtaz4g7u3p-_hoHtfyVx84qyUzxpHU_IUKWHSP8h9jZ3ryGMMvaGqf80SDXz04W2GHbnaz3r8Cw"
    static let rosterLouBox = "AWs-5nRjWDy-PcCP6dB2XCZm_1IQ3VJ8nYcF5EknyA1V8PHy8_T19vf4-fr7kQajN_ueiSFAQU_1PF_phMn7SqcyQOUkHfuuVVyQb3zCY_Q78mmKFMHYUmhGAX1ghsvUdKUoBBG-EvRBuUKUtIx3K37SJa8BKVsrFT6yhtBic79k3gLb2E_y7r1Fh5PgpVI8o5b3JyiWjk0aTBOEEXncwES2AHJmkR44GDRdpVad9xr_8pVFOuHgXdfV8piLGKp5K0GSPaFzNZ25jG1ZNtEeXT25aBag_LEEPJZsOyaOHXYMHddtGnFsokBFh12AaG42Lyr_IvAgluB-LETEKwCMEfiFGBtl-SOi9vrYh-4D78UZMRWjw6GRbK79Y2pgkU_BLN03OZxvO7mjHzzcrnB6FpHRM1BUeP8ftOzLVva4p1dV3sSGWcYy8V9eDeL5G8-BFlVq7lTiKV9ccDPliEOYKeXO2uS1GS3piSzbWsXRMGed9_Kt8Hiv0IeoaiGky-VJV2QtU_Jt0YRu7BbOLr4FuMUNKG7I2C4F3PzKsAkylxyCVUw3dUSR2qGoWcu2sY85bHlHoq_3BYCbGiNNPCDeEbsi6UUApGBeWUmn_xaO6i1ISh8X8-IonqYcc3Fve1Ye6wn5wWaeL_ql6QBsSogf74idv-jjQ_TPXypJN0VSEWvaElcsAv-KQj56SeebJtH1FC-cSvuD43y9QJZueL0gs4xS1J9h82NtAIaiVAppbNDl9GfNde2msMqJNbxaLvEQbOwIDlBi2yLVnlgGPdHlZ4V7myrnMK-3eywOnebPrc61CQfP1LBM8jhQomMYA4unx5xtyx02awDDGnlx8Q-jNCotQTTj1N0EjsU4PApiwaAtEUIhy4thnujUFBzIe0dCreXmLRJlnQm-ESrwfZ1zrGJkiRIPLVPVkFBbPbLikA"
    static let gmsgLouSig = "Jhg6KmEvwF4SdBCDObQIeS3uq8-ZIiQlc0-Q2n2dKTVExpkQTr7xvdUmMeSAgu93_M-AWm_SsLvSIxfaU4Q3Cg"
    static let gmsgLouBox = "AcHgyPVoHs29_u1KqlSZzpdU0PRxmp4MF4HNeP7SPacUoaKjpKWmp6ipqqusROmx4BC81O-NVmsLma46Q0CUd3NKmrHkOWfkSa8yKCHm1OZDiTViVTjXcXkSa7WDl2FS6BBd-h-Hpro_8R6nAHlgfo9-4g_1xrwCZ-Nw_os6KQFFKACdfSxBWOx7oci5R2mtdBslgqqxTNRHbQRb1_ih-J2eCqYDWZolXh9qys-UlU6ErdtHPUMkyLRmhMXGfmC8LcZ6x7mbQiDQYlV7ZcF7FMXyfeIEYqWZsACSGSzaSHOS8F2GDu4UcU1ytROhPpBDj2Dy1p69Xc1MfFVTWGaU0Gs7m9uwFp846SpdQ8mucHtIRXR6"
    static let gmsgSamSig = "bAKqe-KrGg2v1BNSYti8EiCsyMWjgU6FWhqZzWZXuUFvkHdyMHEBlEK9ejv5ZQncm0wj_E437snlsUn-SHv9AQ"
    static let gmsgSamBox = "AWcOn_dEG91cqIbiatThjpvZtO31IhnvwHHNwT7unY5DsbKztLW2t7i5uru8X_0tIgokGLQwviDssVFErIKZLgBN4n9Ft_NgAecydT0R0HNxCU-aObfKdaOHukE72nxbw9Gy8Q5KgMc6ZhUbCUZ0p5V_IIN_5IuXJyp1dml47nVifyi9BPswrJao7VRp4BDGYtq5c79B7SAYdDwJxGhrnEyw1aaln2YiZ2BRAf69RN97XCfh0embpOOcsUIBeg07-syRxm5dwbV_XKwhAd3uKBoYD_TXZxI2cqKzDcepW2_IjIP7QRJOlj8nYp30DkWKrvc5hORftcKsUzX14znV2qdVqOJ9rC3TEOqkYenWhZWCScal"
    static let tripSig = "_YY3pPeiv3WsTZ3ZZeygo1iajicOqqoD0_w6TwlMRBgIy81h1jlkHHAb_-XcQ_uUaxb9vmdUW6rcP3EB1zGQCA"
    static let tripBox = "AWSxAbHQvlqHBL0Hj5iVAB_APo6flSLxiN0SjZhG1IRm0dLT1NXW19jZ2tvcpaSNBO2NCnxoHbkx--22UkdLqhhsh635p0DInyf9QvRoR1cpULartizgPTxXhw1XJpxxnvKFqjs1ha4LCODhIuaxG6DtiYR3fAhainRDLsW0alzRKpSOi8GTm5XfR9CEFIpY-t1K-4NCeSqQmij51Cy1REq4SAd1-b94OekuxLgorNquCM8DTWdhPjTef3HmdAyj1wmaJyXGDbHT162MzM1t5gg1VgJ9Jt4DPu1mBkNE5neZ7PywC3aqmWhb999D7vhHXabuWPzFQGTbheixFbyfBltcHxU-idHXWVaq1uRFZA9VFJatwOQRHQoCTK8tK9akQAWP9B675E9FswCbHxy-9Xp6otJstsA2VuxwimjDcpQ6qb6NbH7hkbIXWCGpCKUNFjo37-ifvvO6zzmILfSlU5oRfGkVLUsA_Yi8rH-HxX0y7FqJHg6wn-LmWEmjZkoqeRn-nWhu4FUqASz1bgA4cuy1F-4JSJoZqBCQXYvzR1Qmpxn22eHBO9JF2UiXmP2HlKglZ59NB10CDDRJfmttE3K4jdDG4WVVyE9h6P17MfAZWSPUfl3i-56IbFsqrsTvslYZtY0h4NaB_aELuMxppojQVdy2TxvSfcjIm2WmNx9VUxYA24JnodKoazK4GP9VAQqCEVGombnhzwgnFzQPMq22fVeUyeqM6U2eW6k-aQH1A8YYGRb4ADeOx8xr9WMkqrpPaaPeBtDSZNUKRaxDjmLGN4dzIgElHXLC9IvilHR0-dOu2ONt-mCKaLcSM13AqwGKxHYW"

    private func lockCheck(_ payload: String, sig: String, box: String, from: FriendIdentity, to: FriendIdentity,
                           eph: String, ephPub: String, nonce: String) throws {
        let p = Data(payload.utf8)
        let s = try XCTUnwrap(B64URL.decode(sig))
        XCTAssertTrue(from.signing.publicKey.isValidSignature(s, for: FriendBox.signed(p, to: to.account)))
        let e = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex(eph))
        XCTAssertEqual(e.publicKey.rawRepresentation.hexString, ephPub)
        let locked = try FriendBox.lock(s + p, to: to.card, eph: e, nonce: try ChaChaPoly.Nonce(data: hex(nonce)))
        XCTAssertEqual(B64URL.encode(locked), box)
    }

    func test_kimsKeys() {
        XCTAssertEqual(kim.account, "9bc64cbb2dab5f14d76c61166b324b98")
        XCTAssertEqual(kim.card.signKey.hexString, "42dc39acb9621b6cae51150c70a8c2d08bd484060fe11bf1f99a4a21dc9f9582")
        XCTAssertEqual(kim.card.agreeKey.hexString, "8494a0fe797543f6b743070880154198b41ce5ca71dccb3f74f1ce8e050d3a4c")
    }

    func test_messageBox() throws {
        // the app writes exactly these bytes
        let p = try FriendBox.payload(.message(ChatText(text: "On the 305")), from: sam.account, at: t0, id: "vector-3")
        XCTAssertEqual(String(decoding: p, as: UTF8.self), Self.messagePayload)
        try lockCheck(Self.messagePayload, sig: Self.messageSig, box: Self.messageBox, from: sam, to: lou,
                      eph: "a0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebf", ephPub: "605a725d2a4adfeeb1a29e17edd621c1b7593ee8cdbc44ac6c4ab6e2f805d23c",
                      nonce: "c0c1c2c3c4c5c6c7c8c9cacb")
        let o = try FriendBox.open(try XCTUnwrap(B64URL.decode(Self.messageBox)), me: lou, from: sam.account, known: { _ in self.sam.card })
        XCTAssertEqual(o.message, .message(ChatText(text: "On the 305")))
        XCTAssertNil(o.header.g)
    }

    func test_groupRosterBox() throws {
        let roster = GroupRoster(name: "Uni crew", admin: sam.account, rev: 1, members: [
            GroupMember(card: sam.card, name: "Sam"), GroupMember(card: lou.card, name: "Lou"), GroupMember(card: kim.card, name: "Kim"),
        ])
        let p = try FriendBox.payload(.group(roster), from: sam.account, at: t0, id: "vector-4", group: group)
        XCTAssertEqual(String(decoding: p, as: UTF8.self), Self.rosterPayload)
        try lockCheck(Self.rosterPayload, sig: Self.rosterLouSig, box: Self.rosterLouBox, from: sam, to: lou,
                      eph: "d0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebecedeeef", ephPub: "6b3ee67463583cbe3dc08fe9d0765c2666ff5210dd527c9d8705e44927c80d55",
                      nonce: "f0f1f2f3f4f5f6f7f8f9fafb")
        let o = try FriendBox.open(try XCTUnwrap(B64URL.decode(Self.rosterLouBox)), me: lou, from: sam.account, known: { _ in self.sam.card })
        XCTAssertEqual(o.message, .group(roster))
        XCTAssertEqual(o.header.g, group)
    }

    /// One line, locked once per member: the same payload (same n, t and g) to Lou and to Sam, each signed for them.
    func test_groupLineFansOut() throws {
        let p = try FriendBox.payload(.message(ChatText(text: "Save me a seat")), from: kim.account,
                                      at: Date(timeIntervalSince1970: 1_800_000_060), id: "vector-5", group: group)
        XCTAssertEqual(String(decoding: p, as: UTF8.self), Self.gmsgPayload)
        try lockCheck(Self.gmsgPayload, sig: Self.gmsgLouSig, box: Self.gmsgLouBox, from: kim, to: lou,
                      eph: "0001020304050607080910111213141516171819202122232425262728293031", ephPub: "c1e0c8f5681ecdbdfeed4aaa5499ce9754d0f4719a9e0c1781cd78fed23da714",
                      nonce: "a1a2a3a4a5a6a7a8a9aaabac")
        try lockCheck(Self.gmsgPayload, sig: Self.gmsgSamSig, box: Self.gmsgSamBox, from: kim, to: sam,
                      eph: "3132333435363738394041424344454647484950515253545556575859606162", ephPub: "670e9ff7441bdd5ca886e26ad4e18e9bd9b4edf52219efc071cdc13eee9d8e43",
                      nonce: "b1b2b3b4b5b6b7b8b9babbbc")
        // Lou isn't Kim's friend: Kim's card comes from the group's list
        let box = try XCTUnwrap(B64URL.decode(Self.gmsgLouBox))
        XCTAssertThrowsError(try FriendBox.open(box, me: lou, from: kim.account, known: { _ in nil }))
        var groups = GroupBook()
        guard case .group(let roster) = try FriendBox.parse(Data(Self.rosterPayload.utf8)).1 else { return XCTFail("not a list") }
        let got = groups.receive(roster, id: group, from: sam.account, me: lou.account, isFriend: { $0 == self.sam.account }, senderName: "Sam", now: t0)
        XCTAssertTrue(got.accepted)
        let o = try FriendBox.open(box, me: lou, from: kim.account, known: { groups.card($0) })
        XCTAssertEqual(o.message, .message(ChatText(text: "Save me a seat")))
        XCTAssertEqual(o.header.g, group)
        XCTAssertTrue(groups.accepts(group, from: kim.account))
    }

    func test_tripBox() throws {
        try lockCheck(Self.tripPayload, sig: Self.tripSig, box: Self.tripBox, from: sam, to: lou,
                      eph: "4142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f60", ephPub: "64b101b1d0be5a8704bd078f9895001fc03e8e9f9522f188dd128d9846d48466",
                      nonce: "d1d2d3d4d5d6d7d8d9dadbdc")
        let o = try FriendBox.open(try XCTUnwrap(B64URL.decode(Self.tripBox)), me: lou, from: sam.account, known: { _ in self.sam.card })
        guard case .trip(let c) = o.message else { return XCTFail("not a trip") }
        XCTAssertEqual(c.rides.count, 1)
        let r = c.rides[0]
        XCTAssertEqual(r.trip, "vector-trip-3512")
        XCTAssertEqual(r.line, "IC")
        XCTAssertEqual(r.num, "3512")
        XCTAssertTrue(r.isTrain)
        XCTAssertEqual(r.from, TripCard.Spot(name: "Eindhoven Centraal", id: "vector-stop-ehv", lat: 51.44306, lon: 5.47917))
        XCTAssertEqual(r.dep, Date(timeIntervalSince1970: 1_800_001_260))
        XCTAssertEqual(r.plat, "4")
        XCTAssertEqual(c.to.name, "BUas")
        XCTAssertEqual(c.by, Date(timeIntervalSince1970: 1_800_006_000))
        XCTAssertEqual(c.note, "Take the 07:41 with me?")
        XCTAssertNotNil(TripCard.valid(c))
    }

    func test_answerPayloadReads() throws {
        let (h, m) = try FriendBox.parse(Data(Self.answerPayload.utf8))
        XCTAssertEqual(h.k, "message")
        XCTAssertEqual(m, .message(ChatText(text: "I’m in", re: "vector-6", answer: "in")))
    }
}
