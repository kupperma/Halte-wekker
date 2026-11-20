import Foundation

// 0.20.7: less battery and less mobile data. Plain numbers, so every rule can be tested without CoreLocation, UIKit or
// ActivityKit. Each slowdown holds only while nothing is due soon, you stand still, or the vehicle you're on is
// confirmed; it gives way at once on movement, doubt or nearness. Nothing here touches the wake or arrival decision,
// the backup alarm, the keep-alive sound or the alarm itself.

/// The open positions feeds (OVapi's buses, NS's trains) during a ride whose vehicle is confirmed: fetched when a look
/// is in doubt, else at most every two minutes.
enum FeedPolicy {
    /// While the ride's vehicle is confirmed, a fetch at most this often.
    static let confirmedEvery: TimeInterval = 120
    /// On doubt: a new fetch, unless the last one is at most this old.
    static let doubtFresh: TimeInterval = 15

    /// The "still the same bus?" look should fetch the positions now, and judge again, before its verdict counts: it
    /// failed or isn't sure, or the vehicle was far from where its times put it. Not when its own GPS kept it already.
    static func fetchOnDoubt(_ verdict: ShownVerdict, farLooks: Int, keptByGPS: Bool) -> Bool {
        if keptByGPS { return false }
        return verdict != .passes || farLooks > 0
    }

    /// Due: never done, done `every` ago or longer, or the clock stepped back.
    static func due(last: Date?, every: TimeInterval, now: Date) -> Bool {
        guard let last else { return true }
        let age = now.timeIntervalSince(last)
        return age < 0 || age >= every
    }
}

/// Fastest trip moving at bus or train speed while it can't tell which one you're on: it looks again after 4, 8, 15,
/// then every 30 seconds; something changing (another one it sees you with) starts it over at 4.
enum LookBackoff {
    static let steps: [TimeInterval] = [4, 8, 15, 30]

    struct State: Equatable {
        var looks = 0                   // looks in a row with nothing new
        var key: String?                // what it saw last (the vehicle it thinks you're with)
    }

    /// One more look: counted on while nothing changed, from 1 again when it did.
    static func step(_ s: State, key: String?) -> State {
        key == s.key ? State(looks: s.looks + 1, key: key) : State(looks: 1, key: key)
    }

    /// How long to wait after the looks so far (1: 4 s, 2: 8 s, 3: 15 s, then 30 s).
    static func wait(_ s: State) -> TimeInterval { steps[min(max(0, s.looks - 1), steps.count - 1)] }
}

/// Fastest trip's own pace (0.20.7): in front as before; behind (the app not in front) the plans slow down, the extras
/// wait for the screen, and "Time to go" still comes on the minute.
enum GoPace {
    /// The plan within this of the departure is "soon".
    static let soon: TimeInterval = 12 * 60

    /// Seconds to the next plan: in front 20 (within 12 minutes of the departure) or 40; behind 30 or 60. Never past
    /// the moment "Time to go" is due (a minute before you have to leave), so that one isn't late.
    static func planWait(inFront: Bool, departureIn: TimeInterval?, leaveIn: TimeInterval?) -> TimeInterval {
        let near = (departureIn ?? .infinity) < soon
        var w: TimeInterval = inFront ? (near ? 20 : 40) : (near ? 30 : 60)
        if let l = leaveIn, l.isFinite {
            let toGo = l - 60
            if toGo > 0 { w = min(w, max(2, toGo + 1)) }
        }
        return w
    }

    /// The earlier ways and the latest in time (more requests per plan) only while the screen is in front.
    static func extras(inFront: Bool) -> Bool { inFront }

    static let missedAfter: TimeInterval = 20 * 60
    static let movedEnough = 300.0

    /// Stop watching by itself: the departure it watched first left 20 minutes ago, you haven't moved 300 m since it
    /// opened (the trip didn't happen), and nothing else is wanted (no deadline, or it has passed).
    static func autoStop(watched: Date?, deadline: Date?, movedMetres: Double, now: Date) -> Bool {
        guard let w = watched, now.timeIntervalSince(w) >= missedAfter else { return false }
        guard movedMetres.isFinite, movedMetres < movedEnough else { return false }
        if let dl = deadline, now < dl { return false }
        return true
    }

    /// Opens by itself for a planned trip from this long before you leave (it was from the school alarm, or 45 minutes).
    static let autoOpenLead: TimeInterval = 20 * 60

    /// The window it opens by itself in: from `lead` before you leave until 5 minutes after the first ride leaves.
    static func autoOpen(leave: Date, firstDeparture: Date, now: Date, lead: TimeInterval = autoOpenLead) -> Bool {
        now > leave.addingTimeInterval(-lead) && now < firstDeparture.addingTimeInterval(5 * 60)
    }
}

/// Fastest trip's GPS (0.20.7): rough (100 m) while you have long to go and stand still; the best at once when you move
/// or it's nearly time.
enum GoGPS {
    /// Further than this from when you leave: rough is enough while you stand.
    static let farLead: TimeInterval = 12 * 60
    static let movingSpeed = 2.0                  // m/s
    static let spread = 100.0                     // m beyond the fixes' accuracy

