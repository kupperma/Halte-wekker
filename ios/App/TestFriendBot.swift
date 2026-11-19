import CoreLocation
import Foundation
import UIKit

/// Test friend (0.30.1): a bot to try every Friends feature with before anyone you know has the app. It is a real
/// second Friends account made on this phone (its own seed and keys, its own registration on the relay), kept in its
/// own file (Friends/testfriend.json: not in a backup, not in the vault, never in a shared log), and it talks to you
/// only through the live relay with the very same boxes a friend's phone would send. Its brain (`TestFriendBrain`)
/// runs only inside your app's own checks of the relay (`FriendStore.sync`, right after it sends what you wrote): no
/// loop of its own. iOS only for now.
@MainActor
final class TestFriendBot: ObservableObject {
    static let shared = TestFriendBot()

    /// Its account while there is one (nil: no test friend, or it's leaving).
    @Published private(set) var account: String?
    @Published private(set) var working = false
    /// Its pretend trip, wait and campus, for its controls.
    @Published private(set) var trip: TestTrip?
    @Published private(set) var wait: TestWait?
    @Published private(set) var campus = false
    /// What it last did, in words (under its controls).
    @Published private(set) var note: String?

    private struct Saved: Codable {
        var seed: Data
        var device: String
        var book: FriendBook
        var groups = GroupBook()
        var cursor = 0
        var pending: [FriendPending] = []
        /// Its hello (and its timetable and area) went, once you were friends.
        var greeted = false
        var timetableAt: Date?
        var trip: TestTrip?
        var tripSent: Date?
        /// A `travel` state of its is on the relay (taken back when the trip is over).
        var tripPut = false
        var wait: TestWait?
        var waitSent: Date?
        var campus = false
        /// Groups it said hello in, and your waits it answered.
        var hello: [String] = []
        var waitsAnswered: [String] = []
        /// Being removed: it leaves the relay (tried again at the next check if the network was away).
        var leaving = false
    }

    private var saved: Saved?
    private var busy = false
    private var leavingNow = false

    private static var file: URL? { FriendStore.folder?.appendingPathComponent("testfriend.json") }
    /// Its `travel` states and its wait move on at most this often (each check of yours).
    private static let every: TimeInterval = 20

    private init() {
        if let f = Self.file, let d = try? Data(contentsOf: f), let s = try? FriendJSON.decoder.decode(Saved.self, from: d) { saved = s }
        publish()
    }

    private func save() {
        guard let f = Self.file else { return }
        if let s = saved, let d = try? FriendJSON.encoder.encode(s) {
            try? d.write(to: f, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } else if saved == nil {
            try? FileManager.default.removeItem(at: f)
        }
    }

    private func publish() {
        let a: String? = saved.flatMap { s in s.leaving ? nil : FriendIdentity(seed: s.seed)?.account }
        if a != account { account = a }
        if saved?.trip != trip { trip = saved?.trip }
        if saved?.wait != wait { wait = saved?.wait }
        let c: Bool = saved?.campus ?? false
        if c != campus { campus = c }
    }

    private func say(_ s: String) { note = s }

    // MARK: what the screens read

    var exists: Bool { account != nil }
    func isBot(_ id: String) -> Bool { account != nil && account == id }
    /// You're friends (it can do things for you now).
    var isFriend: Bool {
        guard let a = account else { return false }
        return FriendStore.shared.book?.isFriend(a) == true
    }

    /// What your vault keeps, without it.
    func scrubbed(_ c: FriendVaultContents) -> FriendVaultContents {
        guard let s = saved, let a = FriendIdentity(seed: s.seed)?.account else { return c }
        return TestFriendBrain.scrub(c, bot: a)
    }

    private var user: FriendCard? { FriendStore.shared.myCard }
    private func relay(_ me: FriendIdentity, _ s: Saved) -> FriendRelay { FriendRelay(me: me, device: s.device, label: nil) }

    // MARK: adding and removing

    /// While a look of its own is on its way (a control waits for it, so neither undoes the other).
    private func idle() async {
        var n = 0
        while busy, n < 150 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            n += 1
        }
    }

