import Foundation
import UserNotifications

/// The train you take with your friend: arrive in Breda at (or leave Breda at) a time, today or tomorrow.
struct PlannedTrip: Codable, Equatable {
    var out: Bool               // true: to Breda, false: home
    var date: String            // yyyy-MM-dd
    var time: String            // HH:mm
    var leave: Bool? = nil      // a "leave at" plan: `time` is when you head off (else when you want to be there)

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
    var station: Place { from == .breda ? to : from }
    var tripIds: [String] { [train, busIn, busOut].compactMap { $0?.first.tripId } }
}

@MainActor
final class Planner: ObservableObject {
    @Published private(set) var trip: PlannedTrip?
    @Published private(set) var options: [PlanOption] = []
    @Published private(set) var inexact = false
    @Published private(set) var error: String?
    @Published private(set) var updated: Date?
    @Published private(set) var busy = false
    @Published var pick = 0 { didSet { watchChosen() } }

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
    func setArrive(out: Bool, time: Date, tomorrow: Bool, leave: Bool = false) -> String? {
        let day = Calendar.current.date(byAdding: .day, value: tomorrow ? 1 : 0, to: Date())!
        let a = PlannedTrip(out: out, date: Fmt.ymd.string(from: day), time: Fmt.hhmm(time), leave: leave ? true : nil)
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
        let from: Place = a.out ? StopsStore.shared.veghel : .buas
        let to: Place = a.out ? .buas : .veghel
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
                                          : "Nothing leaves \(a.out ? "your Veghel stops" : "BUas") after \(a.time)."
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
        arriveOptions = Array(best.prefix(4))
        arrivePick = arriveOptions.firstIndex { $0.first.tripId == old } ?? 0
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
        n.body = "\(f.isTrain ? f.name : "Bus \(f.line)") at \(Fmt.hhmm(f.departure)) from \(Fmt.place(f.fromStop)) · \(a.out ? "BUas" : "home") "
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
        var trains: [(DoorTrip, Place, Place)] = []
        for st in [Place.eindhoven, Place.denBosch] {
            if out {
                trains += await Transit.plan(from: st, to: .breda, modes: "RAIL", at: T.addingTimeInterval(-80 * 60), count: 8, maxTransfers: 1).map { ($0, st, Place.breda) }
            } else {
                trains += await Transit.plan(from: .breda, to: st, modes: "RAIL", at: T.addingTimeInterval(-10 * 60), count: 6, maxTransfers: 1).map { ($0, Place.breda, st) }
            }
        }
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
        var opts: [PlanOption] = []
        for p in picked {
            let b = await buses(for: p.0, station: out ? p.1 : p.2, out: out)
            opts.append(PlanOption(train: p.0, from: p.1, to: p.2, busIn: b.0, busInAlt: b.1, busOut: b.2, busOutAlt: b.3))
        }
        guard trip == t else { return }
        for o in opts { Ratings.shared.learn(o.from, o.to, [o.train]) }
        await NSStore.shared.enrich(opts.map { ($0.train, $0.from, $0.to) })
        guard trip == t else { return }
        options = opts
        inexact = exact.isEmpty
        if pick >= opts.count { pick = 0 }
        error = nil
        updated = Date()
        watchChosen()
    }

    /// The latest bus that still makes the train (2 min spare), and the first one after it.
    private func buses(for train: DoorTrip, station: Place, out: Bool) async -> (DoorTrip?, DoorTrip?, DoorTrip?, DoorTrip?) {
        let dep = train.first.departure, arr = train.last.arrival
        var before: [DoorTrip], after: [DoorTrip]
        if out {
            before = await Transit.plan(from: .veghel, to: station, modes: "BUS", at: dep.addingTimeInterval(-90 * 60), count: 8, maxTransfers: 0)
            after = await Transit.plan(from: .breda, to: .buas, modes: "BUS", at: arr, count: 4, maxTransfers: 0)
            Ratings.shared.learn(.veghel, station, before)
        } else {
            before = await Transit.plan(from: .buas, to: .breda, modes: "BUS", at: dep.addingTimeInterval(-60 * 60), count: 8, maxTransfers: 0)
            after = await Transit.plan(from: station, to: .veghel, modes: "BUS", at: arr, count: 3, maxTransfers: 0)
            Ratings.shared.learn(station, .veghel, after)
        }
        // The same bus can come up from both Veghel stops. Keep it once, from the stop with the least walking.
        func once(_ l: [DoorTrip]) -> [DoorTrip] {
            var seen = Set<String>()
            return l.sorted { $0.first.walkBefore < $1.first.walkBefore }.filter { seen.insert($0.first.tripId).inserted }
        }
        let inn = once(before).filter { $0.end <= dep.addingTimeInterval(-120) }.sorted { $0.first.departure > $1.first.departure }
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
