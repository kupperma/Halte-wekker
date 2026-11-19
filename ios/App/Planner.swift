import CoreLocation
import Foundation
import UserNotifications

/// The train you take with your friend: arrive in Breda at (or leave Breda at) a time, today or tomorrow.
struct PlannedTrip: Codable, Equatable {
    var out: Bool               // true: to Breda, false: home
    var date: String            // yyyy-MM-dd
    var time: String            // HH:mm
    var leave: Bool? = nil      // a "leave at" plan: `time` is when you head off (else when you want to be there)
    var prefer: [String]? = nil // (0.27) a trip a friend sent: the way with their bus or train (its trip id) goes first

    var leaving: Bool { leave == true }

    var when: Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Europe/Amsterdam"); f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: "\(date) \(time)")
    }
    var expired: Bool {
        guard let w = when else { return true }
        return Date() > w.addingTimeInterval(Double(out ? 90 : 150) * 60)
    }
    /// A "be there by" plan is done at its time; a "leave at" one an hour and a half after it (you're on your way).
    var done: Bool {
        guard let w = when else { return true }
        return Date() > w.addingTimeInterval(leaving ? 90 * 60 : 0)
    }
    var dayLabel: String {
        guard let w = when else { return date }
        let cal = Calendar.current
        if cal.isDateInToday(w) { return "Today" }
        if cal.isDateInTomorrow(w) { return "Tomorrow" }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "EEEE d MMM"
        return f.string(from: w)
    }
}

/// One way to do the planned trip: the train, the bus before it and the bus after it.
struct PlanOption: Identifiable {
    var id: String { train.id }
    let train: DoorTrip
    let from: Place
    let to: Place
    var busIn: DoorTrip?
    var busInAlt: DoorTrip?
    var busOut: DoorTrip?
    var busOutAlt: DoorTrip?
    /// The station on the home's side (on the corridor the hub: Den Bosch or Eindhoven).
    var station: Place
    var tripIds: [String] { [train, busIn, busOut].compactMap { $0?.first.tripId } }

    /// The whole trip, bus, train and bus, as one door-to-door trip (off the corridor the alarm follows it: 0.24).
    var door: DoorTrip {
        let rides = (busIn?.rides ?? []) + train.rides + (busOut?.rides ?? [])
        return DoorTrip(rides: rides, start: busIn?.start ?? train.start, end: busOut?.end ?? train.end)
    }

    /// What "Wake me on this trip" starts: on the corridor the route via its hub (as before); off it this whole trip.
    var route: RoutePlan? { RoutePlan.via(station) ?? RoutePlan.from(door) }
}

/// "A train's time" off the corridor (0.24): the stations nearest Home and School, and how Plan names it. On the
/// corridor it's the friend's train between Breda and the two hubs.
enum TrainTime {
    /// Off the corridor: the station nearest Home and the one nearest School (nil: either has no rail within 5 km, or
    /// it's the same station). Nil on the corridor (its stations are the hubs and Breda).
    static var stations: (home: Place, school: Place)? {
        let r = RoleSnapshot.current
        guard r.corridor == nil, let p = NearestStation.pair(home: r.home.point, school: r.school.point, in: NSCodes.shared.stations) else { return nil }
        return (Place(station: p.home), Place(station: p.school))
    }
    /// Plan by a train's time is offered: on the corridor, or with a station near both Home and School.
    static var available: Bool { RoleSnapshot.corridor != nil || stations != nil }
    static var words: TrainTimeWords {
        let s = stations
        return TrainTimeWords.make(corridor: RoleSnapshot.corridor, school: RoleWords.current.school, homeStation: s?.home.short, schoolStation: s?.school.short)
    }
}

extension Place {
    /// An NS station as a place to plan from (key "ns:UT": NS is asked about it by its code).
    init(station s: NSStation) {
        self.init(key: "ns:\(s.code)", name: s.name, short: s.name, ids: ["\(s.lat),\(s.lon)"],
                  coordinate: CLLocationCoordinate2D(latitude: s.lat, longitude: s.lon), spoken: s.name)
    }
}

@MainActor
final class Planner: ObservableObject {
    @Published private(set) var trip: PlannedTrip?
    @Published private(set) var options: [PlanOption] = []
    @Published private(set) var inexact = false
    @Published private(set) var error: String?
    @Published private(set) var updated: Date?
    @Published private(set) var busy = false
    @Published var pick = 0 { didSet { if !holdWatch { watchChosen() } } }
    /// Held only across the synchronous `pick = 0` reset in `refresh`, so the didSet doesn't set up the watch before NS
    /// has answered; `refresh` sets it up itself after `enrich`.
    private var holdWatch = false

    // MARK: be there by a time

