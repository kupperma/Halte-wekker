import Foundation

// Friends (0.27): group chats as plain values, tested without the relay or the UI. Foundation only.
//
// A group is a name, a list of members (each with their card: both public keys) and who runs it (`admin`: the one who
// made it, until they leave). The admin sends the list (the `group` box, its `rev` one higher each time) to every
// member, in the slot `gr.<group id>`, so a phone that was away only finds the newest one. Members must be the
// admin's friends; they needn't be each other's: the list gives everyone the others' keys, so each message can be
// locked once for every member (fan-out) and checked as theirs. Only the admin changes the list; anyone can leave (a
// `gleave` box to everyone). When the admin leaves, the first member left on the list runs it.

struct GroupMember: Codable, Equatable, Identifiable {
    var card: FriendCard
    var name: String
    var id: String { card.account }
}

/// The body of a `group` box.
struct GroupRoster: Codable, Equatable {
    /// Everyone, you included.
    static let maxMembers = 20

    var name: String
    /// The account that runs the group (it's on the list).
    var admin: String
    /// One higher with each change.
    var rev: Int
    var members: [GroupMember]

    func has(_ account: String) -> Bool { members.contains { $0.id == account } }
    func member(_ account: String) -> GroupMember? { members.first { $0.id == account } }

    /// As kept: names cleaned, each account once, the admin on it, 1–20 members. Nil: not a list to take.
    static func valid(_ r: GroupRoster) -> GroupRoster? {
        var seen = Set<String>()
        var members: [GroupMember] = []
        for m in r.members where m.card.signingPublic != nil && m.card.agreementPublic != nil && seen.insert(m.id).inserted {
            let n = FriendNames.clean(m.name)
            members.append(GroupMember(card: m.card, name: n.isEmpty ? "Someone" : n))
        }
        guard !members.isEmpty, members.count <= maxMembers, seen.contains(r.admin), r.rev >= 1 else { return nil }
        let name = FriendNames.clean(r.name)
        return GroupRoster(name: name.isEmpty ? "Group" : name, admin: r.admin, rev: r.rev, members: members)
    }
}

struct FriendGroup: Codable, Equatable, Identifiable {
    enum Out: String, Codable {
        /// You left: nothing from it is taken any more (to come back, someone makes a new group).
        case left
        /// The admin took you off the list (they may put you back).
        case removed
    }

    var id: String
    var roster: GroupRoster
    var since: Date
    var out: Out? = nil

    var isIn: Bool { out == nil }
    var name: String { roster.name }
    func isAdmin(_ me: String) -> Bool { isIn && roster.admin == me }
    /// The other members.
    func others(_ me: String) -> [GroupMember] { roster.members.filter { $0.id != me } }
}

struct GroupBook: Codable, Equatable {
    var groups: [FriendGroup] = []

    /// A box to lock for one member and send (with `g` = the group's id).
    struct Send: Equatable {
        var to: FriendCard
        var message: FriendMessage
        var group: String
        var slot: String?
    }

    /// Something to tell you outside the chat (a banner).
    enum News: Equatable {
        case added(group: String, by: String)
        case removed(group: String)
    }

    struct Received: Equatable {
        var accepted = false
        /// Lines for the group's chat ("Sam added Lou").
        var notes: [String] = []
        var news: News?
    }

    static func rosterSlot(_ id: String) -> String { "gr.\(id)" }
    static func pictureSlot(_ id: String) -> String { "gp.\(id)" }
    static func seenSlot(_ id: String) -> String { "se.\(id)" }

