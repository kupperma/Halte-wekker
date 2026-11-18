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
            myPicture = Self.readPicture("me")
            for id in Self.ids(state.book) { if let p = Self.readPicture(id) { pictures[id] = p } }
        }
    }

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
        }
        save()
        await sync(.now)
    }

    private func queuePicture(_ jpeg: Data, me: FriendIdentity, to card: FriendCard) {
        guard let d = try? FriendBox.seal(.picture(FriendPicture(jpeg: jpeg)), from: me, to: card) else { return }
        state.pending.append(FriendPending(op: .box, to: card.account, data: B64URL.encode(d), slot: "picture", ttl: 30 * 86400))
    }

    /// Keeps the pictures that came, and lets go of those of people no longer in the list.
    private func keepPictures(_ got: [String: Data]) {
        for (id, d) in got { pictures[id] = d; Self.writePicture(id, d) }
        let live = Set(Self.ids(book))
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
            let boxes = b.friends.compactMap { f -> FriendPending? in
                guard let d = try? FriendBox.seal(.unfriend, from: me, to: f.card) else { return nil }
                return FriendPending(op: .box, to: f.id, data: B64URL.encode(d))
            }
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
    func rename(_ name: String) async { change { b, _ in b.rename(name) }; await sync(.now) }

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

    // MARK: checking the relay

    enum Why {
        /// You did something, or Friends is open: now.
        case now
        /// Friends is open: every 30 s, in the background lane.
        case screen
        /// The app came to the front, or a background refresh: at most every 20 s.
        case auto
    }

    /// Sends what's waiting, reads the mailbox, and backs up the list if it changed.
    func sync(_ why: Why) async {
        guard let me = identity, !syncing else { return }
        let now = Date()
        if why == .auto {
            guard now.timeIntervalSince(lastAuto) > 20 else { return }
            lastAuto = now
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
            for _ in 0..<5 {
                let inbox = try await relay.inbox(after: state.cursor, lane: why == .now ? .urgent : .background)
                guard let b = book else { return }
                let r = FriendInbox.process(inbox.boxes, book: b, me: me, now: Date())
                apply(r.book, r.effects)
                keepPictures(r.pictures)
                for n in r.news {
                    let t = FriendInbox.banner(n)
                    Notices.shared.show(title: t.title, body: t.body, kind: "ok")
                }
                state.cursor = inbox.cursor
                save()
                try await relay.ack(r.ack)
                if !inbox.more { break }
            }
            try await flush(relay)
            if state.vaultDirty, let b = book, let plain = try? FriendJSON.encoder.encode(FriendVaultContents(book: b, picture: myPicture)) {
                let sealed = try FriendVault.seal(plain, me: me)
                try await relay.vaultPut(sealed)
                state.vaultDirty = false
                save()
            }
            offline = false
            lastChecked = Date()
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
