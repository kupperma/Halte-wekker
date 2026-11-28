import Foundation

/// How late buses and trains get to the stops where you change, learned from your own rides: per line, stop, hour of the
/// day and weekday or weekend. (Transitous forgets a trip's live times once it's over, so the app keeps its own.)
@MainActor
final class DelayBook {
    static let shared = DelayBook()
    private var book: [String: [Double]]
    private let storeKey = "delayBook"
    private var saveDue = false
    /// Written off the main thread, one at a time, in order.
    private let io = DispatchQueue(label: "nl.haltewekker.delaybook", qos: .utility)

    /// (0.42.15) Your rides at a stop with the minute they were due there (`NearbySlot.Entry`), per line and stop:
    /// how sure a way is counts only the rides around its own time. Filled once from the hour buckets above.
    private var slots: [String: [NearbySlot.Entry]]
    private let slotsKey = "delayBook.slots"

    private init() {
        let b: [String: [Double]] = (UserDefaults.standard.data(forKey: storeKey).flatMap { try? JSONDecoder().decode([String: [Double]].self, from: $0) }) ?? [:]
        book = b
        if let d = UserDefaults.standard.data(forKey: slotsKey), let s = try? JSONDecoder().decode([String: [NearbySlot.Entry]].self, from: d) {
            slots = s
        } else {
            slots = Self.slotsFrom(b)
        }
    }

    /// The hour buckets as rides at half past that hour (what was kept before 0.42.15; your own rides only).
    private static func slotsFrom(_ b: [String: [Double]]) -> [String: [NearbySlot.Entry]] {
        var out: [String: [NearbySlot.Entry]] = [:]
        // (0.42.16) in key order: a Dictionary's own order changes from run to run, and "your last 20" must not
        for k in b.keys.sorted() {
            let list: [Double] = b[k] ?? []
            let p = k.split(separator: "|", omittingEmptySubsequences: false)
            guard p.count == 3, p[1] != "*" else { continue }
            let slot = String(p[2])
            let weekend = slot.hasPrefix("we")
            guard let h = Int(slot.dropFirst(2)) else { continue }
            let base = "\(p[0])|\(p[1])"
            out[base, default: []] += list.map { NearbySlot.Entry(minute: h * 60 + 30, weekend: weekend, delay: $0) }
        }
        return out
    }

    private static func base(_ line: String, _ stop: String) -> String { "\(line)|\(Fmt.place(stop))" }
    private static func slot(_ at: Date) -> String {
        let c = Calendar.current
        let weekend = c.isDateInWeekend(at)
        return "\(weekend ? "we" : "wd")\(c.component(.hour, from: at))"
    }

    /// It got to `stop` `delay` minutes after its timetable said (`scheduled`).
    func record(line: String, stop: String, scheduled: Date, delay: Double) {
        guard !line.isEmpty, !stop.isEmpty, delay > -10, delay < 90 else { return }
        let k = Self.base(line, stop) + "|" + Self.slot(scheduled)
        var list = book[k] ?? []
        list.append((delay * 10).rounded() / 10)
        book[k] = Array(list.suffix(30))
        if stop != "*" {
            let b = Self.base(line, stop)
            let c = Calendar.current
            let e = NearbySlot.Entry(minute: NearbySlot.minute(scheduled, calendar: c), weekend: c.isDateInWeekend(scheduled),
                                     delay: (delay * 10).rounded() / 10)
            slots[b] = Array(((slots[b] ?? []) + [e]).suffix(80))
            if slots.count > 300 { slots = Dictionary(uniqueKeysWithValues: slots.sorted { $0.value.count > $1.value.count }.prefix(250).map { ($0.key, $0.value) }) }
        }
        if book.count > 400 { book = Dictionary(uniqueKeysWithValues: book.sorted { $0.value.count > $1.value.count }.prefix(300).map { ($0.key, $0.value) }) }
        saveSoon()
    }

    /// Saved at most every 30 s (a burst of boards books many trips at once), and when the app goes to the background.
    /// (A crash loses at most the last half minute of delays.)
    private func saveSoon() {
        guard !saveDue else { return }
        saveDue = true
        Task {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            self.save()
        }
    }

