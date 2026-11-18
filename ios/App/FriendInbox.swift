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

    /// What a piece of news says, in a banner.
    static func banner(_ n: FriendBook.News) -> (title: String, body: String) {
        switch n {
        case .request(let name): return ("\(name) wants to be friends", "Open Friends to say yes or no.")
        case .accepted(let name): return ("You and \(name) are friends", "\(name) said yes to your friend request.")
        }
    }
}
