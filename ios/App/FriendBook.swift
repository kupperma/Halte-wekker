import Foundation

// Friends (0.25): your friend list and what happens to it, as plain values (tested without the relay or the UI).
// Each change hands back what to send (`Effect`); FriendStore locks and sends those.

struct Friend: Codable, Equatable, Identifiable {
    var card: FriendCard
    var name: String
    var since: Date
    /// (0.26) "Show my trips" to this friend: nil is the default, on. Kept in the vault as `"trips": false` when off.
    var trips: Bool? = nil
    var id: String { card.account }
    var showsTrips: Bool { trips ?? true }
}

/// A request waiting: one you got (incoming) or one you sent (outgoing).
struct FriendRequest: Codable, Equatable, Identifiable {
    var card: FriendCard
    var name: String
    var at: Date
    var id: String { card.account }
}

struct FriendBook: Codable, Equatable {
    var v = 1
    var myName: String
    var friends: [Friend] = []
    var incoming: [FriendRequest] = []
    var outgoing: [FriendRequest] = []

    enum Effect: Equatable {
        case send(FriendCard, FriendMessage)
        /// Delete the boxes between you and this account on the relay (both ways).
        case drop(String)
        /// Refuse this account's boxes from now on.
        case block(String)
    }

    /// The result of opening someone's code or link.
    enum Added: Equatable { case sent, alreadyFriends, accepted, yourself, alreadyAsked }

    init(myName: String) { self.myName = FriendNames.clean(myName) }

    func friend(_ id: String) -> Friend? { friends.first { $0.id == id } }
    func isFriend(_ id: String) -> Bool { friend(id) != nil }

    /// A known card by account: friends, then the requests either way.
    func card(_ id: String) -> FriendCard? {
        friend(id)?.card ?? incoming.first { $0.id == id }?.card ?? outgoing.first { $0.id == id }?.card
    }

    private func me(_ c: FriendCard) -> FriendIntro { FriendIntro(card: c, name: myName) }

    // MARK: what you do

    /// You opened someone's code: a request to them (or, if they asked you already, you're friends now).
    mutating func add(_ card: FriendCard, name: String, myCard: FriendCard, now: Date) -> (Added, [Effect]) {
        let id = card.account
        if id == myCard.account { return (.yourself, []) }
        if isFriend(id) { return (.alreadyFriends, []) }
        if let r = incoming.first(where: { $0.id == id }) {
            return (.accepted, accept(r.id, myCard: myCard, now: now))
        }
        let n = FriendNames.clean(name)
        if let i = outgoing.firstIndex(where: { $0.id == id }) {
            // asked before: ask again (their phone may have missed it), keeping the newest card and name
            outgoing[i].card = card
            if !n.isEmpty { outgoing[i].name = n }
            outgoing[i].at = now
            return (.alreadyAsked, [.send(card, .request(me(myCard)))])
        }
        outgoing.append(FriendRequest(card: card, name: n.isEmpty ? "Friend" : n, at: now))
        return (.sent, [.send(card, .request(me(myCard)))])
    }

    mutating func accept(_ id: String, myCard: FriendCard, now: Date) -> [Effect] {
        guard let r = incoming.first(where: { $0.id == id }) else { return [] }
        incoming.removeAll { $0.id == id }
        outgoing.removeAll { $0.id == id }
        if !isFriend(id) { friends.append(Friend(card: r.card, name: r.name, since: now)) }
        return [.send(r.card, .accept(me(myCard)))]
    }

    /// Say no (quietly: they aren't told). `block`: their boxes are refused from now on.
    mutating func decline(_ id: String, block: Bool) -> [Effect] {
        guard incoming.contains(where: { $0.id == id }) else { return [] }
        incoming.removeAll { $0.id == id }
        return block ? [.block(id)] : [.drop(id)]
    }

    /// Take back a request you sent.
    mutating func cancel(_ id: String) -> [Effect] {
        guard let r = outgoing.first(where: { $0.id == id }) else { return [] }
        outgoing.removeAll { $0.id == id }
        return [.drop(id), .send(r.card, .unfriend)]
    }

    /// Remove a friend: their keys go, the boxes between you go, and their app is told to forget you too.
    mutating func remove(_ id: String) -> [Effect] {
        guard let f = friend(id) else { return [] }
        friends.removeAll { $0.id == id }
        return [.drop(id), .send(f.card, .unfriend)]
    }

    /// (0.26) "Show my trips" to one friend, on or off (on is kept as the default, nil).
    mutating func showTrips(_ id: String, _ on: Bool) {
        guard let i = friends.firstIndex(where: { $0.id == id }) else { return }
        friends[i].trips = on ? nil : false
    }

    /// Your new name, to every friend.
    mutating func rename(_ name: String) -> [Effect] {
        let n = FriendNames.clean(name)
        guard !n.isEmpty, n != myName else { return [] }
        myName = n
        return friends.map { .send($0.card, .profile(FriendProfile(name: n))) }
    }

    // MARK: what arrives