    /// Now, if anything is waiting to be saved.
    func save() {
        guard saveDue else { return }
        saveDue = false
        let snapshot = book, key = storeKey
        let slotSnapshot = slots, slotKey = slotsKey
        io.async {
            UserDefaults.standard.set(try? JSONEncoder().encode(snapshot), forKey: key)
            UserDefaults.standard.set(try? JSONEncoder().encode(slotSnapshot), forKey: slotKey)
        }
    }

    /// (0.42.15) Your rides on `line` to `stop` around the time it's due there (`NearbySlot.pick`: within an hour
    /// either side, else 90 or 120 minutes; weekdays and weekends apart), and the window used.
    func slotDelays(line: String, stop: String, at: Date) -> (delays: [Double], window: Int) {
        let c = Calendar.current
        return NearbySlot.pick(slots[Self.base(line, stop)] ?? [], minute: NearbySlot.minute(at, calendar: c), weekend: c.isDateInWeekend(at))
    }

    /// What it's been like around that time: that hour, else the hours either side, else any time.
    func delays(line: String, stop: String, at: Date) -> [Double] {
        let b = Self.base(line, stop)
        let exact = book[b + "|" + Self.slot(at)] ?? []
        if exact.count >= 4 { return exact }
        let near = [-1, 1].flatMap { book[b + "|" + Self.slot(at.addingTimeInterval(Double($0) * 3600))] ?? [] }
        if exact.count + near.count >= 4 { return exact + near }
        let all = book.filter { $0.key.hasPrefix(b + "|") }.flatMap(\.value)
        return all.count >= 4 ? all : exact + near
    }

    /// "late on 3 of your last 5 rides around this time", when it knows enough.
    func story(line: String, stop: String, at: Date, slack: Double) -> String? {
        let d = delays(line: line, stop: stop, at: at)
        guard d.count >= 4 else { return nil }
        let late = d.suffix(10).filter { $0 > slack }.count
        return "more than \(Int(slack.rounded())) min late \(late) of the last \(min(10, d.count)) times"
    }

    /// A line seen leaving a stop `delay` minutes late (on a board, or in a plan): what that line is like at that hour,
    /// anywhere. Once per trip.
    func recordLine(line: String, scheduled: Date, delay: Double) {
        record(line: line, stop: "*", scheduled: scheduled, delay: delay)
    }

    /// What a line has been like around that time: at that stop when it knows (your own rides), and anywhere it was seen.
    func lineDelays(line: String, stop: String?, at: Date) -> [Double] {
        let own = stop.map { delays(line: line, stop: $0, at: at) } ?? []
        let b = Self.base(line, "*")
        var seen = book[b + "|" + Self.slot(at)] ?? []
        if seen.count < 6 { seen += [-1, 1].flatMap { book[b + "|" + Self.slot(at.addingTimeInterval(Double($0) * 3600))] ?? [] } }
        return own + seen
    }

    /// Every line it has seen anywhere.
    var lines: [String] {
        Array(Set(book.keys.compactMap { k -> String? in
            let p = k.split(separator: "|")
            return p.count == 3 && p[1] == "*" ? String(p[0]) : nil
        })).sorted()
    }

    /// How many times it has seen this line around this hour.
    func count(line: String, at: Date) -> Int { lineDelays(line: line, stop: nil, at: at).count }

    func clear() {
        book = [:]; slots = [:]; saveDue = false
        let key = storeKey, slotKey = slotsKey
        io.async { UserDefaults.standard.removeObject(forKey: key); UserDefaults.standard.set(try? JSONEncoder().encode([String: [NearbySlot.Entry]]()), forKey: slotKey) }       // (after any save already on its way)
    }
}

/// How late each line is running right now: every live time the app sees (the boards, the plans), the latest per trip,
/// for the last half hour. And, once per trip, into the book for that hour (when it's about to leave, its delay is about
/// what it really is).
@MainActor
final class LiveDelays: ObservableObject {
    static let shared = LiveDelays()
    struct Seen { let line: String; let train: Bool; let delay: Double; let at: Date }
    @Published private(set) var seen: [String: Seen] = [:]           // trip id → the latest
    private var booked: Set<String> = []
    private var bookedDay = ""

