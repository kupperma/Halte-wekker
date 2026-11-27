import Combine
import Foundation
import UIKit
import UserNotifications

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
        /// (0.42.5) Messages from the link's viewers (the newest 50), the newest one read, seen up to, your answers.
        var msgs: [Msg]? = nil
        var lastSeq: Int? = nil
        var seen: Int? = nil
        var replies: [LiveReply]? = nil
        /// (0.42.9) The picture the relay has (`LiveFace.stamp`) and its version (the state's `pic`; none: not put).
        var picStamp: String? = nil
        var pic: Int? = nil

        var unread: Int { (msgs ?? []).filter { $0.seq > (seen ?? 0) }.count }
    }

    /// (0.42.5) One message from someone with the link, as read (`LiveMessages.open`).
    struct Msg: Codable, Equatable, Identifiable {
        var seq: Int
        var at: Date
        var from: String
        var fromKind: String
        var friendId: String?
        var text: String
        var id: Int { seq }
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
    private var faceTried: Date?

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

    /// The name the page says ("Sam is on bus 305…"): your friends name, else the one you typed last time (`LiveNames`).
    var defaultName: String {
        LiveNames.sender(friends: FriendStore.shared.book?.myName, typed: UserDefaults.standard.string(forKey: Self.nameKey))
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
            } else {
                enqueue { await self.inbox() }
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
        let face: Bool = faceDue(l)
        guard face || LiveRules.due(lastSent: l.lastSent, lastKey: l.lastKey, key: LiveRules.key(s), now: Date()) else { return }
        putQueued = true
        enqueue {
            self.putQueued = false
            if face { await self.sendFace() }
            // (read again: a moment may have passed)
            guard let t = self.trip, let l = self.link, !l.arrived, let s = self.state(t, l) else { return }
            guard face || LiveRules.due(lastSent: l.lastSent, lastKey: l.lastKey, key: LiveRules.key(s), now: Date()) else { return }
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
        let now = Date()
        let base: LiveState = LiveRules.state(tr, name: l.name, dep: dep, late: late, now: now)
        // (0.42.5, payload v2) the whole trip: its legs, the leg you're on (its stops and road), the vehicle's own GPS
        return LiveTripV2.build(base, v2Trip(t, now: now), now: now)
    }

    /// The trip as `LiveTripV2` takes it: the legs (the planned rides, the one you're on as it goes), the current leg's
    /// stops and road (the saved copy of its ride, else its live stops), the vehicle's own fix, the coach you shared.
    private func v2Trip(_ t: TripManager, now: Date) -> LiveTripV2.Trip {
        let planned: [PlannedRide] = t.route?.planned ?? []
        let share = FriendTravelShare.shared
        var legs: [LiveTripV2.LegIn] = []
        var curTrip: String? = nil
        for (k, l) in t.legs.enumerated() {
            let p: PlannedRide? = planned[safe: k]
            let train: Bool = l.mode == .train
            var x = LiveTripV2.LegIn(mode: train ? "train" : "bus", line: p.map { $0.isTrain ? Transit.trainLabel($0.line) : $0.line },
                                     from: l.from.short, to: l.to.short)
            var tripId: String? = p?.tripId
            if k == t.index {
                if let v = t.vehicle {
                    x.line = v.isTrain ? Transit.trainLabel(v.line) : v.line
                    tripId = v.tripId
                }
                x.dep = (t.legFrom ?? p?.departure)?.timeIntervalSince1970
                x.arr = (t.legArrival ?? t.legTo)?.timeIntervalSince1970
                curTrip = tripId
            } else {
                x.dep = p?.departure.timeIntervalSince1970
            }
            x.depPlatform = p?.platform
            // (0.42.9) where it goes from and to, and the saved road of the rides ahead (the page draws the rest of the trip)
            x.fromPt = GeoPoint(l.from.coordinate)
            x.toPt = GeoPoint(l.to.coordinate)
            if k >= t.index, let id = tripId, let r = RideCacheStore.shared.saved(id) { x.road = r.shape }
            if let id = tripId, let r = RideCacheStore.shared.saved(id) {
                if x.arr == nil, let i = RideCache.stop(near: GeoPoint(l.to.coordinate), in: r) { x.arr = (r.stops[i].arrival ?? r.stops[i].departure)?.timeIntervalSince1970 }
                if let i = RideCache.stop(near: GeoPoint(l.to.coordinate), in: r) { x.arrPlatform = r.stops[i].platform }
            }
            if let id = tripId, id == share.coachTrip, let c = share.coach {
                x.coach = c.n
                x.deck = c.seat?.deck
            }
            if let id = tripId { x.num = share.numbers[id] }
            legs.append(x)
        }
        var trip = LiveTripV2.Trip(legs: legs, leg: t.index)
        if let leg = t.leg, let id = curTrip, let r = RideCacheStore.shared.saved(id), r.stops.count >= 2 {
            let a: Int = RideCache.stop(near: GeoPoint(leg.from.coordinate), in: r) ?? 0
            let b: Int = RideCache.stop(near: GeoPoint(leg.to.coordinate), in: r, after: a) ?? (r.stops.count - 1)
            if b > a {
                trip.stops = r.stops[a...b].map { LiveTripV2.StopIn(name: $0.name, lat: $0.lat, lon: $0.lon, t: ($0.arrival ?? $0.departure)?.timeIntervalSince1970) }
                trip.shape = r.shape
            }
        } else if !t.vehicleStops.isEmpty {
            trip.stops = t.vehicleStops.map { LiveTripV2.StopIn(name: $0.name, lat: $0.coordinate.latitude, lon: $0.coordinate.longitude, t: $0.arrival?.timeIntervalSince1970) }
        }
        if let id = curTrip, t.vehicle != nil, let f = RealPositionsStore.shared.fix(for: id, now: now) {
            trip.vehicle = LiveTripV2.Vehicle(lat: f.lat, lon: f.lon, at: f.at.timeIntervalSince1970)
        }
        trip.face = LiveTripV2.face(FriendStore.shared.account)
        trip.pic = saved.link?.pic
        // (listening now) the song, when you share it with live links
        trip.music = MusicShareStore.shared.forLink(travelling: FriendTravelShare.running(t) && !t.demo)
        return trip
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
        // (0.42.9) your picture, then a state that says so (the relay takes one every 5 s)
        if faceDue(l) {
            enqueue {
                await self.sendFace()
                try? await Task.sleep(nanoseconds: 5_200_000_000)
                guard let t = self.trip, let cur = self.link, cur.keys == l.keys, !cur.arrived, let s = self.state(t, cur) else { return }
                _ = await self.put(s, arrived: false)
            }
        }
        return URL(string: l.keys.link)
    }

    // MARK: your picture (0.42.9): 128 px, ≤ 12 KB, locked with the link's key; put once, again when it changes

    private func faceDue(_ l: Link) -> Bool {
        LiveFace.due(LiveFace.stamp(FriendStore.shared.myPicture), sent: l.picStamp ?? "", lastTry: faceTried, now: Date())
    }

    private func sendFace() async {
        guard let l = saved.link, let src = FriendStore.shared.myPicture else { return }
        let stamp: String = LiveFace.stamp(src)
        guard LiveFace.due(stamp, sent: l.picStamp ?? "", lastTry: faceTried, now: Date()) else { return }
        faceTried = Date()
        guard let jpeg = Self.small(src), let data = try? LiveFace.seal(jpeg, key: l.keys.key, token: l.keys.token) else { return }
        let a: Answer = await call("/live/v1/face", ["secret": B64URL.encode(l.keys.secret), "data": B64URL.encode(data)])
        guard case .ok = a, var cur = saved.link, cur.keys == l.keys else { return }
        cur.picStamp = stamp
        cur.pic = (cur.pic ?? 0) + 1
        saved.link = cur
        save()
        faceTried = nil
    }

    /// The picture at 128 px, a JPEG of at most 12 KB (lower quality until it fits); nil: it can't be read.
    private static func small(_ jpeg: Data) -> Data? {
        guard let img = UIImage(data: jpeg), img.size.width > 0, img.size.height > 0 else { return nil }
        let side: CGFloat = CGFloat(LiveFace.side)
        let scale: CGFloat = side / min(img.size.width, img.size.height)
        let drawn = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        let origin = CGPoint(x: (side - drawn.width) / 2, y: (side - drawn.height) / 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let square: UIImage = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            img.draw(in: CGRect(origin: origin, size: drawn))
        }
        for q in [0.7, 0.6, 0.5, 0.4, 0.3] as [CGFloat] {
            if let j = square.jpegData(compressionQuality: q), j.count <= LiveFace.maxBytes { return j }
        }
        return nil
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

    // MARK: messages (0.42.5): read with the link's secret, opened with its key; never logged, only counted

    private struct Inbox: Decodable {
        struct M: Decodable { let seq: Int; let at: Double?; let data: String }
        let msgs: [M]
    }
    private var asking = false

    /// The new messages: each one a notification ("💬 Kim: On my way"), kept on the link card.
    private func inbox() async {
        guard !asking, let l = saved.link else { return }
        asking = true
        defer { asking = false }
        let a = await raw("/live/v1/inbox", ["secret": B64URL.encode(l.keys.secret), "after": l.lastSeq ?? 0])
        guard a.status == 200, let box = try? JSONDecoder().decode(Inbox.self, from: a.data) else { return }
        var got: [Msg] = []
        for m in box.msgs {
            guard let d = B64URL.decode(m.data), let x = LiveMessages.open(d, key: l.keys.key, token: l.keys.token) else { continue }
            got.append(Msg(seq: m.seq, at: Date(timeIntervalSince1970: m.at ?? x.at), from: x.from, fromKind: x.fromKind, friendId: x.friendId, text: x.text))
        }
        guard var cur = saved.link, cur.keys == l.keys else { return }
        let top: Int = box.msgs.map(\.seq).max() ?? (cur.lastSeq ?? 0)
        var all: [Msg] = cur.msgs ?? []
        for m in got where !all.contains(where: { $0.seq == m.seq }) { all.append(m) }
        cur.msgs = Array(all.suffix(50))
        cur.lastSeq = max(cur.lastSeq ?? 0, top)
        saved.link = cur
        save()
        for m in got { notify(m) }
        if !got.isEmpty { FieldLog.shared.add(.ride, "live link: \(got.count) new message" + (got.count == 1 ? "" : "s")) }
    }

    /// Who it's from, as this app shows it: the friend (an app's message carries their account), the name they gave.
    func sender(_ m: Msg) -> String {
        LiveMessages.sender(LiveMessage(from: m.from, fromKind: m.fromKind, friendId: m.friendId, text: m.text, at: 0)) { id in
            FriendStore.shared.book?.friends.first { $0.id == id }?.name
        }
    }

    private func notify(_ m: Msg) {
        let c = UNMutableNotificationContent()
        c.title = "💬 " + sender(m)
        c.body = m.text
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "livemsg-\(m.seq)", content: c, trigger: nil)) { _ in }
    }

    /// You looked at them (the card): the pages say "Seen".
    func markSeen() {
        guard var l = saved.link, l.unread > 0, let top = l.msgs?.map(\.seq).max() else { return }
        let ids: [String] = (l.msgs ?? []).filter { $0.seq > (l.seen ?? 0) }.map { "livemsg-\($0.seq)" }
        l.seen = top
        saved.link = l
        save()
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        let keys = l.keys
        enqueue { _ = await self.call("/live/v1/ack", ["secret": B64URL.encode(keys.secret), "seq": top]) }
    }

    /// "Reply": every page of the link shows it under the messages.
    func reply(_ text: String) async -> Bool {
        guard let l = saved.link else { return false }
        let t: String = LiveTripV2.clean(text, LiveMessages.maxText)
        guard !t.isEmpty else { return false }
        let r = LiveReply(text: t, at: Date().timeIntervalSince1970.rounded(.down), re: l.msgs?.last?.seq)
        guard let data = try? LiveMessages.sealReply(r, key: l.keys.key, token: l.keys.token) else { return false }
        let a: Answer = await call("/live/v1/reply", ["secret": B64URL.encode(l.keys.secret), "data": B64URL.encode(data)])
        guard case .ok = a, var cur = saved.link, cur.keys == l.keys else { return false }
        cur.replies = Array(((cur.replies ?? []) + [r]).suffix(10))
        saved.link = cur
        save()
        return true
    }

    // MARK: the relay

    private enum Answer { case ok(exp: Int?, mseq: Int, seq: Int), ended, slow, failed }
    private struct Reply: Decodable { let exp: Int?; let mseq: Int?; let seq: Int? }

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
        case .ok(let exp, let mseq, _):
            cur.lastSent = now
            cur.lastKey = LiveRules.key(s)
            cur.last = s
            cur.exp = exp.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            saved.link = cur
            problem = nil
            save()
            // (0.42.5) a message came: read it now (the put said there's one)
            if mseq > (cur.lastSeq ?? 0) { await inbox() }
            return true
        case .ended:
            saved.link = nil
            save()
            return false
        case .slow, .failed:
            return false
        }
    }

    /// The relay's raw answer (status, body); -1 when it couldn't be reached.
    private func raw(_ path: String, _ body: [String: Any]) async -> (status: Int, data: Data) {
        guard let url = URL(string: LiveCrypto.relay + path),
              let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return (-1, Data()) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = data
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let label: String = "live" + String(path.split(separator: "?").first?.dropFirst(8) ?? "")
        guard let a = try? await Net.response(req, lane: .background, budget: Self.budget, label: label) else { return (-1, Data()) }
        return (a.status, a.data)
    }

    private func call(_ path: String, _ body: [String: Any]) async -> Answer {
        let a = await raw(path, body)
        if a.status < 0 { return .failed }
        switch a.status {
        case 200:
            let r: Reply? = try? JSONDecoder().decode(Reply.self, from: a.data)
            return .ok(exp: r?.exp, mseq: r?.mseq ?? 0, seq: r?.seq ?? 0)
        case 410: return .ended
        case 429: return .slow
        default: return .failed
        }
    }
}
