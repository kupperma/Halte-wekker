import Combine
import CoreLocation
import Foundation
import UIKit
import UserNotifications

/// Friends extras (0.29): "Wait for me", the delay alarm for shared rides, the wake-up buddy and who's on campus. The
/// rules are in `FriendExtras.swift` (tested); this keeps what came and what you shared (Friends/extras.json, not
/// backed up; the switches also go in the vault) and runs only inside `FriendStore.sync` (app to the front, Friends
/// or a chat open, the ride's once-a-minute check, the background refresh) and at region events. No loop of its own:
/// it only reads the trip, never changes it.
@MainActor
final class FriendExtrasStore: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = FriendExtrasStore()

    /// Friends' waits for you (the newest per sender), friends on campus, friends' wake-up buddy plans, by account.
    @Published private(set) var waits: [String: WaitSeen] = [:]
    @Published private(set) var campus: [String: CampusSeen] = [:]
    @Published private(set) var buddies: [String: BuddySeen] = [:]
    /// Delays on rides you share (your own phone's and friends'), the newest first, for three hours.
    @Published private(set) var delays: [DelaySeen] = []
    /// Your own wait, while you ask someone to wait for you.
    @Published private(set) var myWait: MyWait?
    @Published private(set) var settings = ExtrasSettings()
    /// You're shown as on campus now (to how many).
    @Published private(set) var campusShownTo = 0
    /// Working out the next ride for "Take the next one with you".
    @Published private(set) var findingNext: String?

    /// Your wait: where, for which ride, to whom, and what went out last.
    struct MyWait: Codable, Equatable {
        var id: String
        var chat: String
        var stop: TripCard.Spot
        var ride: TripCard.Ride?
        var started: Date
        var to: [String]
        var last: WaitFor?
        var lastSent: Date?
    }

    private struct Saved: Codable {
        var settings = ExtrasSettings()
        var waits: [String: WaitSeen] = [:]
        var campus: [String: CampusSeen] = [:]
        var buddies: [String: BuddySeen] = [:]
        var delays: [DelaySeen] = []
        var delayTold: [String: DelayTold] = [:]
        var buddyTold: [String: String] = [:]
        var waitsTold: [String] = []
        var myWait: MyWait?
        var campusPosted: CampusPosted?
        var campusInside: Bool?
        var campusSince: Date?
        var buddySent: BuddyPlan?
        var buddySentAt: Date?
        var buddySentTo: [String]?
        var leftDay: String?
        var leftAt: Date?
    }

    private var saved = Saved()
    private weak var trip: TripManager?
    private var subs: Set<AnyCancellable> = []
    private lazy var locator: CLLocationManager = {
        let m = CLLocationManager()
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        return m
    }()
    private var oneShot: CLLocation?
    private var lastAsk = Date.distantPast
    private var lastDelayLook: Date?
    private var checkingDelays = false
    private var askedPlan: String?

    private static var file: URL? { FriendStore.folder?.appendingPathComponent("extras.json") }

    private override init() {
        super.init()
        if let f = Self.file, let d = try? Data(contentsOf: f), let s = try? FriendJSON.decoder.decode(Saved.self, from: d) { saved = s }
        publish()
    }

    private func publish() {
        settings = saved.settings
        waits = saved.waits
        campus = saved.campus
        buddies = saved.buddies
        delays = saved.delays
        myWait = saved.myWait
        campusShownTo = saved.campusPosted?.to.count ?? 0
    }

    private func save() {
        guard let f = Self.file, let d = try? FriendJSON.encoder.encode(saved) else { return }
        try? d.write(to: f, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private var store: FriendStore { FriendStore.shared }
    private var me: String { store.myAccount ?? "" }

    // MARK: the trip (read only)

    /// Watches the trip's start (for "left" of the wake-up buddy) and its region events (at school, leaving home).
    func attach(_ t: TripManager) {
        guard trip == nil else { return }
        trip = t
        t.onRegion = { [weak self] id, entered in self?.region(id, entered: entered) }
        t.$phase.removeDuplicates().sink { [weak self] p in
            if p != .idle && p != .finished { self?.markLeft() }
        }.store(in: &subs)
        mirrorCampus()
    }

    private func mirrorCampus() {
        let on: Bool = store.hasAccount && saved.settings.campus == true
        if UserDefaults.standard.bool(forKey: TripManager.campusRegionKey) != on {
            UserDefaults.standard.set(on, forKey: TripManager.campusRegionKey)
            trip?.regionsChanged()
        }
    }

    private func region(_ id: String, entered: Bool) {
        guard store.hasAccount else { return }
        var worth = false
        if id == RoleRegions.schoolId, saved.settings.campus == true {
            if entered != saved.campusInside {
                saved.campusInside = entered
                saved.campusSince = entered ? Date() : nil
                save()
            }
            worth = true
        }
        if !entered, RoleRegions.role(ofRegion: id) == .home, !(saved.settings.buddy ?? []).isEmpty {
            markLeft()
            worth = true
        }
        // (a region wakes the app for a few seconds: what's due goes now)
        if worth { Task { await self.store.sync(.now) } }
    }

    /// You set off today (a trip started, or you left home): the friends watching you know at the next check.
    private func markLeft() {
        guard !(saved.settings.buddy ?? []).isEmpty else { return }
        let today = TimetableDays.key(Date())
        guard saved.leftDay != today else { return }
        saved.leftDay = today
        saved.leftAt = Date()
        save()
    }

    /// Your position now: the trip's last fix when fresh, else one asked for now (while the app is in front).
    private func position(maxAge: TimeInterval) -> CLLocation? {
        let fresh: (CLLocation?) -> CLLocation? = { l in
            guard let l, -l.timestamp.timeIntervalSinceNow <= maxAge, l.horizontalAccuracy >= 0, l.horizontalAccuracy < 300 else { return nil }
            return l
        }
        let a: CLLocation? = fresh(trip?.lastFix)
        let b: CLLocation? = fresh(oneShot)
        if let a, let b { return a.timestamp > b.timestamp ? a : b }
        if let p = a ?? b { return p }
        askPosition()
        return nil
    }

    private func askPosition() {
        guard UIApplication.shared.applicationState == .active, Date().timeIntervalSince(lastAsk) > 15 else { return }
        let st = locator.authorizationStatus
        guard st == .authorizedAlways || st == .authorizedWhenInUse else { return }
        lastAsk = Date()
        locator.requestLocation()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        Task { @MainActor in self.oneShot = l }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    // MARK: what came in

    func take(_ r: FriendInbox.Result) {
        var changed = false
        for (id, w) in r.waits where (saved.waits[id]?.t ?? Int.min) <= w.t {
            saved.waits[id] = w
            changed = true
            if !saved.waitsTold.contains(w.wait.id), w.wait.phase != .off, WaitAge.freshness(w, now: Date()) != .gone {
                saved.waitsTold = Array((saved.waitsTold + [w.wait.id]).suffix(50))
                let name: String = store.name(id)
                tell(title: "\(name) asks you to wait", body: WaitWords.line(name, w.wait, now: Date()) + ". " + WaitWords.detail(name, w.wait),
                     id: "friends-wait-\(id)", chat: w.chat)
            }
        }
        for (id, c) in r.campus where (saved.campus[id]?.t ?? Int.min) <= c.t {
            saved.campus[id] = c.state.on ? c : nil
            changed = true
        }
        for (id, b) in r.buddies where (saved.buddies[id]?.t ?? Int.min) <= b.t {
            saved.buddies[id] = b.plan.on ? b : nil
            changed = true
        }
        for d in r.delays {
            changed = true
            heard(d)
        }
        if changed {
            save()
            publish()
        }
    }

    /// A delay on a ride you share: told once (and again when it changes by 2 minutes or more), whoever found it.
    private func heard(_ d: DelaySeen) {
        let trip: String = d.delay.ride.trip
        saved.delays.removeAll { $0.delay.ride.trip == trip }
        saved.delays.insert(d, at: 0)
        let told: DelayTold? = saved.delayTold[trip]
        guard DelayAlarm.shouldTell(late: d.delay.late, cancelled: d.delay.isCancelled, told: told) else { return }
        saved.delayTold[trip] = DelayTold(late: d.delay.late, cancelled: d.delay.isCancelled, at: Date())
        let names: [String] = (d.delay.who ?? [d.from]).map { $0 == me ? "you" : store.name($0) }
        let by: String = d.from == me ? "" : " (from \(store.name(d.from)))"
        tell(title: DelayWords.title(d.delay) + by, body: DelayWords.body(d.delay, names: names), id: "friends-delay-\(trip)", chat: nil)
    }

    /// In the app: a banner. In the background (a trip's tick, the background refresh): a notification.
    private func tell(title: String, body: String, id: String, chat: String?) {
        if UIApplication.shared.applicationState == .active {
            Notices.shared.show(title: title, body: body, kind: "friends")
            return
        }
        let n = UNMutableNotificationContent()
        n.title = title
        n.body = body
        n.sound = .default
        if let chat { n.userInfo = ["kind": "friends", "chat": chat]; n.threadIdentifier = "friends-\(chat)" }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: n, trigger: nil)) { _ in }
    }

    // MARK: at each check

    func due(now: Date) async {
        guard store.hasAccount else { return }
        prune(now)
        waitDue(now)
        campusDue(now)
        buddyDue(now)
        buddyWatch(now)
        if DelayAlarm.lookDue(last: lastDelayLook, now: now), !checkingDelays {
            lastDelayLook = now
            Task { await self.checkDelays() }
        }
        save()
        publish()
    }

    private func prune(_ now: Date) {
        let b = store.book
        let friend: (String) -> Bool = { b?.isFriend($0) == true }
        saved.waits = saved.waits.filter { WaitAge.freshness($0.value, now: now) != .gone && (friend($0.key) || store.groups.shares($0.key)) }
        saved.campus = saved.campus.filter { CampusRules.here($0.value, now: now) && friend($0.key) }
        saved.buddies = saved.buddies.filter { friend($0.key) }
        saved.delays = saved.delays.filter { now.timeIntervalSince($0.got) < 3 * 3600 && $0.delay.ride.arr > now.addingTimeInterval(-15 * 60) }
        saved.delayTold = saved.delayTold.filter { now.timeIntervalSince($0.value.at) < 6 * 3600 }
        if let allowed = saved.settings.buddy, allowed.contains(where: { !friend($0) }) {
            let kept: [String] = allowed.filter(friend)
            saved.settings.buddy = kept.isEmpty ? nil : kept
        }
    }

    // MARK: wait for me (yours)

    /// "Wait for me" in a chat (a friend's, or a group's): at `stop`, for `ride` when known. Goes now, and again while
    /// you come closer (at each check).
    func startWait(chat: String, stop: TripCard.Spot, ride: TripCard.Ride?) {
        let to: [String] = store.recipients(chat).map(\.account)
        guard !to.isEmpty, stop.point != nil else { return }
        if let old = saved.myWait { sendWaitOff(old) }
        saved.myWait = MyWait(id: String(RelaySign.nonce().prefix(22)), chat: chat, stop: stop, ride: ride, started: Date(), to: to)
        waitDue(Date())
        save()
        publish()
        FriendChats.shared.note("You asked \(ChatKey.isGroup(chat) ? "the group" : store.name(chat)) to wait for you at \(stop.name)", in: chat)
        Task { await store.sync(.now) }
    }

    /// You made it, or gave up: the friends see it's over.
    func stopWait() {
        guard let w = saved.myWait else { return }
        sendWaitOff(w)
        saved.myWait = nil
        save()
        publish()
        Task { await store.sync(.now) }
    }

    private func sendWaitOff(_ w: MyWait) {
        let off = WaitFor(id: w.id, state: WaitFor.Phase.off.rawValue, stop: w.stop, ride: w.ride, at: Date())
        store.queueBox(.wait(off), to: w.to, slot: WaitRules.slot, ttl: WaitRules.ttl, group: ChatKey.groupId(w.chat))
    }

    private func waitDue(_ now: Date) {
        guard var w = saved.myWait, let stopPoint = w.stop.point else { return }
        let fix: CLLocation? = position(maxAge: 90)
        let dist: Double? = fix.map { Geo.metres(GeoPoint(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude), stopPoint) }
        guard let phase = WaitRules.phase(dist: dist, started: w.started, rideDep: w.ride?.dep, now: now) else {
            sendWaitOff(w)
            saved.myWait = nil
            return
        }
        var body = WaitFor(id: w.id, state: phase.rawValue, stop: w.stop, ride: w.ride, at: fix?.timestamp ?? now)
        if let dist {
            body.dist = Int(dist.rounded())
            body.eta = rideEta(to: stopPoint) ?? WaitRules.eta(dist: dist, now: now)
        } else if let last = w.last {
            // (no new position: what you said last, a little later)
            body.dist = last.dist
            body.eta = last.eta
            body.at = last.at
        }
        guard WaitRules.due(last: w.last, lastSent: w.lastSent, next: body, now: now) else { return }
        store.queueBox(.wait(body), to: w.to, slot: WaitRules.slot, ttl: WaitRules.ttl, group: ChatKey.groupId(w.chat))
        w.last = body
        w.lastSent = now
        saved.myWait = w
    }

    /// On a bus or train to that stop (you change there): when it gets there.
    private func rideEta(to stop: GeoPoint) -> Date? {
        guard let t = trip, t.phase == .sleeping || t.phase == .awake, !t.waitingToBoard, let l = t.leg else { return nil }
        let c = l.to.coordinate
        guard Geo.metres(GeoPoint(lat: c.latitude, lon: c.longitude), stop) <= WaitNext.sameStop else { return nil }
        return t.legArrival ?? t.legTo
    }

    struct WaitTarget: Equatable {
        var stop: TripCard.Spot
        var ride: TripCard.Ride?
    }

    /// On the ride screen: the stop you're on your way to (the trip's first stop, or where you change next) and the
    /// ride from there, while you're not on board yet. Nil: on board, or no stop with a place.
    func rideWaitTarget() -> WaitTarget? {
        guard let t = trip, !t.demo else { return nil }
        if t.phase == .transfer, let l = t.legs[safe: t.index + 1] {
            let stop: TripCard.Spot = Self.spot(l.from)
            guard stop.point != nil else { return nil }
            let next: TripCard.Ride? = t.next.map { (r: Ride) -> TripCard.Ride in TripCards.ride(r) }
            return WaitTarget(stop: stop, ride: next)
        }
        guard t.waitingToBoard, let l = t.leg else { return nil }
        let stop: TripCard.Spot = Self.spot(l.from)
        guard stop.point != nil else { return nil }
        var ride: TripCard.Ride? = nil
        if let p = t.route?.planned?[safe: t.index], !p.tripId.isEmpty {
            let arr: Date = max(p.departure, t.legTo ?? t.arrival ?? p.departure)
            ride = TripCard.Ride(mode: p.isTrain ? "train" : "bus", line: p.isTrain ? Transit.trainLabel(p.line) : p.line, trip: p.tripId,
                                 from: stop, to: Self.spot(l.to), dep: p.departure, arr: arr)
        }
        return WaitTarget(stop: stop, ride: ride)
    }

    /// The vehicles of your trip now (for its delays on the ride screen).
    func myTrips() -> Set<String> { Set(myRides(Date()).map(\.trip)) }

    /// The answers to your wait so far, by account.
    func answersToMine() -> [String: WaitAnswer] {
        guard let w = myWait else { return [:] }
        return FriendChats.shared.book.waitAnswers(to: w.id, in: w.chat)
    }

    // MARK: wait for me (theirs)

    /// Waits for you now, the newest first (only in chats you can still write in).
    func waitsForMe(now: Date = Date()) -> [WaitSeen] {
        waits.values.filter { WaitAge.freshness($0, now: now) != .gone && !store.recipients($0.chat).isEmpty }
            .sorted { $0.got > $1.got }
    }

    func myAnswer(to w: WaitSeen) -> WaitAnswer? {
        FriendChats.shared.book.waitAnswers(to: w.wait.id, in: w.chat)[me]
    }

    /// "I'll wait".
    func willWait(_ w: WaitSeen) {
        FriendChats.shared.answerWait(.wait, wait: w.wait.id, in: w.chat)
    }

    /// "Take the next one with you": the next ride from that stop after they get there, as a trip card in the chat
    /// (with the answer). One planner question.
    func takeNext(_ w: WaitSeen) async {
        guard findingNext == nil, let stop = w.wait.stop.point, let from = WayMaking.place(w.wait.stop) else { return }
        findingNext = w.wait.id
        defer { findingNext = nil }
        let dest: TripCard.Spot? = myDestination(from: stop) ?? w.wait.ride?.to
        let after: Date = max(Date(), w.wait.eta ?? Date()).addingTimeInterval(60)
        var card: TripCard?
        if let dest, let to = WayMaking.place(dest) {
            let trips: [DoorTrip] = await Transit.plan(from: from, to: to, modes: nil, at: after, count: 5, maxTransfers: 2)
            let ways: [Way] = trips.map(WayMaking.way)
            if let way = WaitNext.pick(ways, stop: stop, after: after, exclude: w.wait.ride?.trip, line: w.wait.ride?.line),
               let first = way.legs.first {
                let note = "Take the next one with me? \(first.label) at \(TimetableDays.hhmm(first.dep))"
                card = TripCard(rides: Array(way.legs.prefix(TripCard.maxRides)).map(\.card), to: dest, from: w.wait.stop,
                                start: way.start, end: way.end, note: note)
            }
        }
        FriendChats.shared.answerWait(.next, wait: w.wait.id, in: w.chat)
        if let card { FriendChats.shared.sendTrip(card, to: [w.chat]) }
    }

    /// Where you're going from that stop: your trip's leg from there, when it has one.
    private func myDestination(from stop: GeoPoint) -> TripCard.Spot? {
        guard let t = trip, t.phase != .idle, t.phase != .finished else { return nil }
        for l in t.legs.dropFirst(t.index) {
            let c = l.from.coordinate
            if Geo.metres(GeoPoint(lat: c.latitude, lon: c.longitude), stop) <= WaitNext.sameStop { return Self.spot(l.to) }
        }
        return nil
    }

    static func spot(_ p: Place) -> TripCard.Spot {
        if p.key == RoleLogic.homeKey || p.key == Place.home.key { return TripCard.Spot(name: "Home") }
        if p.key == "here" { return TripCard.Spot(name: "Where I am") }
        return TripCard.Spot(name: p.short, id: p.ids.first.flatMap { $0.contains(",") ? nil : $0 },
                             lat: p.coordinate.latitude, lon: p.coordinate.longitude)
    }

    // MARK: who's on campus

    func setCampus(_ on: Bool) {
        saved.settings.campus = on ? true : nil
        if !on { saved.campusInside = nil; saved.campusSince = nil }
        save()
        publish()
        mirrorCampus()
        store.extrasSettingsChanged()
    }

    struct OnCampus: Identifiable, Equatable {
        var id: String
        var state: CampusState
    }

    /// Friends on campus now, by name.
    func onCampus(now: Date = Date()) -> [OnCampus] {
        campus.filter { CampusRules.here($0.value, now: now) && store.book?.isFriend($0.key) == true }
            .sorted { store.name($0.key) < store.name($1.key) }
            .map { OnCampus(id: $0.key, state: $0.value.state) }
    }

    private func campusDue(_ now: Date) {
        let on: Bool = saved.settings.campus == true
        var inside: Bool? = nil
        if on {
            // (a region event said so; else your last position, when fresh)
            let school = Place.school.coordinate
            if let fix = position(maxAge: CampusRules.fixAge) {
                let d = fix.distance(from: CLLocation(latitude: school.latitude, longitude: school.longitude))
                inside = CampusRules.inside(distance: d, radius: NearMe.schoolRadius, was: saved.campusInside ?? false)
            } else {
                inside = saved.campusInside
            }
            if let inside, inside != saved.campusInside {
                saved.campusInside = inside
                saved.campusSince = inside ? (fixTime() ?? now) : nil
            }
        }
        let friends: [String] = store.book?.friends.map(\.id) ?? []
        switch CampusRules.decide(on: on, inside: inside, since: saved.campusSince, posted: saved.campusPosted, friends: friends, now: now) {
        case .post(let since, let to):
            let until: Date = saved.campusPosted?.until ?? CampusRules.until(since: since)
            let body = CampusState(on: true, school: RoleWords.current.school, since: since, until: until)
            store.queueBox(.campus(body), to: to, slot: CampusRules.slot, ttl: CampusRules.ttl(until: until, now: now))
            let had: [String] = saved.campusPosted?.to ?? []
            saved.campusPosted = CampusPosted(since: since, until: until, to: had + to)
        case .clear(let to):
            store.queueBox(.campus(CampusState(on: false)), to: to, slot: CampusRules.slot, ttl: CampusRules.offTTL)
            saved.campusPosted = nil
        case .none:
            break
        }
    }

    private func fixTime() -> Date? { position(maxAge: CampusRules.fixAge)?.timestamp }

    // MARK: the wake-up buddy (yours)

    func allowsBuddy(_ id: String) -> Bool { (settings.buddy ?? []).contains(id) }

    /// "Tell Sam if I haven't left yet" (off by default).
    func setBuddy(_ id: String, _ on: Bool) {
        var list: [String] = (saved.settings.buddy ?? []).filter { $0 != id }
        if on { list.append(id) }
        saved.settings.buddy = list.isEmpty ? nil : list.sorted()
        save()
        publish()
        store.extrasSettingsChanged()
    }

    /// Your plan for the day as friends who watch it see it: the school alarm's next trip (leave, first ride), else
    /// your timetable and start area's way to your first class (one planner question a day, kept), and when you left.
    private func myPlan(_ now: Date) -> BuddyPlan {
        var p = BuddyPlan(on: true)
        let school = SchoolAlarm.shared
        if let n = school.week.filter({ ($0.leave ?? .distantPast) > now.addingTimeInterval(-2 * 3600) })
            .min(by: { $0.classStart < $1.classStart }), let leave = n.leave, leave.timeIntervalSince(now) < 24 * 3600 {
            p.day = TimetableDays.key(leave)
            p.leave = leave
            if let r = school.next?.trip?.first, school.next?.classStart == n.classStart { p.ride = TripCards.ride(r) }
        } else if let w = timetableWay(now) {
            p.day = TimetableDays.key(w.start)
            p.leave = w.start
            p.ride = w.legs.first?.card
        }
        if let d = saved.leftDay, d == p.day ?? TimetableDays.key(now) { p.left = saved.leftAt }
        return p
    }

    /// Your way to today's (or tomorrow's) first class from your shared timetable and area, as kept by the planner's
    /// cache; asked once a day when it isn't.
    private func timetableWay(_ now: Date) -> Way? {
        let tt = FriendTimetables.shared
        guard let share = tt.mine, let area = tt.myArea else { return nil }
        let me = ComparePerson(id: "me", name: "You", isMe: true, timetable: share, area: area)
        for d in Compare.days([me], now: now).prefix(2) {
            guard let pd = d.person("me"), let first = pd.first, first > now else { continue }
            guard let q = CompareModel.question(pd, area: area, .toSchool) else { continue }
            if let ways = CompareModel.cached(q) {
                let ok: [Int] = SharedRides.usable(PersonWays(id: "me", ways: ways, bound: q.bound), .toSchool)
                return ok.map { ways[$0] }.max { $0.start < $1.start }
            }
            if askedPlan != d.key {
                askedPlan = d.key
                Task { _ = await CompareModel.fetch(q) }
            }
            return nil
        }
        return nil
    }

    private func buddyDue(_ now: Date) {
        let friends: Set<String> = Set(store.book?.friends.map(\.id) ?? [])
        let allowed: [String] = (saved.settings.buddy ?? []).filter { friends.contains($0) }
        let had: [String] = saved.buddySentTo ?? []
        // taken back from those who may not any more
        let gone: [String] = had.filter { !allowed.contains($0) }
        if !gone.isEmpty {
            store.queueBox(.buddy(BuddyPlan(on: false)), to: gone, slot: BuddyRules.slot, ttl: BuddyRules.ttl)
        }
        guard !allowed.isEmpty else {
            saved.buddySentTo = nil
            saved.buddySent = nil
            saved.buddySentAt = nil
            return
        }
        // (left today: also when you're well away from home at a check on the plan's day)
        let plan0: BuddyPlan = myPlan(now)
        if saved.leftDay != TimetableDays.key(now), let leave = plan0.leave, plan0.day == TimetableDays.key(now),
           now > leave.addingTimeInterval(-60 * 60), let fix = position(maxAge: 600) {
            let h = Place.home.coordinate
            if fix.distance(from: CLLocation(latitude: h.latitude, longitude: h.longitude)) > BuddyRules.awayMetres { markLeft() }
        }
        let plan: BuddyPlan = myPlan(now)
        let fresh: [String] = allowed.filter { !had.contains($0) }
        if BuddyRules.due(last: saved.buddySent, lastAt: saved.buddySentAt, next: plan, now: now) {
            store.queueBox(.buddy(plan), to: allowed, slot: BuddyRules.slot, ttl: BuddyRules.ttl)
            saved.buddySent = plan
            saved.buddySentAt = now
        } else if !fresh.isEmpty {
            store.queueBox(.buddy(plan), to: fresh, slot: BuddyRules.slot, ttl: BuddyRules.ttl)
        }
        saved.buddySentTo = allowed
    }

    // MARK: the wake-up buddy (theirs)

    /// Each friend who lets you know: not moving yet by their planned time (5 minutes after it), once a day.
    private func buddyWatch(_ now: Date) {
        let today: String = TimetableDays.key(now)
        for (id, b) in saved.buddies where b.plan.on && store.book?.isFriend(id) == true {
            let cards: [(card: TripCard, sent: Bool)] = cardsWith(id, since: now.addingTimeInterval(-24 * 3600))
            guard let plan = BuddyRules.plan(b.plan, cards: cards, today: today) else { continue }
            var seen: [Date] = []
            if let t = store.travel[id] { seen.append(t.sent) }
            if let w = saved.waits[id] { seen.append(w.got) }
            let left: Date? = b.plan.day == today ? b.plan.left : nil
            let moving: Bool = BuddyRules.moving(left: left, seen: seen, leave: plan.leave)
            guard BuddyRules.alert(leave: plan.leave, ride: plan.ride, moving: moving, told: saved.buddyTold[id], today: today, now: now) else { continue }
            saved.buddyTold[id] = today
            let name: String = store.name(id)
            tell(title: BuddyWords.title(name, leave: plan.leave, ride: plan.ride), body: BuddyWords.body(name, leave: plan.leave, ride: plan.ride),
                 id: "friends-buddy-\(id)", chat: ChatKey.friend(id))
        }
    }

    /// Trip cards someone is in (they sent it: `sent`; or said "I'm in"), in your chats with them or your groups.
    private func cardsWith(_ id: String, since: Date) -> [(card: TripCard, sent: Bool)] {
        var out: [(card: TripCard, sent: Bool)] = []
        let book = FriendChats.shared.book
        for chat in FriendChats.shared.recent {
            guard chat.key == id || ChatKey.isGroup(chat.key) else { continue }
            for m in chat.messages where m.at > since {
                guard let c = m.trip else { continue }
                if m.from == id { out.append((card: c, sent: true)); continue }
                if book.answers(to: m.n, in: chat.key)[id] == .yes { out.append((card: c, sent: false)) }
            }
        }
        return out
    }

    // MARK: the delay alarm

    /// Your trip's rides now (the one you're on, the next at a change, the planned ones still to come).
    private func myRides(_ now: Date) -> [TripCard.Ride] {
        guard let t = trip, t.phase != .idle, t.phase != .finished, !t.demo else { return [] }
        var out: [TripCard.Ride] = []
        let end: Date = t.arrival ?? now.addingTimeInterval(3600)
        if let v = t.vehicle, let l = t.leg {
            let dep: Date = t.legFrom ?? now
            let arr: Date = max(dep, t.legArrival ?? t.legTo ?? end)
            var r = TripCard.Ride(mode: v.isTrain ? "train" : "bus", line: v.isTrain ? Transit.trainLabel(v.line) : v.line, trip: v.tripId,
                                  from: Self.spot(l.from), to: Self.spot(l.to), dep: dep, arr: arr)
            r.num = FriendTravelShare.shared.numbers[v.tripId]
            out.append(r)
        }
        if t.phase == .transfer, let n = t.next { out.append(TripCards.ride(n)) }
        let planned: [PlannedRide] = t.route?.planned ?? []
        for (k, p) in planned.enumerated() where k > t.index && !p.tripId.isEmpty && !out.contains(where: { $0.trip == p.tripId }) {
            guard let l = t.legs[safe: k] else { continue }
            let arr: Date = max(p.departure, end)
            out.append(TripCard.Ride(mode: p.isTrain ? "train" : "bus", line: p.isTrain ? Transit.trainLabel(p.line) : p.line, trip: p.tripId,
                                     from: Self.spot(l.from), to: Self.spot(l.to), dep: p.departure, arr: arr))
        }
        return out
    }

    /// Trip cards you're in, with the others who are.
    private func myCards(_ now: Date) -> [(card: TripCard, riders: [String])] {
        var out: [(card: TripCard, riders: [String])] = []
        let book = FriendChats.shared.book
        for chat in FriendChats.shared.recent {
            for m in chat.messages where m.at > now.addingTimeInterval(-24 * 3600) {
                guard let c = m.trip else { continue }
                let answers: [String: TripAnswer] = book.answers(to: m.n, in: chat.key)
                if let r = DelayAlarm.riders(sender: m.from, answers: answers, me: me) { out.append((card: c, riders: r)) }
            }
        }
        return out
    }

    /// Looks at the live times of the rides you share (at most every 2 minutes, in a check): late 3 minutes or more,
    /// or cancelled, tells you and everyone else on it, with the next ride all of you can take.
    private func checkDelays() async {
        let now = Date()
        let travel: [(from: String, state: TravelState)] = store.travelling(now: now).map { (from: $0.from, state: $0.state) }
        let refs: [SharedRideRef] = DelayAlarm.shared(mine: myRides(now), travel: travel, cards: myCards(now), me: me, now: now)
        guard !refs.isEmpty else { return }
        checkingDelays = true
        defer { checkingDelays = false }
        var sent = false
        for ref in refs.prefix(3) {
            guard let live = await lateness(ref.ride, now: now) else { continue }
            let trip: String = ref.ride.trip
            guard DelayAlarm.shouldTell(late: live.late, cancelled: live.cancelled, told: saved.delayTold[trip]) else { continue }
            var ride: TripCard.Ride = ref.ride
            if let d = live.dep {
                ride.sdep = d.addingTimeInterval(-Double(live.late) * 60)
                ride.dep = d
                if ride.arr < d { ride.arr = d }
            }
            let earlier: TripCard.Ride? = saved.delays.first { $0.delay.ride.trip == trip }?.delay.next
            var next: TripCard.Ride? = earlier
            if next == nil { next = await nextTogether(ref, now: now) }
            let d = RideDelay(ride: ride, late: live.late, cancelled: live.cancelled ? true : nil, next: next, who: [me] + ref.riders)
            heard(DelaySeen(from: me, delay: d, got: now))
            store.queueBox(.delay(d), to: ref.riders, slot: DelayAlarm.slot, ttl: DelayAlarm.ttl)
            sent = true
        }
        save()
        publish()
        if sent { Task { await store.sync(.now) } }
    }

    /// How late a ride is: NS's board for a train at an NS station, else the live data's stops.
    private func lateness(_ r: TripCard.Ride, now: Date) async -> (late: Int, cancelled: Bool, dep: Date?)? {
        if r.isTrain, let num = r.num, !num.isEmpty, let code = NSStore.code(stopId: r.from.id ?? "", name: r.from.name) {
            _ = await NSStore.shared.board(code)
            if let m = NSStore.shared.match(code, num: num, planned: r.sdep ?? r.dep) {
                return (m.cancelled ? 0 : max(0, m.delay), m.cancelled, m.actual)
            }
        }
        guard let stops = await Transit.boardStops(r.trip, maxAge: 120) else { return nil }
        return DelayAlarm.read(stops, board: r.from, now: now)
    }

    /// The next ride all of you can take: each person's ways from where they get on to where they get off (at most
    /// `DelayAlarm.budget` questions), matched as 0.28 does.
    private func nextTogether(_ ref: SharedRideRef, now: Date) async -> TripCard.Ride? {
        var who: [(id: String, from: TripCard.Spot, to: TripCard.Spot)] = [(id: me, from: ref.ride.from, to: ref.ride.to)]
        for id in ref.riders {
            let s: [TripCard.Spot] = ref.spots[id] ?? [ref.ride.from, ref.ride.to]
            if s.count == 2 { who.append((id: id, from: s[0], to: s[1])) }
        }
        var asked: [String: [Way]] = [:]
        var people: [PersonWays] = []
        let at: Date = now.addingTimeInterval(60)
        for p in who {
            guard let a = WayMaking.place(p.from), let b = WayMaking.place(p.to) else { continue }
            let k = "\(a)>\(b)"
            if asked[k] == nil {
                guard asked.count < DelayAlarm.budget else { continue }
                let trips: [DoorTrip] = await Transit.plan(from: a, to: b, modes: nil, at: at, count: 5, maxTransfers: 2)
                asked[k] = trips.map(WayMaking.way)
            }
            if let ways = asked[k], !ways.isEmpty { people.append(PersonWays(id: p.id, ways: ways, bound: at)) }
        }
        guard people.count >= 2, let s = DelayAlarm.next(people, exclude: ref.ride.trip, after: now.addingTimeInterval(2 * 60)),
              let first = s.riders.min(by: { $0.dep < $1.dep }),
              let w = people.first(where: { $0.id == first.id })?.ways[safe: first.way], let leg = w.legs[safe: first.leg] else { return nil }
        return leg.card
    }

    /// Delays now on rides you're on (for the ride screen).
    func delaysNow(trips: Set<String>, now: Date = Date()) -> [DelaySeen] {
        delays.filter { trips.contains($0.delay.ride.trip) && $0.delay.ride.arr > now }
    }

    // MARK: the vault, a restore, signing out

    var vaultSettings: ExtrasSettings? { saved.settings == ExtrasSettings() ? nil : saved.settings }

    func restore(_ s: ExtrasSettings?) {
        saved.settings = s ?? ExtrasSettings()
        save()
        publish()
        mirrorCampus()
    }

    func forgetAll() {
        saved = Saved()
        save()
        publish()
        mirrorCampus()
    }
}
