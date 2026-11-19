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
    /// (0.27) The groups you're in (their lists; not their chats or pictures).
    var groups: [FriendGroup]? = nil
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
    /// (0.27) The chat line this box carries (its id), so it shows as sent once it went.
    var line: String? = nil
}

enum FriendInbox {
    /// (0.27) Something for a chat, in the order it came.
    struct ChatIn: Equatable {
        enum What: Equatable {
            case line(ChatMessage)
            /// How far `from` got and read your lines there.
            case seen(ChatSeen, from: String)
        }
        var chat: String
        var what: What
    }

    struct Result: Equatable {
        var book: FriendBook
        var effects: [FriendBook.Effect] = []
        var news: [FriendBook.News] = []
        /// Boxes read (or unreadable for good): the relay may delete them.
        var ack: [Int] = []
        /// Boxes of a kind this version doesn't know: left on the relay for a newer app.
        var kept: [Int] = []
        /// Profile pictures that came, by account (for someone in the list: a friend or a request either way; or
        /// someone in a group with you).
        var pictures: [String: Data] = [:]
        // 0.27
        var groups: GroupBook = GroupBook()
        var groupNews: [GroupBook.News] = []
        /// Group pictures that came, by group id (empty: taken away).
        var groupPictures: [String: Data] = [:]
        var chat: [ChatIn] = []
        /// Boxes that can't be opened yet: from someone this phone has no key for (a group's list that brings it may
        /// still come). Kept on the phone (taken off the relay) and tried again with the next batch, for a week.
        var orphans: [RelayBox] = []
        /// Groups whose list changed (their pictures may be due to new members).
        var groupsChanged: Set<String> = []
    }

    /// How long a box nobody has the key for yet is kept on this phone.
    static let orphanDays = 7
    static let maxOrphans = 100

    /// Reads `boxes` (in the relay's order) into `book` and `groups`; `retry`: boxes kept from before that couldn't be
    /// opened then (they're off the relay already). A group's list, a leave and everything about the friend list go
    /// first, then the chat lines, so a list that came in the same batch is known before the lines it lets in.
    static func process(_ boxes: [RelayBox], book: FriendBook, groups: GroupBook = GroupBook(), retry: [RelayBox] = [],
                        me: FriendIdentity, now: Date) -> Result {
        var r = Result(book: book, groups: groups)
        enum Later { case opened(OpenedBox, RelayBox, Bool), raw(RelayBox, Bool) }
        var later: [Later] = []
        let all: [(RelayBox, Bool)] = retry.map { ($0, true) } + boxes.map { ($0, false) }
        for (box, old) in all {
            guard let data = B64URL.decode(box.data) else { if !old { r.ack.append(box.id) }; continue }
            do {
                let current = r
                let opened = try FriendBox.open(data, me: me, from: box.from, known: { current.book.card($0) ?? current.groups.card($0) })
                if opened.message.isChat { later.append(.opened(opened, box, old)); continue }
                control(opened, box: box, old: old, into: &r, me: me, now: now)
            } catch FriendBoxError.newerVersion {
                if !old { r.kept.append(box.id) }
            } catch FriendBoxError.unknownSender {
                later.append(.raw(box, old))
            } catch {
                // not for us, broken, or from someone who isn't a friend (and not asking to be one)
                if !old { r.ack.append(box.id) }
            }
        }
        let weekAgo = Int(now.timeIntervalSince1970) - orphanDays * 86400
        for item in later {
            switch item {
            case .opened(let o, let box, let old):
                chat(o, box: box, into: &r, me: me, now: now)
                if !old { r.ack.append(box.id) }
            case .raw(let box, let old):
                if !old { r.ack.append(box.id) }
                guard let data = B64URL.decode(box.data) else { continue }
                let current = r
                do {
                    let o = try FriendBox.open(data, me: me, from: box.from, known: { current.book.card($0) ?? current.groups.card($0) })
                    if o.message.isChat { chat(o, box: box, into: &r, me: me, now: now) } else { control(o, box: box, old: true, into: &r, me: me, now: now) }
                } catch FriendBoxError.unknownSender {
                    if box.at >= weekAgo { r.orphans.append(box) }
                } catch {}
            }
        }
        if r.orphans.count > maxOrphans { r.orphans = Array(r.orphans.suffix(maxOrphans)) }
        return r
    }

