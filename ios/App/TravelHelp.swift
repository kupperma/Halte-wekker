import Foundation

// 0.36: three reminders around a trip, as plain rules (Foundation only, tested): "Did you check out?", NS's money back
// for a late train, and the last way home in the evening. TripManager and TravelNotes do the notifying.

// MARK: check-out reminder

/// "Did you check out?" a minute after you get off, when you have to check out there: at the end of every trip, and at a
/// change where the OV-chipkaart wants it — off a bus (you check in and out on every bus), from a train to a bus or the
/// other way, and between train companies (NS to Arriva, …). Not between two NS trains: you stay checked in at a
/// station. The app can't see your card (no NFC): it's only a reminder.
enum CheckOut {
    /// One ride of the trip, as far as checking out goes.
    struct Ride: Equatable, Sendable {
        let train: Bool
        /// Who runs it ("NS", "Arriva"), when known.
        var company: String? = nil
    }

    /// The notification comes this long after you got off.
    static let after: TimeInterval = 60
    /// Faster than this in that minute (m/s, two fixes) and it thinks you're still on board: no reminder.
    static let aboardSpeed = 7.0

    /// Do you check out after ride `i` (0-based)?
    static func due(after i: Int, of rides: [Ride]) -> Bool {
        guard rides.indices.contains(i) else { return false }
        guard i + 1 < rides.count else { return true }               // the end of the trip
        let a = rides[i], b = rides[i + 1]
        if !a.train || !b.train { return true }                      // a bus on either side
        if let x = a.company, let y = b.company, !x.isEmpty, !y.isEmpty, fold(x) != fold(y) { return true }
        return false
    }

    private static func fold(_ s: String) -> String { s.lowercased().trimmingCharacters(in: .whitespaces) }

    /// Still on board in the minute after the stop: the next leg found the vehicle you got off, or two GPS speeds of a
    /// vehicle came in.
    static func stillAboard(speeds: [Double], sameVehicle: Bool) -> Bool {
        sameVehicle || speeds.filter { $0.isFinite && $0 >= aboardSpeed }.count >= 2
    }

    /// The notification's words. `at`: where you got off; `change`: (from, to) at a change, else the trip's end.
    static func text(at stop: String, change: (fromTrain: Bool, toTrain: Bool)? = nil) -> (title: String, body: String) {
        let title = "Did you check out?"
        guard let c = change else {
            return (title, "You’re at \(stop). Hold your card or phone to the check-out pole, or you pay the full fare.")
        }
        func w(_ t: Bool) -> String { t ? "train" : "bus" }
        if c.fromTrain && c.toTrain {
            return (title, "At \(stop) you change train company: check out at the pole of the train you leave, and in at the next one’s.")
        }
        return (title, "At \(stop) you change from \(w(c.fromTrain)) to \(w(c.toTrain)): check out of the \(w(c.fromTrain)), then in on the \(w(c.toTrain)).")
    }
}

// MARK: money back for a late train

/// NS's "Geld terug bij vertraging": a train journey that gets to its last station 30 minutes late or more gets money
/// back (30–59 min half the fare, 60 or more all of it; with a student travel product a fixed amount). The app tells you
/// once per trip, after it, with a link to NS's claim page. Rules and page checked 20 November 2026:
/// https://www.ns.nl/service-en-contact/geld-terug/vergoedingen-geld-terug-bij-vertraging
/// (The high-speed line already pays from 15 minutes; this keeps NS's common 30.)
enum DelayClaim {
    static let threshold = 30.0
    static let claimURL = "https://www.ns.nl/service-en-contact/geld-terug/geld-terug-bij-vertraging"

    /// How late the trip's trains got you there, in minutes: the train part's live arrival against its planned one
    /// (a missed change counts), or the latest delay a train had at your stop, whichever is more. Nil: nothing known.
    static func minutesLate(plannedEnd: Date?, actualEnd: Date?, trainDelays: [Double]) -> Double? {
        var worst: Double? = trainDelays.filter(\.isFinite).max()
        if let p = plannedEnd, let a = actualEnd {
            let m = a.timeIntervalSince(p) / 60
            if m.isFinite { worst = max(worst ?? m, m) }
        }
        return worst
    }

    /// Worth telling: 30 minutes or more, not told for this trip yet.
    static func due(minutesLate m: Double?, told: Bool) -> Bool {
        guard !told, let m, m.isFinite else { return false }
        return m >= threshold - 0.5          // (34.6 is "35 min", 29.6 is "30 min": as it's shown)
    }

