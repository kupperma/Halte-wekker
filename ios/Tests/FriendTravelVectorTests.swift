import XCTest
import CryptoKit

/// Friends 0.26: the travel box and the signed state put, byte for byte (docs/superpowers/specs/2026-11-18-friends-design.md,
/// "As built (0.26)"), made with Node's crypto from the spec alone.
final class FriendTravelVectorTests: XCTestCase {
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

    static let payload = "{\"b\":{\"coach\":{\"at\":\"EHV\",\"front\":true,\"n\":3,\"of\":6},\"end\":1800004200,\"eta\":1800003780,\"from\":{\"lat\":51.44306,\"lon\":5.47917,\"name\":\"Eindhoven Centraal\"},\"leg\":2,\"legs\":2,\"line\":\"IC\",\"mode\":\"train\",\"num\":\"3512\",\"pos\":{\"acc\":12,\"at\":1799999990,\"lat\":51.5112,\"lon\":5.2874},\"state\":\"riding\",\"to\":{\"lat\":51.59556,\"lon\":4.78,\"name\":\"Breda\"},\"trip\":\"vector-trip-3512\"},\"f\":\"3c157621a97cf055f5804a9826c6d1e1\",\"k\":\"travel\",\"n\":\"vector-2\",\"t\":1800000000,\"v\":1}"
    static let signature = "7PkPXX1XZcPuaJGBWjjmWJhPZv2Z8FlixA7Ddq0nx8x0mU2Gy6q90ZPGYeE7TaryRZL9mhCFNzpPBlSHfhilCw"
    static let box = "AWdd1XTtd4kxCz0udoHzeQtGbHc7FSH-zzZXeVg3HqUvgIGCg4SFhoeIiYqLZXWLBco9z3tfobhx5IFO49FI_IR1QXGidybz-bpO_guAfOgz4G8oLdQIaF5b0bBOaJAf1w41CGfhpE6u9ABuv3dyd--Hzvkjf8lvET3kp0QXZpaPiGlZG04GLRL7cXaLgoA0WoWBO7mYef611woIfWFo_o2GXLiK8YxMongc9PQd2FIQGmhHo-xyrnK2Vy3FMYRJCpwIVDZFO5rLrLrMqzc278Q2jy7rdH468tESk0304xKQXctnPMSHZ2TDfx4TPlyErsc9DpqkRgv9ErPLJJIZDDpPvEi_-ZdeR8WSxaoQsyplZax_d_QwUpXClUC3J19Dqiz7vzptdwqEUOwhcV6i8hUE4EJ48icVvs226zj6HaYBLOayX6naO12GN2K0VikdEJ6gVq7qFXrO5TozyVPwssFx0wsBT1__KhSyL8PdhQH1rc7IFxJEWEs-vblDYPj3aOrao8LRoq1VSc-YIiE_OBac2LeIKmhBYW8PnYVUd5K4axYnbur2FS2Wqv2bt1jJMwH-1HjNkQ8Pu513wljfQCOC0TXDk-6T5TEtxUU9n2c7qnJSmefcV_m5od2Tqvx4yiz3qS9cBnjSmMoMduBGuL1QzHYAuJgQ0e9E7pLcsIFUWoDEWdwlRXxPYrTTkWBUe6A2BiS2qK932vckg-5qkXwc3rVhs4T_FxkakhGpng4J2gKoq-SKAjXprkahwrg"