    /// Makes it (its account on the relay), and it sends you a friend request with its picture.
    func add() async {
        guard saved == nil || saved?.leaving == true, !working, let you = user else { return }
        if saved?.leaving == true { await finishLeave() }
        guard saved == nil else { return }
        working = true
        defer { working = false }
        let me = FriendIdentity.random()
        let dev: String = RelaySign.newDevice()
        do {
            _ = try await FriendRelay(me: me, device: dev, label: nil).register()
        } catch {
            say("Couldn’t reach the relay. Check your connection and try again.")
            return
        }
        var book = FriendBook(myName: TestFriendBrain.name)
        let (_, effects) = book.add(you, name: FriendStore.shared.myName, myCard: me.card, now: Date())
        var s = Saved(seed: me.seed, device: dev, book: book)
        for e in effects {
            guard case .send(let card, .request(var intro)) = e else { continue }
            intro.note = TestFriendBrain.note
            enqueue(&s, .request(intro), to: card, me: me)
            if let jpeg = Self.picture() {
                enqueue(&s, .picture(FriendPicture(jpeg: jpeg)), to: card, me: me, slot: "picture", ttl: 30 * 86400)
            }
        }
        saved = s
        save()
        publish()
        say("Test friend sent you a friend request. Accept it under “Want to be friends”.")
        await check()
        await FriendStore.shared.sync(.now)
    }

    /// It leaves: out of its groups, off the relay (`/f/v1/leave`), its chat and everything of it off this phone.
    func remove() async {
        await idle()
        guard var s = saved else { return }
        let id: String? = FriendIdentity(seed: s.seed)?.account
        s.leaving = true
        saved = s
        save()
        publish()
        if let id {
            let store = FriendStore.shared
            if store.book?.isFriend(id) == true {
                await store.remove(id)
            } else if store.book?.incoming.contains(where: { $0.id == id }) == true {
                await store.decline(id, block: false)
            } else if store.book?.outgoing.contains(where: { $0.id == id }) == true {
                await store.cancel(id)
            }
            FriendChats.shared.remove(ChatKey.friend(id))
        }
        await finishLeave()
        note = nil
    }

    /// Your own friends account went (deleted, or moved to another phone): it goes too.
    func userGone() {
        guard var s = saved else { return }
        s.leaving = true
        saved = s
        save()
        publish()
        Task { await self.finishLeave() }
    }

    private func finishLeave() async {
        guard let s = saved, s.leaving, !leavingNow, let me = FriendIdentity(seed: s.seed) else { return }
        leavingNow = true
        defer { leavingNow = false }
        let r: FriendRelay = relay(me, s)
        // (every group it's in hears it left, as from any member)
        var g: GroupBook = s.groups
        var boxes: [FriendPending] = []
        for grp in g.current {
            for x in g.leave(grp.id, me: me.account) {
                guard let d = try? FriendBox.seal(x.message, from: me, to: x.to, group: x.group) else { continue }
                boxes.append(FriendPending(op: .box, to: x.to.account, data: B64URL.encode(d), slot: x.slot))
            }
        }
        for start in stride(from: 0, to: boxes.count, by: 20) {
            _ = try? await r.send(Array(boxes[start..<min(start + 20, boxes.count)]))
        }
        if s.tripPut { _ = try? await r.stateClear(nil) }
        do {
            try await r.leave()
        } catch FriendRelay.Failure.unknownAccount {
            // (gone already)
        } catch {
            return
        }
        saved = nil
        save()
        publish()
    }

    // MARK: its brain, inside your checks

