import CoreLocation
import Foundation
import UIKit
import UserNotifications

/// 0.36: the travel help around your trips — its settings (check-out reminder, money back for a late train, student
/// travel product, works on your routes, last way home), NS's prices for the student OV line, the works and disruptions
/// on the trains you usually take, and the last way home in the evening. The rules are in `StudentOV`, `CheckOut`,
/// `DelayClaim`, `RailWorks` and `LastTrip`; this fetches, keeps and notifies. Battery: NS's works at most every 4 hours
/// and the last way home at most hourly, both only when the app is awake anyway (in front, or a background refresh).
@MainActor
final class TravelNotes: ObservableObject {
    static let shared = TravelNotes()
    private let d = UserDefaults.standard
    /// For where you are (its newest fix), set when the app starts.
    weak var trip: TripManager?

    // MARK: settings

    @Published var checkOut: Bool {
        didSet {
            d.set(checkOut, forKey: CheckOut.settingKey)
            if !checkOut { clearPending(prefix: "checkout-") }      // (0.42.4) off: nothing still to come
        }
    }
    @Published var delayClaim: Bool { didSet { d.set(delayClaim, forKey: "notes.delayClaim") } }
    @Published var works: Bool {
        didSet {
            d.set(works, forKey: "notes.works")
            if works { Task { await self.refreshWorks(force: true) } } else { impacts = []; clearPending(prefix: "works-") }
            SchoolAlarm.scheduleBackground()
        }
    }
    @Published var lastHome: Bool {
        didSet {
            d.set(lastHome, forKey: "notes.lastHome")
            if lastHome { Task { await self.refreshLastHome(force: true) } } else { lastWay = nil; clearPending(prefix: "lasthome-") }
            SchoolAlarm.scheduleBackground()
        }
    }
    @Published var student: StudentOV.Product { didSet { d.set(student.rawValue, forKey: "notes.student") } }

    /// A background refresh is wanted for the works or the last way home (read off the main actor too).
    nonisolated static var wantsBackground: Bool {
        let u = UserDefaults.standard
        return (u.object(forKey: "notes.works") as? Bool ?? true) || (u.object(forKey: "notes.lastHome") as? Bool ?? true)
    }

    private init() {
        let d = UserDefaults.standard
        // (0.42.4) off for everyone, once; on again only by its switch (`CheckOut.atLaunch`)
        let co = CheckOut.atLaunch(stored: d.object(forKey: CheckOut.settingKey) as? Bool, movedOff: d.bool(forKey: CheckOut.movedOffKey))
        checkOut = co.on
        if co.moveOff { d.set(false, forKey: CheckOut.settingKey); d.set(true, forKey: CheckOut.movedOffKey) }
        delayClaim = d.object(forKey: "notes.delayClaim") as? Bool ?? true
        works = d.object(forKey: "notes.works") as? Bool ?? true
        lastHome = d.object(forKey: "notes.lastHome") as? Bool ?? true
        student = StudentOV.Product(rawValue: d.string(forKey: "notes.student") ?? "") ?? .none
        prices = (d.dictionary(forKey: "notes.prices") as? [String: Int]) ?? [:]
        priceDay = d.string(forKey: "notes.priceDay") ?? ""
        rideSeen = (d.dictionary(forKey: "notes.rides") as? [String: Double]) ?? [:]
        worksAt = d.object(forKey: "notes.worksAt") as? Date
        dismissedWorks = Set(d.stringArray(forKey: "notes.worksDismissed") ?? [])
        if let data = d.data(forKey: "notes.worksData") { items = RailWorks.parse(data) }
        recomputeImpacts()
        if !checkOut { clearPending(prefix: "checkout-") }          // (0.42.4) none left from before, while it's off
    }

    // MARK: where you are

    private var here: CLLocation? {
        if let f = trip?.lastFix, f.horizontalAccuracy >= 0, f.horizontalAccuracy < 500, -f.timestamp.timeIntervalSinceNow < 1800 { return f }
        if let f = CLLocationManager().location, f.horizontalAccuracy >= 0, f.horizontalAccuracy < 500, -f.timestamp.timeIntervalSinceNow < 1800 { return f }
        return nil
    }