    /// Rough GPS now: you leave more than 12 minutes from now and you're standing.
    static func coarse(leaveIn: TimeInterval?, standing: Bool) -> Bool {
        guard standing, let l = leaveIn, l.isFinite else { return false }
        return l > farLead
    }

    /// Standing, by your fixes (newest last): none of the last 3 minutes with a speed of 2 m/s or more, and none further
    /// from the newest than 100 m beyond their accuracy. No fix in those 3 minutes after earlier ones: nothing moved
    /// you far enough for a new one (it comes every 50 m), so still standing. No fixes at all: not known (not standing).
    static func standing(_ fixes: [Fix], now: Date) -> Bool {
        let usable = fixes.filter { $0.accuracy.isFinite && $0.accuracy >= 0 && $0.accuracy < 200 }
        guard !usable.isEmpty else { return false }
        let recent = usable.filter { now.timeIntervalSince($0.t) <= 180 }
        guard let last = recent.last else { return true }
        if recent.contains(where: { $0.speed.isFinite && $0.speed >= movingSpeed }) { return false }
        return !recent.contains { Geo.metres($0.p, last.p) > spread + max($0.accuracy, last.accuracy) }
    }
}

/// A ride's network on one clock (0.20.7): what's due goes together on a 30 s tick, so the radio wakes once.
enum RideTick {
    static let every: TimeInterval = 30
    /// The bus or train's own live times (its stops, its arrival at yours).
    static let vehicleEvery: TimeInterval = 60
    /// How old the ridden trip's `/v5/trip` answer may be for the ride's own looks.
    static let tripCache: TimeInterval = 60
    /// The arrival estimate: every 5 minutes, every 2 minutes when a change is within 15 minutes.
    static let etaFar: TimeInterval = 300
    static let etaNear: TimeInterval = 120
    static let changeNear: TimeInterval = 15 * 60

    static func due(last: Date?, now: Date) -> Bool { FeedPolicy.due(last: last, every: every, now: now) }

    /// `changeIn`: how long until this leg ends at a change (nil: no change after it, or not known).
    static func etaGap(changeIn: TimeInterval?) -> TimeInterval {
        guard let c = changeIn, c.isFinite, c <= changeNear else { return etaFar }
        return etaNear
    }

    /// The song: every 5 s with the ride screen on, 15 s in front, 30 s with the screen off (or another app in front).
    static func musicGap(fast: Bool, inFront: Bool) -> TimeInterval { fast ? 5 : inFront ? 15 : 30 }
}

/// At a change, waiting for the next bus or train (0.20.7): the list every 3 minutes while you stand and the next one
/// leaves more than 10 minutes from now; else every minute, as before. (GPS stays the best: `GPSPolicy`.)
enum ChangePace {
    static let standFor: TimeInterval = 120
    static let farDeparture: TimeInterval = 10 * 60

    /// `standingFor`: how long you've stood where you are (nil: not known); `nextIn`: the next listed departure (nil: none).
    static func gap(standingFor: TimeInterval?, nextIn: TimeInterval?) -> TimeInterval {
        guard let s = standingFor, s >= standFor, let n = nextIn, n.isFinite, n > farDeparture else { return 60 }
        return 180
    }
}

/// The look after leaving one of your stations (0.20.7): not right after a ride ended there (you're walking away from
/// the bus you just got off), unless you're at vehicle speed.
enum RegionLook {
    static let afterArrival: TimeInterval = 20 * 60
    static let vehicleSpeed = 5.0

    static func skip(place: String, lastEnd: (place: String, at: Date)?, speed: Double?, now: Date) -> Bool {
        guard let e = lastEnd, e.place == place else { return false }
        let ago = now.timeIntervalSince(e.at)
        guard ago >= 0, ago < afterArrival else { return false }
        if let v = speed, v.isFinite, v >= vehicleSpeed { return false }
        return true
    }
}

/// The planner's answers, kept 45 s, for one question asked to the minute (0.20.7).
enum PlanMemo {
    static let ttl: TimeInterval = 45

    /// The time rounded down to the minute: two asks a few seconds apart are one question.
    static func minute(_ d: Date) -> Date { Date(timeIntervalSince1970: (d.timeIntervalSince1970 / 60).rounded(.down) * 60) }

    static func key(from: String, to: String, modes: String?, at: Date, count: Int, maxTransfers: Int, arriveBy: Bool) -> String {
        "\(from)>\(to)|\(modes ?? "*")|\(Int(minute(at).timeIntervalSince1970))|\(count)|\(maxTransfers)|\(arriveBy ? "by" : "at")"
    }

    /// The same ids once each, in their order.
    static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}