    nonisolated static func name(_ line: String, train: Bool) -> String { train ? Transit.trainLabel(line) : line }

    private struct Sighting { let trip: String; let line: String; let train: Bool; let time: Date; let scheduled: Date }

    func note(trip: String, line: String, train: Bool, time: Date, scheduled: Date) {
        noteAll([Sighting(trip: trip, line: line, train: train, time: time, scheduled: scheduled)])
    }

    func note(_ list: [BoardDeparture]) {
        noteAll(list.filter { $0.live && !$0.cancelled }.map { Sighting(trip: $0.tripId, line: $0.line, train: $0.train, time: $0.time, scheduled: $0.scheduled) })
    }

    func note(_ trips: [DoorTrip]) {
        var all: [Sighting] = []
        for t in trips {
            for r in t.rides where r.live && !r.cancelled && r.fromId != "onboard" {
                all.append(Sighting(trip: r.tripId, line: r.line, train: r.isTrain, time: r.departure, scheduled: r.scheduledDeparture))
            }
        }
        noteAll(all)
    }

    /// A whole board (or plan) at once: the list changes once, not once per departure (each change copied the whole
    /// list and redrew what shows it), and the day's name is worked out once.
    private func noteAll(_ items: [Sighting]) {
        guard !items.isEmpty else { return }
        let now = Date()
        // into the book once per trip a day, when it's leaving about now
        let day = Fmt.ymd.string(from: now)
        if day != bookedDay { bookedDay = day; booked = [] }
        var s = seen
        var changed = false
        for i in items {
            guard !i.trip.isEmpty, !i.line.isEmpty, i.line != "?" else { continue }
            let name = Self.name(i.line, train: i.train)
            let delay = i.time.timeIntervalSince(i.scheduled) / 60
            guard delay > -10, delay < 90 else { continue }
            s[i.trip] = Seen(line: name, train: i.train, delay: delay, at: now)
            changed = true
            if s.count > 600 { s = s.filter { now.timeIntervalSince($0.value.at) < 1800 } }
            if abs(i.time.timeIntervalSince(now)) < 150, booked.insert(i.trip).inserted {
                DelayBook.shared.recordLine(line: name, scheduled: i.scheduled, delay: delay)
            }
        }
        if changed { seen = s }
    }

    /// How late `line` is running now: each live trip seen in the last half hour.
    func now(line: String) -> [Double] {
        let t = Date()
        return seen.values.filter { $0.line == line && t.timeIntervalSince($0.at) < 1800 }.map(\.delay)
    }

    /// Every line seen live in the last half hour.
    var lines: [(line: String, train: Bool)] {
        let t = Date()
        var out: [String: Bool] = [:]
        for s in seen.values where t.timeIntervalSince(s.at) < 1800 { out[s.line] = s.train }
        return out.map { ($0.key, $0.value) }
    }
}

/// How steady a line is at a time of day: S always on time, A mostly, B often a few minutes late, C late a lot. From
/// the time of day (rush hour is when buses run late), what the app has seen of that line at that hour, and how it's
/// running right now.
@MainActor
enum Steady {
    /// What part of the day it is, and how late buses and trains typically get then (minutes, before anything's known).
    static func period(_ at: Date) -> (name: String, bus: Double, train: Double) {
        // (0.42.15) the table is `NearbySlot.period` (tested): rush hours 07–09 and 16–19, the evening after still busy
        let c = Calendar.current
        let h = Double(c.component(.hour, from: at)) + Double(c.component(.minute, from: at)) / 60
        let p: NearbySlot.Period = NearbySlot.period(hour: h, weekend: c.isDateInWeekend(at))
        return (p.name, p.bus, p.train)
    }

