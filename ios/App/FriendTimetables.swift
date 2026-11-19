import CoreLocation
import EventKit
import Foundation

/// Friends (0.28): timetables and start areas, yours and your friends'. Kept in a file beside the friend list
/// (Friends/timetables.json, not backed up); the switches also go in the vault. Yours is read from your timetable
/// (the calendars you picked, or your week) and sent by `FriendStore` at its checks of the relay: when it changed (at
/// most every 3 hours), at once to someone new, and once a day anyway. No loop of its own.
@MainActor
final class FriendTimetables: ObservableObject {
    static let shared = FriendTimetables()

    /// Friends' (and group members') timetables and areas, by account.
    @Published private(set) var seen: [String: TimetableSeen] = [:]
    @Published private(set) var areas: [String: AreaSeen] = [:]
    /// The one-time screen was answered.
    @Published private(set) var answered = false
    /// "Share my timetable" for everyone.
    @Published private(set) var on = true
    /// People it's off for (friends, or people in a group).
    @Published private(set) var off: Set<String> = []
    /// Groups you share it with (their members who aren't your friends get it too).
    @Published private(set) var groupsOn: Set<String> = []
    /// Yours, as last read (for the compare screen), and when it last went out.
    @Published private(set) var mine: TimetableShare?
    @Published private(set) var myArea: TimetableArea?
    @Published private(set) var sentAt: Date?
    @Published private(set) var sentCount = 0

    typealias Settings = TimetableSettings

    private struct Saved: Codable {
        var seen: [String: TimetableSeen] = [:]
        var areas: [String: AreaSeen] = [:]
        var settings = Settings()
        var sent: TimetableShareRules.Sent?
        var areaSent: TimetableShareRules.Sent?
        var areaStops: AreaStops?
    }

    /// The stops near home, as looked up once (and again when home moves).
    struct AreaStops: Codable, Equatable {
        var lat: Double
        var lon: Double
        var stops: [TripCard.Spot]
    }

    private var saved = Saved()
    private var lastLook = Date.distantPast
    private var dirty = true
    private var observer: NSObjectProtocol?

    private static var file: URL? { FriendStore.folder?.appendingPathComponent("timetables.json") }

    private init() {
        if let f = Self.file, let d = try? Data(contentsOf: f), let s = try? FriendJSON.decoder.decode(Saved.self, from: d) { saved = s }
        seen = saved.seen
        areas = saved.areas
        readSettings()
        sentAt = saved.sent?.at
        sentCount = saved.sent?.to.count ?? 0
        // a calendar changed (TimeEdit synced): look again at the next check
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { _ in
            Task { @MainActor in FriendTimetables.shared.changed() }
        }
    }

    private func readSettings() {
        let s = saved.settings
        answered = s.answered ?? false
        on = s.on ?? true
        off = Set(s.off ?? [])
        groupsOn = Set(s.groups ?? [])
    }

