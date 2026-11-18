import Foundation
import CryptoKit

// Friends (0.25): the locked box, the only thing the relay ever holds for a friend. Foundation and CryptoKit only.
//
// A box, as bytes (sent base64url):
//   0x01 | ephemeral X25519 public key (32) | ChaChaPoly combined (nonce 12 | ciphertext | tag 16)
// key  = HKDF-SHA256(X25519(ephemeral, recipient's agreement key), salt "haltewekker-box-v1",
//                    info ephemeral public + recipient public, 32 bytes)
// AAD  = the recipient's account id (a box can't be moved to someone else's mailbox)
// The plaintext inside: the sender's Ed25519 signature (64) | the payload's JSON, signed as
//   "HWBOX1\n" + recipient account + "\n" + payload bytes
// The payload: {"v":1, "k": kind, "f": sender account, "t": unix seconds, "n": random id, "g": group id (optional,
// for the group chats to come: the same message is locked once per member and posted to all their mailboxes in one
// /f/v1/send), "b": the kind's body}.
// New kinds (0.26 travel, 0.27 message and trip, 0.28 timetable and area) only add a case and a body: an app that
// doesn't know a kind leaves that box on the relay (unacknowledged, until it expires), so a newer app can still read it.

/// What a box says. 0.25 knows these; anything else comes back as `.unknown`.
enum FriendMessage: Equatable {
    /// "Be my friend": who you are (keys and name).
    case request(FriendIntro)
    /// "Yes": the same, back.
    case accept(FriendIntro)
    /// Removed, or a request taken back: forget me.
    case unfriend
    /// A new name.
    case profile(FriendProfile)
    /// Your profile picture (a small square JPEG), kept in the relay's "picture" slot (the newest replaces the last).
    case picture(FriendPicture)
    /// A kind this version doesn't know (from a newer app).
    case unknown(String)

    var kind: String {
        switch self {
        case .request: return "request"
        case .accept: return "accept"
        case .unfriend: return "unfriend"
        case .profile: return "profile"
        case .picture: return "picture"
        case .unknown(let k): return k
        }
    }

    /// The kinds this version reads (and acknowledges, so the relay drops them).
    static let known: Set<String> = ["request", "accept", "unfriend", "profile", "picture"]
    /// Raised whenever a release learns new kinds: boxes left on the relay are read again from the start once.
    static let kindsVersion = 1
}

struct FriendIntro: Codable, Equatable {
    var card: FriendCard
    var name: String
    var note: String?
}

struct FriendProfile: Codable, Equatable {
    var name: String
}

/// A profile picture: a square JPEG (256 px), at most `maxBytes` (base64 inside the box, which the relay takes up to
/// 64 KB).
struct FriendPicture: Codable, Equatable {
    static let maxBytes = 40 * 1024
    var jpeg: Data
}

/// The payload's fields other than the body.
struct BoxHeader: Codable, Equatable {
    var v: Int
    var k: String
    var f: String
    var t: Int
    var n: String
    var g: String? = nil
}

private struct BoxEnvelope<Body: Codable>: Codable {
    var v: Int
    var k: String
    var f: String
    var t: Int
    var n: String
    var g: String? = nil
    var b: Body
}

private struct NoBody: Codable {}

enum FriendBoxError: Error, Equatable {
    case badFormat, cantOpen, badSignature, wrongSender, unknownSender, newerVersion
}

/// An opened box: who sent it (their card, checked against the signature) and what it says.
struct OpenedBox: Equatable {
    let header: BoxHeader
    let message: FriendMessage
    let sender: FriendCard
}

enum FriendBox {
    static let version: UInt8 = 1
    static let payloadVersion = 1

    // MARK: payload