    /// A box from `card` (already opened and checked). Returns what to send back, and whether to tell you
    /// ("Sam wants to be friends", "Sam accepted").
    mutating func receive(_ m: FriendMessage, from card: FriendCard, myCard: FriendCard, now: Date) -> (effects: [Effect], news: News?) {
        let id = card.account
        guard id != myCard.account else { return ([], nil) }
        switch m {
        case .request(let intro):
            let n = FriendNames.clean(intro.name)
            if let i = friends.firstIndex(where: { $0.id == id }) {
                // already friends (they lost their list, or asked twice): say yes again
                friends[i].card = intro.card
                if !n.isEmpty { friends[i].name = n }
                return ([.send(intro.card, .accept(me(myCard)))], nil)
            }
            if outgoing.contains(where: { $0.id == id }) {
                // you both asked: friends
                outgoing.removeAll { $0.id == id }
                incoming.removeAll { $0.id == id }
                friends.append(Friend(card: intro.card, name: n.isEmpty ? "Friend" : n, since: now))
                return ([.send(intro.card, .accept(me(myCard)))], .accepted(n))
            }
            if let i = incoming.firstIndex(where: { $0.id == id }) {
                incoming[i].card = intro.card
                if !n.isEmpty { incoming[i].name = n }
                incoming[i].at = now
                return ([], nil)
            }
            incoming.append(FriendRequest(card: intro.card, name: n.isEmpty ? "Someone" : n, at: now))
            return ([], .request(n.isEmpty ? "Someone" : n))
        case .accept(let intro):
            let n = FriendNames.clean(intro.name)
            if let i = friends.firstIndex(where: { $0.id == id }) {
                friends[i].card = intro.card
                if !n.isEmpty { friends[i].name = n }
                return ([], nil)
            }
            // only an answer to a request you sent
            guard let r = outgoing.first(where: { $0.id == id }) else { return ([], nil) }
            outgoing.removeAll { $0.id == id }
            incoming.removeAll { $0.id == id }
            let name = n.isEmpty ? r.name : n
            friends.append(Friend(card: intro.card, name: name, since: now))
            return ([], .accepted(name))
        case .unfriend:
            friends.removeAll { $0.id == id }
            incoming.removeAll { $0.id == id }
            outgoing.removeAll { $0.id == id }
            return ([], nil)
        case .profile(let p):
            let n = FriendNames.clean(p.name)
            guard !n.isEmpty, let i = friends.firstIndex(where: { $0.id == id }) else { return ([], nil) }
            friends[i].name = n
            return ([], nil)
        case .picture, .travel, .message, .trip, .seen, .group, .groupPicture, .groupLeave, .timetable, .area, .unknown:
            // (a picture is kept beside the list, by FriendInbox; chats and groups are FriendInbox's too; nothing here
            // changes)
            return ([], nil)
        }
    }

    enum News: Equatable {
        case request(String)
        case accepted(String)
    }

    /// Friends A to Z.
    var sortedFriends: [Friend] {
        friends.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

enum FriendNames {
    static let maxLength = 40

    /// A name as shown and sent: trimmed, single spaces, no control characters, at most 40 characters.
    static func clean(_ s: String) -> String {
        // Whitespace first (tabs and newlines are control characters too, and must become a space, not vanish).
        let words: [Substring] = s.split(whereSeparator: { $0.isWhitespace })
        let kept: [String] = words.map { word in
            String(String.UnicodeScalarView(word.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        }
        let one: String = kept.filter { !$0.isEmpty }.joined(separator: " ")
        return String(one.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
    }

    /// "SJ" for "Sam Jansen", "S" for "Sam".
    static func initials(_ name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let s = parts.compactMap { $0.first.map { String($0).uppercased() } }.joined()
        return s.isEmpty ? "?" : s
    }
}

/// The friend code as a link or QR code: `haltewekker://friend?v=1&k=<both keys>&n=<name>`, or the same fields after
/// the # of `https://<relay>/add#v=1&k=…&n=…` (a page that opens the app; the fields never reach the server).
enum FriendLink {
    static let page = "https://haltewekker-relay.tsfaw1.workers.dev/add"

    /// Only letters, digits and "-._~" stay as they are; everything else is %-encoded (UTF-8).
    private static let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    static func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: plain) ?? "" }

    static func fields(_ card: FriendCard, name: String) -> String {
        "v=1&k=\(card.packed)&n=\(encode(FriendNames.clean(name)))"
    }

    static func app(_ card: FriendCard, name: String) -> URL { URL(string: "haltewekker://friend?" + fields(card, name: name))! }
    static func share(_ card: FriendCard, name: String) -> URL { URL(string: page + "#" + fields(card, name: name))! }

    /// A card and name from either form (or nil: not a friend code).
    static func parse(_ text: String) -> (card: FriendCard, name: String)? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URLComponents(string: t) else { return nil }
        let query: String?
        if u.scheme?.lowercased() == "haltewekker", u.host?.lowercased() == "friend" {
            query = u.percentEncodedQuery
        } else if u.scheme?.lowercased() == "https", u.path == "/add", u.host?.lowercased().hasSuffix("workers.dev") == true {
            query = u.percentEncodedFragment
        } else { return nil }
        var items: [String: String] = [:]
        for pair in (query ?? "").split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { continue }
            let raw = String(kv[1]).replacingOccurrences(of: "+", with: " ")
            items[String(kv[0])] = raw.removingPercentEncoding ?? raw
        }
        func v(_ k: String) -> String? { items[k] }
        guard (v("v") ?? "1") == "1", let k = v("k"), let card = FriendCard(packed: k) else { return nil }
        return (card, FriendNames.clean(v("n") ?? ""))
    }
}
