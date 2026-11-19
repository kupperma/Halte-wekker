import XCTest
import CryptoKit

final class ChatBookTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let me = "me", sam = "sam", lou = "lou"

    private func line(_ from: String, _ n: String, t: Int, at: TimeInterval, text: String = "hi", sent: Bool? = nil) -> ChatMessage {
        ChatMessage(id: ChatMessage.id(from: from, n: n), from: from, n: n, t: t, at: t0.addingTimeInterval(at),
                    content: .text(ChatText(text: text)), sent: sent)
    }

    func test_cleanText() {
        XCTAssertEqual(ChatText.clean("  hi\u{0007} there \n\n\n\nsee you  "), "hi there\n\nsee you")
        XCTAssertEqual(ChatText.clean("\t\n "), "")
        XCTAssertEqual(ChatText.clean(String(repeating: "a", count: 1200)).count, 1000)
    }

    func test_addDedupesAndKeepsOrder() {
        var b = ChatBook()
        XCTAssertTrue(b.add(line(sam, "1", t: 10, at: 1), to: sam))
        XCTAssertFalse(b.add(line(sam, "1", t: 10, at: 2), to: sam), "the same box again")
        b.add(line(sam, "0", t: 5, at: 3), to: sam)
        XCTAssertEqual(b.chat(sam)?.messages.map(\.n), ["1", "0"], "in the order this phone got them")
    }

    func test_keepsTheNewest500() {
        var b = ChatBook()
        for i in 0..<510 { b.add(line(sam, "\(i)", t: i, at: Double(i)), to: sam) }
        XCTAssertEqual(b.chat(sam)?.messages.count, ChatBook.keep)
        XCTAssertEqual(b.chat(sam)?.messages.first?.n, "10")
    }

    func test_unreadCountsOthersSinceRead() {
        var b = ChatBook()
        b.add(line(sam, "1", t: 10, at: 1), to: sam)
        b.add(line(me, "2", t: 11, at: 2), to: sam)
        b.add(line(sam, "3", t: 12, at: 3), to: sam)
        XCTAssertEqual(b.unread(sam, me: me), 2)
        b.read(sam, now: t0.addingTimeInterval(3))
        XCTAssertEqual(b.unread(sam, me: me), 0)
        b.add(line(sam, "4", t: 13, at: 9), to: sam)
        b.add(line(lou, "5", t: 13, at: 9), to: "g.x")
        b.add(ChatMessage(id: "|n", from: "", n: "n", t: 0, at: t0.addingTimeInterval(9), content: .note("Lou left")), to: "g.x")
        XCTAssertEqual(b.unread(sam, me: me), 1)
        XCTAssertEqual(b.unreadTotal(me: me), 2, "a note isn't unread")
        XCTAssertEqual(b.unreadTotal(me: me, among: [sam]), 1)
        XCTAssertEqual(b.unread("nobody", me: me), 0)
    }

    func test_marksDueOncePerChange() {
        var b = ChatBook()
        b.add(line(sam, "1", t: 100, at: 1), to: sam)
        b.add(line(sam, "2", t: 105, at: 2), to: sam)
        var due = b.marksDue(sam, me: me)
        XCTAssertEqual(due.map(\.to), [sam])
        XCTAssertEqual(due.first?.seen, ChatSeen(got: 105, read: nil))
        b.told(due[0].seen, to: sam, in: sam)
        XCTAssertTrue(b.marksDue(sam, me: me).isEmpty, "nothing new")
        b.read(sam, now: t0.addingTimeInterval(5))
        due = b.marksDue(sam, me: me)
        XCTAssertEqual(due.first?.seen, ChatSeen(got: 105, read: 105))
        b.told(due[0].seen, to: sam, in: sam)
        XCTAssertTrue(b.marksDue(sam, me: me).isEmpty)
        // your own lines never need a mark
        b.add(line(me, "3", t: 200, at: 6), to: sam)
        XCTAssertTrue(b.marksDue(sam, me: me).isEmpty)
    }

    func test_marksDuePerWriterInAGroup() {
        var b = ChatBook()
        b.add(line(sam, "1", t: 100, at: 1), to: "g.x")
        b.add(line(lou, "2", t: 50, at: 2), to: "g.x")
        let due = b.marksDue("g.x", me: me)
        XCTAssertEqual(due.map(\.to), [lou, sam])
        XCTAssertEqual(due.map(\.seen.got), [50, 100])
    }

    func test_deliveryFromMarks() {
        var b = ChatBook()
        let mine = line(me, "1", t: 100, at: 1, sent: false)
        b.add(mine, to: "g.x")
        XCTAssertEqual(b.delivery(mine, in: "g.x", others: [sam, lou]), .waiting)
        b.markSent([mine.id])
        let sent = b.chat("g.x")!.messages[0]
        XCTAssertEqual(b.delivery(sent, in: "g.x", others: [sam, lou]), .sent)
        b.seen(ChatSeen(got: 100), from: sam, in: "g.x")
        XCTAssertEqual(b.delivery(sent, in: "g.x", others: [sam, lou]), .delivered(1, of: 2))
        b.seen(ChatSeen(got: 99, read: 100), from: lou, in: "g.x")
        XCTAssertEqual(b.delivery(sent, in: "g.x", others: [sam, lou]), .read(1, of: 2))
        // marks only move forward
        b.seen(ChatSeen(got: 1, read: 1), from: lou, in: "g.x")
        XCTAssertEqual(b.chat("g.x")?.marks[lou], ChatSeen(got: 99, read: 100))
        // an older line of mine is read too once a later one is
        let older = ChatMessage(id: "me|0", from: me, n: "0", t: 90, at: t0, content: .text(ChatText(text: "a")), sent: true)
        XCTAssertEqual(b.delivery(older, in: "g.x", others: [sam, lou]), .read(1, of: 2))
    }

    func test_answersNewestPerPerson() {
        var b = ChatBook()
        func answer(_ from: String, _ n: String, _ a: TripAnswer, at: TimeInterval) -> ChatMessage {
            ChatMessage(id: "\(from)|\(n)", from: from, n: n, t: 0, at: t0.addingTimeInterval(at),
                        content: .text(ChatText(text: a.text, re: "card", answer: a.rawValue)))
        }
        b.add(answer(sam, "1", .yes, at: 1), to: "g.x")
        b.add(answer(lou, "2", .no, at: 2), to: "g.x")
        b.add(answer(sam, "3", .no, at: 3), to: "g.x")
        XCTAssertEqual(b.answers(to: "card", in: "g.x"), [sam: .no, lou: .no])
        XCTAssertEqual(b.answers(to: "other", in: "g.x"), [:])
    }

    func test_recentNewestFirst() {
        var b = ChatBook()
        b.add(line(sam, "1", t: 1, at: 1), to: sam)
        b.add(line(lou, "2", t: 1, at: 5), to: lou)
        XCTAssertEqual(b.recent.map(\.key), [lou, sam])
    }

    func test_quickReplies() {
        XCTAssertEqual(QuickReplies.list(line: nil), ["Running 5 min late", "Save me a seat", "Wait for me", "I’m at the stop"])
        XCTAssertEqual(QuickReplies.list(line: "305").first, "On the 305")
        XCTAssertEqual(QuickReplies.list(line: " ").count, 4)
    }

    func test_chatKeys() {
        XCTAssertEqual(ChatKey.group("abc"), "g.abc")
        XCTAssertEqual(ChatKey.groupId("g.abc"), "abc")
        XCTAssertNil(ChatKey.groupId("3c157621a97cf055f5804a9826c6d1e1"))
        XCTAssertTrue(ChatKey.isGroup("g.abc"))
    }
}

