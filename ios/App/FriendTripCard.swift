import Foundation

// Friends (0.27): a trip sent to a friend or a group (the `trip` box), and what "Take this trip" makes of it on the
// other phone. Plain values, tested without the planner or the UI. Foundation only.

/// The body of a `trip` box: the rides of one way somewhere, as the sender's planner had them.
struct TripCard: Codable, Equatable {
    /// A stop, a station or a place: its name, the live data's stop id (when known) and where it is.
    struct Spot: Codable, Equatable {
        var name: String
        var id: String? = nil
        var lat: Double? = nil
        var lon: Double? = nil

        var point: GeoPoint? {
            guard let lat, let lon else { return nil }
            return GeoPoint(lat: lat, lon: lon)
        }
    }

    /// One bus or train.
    struct Ride: Codable, Equatable {
        /// "train" or "bus" (a newer app may add "tram", "metro", "ferry").
        var mode: String
        /// As shown: "IC", "SPR", "305".
        var line: String
        /// "Intercity" (trains).
        var name: String? = nil
        /// A train's number ("3512").
        var num: String? = nil
        /// The vehicle's trip id as the live data (Transitous) names it: the same id is the same bus or train.
        var trip: String
        var head: String? = nil
        var from: Spot
        var to: Spot
        var dep: Date
        var arr: Date
        /// Scheduled times, when they differ.
        var sdep: Date? = nil
        var sarr: Date? = nil
        var plat: String? = nil
        /// Minutes of walking before it.
        var walk: Int? = nil

        var isTrain: Bool { mode == "train" }
        /// "IC 3512", "Bus 305".
        var label: String {
            if isTrain { return num.map { "\(line) \($0)" } ?? line }
            return "Bus \(line)"
        }
    }

    static let maxRides = 8
    static let maxNote = 200

    var rides: [Ride]
    /// Where the trip ends (the sender's destination).
    var to: Spot
    /// Where the sender starts (their Home goes as {"name":"Home"} without a place).
    var from: Spot? = nil
    /// When the sender leaves the door, and gets there.
    var start: Date? = nil
    var end: Date? = nil
    /// A planned trip's "be there by".
    var by: Date? = nil
    /// The sender's own line ("Take the 07:41 with me?"); nil: the app says it.
    var note: String? = nil

    var first: Ride? { rides.first }
    var arrival: Date? { end ?? rides.last?.arr }

    /// As taken: 1–8 rides, each arriving after it leaves.
    static func valid(_ c: TripCard) -> TripCard? {
        guard !c.rides.isEmpty, c.rides.count <= maxRides, c.rides.allSatisfy({ $0.arr >= $0.dep && !$0.trip.isEmpty }) else { return nil }
        var v = c
        v.note = c.note.map { String(ChatText.clean($0).prefix(maxNote)) }.flatMap { $0.isEmpty ? nil : $0 }
        return v
    }
}

/// What "Take this trip" does with a card.
enum TripTake {
    enum Way: Equatable {
        /// It leaves within the hour: Fastest trip, with this trip as your pick (it watches it and starts the ride when
        /// you're on board).
        case fastest
        /// Later today or tomorrow, to your school (`out`) or home: a Be there by plan, the friend's ride first.
        case beThereBy(out: Bool, tomorrow: Bool)
        /// Anything else: Plan, with where to and the time filled in.
        case plan
        /// The ride you'd share has left.
        case gone
    }

    /// (0.31) "Ride along" on a friend's page: their bus or train now, as a card to take. On board, it starts from
    /// where they are (so your way gets onto it further along); waiting or changing, from their stop. Nil: no vehicle
    /// known, or nowhere to get off (Home goes without a place).
    static func rideAlong(_ s: TravelState, now: Date) -> TripCard? {
        guard let trip = s.trip, !trip.isEmpty, let tl = s.to.lat, let to = s.to.lon else { return nil }
        var from = TripCard.Spot(name: s.from.name, lat: s.from.lat, lon: s.from.lon)
        if s.stage == .riding, let p = s.pos { from = TripCard.Spot(name: "On the way to \(s.to.name)", lat: p.lat, lon: p.lon) }
        let end = TripCard.Spot(name: s.to.name, lat: tl, lon: to)
        let arr: Date = max(now, s.eta ?? now.addingTimeInterval(30 * 60))
        let ride = TripCard.Ride(mode: s.mode, line: s.line ?? "", num: s.num, trip: trip, from: from, to: end, dep: now, arr: arr)
        return TripCard(rides: [ride], to: end, end: arr)
    }

    /// Fastest trip takes it when the shared ride leaves within this.
    static let soon: TimeInterval = 60 * 60
    /// Your start counts as the sender's (the rides as they are) within this of their first stop.
    static let sameStartMetres = 600.0
    /// The card's end counts as your school or home within this.
    static let samePlaceMetres = 500.0

    /// The ride you share with the sender: the first train, else the longest ride.
    static func sharedIndex(_ c: TripCard) -> Int {
        if let i = c.rides.firstIndex(where: { $0.isTrain }) { return i }
        var best = 0
        for (i, r) in c.rides.enumerated() where r.arr.timeIntervalSince(r.dep) > c.rides[best].arr.timeIntervalSince(c.rides[best].dep) {
            best = i
        }
        return best
    }

