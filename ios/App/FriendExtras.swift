import Foundation

// Friends extras (0.29): "Wait for me", the delay alarm for shared rides, the wake-up buddy and who's on campus, as
// plain values and rules, tested without the relay, the trip or the UI. Foundation only. Every box goes through the
// 0.25 mailbox (`/f/v1/send`) with a slot, so the newest replaces the last one waiting; nothing new on the relay.
// Platform-neutral: the bodies and rules are written out in docs/superpowers/specs/2026-11-18-friends-design.md,
// "As built (0.29)".

// MARK: wait for me

/// The body of a `wait` box (slot `wait`, ttl 900 s): you're on your way to a stop and ask a friend (or a group) to
/// wait for you there. Sent again while you come closer (with each check of the relay), `off` when it's over.
struct WaitFor: Codable, Equatable {
    enum Phase: String { case coming, there, off }

    /// The request's id: the same in every update (an answer says it in `re`).
    var id: String
    /// "coming", "there" or "off" (an unknown value reads as coming).
    var state: String
    /// The stop to wait at (with where it is).
    var stop: TripCard.Spot
    /// The bus or train to take from there (0.27's ride), when known.
    var ride: TripCard.Ride? = nil
    /// How far you are from the stop (straight line, metres).
    var dist: Int? = nil
    /// When you expect to be there.
    var eta: Date? = nil
    /// When that was measured (your position's time).
    var at: Date

    var phase: Phase { Phase(rawValue: state) ?? .coming }

    /// As taken: an id of 1–32 of [A-Za-z0-9_-], a stop with a name and a place, a distance within 100 km.
    static func valid(_ w: WaitFor) -> WaitFor? {
        guard WaitRules.validId(w.id), !w.stop.name.isEmpty, w.stop.point != nil else { return nil }
        var v = w
        if let d = w.dist, d < 0 || d > 100_000 { v.dist = nil }
        if let r = w.ride, r.trip.isEmpty || r.arr < r.dep { v.ride = nil }
        return v
    }
}

/// An answer to a `wait`: a `message` with `re` = the wait's id and `answer` = "wait" or "next".
enum WaitAnswer: String, Codable, Equatable {
    /// "I'll wait".
    case wait
    /// "Let's take the next one together" (a trip card for that next one follows).
    case next

    var text: String { self == .wait ? "I’ll wait" : "Let’s take the next one together" }
}

/// Someone's wait as this phone read it.
struct WaitSeen: Codable, Equatable {
    var from: String
    /// The chat it's in: their account, or "g." + the group's id.
    var chat: String
    var wait: WaitFor
    /// Their signed time.
    var t: Int
    /// When this phone got it.
    var got: Date
}

/// How old a wait is.
enum WaitAge {
    /// Up to date.
    static let freshFor: TimeInterval = 90
    /// Shown at all (greyed after `freshFor`).
    static let showFor: TimeInterval = 15 * 60
    /// A wait for a ride that left this long ago is over.
    static let pastRide: TimeInterval = 5 * 60

    static func freshness(_ s: WaitSeen, now: Date) -> TravelFreshness {
        if s.wait.phase == .off { return .gone }
        // (their time, never later than this phone got it)
        let sent: Date = min(s.wait.at, s.got)
        let age: TimeInterval = now.timeIntervalSince(sent)
        if age > showFor { return .gone }
        if let r = s.wait.ride, now.timeIntervalSince(r.dep) > pastRide { return .gone }
        return age <= freshFor ? .fresh : .stale
    }
}

/// When your own wait goes out again, and when it's over.
enum WaitRules {
    static let slot = "wait"
    static let ttl = 900
    /// At the stop within this.
    static let thereMetres = 40.0
    /// Not more often than this (the checks come every 8–60 s).
    static let minGap: TimeInterval = 20
    /// Again after this even when nothing moved.
    static let refresh: TimeInterval = 60
    /// Again when you moved this much closer or further.
    static let moved = 25
    /// A wait is over after this, whatever happens.
    static let maxAge: TimeInterval = 30 * 60
    /// …or this long after its ride left.
    static let afterRide: TimeInterval = 2 * 60