    /// One look: what's waiting goes, its mailbox is read and answered, its pretend trip and wait move on. Called by
    /// `FriendStore.sync` right after your own boxes went, so its answers come back in the same check.
    func check() async {
        guard let s0 = saved, !busy else { return }
        if s0.leaving { await finishLeave(); return }
        guard let me = FriendIdentity(seed: s0.seed), let you = user else { return }
        busy = true
        defer { busy = false }
        var s: Saved = s0
        let r: FriendRelay = relay(me, s)
        let now = Date()
        do {
            try await flush(&s, r)
            let inbox: RelayInbox = try await r.inbox(after: s.cursor)
            let res: FriendInbox.Result = FriendInbox.process(inbox.boxes, book: s.book, groups: s.groups, me: me, now: now)
            s.book = res.book
            s.groups = res.groups
            apply(&s, res.effects, me: me)
            // it says yes to you at once
            if s.book.incoming.contains(where: { $0.id == you.account }) {
                let yes: [FriendBook.Effect] = s.book.accept(you.account, myCard: me.card, now: now)
                apply(&s, yes, me: me)
            }
            if s.book.isFriend(you.account), !s.greeted {
                s.greeted = true
                line(&s, ChatText(text: TestFriendBrain.hello), chat: you.account, me: me)
                shareTimetable(&s, me: me, now: now)
            } else if s.greeted, s.book.isFriend(you.account),
                      now.timeIntervalSince(s.timetableAt ?? .distantPast) >= 20 * 3600 {
                shareTimetable(&s, me: me, now: now)
            }
            greetGroups(&s, me: me)
            answer(&s, res, you: you.account, me: me)
            s.cursor = inbox.cursor
            saved = s
            save()
            try await r.ack(res.ack)
            await pretend(&s, r, me: me, you: you, now: now)
            try await flush(&s, r)
            // removed as a friend some other way (their page's "Remove"): it leaves too
            if s.greeted, !s.book.isFriend(you.account), !s.book.incoming.contains(where: { $0.id == you.account }) {
                s.leaving = true
            }
        } catch FriendRelay.Failure.unknownAccount {
            _ = try? await r.register()
        } catch {
            // (offline: next check)
        }
        // (removed meanwhile: that stays)
        if saved?.leaving == true { s.leaving = true }
        saved = s
        save()
        publish()
        if s.leaving { await finishLeave() }
    }

    /// Sends what's waiting, 20 at a time; a box the relay refuses for good is let go.
    private func flush(_ s: inout Saved, _ r: FriendRelay) async throws {
        while !s.pending.isEmpty {
            let run: [FriendPending] = Array(s.pending.prefix(20))
            do {
                _ = try await r.send(run)
            } catch FriendRelay.Failure.refused(_, _) {
                // (let it go rather than hold up the rest)
            }
            s.pending.removeFirst(run.count)
        }
    }

    /// The list's effects: boxes to send (its picture along with a yes).
    private func apply(_ s: inout Saved, _ effects: [FriendBook.Effect], me: FriendIdentity) {
        for e in effects {
            guard case .send(let card, let m) = e else { continue }
            enqueue(&s, m, to: card, me: me)
            if case .accept = m, let jpeg = Self.picture() {
                enqueue(&s, .picture(FriendPicture(jpeg: jpeg)), to: card, me: me, slot: "picture", ttl: 30 * 86400)
            }
        }
    }

    /// One box for one person (a box waiting in the same slot for them goes).
    private func enqueue(_ s: inout Saved, _ m: FriendMessage, to card: FriendCard, me: FriendIdentity, slot: String? = nil, ttl: Int? = nil,
                         group: String? = nil) {
        guard let d = try? FriendBox.seal(m, from: me, to: card, group: group) else { return }
        if let slot { s.pending.removeAll { $0.to == card.account && $0.slot == slot } }
        s.pending.append(FriendPending(op: .box, to: card.account, data: B64URL.encode(d), slot: slot, ttl: ttl))
    }

    /// A line in a chat: to you (`chat` = your account), or to everyone else in a group ("g." + its id), one payload
    /// locked for each.
    private func line(_ s: inout Saved, _ text: ChatText, chat: String, me: FriendIdentity) {
        post(&s, .message(text), chat: chat, me: me)
    }