    func test_travelBoxLocksByteForByte() throws {
        let p = Data(Self.payload.utf8)
        let sig = try XCTUnwrap(B64URL.decode(Self.signature))
        XCTAssertTrue(sam.signing.publicKey.isValidSignature(sig, for: FriendBox.signed(p, to: lou.account)))
        let eph = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex("606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f"))
        XCTAssertEqual(eph.publicKey.rawRepresentation.hexString, "675dd574ed7789310b3d2e7681f3790b466c773b1521fecf36577958371ea52f")
        let nonce = try ChaChaPoly.Nonce(data: hex("808182838485868788898a8b"))
        let box = try FriendBox.lock(sig + p, to: lou.card, eph: eph, nonce: nonce)
        XCTAssertEqual(B64URL.encode(box), Self.box)
    }

    func test_travelBoxOpens() throws {
        let box = try XCTUnwrap(B64URL.decode(Self.box))
        let o = try FriendBox.open(box, me: lou, from: sam.account, known: { $0 == self.sam.account ? self.sam.card : nil })
        guard case .travel(let s) = o.message else { return XCTFail("not a travel box") }
        XCTAssertEqual(o.header.n, "vector-2")
        XCTAssertEqual(s.stage, .riding)
        XCTAssertEqual(s.mode, "train")
        XCTAssertEqual(s.line, "IC")
        XCTAssertEqual(s.num, "3512")
        XCTAssertEqual(s.trip, "vector-trip-3512")
        XCTAssertEqual(s.from, TravelState.Spot(name: "Eindhoven Centraal", lat: 51.44306, lon: 5.47917))
        XCTAssertEqual(s.to.name, "Breda")
        XCTAssertEqual(s.eta, Date(timeIntervalSince1970: 1_800_003_780))
        XCTAssertEqual(s.end, Date(timeIntervalSince1970: 1_800_004_200))
        XCTAssertEqual(s.pos?.lat, 51.5112)
        XCTAssertEqual(s.pos?.acc, 12)
        XCTAssertEqual(s.pos?.at, Date(timeIntervalSince1970: 1_799_999_990))
        XCTAssertEqual(s.leg, 2)
        XCTAssertEqual(s.legs, 2)
        XCTAssertEqual(s.coach, TravelState.Coach(n: 3, of: 6, front: true, at: "EHV"))
        // a stranger's travel box doesn't open as theirs
        XCTAssertThrowsError(try FriendBox.open(box, me: lou, from: sam.account, known: { _ in nil }))
    }

    func test_signedStatePut() throws {
        let body = Data("{\"states\":[{\"data\":\"AWdd1XTtd4kxCz0udoHzeQtGbHc7FSH-zzZXeVg3HqUvgIGCg4SFhoeIiYqLZXWLBco9z3tfobhx5IFO49FI_IR1QXGidybz-bpO_guAfOgz4G8oLdQIaF5b0bBOaJAf1w41CGfhpE6u9ABuv3dyd--Hzvkjf8lvET3kp0QXZpaPiGlZG04GLRL7cXaLgoA0WoWBO7mYef611woIfWFo_o2GXLiK8YxMongc9PQd2FIQGmhHo-xyrnK2Vy3FMYRJCpwIVDZFO5rLrLrMqzc278Q2jy7rdH468tESk0304xKQXctnPMSHZ2TDfx4TPlyErsc9DpqkRgv9ErPLJJIZDDpPvEi_-ZdeR8WSxaoQsyplZax_d_QwUpXClUC3J19Dqiz7vzptdwqEUOwhcV6i8hUE4EJ48icVvs226zj6HaYBLOayX6naO12GN2K0VikdEJ6gVq7qFXrO5TozyVPwssFx0wsBT1__KhSyL8PdhQH1rc7IFxJEWEs-vblDYPj3aOrao8LRoq1VSc-YIiE_OBac2LeIKmhBYW8PnYVUd5K4axYnbur2FS2Wqv2bt1jJMwH-1HjNkQ8Pu513wljfQCOC0TXDk-6T5TEtxUU9n2c7qnJSmefcV_m5od2Tqvx4yiz3qS9cBnjSmMoMduBGuL1QzHYAuJgQ0e9E7pLcsIFUWoDEWdwlRXxPYrTTkWBUe6A2BiS2qK932vckg-5qkXwc3rVhs4T_FxkakhGpng4J2gKoq-SKAjXprkahwrg\",\"to\":\"65392c81aa86e697083b0960bf107afb\",\"ttl\":360}]}".utf8)
        XCTAssertEqual(Data(SHA256.hash(data: body)).hexString, "0c15ebabfaa77e823f6831b5718b0ed587350e01cd3ca08e842971307246ec57")
        let text = RelaySign.canonical(method: "POST", path: "/f/v1/state/put", account: sam.account,
                                       device: "00112233445566778899aabbccddeeff", time: 1_800_000_000,
                                       nonce: "vector-nonce-0002", body: body)
        XCTAssertTrue(text.hasSuffix("\n0c15ebabfaa77e823f6831b5718b0ed587350e01cd3ca08e842971307246ec57"))
        let sig = try XCTUnwrap(B64URL.decode("TYjw9PyrJ_a6Y0ahTV_e6jnPN_YsdfOobgbhBIJXyLtokJQvQOCicQpl-ZnmZPbFJlCmYLw8vXV8YcZl6ikHAQ"))
        XCTAssertTrue(sam.signing.publicKey.isValidSignature(sig, for: Data(text.utf8)))
    }
}