    static func validId(_ s: String) -> Bool {
        guard (1...32).contains(s.count) else { return false }
        return s.unicodeScalars.allSatisfy { c in
            (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "_" || c == "-"
        }
    }

    /// Your state now: at the stop within `thereMetres`, else coming; nil: it's over (too old, or its ride left).
    static func phase(dist: Double?, started: Date, rideDep: Date?, now: Date) -> WaitFor.Phase? {
        if now.timeIntervalSince(started) > maxAge { return nil }
        if let d = rideDep, now.timeIntervalSince(d) > afterRide { return nil }
        if let dist, dist <= thereMetres { return .there }
        return .coming
    }

    /// When you'll be at the stop, walking (`BoardAt.walkMinutes`: a third longer by the streets, 1.2 m/s); now at it.
    static func eta(dist: Double, now: Date) -> Date {
        if dist <= thereMetres { return now }
        return now.addingTimeInterval(Double(BoardAt.walkMinutes(metres: dist)) * 60)
    }

    /// Whether the next update goes now: a new phase at once; else not within `minGap` of the last, then when you
    /// moved `moved` m or more, the time there moved a minute or more, or `refresh` went by.
    static func due(last: WaitFor?, lastSent: Date?, next: WaitFor, now: Date) -> Bool {
        guard let last, let lastSent else { return true }
        if last.phase != next.phase { return true }
        let gap: TimeInterval = now.timeIntervalSince(lastSent)
        if gap < minGap { return false }
        if gap >= refresh { return true }
        if let a = last.dist, let b = next.dist, abs(a - b) >= moved { return true }
        if let a = last.eta, let b = next.eta, abs(a.timeIntervalSince(b)) >= 60 { return true }
        return false
    }
}

/// The words for a wait.
enum WaitWords {
    /// "300 m", "1.2 km" (tens of metres below a kilometre).
    static func metres(_ m: Int) -> String {
        if m < 1000 { return "\(max(0, Int((Double(m) / 10).rounded()) * 10)) m" }
        return String(format: "%.1f km", Double(m) / 1000)
    }

    /// "Sam is 2 min from the stop (300 m)", "Sam is under a minute from the stop (80 m)", "Sam is 300 m from the
    /// stop", "Sam is at the stop".
    static func line(_ name: String, _ w: WaitFor, now: Date) -> String {
        if w.phase == .there { return "\(name) is at the stop" }
        let far: String? = w.dist.map(metres)
        guard let eta = w.eta else {
            return far.map { "\(name) is \($0) from the stop" } ?? "\(name) is on the way to the stop"
        }
        let mins = Int((eta.timeIntervalSince(now) / 60).rounded(.up))
        let when: String = mins <= 0 ? "under a minute" : "\(mins) min"
        return far.map { "\(name) is \(when) from the stop (\($0))" } ?? "\(name) is \(when) from the stop"
    }

    /// "At Eindhoven Centraal · for the IC 3512 at 07:41", and "· it leaves before Sam gets there" when it does.
    static func detail(_ name: String, _ w: WaitFor) -> String {
        var t = "At \(w.stop.name)"
        if let r = w.ride {
            t += " · for the \(r.label) at \(TimetableDays.hhmm(r.dep))"
            if w.phase == .coming, let e = w.eta, e > r.dep { t += " · it leaves before \(name) gets there" }
        }
        return t
    }

    /// Your own wait, on the ride screen and in the chat: "Asked Lisa to wait · you're 300 m from the stop".
    static func mine(_ who: String, _ w: WaitFor) -> String {
        if w.phase == .there { return "Asked \(who) to wait · you’re at the stop" }
        guard let d = w.dist else { return "Asked \(who) to wait" }
        return "Asked \(who) to wait · you’re \(metres(d)) from the stop"
    }
}

/// "Take the next one with you": the next way from the stop (getting on within 300 m of it, after the one you'd miss).
enum WaitNext {
    static let sameStop = 300.0