/// A ride's GPS far from its stop (0.20.7, Settings › "Save battery on long rides"): 10 m accuracy and a fix every
/// 75 m instead of the best and every 25 m, only while all of these hold:
/// - the setting is on, and the leg is still asleep (no wake-up yet, nothing ringing);
/// - the bus or train is confirmed (none to choose between, on its road, near its times, not picked by hand in the
///   ride, not taken by its timetable alone);
/// - a fresh, good fix puts you further from the stop than the wake distance plus 8 minutes at full speed (90 km/h a
///   bus, 140 km/h a train; faster when you are), and a kilometre more to switch it on (0.33: Motion & Fitness saying
///   automotive steadily, `MotionRules.steadyVehicle`: 6 minutes, and no kilometre more);
/// - the stop isn't due within 10 minutes (when its time is known);
/// - the backstop around the stop hasn't been entered.
/// Anything else: the best, at once.
enum RideGPS {
    static let busCruise = 25.0                   // m/s, 90 km/h
    static let trainCruise = 39.0                 // m/s, 140 km/h
    static let travel: TimeInterval = 8 * 60
    /// Steadily in a vehicle by Motion & Fitness (0.33): the far tier from 6 minutes at full speed.
    static let steadyTravel: TimeInterval = 6 * 60
    static let hysteresis = 1000.0                // m more to switch the far tier on than to stay in it
    static let dueSoon: TimeInterval = 10 * 60
    static let freshFix: TimeInterval = 300
    static let goodAccuracy = 100.0
    /// The backstop region around the stop: wake distance plus this (well before the wake point).
    static let backstopMargin = 4000.0
    static let settingKey = "battery.longRides"

    /// The setting: on unless turned off.
    static func enabled(_ d: UserDefaults = .standard) -> Bool { d.object(forKey: settingKey) as? Bool ?? true }

    struct Input: Equatable {
        var enabled = true
        var asleep = true                 // the leg's phase is "sleeping" (not awake, no alarm)
        var confirmed = false
        var metresToStop: Double?         // from your newest good fix
        var accuracy: Double?
        var fixAge: TimeInterval?
        var wakeMetres: Double
        var isTrain: Bool
        var speed: Double?                // your GPS speed, m/s
        var secondsToStop: TimeInterval?  // when it reaches your stop (nil: not known)
        var backstop = false              // the region around the stop was entered
        var wasFar = false                // the far tier is on now
        var steady = false                // Motion & Fitness: automotive for 3 minutes or more (0.33)
    }

    /// Beyond this from the stop the far tier may be on: the wake distance plus 8 minutes at the faster of full speed
    /// and yours.
    static func farFrom(wakeMetres: Double, isTrain: Bool, speed: Double?, steady: Bool = false) -> Double {
        let cruise = isTrain ? trainCruise : busCruise
        let v = max(cruise, speed.flatMap { $0.isFinite ? $0 : nil } ?? 0)
        return max(0, wakeMetres) + v * (steady ? steadyTravel : travel)
    }

    static func backstopRadius(wakeMetres: Double) -> Double { max(0, wakeMetres) + backstopMargin }

    static func far(_ i: Input) -> Bool {
        guard i.enabled, i.asleep, i.confirmed, !i.backstop else { return false }
        guard let d = i.metresToStop, d.isFinite, d >= 0 else { return false }
        guard let a = i.accuracy, a.isFinite, a >= 0, a < goodAccuracy else { return false }
        guard let age = i.fixAge, age.isFinite, age >= 0, age <= freshFix else { return false }
        guard i.wakeMetres.isFinite, i.wakeMetres >= 0 else { return false }
        if let s = i.secondsToStop, !(s.isFinite && s > dueSoon) { return false }
        let line = farFrom(wakeMetres: i.wakeMetres, isTrain: i.isTrain, speed: i.speed, steady: i.steady)
        return d > line + (i.wasFar || i.steady ? 0 : hysteresis)
    }
}

/// The home's on-board look while you move like a bus or train and it hasn't found the one you're on (0.28): 0.26.2
/// looks every ~20 s (`OnBoardRules.lookDue`). After `emptyRun` looks in a row that find nothing (a car, a bike, a
/// train it can't see), it looks every `slowEvery` instead, until you stop moving or start again (or it finds one).
/// Nothing else changes: the look itself, the trips it shows and a running trip's own matching are as they were.
enum OnBoardBackoff {
    static let emptyRun = 6
    static let slowEvery: TimeInterval = 120

    struct State: Equatable {
        /// Looks in a row that found nothing.
        var empty = 0
        /// When the last look ran.
        var last: Date?
    }

    /// One look ran: found one (from scratch) or not (one more in the row).
    static func looked(_ s: State, found: Bool, at now: Date) -> State {
        State(empty: found ? 0 : s.empty + 1, last: now)
    }

    /// You stopped moving, or just started: from scratch.
    static func reset() -> State { State() }

    /// Backing off: six empty looks in a row and the last under two minutes ago (a clock that stepped back doesn't
    /// hold it).
    static func holding(_ s: State, now: Date) -> Bool {
        guard s.empty >= emptyRun, let last = s.last else { return false }
        let age = now.timeIntervalSince(last)
        return age >= 0 && age < slowEvery
    }
}
