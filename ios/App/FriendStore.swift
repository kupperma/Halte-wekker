import Foundation
import Security
import SwiftUI

/// The account's secret and this phone's id, in the Keychain, this device only (never in a backup, never synced).
enum FriendKeychain {
    private static func query(_ k: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "nl.haltewekker.friends", kSecAttrAccount as String: k]
    }
    /// Where it goes if a sideloaded build can't write the Keychain: a file only this app reads, not backed up.
    private static func fallback(_ k: String) -> URL? {
        FriendStore.folder?.appendingPathComponent("k-\(k)")
    }
    static func get(_ k: String) -> Data? {
        var q = query(k)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data { return d }
        return fallback(k).flatMap { try? Data(contentsOf: $0) }
    }
    static func set(_ k: String, _ v: Data?) {
        SecItemDelete(query(k) as CFDictionary)
        if let f = fallback(k) { try? FileManager.default.removeItem(at: f) }
        guard let v else { return }
        var a = query(k)
        a[kSecValueData as String] = v
        a[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if SecItemAdd(a as CFDictionary, nil) != errSecSuccess, let f = fallback(k) {
            try? v.write(to: f, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
}

/// Friends (0.25): your account, your friend list and the relay. The list and what's waiting to be sent are kept in
/// a file; the keys in the Keychain. Checks the relay when the app comes to the front, every 30 s while Friends is
/// open, and at the background refresh the school alarm already has; nothing else runs (no loop of its own).
@MainActor
final class FriendStore: ObservableObject {
    static let shared = FriendStore()

    @Published private(set) var book: FriendBook?
    @Published private(set) var syncing = false
    @Published private(set) var lastChecked: Date?
    @Published private(set) var offline = false
    /// The account moved to another phone (restored there): this phone was signed out.
    @Published private(set) var movedAway: Bool
    /// A friend code opened from a link, waiting for "Send friend request".
    @Published var opened: OpenedCode?
    /// The Friends sheet over the home (from the home's button, or a link).
    @Published var showing = false
    /// Your own profile picture (a 256 px square JPEG), and friends' by account.
    @Published private(set) var myPicture: Data?
    @Published private(set) var pictures: [String: Data] = [:]
    /// (0.26) Friends travelling now: their latest state, by account (read from the relay; old ones drop out).
    @Published private(set) var travel: [String: FriendTravelSeen] = [:]
    @Published private(set) var travelChecked: Date?
    /// How many friends see your trip right now (0: none, or no trip).
    @Published private(set) var sharingWith = 0
    /// The one-time "Show my trips" screen was answered.
    @Published private(set) var travelAnswered = false
    /// "Show my trips" is paused for everyone (Friends › Your trips).
    @Published private(set) var travelPaused = false
    /// (0.27) Your groups (their lists), and their pictures by group id.
    @Published private(set) var groups = GroupBook()
    @Published private(set) var groupPictures: [String: Data] = [:]
    /// (0.27) Chat lines you haven't seen yet (set by `FriendChats`).
    @Published var unread = 0
    /// (0.27) "Take this trip" wants Plan open with this filled in (the home opens it once Friends has gone).
    @Published var planRequest: PlanRequest?

    struct PlanRequest: Equatable, Identifiable {
        let id = UUID()
        let to: Place
        let name: String
        let arriveBy: Date?
        let leaveAt: Date?
        static func == (a: PlanRequest, b: PlanRequest) -> Bool { a.id == b.id }
    }

    struct OpenedCode: Identifiable, Equatable {
        let card: FriendCard
        let name: String
        var id: String { card.account }
    }

    private var identity: FriendIdentity?
    private var device = ""
    private var state = Saved()
    private var lastAuto = Date.distantPast

    /// What's kept in the file.
    private struct Saved: Codable {
        var book: FriendBook?
        var cursor = 0
        var kindsVersion = 0
        var pending: [FriendPending] = []
        var vaultDirty = false
        // 0.26 (optional, so a 0.25 file still reads): the one-time screen's answer, the pause, who has this trip's
        // state, and a take-back that didn't go through yet
        var travelAnswered: Bool?
        var travelPaused: Bool?
        var travelSentTo: [String]?
        var travelClearDue: Bool?
        // 0.27 (optional, so an older file still reads): the groups, boxes waiting for a key, and who got your
        // picture because you share a group (not friends)
        var groups: GroupBook?
        var orphans: [RelayBox]?
        var picturesTo: [String]?
    }

    nonisolated static let folder: URL? = {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        var dir = base.appendingPathComponent("Friends", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        try? dir.setResourceValues(v)
        return dir
    }()
    private static var file: URL? { folder?.appendingPathComponent("friends.json") }
    private static let movedKey = "friends.movedAway"

    private init() {
        movedAway = UserDefaults.standard.bool(forKey: Self.movedKey)
        if let seed = FriendKeychain.get("seed"), let me = FriendIdentity(seed: seed),
           let dev = FriendKeychain.get("device").flatMap({ String(data: $0, encoding: .utf8) }) {
            identity = me
            device = dev
            if let f = Self.file, let d = try? Data(contentsOf: f), let s = try? FriendJSON.decoder.decode(Saved.self, from: d) { state = s }
            book = state.book ?? FriendBook(myName: "")
            travelAnswered = state.travelAnswered ?? false
            travelPaused = state.travelPaused ?? false
            myPicture = Self.readPicture("me")
            groups = state.groups ?? GroupBook()
            for id in Self.ids(state.book) + Self.memberIds(groups) { if let p = Self.readPicture(id) { pictures[id] = p } }
            for g in groups.groups { if let p = Self.readPicture("g-\(g.id)") { groupPictures[g.id] = p } }
        }
    }

    private static func memberIds(_ g: GroupBook) -> [String] { g.groups.filter(\.isIn).flatMap { $0.roster.members.map(\.id) } }

    // MARK: pictures (files beside the list: Friends/pic-<account>.jpg)

    private static func ids(_ b: FriendBook?) -> [String] {
        guard let b else { return [] }
        return b.friends.map(\.id) + b.incoming.map(\.id) + b.outgoing.map(\.id)
    }
    private static func pictureFile(_ id: String) -> URL? { folder?.appendingPathComponent("pic-\(id).jpg") }
    private static func readPicture(_ id: String) -> Data? { pictureFile(id).flatMap { try? Data(contentsOf: $0) } }
    private static func writePicture(_ id: String, _ d: Data?) {
        guard let f = pictureFile(id) else { return }
        if let d { try? d.write(to: f, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
        else { try? FileManager.default.removeItem(at: f) }
    }

    /// Your new picture (already cropped and made small), to every friend; nil takes it away (friends keep the last
    /// one they got until you pick another).
    func setPicture(_ jpeg: Data?) async {
        guard let me = identity, let b = book else { return }
        if let jpeg, jpeg.count > FriendPicture.maxBytes { return }
        myPicture = jpeg
        Self.writePicture("me", jpeg)
        state.vaultDirty = true
        if let jpeg {
            for f in b.friends { queuePicture(jpeg, me: me, to: f.card) }
            // (0.27) and to the people you share a group with who aren't your friends
            for c in coMemberCards(b) { queuePicture(jpeg, me: me, to: c) }
        }
        save()
        await sync(.now)
    }

    private func queuePicture(_ jpeg: Data, me: FriendIdentity, to card: FriendCard) {
        guard let d = try? FriendBox.seal(.picture(FriendPicture(jpeg: jpeg)), from: me, to: card) else { return }
        state.pending.append(FriendPending(op: .box, to: card.account, data: B64URL.encode(d), slot: "picture", ttl: 30 * 86400))
    }

    /// Keeps the pictures that came, and lets go of those of people no longer in the list (or a group with you).
    private func keepPictures(_ got: [String: Data]) {
        for (id, d) in got { pictures[id] = d; Self.writePicture(id, d) }
        let live = Set(Self.ids(book) + Self.memberIds(groups))
        for id in pictures.keys where !live.contains(id) { pictures[id] = nil; Self.writePicture(id, nil) }
    }

    // MARK: what the screens read

    var hasAccount: Bool { identity != nil }
    var myCard: FriendCard? { identity?.card }
    var account: String? { identity?.account }
    var backupWords: [String]? { identity?.words }
    /// The home shows its Friends button only once there's someone (a friend, or a request either way).
    var onHome: Bool { guard let b = book else { return false }; return !b.friends.isEmpty || !b.incoming.isEmpty || !b.outgoing.isEmpty }
    var waiting: Int { book?.incoming.count ?? 0 }
    /// (0.27) On the Friends button: requests waiting and chat lines not seen yet.
    var badge: Int { waiting + unread }
    var shareLink: URL? { identity.map { FriendLink.share($0.card, name: book?.myName ?? "") } }

    // MARK: the account

    /// A new account: made on the relay first, then kept here.
    func create(name: String) async throws {
        let me = FriendIdentity.random()
        let dev = RelaySign.newDevice()
        _ = try await FriendRelay(me: me, device: dev).register()
        adopt(me, device: dev, book: FriendBook(myName: name))
        state.vaultDirty = true
        save()
        await sync(.now)
    }

    enum RestoreError: Error { case badCode }

    /// The backup code typed on this phone: the account (and the friend list kept on the relay) comes here, and the
    /// phone it was on is signed out. Returns whether a friend list was found.
    @discardableResult
    func restore(words: [String], name: String) async throws -> Bool {
        guard let me = FriendIdentity(words: words) else { throw RestoreError.badCode }
        let dev = RelaySign.newDevice()
        let relay = FriendRelay(me: me, device: dev)
        _ = try await relay.register()
        var restored: FriendVaultContents?
        if let v = try? await relay.vaultGet(), let plain = try? FriendVault.open(v, me: me) {
            restored = try? FriendJSON.decoder.decode(FriendVaultContents.self, from: plain)
        }
        let b = restored?.book ?? FriendBook(myName: name)
        adopt(me, device: dev, book: b)
        groups = GroupBook(groups: restored?.groups ?? [])
        state.groups = groups
        FriendTimetables.shared.restore(restored?.timetable)
        FriendExtrasStore.shared.restore(restored?.extras)
        myPicture = restored?.picture
        Self.writePicture("me", myPicture)
        state.vaultDirty = restored == nil
        save()
        await sync(.now)
        return restored != nil
    }

    private func adopt(_ me: FriendIdentity, device dev: String, book b: FriendBook) {
        FriendKeychain.set("seed", me.seed)
        FriendKeychain.set("device", Data(dev.utf8))
        identity = me
        device = dev
        state = Saved(book: b, cursor: 0, kindsVersion: FriendMessage.kindsVersion, pending: [], vaultDirty: false)
        book = b
        movedAway = false
        UserDefaults.standard.removeObject(forKey: Self.movedKey)
    }

    /// Deletes the account: friends are told, the relay forgets it, and this phone forgets the keys.
    func deleteAccount() async {
        if let me = identity, let b = book {
            let relay = FriendRelay(me: me, device: device)
            var boxes = b.friends.compactMap { f -> FriendPending? in
                guard let d = try? FriendBox.seal(.unfriend, from: me, to: f.card) else { return nil }
                return FriendPending(op: .box, to: f.id, data: B64URL.encode(d))
            }
            // (0.27) out of every group too
            var g = groups
            for grp in g.current { boxes += pendings(g.leave(grp.id, me: me.account), me: me) }
            for chunk in stride(from: 0, to: boxes.count, by: 20).map({ Array(boxes[$0..<min($0 + 20, boxes.count)]) }) {
                _ = try? await relay.send(chunk)
            }
            try? await relay.leave()
        }
        forget(moved: false)
    }

    /// Off this phone (the relay still has the account: the backup code brings it back).
    private func forget(moved: Bool) {
        FriendKeychain.set("seed", nil)
        FriendKeychain.set("device", nil)
        if let f = Self.file { try? FileManager.default.removeItem(at: f) }
        for id in Array(pictures.keys) + ["me"] { Self.writePicture(id, nil) }
        pictures = [:]
        myPicture = nil
        travel = [:]
        sharingWith = 0
        travelAnswered = false
        travelPaused = false
        for g in groups.groups { Self.writePicture("g-\(g.id)", nil) }
        groups = GroupBook()
        groupPictures = [:]
        unread = 0
        FriendChats.shared.clearAll()
        FriendTimetables.shared.forgetAll()
        FriendExtrasStore.shared.forgetAll()
        FriendTogetherStore.shared.forgetAll()
        identity = nil
        device = ""
        state = Saved()
        book = nil
        opened = nil
        movedAway = moved
        UserDefaults.standard.set(moved, forKey: Self.movedKey)
        if moved {
            Notices.shared.show(title: "Friends moved to another phone",
                                body: "Your friends account was restored on another phone, so this one was signed out.", kind: "info")
        }
    }

    func dismissMoved() {
        movedAway = false
        UserDefaults.standard.removeObject(forKey: Self.movedKey)
    }

    // MARK: friends

    /// A link opened (haltewekker://friend?…): Friends opens with it. False: not a friend link.
    func handle(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "haltewekker", url.host?.lowercased() == "friend" else { return false }
        if let c = FriendLink.parse(url.absoluteString) { opened = OpenedCode(card: c.card, name: c.name) }
        showing = true
        return true
    }

    /// Someone's code (scanned, pasted or opened): a friend request goes to them.
    func add(_ code: OpenedCode) async -> FriendBook.Added? {
        guard let me = identity, var b = book else { return nil }
        let (result, effects) = b.add(code.card, name: code.name, myCard: me.card, now: Date())
        apply(b, effects)
        await sync(.now)
        return result
    }

    func accept(_ id: String) async { change { $0.accept(id, myCard: $1, now: Date()) }; await sync(.now) }
    func decline(_ id: String, block: Bool) async { change { b, _ in b.decline(id, block: block) }; await sync(.now) }
    func cancel(_ id: String) async { change { b, _ in b.cancel(id) }; await sync(.now) }
    func remove(_ id: String) async { change { b, _ in b.remove(id) }; await sync(.now) }
    func rename(_ name: String) async {
        change { b, _ in b.rename(name) }
        refreshGroupNames()
        await sync(.now)
    }

    private func change(_ f: (inout FriendBook, FriendCard) -> [FriendBook.Effect]) {
        guard let me = identity, var b = book else { return }
        let effects = f(&b, me.card)
        apply(b, effects)
    }

    /// The new list kept (and to be backed up), and what it says to send queued, in order.
    private func apply(_ b: FriendBook, _ effects: [FriendBook.Effect]) {
        guard let me = identity else { return }
        if b != book { state.vaultDirty = true }
        book = b
        state.book = b
        if travel.keys.contains(where: { !b.isFriend($0) }) { travel = travel.filter { b.isFriend($0.key) } }
        for e in effects {
            switch e {
            case .send(let card, let m):
                if let d = try? FriendBox.seal(m, from: me, to: card) {
                    state.pending.append(FriendPending(op: .box, to: card.account, data: B64URL.encode(d)))
                }
                // a request or a yes brings your picture along
                switch m {
                case .request, .accept: if let p = myPicture { queuePicture(p, me: me, to: card) }
                default: break
                }
            case .drop(let id): state.pending.append(FriendPending(op: .drop, to: id))
            case .block(let id): state.pending.append(FriendPending(op: .block, to: id))
            }
        }
        save()
    }

    private func save() {
        guard let f = Self.file, let d = try? FriendJSON.encoder.encode(state) else { return }
        try? d.write(to: f, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: groups and chat lines (0.27)

    var myAccount: String? { identity?.account }
    var myName: String { book?.myName ?? "" }

    /// A name for an account: a friend's, else the one a group gives them.
    func name(_ account: String) -> String {
        if account == identity?.account { return "You" }
        return book?.friend(account)?.name ?? groups.name(account) ?? "Someone"
    }

    /// The people you share a group with who aren't your friends (their cards from the groups' lists).
    private func coMemberCards(_ b: FriendBook) -> [FriendCard] {
        guard let me = identity?.account else { return [] }
        var seen = Set<String>()
        var out: [FriendCard] = []
        for g in groups.groups where g.isIn {
            for m in g.roster.members where m.id != me && !b.isFriend(m.id) && seen.insert(m.id).inserted { out.append(m.card) }
        }
        return out
    }

    /// Locks each of a group's boxes for its member (the group's id as `g`).
    private func pendings(_ sends: [GroupBook.Send], me: FriendIdentity) -> [FriendPending] {
        sends.compactMap { x in
            guard let d = try? FriendBox.seal(x.message, from: me, to: x.to, group: x.group) else { return nil }
            return FriendPending(op: .box, to: x.to.account, data: B64URL.encode(d), slot: x.slot)
        }
    }

    private func queue(_ sends: [GroupBook.Send]) {
        guard let me = identity, !sends.isEmpty else { return }
        for p in pendings(sends, me: me) { replacePending(p) }
    }

    /// Queued; a box for the same slot at the same person still waiting goes (only the newest matters).
    private func replacePending(_ p: FriendPending) {
        if let slot = p.slot { state.pending.removeAll { $0.op == .box && $0.to == p.to && $0.slot == slot } }
        state.pending.append(p)
    }

    private func setGroups(_ g: GroupBook) {
        if g != groups { state.vaultDirty = true }
        groups = g
        state.groups = g
        save()
    }

    /// After a batch: the groups as they are now, their pictures, and your picture to new people in them.
    private func takeGroups(_ r: FriendInbox.Result, me: FriendIdentity) {
        setGroups(r.groups)
        for (gid, d) in r.groupPictures {
            groupPictures[gid] = d.isEmpty ? nil : d
            Self.writePicture("g-\(gid)", d.isEmpty ? nil : d)
        }
        for n in r.groupNews {
            switch n {
            case .added(let g, let by): Notices.shared.show(title: "\(by) added you to “\(g)”", body: "Open Friends to see the group.", kind: "ok")
            case .removed(let g): Notices.shared.show(title: "You’re no longer in “\(g)”", body: "Its chat stays to read.", kind: "info")
            }
        }
        sharePictureWithGroups()
        refreshGroupNames()
        save()
    }

    /// Your picture to the people in your groups who haven't had it from you (and aren't your friends).
    private func sharePictureWithGroups() {
        guard let me = identity, let b = book, let jpeg = myPicture else { return }
        var had = Set(state.picturesTo ?? [])
        for c in coMemberCards(b) where !had.contains(c.account) {
            queuePicture(jpeg, me: me, to: c)
            had.insert(c.account)
        }
        state.picturesTo = had.isEmpty ? nil : had.sorted()
    }

    /// The lists you run carry your friends' (and your own) newest names.
    private func refreshGroupNames() {
        guard let me = identity, let b = book else { return }
        var g = groups
        let sends = g.refreshNames(friends: b.friends, me: me.account, myName: b.myName)
        guard !sends.isEmpty else { return }
        setGroups(g)
        queue(sends)
        save()
    }

    /// A new group of your friends (you run it). Gives its id.
    func createGroup(name: String, friends ids: [String], picture: Data?) async -> String? {
        guard let me = identity, let b = book else { return nil }
        let friends = ids.compactMap { b.friend($0) }
        var g = groups
        let id = GroupBook.newId()
        guard let made = g.create(id: id, name: name, friends: friends, me: me.card, myName: b.myName, now: Date()) else { return nil }
        let sends: [GroupBook.Send] = made.1
        setGroups(g)
        queue(sends)
        FriendChats.shared.note("You made the group", in: ChatKey.group(id))
        if let picture { setGroupPictureQueued(id, picture) }
        sharePictureWithGroups()
        save()
        await sync(.now)
        return id
    }

    func addToGroup(_ id: String, friends ids: [String]) async {
        guard let me = identity, let b = book else { return }
        let friends = ids.compactMap { b.friend($0) }
        var g = groups
        let sends = g.add(id, friends: friends, me: me.account)
        guard !sends.isEmpty else { return }
        setGroups(g)
        queue(sends)
        for f in friends { FriendChats.shared.note("You added \(f.name)", in: ChatKey.group(id)) }
        // the group's picture to the new ones
        if let p = groupPictures[id] { queue(g.pictureSends(id, jpeg: p, me: me.account, only: Set(ids))) }
        sharePictureWithGroups()
        save()
        await sync(.now)
    }

    func removeFromGroup(_ id: String, member: String) async {
        guard let me = identity else { return }
        let who = name(member)
        var g = groups
        let sends = g.remove(id, member: member, me: me.account)
        guard !sends.isEmpty else { return }
        setGroups(g)
        queue(sends)
        FriendChats.shared.note("You removed \(who)", in: ChatKey.group(id))
        save()
        await sync(.now)
    }

    func renameGroup(_ id: String, to name: String) async {
        guard let me = identity else { return }
        var g = groups
        let sends = g.rename(id, to: name, me: me.account)
        guard !sends.isEmpty else { return }
        setGroups(g)
        queue(sends)
        FriendChats.shared.note("You named the group “\(g.group(id)?.name ?? name)”", in: ChatKey.group(id))
        save()
        await sync(.now)
    }

    /// (you run it) The group's picture (nil takes it away), to everyone in it.
    func setGroupPicture(_ id: String, _ jpeg: Data?) async {
        setGroupPictureQueued(id, jpeg ?? Data())
        save()
        await sync(.now)
    }

    private func setGroupPictureQueued(_ id: String, _ jpeg: Data) {
        guard let me = identity, groups.group(id)?.isAdmin(me.account) == true, jpeg.count <= FriendPicture.maxBytes else { return }
        groupPictures[id] = jpeg.isEmpty ? nil : jpeg
        Self.writePicture("g-\(id)", jpeg.isEmpty ? nil : jpeg)
        queue(groups.pictureSends(id, jpeg: jpeg, me: me.account))
    }

    /// You leave a group: everyone in it is told. Its chat stays here to read until you delete it.
    func leaveGroup(_ id: String) async {
        guard let me = identity else { return }
        var g = groups
        let sends = g.leave(id, me: me.account)
        setGroups(g)
        queue(sends)
        FriendChats.shared.note("You left", in: ChatKey.group(id))
        save()
        await sync(.now)
    }

    /// A group you're no longer in, and its chat, off this phone.
    func forgetGroup(_ id: String) {
        var g = groups
        g.forget(id)
        setGroups(g)
        groupPictures[id] = nil
        Self.writePicture("g-\(id)", nil)
        FriendChats.shared.remove(ChatKey.group(id))
    }

    /// Who a chat line goes to: the friend, or everyone else in the group. Empty: nobody (not friends any more, or
    /// you're not in the group).
    func recipients(_ chat: String) -> [FriendCard] {
        guard let me = identity?.account else { return [] }
        if let gid = ChatKey.groupId(chat) {
            guard let g = groups.group(gid), g.isIn else { return [] }
            return g.others(me).map(\.card)
        }
        return book?.friend(chat).map { [$0.card] } ?? []
    }

    /// Locks a chat line once for everyone it goes to (the same `n` and `t` in each) and queues them. False: nobody to
    /// send it to.
    @discardableResult
    func queueLine(_ m: FriendMessage, chat: String, n: String, at: Date, line: String) -> Bool {
        guard let me = identity else { return false }
        let cards = recipients(chat)
        guard !cards.isEmpty else { return false }
        let g = ChatKey.groupId(chat)
        let t = Int(at.timeIntervalSince1970)
        guard let p = try? FriendBox.payload(m, from: me.account, at: Date(timeIntervalSince1970: TimeInterval(t)), id: n, group: g) else { return false }
        for c in cards {
            guard let d = try? FriendBox.seal(payload: p, from: me, to: c) else { continue }
            state.pending.append(FriendPending(op: .box, to: c.account, data: B64URL.encode(d), line: line))
        }
        save()
        return true
    }

    /// How far you got and read someone's lines in a chat (one box in their mailbox, replaced by the next).
    func queueSeen(_ s: ChatSeen, to account: String, chat: String) {
        guard let me = identity else { return }
        let g = ChatKey.groupId(chat)
        let card: FriendCard?
        if let g { card = groups.group(g)?.roster.member(account)?.card } else { card = book?.friend(account)?.card }
        guard let card, let d = try? FriendBox.seal(.seen(s), from: me, to: card, group: g) else { return }
        replacePending(FriendPending(op: .box, to: account, data: B64URL.encode(d), slot: g.map(GroupBook.seenSlot) ?? "seen"))
        save()
    }

    /// The groups' members (for pictures and names on screen).
    func group(_ id: String) -> FriendGroup? { groups.group(id) }

    // MARK: travelling now (0.26)

    /// Each friend and their "Show my trips" switch.
    var travelFriends: [(id: String, on: Bool)] { book?.friends.map { (id: $0.id, on: $0.showsTrips) } ?? [] }
    var hasFriends: Bool { !(book?.friends.isEmpty ?? true) }
    /// Rules' view of the one-time screen: nil, not answered yet.
    var travelConsent: Bool? { travelAnswered ? true : nil }

    /// The one-time screen, answered: show my trips (on) or not for now (paused; the switch in Friends turns it on).
    func answerTravel(show: Bool) {
        state.travelAnswered = true
        state.travelPaused = !show
        travelAnswered = true
        travelPaused = !show
        save()
        FriendTravelShare.shared.settingsChanged()
    }

    func setTravelPaused(_ paused: Bool) {
        state.travelPaused = paused
        travelPaused = paused
        save()
        FriendTravelShare.shared.settingsChanged()
    }

    /// "Show my trips" to one friend (kept in the list, so the backup has it too).
    func setShowTrips(_ id: String, _ on: Bool) {
        change { b, _ in b.showTrips(id, on); return [] }
        FriendTravelShare.shared.settingsChanged()
        Task { await sync(.auto) }
    }

    /// Puts this trip's state at each of `ids` (a box locked for each), and takes it back from those it went to before
    /// and doesn't now. One try (the next minute sends the next one anyway).
    func putTravel(_ s: TravelState, to ids: [String]) async {
        guard let me = identity, let b = book else { return }
        let relay = FriendRelay(me: me, device: device)
        let cards = ids.compactMap { b.friend($0)?.card }
        var sealed: [(to: String, data: Data)] = []
        for c in cards {
            if let d = try? FriendBox.seal(.travel(s), from: me, to: c) { sealed.append((to: c.account, data: d)) }
        }
        var got: [String] = []
        do {
            for start in stride(from: 0, to: sealed.count, by: 50) {
                let chunk = Array(sealed[start..<min(start + 50, sealed.count)])
                let r = try await relay.statePut(chunk, ttl: TravelAge.ttl)
                got += r.filter(\.ok).map(\.to)
            }
            let gone = TravelShareRules.toClear(sentTo: state.travelSentTo ?? [], now: ids)
            if !gone.isEmpty { try await relay.stateClear(gone) }
            state.travelSentTo = Array(Set((state.travelSentTo ?? []).filter { !gone.contains($0) } + got)).sorted()
            state.travelClearDue = nil
            sharingWith = got.count
            save()
        } catch FriendRelay.Failure.signedOut {
            forget(moved: true)
        } catch {
            // offline: what it did put stays known, so the trip's end takes it back
            if !got.isEmpty {
                state.travelSentTo = Array(Set((state.travelSentTo ?? []) + got)).sorted()
                save()
            }
        }
    }

    /// The trip ended (or sharing went off): your state goes from the relay, from everyone. If that can't go through
    /// now, the next check tries again (and the relay lets it go by itself within minutes).
    func clearTravel() async {
        sharingWith = 0
        guard let me = identity, !(state.travelSentTo ?? []).isEmpty || state.travelClearDue == true else { return }
        do {
            try await FriendRelay(me: me, device: device).stateClear(nil)
            state.travelSentTo = nil
            state.travelClearDue = nil
        } catch {
            state.travelClearDue = true
        }
        save()
    }

    /// Friends' states, read now (on the ride's tick, while Friends is open, as the app comes to the front).
    func fetchTravel(lane: Lane = .background) async {
        guard let me = identity else { return }
        await travelRead(FriendRelay(me: me, device: device), lane: lane)
    }

    private func travelRead(_ relay: FriendRelay, lane: Lane) async {
        guard let b = book, !b.friends.isEmpty else { travel = [:]; return }
        guard let states = try? await relay.stateGet(lane: lane), let me = identity else { return }
        travel = FriendInbox.readStates(states, book: b, me: me, now: Date())
        travelChecked = Date()
    }

    /// (in a check of the relay) a take-back still due, then friends' states.
    private func travelAfterSync(_ relay: FriendRelay, lane: Lane) async {
        if state.travelClearDue == true, !FriendTravelShare.shared.sharing {
            if (try? await relay.stateClear(nil)) != nil {
                state.travelSentTo = nil
                state.travelClearDue = nil
                save()
            }
        }
        await travelRead(relay, lane: lane)
    }

    /// Friends travelling now (fresh or a little old), the freshest first.
    func travelling(now: Date = Date()) -> [FriendTravelSeen] {
        travel.values.filter { TravelAge.freshness($0, now: now) != .gone && book?.isFriend($0.from) == true }
            .sorted { $0.sent > $1.sent }
    }

    // MARK: timetables (0.28)

    /// The switches as the vault keeps them (nil: never touched).
    private var vaultTimetable: TimetableSettings? {
        let s = FriendTimetables.shared.settings
        return s == TimetableSettings() ? nil : s
    }

    /// A timetable switch changed: what's shared follows at once (and the vault keeps the switches).
    func timetableSettingsChanged() {
        state.vaultDirty = true
        save()
        Task { await sync(.now) }
    }

    /// The people in groups you share your timetable with who aren't your friends.
    private func timetableGroupMembers(_ b: FriendBook, on: Set<String>) -> [String] {
        groups.groups.filter { $0.isIn && on.contains($0.id) }.flatMap { $0.roster.members.map(\.id) }.filter { !b.isFriend($0) }
    }

    /// A card for a friend, else for someone in a group with you.
    private func anyCard(_ id: String) -> FriendCard? { book?.friend(id)?.card ?? groups.card(id) }

    /// Who your timetable goes to now (`TimetableShareRules.recipients`).
    var timetableRecipients: [String] {
        guard let me = identity?.account, let b = book else { return [] }
        let tt = FriendTimetables.shared
        return TimetableShareRules.recipients(friends: b.friends.map(\.id), off: tt.off,
                                              groupMembers: timetableGroupMembers(b, on: tt.groupsOn), me: me, on: tt.answered && tt.on)
    }

    /// In a check of the relay: your timetable and area to whoever should have them and doesn't (`TimetableShareRules`),
    /// taken back from whoever shouldn't any more; friends' kept only while they're friends or in a group with you.
    private func timetableDue(_ me: FriendIdentity, now: Date) async {
        guard let b = book else { return }
        let tt = FriendTimetables.shared
        tt.keep(Set(b.friends.map(\.id) + Self.memberIds(groups)))
        let recipients: [String] = timetableRecipients
        var sent: TimetableShareRules.Sent? = tt.sent
        var areaSent: TimetableShareRules.Sent? = tt.areaSent
        var changed = false
        // taken back from those who shouldn't have it any more
        let gone: [String] = TimetableShareRules.takeBack(last: sent, recipients: recipients)
        if !gone.isEmpty {
            for id in gone {
                guard let c = anyCard(id), let d = try? FriendBox.seal(.timetable(.takenBack(at: now)), from: me, to: c) else { continue }
                replacePending(FriendPending(op: .box, to: id, data: B64URL.encode(d), slot: TimetableShareRules.timetableSlot,
                                             ttl: TimetableShareRules.timetableTTL))
            }
            sent = TimetableShareRules.afterTakeBack(sent, gone: gone)
            areaSent = TimetableShareRules.afterTakeBack(areaSent, gone: gone)
            changed = true
        }
        let had = Set(sent?.to ?? [])
        let fresh: Bool = recipients.contains { !had.contains($0) }
        if !recipients.isEmpty, tt.lookDue(now: now, newRecipients: fresh) {
            let (share, area) = await tt.readMine(now: now)
            if let share, let data = try? FriendJSON.encoder.encode(share) {
                let hash = TimetableShareRules.fingerprint(data)
                let due = TimetableShareRules.due(last: sent, hash: hash, recipients: recipients, at: now)
                for id in due {
                    guard let c = anyCard(id), let d = try? FriendBox.seal(.timetable(share), from: me, to: c) else { continue }
                    replacePending(FriendPending(op: .box, to: id, data: B64URL.encode(d), slot: TimetableShareRules.timetableSlot,
                                                 ttl: TimetableShareRules.timetableTTL))
                }
                if !due.isEmpty { sent = TimetableShareRules.after(sent, hash: hash, sent: due, everyone: recipients, at: now); changed = true }
            }
            if let area, let data = try? FriendJSON.encoder.encode(area) {
                let hash = TimetableShareRules.fingerprint(data)
                let due = TimetableShareRules.due(last: areaSent, hash: hash, recipients: recipients, at: now, every: TimetableShareRules.areaRefresh)
                for id in due {
                    guard let c = anyCard(id), let d = try? FriendBox.seal(.area(area), from: me, to: c) else { continue }
                    replacePending(FriendPending(op: .box, to: id, data: B64URL.encode(d), slot: TimetableShareRules.areaSlot,
                                                 ttl: TimetableShareRules.areaTTL))
                }
                if !due.isEmpty { areaSent = TimetableShareRules.after(areaSent, hash: hash, sent: due, everyone: recipients, at: now); changed = true }
            }
        }
        if changed {
            tt.didSend(sent, area: areaSent)
            save()
        }
    }

    // MARK: the extras (0.29)

    /// Locks one payload for each of these people (a friend, or someone in a group with you; the group's id as `g`)
    /// and queues it in `slot` (a box still waiting there for them goes: only the newest matters).
    func queueBox(_ m: FriendMessage, to ids: [String], slot: String, ttl: Int, group: String? = nil) {
        guard let me = identity, !ids.isEmpty else { return }
        let n: String = RelaySign.nonce()
        guard let p = try? FriendBox.payload(m, from: me.account, at: Date(), id: n, group: group) else { return }
        for id in ids where id != me.account {
            guard let c = anyCard(id), let d = try? FriendBox.seal(payload: p, from: me, to: c) else { continue }
            replacePending(FriendPending(op: .box, to: id, data: B64URL.encode(d), slot: slot, ttl: ttl))
        }
        save()
    }

    /// An extras switch changed: the vault keeps it, and what's shared follows at once.
    func extrasSettingsChanged() {
        state.vaultDirty = true
        save()
        Task { await sync(.now) }
    }

    // MARK: checking the relay

    enum Why {
        /// You did something, or Friends is open: now.
        case now
        /// Friends is open: every 30 s, in the background lane.
        case screen
        /// The app came to the front, or a background refresh: at most every 20 s.
        case auto
        /// (0.27) A chat is open: the mailbox every few seconds (friends' trips every 30 s of these).
        case chat
        /// (0.27) The ride's network tick during a trip: at most once a minute.
        case tick
    }

    private var lastChat = Date.distantPast
    private var lastTick = Date.distantPast

    /// Sends what's waiting, reads the mailbox, and backs up the list if it changed.
    func sync(_ why: Why) async {
        guard let me = identity, !syncing else { return }
        let now = Date()
        switch why {
        case .auto:
            guard now.timeIntervalSince(lastAuto) > 20 else { return }
            lastAuto = now
        case .chat:
            guard now.timeIntervalSince(lastChat) >= 6 else { return }
            lastChat = now
        case .tick:
            guard now.timeIntervalSince(lastTick) >= 55 else { return }
            lastTick = now
        case .now, .screen:
            break
        }
        syncing = true
        defer { syncing = false }
        let relay = FriendRelay(me: me, device: device)
        do {
            try await flush(relay)
            if state.kindsVersion < FriendMessage.kindsVersion {
                state.cursor = 0
                state.kindsVersion = FriendMessage.kindsVersion
            }
            var retry: [RelayBox] = state.orphans ?? []
            var orphans: [RelayBox] = []
            for _ in 0..<5 {
                let inbox = try await relay.inbox(after: state.cursor, lane: why == .now ? .urgent : .background)
                guard let b = book else { return }
                let r = FriendInbox.process(inbox.boxes, book: b, groups: groups, retry: retry, me: me, now: Date())
                retry = []
                orphans += r.orphans
                state.orphans = orphans.isEmpty ? nil : Array(orphans.suffix(FriendInbox.maxOrphans))
                apply(r.book, r.effects)
                takeGroups(r, me: me)
                keepPictures(r.pictures)
                for n in r.news {
                    let t = FriendInbox.banner(n)
                    Notices.shared.show(title: t.title, body: t.body, kind: "ok")
                }
                FriendChats.shared.take(r.chat)
                FriendTimetables.shared.take(r)
                FriendExtrasStore.shared.take(r)
                FriendTogetherStore.shared.take(r)
                state.cursor = inbox.cursor
                save()
                try await relay.ack(r.ack)
                if !inbox.more { break }
            }
            await timetableDue(me, now: Date())
            // (0.29) the extras: a wait on its way, at school, your plan for the wake-up buddy, delays on shared rides
            await FriendExtrasStore.shared.due(now: Date())
            // (0.30) part B: your scores for the friends leaderboard, free time together today
            await FriendTogetherStore.shared.due(now: Date())
            try await flush(relay)
            let statesDue = why != .chat || (travelChecked.map { now.timeIntervalSince($0) >= 30 } ?? true)
            if statesDue { await travelAfterSync(relay, lane: why == .now ? .urgent : .background) }
            if state.vaultDirty, let b = book,
               let plain = try? FriendJSON.encoder.encode(FriendVaultContents(book: b, picture: myPicture, groups: groups.groups.isEmpty ? nil : groups.groups,
                                                                              timetable: vaultTimetable,
                                                                              extras: FriendExtrasStore.shared.vaultSettings)) {
                let sealed = try FriendVault.seal(plain, me: me)
                try await relay.vaultPut(sealed)
                state.vaultDirty = false
                save()
            }
            offline = false
            lastChecked = Date()
            FriendChats.shared.refresh()
        } catch FriendRelay.Failure.signedOut {
            forget(moved: true)
        } catch FriendRelay.Failure.unknownAccount {
            // the relay lost it (or it was idle for over a year): made again with the same keys
            _ = try? await relay.register()
        } catch {
            offline = true
        }
    }

    /// Sends what's waiting, oldest first; stops at the first network failure (tried again next time). A box the
    /// relay refused for good (that account is gone, its mailbox is full) is let go.
    private func flush(_ relay: FriendRelay) async throws {
        while let first = state.pending.first {
            let count: Int
            do {
                switch first.op {
                case .drop:
                    count = 1
                    try await relay.drop(first.to)
                case .block:
                    count = 1
                    try await relay.block(first.to)
                case .box:
                    let run = Array(state.pending.prefix { $0.op == .box }.prefix(20))
                    count = run.count
                    _ = try await relay.send(run)
                    let lines = Set(run.compactMap(\.line))
                    if !lines.isEmpty { FriendChats.shared.markSent(lines) }
                }
            } catch FriendRelay.Failure.refused(_, _) {
                // (a request the relay will never take: let it go rather than hold up the rest)
                state.pending.removeFirst()
                save()
                continue
            }
            state.pending.removeFirst(count)
            save()
        }
    }
}
