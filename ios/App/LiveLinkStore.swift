import Combine
import Foundation

/// Live link (0.30): a web page with your trip's live times for someone without the app (a parent), made from the ride
/// screen or Friends while a trip runs. The lock and the rules are in `LiveLink.swift` (tested); the relay's side is
/// relay/live.js. Posted only on the ride's existing network tick (every 30 s on a trip: a put when 55 s went by, or at
/// once when the leg, the stage or the vehicle changed), "Arrived" at the last stop (kept 15 minutes), ended when the
/// trip ends otherwise, when you stop it, or after 4 hours. No loop of its own; it never changes the trip. Works without
/// a friends account. The link (with its secret and key) is kept in Friends/live.json, not backed up.
@MainActor
final class LiveLinkStore: ObservableObject {
    static let shared = LiveLinkStore()

    struct Link: Codable, Equatable {
        var keys: LiveKeys
        var created: Date
        var name: String
        var lastSent: Date?
        var lastKey: String = ""
        var last: LiveState?
        /// The last stop was reached: "Arrived" went out, nothing more goes.
        var arrived: Bool = false
        /// When the relay drops it (as it last said).
        var exp: Date?
    }

    private struct Saved: Codable {
        var link: Link?
        /// A link to end on the relay still (the network was away when it ended).
        var endPending: LiveKeys?
    }

    /// The link while it's shared (and for 15 minutes after the last stop, "Arrived").
    @Published private(set) var link: Link?
    @Published private(set) var making = false
    @Published private(set) var problem: String?

    private var saved = Saved()
    private weak var trip: TripManager?
    private var subs: Set<AnyCancellable> = []
    private var chain: Task<Void, Never>?
    private var putQueued = false

    private static var file: URL? { FriendStore.folder?.appendingPathComponent("live.json") }
    private static let nameKey = "live.name"
    private static let budget = Budget(idle: 8, total: 15, retries: 0, backoff: 1, fastFailure: 2, minLeft: 3)

    private init() {
        if let f = Self.file, let d = try? Data(contentsOf: f), let s = try? FriendJSON.decoder.decode(Saved.self, from: d) { saved = s }
        link = saved.link
    }

    private func save() {
        guard let f = Self.file, let d = try? FriendJSON.encoder.encode(saved) else { return }
        try? d.write(to: f, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        if link != saved.link { link = saved.link }
    }

    /// The name the page says ("Sam is on bus 305…"): your friends name, else the one you typed last time.
    var defaultName: String {
        let friends: String = FriendStore.shared.book?.myName ?? ""
        if !friends.isEmpty { return friends }
        return UserDefaults.standard.string(forKey: Self.nameKey) ?? ""
    }

    var url: URL? { link.flatMap { URL(string: $0.keys.link) } }

    // MARK: the trip (read only)

    func attach(_ t: TripManager) {
        guard trip == nil else { return }
        trip = t
        t.$phase.removeDuplicates().sink { [weak self] _ in
            // (published before the change lands: a moment later it reads the trip as it is)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.phaseChanged()
            }
        }.store(in: &subs)
        settle()
    }

    /// Can a link be made now: a trip runs (not the demo).
    var canMake: Bool {
        guard let t = trip else { return false }
        return FriendTravelShare.running(t) && !t.demo
    }

    private func phaseChanged() {
        guard let t = trip, let l = link, !l.arrived else { settle(); return }
        if t.phase == .finished {
            enqueue { await self.arrive() }
        } else if !FriendTravelShare.running(t) {
            enqueue { await self.endNow() }
        } else {
            tick()
        }
    }

    /// No trip runs (the app came back, or started): a link left over ends; "Arrived" goes once its 15 minutes are up.
    private func settle() {
        if let k = saved.endPending { enqueue { await self.endOnRelay(k) } }
        guard let t = trip, let l = link else { return }
        if l.arrived {
            if Date() >= (l.exp ?? l.created.addingTimeInterval(LiveRules.maxAge)) {
                saved.link = nil
                save()
            }
            return
        }
        if !FriendTravelShare.running(t) { enqueue { await self.endNow() } }
    }

    /// The ride's network tick, or the leg changed: the next state when it's due.
    func tick() {
        if saved.endPending != nil { settle() }
        guard let t = trip, let l = link, !l.arrived, !putQueued else {
            if link?.arrived == true { settle() }
            return
        }
        guard FriendTravelShare.running(t), !t.demo else { return }
        if LiveRules.expired(created: l.created, now: Date()) {
            enqueue { await self.endNow() }
            return
        }
        guard let s = state(t, l) else { return }
        guard LiveRules.due(lastSent: l.lastSent, lastKey: l.lastKey, key: LiveRules.key(s), now: Date()) else { return }
        putQueued = true
        enqueue {
            self.putQueued = false
            // (read again: a moment may have passed)
            guard let t = self.trip, let l = self.link, !l.arrived, let s = self.state(t, l) else { return }
            _ = await self.put(s, arrived: false)
        }
    }

