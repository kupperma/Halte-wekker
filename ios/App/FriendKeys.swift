import Foundation
import CryptoKit

// Friends (0.25): who you are to the relay and to your friends. Foundation and CryptoKit only, so it's tested as is.
//
// Everything comes from one secret, the 16 random bytes the backup code spells (`FriendWords`):
//   signing key   = Ed25519 (Curve25519.Signing) from HKDF-SHA256(seed, salt "haltewekker-seed-v1", info "sign")
//   agreement key = X25519 (Curve25519.KeyAgreement) from the same, info "agree"
//   vault key     = ChaChaPoly key from the same, info "vault" (locks the friend list kept on the relay)
//   account id    = the first 16 bytes of SHA-256("haltewekker-account-v1" + the signing public key), in hex
// So the backup code brings back the account, its keys and (through the vault) the friend list.

/// base64url without padding, as the relay and the links use it.
enum B64URL {
    static func encode(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    static func decode(_ s: String) -> Data? {
        guard s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "=") }) else { return nil }
        var t = s.replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }
}

/// The JSON every Friends value is written in (boxes, the vault, the list on this phone), the same on any platform:
/// keys sorted, binary data as base64url without padding, dates as unix seconds (a number, may have a fraction).
enum FriendJSON {
    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .secondsSince1970
        e.dataEncodingStrategy = .custom { d, enc in
            var c = enc.singleValueContainer()
            try c.encode(B64URL.encode(d))
        }
        return e
    }
    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        d.dataDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            guard let v = B64URL.decode(try c.decode(String.self)) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "not base64url")
            }
            return v
        }
        return d
    }
}

extension Data {
    /// Lowercase hex.
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

/// What a friend needs to know about you to send you boxes: your two public keys. Your account id comes from the
/// signing one. (In a link, a QR code and inside the request and accept boxes; names travel beside it.)
struct FriendCard: Equatable, Hashable {
    let signKey: Data       // Ed25519 public, 32 bytes
    let agreeKey: Data      // X25519 public, 32 bytes

    init?(signKey: Data, agreeKey: Data) {
        guard signKey.count == 32, agreeKey.count == 32,
              (try? Curve25519.Signing.PublicKey(rawRepresentation: signKey)) != nil,
              (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: agreeKey)) != nil else { return nil }
        self.signKey = signKey
        self.agreeKey = agreeKey
    }

    var account: String { FriendIdentity.accountId(signKey: signKey) }

    /// Both keys in one string (the links' `k`): base64url of the 64 bytes.
    var packed: String { B64URL.encode(signKey + agreeKey) }
    init?(packed: String) {
        guard let d = B64URL.decode(packed), d.count == 64 else { return nil }
        self.init(signKey: Data(d.prefix(32)), agreeKey: Data(d.suffix(32)))
    }

    var signingPublic: Curve25519.Signing.PublicKey? { try? .init(rawRepresentation: signKey) }
    var agreementPublic: Curve25519.KeyAgreement.PublicKey? { try? .init(rawRepresentation: agreeKey) }
}

extension FriendCard: Codable {
    private enum K: String, CodingKey { case s, a }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        guard let s = B64URL.decode(try c.decode(String.self, forKey: .s)),
              let a = B64URL.decode(try c.decode(String.self, forKey: .a)),
              let card = FriendCard(signKey: s, agreeKey: a) else {
            throw DecodingError.dataCorruptedError(forKey: .s, in: c, debugDescription: "not a friend card")
        }
        self = card
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(B64URL.encode(signKey), forKey: .s)
        try c.encode(B64URL.encode(agreeKey), forKey: .a)
    }
}

/// Your Friends account: the seed and the keys from it.
struct FriendIdentity {
    static let seedBytes = 16
    let seed: Data
    let signing: Curve25519.Signing.PrivateKey
    let agreement: Curve25519.KeyAgreement.PrivateKey
    let vaultKey: SymmetricKey
    let account: String

    init?(seed: Data) {
        guard seed.count == Self.seedBytes else { return nil }
        let sign = Self.derive(seed, "sign"), agree = Self.derive(seed, "agree")
        guard let s = try? Curve25519.Signing.PrivateKey(rawRepresentation: sign),
              let a = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: agree) else { return nil }
        self.seed = seed
        signing = s
        agreement = a
        vaultKey = SymmetricKey(data: Self.derive(seed, "vault"))
        account = Self.accountId(signKey: s.publicKey.rawRepresentation)
    }

    /// A new account: 16 random bytes.
    static func random() -> FriendIdentity {
        let seed = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        return FriendIdentity(seed: seed)!
    }

    /// From the backup code's words (nil: not a valid code).
    init?(words: [String]) {
        guard let seed = FriendWords.decode(words) else { return nil }
        self.init(seed: seed)
    }

    var words: [String] { FriendWords.encode(seed) }

    var card: FriendCard {
        FriendCard(signKey: signing.publicKey.rawRepresentation, agreeKey: agreement.publicKey.rawRepresentation)!
    }

    static func derive(_ seed: Data, _ info: String) -> Data {
        let k = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: seed), salt: Data("haltewekker-seed-v1".utf8),
                                       info: Data(info.utf8), outputByteCount: 32)
        return k.withUnsafeBytes { Data($0) }
    }

    static func accountId(signKey: Data) -> String {
        let digest = SHA256.hash(data: Data("haltewekker-account-v1".utf8) + signKey)
        return Data(digest).prefix(16).hexString
    }

    /// Is this a well-formed account id (32 hex)?
    static func isAccount(_ s: String) -> Bool {
        s.count == 32 && s.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }
}

/// How a request to the relay is signed (the relay's friends.js checks it the same way).
enum RelaySign {
    /// "HW1\n" + method + "\n" + path + "\n" + account + "\n" + device + "\n" + time + "\n" + nonce + "\n" + hex(SHA-256(body))
    static func canonical(method: String, path: String, account: String, device: String, time: Int, nonce: String, body: Data) -> String {
        let hash = Data(SHA256.hash(data: body)).hexString
        return ["HW1", method, path, account, device, String(time), nonce, hash].joined(separator: "\n")
    }

    /// 16 random bytes, base64url (22 characters).
    static func nonce() -> String { B64URL.encode(SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }) }

    /// A phone's id for the relay (one phone at a time per account): 16 random bytes in hex.
    static func newDevice() -> String { SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }.hexString }

    /// The headers of a signed POST.
    static func headers(_ me: FriendIdentity, device: String, path: String, body: Data, time: Int, nonce: String) throws -> [String: String] {
        let text = canonical(method: "POST", path: path, account: me.account, device: device, time: time, nonce: nonce, body: body)
        let sig = try me.signing.signature(for: Data(text.utf8))
        return [
            "X-HW-Account": me.account,
            "X-HW-Device": device,
            "X-HW-Time": String(time),
            "X-HW-Nonce": nonce,
            "X-HW-Signature": B64URL.encode(sig),
            "Content-Type": "application/json",
        ]
    }
}