    /// Be at school (or home) by a time: `out` is to BUas, `time` when you want to be there.
    @Published private(set) var arrive: PlannedTrip?
    /// The trips that get you there in time, the best first: the one that leaves the latest (then the fewest changes).
    @Published private(set) var arriveOptions: [DoorTrip] = []
    @Published var arrivePick = 0 { didSet { remind() } }
    @Published private(set) var arriveError: String?
    @Published private(set) var arriveBusy = false
    private var arriveUpdated: Date?

    init() {
        trip = UserDefaults.standard.data(forKey: "plannedTrip").flatMap { try? JSONDecoder().decode(PlannedTrip.self, from: $0) }
        if trip?.expired == true { clear() }
        arrive = UserDefaults.standard.data(forKey: "arrivePlan").flatMap { try? JSONDecoder().decode(PlannedTrip.self, from: $0) }
        if let a = arrive, a.done { clearArrive() }
    }

    var arriveChosen: DoorTrip? { arriveOptions[safe: arrivePick] ?? arriveOptions.first }

    /// Plan backwards from when you want to be there, or (`leave`) forwards from when you want to head off. Returns a
    /// message if the time doesn't work.
    func setArrive(out: Bool, time: Date, tomorrow: Bool, leave: Bool = false, prefer: [String]? = nil) -> String? {
        let day = Calendar.current.date(byAdding: .day, value: tomorrow ? 1 : 0, to: Date())!
        let a = PlannedTrip(out: out, date: Fmt.ymd.string(from: day), time: Fmt.hhmm(time), leave: leave ? true : nil, prefer: prefer)
        if let w = a.when {
            if leave, w < Date().addingTimeInterval(-5 * 60) { return "That time has passed today. Pick a later time, or Tomorrow." }
            if !leave, w < Date().addingTimeInterval(10 * 60) { return "That’s too soon (or already passed) today. Pick a later time, or Tomorrow." }
        }
        arrive = a; arriveOptions = []; arriveError = nil; arriveUpdated = nil; arrivePick = 0
        UserDefaults.standard.set(try? JSONEncoder().encode(a), forKey: "arrivePlan")
        Task { await refreshArrive(force: true) }
        return nil
    }

