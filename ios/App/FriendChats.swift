import Foundation
import SwiftUI
import UIKit
import UserNotifications

/// Friends (0.27): the chats on this phone (one per friend, one per group). Lines come in with each check of the relay
/// (`FriendStore.sync`: the app to the front, every 30 s while Friends is open, every few seconds while a chat is open,
/// once a minute on a trip, the background refresh). No push: a line arrives when the other phone checks in.
/// Kept in Application Support/Friends/chats.json (not backed up, not in the vault).
@MainActor
final class FriendChats: ObservableObject {
    static let shared = FriendChats()

    @Published private(set) var book = ChatBook()
    /// The chat on screen now: what comes in there is read at once, without a banner.
    @Published var onScreen: String?
    /// A chat to open (from a notification, a friend's page or a banner): Friends goes there.
    @Published var toOpen: String?

    private static var file: URL? { FriendStore.folder?.appendingPathComponent("chats.json") }

    private init() {
        if let f = Self.file, let d = try? Data(contentsOf: f), let b = try? FriendJSON.decoder.decode(ChatBook.self, from: d) { book = b }
        publishUnread()
    }

    private var store: FriendStore { FriendStore.shared }

    private func save() {
        guard let f = Self.file, let d = try? FriendJSON.encoder.encode(book) else { return }
        try? d.write(to: f, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// The chats that can still be written in or read: friends', and groups you're in (or were taken off).
    private var liveKeys: Set<String> {
        let friends = store.book?.friends.map(\.id) ?? []
        let groups = store.groups.shown.map { ChatKey.group($0.id) }
        return Set(friends + groups)
    }

    private func publishUnread() {
        guard let me = store.myAccount else { store.unread = 0; return }
        store.unread = book.unreadTotal(me: me, among: liveKeys)
    }

    /// The badge again (a friend gone, a group left).
    func refresh() { publishUnread() }

    func unread(_ key: String) -> Int {
        guard let me = store.myAccount else { return 0 }
        return book.unread(key, me: me)
    }

    /// The chats with something in them, newest first (a removed friend's chat isn't listed).
    var recent: [Chat] {
        let live = liveKeys
        return book.recent.filter { live.contains($0.key) }
    }

    // MARK: what comes in

    /// A batch from the relay: lines and marks into their chats; a banner (or, with the app in the background, a
    /// notification) for new lines not on screen; how far you got goes back to the writers.
    func take(_ items: [FriendInbox.ChatIn]) {
        guard let me = store.myAccount, !items.isEmpty else { return }
        var fresh: [(chat: String, line: ChatMessage)] = []
        for i in items {
            switch i.what {
            case .line(let m):
                if book.add(m, to: i.chat), !m.isNote, m.from != me { fresh.append((chat: i.chat, line: m)) }
            case .seen(let s, let from):
                book.seen(s, from: from, in: i.chat)
            }
        }
        let active = UIApplication.shared.applicationState == .active
        if active, let k = onScreen { book.read(k, now: Date()) }
        tell(fresh, active: active)
        marks(Set(items.map(\.chat)))
        save()
        publishUnread()
    }

    private func title(_ chat: String, from: String) -> String {
        let who = store.name(from)
        if let gid = ChatKey.groupId(chat), let g = store.group(gid) { return "\(who) · \(g.name)" }
        return who
    }

    private func tell(_ fresh: [(chat: String, line: ChatMessage)], active: Bool) {
        let byChat: [String: [(chat: String, line: ChatMessage)]] = Dictionary(grouping: fresh, by: { $0.chat })
        for (chat, lines) in byChat {
            if active && chat == onScreen { continue }
            guard let last = lines.last?.line, let me = store.myAccount else { continue }
            let t = title(chat, from: last.from)
            let body = ChatWords.preview(last, me: me, name: { self.store.name($0) }, group: false)
                + (lines.count > 1 ? " (+\(lines.count - 1) more)" : "")
            if active {
                Notices.shared.show(title: t, body: body, kind: "friends")
            } else {
                // fetched in the background (a trip's network tick, the background refresh): one notification per chat
                let n = UNMutableNotificationContent()
                n.title = t
                n.body = body
                n.sound = .default
                n.threadIdentifier = "friends-\(chat)"
                n.userInfo = ["kind": "friends", "chat": chat]
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "friends-chat-\(chat)", content: n, trigger: nil)) { _ in }
            }
        }
    }