final class GroupBookTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let sam = FriendIdentity.random(), lou = FriendIdentity.random(), kim = FriendIdentity.random(), max = FriendIdentity.random()
    let gid = "0123456789abcdef01234567"

    private func friend(_ i: FriendIdentity, _ n: String) -> Friend { Friend(card: i.card, name: n, since: t0) }

    /// Sam's group with Lou and Kim, as Sam made it.
    private func made() -> (GroupBook, FriendGroup, [GroupBook.Send]) {
        var b = GroupBook()
        let r = b.create(id: gid, name: " Uni  crew ", friends: [friend(lou, "Lou"), friend(kim, "Kim")], me: sam.card, myName: "Sam", now: t0)!
        return (b, r.0, r.1)
    }

    func test_newIdFitsASlot() {
        let id = GroupBook.newId()
        XCTAssertTrue(GroupBook.isId(id))
        XCTAssertLessThanOrEqual(GroupBook.rosterSlot(id).count, 32)
        XCTAssertFalse(GroupBook.isId("xyz"))
    }

    func test_createSendsTheListToEveryoneElse() {
        let (b, g, sends) = made()
        XCTAssertEqual(g.roster.name, "Uni crew")
        XCTAssertEqual(g.roster.admin, sam.account)
        XCTAssertEqual(g.roster.rev, 1)
        XCTAssertEqual(g.roster.members.map(\.name), ["Sam", "Lou", "Kim"])
        XCTAssertEqual(Set(sends.map(\.to.account)), [lou.account, kim.account])
        XCTAssertTrue(sends.allSatisfy { $0.slot == "gr.\(gid)" && $0.group == gid && $0.message == .group(g.roster) })
        XCTAssertTrue(b.group(gid)!.isAdmin(sam.account))
        var e = GroupBook()
        XCTAssertNil(e.create(id: gid, name: "x", friends: [], me: sam.card, myName: "Sam", now: t0), "nobody to put in it")
    }

    func test_atMostTwentyPeople() {
        var b = GroupBook()
        let many = (0..<25).map { friend(FriendIdentity.random(), "F\($0)") }
        XCTAssertNil(b.create(id: gid, name: "Big", friends: many, me: sam.card, myName: "Sam", now: t0))
        let ok = b.create(id: gid, name: "Big", friends: Array(many.prefix(19)), me: sam.card, myName: "Sam", now: t0)
        XCTAssertEqual(ok?.0.roster.members.count, 20)
        XCTAssertTrue(b.add(gid, friends: [many[20]], me: sam.account).isEmpty, "full")
    }

    func test_anInviteOnlyFromAFriendWhoRunsIt() {
        let (_, g, _) = made()
        // Lou's phone: Sam is a friend, Sam runs it, Lou is on it
        var lb = GroupBook()
        var got = lb.receive(g.roster, id: gid, from: sam.account, me: lou.account, isFriend: { _ in false }, senderName: "Sam", now: t0)
        XCTAssertFalse(got.accepted, "not from a friend")
        got = lb.receive(g.roster, id: gid, from: kim.account, me: lou.account, isFriend: { _ in true }, senderName: "Kim", now: t0)
        XCTAssertFalse(got.accepted, "from someone who doesn't run it")
        got = lb.receive(g.roster, id: gid, from: sam.account, me: max.account, isFriend: { _ in true }, senderName: "Sam", now: t0)
        XCTAssertFalse(got.accepted, "not on the list")
        got = lb.receive(g.roster, id: "bad", from: sam.account, me: lou.account, isFriend: { _ in true }, senderName: "Sam", now: t0)
        XCTAssertFalse(got.accepted, "not a group id")
        got = lb.receive(g.roster, id: gid, from: sam.account, me: lou.account, isFriend: { $0 == self.sam.account }, senderName: "Sam", now: t0)
        XCTAssertTrue(got.accepted)
        XCTAssertEqual(got.news, .added(group: "Uni crew", by: "Sam"))
        XCTAssertEqual(lb.card(kim.account), kim.card, "Kim's key from the list, though not Lou's friend")
        XCTAssertTrue(lb.accepts(gid, from: kim.account))
        XCTAssertFalse(lb.accepts(gid, from: max.account))
        XCTAssertTrue(lb.shares(kim.account))
        XCTAssertEqual(lb.name(kim.account), "Kim")
    }

    func test_changesOnlyFromTheAdminAndNewer() {
        var (sb, g, _) = made()
        var lb = GroupBook()
        _ = lb.receive(g.roster, id: gid, from: sam.account, me: lou.account, isFriend: { _ in true }, senderName: "Sam", now: t0)
        // Sam renames and adds Max
        _ = sb.rename(gid, to: "Crew", me: sam.account)
        let sends = sb.add(gid, friends: [friend(max, "Max")], me: sam.account)
        XCTAssertEqual(Set(sends.map(\.to.account)), [lou.account, kim.account, max.account])
        let r3 = sb.group(gid)!.roster
        XCTAssertEqual(r3.rev, 3)
        // Kim can't change it
        var fake = r3
        fake.name = "Kim's"
        fake.rev = 9
        XCTAssertFalse(lb.receive(fake, id: gid, from: kim.account, me: lou.account, isFriend: { _ in true }, senderName: "Kim", now: t0).accepted)
        let got = lb.receive(r3, id: gid, from: sam.account, me: lou.account, isFriend: { _ in true }, senderName: "Sam", now: t0)
        XCTAssertTrue(got.accepted)
        XCTAssertEqual(got.notes, ["Sam named the group “Crew”", "Sam added Max"])
        XCTAssertFalse(lb.receive(g.roster, id: gid, from: sam.account, me: lou.account, isFriend: { _ in true }, senderName: "Sam", now: t0).accepted,
                       "an older list doesn't win")
        XCTAssertEqual(lb.group(gid)?.name, "Crew")
    }

    func test_removedThenBackIn() {
        var (sb, g, _) = made()
        var lb = GroupBook()
        _ = lb.receive(g.roster, id: gid, from: sam.account, me: lou.account, isFriend: { _ in true }, senderName: "Sam", now: t0)
        let sends = sb.remove(gid, member: lou.account, me: sam.account)
        XCTAssertEqual(Set(sends.map(\.to.account)), [lou.account, kim.account], "the removed one is told too")
        XCTAssertTrue(sb.remove(gid, member: sam.account, me: sam.account).isEmpty, "not yourself: leave instead")
        var got = lb.receive(sb.group(gid)!.roster, id: gid, from: sam.account, me: lou.account, isFriend: { _ in true }, senderName: "Sam", now: t0)
        XCTAssertEqual(got.news, .removed(group: "Uni crew"))
        XCTAssertEqual(lb.group(gid)?.out, .removed)
        XCTAssertFalse(lb.accepts(gid, from: kim.account))
        XCTAssertNil(lb.card(kim.account))
        XCTAssertEqual(lb.shown.count, 1, "its chat stays to read")
        _ = sb.add(gid, friends: [friend(lou, "Lou")], me: sam.account)
        got = lb.receive(sb.group(gid)!.roster, id: gid, from: sam.account, me: lou.account, isFriend: { _ in true }, senderName: "Sam", now: t0)
        XCTAssertTrue(got.accepted)
        XCTAssertNil(lb.group(gid)?.out)
    }

    func test_leaveTellsEveryoneAndTheAdminPasses() {
        var (sb, g, _) = made()
        var lb = GroupBook()
        _ = lb.receive(g.roster, id: gid, from: sam.account, me: lou.account, isFriend: { _ in true }, senderName: "Sam", now: t0)
        // Sam leaves: Lou (first on the list after Sam) runs it
        let sends = sb.leave(gid, me: sam.account)
        XCTAssertEqual(Set(sends.map(\.to.account)), [lou.account, kim.account])
        XCTAssertTrue(sends.allSatisfy { $0.message == .groupLeave && $0.slot == nil })
        XCTAssertEqual(sb.group(gid)?.out, .left)
        XCTAssertEqual(lb.receiveLeave(gid, from: sam.account, me: lou.account), "Sam left · you run the group now")
        XCTAssertTrue(lb.group(gid)!.isAdmin(lou.account))
        XCTAssertNil(lb.receiveLeave(gid, from: max.account, me: lou.account), "not on the list")
        // Sam's old list still on its way doesn't bring Sam back on Lou's phone, nor Sam back in on Sam's
        XCTAssertFalse(lb.receive(g.roster, id: gid, from: sam.account, me: lou.account, isFriend: { _ in true }, senderName: "Sam", now: t0).accepted)
        var r = g.roster
        r.rev = 5
        XCTAssertFalse(sb.receive(r, id: gid, from: sam.account, me: sam.account, isFriend: { _ in true }, senderName: "Sam", now: t0).accepted)
        sb.forget(gid)
        XCTAssertNotNil(sb.group(gid), "a group you left stays known as left")
        XCTAssertTrue(sb.shown.isEmpty)
    }

    func test_pictureOnlyFromTheAdmin() {
        let (sb, _, _) = made()
        let sends = sb.pictureSends(gid, jpeg: Data([1, 2]), me: sam.account, only: [kim.account])
        XCTAssertEqual(sends.map(\.to.account), [kim.account])
        XCTAssertEqual(sends.first?.slot, "gp.\(gid)")
        XCTAssertTrue(sb.pictureSends(gid, jpeg: Data([1]), me: lou.account).isEmpty)
        XCTAssertTrue(sb.acceptsPicture(gid, from: sam.account))
        XCTAssertFalse(sb.acceptsPicture(gid, from: lou.account))
    }

    func test_namesFollowFriends() {
        var (sb, _, _) = made()
        let sends = sb.refreshNames(friends: [friend(lou, "Louise"), friend(kim, "Kim")], me: sam.account, myName: "Sam")
        XCTAssertEqual(sends.count, 2)
        XCTAssertEqual(sb.group(gid)?.roster.member(lou.account)?.name, "Louise")
        XCTAssertEqual(sb.group(gid)?.roster.rev, 2)
        XCTAssertTrue(sb.refreshNames(friends: [friend(lou, "Louise"), friend(kim, "Kim")], me: sam.account, myName: "Sam").isEmpty)
    }

    func test_validCleansTheList() {
        let r = GroupRoster(name: "  ", admin: sam.account, rev: 1, members: [
            GroupMember(card: sam.card, name: "Sam\n"), GroupMember(card: sam.card, name: "Again"), GroupMember(card: lou.card, name: ""),
        ])
        let v = GroupRoster.valid(r)
        XCTAssertEqual(v?.name, "Group")
        XCTAssertEqual(v?.members.map(\.name), ["Sam", "Someone"])
        XCTAssertNil(GroupRoster.valid(GroupRoster(name: "x", admin: kim.account, rev: 1, members: [GroupMember(card: sam.card, name: "Sam")])),
                     "the admin must be on it")
        XCTAssertNil(GroupRoster.valid(GroupRoster(name: "x", admin: sam.account, rev: 0, members: [GroupMember(card: sam.card, name: "Sam")])))
    }
}