    private func post(_ s: inout Saved, _ m: FriendMessage, chat: String, me: FriendIdentity, slot: String? = nil, ttl: Int? = nil) {
        let gid: String? = ChatKey.groupId(chat)
        var cards: [FriendCard] = []
        if let gid {
            guard let g = s.groups.group(gid), g.isIn else { return }
            cards = g.others(me.account).map(\.card)
        } else if let f = s.book.friend(chat) {
            cards = [f.card]
        }
        guard !cards.isEmpty, let p = try? FriendBox.payload(m, from: me.account, at: Date(), id: RelaySign.nonce(), group: gid) else { return }
        for c in cards {
            guard let d = try? FriendBox.seal(payload: p, from: me, to: c) else { continue }
            if let slot { s.pending.removeAll { $0.to == c.account && $0.slot == slot } }
            s.pending.append(FriendPending(op: .box, to: c.account, data: B64URL.encode(d), slot: slot, ttl: ttl))
        }
    }

    /// Hello in each group it's in and hasn't said it in yet.
    private func greetGroups(_ s: inout Saved, me: FriendIdentity) {
        for g in s.groups.current where !s.hello.contains(g.id) {
            s.hello.append(g.id)
            line(&s, ChatText(text: TestFriendBrain.groupHello(g.name)), chat: ChatKey.group(g.id), me: me)
        }
    }

    /// Your lines (one-to-one and in groups) answered, marked as read; your waits answered "I’ll wait".
    private func answer(_ s: inout Saved, _ res: FriendInbox.Result, you: String, me: FriendIdentity) {
        var newest: [String: Int] = [:]
        for item in res.chat {
            guard case .line(let m) = item.what, m.from == you else { continue }
            newest[item.chat] = max(newest[item.chat] ?? Int.min, m.t)
            switch m.content {
            case .text(let t):
                if let a = t.answer {
                    if let r = TestFriendBrain.reply(toAnswer: a) { line(&s, ChatText(text: r), chat: item.chat, me: me) }
                } else if let r = TestFriendBrain.reply(to: t.text) {
                    line(&s, ChatText(text: r), chat: item.chat, me: me)
                }
            case .trip(let c):
                for r in TestFriendBrain.replies(toTrip: c, n: m.n) { line(&s, r, chat: item.chat, me: me) }
            case .note:
                break
            }
        }
        // (read at once: "Read" under your line)
        for (chat, t) in newest {
            let gid: String? = ChatKey.groupId(chat)
            let card: FriendCard? = gid.flatMap { s.groups.group($0)?.roster.member(you)?.card } ?? s.book.friend(you)?.card
            guard let card else { continue }
            enqueue(&s, .seen(ChatSeen(got: t, read: t)), to: card, me: me, slot: gid.map(GroupBook.seenSlot) ?? "seen", group: gid)
        }
        if let w = res.waits[you], w.wait.phase != .off, !s.waitsAnswered.contains(w.wait.id) {
            s.waitsAnswered = Array((s.waitsAnswered + [w.wait.id]).suffix(20))
            line(&s, TestFriendBrain.reply(toWait: w.wait.id), chat: w.chat, me: me)
        }
    }

    // MARK: its timetable and area

    private func shareTimetable(_ s: inout Saved, me: FriendIdentity, now: Date) {
        guard let you = s.book.friends.first?.card else { return }
        s.timetableAt = now
        let mine: TimetableShare? = FriendTimetables.shared.mine
        let tt: TimetableShare = TestFriendBrain.timetable(mine: mine, now: now)
        enqueue(&s, .timetable(tt), to: you, me: me, slot: TimetableShareRules.timetableSlot, ttl: TimetableShareRules.timetableTTL)
        if let a = Self.area() {
            enqueue(&s, .area(a), to: you, me: me, slot: TimetableShareRules.areaSlot, ttl: TimetableShareRules.areaTTL)
        }
    }

    /// Where its trips start: the stops near your Home you share (public stops, never the address), the NS station
    /// nearest Home, and your school.
    private static func area() -> TimetableArea? {
        let yours: TimetableArea? = FriendTimetables.shared.myArea
        let home: GeoPoint = Place.home.point
        var station: TimetableArea.Station? = yours?.station
        if station == nil, let st = NearestStation.pick(home, in: NSCodes.shared.stations, within: 30_000) {
            station = TimetableArea.Station(name: st.name, code: st.code, id: nil, lat: st.lat, lon: st.lon)
        }
        let school = Place.school
        let sid: String? = school.ids.first.flatMap { $0.contains(",") ? nil : $0 }
        let spot = TripCard.Spot(name: RoleWords.current.school, id: sid, lat: round5(school.coordinate.latitude),
                                 lon: round5(school.coordinate.longitude))
        let a = TimetableArea(stops: yours?.stops ?? [], station: station, school: yours?.school ?? spot, early: 10)
        return TimetableArea.valid(a)
    }

