import XCTest
import CryptoKit

/// The Friends test vectors (docs/superpowers/specs/2026-11-18-friends-design.md, "As built (0.25)"), made with
/// Node's crypto from the spec alone, so another platform (Android) can check itself against the same numbers.
final class FriendVectorTests: XCTestCase {
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

    func test_seedsGiveKeys() {
        XCTAssertEqual(sam.card.signKey.hexString, "3e299fe695cc0d9c74ddf561942c1a7d8f62ea29783f5caa3414644025b420c2")
        XCTAssertEqual(sam.card.agreeKey.hexString, "e0191e9cfb5e4b2ccc859180133c42543b4f6ec6007e4b5c50608563f7fac134")
        XCTAssertEqual(sam.account, "3c157621a97cf055f5804a9826c6d1e1")
        XCTAssertEqual(sam.card.packed, "Pimf5pXMDZx03fVhlCwafY9i6il4P1yqNBRkQCW0IMLgGR6c-15LLMyFkYATPEJUO09uxgB-S1xQYIVj9_rBNA")
        XCTAssertEqual(lou.card.signKey.hexString, "8e8bd8b8e2fe90d2a870daf99b6646c8b744598a3ca840b12d19959bce0743ff")
        XCTAssertEqual(lou.card.agreeKey.hexString, "98973049022a31db881258005785a2350c8d5ab34ef695e9726bb2feba3e1f5e")
        XCTAssertEqual(lou.account, "65392c81aa86e697083b0960bf107afb")
    }

    func test_boxOpens() throws {
        let box = try XCTUnwrap(B64URL.decode("ATWActY2WIDRruoymt-RITg4Ue0hoo47dell0NLNFmJUQEFCQ0RFRkdISUpLhNjroAbjjIoeYOMe5kdazUPO6vUbw6CWi8bBVyPDycUHH100hP5LwyHNKs7M9kvkxy5hOoexAJL6GOvZ9Oi1kVwqOxYRggbgy-5ifJcMbXtaSibw7_JrtYzH1z5XYVbg3qcSmAAdHPDaeO01RZ4vBuq5t8w1bTo7Uaj1oh4xKD1WA1dPJ1VJJNELVrkBVcAbnYjQvG7p7x7x5uIYeGGvGPc-d5Ut9FdPapHC3Xp1lcrVPHA1F29V5tfYLzkOeQbGknEvQp6BCs150iuFeRBoI9x5WqtARgmWuN2de5qaKISfCyOpu-4knj48qm1aviXL97LBUkjJgLQ3d98wnug_TFK4O05Ns9nS8Ss6gJYLL5IT4tcPTiQOvf8Yw_5frIVF3-c187FoofV24Q"))
        let o = try FriendBox.open(box, me: lou, from: sam.account, known: { _ in nil })
        XCTAssertEqual(o.message, .request(FriendIntro(card: sam.card, name: "Sam")))
        XCTAssertEqual(o.header.n, "vector-1")
        XCTAssertEqual(o.header.t, 1_800_000_000)
        XCTAssertEqual(o.sender, sam.card)
    }