    /// The app is awake (in front, a background refresh, a new position): what's due of the works and the last way
    /// home. Cheap when nothing is due.
    func tick() async {
        NoticeSweep.soon()
        await refreshLastHome(force: false)
        await refreshWorks(force: false)
    }

    // MARK: student OV: NS's price for a journey

    /// Full 2nd-class fares by "FROM>TO" (cents), kept for the day (NS changes prices once a year).
    @Published private(set) var prices: [String: Int] = [:]
    private var priceDay: String
    private var priceAsked: Set<String> = []

    func fullFare(from: String, to: String) -> Int? { prices["\(from)>\(to)"] ?? prices["\(to)>\(from)"] }

    /// NS's price through the relay (`/ns/price`), once a day per journey; nothing when the relay has no answer (the
    /// line then says the discount without an amount).
    func askPrice(from: String, to: String) async {
        guard student != .none, from != to else { return }
        let today = RailWorks.dayKey(Date())
        if priceDay != today { priceDay = today; priceAsked = []; d.set(today, forKey: "notes.priceDay") }
        let k = "\(from)>\(to)"
        guard !priceAsked.contains(k) else { return }
        priceAsked.insert(k)
        if prices[k] != nil, d.string(forKey: "notes.price.\(k)") == today { return }
        let r = await Self.relay("/ns/price?from=\(from)&to=\(to)", label: "/ns/price")
        guard let data = r, let j = try? JSONSerialization.jsonObject(with: data), let c = StudentOV.fullFareCents(j) else { return }
        prices[k] = c
        d.set(prices, forKey: "notes.prices"); d.set(today, forKey: "notes.price.\(k)")
    }

    nonisolated private static func relay(_ path: String, label: String) async -> Data? {
        guard let url = URL(string: NSStore.relay + path) else { return nil }
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        r.setValue(Transit.userAgent, forHTTPHeaderField: "User-Agent")
        guard let a = try? await Net.response(r, lane: .background, label: label), a.status == 200 else { return nil }
        return a.data
    }

    /// The rail part of a trip: its first train's station and its last train's (NS codes).
    nonisolated static func railEnds(_ rides: [Ride]) -> (from: String, to: String)? {
        guard let f = rides.first(where: \.isTrain), let l = rides.last(where: \.isTrain),
              let a = NSStore.code(stopId: f.fromId, name: f.fromStop), let b = NSStore.code(stopId: "", name: l.toStop), a != b else { return nil }
        return (a, b)
    }

    // MARK: the trains you usually take

    /// "A>B" (sorted) → when last seen; kept 45 days, the 12 newest.
    private var rideSeen: [String: Double]

    /// Trips between Home and School, and the trips you plan: their train rides are your usual ones.
    func noteRails(_ trips: [DoorTrip]) {
        var changed = false
        for t in trips.prefix(6) {
            for r in t.rides where r.isTrain {
                guard let a = NSStore.code(stopId: r.fromId, name: r.fromStop), let b = NSStore.code(stopId: "", name: r.toStop), a != b else { continue }
                changed = noteRail(a, b) || changed
            }
        }
        if changed { saveRides() }
    }

    /// A trip's legs (a trip you started): its train legs.
    func noteLegs(_ legs: [Leg]) {
        var changed = false
        for l in legs where l.mode == .train {
            guard let a = NSStore.code(l.from), let b = NSStore.code(l.to), a != b else { continue }
            changed = noteRail(a, b) || changed
        }
        if changed { saveRides() }
    }

    private func noteRail(_ a: String, _ b: String) -> Bool {
        let k = a < b ? "\(a)>\(b)" : "\(b)>\(a)"
        let now = Date().timeIntervalSince1970
        let old = rideSeen[k]
        rideSeen[k] = now
        return old == nil || now - (old ?? 0) > 3600
    }

    private func saveRides() {
        let cut = Date().timeIntervalSince1970 - 45 * 86400
        var kept = rideSeen.filter { $0.value >= cut }
        if kept.count > 12 { kept = Dictionary(uniqueKeysWithValues: kept.sorted { $0.value > $1.value }.prefix(12).map { ($0.key, $0.value) }) }
        rideSeen = kept
        d.set(kept, forKey: "notes.rides")
    }