    private static func round5(_ v: Double) -> Double { (v * 100_000).rounded() / 100_000 }

    // MARK: pretending

    /// Its trip's state at you (every `every` seconds), its wait moving closer; taken back when they're over.
    private func pretend(_ s: inout Saved, _ r: FriendRelay, me: FriendIdentity, you: FriendCard, now: Date) async {
        guard s.book.isFriend(you.account) else { return }
        if let t = s.trip {
            if TestTripSim.over(t, now: now) {
                s.trip = nil
                if s.tripPut, (try? await r.stateClear(nil)) != nil { s.tripPut = false }
                let last: String = t.stops.last?.name ?? "there"
                line(&s, ChatText(text: "Made it to \(last)! (That was a pretend trip.)"), chat: you.account, me: me)
            } else if now.timeIntervalSince(s.tripSent ?? .distantPast) >= Self.every, let st = TestTripSim.state(t, now: now),
                      let d = try? FriendBox.seal(.travel(st), from: me, to: you) {
                if let res = try? await r.statePut([(to: you.account, data: d)], ttl: TravelAge.ttl), res.contains(where: \.ok) {
                    s.tripSent = now
                    s.tripPut = true
                }
            }
        } else if s.tripPut, (try? await r.stateClear(nil)) != nil {
            s.tripPut = false
        }
        if let w = s.wait, now.timeIntervalSince(s.waitSent ?? .distantPast) >= Self.every || TestWaitSim.over(w, now: now) {
            enqueue(&s, .wait(TestWaitSim.body(w, now: now)), to: you, me: me, slot: WaitRules.slot, ttl: WaitRules.ttl)
            s.waitSent = now
            if TestWaitSim.over(w, now: now) { s.wait = nil }
        }
    }

    /// One of its controls: changes what it keeps, then a check of yours (which runs its brain) at once.
    private func act(_ f: (inout Saved, FriendIdentity, FriendCard) -> String?) async {
        await idle()
        guard var s = saved, !s.leaving, let me = FriendIdentity(seed: s.seed), let you = user, s.book.isFriend(you.account) else {
            say("Accept the test friend’s request first.")
            return
        }
        if let n = f(&s, me, you) { say(n) }
        saved = s
        save()
        publish()
        await check()
        await FriendStore.shared.sync(.now)
    }

    /// "Pretend I’m travelling": a real bus or train near your Home (the NS station nearest it first) for 10 minutes.
    func pretendTravel() async {
        if trip != nil {
            await act { s, _, _ in
                s.trip = nil
                return "Stopped pretending to travel."
            }
            return
        }
        working = true
        let found: TestTrip? = await Self.realTrip(now: Date())
        working = false
        guard let t = found else {
            say("Couldn’t find a bus or train near your Home right now. Try again in a minute.")
            return
        }
        await act { s, me, you in
            s.trip = t
            s.tripSent = nil
            s.wait = nil
            let what: String = t.isTrain ? "the \(t.line)" : "bus \(t.line)"
            let to: String = t.stops.last?.name ?? ""
            line(&s, ChatText(text: "I’m taking \(what) from \(t.stops.first?.name ?? "") to \(to) (pretend, for 10 minutes). Follow me in Travelling now!"),
                 chat: you.account, me: me)
            return "Travelling on \(what) to \(to) until \(TimetableDays.hhmm(TestTripSim.end(t)))."
        }
    }

