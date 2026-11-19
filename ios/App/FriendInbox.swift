import Foundation

// Friends (0.25): the relay's answers, and reading a batch of boxes into the friend list. Plain values, tested.

/// A box as the relay hands it out.
struct RelayBox: Codable, Equatable {
    let id: Int
    let from: String
    let slot: String?
    let at: Int
    let exp: Int
    let data: String
}

struct RelayInbox: Codable, Equatable {
    let boxes: [RelayBox]
    let cursor: Int
    let more: Bool
}

struct RelayRegistered: Codable, Equatable {
    let account: String
    let created: Bool
    let moved: Bool
}

struct RelaySendResult: Codable, Equatable {
    let to: String
    let ok: Bool
    let id: Int?
    let error: String?
}

struct RelaySent: Codable, Equatable { let results: [RelaySendResult] }

/// (0.26) A friend's latest state as the relay hands it out (/f/v1/state/get).
struct RelayState: Codable, Equatable {
    let from: String
    let at: Int
    let exp: Int
    let data: String
}
struct RelayStates: Codable, Equatable { let states: [RelayState] }
struct RelayCleared: Codable, Equatable { let cleared: Int }
struct RelayVault: Codable, Equatable { let data: String?; let at: Int? }

/// What the vault holds (locked with the backup code's vault key): the list, and your own picture.
struct FriendVaultContents: Codable, Equatable {
    var v = 1
    var book: FriendBook
    var picture: Data?
}

/// Something to do on the relay, kept until it went through (so an accept isn't lost to a tunnel).
struct FriendPending: Codable, Equatable {
    enum Op: String, Codable { case box, drop, block }
    var op: Op
    /// The account it's for.
    var to: String
    /// A locked box (base64url), for `.box`.
    var data: String?
    /// For later releases: a latest-state slot ("travel"), and how long the relay keeps it.
    var slot: String?
    var ttl: Int?
}

enum FriendInbox {
    struct Result: Equatable {
        var book: FriendBook
        var effects: [FriendBook.Effect] = []
        var news: [FriendBook.News] = []
        /// Boxes read (or unreadable for good): the relay may delete them.
        var ack: [Int] = []
        /// Boxes of a kind this version doesn't know: left on the relay for a newer app.
        var kept: [Int] = []
        /// Profile pictures that came, by account (for someone in the list: a friend or a request either way).
        var pictures: [String: Data] = [:]
    }

    /// Reads `boxes` (in the relay's order) into `book`.
    static func process(_ boxes: [RelayBox], book: FriendBook, me: FriendIdentity, now: Date) -> Result {
        var r = Result(book: book)
        for box in boxes {
            guard let data = B64URL.decode(box.data) else { r.ack.append(box.id); continue }
            let opened: OpenedBox
            do {
                let current = r.book
                opened = try FriendBox.open(data, me: me, from: box.from, known: { current.card($0) })
            } catch FriendBoxError.newerVersion {
                r.kept.append(box.id); continue
            } catch {
                // not for us, broken, or from someone who isn't a friend (and not asking to be one)
                r.ack.append(box.id); continue
            }
            if case .unknown = opened.message { r.kept.append(box.id); continue }
            if case .picture(let p) = opened.message {
                let id = opened.sender.account
                if r.book.card(id) != nil, p.jpeg.count <= FriendPicture.maxBytes, !p.jpeg.isEmpty { r.pictures[id] = p.jpeg }
                r.ack.append(box.id)
                continue
            }
            let (effects, news) = r.book.receive(opened.message, from: opened.sender, myCard: me.card, now: now)
            r.effects += effects
            if let news { r.news.append(news) }
            r.ack.append(box.id)
        }
        return r
    }

    /// (0.26) Friends' latest states, opened: only from friends, only `travel`, only while not too old; the newest
    /// per friend. (A state that won't open is simply left: it goes by itself in minutes.)
    static func readStates(_ states: [RelayState], book: FriendBook, me: FriendIdentity, now: Date) -> [String: FriendTravelSeen] {
        var out: [String: FriendTravelSeen] = [:]
        for st in states {
            guard book.isFriend(st.from), let data = B64URL.decode(st.data) else { continue }
            guard let o = try? FriendBox.open(data, me: me, from: st.from, known: { book.friend($0)?.card }) else { continue }
            guard case .travel(let t) = o.message else { continue }
            // (their clock, signed; never later than the relay got it)
            let sent = Date(timeIntervalSince1970: TimeInterval(min(o.header.t, st.at)))
            let seen = FriendTravelSeen(from: st.from, state: t, sent: sent, exp: Date(timeIntervalSince1970: TimeInterval(st.exp)))
            guard TravelAge.freshness(seen, now: now) != .gone else { continue }
            if let had = out[st.from], had.sent >= sent { continue }
            out[st.from] = seen
        }
        return out
    }

    /// What a piece of news says, in a banner.
    static func banner(_ n: FriendBook.News) -> (title: String, body: String) {
        switch n {
        case .request(let name): return ("\(name) wants to be friends", "Open Friends to say yes or no.")
        case .accepted(let name): return ("You and \(name) are friends", "\(name) said yes to your friend request.")
        }
    }
}