    static func payload(_ m: FriendMessage, from: String, at: Date, id: String) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        let t = Int(at.timeIntervalSince1970)
        switch m {
        case .request(let b), .accept(let b):
            return try e.encode(BoxEnvelope(v: payloadVersion, k: m.kind, f: from, t: t, n: id, b: b))
        case .profile(let b):
            return try e.encode(BoxEnvelope(v: payloadVersion, k: m.kind, f: from, t: t, n: id, b: b))
        case .picture(let b):
            return try e.encode(BoxEnvelope(v: payloadVersion, k: m.kind, f: from, t: t, n: id, b: b))
        case .unfriend, .unknown:
            return try e.encode(BoxEnvelope(v: payloadVersion, k: m.kind, f: from, t: t, n: id, b: NoBody()))
        }
    }

    static func parse(_ data: Data) throws -> (BoxHeader, FriendMessage) {
        let d = JSONDecoder()
        guard let h = try? d.decode(BoxHeader.self, from: data) else { throw FriendBoxError.badFormat }
        guard h.v <= payloadVersion else { throw FriendBoxError.newerVersion }
        do {
            switch h.k {
            case "request": return (h, .request(try d.decode(BoxEnvelope<FriendIntro>.self, from: data).b))
            case "accept": return (h, .accept(try d.decode(BoxEnvelope<FriendIntro>.self, from: data).b))
            case "unfriend": return (h, .unfriend)
            case "profile": return (h, .profile(try d.decode(BoxEnvelope<FriendProfile>.self, from: data).b))
            case "picture": return (h, .picture(try d.decode(BoxEnvelope<FriendPicture>.self, from: data).b))
            default: return (h, .unknown(h.k))
            }
        } catch { throw FriendBoxError.badFormat }
    }

    // MARK: seal and open

    static func signed(_ payload: Data, to account: String) -> Data {
        Data("HWBOX1\n\(account)\n".utf8) + payload
    }

    /// Locks `m` for the friend with `card`.
    static func seal(_ m: FriendMessage, from me: FriendIdentity, to card: FriendCard, at: Date = Date(),
                     id: String = RelaySign.nonce()) throws -> Data {
        guard let theirs = card.agreementPublic else { throw FriendBoxError.badFormat }
        let p = try payload(m, from: me.account, at: at, id: id)
        let sig = try me.signing.signature(for: signed(p, to: card.account))
        let eph = Curve25519.KeyAgreement.PrivateKey()
        let key = try boxKey(eph.sharedSecretFromKeyAgreement(with: theirs), eph: eph.publicKey.rawRepresentation, recipient: card.agreeKey)
        let box = try ChaChaPoly.seal(sig + p, using: key, authenticating: Data(card.account.utf8))
        return Data([version]) + eph.publicKey.rawRepresentation + box.combined
    }

    /// Opens a box left for `me` by the account `from` (as the relay says). `known` gives a friend's card by account;
    /// a request or an accept carries its own (checked to be the sender's).
    static func open(_ data: Data, me: FriendIdentity, from: String, known: (String) -> FriendCard?) throws -> OpenedBox {
        guard data.count > 1 + 32 + 12 + 16 + 64, data.first == version else { throw FriendBoxError.badFormat }
        let eph = Data(data[data.startIndex + 1 ..< data.startIndex + 33])
        let rest = Data(data[(data.startIndex + 33)...])
        guard let ephKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: eph) else { throw FriendBoxError.badFormat }
        let inner: Data
        do {
            let key = try boxKey(me.agreement.sharedSecretFromKeyAgreement(with: ephKey), eph: eph,
                                 recipient: me.agreement.publicKey.rawRepresentation)
            inner = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: rest), using: key, authenticating: Data(me.account.utf8))
        } catch { throw FriendBoxError.cantOpen }
        guard inner.count > 64 else { throw FriendBoxError.badFormat }
        let sig = Data(inner.prefix(64))
        let p = Data(inner.dropFirst(64))
        let (h, m) = try parse(p)
        guard h.f == from else { throw FriendBoxError.wrongSender }
        let sender: FriendCard
        switch m {
        case .request(let i), .accept(let i):
            guard i.card.account == from else { throw FriendBoxError.wrongSender }
            sender = i.card
        default:
            guard let c = known(from) else { throw FriendBoxError.unknownSender }
            sender = c
        }
        guard let pub = sender.signingPublic, pub.isValidSignature(sig, for: signed(p, to: me.account)) else {
            throw FriendBoxError.badSignature
        }
        return OpenedBox(header: h, message: m, sender: sender)
    }

    private static func boxKey(_ shared: SharedSecret, eph: Data, recipient: Data) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("haltewekker-box-v1".utf8),
                                       sharedInfo: eph + recipient, outputByteCount: 32)
    }
}

/// Your friend list kept on the relay, locked with the vault key (only your backup code opens it).
///   0x01 | ChaChaPoly combined, AAD "hw-vault-v1\n" + account
enum FriendVault {
    static func seal(_ plain: Data, me: FriendIdentity) throws -> Data {
        let box = try ChaChaPoly.seal(plain, using: me.vaultKey, authenticating: aad(me))
        return Data([1]) + box.combined
    }

    static func open(_ data: Data, me: FriendIdentity) throws -> Data {
        guard data.count > 1 + 28, data.first == 1 else { throw FriendBoxError.badFormat }
        do {
            return try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: Data(data.dropFirst())), using: me.vaultKey, authenticating: aad(me))
        } catch { throw FriendBoxError.cantOpen }
    }

    private static func aad(_ me: FriendIdentity) -> Data { Data("hw-vault-v1\n\(me.account)".utf8) }
}