    /// Everything but a chat line: the friend list, pictures, a group's list, picture or leave.
    private static func control(_ opened: OpenedBox, box: RelayBox, old: Bool, into r: inout Result, me: FriendIdentity, now: Date) {
        let id = opened.sender.account
        let g = opened.header.g
        switch opened.message {
        case .unknown:
            if !old { r.kept.append(box.id) }
            return
        case .picture(let p):
            if r.book.card(id) != nil || r.groups.shares(id), p.jpeg.count <= FriendPicture.maxBytes, !p.jpeg.isEmpty { r.pictures[id] = p.jpeg }
        case .group(let roster):
            if let g {
                let b: FriendBook = r.book
                let name: String = b.friend(id)?.name ?? roster.member(id)?.name ?? "Someone"
                let got = r.groups.receive(roster, id: g, from: id, me: me.account, isFriend: { b.isFriend($0) },
                                           senderName: name, now: now)
                if got.accepted { r.groupsChanged.insert(g) }
                if let n = got.news { r.groupNews.append(n) }
                for (k, line) in got.notes.enumerated() { note(line, group: g, n: "\(opened.header.n).\(k)", into: &r, now: now) }
            }
        case .groupPicture(let p):
            if let g, r.groups.acceptsPicture(g, from: id), p.jpeg.count <= FriendPicture.maxBytes { r.groupPictures[g] = p.jpeg }
        case .groupLeave:
            if let g, let line = r.groups.receiveLeave(g, from: id, me: me.account) {
                r.groupsChanged.insert(g)
                note(line, group: g, n: opened.header.n, into: &r, now: now)
            }
        case .travel, .message, .trip, .seen:
            break
        case .request, .accept, .unfriend, .profile:
            let (effects, news) = r.book.receive(opened.message, from: opened.sender, myCard: me.card, now: now)
            r.effects += effects
            if let news { r.news.append(news) }
        }
        if !old { r.ack.append(box.id) }
    }

    private static func note(_ text: String, group g: String, n: String, into r: inout Result, now: Date) {
        let m = ChatMessage(id: ChatMessage.id(from: "", n: n), from: "", n: n, t: Int(now.timeIntervalSince1970), at: now, content: .note(text))
        r.chat.append(ChatIn(chat: ChatKey.group(g), what: .line(m)))
    }

    /// A chat line or mark: in a group only from someone on its list (while you're in it), else only from a friend.
    private static func chat(_ o: OpenedBox, box: RelayBox, into r: inout Result, me: FriendIdentity, now: Date) {
        let from = o.sender.account
        guard from != me.account else { return }
        let key: String
        if let g = o.header.g {
            guard r.groups.accepts(g, from: from) else { return }
            key = ChatKey.group(g)
        } else {
            guard r.book.isFriend(from) else { return }
            key = ChatKey.friend(from)
        }
        let content: ChatMessage.Content
        switch o.message {
        case .message(let t):
            let text = ChatText.clean(t.text)
            let answer = t.answer.flatMap(TripAnswer.init(rawValue:))
            guard !text.isEmpty || answer != nil else { return }
            content = .text(ChatText(text: text.isEmpty ? (answer?.text ?? "") : text, re: answer == nil ? nil : t.re, answer: answer?.rawValue))
        case .trip(let c):
            guard let c = TripCard.valid(c) else { return }
            content = .trip(c)
        case .seen(let s):
            r.chat.append(ChatIn(chat: key, what: .seen(s, from: from)))
            return
        default:
            return
        }
        let m = ChatMessage(id: ChatMessage.id(from: from, n: o.header.n), from: from, n: o.header.n, t: o.header.t, at: now, content: content)
        r.chat.append(ChatIn(chat: key, what: .line(m)))
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