    /// Your usual train rides: those seen, and on the corridor its two (Den Bosch or Eindhoven to Breda).
    var usualRides: [RailWorks.Ride] {
        var keys = Set(rideSeen.keys)
        if RoleSnapshot.corridor != nil, let bd = NSStore.code(.breda) {
            for hub in [Place.denBosch, Place.eindhoven] { if let h = NSStore.code(hub) { keys.insert(h < bd ? "\(h)>\(bd)" : "\(bd)>\(h)") } }
        }
        return keys.sorted().compactMap { k in
            let p = k.split(separator: ">").map(String.init)
            return p.count == 2 ? RailWorks.Ride(from: p[0], to: p[1]) : nil
        }
    }

    nonisolated static func point(_ code: String) -> GeoPoint? { NSCodes.shared.station(code)?.point }

    /// The stations to ask NS about: your rides' own and those they pass (at most 40).
    private func stationsToAsk(_ rides: [RailWorks.Ride]) -> [String] {
        let all = NSCodes.shared.stations.map(\.code)
        var out: [String] = []
        for r in rides {
            for c in [r.from, r.to] + RailWorks.passed(r, stretch: all, point: Self.point) where !out.contains(c) { out.append(c) }
        }
        return Array(out.prefix(40))
    }

    // MARK: works and disruptions on your routes

    private var items: [RailWorks.Item] = []
    private var worksAt: Date?
    private var worksBusy = false
    /// What's on your rides today and the next 7 days, the soonest first.
    @Published private(set) var impacts: [RailWorks.Impact] = []
    /// How many minutes earlier to leave, by impact key (worked out with Transitous for a school day).
    @Published private(set) var earlier: [String: Int] = [:]
    @Published private(set) var dismissedWorks: Set<String>

    /// On the home: today's or tomorrow's, unless you closed it.
    var homeWorks: RailWorks.Impact? {
        guard works else { return nil }
        let cal = RailWorks.calendar
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!
        return impacts.first { $0.dayStart <= tomorrow && !dismissedWorks.contains($0.key) }
    }

    func headline(_ i: RailWorks.Impact) -> String { RailWorks.headline(i, now: Date(), earlier: earlier[i.key]) }

    func dismiss(_ i: RailWorks.Impact) {
        dismissedWorks.insert(i.key)
        let keep = dismissedWorks.filter { k in impacts.contains { $0.key == k } || k.hasPrefix(RailWorks.dayKey(Date())) }
        d.set(Array(keep), forKey: "notes.worksDismissed")
    }

    /// A school day's travel window (an hour before you leave until you're there), else the whole day.
    private func window(_ dayStart: Date) -> (Date, Date)? {
        RailWorks.defaultWindow(dayStart)
    }

    private func recomputeImpacts() {
        impacts = works ? RailWorks.impacts(items, rides: usualRides, now: Date(), window: { self.window($0) }, point: Self.point) : []
    }

    /// NS's works and disruptions for your stations, at most every 4 hours (`force`: now); then what's on your rides,
    /// how much earlier to leave, and the evening-before notifications.
    func refreshWorks(force: Bool) async {
        guard works, !worksBusy else { return }
        let rides = usualRides
        guard !rides.isEmpty else { impacts = []; return }
        let due = force || worksAt.map { Date().timeIntervalSince($0) >= RailWorks.fetchEvery || Date() < $0 } ?? true
        if due {
            worksBusy = true
            defer { worksBusy = false }
            let codes = stationsToAsk(rides).joined(separator: ",")
            if let data = await Self.relay("/ns/disruptions?stations=\(codes)", label: "/ns/disruptions") {
                items = RailWorks.parse(data)
                worksAt = Date()
                d.set(data, forKey: "notes.worksData"); d.set(worksAt, forKey: "notes.worksAt")
            } else {
                worksAt = Date().addingTimeInterval(-RailWorks.fetchEvery + 1800)       // (again in half an hour)
            }
            recomputeImpacts()
            await workOutEarlier()
        } else {
            recomputeImpacts()
        }
        scheduleWorkNotices()
    }

