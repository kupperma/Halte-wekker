import Foundation

// Friends (0.26): "Travelling now" as plain values, tested without the relay, the trip or the UI. Foundation only.
//
// While a trip runs and you're confirmed on board, each friend you show your trips to gets a `travel` box (the body
// below, locked for them like every box) every minute and when the leg changes, through the relay's state routes:
// the relay keeps only the newest one per (you -> friend), for a few minutes, and the app takes it back when the trip
// ends. Nothing is sent when no trip runs.

/// The body of a `travel` box: what a friend sees of your trip right now.
struct TravelState: Codable, Equatable {
    /// A stop or station: its name, and where it is (when known).
    struct Spot: Codable, Equatable {
        var name: String
        var lat: Double?
        var lon: Double?
    }

    /// Your phone's last GPS fix (5 decimals), how sure (m) and when.
    struct Position: Codable, Equatable {
        var lat: Double
        var lon: Double
        var acc: Double?
        var at: Date
    }

    /// The coach you marked on a train: `n` of `of`, counted from the front when `front` (the direction it goes),
    /// else as NS draws it at the station `at` (an NS station code) from the left.
    struct Coach: Codable, Equatable {
        var n: Int
        var of: Int
        var front: Bool
        var at: String?
        /// (0.31) Where in the coach, roughly: the deck and the window (`SeatMap`). A 0.26–0.30 app leaves it out and
        /// ignores it.
        var seat: Seat? = nil
    }

    /// (0.31) Your window in your coach. `deck`: "upper" or "lower" in a double-deck coach, "none" in a single-deck
    /// one (anything else reads as "none"). `w`: the window, 1-based, counted from the back of the coach (the end
    /// nearer the back of the train) when the coach is counted from the front (`front`); else from the left of NS's
    /// drawing at `at`, like the coach. `of`: windows in a row as the picker drew them (11).
    struct Seat: Codable, Equatable {
        var deck: String
        var w: Int
        var of: Int
    }

    enum Stage: String {
        /// On board.
        case riding
        /// The trip runs, but you're still at the stop.
        case waiting
        /// Between two legs.
        case change
    }

    /// "riding", "waiting" or "change" (a value this version doesn't know reads as riding).
    var state: String
    /// "train" or "bus" (or what a newer app adds: "tram", "metro", "ferry").
    var mode: String
    /// The line as shown: "IC", "SPR", "306" (nil: not known yet).
    var line: String?
    /// A train's number ("3512").
    var num: String?
    /// The vehicle's trip id as the live data names it: the same id is the same bus or train.
    var trip: String?
    var from: Spot
    var to: Spot
    /// The trip's end, when it isn't `to`.
    var dest: Spot?
    /// When it gets to `to`.
    var eta: Date?
    /// When it gets to the trip's end.
    var end: Date?
    var pos: Position?
    /// This leg (1-based) of how many.
    var leg: Int?
    var legs: Int?
    var coach: Coach?
    /// (Listening now, relay 2026-11-27) The song playing now, when you share it with friends (`MusicShare`): the
    /// live link's `music`. An app before it leaves it out and ignores it.
    var music: LiveMusic? = nil

    var stage: Stage { Stage(rawValue: state) ?? .riding }
    var isTrain: Bool { mode == "train" }
}

/// A friend's state as this phone read it from the relay.
struct FriendTravelSeen: Equatable {
    let from: String
    let state: TravelState
    /// When they sent it (their signed time), and when the relay drops it.
    let sent: Date
    let exp: Date
}

/// How old a friend's state is.
enum TravelFreshness: Equatable {
    /// Up to date (within a couple of minutes).
    case fresh
    /// Older: shown as "last seen", greyed.
    case stale
    /// Too old, expired, or the trip should be over: not shown.
    case gone
}