    static func shared(_ c: TripCard) -> TripCard.Ride? { c.rides.isEmpty ? nil : c.rides[sharedIndex(c)] }

    static func way(_ c: TripCard, now: Date, home: GeoPoint?, school: GeoPoint?, calendar: Calendar) -> Way {
        guard let s = shared(c) else { return .plan }
        if s.dep < now.addingTimeInterval(-60) { return .gone }
        if s.dep.timeIntervalSince(now) <= soon { return .fastest }
        let day = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: c.by ?? c.arrival ?? s.arr)).day ?? 9
        guard day == 0 || day == 1, let end = c.to.point ?? c.rides.last?.to.point else { return .plan }
        if let sc = school, Geo.metres(sc, end) <= samePlaceMetres { return .beThereBy(out: true, tomorrow: day == 1) }
        if let h = home, Geo.metres(h, end) <= samePlaceMetres { return .beThereBy(out: false, tomorrow: day == 1) }
        return .plan
    }

    /// You start where the sender does (near their first stop): the rides as they are.
    static func sameStart(_ c: TripCard, you: GeoPoint?) -> Bool {
        guard let you, let f = c.first?.from.point else { return false }
        return Geo.metres(you, f) <= sameStartMetres
    }

    /// Which of your planner's options (each its rides' trip ids) has the sender's shared ride: the one sharing the
    /// most of the card's rides (the first on a tie). Nil: none has it.
    static func pick(_ options: [[String]], card c: TripCard) -> Int? {
        guard let s = shared(c) else { return nil }
        let mine = Set(c.rides.map(\.trip))
        var best: (i: Int, n: Int)?
        for (i, ids) in options.enumerated() where ids.contains(s.trip) {
            let n = Set(ids).intersection(mine).count
            if best == nil || n > best!.n { best = (i, n) }
        }
        return best?.i
    }

    /// Where you could get on the shared ride instead (its stops before you'd get off, that it still leaves from, where
    /// you may board), the nearest to you first, at most `limit`. `board`/`alight`: where the sender gets on and off.
    static func boardCandidates(_ stops: [BoardAt.Stop], board: Int, alight: Int, you: GeoPoint, now: Date, limit: Int = 2) -> [Int] {
        guard alight <= stops.count, board < alight else { return [] }
        let ok = (0..<alight).filter { i in
            guard stops[i].boarding, let d = stops[i].departure else { return false }
            return d > now.addingTimeInterval(2 * 60)
        }
        return Array(ok.sorted { Geo.metres(you, stops[$0].point) < Geo.metres(you, stops[$1].point) }.prefix(limit))
    }

    /// When to be there by on your own way: the card's "by", else when it gets there.
    static func deadline(_ c: TripCard) -> Date? { c.by ?? c.arrival }
}

/// The words on a card.
enum TripCardWords {
    private static let amsterdam = TimeZone(identifier: "Europe/Amsterdam") ?? .current

    static func hhmm(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = amsterdam
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    /// "Today", "Tomorrow", "Thursday" (within a week), "Thu 27 Nov".
    static func day(_ d: Date, now: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = amsterdam
        let n = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: d)).day ?? 0
        if n == 0 { return "Today" }
        if n == 1 { return "Tomorrow" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = amsterdam
        f.dateFormat = (n > 1 && n < 7) ? "EEEE" : "EEE d MMM"
        return f.string(from: d)
    }

    /// The card's headline: "Take the 07:41 with me?", "Thursday: be at BUas by 09:00, this way".
    static func headline(_ c: TripCard, now: Date, group: Bool) -> String {
        if let note = c.note, !note.isEmpty { return note }
        let who = group ? "us" : "me"
        if let by = c.by {
            let d = day(by, now: now)
            return "\(d): be at \(c.to.name) by \(hhmm(by)), this way"
        }
        guard let s = TripTake.shared(c) else { return "A trip to \(c.to.name)" }
        let d = day(s.dep, now: now)
        let t: String = hhmm(s.dep)
        let when: String
        if d == "Today" { when = t } else if d == "Tomorrow" { when = t + " tomorrow" } else { when = t + " on " + d }
        return "Take the \(when) with \(who)?"
    }

    /// One line: "IC 07:41 Eindhoven → Breda".
    static func ride(_ r: TripCard.Ride) -> String {
        "\(r.isTrain ? r.line : "Bus \(r.line)") \(hhmm(r.dep)) \(r.from.name) → \(r.to.name)"
    }

    /// For a chat's list: "07:41 to Breda".
    static func short(_ c: TripCard) -> String {
        guard let f = c.first else { return c.to.name }
        return "\(hhmm(f.dep)) to \(c.to.name)"
    }

    /// For VoiceOver: the whole card in one go.
    static func spoken(_ c: TripCard, now: Date, group: Bool) -> String {
        let rides = c.rides.map(ride).joined(separator: ", then ")
        let arrive = c.arrival.map { ", there at \(hhmm($0))" } ?? ""
        return "\(headline(c, now: now, group: group)). \(rides)\(arrive)."
    }
}