    /// The earliest way whose first ride leaves from the stop at `after` or later and isn't `exclude`; one of the same
    /// line instead when it leaves within 15 minutes of that one.
    static func pick(_ ways: [Way], stop: GeoPoint, after: Date, exclude: String?, line: String?) -> Way? {
        let ok: [Way] = ways.filter { w in
            guard let f = w.legs.first, f.trip != exclude, f.dep >= after, let p = f.from.point else { return false }
            return Geo.metres(p, stop) <= sameStop
        }.sorted { ($0.legs.first?.dep ?? .distantFuture) < ($1.legs.first?.dep ?? .distantFuture) }
        guard let first = ok.first, let firstDep = first.legs.first?.dep else { return nil }
        if let line, first.legs.first?.line != line,
           let same = ok.first(where: { $0.legs.first?.line == line && ($0.legs.first?.dep ?? .distantFuture) <= firstDep.addingTimeInterval(15 * 60) }) {
            return same
        }
        return first
    }
}

// MARK: delay alarm for shared rides

/// The body of a `delay` box (slot `delay`, ttl 3 h): a bus or train you share with friends runs late or is cancelled,
/// to everyone else on it, with the next ride you can all still take.
struct RideDelay: Codable, Equatable {
    /// The ride (0.27's ride) as the sender has it: where they get on (`from`), its live `dep` and scheduled `sdep`.
    var ride: TripCard.Ride
    /// Minutes late (0 when only cancelled).
    var late: Int
    var cancelled: Bool? = nil
    /// The next ride all of you can still take (as the sender's planner has it: from where the first of you gets on).
    var next: TripCard.Ride? = nil
    /// Everyone on it the sender knows of (their own account too).
    var who: [String]? = nil

    var isCancelled: Bool { cancelled == true }

    static func valid(_ d: RideDelay) -> RideDelay? {
        guard !d.ride.trip.isEmpty, d.late >= 0, d.late <= 600 else { return nil }
        var v = d
        if let n = d.next, n.trip.isEmpty || n.arr < n.dep { v.next = nil }
        if let w = d.who { v.who = Array(w.prefix(20)) }
        return v
    }
}

/// A delay as this phone read it (or found it itself: `from` is then your own account).
struct DelaySeen: Codable, Equatable {
    var from: String
    var delay: RideDelay
    var got: Date
}

/// What you were last told about a ride (by your own phone or a friend's).
struct DelayTold: Codable, Equatable {
    var late: Int
    var cancelled: Bool
    var at: Date
}

/// One bus or train you're on (or about to be) with friends.
struct SharedRideRef: Equatable {
    /// The ride as you have it (where you get on and off).
    var ride: TripCard.Ride
    /// The others on it (not you), in order.
    var riders: [String]
    /// Where each of them gets on and off it, when known (their trip, or the card).
    var spots: [String: [TripCard.Spot]] = [:]
}

enum DelayAlarm {
    static let slot = "delay"
    static let ttl = 3 * 3600
    /// Late enough to tell.
    static let minLate = 3
    /// Told again when it changes this much more.
    static let step = 2
    /// Looked at (live times) at most this often.
    static let lookEvery: TimeInterval = 120
    /// Rides that leave within this are watched (and the one you're on, until it gets there).
    static let ahead: TimeInterval = 90 * 60
    /// At most this many planner questions for the next ride you can all take, per delay.
    static let budget = 4

    /// Tell: cancelled when it wasn't, or `minLate` or more and `step` away from what you were told.
    static func shouldTell(late: Int, cancelled: Bool, told: DelayTold?) -> Bool {
        if cancelled { return told?.cancelled != true }
        guard late >= minLate else { return false }
        guard let told, !told.cancelled else { return told == nil }
        return abs(late - told.late) >= step
    }

    static func lookDue(last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= lookEvery
    }

    /// Whether a ride is watched now: it leaves within `ahead` and hasn't arrived.
    static func watched(_ r: TripCard.Ride, now: Date) -> Bool {
        r.arr > now && r.dep.timeIntervalSince(now) <= ahead
    }

    /// The ride's lateness from its stops' live times (`BoardAt.Stop`, the live data's trip): at your stop (`board`,
    /// within 300 m, else by name) while it hasn't left there; after that at its next stop. Cancelled: the stop (or
    /// every stop) says so. Nil: no live time to tell by.
    static func read(_ stops: [BoardAt.Stop], board: TripCard.Spot, now: Date) -> (late: Int, cancelled: Bool, dep: Date?)? {
        guard !stops.isEmpty else { return nil }
        var at: Int? = nil
        if let p = board.point {
            let near: [Int] = stops.indices.filter { Geo.metres(stops[$0].point, p) <= 300 }
            at = near.min { Geo.metres(stops[$0].point, p) < Geo.metres(stops[$1].point, p) }
        }
        if at == nil { at = stops.firstIndex { $0.name == board.name } }
        let allCancelled: Bool = stops.allSatisfy(\.cancelled)
        guard let i = at else { return allCancelled ? (0, true, nil) : nil }
        let mine: BoardAt.Stop = stops[i]
        if mine.cancelled || allCancelled { return (0, true, mine.departure) }
        var s: BoardAt.Stop = mine
        if let d = mine.departure, d < now, let ahead = stops[i...].first(where: { ($0.departure ?? .distantPast) >= now }) { s = ahead }
        guard let dep = s.departure, let sched = s.scheduledDeparture else { return nil }
        let late = max(0, Int((dep.timeIntervalSince(sched) / 60).rounded()))
        return (late, false, mine.departure)
    }