    private func save() {
        saved.seen = seen
        saved.areas = areas
        guard let f = Self.file, let d = try? FriendJSON.encoder.encode(saved) else { return }
        try? d.write(to: f, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Your timetable or week changed: it's read again at the next check.
    func changed() { dirty = true }

    // MARK: the switches

    var settings: Settings { saved.settings }

    /// Back from the vault (a restore), or cleared (signed out).
    func restore(_ s: Settings?) {
        saved.settings = s ?? Settings()
        readSettings()
        dirty = true
        save()
    }

    func forgetAll() {
        saved = Saved()
        seen = [:]
        areas = [:]
        mine = nil
        myArea = nil
        sentAt = nil
        sentCount = 0
        readSettings()
        save()
    }

    /// The one-time screen, answered.
    func answer(share: Bool) {
        saved.settings.answered = true
        saved.settings.on = share
        readSettings()
        dirty = true
        save()
        FriendStore.shared.timetableSettingsChanged()
    }

    func setOn(_ v: Bool) {
        saved.settings.answered = true
        saved.settings.on = v
        readSettings()
        dirty = true
        save()
        FriendStore.shared.timetableSettingsChanged()
    }

    /// "Share my timetable with Sam".
    func setShares(_ id: String, _ v: Bool) {
        var o = off
        if v { o.remove(id) } else { o.insert(id) }
        saved.settings.off = o.isEmpty ? nil : o.sorted()
        readSettings()
        dirty = true
        save()
        FriendStore.shared.timetableSettingsChanged()
    }

    func shares(with id: String) -> Bool { answered && on && !off.contains(id) }

    /// "Share my timetable with this group" (its members who aren't your friends get it too).
    func setGroup(_ gid: String, _ v: Bool) {
        var g = groupsOn
        if v { g.insert(gid) } else { g.remove(gid) }
        saved.settings.groups = g.isEmpty ? nil : g.sorted()
        if v && !answered { saved.settings.answered = true; saved.settings.on = true }
        readSettings()
        dirty = true
        save()
        FriendStore.shared.timetableSettingsChanged()
    }

    // MARK: what came

    /// A batch from the relay: the newest of each; taken back ones go.
    func take(_ r: FriendInbox.Result) {
        guard !r.timetables.isEmpty || !r.areas.isEmpty || !r.timetablesOff.isEmpty else { return }
        for id in r.timetablesOff { seen[id] = nil; areas[id] = nil }
        for (id, t) in r.timetables where (seen[id]?.t ?? Int.min) <= t.t { seen[id] = t }
        for (id, a) in r.areas where (areas[id]?.t ?? Int.min) <= a.t { areas[id] = a }
        save()
    }

    /// Only the people still in your list or a group with you.
    func keep(_ ids: Set<String>) {
        let before = seen.count + areas.count
        seen = seen.filter { ids.contains($0.key) }
        areas = areas.filter { ids.contains($0.key) }
        if seen.count + areas.count != before { save() }
    }

    func timetable(_ id: String) -> TimetableShare? { seen[id]?.share }
    func area(_ id: String) -> TimetableArea? { areas[id]?.area }

    // MARK: yours

    /// Time to read yours again (and maybe send it): something changed, it's been 30 minutes, or someone new should
    /// get it.
    func lookDue(now: Date, newRecipients: Bool) -> Bool {
        dirty || newRecipients || now.timeIntervalSince(lastLook) >= TimetableShareRules.lookEvery || now < lastLook
    }

    /// Reads your timetable and area now (no network but, once, the stops near your home).
    /// `sharing`: read for sending (the next look is then 30 minutes on); the compare screen's read doesn't count.
    func readMine(now: Date = Date(), sharing: Bool = true) async -> (TimetableShare?, TimetableArea?) {
        if sharing {
            lastLook = now
            dirty = false
        }
        var share: TimetableShare?
        if let got = await SchoolAlarm.shared.friendClasses(days: TimetableShare.days) {
            let w = TimetableDays.window(now: now)
            share = TimetableShare.valid(TimetableShare(from: w.from, to: w.to, classes: got.classes, src: got.src))
        }
        let area = await readArea()
        mine = share
        myArea = area
        return (share, area)
    }

    /// Your school, the train station nearest home (NS's list, on the phone) and the bus stops nearest home: your
    /// board stops where the setup knows where they are, else looked up once near home (one question to Transitous,
    /// remembered until home moves).
    private func readArea() async -> TimetableArea? {
        let school = Place.school
        let sid: String? = school.ids.first.flatMap { $0.contains(",") ? nil : $0 }
        let schoolSpot = TripCard.Spot(name: RoleWords.current.school, id: sid,
                                       lat: Self.round(school.coordinate.latitude), lon: Self.round(school.coordinate.longitude))
        let home = Place.home.point
        var stops: [TripCard.Spot] = StopsStore.shared.boardStops.compactMap { b -> TripCard.Spot? in
            guard let la = b.lat, let lo = b.lon, Geo.metres(home, GeoPoint(lat: la, lon: lo)) < 3000 else { return nil }
            return TripCard.Spot(name: b.name, id: b.id, lat: la, lon: lo)
        }
        if stops.isEmpty { stops = await nearHomeStops(home) }
        var station: TimetableArea.Station?
        if let s = NearestStation.pick(home, in: NSCodes.shared.stations) {
            station = TimetableArea.Station(name: s.name, code: s.code, id: nil, lat: s.lat, lon: s.lon)
        }
        let a = TimetableArea(stops: Array(stops.prefix(TimetableArea.maxStops)), station: station, school: schoolSpot,
                              early: SchoolAlarm.shared.earlyMinutes)
        return TimetableArea.valid(a)
    }

    private func nearHomeStops(_ home: GeoPoint) async -> [TripCard.Spot] {
        if let c = saved.areaStops, Geo.metres(home, GeoPoint(lat: c.lat, lon: c.lon)) < 300 { return c.stops }
        guard let near = await Transit.nearStopsAnswer(CLLocationCoordinate2D(latitude: home.lat, longitude: home.lon)) else {
            return saved.areaStops?.stops ?? []
        }
        let list: [TripCard.Spot] = near.filter { !$0.rail && $0.meters < 1200 }.prefix(3).map {
            TripCard.Spot(name: $0.name, id: $0.id, lat: $0.lat, lon: $0.lon)
        }
        saved.areaStops = AreaStops(lat: home.lat, lon: home.lon, stops: list)
        save()
        return list
    }

    private static func round(_ v: Double) -> Double { (v * 100_000).rounded() / 100_000 }

    // MARK: what went

    var sent: TimetableShareRules.Sent? { saved.sent }
    var areaSent: TimetableShareRules.Sent? { saved.areaSent }

    func didSend(_ s: TimetableShareRules.Sent?, area: TimetableShareRules.Sent?) {
        saved.sent = s
        saved.areaSent = area
        sentAt = s?.at
        sentCount = s?.to.count ?? 0
        save()
    }
}