    /// "Ask you to wait for me": at the station (or stop) nearest your Home, coming closer for 5 minutes.
    func askToWait() async {
        guard let stop = Self.nearStop() else {
            say("There’s no station near your Home to wait at.")
            return
        }
        await act { s, _, _ in
            s.wait = TestWait(id: RelaySign.nonce(), stop: stop, start: Date())
            s.waitSent = nil
            return "Asked you to wait at \(stop.name). It gets there in 5 minutes."
        }
    }

    /// "Pretend I’m on campus" (and back).
    func toggleCampus() async {
        await act { s, me, you in
            let now = Date()
            s.campus.toggle()
            if s.campus {
                let until: Date = now.addingTimeInterval(4 * 3600)
                let body = CampusState(on: true, school: RoleWords.current.school, since: now.addingTimeInterval(-20 * 60), until: until)
                enqueue(&s, .campus(body), to: you, me: me, slot: CampusRules.slot, ttl: CampusRules.ttl(until: until, now: now))
                return "On campus now (for 4 hours, or until you tap again)."
            }
            enqueue(&s, .campus(CampusState(on: false)), to: you, me: me, slot: CampusRules.slot, ttl: 3600)
            return "Left campus."
        }
    }

    /// "Share scores": its fastest trips on your routes, for the leaderboard with friends.
    func shareScores() async {
        let mine: [ScoreTrip] = FriendTogetherStore.myTrips()
        await act { s, me, you in
            let rides: Int = FriendTogetherStore.shared.count(with: me.account)
            enqueue(&s, .scores(TestFriendBrain.scores(mine: mine, rides: rides, now: Date())), to: you, me: me,
                    slot: ScoresRules.slot, ttl: ScoresRules.ttl)
            return "Shared its scores: see Friends › Leaderboard with friends."
        }
    }

    /// "Pretend we rode together": a ride on your phone's history with it (as if it had been on your bus or train),
    /// and a line about it.
    func pretendRodeTogether() async {
        let now = Date()
        let from: String = Self.nearStop()?.name ?? "the station"
        let to: String = trip?.stops.last?.name ?? RoleWords.current.school
        let ride = RideTogether(trip: "test-friend-\(Int(now.timeIntervalSince1970))", day: TimetableDays.key(now), label: "SPR",
                                from: from, to: to, dep: now.addingTimeInterval(-25 * 60), with: [])
        await act { s, me, you in
            var r = ride
            r.with = [me.account]
            FriendTogetherStore.shared.addPretend(r)
            line(&s, ChatText(text: "That was fun, riding together from \(from)! (Pretend: it’s on my page under Rides together.)"),
                 chat: you.account, me: me)
            return "A ride together went in your history."
        }
    }

    /// "Wake-up buddy: pretend I haven’t left": its plan said leave 6 minutes ago, for a train in 4. (Your phone tells
    /// you once a day per friend, and not if it pretended to travel or wait in the last hour.)
    func buddyNotLeft() async {
        let stop: TripCard.Spot? = Self.nearStop()
        let next: TripCard.Spot? = Self.nextStation()
        await act { s, me, you in
            let now = Date()
            s.trip = nil
            s.wait = nil
            var ride: TripCard.Ride?
            if let stop, let next { ride = TestFriendBrain.ride(from: stop, to: next, train: true, now: now, inMinutes: 4, id: "test-friend-buddy-\(Int(now.timeIntervalSince1970))") }
            enqueue(&s, .buddy(TestFriendBrain.buddy(now: now, ride: ride)), to: you, me: me, slot: BuddyRules.slot, ttl: BuddyRules.ttl)
            return "Its plan said leave at \(TimetableDays.hhmm(now.addingTimeInterval(-6 * 60))) and it hasn’t: your phone should tell you now."
        }
    }

    // MARK: places near your Home (never the address)

    private static func nearStation() -> NSStation? { NearestStation.pick(Place.home.point, in: NSCodes.shared.stations, within: 30_000) }

    /// The NS station nearest your Home, as a stop.
    private static func nearStop() -> TripCard.Spot? {
        guard let st = nearStation() else { return nil }
        return TripCard.Spot(name: st.name, lat: st.lat, lon: st.lon)
    }