final class FriendInboxChatTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let sam = FriendIdentity.random(), lou = FriendIdentity.random(), kim = FriendIdentity.random(), max = FriendIdentity.random()
    let gid = "0123456789abcdef01234567"

    private func box(_ id: Int, _ m: FriendMessage, from: FriendIdentity, to: FriendIdentity, n: String = RelaySign.nonce(),
                     group: String? = nil, at: Int = 1_800_000_000) throws -> RelayBox {
        let d = try FriendBox.seal(m, from: from, to: to.card, at: t0, id: n, group: group)
        return RelayBox(id: id, from: from.account, slot: nil, at: at, exp: 0, data: B64URL.encode(d))
    }

    /// Lou's list: Sam is a friend; Kim isn't.
    private var louBook: FriendBook {
        var b = FriendBook(myName: "Lou")
        b.friends = [Friend(card: sam.card, name: "Sam", since: t0)]
        return b
    }

    private var roster: GroupRoster {
        GroupRoster(name: "Crew", admin: sam.account, rev: 1, members: [
            GroupMember(card: sam.card, name: "Sam"), GroupMember(card: lou.card, name: "Lou"), GroupMember(card: kim.card, name: "Kim"),
        ])
    }

    private func lines(_ r: FriendInbox.Result) -> [(String, String)] {
        r.chat.compactMap { c in
            if case .line(let m) = c.what, let t = m.text { return (c.chat, t.text) }
            return nil
        }
    }

    func test_oneToOneFromFriendsOnly() throws {
        let boxes = [
            try box(1, .message(ChatText(text: "On the 305")), from: sam, to: lou, n: "a"),
            try box(2, .message(ChatText(text: "Hello")), from: kim, to: lou),          // a stranger: no key for them
            try box(3, .message(ChatText(text: "  ")), from: sam, to: lou),              // empty: dropped
            try box(4, .seen(ChatSeen(got: 5, read: 4)), from: sam, to: lou),
        ]
        let r = FriendInbox.process(boxes, book: louBook, me: lou, now: t0)
        XCTAssertEqual(lines(r).map(\.0), [sam.account])
        XCTAssertEqual(lines(r).map(\.1), ["On the 305"])
        XCTAssertEqual(r.ack.sorted(), [1, 2, 3, 4], "all off the relay (the stranger's kept on the phone a while)")
        XCTAssertEqual(r.orphans.map(\.id), [2])
        XCTAssertTrue(r.chat.contains { $0.what == .seen(ChatSeen(got: 5, read: 4), from: sam.account) })
        if case .line(let m) = r.chat.first?.what {
            XCTAssertEqual(m.id, "\(sam.account)|a")
            XCTAssertEqual(m.t, 1_800_000_000)
        } else { XCTFail("no line") }
    }

    func test_aGroupLineBeforeItsListInTheSameBatch() throws {
        let boxes = [
            try box(1, .message(ChatText(text: "Save me a seat")), from: kim, to: lou, group: gid),
            try box(2, .group(roster), from: sam, to: lou, n: "r", group: gid),
            try box(3, .message(ChatText(text: "On my way")), from: sam, to: lou, group: gid),
            try box(4, .message(ChatText(text: "sneaky")), from: max, to: lou, group: gid),   // not on the list
        ]
        let r = FriendInbox.process(boxes, book: louBook, me: lou, now: t0)
        XCTAssertNotNil(r.groups.group(gid))
        XCTAssertEqual(r.groupsChanged, [gid])
        XCTAssertEqual(r.groupNews, [.added(group: "Crew", by: "Sam")])
        let ls = lines(r)
        XCTAssertEqual(ls.map(\.1), ["Save me a seat", "On my way"], "in the relay's order, after the list")
        XCTAssertTrue(ls.allSatisfy { $0.0 == "g.\(gid)" })
        XCTAssertEqual(r.orphans.map(\.id), [4])
        // the "Sam added you" line
        XCTAssertTrue(r.chat.contains { if case .line(let m) = $0.what, case .note(let s) = m.content { return s == "Sam added you" }; return false })
    }

    func test_orphansTriedAgainWhenTheListComes() throws {
        let early = try box(1, .message(ChatText(text: "Hi all")), from: kim, to: lou, group: gid)
        let first = FriendInbox.process([early], book: louBook, me: lou, now: t0)
        XCTAssertEqual(first.orphans.map(\.id), [1])
        XCTAssertTrue(lines(first).isEmpty)
        let later = FriendInbox.process([try box(2, .group(roster), from: sam, to: lou, group: gid)], book: louBook,
                                        groups: first.groups, retry: first.orphans, me: lou, now: t0)
        XCTAssertEqual(lines(later).map(\.1), ["Hi all"])
        XCTAssertTrue(later.orphans.isEmpty)
        XCTAssertEqual(later.ack, [2], "the retried one was off the relay already")
        // a week later, an orphan goes
        let old = FriendInbox.process([], book: louBook, retry: [early], me: lou, now: t0.addingTimeInterval(8 * 86400))
        XCTAssertTrue(old.orphans.isEmpty)
    }

    func test_groupLeaveAndPictureAndMemberPictures() throws {
        var g = GroupBook()
        _ = g.receive(roster, id: gid, from: sam.account, me: lou.account, isFriend: { _ in true }, senderName: "Sam", now: t0)
        let boxes = [
            try box(1, .groupPicture(FriendPicture(jpeg: Data([9]))), from: sam, to: lou, group: gid),
            try box(2, .groupPicture(FriendPicture(jpeg: Data([8]))), from: kim, to: lou, group: gid),   // not the admin
            try box(3, .picture(FriendPicture(jpeg: Data([7]))), from: kim, to: lou),                    // in a group with you
            try box(4, .groupLeave, from: kim, to: lou, group: gid),
        ]
        let r = FriendInbox.process(boxes, book: louBook, groups: g, me: lou, now: t0)
        XCTAssertEqual(r.groupPictures, [gid: Data([9])])
        XCTAssertEqual(r.pictures, [kim.account: Data([7])])
        XCTAssertFalse(r.groups.group(gid)!.roster.has(kim.account))
        XCTAssertEqual(r.ack, [1, 2, 3, 4])
    }

    func test_tripsAndAnswers() throws {
        let card = TripCard(rides: [TripCard.Ride(mode: "bus", line: "305", trip: "t1", from: .init(name: "A"), to: .init(name: "B"),
                                                  dep: t0, arr: t0.addingTimeInterval(600))], to: .init(name: "B"))
        let bad = TripCard(rides: [], to: .init(name: "B"))
        let boxes = [
            try box(1, .trip(card), from: sam, to: lou, n: "c1"),
            try box(2, .trip(bad), from: sam, to: lou),
            try box(3, .message(ChatText(text: "", re: "c1", answer: "in")), from: sam, to: lou),
            try box(4, .message(ChatText(text: "x", re: "c1", answer: "maybe")), from: sam, to: lou),
        ]
        let r = FriendInbox.process(boxes, book: louBook, me: lou, now: t0)
        let contents: [ChatMessage.Content] = r.chat.compactMap { if case .line(let m) = $0.what { return m.content }; return nil }
        XCTAssertEqual(contents.count, 3)
        XCTAssertEqual(contents[0], .trip(card))
        XCTAssertEqual(contents[1], .text(ChatText(text: "I’m in", re: "c1", answer: "in")), "an answer without words gets them")
        XCTAssertEqual(contents[2], .text(ChatText(text: "x")), "an answer this version doesn't know is just text")
    }
}