enum TravelAge {
    /// What a state may be old and still count as now (the app sends every minute).
    static let freshFor: TimeInterval = 150
    /// The longest a state is shown at all (as "last seen").
    static let showFor: TimeInterval = 600
    /// How long after its arrival time a trip still shows (late trains).
    static let pastEnd: TimeInterval = 20 * 60
    /// What the app asks the relay to keep a state for (it sends every minute; an update that doesn't come lets it go).
    static let ttl = 360
    /// How often a running trip sends (on the ride's own network tick, which comes every 30 s).
    static let every: TimeInterval = 55

    static func freshness(sent: Date, exp: Date?, end: Date?, now: Date) -> TravelFreshness {
        if let exp, exp <= now { return .gone }
        if let end, now.timeIntervalSince(end) > pastEnd { return .gone }
        let age = now.timeIntervalSince(sent)
        if age > showFor { return .gone }
        return age <= freshFor ? .fresh : .stale
    }

    static func freshness(_ s: FriendTravelSeen, now: Date) -> TravelFreshness {
        freshness(sent: s.sent, exp: s.exp, end: s.state.end ?? s.state.eta, now: now)
    }

    /// Whether it's time for the next one (`last`: when the last went; a leg change sends at once).
    static func due(last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= every
    }
}

/// When your trip is shared, and with whom.
enum TravelShareRules {
    /// What the running trip says about you (as `TripManager` has it).
    struct Signals: Equatable {
        /// A trip runs (riding, waiting, at a change; not idle, not arrived).
        var running = false
        /// The demo ride: never shared.
        var demo = false
        /// You started this trip yourself (not started by itself).
        var startedByHand = false
        /// The bus or train you're on is known: matched by your GPS against its live position, with none left to
        /// choose between.
        var vehicleMatched = false
        /// You picked it ("I'm on this one") or said you're on the planned one ("I'm on it").
        var pickedByHand = false
    }

    /// Confirmed on board for this trip: once it is, it stays so until the trip ends.
    static func confirmed(before: Bool, _ s: Signals) -> Bool {
        guard s.running, !s.demo else { return false }
        return before || s.startedByHand || s.vehicleMatched || s.pickedByHand
    }

    enum Decision: Equatable {
        /// Send the state to these friends (and take it back from anyone it went to before and doesn't now).
        case share([String])
        /// Take back what was sent (the trip ended, or sharing is off now).
        case clear
        /// Ask first: the one-time screen hasn't been answered.
        case ask
        /// Nothing to do.
        case none
    }

    /// `consent`: the one-time screen's answer (nil: not asked yet). `friends`: each friend and their "Show my trips"
    /// switch. `sentBefore`: someone has this trip's state (so stopping must clear it).
    static func decide(consent: Bool?, paused: Bool, confirmed: Bool, friends: [(id: String, on: Bool)], sentBefore: Bool) -> Decision {
        let stop: Decision = sentBefore ? .clear : .none
        guard confirmed, !friends.isEmpty else { return stop }
        guard let consent else { return sentBefore ? .clear : .ask }
        guard consent, !paused else { return stop }
        let to = recipients(friends)
        return to.isEmpty ? stop : .share(to)
    }

    /// The friends with "Show my trips" on (the default), in order.
    static func recipients(_ friends: [(id: String, on: Bool)]) -> [String] {
        friends.filter(\.on).map(\.id)
    }

    /// Those it went to before that it doesn't go to now (their switch went off): their state is taken back.
    static func toClear(sentTo: [String], now: [String]) -> [String] {
        let keep = Set(now)
        return sentTo.filter { !keep.contains($0) }
    }
}

