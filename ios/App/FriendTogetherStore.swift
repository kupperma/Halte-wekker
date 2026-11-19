import Foundation
import UIKit
import UserNotifications

/// Friends extras, part B (0.30): free hours together today, the friends leaderboard and the ride history. The rules
/// are in `FriendExtrasB.swift` (tested); this keeps what came and what you shared (Friends/together.json, not backed
/// up; the two switches go in the vault with the extras' others) and runs only inside `FriendStore.sync` (app to the
/// front, Friends or a chat open, the ride's once-a-minute check, the background refresh) and on the ride's own
/// network tick (the ride history). No loop of its own: it only reads the trip, never changes it.
@MainActor
final class FriendTogetherStore: ObservableObject {
    static let shared = FriendTogetherStore()

    /// Rides you shared with friends, newest first (this phone only).
    @Published private(set) var rides: [RideTogether] = []
    /// Friends' scores, by account.
    @Published private(set) var scores: [String: ScoresSeen] = [:]
    /// Today's free time together, as worked out at the last check.
    @Published private(set) var freeToday: [FreeTodaySlot] = []

    private struct Saved: Codable {
        var rides: [RideTogether] = []
        var scores: [String: ScoresSeen] = [:]
        var scoresSent: TimetableShareRules.Sent?
        var freeNoteDay: String?
    }

    private var saved = Saved()
    private var lastWritten: Data?
    private var lastScoresLook = Date.distantPast
    private var lastMineRead = Date.distantPast

    private static var file: URL? { FriendStore.folder?.appendingPathComponent("together.json") }

    private init() {
        if let f = Self.file, let d = try? Data(contentsOf: f), let s = try? FriendJSON.decoder.decode(Saved.self, from: d) { saved = s }
        publish()
    }

    private var store: FriendStore { FriendStore.shared }
    private var me: String { store.myAccount ?? "" }
    private var settings: ExtrasSettings { FriendExtrasStore.shared.settings }

    private func publish() {
        if rides != saved.rides { rides = saved.rides }
        if scores != saved.scores { scores = saved.scores }
    }