    /// Tells each writer how far you got and read their lines (only what's new since you last told them).
    private func marks(_ chats: Set<String>) {
        guard let me = store.myAccount else { return }
        for chat in chats {
            for due in book.marksDue(chat, me: me) {
                store.queueSeen(due.seen, to: due.to, chat: chat)
                book.told(due.seen, to: due.to, in: chat)
            }
        }
    }

    // MARK: what you do

    /// The chat is on screen: everything in it is read (and the writers are told at the next check).
    func read(_ chat: String) {
        book.read(chat, now: Date())
        marks([chat])
        save()
        publishUnread()
    }

    /// A line of text. False: nobody to send it to.
    @discardableResult
    func send(_ text: String, to chat: String) -> Bool {
        let t = ChatText.clean(text)
        guard !t.isEmpty else { return false }
        let body = ChatText(text: t)
        return post(.message(body), content: .text(body), chat: chat)
    }

    /// "I'm in" / "Can't" on a trip card (its `n`).
    @discardableResult
    func answer(_ a: TripAnswer, card n: String, in chat: String) -> Bool {
        let body = ChatText(text: a.text, re: n, answer: a.rawValue)
        return post(.message(body), content: .text(body), chat: chat)
    }

    /// A trip card to each of these chats. Gives how many it went to.
    @discardableResult
    func sendTrip(_ c: TripCard, to chats: [String]) -> Int {
        guard let card = TripCard.valid(c) else { return 0 }
        return chats.filter { post(.trip(card), content: .trip(card), chat: $0) }.count
    }

    private func post(_ m: FriendMessage, content: ChatMessage.Content, chat: String) -> Bool {
        guard let me = store.myAccount else { return false }
        let n = RelaySign.nonce()
        let now = Date()
        let line = ChatMessage(id: ChatMessage.id(from: me, n: n), from: me, n: n, t: Int(now.timeIntervalSince1970), at: now,
                               content: content, sent: false)
        guard store.queueLine(m, chat: chat, n: n, at: now, line: line.id) else { return false }
        book.add(line, to: chat)
        book.read(chat, now: now)
        save()
        publishUnread()
        Task { await store.sync(.now) }
        return true
    }

    /// A line about the group written on this phone ("You added Lou").
    func note(_ text: String, in chat: String) {
        let now = Date()
        let n = RelaySign.nonce()
        book.add(ChatMessage(id: ChatMessage.id(from: "", n: n), from: "", n: n, t: Int(now.timeIntervalSince1970), at: now,
                             content: .note(text)), to: chat)
        book.read(chat, now: now)
        save()
    }

    func markSent(_ lines: Set<String>) {
        book.markSent(lines)
        save()
    }

    func remove(_ chat: String) {
        book.remove(chat)
        save()
        publishUnread()
    }

    func clearAll() {
        book = ChatBook()
        onScreen = nil
        toOpen = nil
        save()
        if let f = Self.file { try? FileManager.default.removeItem(at: f) }
    }

    /// Open Friends at this chat (a notification tapped, a friend's "Message").
    func open(_ chat: String) {
        toOpen = chat
        store.showing = true
    }

    /// A notification of ours was tapped.
    nonisolated static func tapped(_ info: [AnyHashable: Any]) {
        guard (info["kind"] as? String) == "friends", let chat = info["chat"] as? String else { return }
        Task { @MainActor in FriendChats.shared.open(chat) }
    }

    func delivery(_ m: ChatMessage, in chat: String) -> ChatDelivery {
        let others = store.recipients(chat).map(\.account)
        return book.delivery(m, in: chat, others: others)
    }
}
