import Foundation

/// The "Next trip first" home (0.19.1, concept B): which trip its big card shows, the countdown on it, its leg bar and
/// the week strip. Plain values (no SwiftUI, no stores), so the rules and the wording are tested.
enum NextTrip {
    /// Where the card's trip comes from.
    enum Source: String, Equatable {
        case school         // the school trip, due now (the next-trip nudge's, the window Fastest trip opens by itself in)
        case planned        // a planned trip (Be there by / Leave at), due now
        case live           // the first of the next trips toward where you're going
        case none           // nothing: "No trip planned"
    }

    /// A trip still to be caught counts until this long after its time to leave (you may be running for it).
    static let grace: TimeInterval = 2 * 60

    /// The card's trip: a due school trip first, then a due planned trip, then the first of the next trips you can
    /// still catch (`liveLeaves`: when to leave for each, in the live store's order), else none.
    static func pick(schoolDue: Bool, plannedDue: Bool, liveLeaves: [Date], now: Date) -> (source: Source, index: Int?) {
        if schoolDue { return (.school, nil) }
        if plannedDue { return (.planned, nil) }
        if let i = liveLeaves.firstIndex(where: { $0.timeIntervalSince(now) > -grace }) { return (.live, i) }
        return (.none, nil)
    }

    /// The card owns where it's going (0.20.1): the trip for `dest` (a place's key). A due school or planned trip only
    /// when it goes there (`dueDest`); else the first of the next trips you can still catch, when they're toward there
    /// (`liveDest`: where the live store's trips go); else none (the trips there are still coming).
    static func pick(dest: String, dueDest: String?, schoolDue: Bool, plannedDue: Bool, liveDest: String, liveLeaves: [Date],
                     now: Date) -> (source: Source, index: Int?) {
        let dueHere = dueDest == dest
        if dueHere && (schoolDue || plannedDue) { return pick(schoolDue: schoolDue, plannedDue: plannedDue, liveLeaves: [], now: now) }
        guard liveDest == dest else { return (.none, nil) }
        return pick(schoolDue: false, plannedDue: false, liveLeaves: liveLeaves, now: now)
    }

    /// (0.40) The same, with the live trip already picked (`liveIndex`, `StickyTrips.pick`: the trip you're heading for
    /// stays the card's until it has left, also past its time to leave).
    static func pick(dest: String, dueDest: String?, schoolDue: Bool, plannedDue: Bool, liveDest: String, liveIndex: Int?,
                     now: Date) -> (source: Source, index: Int?) {
        let dueHere = dueDest == dest
        if dueHere && (schoolDue || plannedDue) { return pick(schoolDue: schoolDue, plannedDue: plannedDue, liveLeaves: [], now: now) }
        guard liveDest == dest, let i = liveIndex else { return (.none, nil) }
        return (.live, i)
    }

    /// The card's destination chip: "To BUas", "To Home".
    static func destTitle(_ name: String) -> String { "To \(name)" }

    // MARK: the countdown

    struct Countdown: Equatable {
        let value: String       // "9 min", "1 h 05", "Now"
        let unit: String        // "until you leave", "time to leave"
        let spoken: String
    }

    /// "9 min until you leave"; from an hour "1 h 05"; within the minute (or just past) "Now · time to leave".
    static func countdown(leave: Date, now: Date) -> Countdown {
        let m = Int((leave.timeIntervalSince(now) / 60).rounded(.down))
        if m < 1 { return Countdown(value: "Now", unit: "time to leave", spoken: "Time to leave") }
        if m >= 60 {
            let h = m / 60, r = m % 60
            let spokenRest = r == 0 ? "" : " \(r) minute\(r == 1 ? "" : "s")"
            return Countdown(value: "\(h) h \(String(format: "%02d", r))", unit: "until you leave",
                             spoken: "\(h) hour\(h == 1 ? "" : "s")\(spokenRest) until you leave")
        }
        return Countdown(value: "\(m) min", unit: "until you leave", spoken: "\(m) minute\(m == 1 ? "" : "s") until you leave")
    }

    // MARK: the leg bar

    /// One ride of a trip, as the leg bar needs it.
    struct RideSpan: Equatable {
        let departure: Date
        let arrival: Date
        let line: String
        let train: Bool
    }

    struct Leg: Equatable {
        enum Kind: String { case walk, wait, ride }
        let kind: Kind
        let minutes: Double
        var line: String = ""
        var train = false
    }

    /// Shorter than this, a walk or a wait isn't drawn.
    static let minPart: Double = 0.5

    /// The trip as parts in time order: the walk to the first stop, each ride, the wait at each change, the walk at
    /// the end. `start`/`end`: leaving the door, arriving at the door.
    static func legs(start: Date, end: Date, rides: [RideSpan]) -> [Leg] {
        guard let first = rides.first, let last = rides.last else { return [] }
        var out: [Leg] = []
        func gap(_ a: Date, _ b: Date, _ k: Leg.Kind) {
            let m = b.timeIntervalSince(a) / 60
            if m >= minPart { out.append(Leg(kind: k, minutes: m)) }
        }
        gap(start, first.departure, .walk)
        for (k, r) in rides.enumerated() {
            if k > 0 { gap(rides[k - 1].arrival, r.departure, .wait) }
            out.append(Leg(kind: .ride, minutes: max(0, r.arrival.timeIntervalSince(r.departure) / 60), line: r.line, train: r.train))
        }
        gap(last.arrival, end, .walk)
        return out
    }

    /// Each part's share of the bar's width (they add up to 1), each at least `floor` so a short walk still shows.
    static func fractions(_ legs: [Leg], floor: Double = 0.06) -> [Double] {
        guard !legs.isEmpty else { return [] }
        let total = legs.reduce(0) { $0 + max(0, $1.minutes) }
        guard total > 0 else { return legs.map { _ in 1 / Double(legs.count) } }
        let f = min(floor, 1 / Double(legs.count))
        let raw = legs.map { max(f, max(0, $0.minutes) / total) }
        let sum = raw.reduce(0, +)
        return raw.map { $0 / sum }
    }

    /// For VoiceOver: "4 min walk, bus 306 32 min, 8 min walk".
    static func spoken(_ legs: [Leg]) -> String {
        legs.map { l in
            let m = max(1, Int(l.minutes.rounded()))
            switch l.kind {
            case .walk: return "\(m) min walk"
            case .wait: return "\(m) min to change"
            case .ride: return "\(l.train ? "train" : "bus") \(l.line) \(m) min"
            }
        }.joined(separator: ", ")
    }

    // MARK: the week

    /// The seven days of the week strip: today and the six after it.
    static func weekDays(from now: Date, cal: Calendar, count: Int = 7) -> [Date] {
        let today = cal.startOfDay(for: now)
        return (0..<count).compactMap { cal.date(byAdding: .day, value: $0, to: today) }
    }

    static func isWeekend(_ day: Date, cal: Calendar) -> Bool {
        let wd = cal.component(.weekday, from: day)
        return wd == 1 || wd == 7
    }
}