    /// The next ride all of you can take, from each person's ways from where they get on to where they get off
    /// (asked from now): 0.28's shared-ride matching (`SharedRides.match`, leaving after `after`), without `exclude`;
    /// the earliest that has everyone, else the earliest with the most of you. Nil: none with two or more.
    static func next(_ people: [PersonWays], exclude: String, after: Date) -> SharedRide? {
        let all: [SharedRide] = SharedRides.match(people, .home).filter { $0.trip != exclude && $0.firstDep >= after }
        guard let most = all.map({ $0.riders.count }).max(), most >= 2 else { return nil }
        let best: [SharedRide] = all.filter { $0.riders.count == most }
        return best.min { a, b in a.firstDep != b.firstDep ? a.firstDep < b.firstDep : a.trip < b.trip }
    }

    /// The rides you share now: your trip's (each with the friends whose trip is on that vehicle), and trip cards
    /// you're in (you sent it, or said "I'm in") with the sender and everyone else who's in. Merged by vehicle;
    /// only rides `watched` now and with someone else on them.
    static func shared(mine: [TripCard.Ride], travel: [(from: String, state: TravelState)],
                       cards: [(card: TripCard, riders: [String])], me: String, now: Date) -> [SharedRideRef] {
        var out: [SharedRideRef] = []
        func add(_ ride: TripCard.Ride, _ who: String, _ spots: [TripCard.Spot]?) {
            guard who != me else { return }
            if let i = out.firstIndex(where: { $0.ride.trip == ride.trip }) {
                if !out[i].riders.contains(who) { out[i].riders.append(who) }
                if let spots, out[i].spots[who] == nil { out[i].spots[who] = spots }
            } else {
                var r = SharedRideRef(ride: ride, riders: [who])
                if let spots { r.spots[who] = spots }
                out.append(r)
            }
        }
        for r in mine where watched(r, now: now) {
            for t in travel where t.state.trip == r.trip {
                add(r, t.from, [spot(t.state.from), spot(t.state.to)])
            }
        }
        for c in cards {
            guard let s = TripTake.shared(c.card), watched(s, now: now) else { continue }
            // (your own ride on it when your trip has it: where you get on)
            let ride: TripCard.Ride = mine.first { $0.trip == s.trip } ?? s
            for who in c.riders { add(ride, who, [s.from, s.to]) }
        }
        return out.filter { !$0.riders.isEmpty }
    }

    static func spot(_ s: TravelState.Spot) -> TripCard.Spot { TripCard.Spot(name: s.name, lat: s.lat, lon: s.lon) }

    /// Who's in on a card: the sender and everyone who said "I'm in" (not "Can't"); you count only when you are.
    static func riders(sender: String, answers: [String: TripAnswer], me: String) -> [String]? {
        let yes: [String] = answers.filter { $0.value == .yes }.map(\.key).sorted()
        let all: [String] = [sender] + yes.filter { $0 != sender }
        guard all.contains(me) else { return nil }
        return all.filter { $0 != me }
    }
}

/// The words for a delay.
enum DelayWords {
    /// "IC 3512 is 6 min late", "Bus 305 is cancelled".
    static func title(_ d: RideDelay) -> String {
        d.isCancelled ? "\(d.ride.label) is cancelled" : "\(d.ride.label) is \(d.late) min late"
    }

