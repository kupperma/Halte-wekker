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
// 0.26 adds travel (sent through the state routes, not the mailbox); 0.27 message, trip, seen and the group kinds (group,
// gpicture, gleave; a group's boxes carry `g` and are locked once per member); 0.28 timetable and area (slots `tt` and
// `area`). New kinds only add a case and a body: an app that
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
    /// (0.26) Your trip right now, to a friend you show your trips to: through the relay's state routes (the newest
    /// replaces the last; taken back when the trip ends), never the mailbox.
    case travel(TravelState)
    /// (0.27) A line in a chat (one-to-one, or in a group with the header's `g`), or an answer to a trip card.
    case message(ChatText)
    /// (0.27) A trip to take together.
    case trip(TripCard)
    /// (0.27) How far you got and read the recipient's lines in that chat (slot `seen`; a group: `se.<id>`).
    case seen(ChatSeen)
    /// (0.27) A group's list (from the one who runs it; slot `gr.<id>`).
    case group(GroupRoster)
    /// (0.27) A group's picture (from the one who runs it; slot `gp.<id>`); an empty one takes it away.
    case groupPicture(FriendPicture)
    /// (0.27) The sender left the group.
    case groupLeave
    /// (0.28) Your class timetable for the next two weeks (slot `tt`), or taking it back (`off`).
    case timetable(TimetableShare)
    /// (0.28) Where your trips start and your school (slot `area`): never your home address.
    case area(TimetableArea)
    /// A kind this version doesn't know (from a newer app).
    case unknown(String)

    var kind: String {
        switch self {
        case .request: return "request"
        case .accept: return "accept"
        case .unfriend: return "unfriend"
        case .profile: return "profile"
        case .picture: return "picture"
        case .travel: return "travel"
        case .message: return "message"
        case .trip: return "trip"
        case .seen: return "seen"
        case .group: return "group"
        case .groupPicture: return "gpicture"
        case .groupLeave: return "gleave"
        case .timetable: return "timetable"
        case .area: return "area"
        case .unknown(let k): return k
        }
    }

    /// The kinds this version reads (and acknowledges, so the relay drops them).
    static let known: Set<String> = ["request", "accept", "unfriend", "profile", "picture", "travel",
                                     "message", "trip", "seen", "group", "gpicture", "gleave", "timetable", "area"]
    /// Raised whenever a release learns new kinds: boxes left on the relay are read again from the start once.
    /// (2: 0.26, travel. 3: 0.27, messages, trips and groups. 4: 0.28, timetables and areas.)
    static let kindsVersion = 4

    /// The kinds that belong to a chat (read after the rest of a batch, so a group's list that came in the same batch
    /// is known first).
    var isChat: Bool {
        switch self {
        case .message, .trip, .seen: return true
        default: return false
        }
    }
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
    /// A plain JPEG (base64url in the JSON, through FriendJSON).
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

    /// `group`: the header's `g` (a group's line, list, picture or leave).
    static func payload(_ m: FriendMessage, from: String, at: Date, id: String, group: String? = nil) throws -> Data {
        let e = FriendJSON.encoder
        let t = Int(at.timeIntervalSince1970)
        let k = m.kind
        let v = payloadVersion
        let g = group
        switch m {
        case .request(let b), .accept(let b):
            return try e.encode(BoxEnvelope(v: v, k: k, f: from, t: t, n: id, g: g, b: b))
        case .profile(let b):
            return try e.encode(BoxEnvelope(v: v, k: k, f: from, t: t, n: id, g: g, b: b))
        case .picture(let b), .groupPicture(let b):
            return try e.encode(BoxEnvelope(v: v, k: k, f: from, t: t, n: id, g: g, b: b))
        case .travel(let b):
            return try e.encode(BoxEnvelope(v: v, k: k, f: from, t: t, n: id, g: g, b: b))
        case .message(let b):
            return try e.encode(BoxEnvelope(v: v, k: k, f: from, t: t, n: id, g: g, b: b))
        case .trip(let b):
            return try e.encode(BoxEnvelope(v: v, k: k, f: from, t: t, n: id, g: g, b: b))
        case .seen(let b):
            return try e.encode(BoxEnvelope(v: v, k: k, f: from, t: t, n: id, g: g, b: b))
        case .group(let b):
            return try e.encode(BoxEnvelope(v: v, k: k, f: from, t: t, n: id, g: g, b: b))
        case .timetable(let b):
            return try e.encode(BoxEnvelope(v: v, k: k, f: from, t: t, n: id, g: g, b: b))
        case .area(let b):
            return try e.encode(BoxEnvelope(v: v, k: k, f: from, t: t, n: id, g: g, b: b))
        case .unfriend, .groupLeave, .unknown:
            return try e.encode(BoxEnvelope(v: v, k: k, f: from, t: t, n: id, g: g, b: NoBody()))
        }
    }

    static func parse(_ data: Data) throws -> (BoxHeader, FriendMessage) {
        let d = FriendJSON.decoder
        guard let h = try? d.decode(BoxHeader.self, from: data) else { throw FriendBoxError.badFormat }
        guard h.v <= payloadVersion else { throw FriendBoxError.newerVersion }
        do {
            switch h.k {
            case "request": return (h, .request(try d.decode(BoxEnvelope<FriendIntro>.self, from: data).b))
            case "accept": return (h, .accept(try d.decode(BoxEnvelope<FriendIntro>.self, from: data).b))
            case "unfriend": return (h, .unfriend)
            case "profile": return (h, .profile(try d.decode(BoxEnvelope<FriendProfile>.self, from: data).b))
            case "picture": return (h, .picture(try d.decode(BoxEnvelope<FriendPicture>.self, from: data).b))
            case "travel": return (h, .travel(try d.decode(BoxEnvelope<TravelState>.self, from: data).b))
            case "message": return (h, .message(try d.decode(BoxEnvelope<ChatText>.self, from: data).b))
            case "trip": return (h, .trip(try d.decode(BoxEnvelope<TripCard>.self, from: data).b))
            case "seen": return (h, .seen(try d.decode(BoxEnvelope<ChatSeen>.self, from: data).b))
            case "group": return (h, .group(try d.decode(BoxEnvelope<GroupRoster>.self, from: data).b))
            case "gpicture": return (h, .groupPicture(try d.decode(BoxEnvelope<FriendPicture>.self, from: data).b))
            case "gleave": return (h, .groupLeave)
            case "timetable": return (h, .timetable(try d.decode(BoxEnvelope<TimetableShare>.self, from: data).b))
            case "area": return (h, .area(try d.decode(BoxEnvelope<TimetableArea>.self, from: data).b))
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
                     id: String = RelaySign.nonce(), group: String? = nil) throws -> Data {
        try seal(payload: payload(m, from: me.account, at: at, id: id, group: group), from: me, to: card)
    }

    /// Locks a payload already written (the test vectors pass the ephemeral key and the nonce).
    static func seal(payload p: Data, from me: FriendIdentity, to card: FriendCard,
                     eph: Curve25519.KeyAgreement.PrivateKey = .init(), nonce: ChaChaPoly.Nonce = .init()) throws -> Data {
        let sig = try me.signing.signature(for: signed(p, to: card.account))
        return try lock(sig + p, to: card, eph: eph, nonce: nonce)
    }

    /// The box around a signed inside (signature ‖ payload): no randomness of its own, so it can be checked byte for
    /// byte against the test vectors.
    static func lock(_ inner: Data, to card: FriendCard, eph: Curve25519.KeyAgreement.PrivateKey,
                     nonce: ChaChaPoly.Nonce) throws -> Data {
        guard let theirs = card.agreementPublic else { throw FriendBoxError.badFormat }
        let key = try boxKey(eph.sharedSecretFromKeyAgreement(with: theirs), eph: eph.publicKey.rawRepresentation, recipient: card.agreeKey)
        let box = try ChaChaPoly.seal(inner, using: key, nonce: nonce, authenticating: Data(card.account.utf8))
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
    static func seal(_ plain: Data, me: FriendIdentity, nonce: ChaChaPoly.Nonce = .init()) throws -> Data {
        let box = try ChaChaPoly.seal(plain, using: me.vaultKey, nonce: nonce, authenticating: aad(me))
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