    private func save() {
        guard let f = Self.file, let d = try? FriendJSON.encoder.encode(saved), d != lastWritten else { return }
        try? d.write(to: f, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        lastWritten = d
    }

    // MARK: what came in

    func take(_ r: FriendInbox.Result) {
        guard !r.scores.isEmpty else { return }
        for (id, s) in r.scores where (saved.scores[id]?.t ?? Int.min) <= s.t {
            saved.scores[id] = s.share.on ? s : nil
        }
        save()
        publish()
    }

    // MARK: at each check

    func due(now: Date) async {
        guard store.hasAccount, let b = store.book else { return }
        let friends: [String] = b.friends.map(\.id)
        let keep = Set(friends)
        // (only friends stay)
        saved.scores = saved.scores.filter { keep.contains($0.key) }
        saved.rides = RideHistory.keep(saved.rides, friends: keep)
        if now.timeIntervalSince(lastScoresLook) >= 60 || now < lastScoresLook {
            lastScoresLook = now
            scoresDue(friends: friends, now: now)
        }
        await freeDue(friends: friends, now: now)
        save()
        publish()
    }

    // MARK: the friends leaderboard

    /// Your trips on the leaderboard (ScoreBook), as the friends board counts them.
    static func myTrips() -> [ScoreTrip] {
        ScoreBook.shared.trips.map { ScoreTrip(route: $0.route, home: $0.home, mins: $0.mins, at: $0.at) }
    }

    /// Yours as friends see it now.
    func myScores(now: Date = Date()) -> ScoresShare {
        ScoresRules.build(trips: Self.myTrips(), rides: RideHistory.count(saved.rides, now: now), now: now)
    }

    /// "Share my scores" on: to every friend when it changed (at most every 12 hours) and once a week anyway, to a new
    /// friend at once. Off: taken back from those who had it.
    private func scoresDue(friends: [String], now: Date) {
        if settings.scores == true {
            let body: ScoresShare = myScores(now: now)
            let hash: String = ScoresRules.fingerprint(body)
            let to: [String] = ScoresRules.due(last: saved.scoresSent, hash: hash, friends: friends, now: now)
            guard !to.isEmpty else { return }
            store.queueBox(.scores(body), to: to, slot: ScoresRules.slot, ttl: ScoresRules.ttl)
            saved.scoresSent = TimetableShareRules.after(saved.scoresSent, hash: hash, sent: to, everyone: friends, at: now)
        } else if let sent = saved.scoresSent {
            let still: [String] = sent.to.filter { friends.contains($0) }
            if !still.isEmpty {
                store.queueBox(.scores(ScoresShare(on: false)), to: still, slot: ScoresRules.slot, ttl: ScoresRules.offTTL)
            }
            saved.scoresSent = nil
        }
    }

    /// You and the friends who share their scores (the newest of each).
    func boardPeople(now: Date = Date()) -> [ScoresPerson] {
        var out: [ScoresPerson] = [ScoresPerson(id: "me", share: myScores(now: now))]
        for (id, s) in scores where store.book?.isFriend(id) == true && s.share.on {
            out.append(ScoresPerson(id: id, share: s.share))
        }
        return out
    }

    /// Friends who share their scores.
    var sharingCount: Int { scores.filter { store.book?.isFriend($0.key) == true && $0.value.share.on }.count }

    // MARK: free hours together

    private func freeDue(friends: [String], now: Date) async {
        let tt = FriendTimetables.shared
        // (yours as read for sending; read here, without sending, at most every 30 minutes when it isn't)
        if tt.mine == nil, now.timeIntervalSince(lastMineRead) >= TimetableShareRules.lookEvery {
            lastMineRead = now
            _ = await tt.readMine(now: now, sharing: false)
        }
        var theirs: [(id: String, share: TimetableShare)] = []
        for id in friends {
            if let s = tt.timetable(id) { theirs.append((id: id, share: s)) }
        }
        let slots: [FreeTodaySlot] = FreeToday.slots(mine: tt.mine, friends: theirs, now: now)
        if slots != freeToday { freeToday = slots }
        guard FreeToday.noteDue(on: settings.free == true, lastDay: saved.freeNoteDay, slots: slots, now: now) else { return }
        saved.freeNoteDay = TimetableDays.key(now)
        let body: String = FreeToday.note(slots, names: { self.store.name($0) }, now: now)
        tell(title: "Free time together today", body: body, id: "friends-free-\(TimetableDays.key(now))")
    }

    /// Today's free time still to come (for Friends).
    func freeNow(now: Date = Date()) -> [FreeTodaySlot] { freeToday.filter { $0.end > now } }

    private func tell(title: String, body: String, id: String) {
        if UIApplication.shared.applicationState == .active {
            Notices.shared.show(title: title, body: body, kind: "friends")
            return
        }
        let n = UNMutableNotificationContent()
        n.title = title
        n.body = body
        n.sound = .default
        n.userInfo = ["kind": "friends"]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: n, trigger: nil)) { _ in }
    }

    // MARK: ride history (on the ride's network tick)

    /// On board a bus or train with friends on it too (their trip is on that vehicle, or a trip card you're both in
    /// has it): the ride goes in the history (once per vehicle per day; more friends are added to it).
    func rideTick(_ t: TripManager) {
        guard store.hasFriends, !t.demo, let v = t.vehicle, let l = t.leg, !t.waitingToBoard, t.phase != .transfer,
              FriendTravelShare.running(t), let b = store.book else { return }
        let now = Date()
        let travel: [(from: String, state: TravelState)] = store.travelling(now: now).map { (from: $0.from, state: $0.state) }
        let cards: [(card: TripCard, riders: [String])] = FriendExtrasStore.shared.myCards(now)
        let who: [String] = RideHistory.riders(trip: v.tripId, travel: travel, cards: cards, me: me).filter { b.isFriend($0) }
        guard !who.isEmpty else { return }
        let dep: Date = t.legFrom ?? now
        let num: String? = FriendTravelShare.shared.numbers[v.tripId]
        let line: String = v.isTrain ? Transit.trainLabel(v.line) : v.line
        let label: String = v.isTrain ? (num.map { "\(line) \($0)" } ?? line) : "Bus \(line)"
        let r = RideTogether(trip: v.tripId, day: TimetableDays.key(dep), label: label, from: l.from.short, to: l.to.short, dep: dep, with: who)
        let next: [RideTogether] = RideHistory.add(saved.rides, r, now: now)
        guard next != saved.rides else { return }
        saved.rides = next
        save()
        publish()
    }

    /// Times you rode with a friend this month, and the last rides.
    func count(with id: String, now: Date = Date()) -> Int { RideHistory.count(rides, with: id, now: now) }
    func last(with id: String) -> [RideTogether] { RideHistory.last(rides, with: id) }

    // MARK: signing out

    func forgetAll() {
        saved = Saved()
        freeToday = []
        save()
        publish()
    }
}