    func test_boxLocksByteForByte() throws {
        let payload = Data("{\"b\":{\"card\":{\"a\":\"4BkenPteSyzMhZGAEzxCVDtPbsYAfktcUGCFY_f6wTQ\",\"s\":\"Pimf5pXMDZx03fVhlCwafY9i6il4P1yqNBRkQCW0IMI\"},\"name\":\"Sam\"},\"f\":\"3c157621a97cf055f5804a9826c6d1e1\",\"k\":\"request\",\"n\":\"vector-1\",\"t\":1800000000,\"v\":1}".utf8)
        let sig = try XCTUnwrap(B64URL.decode("u7Zi2kaNq4eocGLTn5-8SvBDPzZpGq5HGqBOkGUVcvp7CdJWlP4ErXRiHUwz_a2QR8WyOHLWD-q2c0ASirOVDw"))
        XCTAssertTrue(sam.signing.publicKey.isValidSignature(sig, for: FriendBox.signed(payload, to: lou.account)))
        let eph = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex("202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f"))
        XCTAssertEqual(eph.publicKey.rawRepresentation.hexString, "358072d6365880d1aeea329adf9121383851ed21a28e3b75e965d0d2cd166254")
        let nonce = try ChaChaPoly.Nonce(data: hex("404142434445464748494a4b"))
        let box = try FriendBox.lock(sig + payload, to: lou.card, eph: eph, nonce: nonce)
        XCTAssertEqual(B64URL.encode(box), "ATWActY2WIDRruoymt-RITg4Ue0hoo47dell0NLNFmJUQEFCQ0RFRkdISUpLhNjroAbjjIoeYOMe5kdazUPO6vUbw6CWi8bBVyPDycUHH100hP5LwyHNKs7M9kvkxy5hOoexAJL6GOvZ9Oi1kVwqOxYRggbgy-5ifJcMbXtaSibw7_JrtYzH1z5XYVbg3qcSmAAdHPDaeO01RZ4vBuq5t8w1bTo7Uaj1oh4xKD1WA1dPJ1VJJNELVrkBVcAbnYjQvG7p7x7x5uIYeGGvGPc-d5Ut9FdPapHC3Xp1lcrVPHA1F29V5tfYLzkOeQbGknEvQp6BCs150iuFeRBoI9x5WqtARgmWuN2de5qaKISfCyOpu-4knj48qm1aviXL97LBUkjJgLQ3d98wnug_TFK4O05Ns9nS8Ss6gJYLL5IT4tcPTiQOvf8Yw_5frIVF3-c187FoofV24Q")
    }

    func test_signedRequest() throws {
        let body = Data("{\"after\":0,\"limit\":100}".utf8)
        let text = RelaySign.canonical(method: "POST", path: "/f/v1/inbox", account: sam.account,
                                       device: "00112233445566778899aabbccddeeff", time: 1_800_000_000,
                                       nonce: "vector-nonce-0001", body: body)
        XCTAssertEqual(text, "HW1\nPOST\n/f/v1/inbox\n3c157621a97cf055f5804a9826c6d1e1\n00112233445566778899aabbccddeeff\n1800000000\nvector-nonce-0001\n6d91ff60bfde16a24f2bf5ef2516cdf9e47c5d2d54f6e04b5e538046377e375f")
        let sig = try XCTUnwrap(B64URL.decode("Al3g11GCpgqXzYqJAH61A3JX_sSHiXIGqlOz5l_8bjR_VQe4R-VUQqXc5Q08xmJ_kGsRYmklpNUdKHXMRJbBBg"))
        XCTAssertTrue(sam.signing.publicKey.isValidSignature(sig, for: Data(text.utf8)))
    }

    func test_vaultByteForByte() throws {
        let plain = Data("{\"book\":{\"friends\":[],\"incoming\":[],\"myName\":\"Sam\",\"outgoing\":[],\"v\":1},\"v\":1}".utf8)
        let sealed = try FriendVault.seal(plain, me: sam, nonce: ChaChaPoly.Nonce(data: hex("505152535455565758595a5b")))
        XCTAssertEqual(B64URL.encode(sealed), "AVBRUlNUVVZXWFlaW53946SaBXtO59uYSRBJF1zTgHIUdVubOEKiCPQ5MEnqVJhxImhJYxfVnyjS4w0TLI9xA_AKoX6RlIIvJ7G5PfhNK7konHLAQ40zqQx-Qhj8QDR6WwPW0HRNmTwNp40")
        let back = try FriendVault.open(sealed, me: sam)
        let contents = try FriendJSON.decoder.decode(FriendVaultContents.self, from: back)
        XCTAssertEqual(contents.book.myName, "Sam")
        XCTAssertNil(contents.picture)
    }

    func test_jsonIsPlain() throws {
        // dates as unix seconds, data as base64url: nothing only Apple's JSON would read
        let p = FriendPicture(jpeg: Data([0xff, 0xd8, 0xff]))
        let j = String(decoding: try FriendJSON.encoder.encode(p), as: UTF8.self)
        XCTAssertEqual(j, #"{"jpeg":"_9j_"}"#)
        let f = Friend(card: sam.card, name: "Sam", since: Date(timeIntervalSince1970: 1_800_000_000))
        let fj = String(decoding: try FriendJSON.encoder.encode(f), as: UTF8.self)
        XCTAssertTrue(fj.contains(#""since":1800000000"#), fj)
    }
}