/// What a friend's trip says, in words.
enum TravelWords {
    static func clock(_ d: Date, zone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = zone
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    static func capitalFirst(_ t: String) -> String { String(t.prefix(1)).uppercased() + String(t.dropFirst()) }
    static func lowerFirst(_ t: String) -> String { String(t.prefix(1)).lowercased() + String(t.dropFirst()) }

    /// "IC 3512", "Bus 306", "Train" (no line yet).
    static func vehicle(_ s: TravelState) -> String {
        let line = (s.line ?? "").trimmingCharacters(in: .whitespaces)
        let num = (s.num ?? "").trimmingCharacters(in: .whitespaces)
        if s.isTrain {
            if line.isEmpty { return num.isEmpty ? "Train" : "Train \(num)" }
            return num.isEmpty ? line : "\(line) \(num)"
        }
        let word: String = s.mode == "bus" || s.mode.isEmpty ? "Bus" : capitalFirst(s.mode)
        return line.isEmpty ? word : "\(word) \(line)"
    }

    /// One line for the list: "IC 3512 to Breda · arrives 08:43", "Waiting for bus 306 at Veghel",
    /// "Changing at Eindhoven".
    static func summary(_ s: TravelState, zone: TimeZone = .current) -> String {
        let v = vehicle(s)
        switch s.stage {
        case .waiting:
            // "the IC 3512", "the train", "bus 306", "the bus"
            let what: String
            if s.isTrain { what = "the " + (v == "Train" ? "train" : v) }
            else if s.line == nil { what = "the " + v.lowercased() }
            else { what = lowerFirst(v) }
            return "Waiting for \(what) at \(s.from.name)"
        case .change:
            var t = "Changing at \(s.from.name)"
            if s.line != nil { t += " · then \(v) to \(s.to.name)" }
            return t
        case .riding:
            var t = "\(v) to \(s.to.name)"
            if let e = s.eta { t += " · arrives \(clock(e, zone: zone))" }
            return t
        }
    }

    /// (0.31) A friend's card on the Friends map's sheet: "IC 3512 to Breda", "Waiting at Best", "Changing at Eindhoven".
    static func cardLine(_ s: TravelState) -> String {
        switch s.stage {
        case .waiting: return "Waiting at \(s.from.name)"
        case .change: return "Changing at \(s.from.name)"
        case .riding: return "\(vehicle(s)) to \(s.to.name)"
        }
    }

    /// (0.31) Under it: "arrives 08:43" (nil: not known, or still waiting).
    static func cardTime(_ s: TravelState, zone: TimeZone = .current) -> String? {
        guard s.stage == .riding, let e = s.eta else { return nil }
        return "arrives \(clock(e, zone: zone))"
    }

    /// (0.31) The friend's page, next to the line's pill: "to Breda · 08:43".
    static func headline(_ s: TravelState, zone: TimeZone = .current) -> String {
        switch s.stage {
        case .waiting: return "waiting at \(s.from.name)"
        case .change: return "changing at \(s.from.name)"
        case .riding:
            let v = vehicle(s)
            let what: String = s.line == nil ? v + " " : (s.num.map { "\($0) " } ?? "")
            return "\(what)to \(s.to.name)" + (s.eta.map { " · \(clock($0, zone: zone))" } ?? "")
        }
    }

    /// Under it: where the trip ends and when, if that's further.
    static func ending(_ s: TravelState, zone: TimeZone = .current) -> String? {
        guard let d = s.dest, d.name != s.to.name else { return nil }
        if let e = s.end { return "To \(d.name), there around \(clock(e, zone: zone))" }
        return "To \(d.name)"
    }

    /// "Updated 08:41" (stale) or nil (fresh).
    static func age(_ seen: FriendTravelSeen, now: Date, zone: TimeZone = .current) -> String? {
        TravelAge.freshness(seen, now: now) == .stale ? "Last update \(clock(seen.sent, zone: zone)) · may have moved on" : nil
    }
}

/// The coach picker's sums: the coaches of a train from NS's drawing (its units and how many coaches each has), which
/// one is which counted from the front, and where on the platform one stops.
enum CoachMap {
    /// A unit of the train as NS draws it: where it starts and how long it is (shares of the whole train), and its
    /// coaches (0: not known).
    struct Unit: Equatable {
        var x: Double
        var w: Double
        var cars: Int
    }