final class TripTakeTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)       // a Friday, 09:00 in Amsterdam
    var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return c
    }
    let home = GeoPoint(lat: 51.6167, lon: 5.5486)
    let school = GeoPoint(lat: 51.5866, lon: 4.7745)

    private func ride(_ mode: String, _ trip: String, dep: TimeInterval, mins: Double, from: GeoPoint? = nil) -> TripCard.Ride {
        TripCard.Ride(mode: mode, line: mode == "train" ? "IC" : "305", trip: trip,
                      from: TripCard.Spot(name: "From", lat: from?.lat, lon: from?.lon), to: TripCard.Spot(name: "To"),
                      dep: now.addingTimeInterval(dep), arr: now.addingTimeInterval(dep + mins * 60))
    }

    private func card(_ rides: [TripCard.Ride], to: GeoPoint? = nil, by: Date? = nil) -> TripCard {
        TripCard(rides: rides, to: TripCard.Spot(name: "BUas", lat: to?.lat, lon: to?.lon), by: by)
    }

    func test_sharedRideIsTheTrainElseTheLongest() {
        XCTAssertEqual(TripTake.sharedIndex(card([ride("bus", "b", dep: 0, mins: 10), ride("train", "t", dep: 900, mins: 30)])), 1)
        XCTAssertEqual(TripTake.sharedIndex(card([ride("bus", "b1", dep: 0, mins: 10), ride("bus", "b2", dep: 900, mins: 30)])), 1)
        XCTAssertEqual(TripTake.sharedIndex(card([ride("bus", "b1", dep: 0, mins: 40), ride("bus", "b2", dep: 3000, mins: 5)])), 0)
    }

    func test_way() {
        let soon = card([ride("bus", "b", dep: 600, mins: 10), ride("train", "t", dep: 1800, mins: 30)], to: school)
        XCTAssertEqual(TripTake.way(soon, now: now, home: home, school: school, calendar: cal), .fastest)
        let gone = card([ride("train", "t", dep: -600, mins: 30)], to: school)
        XCTAssertEqual(TripTake.way(gone, now: now, home: home, school: school, calendar: cal), .gone)
        let later = card([ride("train", "t", dep: 4 * 3600, mins: 30)], to: school)
        XCTAssertEqual(TripTake.way(later, now: now, home: home, school: school, calendar: cal), .beThereBy(out: true, tomorrow: false))
        let tomorrowHome = card([ride("train", "t", dep: 86400, mins: 30)], to: home)
        XCTAssertEqual(TripTake.way(tomorrowHome, now: now, home: home, school: school, calendar: cal), .beThereBy(out: false, tomorrow: true))
        let elsewhere = card([ride("train", "t", dep: 4 * 3600, mins: 30)], to: GeoPoint(lat: 52.37, lon: 4.9))
        XCTAssertEqual(TripTake.way(elsewhere, now: now, home: home, school: school, calendar: cal), .plan)
        let nextWeek = card([ride("train", "t", dep: 5 * 86400, mins: 30)], to: school)
        XCTAssertEqual(TripTake.way(nextWeek, now: now, home: home, school: school, calendar: cal), .plan)
        // the shared train still to come, though the bus to it has left: still on
        let busGone = card([ride("bus", "b", dep: -300, mins: 10), ride("train", "t", dep: 900, mins: 30)], to: school)
        XCTAssertEqual(TripTake.way(busGone, now: now, home: home, school: school, calendar: cal), .fastest)
    }

    func test_sameStartAndPick() {
        let c = card([ride("bus", "b", dep: 600, mins: 10, from: home), ride("train", "t", dep: 1800, mins: 30)])
        XCTAssertTrue(TripTake.sameStart(c, you: GeoPoint(lat: 51.6170, lon: 5.5490)))
        XCTAssertFalse(TripTake.sameStart(c, you: school))
        XCTAssertFalse(TripTake.sameStart(c, you: nil))
        XCTAssertEqual(TripTake.pick([["x", "y"], ["z", "t"], ["b", "t"]], card: c), 2, "the one sharing the most")
        XCTAssertNil(TripTake.pick([["x"], ["b"]], card: c), "none has the train")
    }

    func test_boardCandidatesNearestFirst() {
        func stop(_ i: Int, lat: Double, dep: TimeInterval?, boarding: Bool = true) -> BoardAt.Stop {
            BoardAt.Stop(id: "s\(i)", name: "S\(i)", point: GeoPoint(lat: lat, lon: 5), departure: dep.map { now.addingTimeInterval($0) }, boarding: boarding)
        }
        let stops = [stop(0, lat: 51.0, dep: 60), stop(1, lat: 51.1, dep: 600), stop(2, lat: 51.2, dep: 1200, boarding: false),
                     stop(3, lat: 51.3, dep: 1800), stop(4, lat: 51.4, dep: 2400)]
        let you = GeoPoint(lat: 51.22, lon: 5)
        XCTAssertEqual(TripTake.boardCandidates(stops, board: 0, alight: 4, you: you, now: now), [3, 1],
                       "not where you can't get on, nor one it leaves within two minutes, nor where you'd get off")
    }

    func test_words() {
        let c = card([ride("train", "t", dep: 1800, mins: 30)])
        XCTAssertEqual(TripCardWords.headline(c, now: now, group: false), "Take the 09:30 with me?")
        XCTAssertEqual(TripCardWords.headline(c, now: now, group: true), "Take the 09:30 with us?")
        let tomorrow = card([ride("train", "t", dep: 86400, mins: 30)])
        XCTAssertEqual(TripCardWords.headline(tomorrow, now: now, group: false), "Take the 09:00 tomorrow with me?")
        let thursday = card([ride("train", "t", dep: 6 * 86400 - 3600, mins: 30)], by: now.addingTimeInterval(6 * 86400))
        XCTAssertEqual(TripCardWords.headline(thursday, now: now, group: false), "Thursday: be at BUas by 09:00, this way")
        var noted = c
        noted.note = "Same train?"
        XCTAssertEqual(TripCardWords.headline(noted, now: now, group: false), "Same train?")
        XCTAssertEqual(TripCardWords.short(c), "09:30 to BUas")
    }

    func test_valid() {
        var c = card([ride("train", "t", dep: 0, mins: 30)])
        c.note = "  hi \u{0007} "
        XCTAssertEqual(TripCard.valid(c)?.note, "hi")
        XCTAssertNil(TripCard.valid(card([])))
        var back = ride("train", "t", dep: 0, mins: 30)
        back.arr = now.addingTimeInterval(-60)
        XCTAssertNil(TripCard.valid(card([back])))
    }
}