    /// A new group's id: 12 random bytes, 24 lowercase hex characters (so `gr.<id>` fits the relay's 32-character slot).
    static func newId() -> String {
        (0..<12).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    static func isId(_ s: String) -> Bool {
        s.count == 24 && s.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    func group(_ id: String) -> FriendGroup? { groups.first { $0.id == id } }
    private func index(_ id: String) -> Int? { groups.firstIndex { $0.id == id } }

    /// The groups you're in, by name.
    var current: [FriendGroup] {
        groups.filter(\.isIn).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Groups to show (in, or taken off: their chat stays to read), not the ones you left.
    var shown: [FriendGroup] { groups.filter { $0.out != .left } }

    /// A member's card from the groups you're in (to check what they write there).
    func card(_ account: String) -> FriendCard? {
        for g in groups where g.isIn { if let m = g.roster.member(account) { return m.card } }
        return nil
    }

    /// Someone you share a group with (you both on its list).
    func shares(_ account: String) -> Bool { groups.contains { $0.isIn && $0.roster.has(account) } }

    /// The name a group gives someone (the first group that has them).
    func name(_ account: String) -> String? {
        for g in groups where g.isIn { if let m = g.roster.member(account) { return m.name } }
        return nil
    }

    /// May `from` write in group `id` (and you read it)?
    func accepts(_ id: String, from: String) -> Bool {
        guard let g = group(id), g.isIn else { return false }
        return g.roster.has(from)
    }

    // MARK: what you do

    private func rosterSends(_ g: FriendGroup, me: String, extra: [GroupMember] = []) -> [Send] {
        (g.others(me) + extra).map { Send(to: $0.card, message: .group(g.roster), group: g.id, slot: Self.rosterSlot(g.id)) }
    }

    /// A new group of your friends, run by you. Nil: nobody (or too many) to put in it.
    mutating func create(id: String, name: String, friends: [Friend], me: FriendCard, myName: String, now: Date) -> (FriendGroup, [Send])? {
        var members = [GroupMember(card: me, name: myName.isEmpty ? "Me" : myName)]
        for f in friends where f.id != me.account && !members.contains(where: { $0.id == f.id }) {
            members.append(GroupMember(card: f.card, name: f.name))
        }
        guard members.count >= 2, members.count <= GroupRoster.maxMembers, group(id) == nil else { return nil }
        let n = FriendNames.clean(name)
        let r = GroupRoster(name: n.isEmpty ? "Group" : n, admin: me.account, rev: 1, members: members)
        guard let roster = GroupRoster.valid(r) else { return nil }
        let g = FriendGroup(id: id, roster: roster, since: now)
        groups.append(g)
        return (g, rosterSends(g, me: me.account))
    }

    /// (the admin) More friends in.
    mutating func add(_ id: String, friends: [Friend], me: String) -> [Send] {
        guard let i = index(id), groups[i].isAdmin(me) else { return [] }
        var r = groups[i].roster
        for f in friends where !r.has(f.id) && r.members.count < GroupRoster.maxMembers {
            r.members.append(GroupMember(card: f.card, name: f.name))
        }
        guard r.members.count != groups[i].roster.members.count else { return [] }
        r.rev += 1
        groups[i].roster = r
        return rosterSends(groups[i], me: me)
    }

    /// (the admin) Someone off the list: the others get the new list, and so do they (so they know).
    mutating func remove(_ id: String, member: String, me: String) -> [Send] {
        guard let i = index(id), groups[i].isAdmin(me), member != me, let gone = groups[i].roster.member(member) else { return [] }
        groups[i].roster.members.removeAll { $0.id == member }
        groups[i].roster.rev += 1
        return rosterSends(groups[i], me: me, extra: [gone])
    }

    /// (the admin) A new name.
    mutating func rename(_ id: String, to name: String, me: String) -> [Send] {
        let n = FriendNames.clean(name)
        guard let i = index(id), groups[i].isAdmin(me), !n.isEmpty, n != groups[i].roster.name else { return [] }
        groups[i].roster.name = n
        groups[i].roster.rev += 1
        return rosterSends(groups[i], me: me)
    }

    /// (the admin) The group's picture to everyone (an empty one takes it away).
    func pictureSends(_ id: String, jpeg: Data, me: String, only: Set<String>? = nil) -> [Send] {
        guard let g = group(id), g.isAdmin(me) else { return [] }
        return g.others(me).filter { only?.contains($0.id) ?? true }
            .map { Send(to: $0.card, message: .groupPicture(FriendPicture(jpeg: jpeg)), group: id, slot: Self.pictureSlot(id)) }
    }

    /// You leave: everyone is told; nothing from the group is taken from now on.
    mutating func leave(_ id: String, me: String) -> [Send] {
        guard let i = index(id) else { return [] }
        let wasIn = groups[i].isIn
        let others = groups[i].others(me)
        groups[i].out = .left
        guard wasIn else { return [] }
        return others.map { Send(to: $0.card, message: .groupLeave, group: id, slot: nil) }
    }

    /// Off this phone (a group you left or were taken off; its chat goes with it). A group you left stays known as
    /// left, so an old list still on its way doesn't put you back in.
    mutating func forget(_ id: String) {
        guard let i = index(id) else { return }
        if groups[i].out == .left { return }
        groups.remove(at: i)
    }

    /// (the admin) Your friends' new names on the lists you run, and yours: the lists that changed, to everyone.
    mutating func refreshNames(friends: [Friend], me: String, myName: String) -> [Send] {
        var sends: [Send] = []
        for i in groups.indices where groups[i].isAdmin(me) {
            var r = groups[i].roster
            var changed = false
            for k in r.members.indices {
                let who: String = r.members[k].id
                let want: String?
                if who == me { want = myName.isEmpty ? nil : myName } else { want = friends.first(where: { $0.id == who })?.name }
                if let w = want, w != r.members[k].name { r.members[k].name = w; changed = true }
            }
            guard changed else { continue }
            r.rev += 1
            groups[i].roster = r
            sends += rosterSends(groups[i], me: me)
        }
        return sends
    }

    // MARK: what arrives

    /// A list from `from`. A new group only from a friend who runs it, with you on it; a known one only from the one
    /// who runs it now, and only a newer one (`rev`). Not on it any more: you were taken off.
    mutating func receive(_ incoming: GroupRoster, id: String, from: String, me: String, isFriend: (String) -> Bool,
                          senderName: String, now: Date) -> Received {
        var out = Received()
        guard Self.isId(id), let r = GroupRoster.valid(incoming), r.has(from) else { return out }
        guard let i = index(id) else {
            guard r.admin == from, isFriend(from), r.has(me) else { return out }
            groups.append(FriendGroup(id: id, roster: r, since: now))
            out.accepted = true
            out.notes = ["\(senderName) added you"]
            out.news = .added(group: r.name, by: senderName)
            return out
        }
        let g = groups[i]
        guard g.out != .left, from == g.roster.admin, r.rev > g.roster.rev else { return out }
        let who = g.roster.member(from)?.name ?? senderName
        let before = Set(g.roster.members.map(\.id))
        let after = Set(r.members.map(\.id))
        if r.name != g.roster.name { out.notes.append("\(who) named the group “\(r.name)”") }
        for m in r.members where !before.contains(m.id) && m.id != me { out.notes.append("\(who) added \(m.name)") }
        for m in g.roster.members where !after.contains(m.id) && m.id != me && m.id != from { out.notes.append("\(who) removed \(m.name)") }
        if r.admin != g.roster.admin, let a = r.member(r.admin) { out.notes.append(a.id == me ? "You run the group now" : "\(a.name) runs the group now") }
        groups[i].roster = r
        if r.has(me) {
            if g.out == .removed { groups[i].out = nil; out.notes.append("\(who) added you"); out.news = .added(group: r.name, by: who) }
        } else if g.out == nil {
            groups[i].out = .removed
            out.notes.append("\(who) removed you")
            out.news = .removed(group: r.name)
        }
        out.accepted = true
        return out
    }

    /// `from` left group `id`: off the list here too (the admin's next list says the same). If they ran it, the first
    /// member left runs it now. Gives the line for the chat.
    mutating func receiveLeave(_ id: String, from: String, me: String) -> String? {
        guard let i = index(id), groups[i].isIn, from != me, let m = groups[i].roster.member(from) else { return nil }
        groups[i].roster.members.removeAll { $0.id == from }
        var line = "\(m.name) left"
        if groups[i].roster.admin == from, let next = groups[i].roster.members.first {
            groups[i].roster.admin = next.id
            line += next.id == me ? " · you run the group now" : " · \(next.name) runs the group now"
        }
        return line
    }

    /// A group picture is taken only from the one who runs it.
    func acceptsPicture(_ id: String, from: String) -> Bool {
        guard let g = group(id), g.isIn else { return false }
        return g.roster.admin == from
    }
}