    /// For a school day with works on your way: Transitous asked again for that day (arrive by when you want to be
    /// there), against your usual door-to-door time on the other school days.
    private func workOutEarlier() async {
        let week = SchoolAlarm.shared.week
        let days = Set(impacts.map(\.day))
        let usual: [Double] = week.filter { !days.contains($0.day) }.compactMap { p in
            guard let l = p.leave, let a = p.arrive else { return nil }
            return a.timeIntervalSince(l) / 60
        }.sorted()
        let usualMinutes: Double? = usual.isEmpty ? nil : usual[usual.count / 2]
        var out: [String: Int] = [:]
        var asked = 0
        for i in impacts {
            guard let p = week.first(where: { $0.day == i.day }), p.beThere > Date() else { continue }
            var leave = p.leave
            if asked < 3 {
                asked += 1
                let trips = await Transit.plan(from: .home, to: .school, modes: nil, at: p.beThere, count: 4, maxTransfers: 4, arriveBy: true)
                if let best = trips.filter({ $0.end <= p.beThere.addingTimeInterval(60) }).max(by: { $0.start < $1.start }) { leave = best.start }
            }
            if let e = RailWorks.leaveEarlier(usualMinutes: usualMinutes, newLeave: leave, beThere: p.beThere) { out[i.key] = e }
        }
        earlier = out
    }