    func clearArrive() {
        arrive = nil; arriveOptions = []; arriveError = nil; arriveUpdated = nil; arrivePick = 0
        UserDefaults.standard.removeObject(forKey: "arrivePlan")
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["arrive-leave"])
    }

    /// Every two minutes while the home screen is on: the trips that get you there by the time, from your Veghel stops
    /// (or from BUas going home), with live times.
    func refreshArrive(force: Bool = false) async {
        guard let a = arrive, let T = a.when else { return }
        if a.done { clearArrive(); return }
        guard !arriveBusy, force || arriveUpdated.map({ Date().timeIntervalSince($0) >= 120 }) ?? true else { return }
        arriveBusy = true
        defer { arriveBusy = false }
        let from: Place = a.out ? StopsStore.shared.homePlace : .school
        let to: Place = a.out ? .school : .home
        if a.leaving {
            // head off at a time: the ones that leave then or after, the one that gets you there first (and safely, and
            // with the least standing outside) on top
            let all = await Transit.plan(from: from, to: to, modes: nil, at: T.addingTimeInterval(-60), count: 6, maxTransfers: 4)
            guard arrive == a else { return }
            var seen = Set<String>()
            let after = all.filter { $0.start >= T.addingTimeInterval(-60) && $0.first.departure > Date().addingTimeInterval(-60) && seen.insert($0.id).inserted }
                .sorted(by: GoStore.sooner)
            arriveUpdated = Date()
            if after.isEmpty {
                arriveError = all.isEmpty ? "No trips found for that time yet. It tries again in a couple of minutes."
                                          : "Nothing leaves \(a.out ? RoleWords.current.homeStops : RoleWords.current.school) after \(a.time)."
                if !all.isEmpty { arriveOptions = [] }
                return
            }
            let old = arriveChosen?.first.tripId
            arriveOptions = Array(after.prefix(4))
            arrivePick = arriveOptions.firstIndex { $0.first.tripId == old } ?? 0
            arriveError = nil
            remind()
            return
        }
        let all = await Transit.plan(from: from, to: to, modes: nil, at: T, count: 6, maxTransfers: 4, arriveBy: true)
        guard arrive == a else { return }
        var seen = Set<String>()
        let inTime = all.filter { $0.end <= T.addingTimeInterval(60) && $0.first.departure > Date().addingTimeInterval(-60) && seen.insert($0.id).inserted }
        // the best: leave as late as you can and still be there in time; then the fewest changes
        let best = inTime.sorted { ($0.start, -$0.rides.count) > ($1.start, -$1.rides.count) }
        arriveUpdated = Date()
        if best.isEmpty {
            arriveError = all.isEmpty ? "No trips found for that time yet. It tries again in a couple of minutes."
                                      : "Nothing gets you there by \(a.time). The earliest arrives \(Fmt.hhmm(all.map(\.end).min() ?? T))."
            if !all.isEmpty { arriveOptions = [] }
            return
        }
        let old = arriveChosen?.first.tripId
        var top = Array(best.prefix(4))
        // (0.27) a friend's trip: the way with their ride stays among the options, and is the pick to start with
        var preferred: Int?
        if let p = a.prefer, !p.isEmpty {
            let want = Set(p)
            if let f = best.first(where: { t in t.rides.contains { want.contains($0.tripId) } }), !top.contains(f) { top[top.count - 1] = f }
            preferred = top.firstIndex { t in t.rides.contains { want.contains($0.tripId) } }
        }
        arriveOptions = top
        arrivePick = arriveOptions.firstIndex { $0.first.tripId == old } ?? preferred ?? 0
        arriveError = nil
        remind()
    }

    /// A reminder ten minutes before you have to leave.
    private func remind() {
        let c = UNUserNotificationCenter.current()
        c.removePendingNotificationRequests(withIdentifiers: ["arrive-leave"])
        guard let a = arrive, let t = arriveChosen else { return }
        let at = t.start.addingTimeInterval(-10 * 60)
        guard at > Date().addingTimeInterval(30) else { return }
        let f = t.first
        let n = UNMutableNotificationContent()
        n.title = "Leave in 10 min"
        n.body = "\(f.isTrain ? f.name : "Bus \(f.line)") at \(Fmt.hhmm(f.departure)) from \(Fmt.place(f.fromStop)) · \(a.out ? RoleWords.current.school : "home") "
            + (a.leaving ? "at \(Fmt.hhmm(t.end))" : "by \(a.time)")
        n.sound = .default
        n.interruptionLevel = .timeSensitive
        n.userInfo = ["kind": "go"]
        c.add(UNNotificationRequest(identifier: "arrive-leave", content: n, trigger: UNTimeIntervalNotificationTrigger(timeInterval: at.timeIntervalSinceNow, repeats: false))) { _ in }
    }

    var chosen: PlanOption? { options[safe: pick] ?? options.first }

    /// Saves a new plan. Returns a message if the time doesn't work.
    func set(out: Bool, time: Date, tomorrow: Bool) -> String? {
        let day = Calendar.current.date(byAdding: .day, value: tomorrow ? 1 : 0, to: Date())!
        let t = PlannedTrip(out: out, date: Fmt.ymd.string(from: day), time: Fmt.hhmm(time))
        if t.expired { return "That time has already passed today. Pick Tomorrow." }
        WatchStore.shared.removeAuto()
        trip = t; options = []; error = nil; updated = nil; pick = 0
        UserDefaults.standard.set(try? JSONEncoder().encode(t), forKey: "plannedTrip")
        Task { await refresh(force: true) }
        return nil
    }

    func clear() {
        trip = nil; options = []; error = nil; updated = nil; pick = 0
        UserDefaults.standard.removeObject(forKey: "plannedTrip")
        WatchStore.shared.removeAuto()
    }

    /// Every minute while the home screen is on.
    func refresh(force: Bool = false) async {
        await refreshArrive(force: force)
        guard let t = trip else { return }
        if t.expired { clear(); return }
        guard !busy, force || updated.map({ Date().timeIntervalSince($0) >= 60 }) ?? true, let T = t.when else { return }
        busy = true
        defer { busy = false }
        let out = t.out
        // On the corridor its two hubs and Breda; off it the stations nearest Home and School (0.24)
        let hubs: [Place], far: Place
        if RoleSnapshot.corridor != nil {
            hubs = [Place.eindhoven, Place.denBosch]; far = .breda
        } else if let s = TrainTime.stations {
            hubs = [s.home]; far = s.school
        } else {
            error = "There’s no train station near both your home and \(RoleWords.current.school)."
            options = []; updated = Date()
            return
        }
        // Both stations at once; the answers keep the station order.
        let planJobs: [@Sendable () async -> [(DoorTrip, Place, Place)]] = hubs.map { st in
            { @Sendable in
                if out {
                    return await Transit.plan(from: st, to: far, modes: "RAIL", at: T.addingTimeInterval(-80 * 60), count: 8, maxTransfers: 1).map { ($0, st, far) }
                } else {
                    return await Transit.plan(from: far, to: st, modes: "RAIL", at: T.addingTimeInterval(-10 * 60), count: 6, maxTransfers: 1).map { ($0, far, st) }
                }
            }
        }
        var trains: [(DoorTrip, Place, Place)] = await Progressive.all(planJobs).flatMap { $0 }
        guard trip == t else { return }
        guard !trains.isEmpty else {
            error = "Couldn’t plan this trip because no trains were found for that time. It tries again in a minute."
            updated = Date()
            return
        }
        // Your friend's train: the one that arrives (or leaves) closest to the time, fewest changes first.
        func ref(_ o: DoorTrip) -> Date { out ? o.last.scheduledArrival : o.first.scheduledDeparture }
        trains.sort { a, b in
            let x = abs(ref(a.0).timeIntervalSince(T)), y = abs(ref(b.0).timeIntervalSince(T))
            return x != y ? x < y : a.0.rides.count < b.0.rides.count
        }
        let exact = trains.filter { abs(ref($0.0).timeIntervalSince(T)) <= 60 }
        let picked = Array((exact.isEmpty ? Array(trains.prefix(1)) : exact).prefix(3))
        // The buses of every picked train at once; the options keep the picked order.
        let busJobs: [@Sendable () async -> (DoorTrip?, DoorTrip?, DoorTrip?, DoorTrip?)] = picked.map { p in
            { @Sendable in await self.buses(for: p.0, station: out ? p.1 : p.2, far: far, out: out) }
        }
        let found = await Progressive.all(busJobs)
        let opts: [PlanOption] = zip(picked, found).map { p, b in
            PlanOption(train: p.0, from: p.1, to: p.2, busIn: b.0, busInAlt: b.1, busOut: b.2, busOutAlt: b.3, station: out ? p.1 : p.2)
        }
        guard trip == t else { return }
        for o in opts { Ratings.shared.learn(o.from, o.to, [o.train]) }
        options = opts
        inexact = exact.isEmpty
        holdWatch = true
        if pick >= opts.count { pick = 0 }
        holdWatch = false
        error = nil
        updated = Date()
        // The platform, crowding and size come in after the options are on screen; the watch starts from NS's answer.
        let rows = opts.map { ($0.train, $0.from, $0.to) }
        Task {
            await NSStore.shared.enrich(rows)
            guard self.trip == t else { return }
            self.watchChosen()
        }
    }

    /// The latest bus that still makes the train (2 min spare; after a slow bus, a B 4 and a C 6), and the first one after it.
    /// `far`: the station on the school's side (Breda on the corridor). Off it the ride to and from the stations may be
    /// a tram or a metro too.
    private func buses(for train: DoorTrip, station: Place, far: Place, out: Bool) async -> (DoorTrip?, DoorTrip?, DoorTrip?, DoorTrip?) {
        let dep = train.first.departure, arr = train.last.arrival
        let before: [DoorTrip], after: [DoorTrip]
        let modes = RoleSnapshot.corridor != nil ? "BUS" : "BUS,TRAM,SUBWAY,FERRY"
        if out {
            async let b = Transit.plan(from: .home, to: station, modes: modes, at: dep.addingTimeInterval(-90 * 60), count: 8, maxTransfers: 0)
            async let a = Transit.plan(from: far, to: .school, modes: modes, at: arr, count: 4, maxTransfers: 0)
            let (x, y) = await (b, a)
            before = x; after = y
            Ratings.shared.learn(.home, station, before)
        } else {
            async let b = Transit.plan(from: .school, to: far, modes: modes, at: dep.addingTimeInterval(-60 * 60), count: 8, maxTransfers: 0)
            async let a = Transit.plan(from: station, to: .home, modes: modes, at: arr, count: 3, maxTransfers: 0)
            let (x, y) = await (b, a)
            before = x; after = y
            Ratings.shared.learn(station, .home, after)
        }
        // The same bus can come up from both Veghel stops. Keep it once, from the stop with the least walking.
        func once(_ l: [DoorTrip]) -> [DoorTrip] {
            var seen = Set<String>()
            return l.sorted { $0.first.walkBefore < $1.first.walkBefore }.filter { seen.insert($0.first.tripId).inserted }
        }
        let inn = ChangeRoom.inTime(once(before), trainLeaves: dep, end: { $0.end }, departure: { $0.first.departure },
                                    grade: { Risk.feederGrade($0.first) })
        let nxt = once(after).filter { $0.start >= arr.addingTimeInterval(-60) }.sorted { a, b in
            let x = out ? a.end : a.last.arrival, y = out ? b.end : b.last.arrival
            return x != y ? x < y : a.first.departure < b.first.departure
        }
        return (inn[safe: 0], inn[safe: 1], nxt[safe: 0], nxt[safe: 1])
    }

    /// The train of the plan you picked is watched for platform changes by itself.
    private func watchChosen() {
        guard let c = chosen, let code = NSStore.code(c.from) else { return }
        let k = WatchStore.key(code: code, ride: c.train.first)
        let w = WatchStore.shared
        if w.watches.contains(where: { $0.auto && $0.key == k }) { return }     // already watching it: keep what it knows
        w.removeAuto()
        if c.train.first.scheduledDeparture > Date().addingTimeInterval(-600) { w.add(c.train, from: c.from, to: c.to, auto: true) }
    }
}