    /// How late it typically gets, in minutes: the chance it's more than x minutes late is about e^(−x / this).
    static func scale(line: String, train: Bool, stop: String? = nil, at: Date) -> Double {
        let key = "\(line)|\(train)|\(stop ?? "")|\(Int(at.timeIntervalSince1970 / 1800))"
        if let c = cache[key], Date().timeIntervalSince(c.at) < 60 { return c.value }
        let p = period(at)
        var s = train ? p.train : p.bus
        // what it's been like at this hour: your rides, and what the app saw on the boards
        let hist = DelayBook.shared.lineDelays(line: line, stop: stop, at: at)
        if hist.count >= 3 {
            let w = Double(hist.count) / Double(hist.count + 6)
            s = w * fit(hist) + (1 - w) * s
        }
        // and right now, for a ride within the hour: how late they're running
        if abs(at.timeIntervalSinceNow) < 3600 {
            let live = LiveDelays.shared.now(line: line)
            if live.count >= 2 { s = 0.5 * s + 0.5 * fit(live) }
        }
        let v = max(0.5, s)
        cache[key] = (v, Date())
        if cache.count > 500 { cache = [:] }
        return v
    }
    private static var cache: [String: (value: Double, at: Date)] = [:]

    /// The typical lateness of a set of delays (early counts as on time).
    static func fit(_ d: [Double]) -> Double { d.isEmpty ? 0 : max(0.5, d.map { max(0, $0) }.reduce(0, +) / Double(d.count)) }

    /// The chance it's more than `m` minutes late.
    static func late(line: String, train: Bool, stop: String? = nil, at: Date, by m: Double = 3) -> Double {
        exp(-m / scale(line: line, train: train, stop: stop, at: at))
    }

    /// S to C, by the chance it's more than 3 minutes late: under 10%, 25%, 45%, or more.
    static func rank(line: String, train: Bool, stop: String? = nil, at: Date = Date()) -> String {
        rank(late(line: line, train: train, stop: stop, at: at))
    }
    static func rank(_ p: Double) -> String { p < 0.10 ? "S" : p < 0.25 ? "A" : p < 0.45 ? "B" : "C" }

    /// The time to leave for a change after it, to make it 9 times out of 10 (the planner's walk has a minute of room).
    static func room(line: String, train: Bool, stop: String? = nil, at: Date) -> Int {
        max(1, Int((scale(line: line, train: train, stop: stop, at: at) * log(10.0) - 1).rounded(.up)))
    }

    static func meaning(_ g: String) -> String {
        switch g {
        case "S": return "Nearly always on time"
        case "A": return "Mostly on time"
        case "B": return "Often a few minutes late"
        default: return "Late a lot"
        }
    }
}

/// What a change costs you when it goes wrong: how likely you'd miss it (the ride before it a bit late, and too little
/// time to change), and how long you'd wait for the next one then. Missing one train often means 20 to 30 minutes.
@MainActor
enum Risk {
    /// How likely you'd miss change `i` of `t` (getting from ride i-1 onto ride i).
    static func miss(_ t: DoorTrip, at i: Int, now: Date = Date()) -> Double {
        guard i > 0, i < t.rides.count else { return 0 }
        let r = t.rides[i - 1], n = t.rides[i]
        // (0.34) the planner's walk is at your own walking speed once it's learned (`Transit.plan`); the room a change
        // needs, your own change time when that's more (`HabitStore.changeNeed`)
        let slack = n.departure.timeIntervalSince(r.arrival) / 60 - HabitStore.shared.changeNeed(walk: n.walkBefore)
        if slack < 0 { return 0.95 }
        // its live times already have the delay it has now; what's left is how much later it could still get
        let already = r.live ? r.arrival.timeIntervalSince(r.scheduledArrival) / 60 : 0
        let soon = r.live && r.arrival.timeIntervalSince(now) < 10 * 60
        // How late that line gets at that time of day (rush hour is worse), from what's been seen and how it runs now;
        // one about to arrive hardly changes any more. (The planner's walk across already has a minute or so of room.)
        let typical = soon ? 0.8 : Steady.scale(line: r.line, train: r.isTrain, stop: r.toStop, at: r.scheduledArrival)
        // your own rides to that stop, once there are a few
        let learned = DelayBook.shared.delays(line: r.line, stop: r.toStop, at: r.scheduledArrival)
        // a slow bus before it (its speed rank B or C) needs more room: that much less of the slack counts
        let model = ChangeRoom.missChance(slack: slack, typical: typical, already: already, soon: soon, learned: learned,
                                          extra: ChangeRoom.feederExtra(isTrain: r.isTrain, grade: feederGrade(r)))
        // (0.34) how this change went for you on other days, at this time of day (`ChangeOdds`)
        let mine = HabitStore.shared.tally(from: r.line, to: n.line, at: n.fromStop, time: n.departure)
        return ChangeOdds.missChance(model: model, made: mine.made, days: mine.days)
    }