    /// The next station on from there.
    private static func nextStation() -> TripCard.Spot? {
        guard let a = nearStation() else { return nil }
        var best: (NSStation, Double)?
        for st in NSCodes.shared.stations where st.code != a.code {
            let d: Double = Geo.metres(a.point, st.point)
            if d >= 1500, best.map({ d < $0.1 }) ?? true { best = (st, d) }
        }
        guard let b = best?.0 else { return nil }
        return TripCard.Spot(name: b.name, lat: b.lat, lon: b.lon)
    }

    /// A real bus or train leaving soon: from the NS station nearest Home (a train), else the stop nearest Home; its
    /// stops from the live data. Without an answer: a Sprinter to the next station.
    private static func realTrip(now: Date) async -> TestTrip? {
        var places: [CLLocationCoordinate2D] = []
        if let st = nearStation() { places.append(CLLocationCoordinate2D(latitude: st.lat, longitude: st.lon)) }
        places.append(Place.home.coordinate)
        for (i, c) in places.enumerated() {
            let near: [Transit.NearStop] = await Transit.nearStops(c)
            let stop: Transit.NearStop? = i == 0 && places.count > 1 ? near.first(where: { $0.rail }) : near.first
            guard let stop else { continue }
            if let t = await rideFrom(stop, now: now) { return t }
        }
        return TestTripSim.fallback(home: Place.home.point, stations: NSCodes.shared.stations, start: now)
    }

    private static func rideFrom(_ stop: Transit.NearStop, now: Date) async -> TestTrip? {
        let deps: [BoardDeparture] = await Transit.board(stopIds: [stop.id], n: 20)
        let soon: [BoardDeparture] = deps.filter { d in
            !d.tripId.isEmpty && !d.cancelled && d.time > now.addingTimeInterval(-60) && d.time < now.addingTimeInterval(45 * 60)
        }
        for d in soon.prefix(3) {
            guard let stops = await Transit.boardStops(d.tripId) else { continue }
            let here = GeoPoint(lat: stop.lat, lon: stop.lon)
            var at = 0
            var best = Double.greatestFiniteMagnitude
            for (i, s) in stops.enumerated() {
                let m: Double = Geo.metres(here, s.point)
                if m < best { best = m; at = i }
            }
            let real: [TestTripSim.RealStop] = stops[at...].map { s in
                TestTripSim.RealStop(name: s.name, lat: s.point.lat, lon: s.point.lon, time: s.departure ?? s.arrival)
            }
            let line: String = d.train ? Transit.trainLabel(d.line) : d.line
            if let t = TestTripSim.make(mode: d.train ? "train" : "bus", line: line, num: nil, trip: d.tripId, stops: real,
                                        dest: d.headsign, start: now) {
                return t
            }
        }
        return nil
    }

    // MARK: its picture

    /// A 256 px square: a test tube on violet to teal, and "TEST" under it.
    static func picture() -> Data? {
        let side: CGFloat = 256
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let img: UIImage = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { ctx in
            let cg: CGContext = ctx.cgContext
            let colours: [CGColor] = [UIColor(red: 0.42, green: 0.27, blue: 0.85, alpha: 1).cgColor,
                                      UIColor(red: 0.10, green: 0.62, blue: 0.72, alpha: 1).cgColor]
            let stops: [CGFloat] = [0, 1]
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colours as CFArray, locations: stops) {
                cg.drawLinearGradient(g, start: .zero, end: CGPoint(x: side, y: side), options: [])
            }
            let cfg = UIImage.SymbolConfiguration(pointSize: 96, weight: .semibold)
            if let sym = UIImage(systemName: "testtube.2", withConfiguration: cfg)?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                let sz: CGSize = sym.size
                sym.draw(in: CGRect(x: (side - sz.width) / 2, y: (side - sz.height) / 2 - 22, width: sz.width, height: sz.height))
            }
            let text = "TEST" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 40, weight: .heavy), .foregroundColor: UIColor.white]
            let ts: CGSize = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: (side - ts.width) / 2, y: side - ts.height - 28), withAttributes: attrs)
        }
        guard let png = img.pngData() else { return nil }
        return FriendPictureMaker.make(from: png)
    }
}