    static func text(minutesLate m: Double) -> (title: String, body: String) {
        let n = Int(m.rounded())
        let share = n >= 60 ? "the whole fare" : "half the fare"
        return ("Your train was \(n) min late — you can claim money back from NS",
                "Geld terug bij vertraging: \(share) back (a fixed amount with a student OV). Tap to open NS’s claim page.")
    }
}

// MARK: the last way home

/// In the evening, away from home: the latest bus or train that still gets you home tonight, on the home's card, and a
/// notification 30 minutes before it leaves. Worked out with Transitous (asked "arrive by" the night's end), kept, and
/// asked again at most once an hour (or after you moved a kilometre).
enum LastTrip {
    /// From 20:00 until 04:00.
    static let fromHour = 20
    static let untilHour = 4
    static let awayMetres = 3000.0
    static let warnBefore: TimeInterval = 30 * 60
    static let refreshEvery: TimeInterval = 3600
    static let movedMetres = 1000.0
    /// A way home that takes longer than this from its first departure isn't one (a night spent at a station).
    static let longest: TimeInterval = 4 * 3600

    static let zone = TimeZone(identifier: "Europe/Amsterdam")!
    private static var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = zone; return c }

    /// One way home Transitous gave: when you leave where you are, when its first ride leaves (and from where), when
    /// you're home.
    struct Option: Equatable, Sendable {
        let leave: Date
        let firstDeparture: Date
        let arrive: Date
        let from: String
        var cancelled = false
    }

    static func evening(_ now: Date) -> Bool {
        let h = calendar.component(.hour, from: now)
        return h >= fromHour || h < untilHour
    }

    /// The card and the notification are for now: evening, and more than 3 km from Home.
    static func wanted(now: Date, metresFromHome: Double?) -> Bool {
        guard let m = metresFromHome, m.isFinite else { return false }
        return evening(now) && m > awayMetres
    }

    /// The night's end it asks Transitous to arrive by, latest first: 04:00, then 02:00, 01:00 and midnight (its
    /// "arrive by" looks a few hours back only, so an earlier one finds a last train that left before the latest asked).
    static func arriveBy(now: Date) -> [Date] {
        let cal = calendar
        let base = cal.startOfDay(for: now.addingTimeInterval(-Double(untilHour) * 3600))   // the evening's own day
        let night = cal.date(byAdding: .day, value: 1, to: base)!                            // the midnight after it
        return [4, 2, 1, 0].map { night.addingTimeInterval(Double($0) * 3600) }.filter { $0 > now.addingTimeInterval(15 * 60) }
    }

    /// The last one: the latest you can leave (still to come, at least a minute away), not cancelled, not a night at a
    /// station; of those leaving together, the one home first.
    static func pick(_ options: [Option], now: Date) -> Int? {
        let ok = options.indices.filter { i in
            let o = options[i]
            return !o.cancelled && o.leave > now.addingTimeInterval(60) && o.arrive > o.leave
                && o.arrive.timeIntervalSince(o.firstDeparture) <= longest
        }
        return ok.max { a, b in
            let x = options[a], y = options[b]
            if x.leave != y.leave { return x.leave < y.leave }
            return x.arrive > y.arrive
        }
    }

    /// Ask again: never asked, an hour since, moved a kilometre, or the one it knows has left.
    static func refreshDue(lastAsked: Date?, askedAt: GeoPoint?, here: GeoPoint, known: Option?, now: Date) -> Bool {
        guard let t = lastAsked, let p = askedAt else { return true }
        if now.timeIntervalSince(t) >= refreshEvery || now < t { return true }
        if Geo.metres(p, here) >= movedMetres { return true }
        if let k = known, k.leave <= now { return true }
        return false
    }

    /// When the notification comes (nil: already past).
    static func warnAt(_ o: Option, now: Date) -> Date? {
        let w = o.leave.addingTimeInterval(-warnBefore)
        return w > now ? w : nil
    }

    static func cardText(_ o: Option, hhmm: (Date) -> String) -> String {
        "Last way home leaves \(hhmm(o.leave)) from \(o.from)"
    }

    static func notice(_ o: Option, hhmm: (Date) -> String) -> (title: String, body: String) {
        ("Last way home in 30 min",
         "Leave at \(hhmm(o.leave)) for the \(hhmm(o.firstDeparture)) from \(o.from), home \(hhmm(o.arrive)). After that there’s none tonight.")
    }
}