    /// The trip as the page shows it: the state friends get (0.26), with how late and when the next ride leaves.
    private func state(_ t: TripManager, _ l: Link) -> LiveState? {
        guard let tr = FriendTravelShare.shared.currentState() else { return nil }
        var dep: Date? = nil
        var late: Int? = nil
        let rides: [Ride] = t.upcoming.map(\.trip.first)
        if t.phase == .transfer {
            dep = t.next?.departure
            if let n = t.next, n.live { late = max(0, n.delay) }
        } else if t.waitingToBoard {
            let planned: PlannedRide? = t.route?.planned?[safe: t.index]
            let first: Ride? = planned.flatMap { p in rides.first { $0.tripId == p.tripId } } ?? rides.first
            dep = first?.departure ?? planned?.departure
            if let f = first, f.live { late = max(0, f.delay) }
        } else if let v = t.vehicle, let r = rides.first(where: { $0.tripId == v.tripId }) {
            late = LiveRules.late(live: t.legTo ?? t.legArrival, scheduled: r.scheduledArrival)
        }
        return LiveRules.state(tr, name: l.name, dep: dep, late: late, now: Date())
    }

    // MARK: making, stopping

    /// Makes a link for this trip and posts its first state; nil: no trip runs, or the relay couldn't be reached.
    func make(name: String) async -> URL? {
        let n: String = FriendNames.clean(name)
        guard let t = trip, canMake, !n.isEmpty, !making else { return nil }
        if FriendStore.shared.book?.myName.isEmpty ?? true { UserDefaults.standard.set(n, forKey: Self.nameKey) }
        if let old = link, !old.arrived { await endOnRelay(old.keys) }
        making = true
        defer { making = false }
        problem = nil
        let l = Link(keys: LiveKeys.make(), created: Date(), name: n)
        saved.link = l
        save()
        guard let s = state(t, l), await put(s, arrived: false) else {
            saved.link = nil
            save()
            problem = "Couldn’t make the link. Check your connection and try again."
            return nil
        }
        return URL(string: l.keys.link)
    }

    /// "Stop sharing": the page says the link has ended, at once.
    func stop() {
        guard let l = link else { return }
        saved.link = nil
        save()
        enqueue { await self.endOnRelay(l.keys) }
    }

    private func arrive() async {
        guard let l = link, !l.arrived else { return }
        let s: LiveState = LiveRules.arrived(l.last, name: l.name, stop: trip?.arrivedAt, at: Date())
        var ok: Bool = await put(s, arrived: true)
        if !ok {
            // (the relay takes one every 5 s: a tick's put may just have gone)
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            ok = await put(s, arrived: true)
        }
        guard var cur = saved.link, cur.keys == l.keys else { return }
        if ok {
            cur.arrived = true
            saved.link = cur
            save()
        } else {
            await endNow()
        }
    }

    private func endNow() async {
        guard let l = saved.link else { return }
        saved.link = nil
        save()
        await endOnRelay(l.keys)
    }

    private func endOnRelay(_ k: LiveKeys) async {
        let a: Answer = await call("/live/v1/end", ["secret": B64URL.encode(k.secret)])
        if case .failed = a {
            saved.endPending = k
        } else if saved.endPending == k {
            saved.endPending = nil
        }
        save()
    }

    /// One at a time (a put, the arrival, the end), in order.
    private func enqueue(_ op: @escaping @MainActor () async -> Void) {
        let prev = chain
        chain = Task { @MainActor in
            await prev?.value
            await op()
        }
    }

    // MARK: the relay

    private enum Answer { case ok(exp: Int?), ended, slow, failed }
    private struct Reply: Decodable { let exp: Int? }

    @discardableResult
    private func put(_ s: LiveState, arrived: Bool) async -> Bool {
        guard let l = saved.link, let data = try? LiveCrypto.lock(s, keys: l.keys) else { return false }
        let now = Date()
        let until: Date = LiveRules.until(created: l.created, now: now, arrived: arrived)
        let body: [String: Any] = ["secret": B64URL.encode(l.keys.secret), "data": B64URL.encode(data),
                                   "until": Int(until.timeIntervalSince1970)]
        let a: Answer = await call("/live/v1/put", body)
        guard var cur = saved.link, cur.keys == l.keys else { return false }       // stopped meanwhile
        switch a {
        case .ok(let exp):
            cur.lastSent = now
            cur.lastKey = LiveRules.key(s)
            cur.last = s
            cur.exp = exp.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            saved.link = cur
            problem = nil
            save()
            return true
        case .ended:
            saved.link = nil
            save()
            return false
        case .slow, .failed:
            return false
        }
    }

    private func call(_ path: String, _ body: [String: Any]) async -> Answer {
        guard let url = URL(string: LiveCrypto.relay + path),
              let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return .failed }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = data
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let a = try? await Net.response(req, lane: .background, budget: Self.budget, label: "live" + String(path.dropFirst(8))) else {
            return .failed
        }
        switch a.status {
        case 200: return .ok(exp: (try? JSONDecoder().decode(Reply.self, from: a.data))?.exp)
        case 410: return .ended
        case 429: return .slow
        default: return .failed
        }
    }
}