    /// The evening before each day with works on your way: a notification at 19:30 (now, if that has passed and it's
    /// before 23:00). Ones no longer on are taken back.
    private func scheduleWorkNotices() {
        let c = UNUserNotificationCenter.current()
        let now = Date()
        var told = Set(d.stringArray(forKey: "notes.worksTold") ?? [])
        // one per day: the first thing on that day
        var byDay: [String: RailWorks.Impact] = [:]
        for i in impacts where byDay[i.day] == nil && i.dayStart > now { byDay[i.day] = i }
        let ids = Set(byDay.values.map { "works-\($0.day)-\($0.id)" })
        c.getPendingNotificationRequests { reqs in
            let gone = reqs.map(\.identifier).filter { $0.hasPrefix("works-") && !ids.contains($0) }
            if !gone.isEmpty { c.removePendingNotificationRequests(withIdentifiers: gone) }
        }
        for i in byDay.values {
            let id = "works-\(i.day)-\(i.id)"
            guard !told.contains(id) else { continue }
            let content = UNMutableNotificationContent()
            content.title = i.works ? "Works on your route" : "Disruption on your route"
            content.body = headline(i)
            content.sound = .default
            content.userInfo = ["kind": "late"]
            let at = RailWorks.eveningBefore(i.dayStart)
            if at > now {
                let comps = RailWorks.calendar.dateComponents(in: RailWorks.zone, from: at)
                let want = DateComponents(calendar: RailWorks.calendar, timeZone: RailWorks.zone, year: comps.year, month: comps.month,
                                          day: comps.day, hour: comps.hour, minute: comps.minute)
                c.add(UNNotificationRequest(identifier: id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: want, repeats: false))) { _ in }
            } else if RailWorks.tellNow(i, now: now) {
                told.insert(id)
                c.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { _ in }
            }
        }
        // (a delivered one is told; the list is kept short)
        d.set(Array(told.filter { k in byDay.values.contains { "works-\($0.day)-\($0.id)" == k } }), forKey: "notes.worksTold")
    }

    private func clearPending(prefix: String) {
        let c = UNUserNotificationCenter.current()
        c.getPendingNotificationRequests { reqs in
            let ids = reqs.map(\.identifier).filter { $0.hasPrefix(prefix) }
            if !ids.isEmpty { c.removePendingNotificationRequests(withIdentifiers: ids) }
        }
    }

    // MARK: the last way home

    /// The latest way home tonight from where you are (evening, more than 3 km from Home); nil otherwise.
    @Published private(set) var lastWay: LastTrip.Option?
    private var lastAsked: Date?
    private var askedAt: GeoPoint?
    private var lastBusy = false

    func refreshLastHome(force: Bool) async {
        guard lastHome, !lastBusy else { return }
        let now = Date()
        guard let h = here else { if !LastTrip.evening(now) { lastWay = nil }; return }
        let homeP = Place.home.coordinate
        let metres = h.distance(from: CLLocation(latitude: homeP.latitude, longitude: homeP.longitude))
        guard LastTrip.wanted(now: now, metresFromHome: metres) else {
            if lastWay != nil { lastWay = nil; clearPending(prefix: "lasthome-") }
            return
        }
        let p = GeoPoint(lat: h.coordinate.latitude, lon: h.coordinate.longitude)
        guard force || LastTrip.refreshDue(lastAsked: lastAsked, askedAt: askedAt, here: p, known: lastWay, now: now) else { return }
        lastBusy = true
        defer { lastBusy = false }
        lastAsked = now; askedAt = p
        var found: LastTrip.Option?
        for by in LastTrip.arriveBy(now: now) {
            let trips = await Transit.plan(from: .here(h.coordinate), to: .home, modes: nil, at: by, count: 5, maxTransfers: 4, arriveBy: true)
            let opts = trips.map { t in
                LastTrip.Option(leave: t.start, firstDeparture: t.first.departure, arrive: t.end, from: Fmt.place(t.first.fromStop),
                                cancelled: t.rides.contains(where: \.cancelled))
            }
            if let i = LastTrip.pick(opts, now: Date()) { found = opts[i]; break }
        }
        lastWay = found
        scheduleLastHome()
    }

    /// A trip started (on the way home, or elsewhere): the "last way home" notification isn't needed now.
    func tripStarted() { clearPending(prefix: "lasthome-") }

    private func scheduleLastHome() {
        let center = UNUserNotificationCenter.current()
        guard let o = lastWay, let at = LastTrip.warnAt(o, now: Date()) else { clearPending(prefix: "lasthome-"); return }
        let t = LastTrip.notice(o, hhmm: Fmt.hhmm)
        let c = UNMutableNotificationContent()
        c.title = t.title; c.body = t.body; c.sound = .default
        c.interruptionLevel = .timeSensitive
        c.userInfo = ["kind": "go"]
        let id = "lasthome-\(Int(o.leave.timeIntervalSince1970))"
        // the others go (this one, added again, replaces itself)
        center.getPendingNotificationRequests { reqs in
            let old = reqs.map(\.identifier).filter { $0.hasPrefix("lasthome-") && $0 != id }
            if !old.isEmpty { center.removePendingNotificationRequests(withIdentifiers: old) }
        }
        center.add(UNNotificationRequest(identifier: id, content: c,
                                         trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, at.timeIntervalSinceNow), repeats: false))) { _ in }
    }

    // MARK: the reminders a trip posts (TripManager decides when)

    nonisolated static func post(id: String, title: String, body: String, kind: String, after: TimeInterval? = nil, url: String? = nil) {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.sound = .default
        var info: [String: Any] = ["kind": kind]
        if let url { info["url"] = url }
        c.userInfo = info
        let trigger = after.map { UNTimeIntervalNotificationTrigger(timeInterval: max(1, $0), repeats: false) }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: trigger)) { _ in }
    }

    nonisolated static func cancel(id: String) {
        let c = UNUserNotificationCenter.current()
        c.removePendingNotificationRequests(withIdentifiers: [id])
        c.removeDeliveredNotifications(withIdentifiers: [id])
    }

    /// Reset everything.
    func reset() {
        student = .none; checkOut = false; delayClaim = true
        for k in ["notes.checkOut", "notes.delayClaim", "notes.works", "notes.lastHome", "notes.student", "notes.prices", "notes.priceDay",
                  "notes.rides", "notes.worksAt", "notes.worksData", "notes.worksDismissed", "notes.worksTold"] { d.removeObject(forKey: k) }
        rideSeen = [:]; items = []; impacts = []; prices = [:]; lastWay = nil; earlier = [:]; dismissedWorks = []
        clearPending(prefix: "works-"); clearPending(prefix: "lasthome-")
    }
}