    /// "You, Lisa and Sam are on it. It now leaves Eindhoven Centraal at 07:47. Next you can all take: IC 3516 at
    /// 08:11 from Eindhoven Centraal."
    static func body(_ d: RideDelay, names: [String]) -> String {
        var parts: [String] = []
        if !names.isEmpty {
            let list: String = CompareWords.names(names)
            parts.append("\(TravelWords.capitalFirst(list)) \(names.count == 1 && names[0] != "you" ? "is" : "are") on it.")
        }
        if !d.isCancelled { parts.append("It now leaves \(d.ride.from.name) at \(TimetableDays.hhmm(d.ride.dep)).") }
        if let n = d.next {
            parts.append("Next you can all take: \(n.label) at \(TimetableDays.hhmm(n.dep)) from \(n.from.name).")
        } else if d.isCancelled {
            parts.append("Look for another way in Fastest trip.")
        }
        return parts.joined(separator: " ")
    }
}

// MARK: wake-up buddy

/// The body of a `buddy` box (slot `buddy`, ttl 36 h): "Tell Sam if I haven't left yet", from the friend who allows
/// it, with their plan for the day and when they left. `on: false` takes it back.
struct BuddyPlan: Codable, Equatable {
    var on: Bool
    /// The plan's day (yyyy-MM-dd, Europe/Amsterdam).
    var day: String? = nil
    /// When they plan to leave the door.
    var leave: Date? = nil
    /// The first bus or train of it (0.27's ride).
    var ride: TripCard.Ride? = nil
    /// When they left (or started moving) that day.
    var left: Date? = nil
}

struct BuddySeen: Codable, Equatable {
    var plan: BuddyPlan
    var t: Int
    var got: Date
}

enum BuddyRules {
    static let slot = "buddy"
    static let ttl = 36 * 3600
    /// Told once they're this late leaving.
    static let grace: TimeInterval = 5 * 60
    /// …until this long after their ride (or after `grace` + this when there's no ride).
    static let window: TimeInterval = 10 * 60
    /// A plan goes again after this even when it didn't change.
    static let refresh: TimeInterval = 12 * 3600
    /// "Left": a trip started, or this far from home.
    static let awayMetres = 400.0

    /// Someone's plan for `today`: their own (the buddy box) first, else a trip card they're in (they sent it: its
    /// start; they said "I'm in": 15 minutes before the shared ride, as they come from elsewhere).
    static func plan(_ b: BuddyPlan?, cards: [(card: TripCard, sent: Bool)], today: String) -> (leave: Date, ride: TripCard.Ride?)? {
        if let b, b.on, b.day == today, let l = b.leave { return (l, b.ride) }
        var best: (leave: Date, ride: TripCard.Ride?)? = nil
        for c in cards {
            guard let s = TripTake.shared(c.card), TimetableDays.key(s.dep) == today else { continue }
            let first: TripCard.Ride = c.card.first ?? s
            let leave: Date = c.sent ? (c.card.start ?? first.dep) : s.dep.addingTimeInterval(-15 * 60)
            let ride: TripCard.Ride = c.sent ? first : s
            if best == nil || leave < best!.leave { best = (leave, ride) }
        }
        return best
    }

    /// Moving already: they left (the buddy box), or a trip or a wait of theirs came, since an hour before they'd leave.
    static func moving(left: Date?, seen: [Date], leave: Date) -> Bool {
        let since: Date = leave.addingTimeInterval(-60 * 60)
        if let left, left >= since { return true }
        return seen.contains { $0 >= since }
    }

    /// Time to tell you: on the day, `grace` after they should have left, until `window` after their ride, not
    /// moving, and not told yet today.
    static func alert(leave: Date, ride: TripCard.Ride?, moving: Bool, told: String?, today: String, now: Date) -> Bool {
        guard !moving, told != today, TimetableDays.key(leave) == today else { return false }
        let start: Date = leave.addingTimeInterval(grace)
        let base: Date = max(ride?.dep ?? start, start)
        return now >= start && now <= base.addingTimeInterval(window)
    }

    /// Your own plan goes again: it changed, or `refresh` went by.
    static func due(last: BuddyPlan?, lastAt: Date?, next: BuddyPlan, now: Date) -> Bool {
        guard let last, let lastAt else { return true }
        if last != next { return true }
        return now.timeIntervalSince(lastAt) >= refresh
    }
}

enum BuddyWords {
    /// "Lisa isn't moving yet — their train is at 07:41", "Lisa isn't moving yet — they planned to leave at 07:20".
    static func title(_ name: String, leave: Date, ride: TripCard.Ride?) -> String {
        guard let r = ride else { return "\(name) isn’t moving yet — they planned to leave at \(TimetableDays.hhmm(leave))" }
        let what: String = r.isTrain ? "train" : "bus"
        return "\(name) isn’t moving yet — their \(what) is at \(TimetableDays.hhmm(r.dep))"
    }