    /// One coach in the drawing, `drawn` counted from the left (0-based), from `x0` to `x1` (shares of the train).
    struct Spot: Equatable {
        var drawn: Int
        var x0: Double
        var x1: Double
        var mid: Double { (x0 + x1) / 2 }
    }

    /// Every coach, left to right. A unit whose coaches aren't known gets its share of `totalCars` (by length), at least one.
    static func spots(_ units: [Unit], totalCars: Int = 0) -> [Spot] {
        let known = units.reduce(0) { $0 + max(0, $1.cars) }
        let unknownWidth = units.filter { $0.cars <= 0 }.reduce(0.0) { $0 + $1.w }
        let left = max(0, totalCars - known)
        var out: [Spot] = []
        for u in units {
            var n = u.cars
            if n <= 0 {
                n = unknownWidth > 0 && left > 0 ? Int((Double(left) * u.w / unknownWidth).rounded()) : 1
                n = max(1, n)
            }
            let step = u.w / Double(n)
            for i in 0..<n {
                out.append(Spot(drawn: out.count, x0: u.x + Double(i) * step, x1: u.x + Double(i + 1) * step))
            }
        }
        return out
    }

    /// The coach drawn at `drawn` (from the left), as a number: from the front when the drawing says which way it goes
    /// ("left": the front is on the left; "right": on the right), else from the left.
    static func number(drawn: Int, of total: Int, dir: String?) -> (n: Int, front: Bool) {
        switch dir {
        case "left": return (drawn + 1, true)
        case "right": return (total - drawn, true)
        default: return (drawn + 1, false)
        }
    }

    /// Back to the drawing: which coach (from the left) is coach `c` in a drawing going `dir` at `station`. Nil: it
    /// can't be told (a count from the left at another station, or a train of another length).
    static func drawn(_ c: TravelState.Coach, total: Int, dir: String?, station: String?) -> Int? {
        guard c.n >= 1, c.n <= c.of, c.of == total else { return nil }
        if c.front {
            switch dir {
            case "left": return c.n - 1
            case "right": return total - c.n
            default: return nil
            }
        }
        guard let at = c.at, let station, at == station else { return nil }
        return c.n - 1
    }

    /// "front", "middle" or "back" (halves; the middle coach of an odd train is "middle").
    static func part(_ n: Int, of total: Int) -> String {
        guard total > 1 else { return "middle" }
        if total % 2 == 1, n == (total + 1) / 2 { return "middle" }
        return n <= total / 2 ? "front" : "back"
    }

    /// "Coach 3 of 6 · front", or "Coach 3 of 6" when it isn't known which way the train goes.
    static func label(_ c: TravelState.Coach) -> String {
        c.front ? "Coach \(c.n) of \(c.of) · \(part(c.n, of: c.of))" : "Coach \(c.n) of \(c.of)"
    }

    /// The platform letter nearest a point of the train (letters: their place along it, as shares).
    static func letter(at x: Double, letters: [(letter: String, x: Double)]) -> String? {
        letters.min { abs($0.x - x) < abs($1.x - x) }?.letter
    }

    /// Where to wait for coach `c`: "Wait near B, at the front end of the platform", or "Coach 3 from the front"
    /// without letters (nil: nothing to say).
    static func platformHint(_ c: TravelState.Coach, units: [Unit], totalCars: Int, letters: [(letter: String, x: Double)],
                             dir: String?, station: String?) -> String? {
        let all = spots(units, totalCars: totalCars)
        let fromFront = c.front ? "Coach \(c.n) from the front" : nil
        guard !all.isEmpty, let d = drawn(c, total: all.count, dir: dir, station: station), d < all.count else { return fromFront }
        guard let l = letter(at: all[d].mid, letters: letters) else { return fromFront }
        let p = part(c.n, of: c.of)
        if c.front { return p == "middle" ? "Wait near \(l), in the middle of the platform" : "Wait near \(l), at the \(p) end of the platform" }
        return "Wait near \(l) on the platform"
    }
}
