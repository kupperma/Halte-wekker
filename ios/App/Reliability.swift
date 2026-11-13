import Foundation

/// How late buses and trains get to the stops where you change, learned from your own rides: per line, stop, hour of the
/// day and weekday or weekend. (Transitous forgets a trip's live times once it's over, so the app keeps its own.)
@MainActor
final class DelayBook {
    static let shared = DelayBook()
    private var book: [String: [Double]]
    private let storeKey = "delayBook"

    private init() {
        book = (UserDefaults.standard.data(forKey: storeKey).flatMap { try? JSONDecoder().decode([String: [Double]].self, from: $0) }) ?? [:]
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
        if book.count > 400 { book = Dictionary(uniqueKeysWithValues: book.sorted { $0.value.count > $1.value.count }.prefix(300).map { ($0.key, $0.value) }) }
        UserDefaults.standard.set(try? JSONEncoder().encode(book), forKey: storeKey)
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

    func clear() { book = [:]; UserDefaults.standard.removeObject(forKey: storeKey) }
}

/// What a change costs you when it goes wrong: how likely you'd miss it (the ride before it a bit late, and too little
/// time to change), and how long you'd wait for the next one then. Missing one train often means 20 to 30 minutes.
@MainActor
enum Risk {
    /// How likely you'd miss change `i` of `t` (getting from ride i-1 onto ride i).
    static func miss(_ t: DoorTrip, at i: Int, now: Date = Date()) -> Double {
        guard i > 0, i < t.rides.count else { return 0 }
        let r = t.rides[i - 1], n = t.rides[i]
        let slack = n.departure.timeIntervalSince(r.arrival) / 60 - Double(n.walkBefore)
        if slack < 0 { return 0.95 }
        // its live times already have the delay it has now; what's left is how much later it could still get
        let already = r.live ? r.arrival.timeIntervalSince(r.scheduledArrival) / 60 : 0
        let soon = r.live && r.arrival.timeIntervalSince(now) < 10 * 60
        let learned = DelayBook.shared.delays(line: r.line, stop: r.toStop, at: r.scheduledArrival)
        if learned.count >= 4 && !soon {
            let late = learned.filter { $0 > already + slack + 0.5 }.count
            return min(0.95, (Double(late) + 0.5) / (Double(learned.count) + 1))
        }
        // Not known yet: a bus is a few minutes late quite often, a train much less, and one about to arrive hardly
        // changes any more. (The planner's walk across already has a minute or so of room in it.)
        let typical = soon ? 0.8 : r.isTrain ? 1.0 : 2.5
        return min(0.95, exp(-(slack + 1) / typical))
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

    /// Below this many minutes of likely cost, a trip's changes are safe enough.
    static let safe = 3.5

    /// When you'd likely be there, in minutes: the arrival, plus what a missed change would likely cost.
    static func score(_ t: DoorTrip, now: Date = Date()) -> Double {
        t.end.timeIntervalSince1970 / 60 + penalty(t, now: now)
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