    static func body(_ name: String, leave: Date, ride: TripCard.Ride?) -> String {
        var t = "\(name) planned to leave at \(TimetableDays.hhmm(leave))"
        if let r = ride { t += " for the \(r.label) from \(r.from.name)" }
        return t + ". Maybe send a message?"
    }
}

// MARK: who's on campus

/// The body of a `campus` box (slot `campus`): you're at your school now, without where exactly. `on: false` takes it
/// back (you left, or turned it off).
struct CampusState: Codable, Equatable {
    var on: Bool
    /// The school's short name ("BUas").
    var school: String? = nil
    var since: Date? = nil
    /// Gone by itself then (at most 10 h after `since`).
    var until: Date? = nil
}

struct CampusSeen: Codable, Equatable {
    var state: CampusState
    var t: Int
    var got: Date
}

/// What you posted, so it's taken back when you leave.
struct CampusPosted: Codable, Equatable {
    var since: Date
    var until: Date
    var to: [String]
}

enum CampusRules {
    static let slot = "campus"
    static let maxStay: TimeInterval = 10 * 3600
    /// Outside once this much past the school's radius (so standing at its edge doesn't flap).
    static let margin = 150.0
    /// A position at most this old counts.
    static let fixAge: TimeInterval = 10 * 60
    static let offTTL = 3600

    /// Inside (within `radius`), outside (past `radius` + `margin`), else as it was; nil: no position.
    static func inside(distance: Double?, radius: Double, was: Bool) -> Bool? {
        guard let distance else { return nil }
        if distance <= radius { return true }
        if distance > radius + margin { return false }
        return was
    }

    enum Action: Equatable {
        /// Post "on campus since …" (to these friends).
        case post(since: Date, to: [String])
        /// Take it back from these.
        case clear([String])
        case none
    }

    /// `on`: your switch. `inside`: where you are (nil: not known). `since`: when you got there. Posted once per
    /// stay, to friends who haven't had it; taken back when you leave, turn it off, or after 10 hours (then not again
    /// until you've left and come back).
    static func decide(on: Bool, inside: Bool?, since: Date?, posted: CampusPosted?, friends: [String], now: Date) -> Action {
        if let p = posted {
            let leave: Bool = !on || inside == false || now >= p.until
            if leave { return p.to.isEmpty ? .none : .clear(p.to) }
            let more: [String] = friends.filter { !p.to.contains($0) }
            return more.isEmpty ? .none : .post(since: p.since, to: more)
        }
        guard on, inside == true, let since, now.timeIntervalSince(since) < maxStay, !friends.isEmpty else { return .none }
        return .post(since: since, to: friends)
    }

    static func until(since: Date) -> Date { since.addingTimeInterval(maxStay) }

    /// How long the relay keeps it: to its end (60 s – 10 h).
    static func ttl(until: Date, now: Date) -> Int { max(60, min(Int(maxStay), Int(until.timeIntervalSince(now)))) }

    /// On campus now, as read.
    static func here(_ s: CampusSeen, now: Date) -> Bool {
        guard s.state.on, let until = s.state.until else { return false }
        let since: Date = s.state.since ?? Date(timeIntervalSince1970: TimeInterval(s.t))
        return now < until && until.timeIntervalSince(since) <= maxStay + 60
    }
}

enum CampusWords {
    /// "On campus now: Tom and Lisa".
    static func list(_ names: [String]) -> String { "On campus now: \(CompareWords.names(names))" }

    /// "At BUas since 09:05".
    static func since(_ s: CampusState) -> String {
        let at: String = s.school.map { "At \($0)" } ?? "At school"
        guard let t = s.since else { return at }
        return "\(at) since \(TimetableDays.hhmm(t))"
    }
}

// MARK: your switches

/// The extras' switches (kept with the friend list and in the vault): "Show friends when I'm at school" (off by
/// default) and who may hear you haven't left yet (nobody by default).
struct ExtrasSettings: Codable, Equatable {
    var campus: Bool? = nil
    var buddy: [String]? = nil
}