    /// The speed rank of a bus you'd change from (only read): a slow one needs more room. Trains: none (a Sprinter is
    /// slower than an Intercity by its timetable, not late).
    static func feederGrade(_ r: Ride) -> String? { r.isTrain ? nil : r.speedGrade }

    /// "N min to change" after `r`: red under the room it needs, and why when it's the slow bus (`ChangeRoom.changeNote`).
    static func changeNote(after r: Ride, minutes: Int, walk: Int) -> (red: Bool, why: String?) {
        ChangeRoom.changeNote(minutes: minutes, walk: walk, isTrain: r.isTrain, grade: feederGrade(r))
    }

    /// Minutes it's likely to cost: each change's chance of missing it times the wait for the next one after it.
    static func penalty(_ t: DoorTrip, now: Date = Date()) -> Double {
        var p = 0.0
        for i in t.rides.indices.dropFirst() {
            // the wait for the next one: a train often 20 to 30 min, a bus into town (the last ride) a few
            p += miss(t, at: i, now: now) * after(t, i)
        }
        return p
    }

    /// The wait for the next one if you miss change `i`: a train often 20 to 30 min, a bus into town (the last ride) a few.
    static func after(_ t: DoorTrip, _ i: Int) -> Double { t.rides[i].isTrain ? 20 : i == t.rides.count - 1 ? 6 : 12 }

    /// (0.34) Your own history of one of the trip's changes, once there are 3 days of it: "At Tilburg: this change worked
    /// on 9 of 10 days" (the change with the most days; nil: none yet).
    static func history(_ t: DoorTrip) -> String? {
        var best: (days: Int, text: String)?
        for i in t.rides.indices.dropFirst() {
            let a = t.rides[i - 1], n = t.rides[i]
            let mine = HabitStore.shared.tally(from: a.line, to: n.line, at: n.fromStop, time: n.departure)
            guard let w = ChangeOdds.words(made: mine.made, days: mine.days), mine.days > (best?.days ?? 0) else { continue }
            let cap: String = w.prefix(1).uppercased() + String(w.dropFirst())
            let text: String = t.rides.count > 2 ? "At \(Fmt.place(n.fromStop)): \(w)" : cap
            best = (mine.days, text)
        }
        return best?.text
    }

    /// Below this many minutes of likely cost, a trip's changes are safe enough.
    static let safe = 3.5

    /// When you'd likely be there, in minutes: the arrival, plus what a missed change would likely cost.
    /// (0.34) A plan from a stop you get on at more often than the planner has you: a little sooner (`Habits.bonus`).
    static func score(_ t: DoorTrip, now: Date = Date()) -> Double {
        t.end.timeIntervalSince1970 / 60 + penalty(t, now: now) - HabitStore.shared.bonus(t)
    }

    /// The change most likely to cost you, if it's a real worry (missing it would likely cost 2.5 minutes or more: a train
    /// you could well miss, not a city bus that comes again in a few).
    static func weakest(_ t: DoorTrip, now: Date = Date()) -> (index: Int, chance: Double, slack: Double)? {
        let c = t.rides.indices.dropFirst().map { ($0, miss(t, at: $0, now: now)) }.max { $0.1 * after(t, $0.0) < $1.1 * after(t, $1.0) }
        guard let c, c.1 * after(t, c.0) >= 2.5 else { return nil }
        let (i, p) = c
        let slack = t.rides[i].departure.timeIntervalSince(t.rides[i - 1].arrival) / 60 - Double(t.rides[i].walkBefore)
        return (i, p, slack)
    }
}
