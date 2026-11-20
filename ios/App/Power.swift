import Foundation

// What the app does to save the battery and the main thread when nothing needs the work: plain numbers, so it can be
// tested without CoreLocation or ActivityKit. Nothing here makes an alarm later: on a leg, riding toward the stop
// that rings, GPS is always the best there is, and every alarm, phase or vehicle change on the lock screen goes at once.

/// The GPS a trip (or what's watched without one) needs right now: one decision, from the trip's phase and what's open.
enum GPSPolicy {
    enum Phase: Equatable { case idle, riding, transfer, finished }
    enum Accuracy: Equatable { case best, tenMetres, hundredMetres }

    struct Plan: Equatable {
        let on: Bool
        let accuracy: Accuracy
        let filter: Double              // metres between fixes (distanceFilter)
        /// Also with the phone locked (and the blue location pill).
        var background: Bool { on }

        static let off = Plan(on: false, accuracy: .best, filter: 25)
        static func best(_ filter: Double) -> Plan { Plan(on: true, accuracy: .best, filter: filter) }
        static func coarse(_ filter: Double) -> Plan { Plan(on: true, accuracy: .hundredMetres, filter: filter) }
        static func ten(_ filter: Double) -> Plan { Plan(on: true, accuracy: .tenMetres, filter: filter) }
    }

    /// - Parameters:
    ///   - phase: the trip's phase (on a leg: riding, however far from its stop)
    ///   - demo: the pretend ride, which doesn't use GPS
    ///   - going: Fastest trip is open
    ///   - lineWatch: a bus line is watched
    ///   - regionLook: you just left one of your stations, and it looks for what you're on
    ///   - rideFar: on a leg, far from its stop with the vehicle confirmed (`RideGPS.far`, 0.20.7): 10 m, every 75 m
    ///   - goCoarse: Fastest trip, standing with long to go (`GoGPS.coarse`, 0.20.7): 100 m, every 50 m
    ///   - waitLow: waiting for the one you get on (a leg's first stop, or a change) while Motion & Fitness says you
    ///     stand or walk about and the fixes agree (`MotionRules.waitLow`, 0.33): 100 m, every 50 m
    /// At a change it stays the best while standing still without Motion & Fitness: a coarse fix could see the next one
    /// you get on (an earlier one than listed, a late one without live times) more than one look later. With it, the
    /// word "automotive" (or a fix that moves) brings the best back at once.
    static func plan(phase: Phase, demo: Bool, going: Bool, lineWatch: Bool, regionLook: Bool,
                     rideFar: Bool = false, goCoarse: Bool = false, waitLow: Bool = false) -> Plan {
        if demo { return .off }
        switch phase {
        case .riding:
            if waitLow { return .coarse(50) }
            return rideFar ? .ten(75) : .best(25)                   // the best near the stop, and whenever in doubt
        case .transfer: return waitLow ? .coarse(50) : .best(25)
        case .finished: return .off
        case .idle:
            if going { return goCoarse ? .coarse(50) : .best(10) }
            if regionLook { return .best(25) }                      // (the look's matching wants good fixes)
            if lineWatch { return .coarse(30) }
            return .off
        }
    }
}

/// At a change, waiting for the next bus or train: an end to a trip whose connection you didn't take, an hour after the
/// last one you could have, while you stand about at the change.
enum TransferPolicy {
    static let stillSpeed = 2.0 / 3.6               // ≤ 2 km/h is standing (still)
    static let movedMetres = 60.0                    // further than this from where you stood (plus the fix's accuracy over 50 m)
    static let giveUpAfter: TimeInterval = 3600      // an hour after the last one you could take…
    static let standFor: TimeInterval = 600          // …while you've stood at the change for 10 minutes: the trip ends

    /// Where you've been standing since when.
    struct Anchor: Equatable {
        let p: GeoPoint
        let since: Date
    }

    /// The anchor after a new fix: the same while you stand (a fix with an unknown or bad accuracy says nothing), a new
    /// one from this fix once you move (a known speed over 2 km/h, or further than 60 m from it: more for a rough fix).
    static func update(_ a: Anchor?, with f: Fix) -> Anchor? {
        guard f.accuracy.isFinite, f.accuracy >= 0, f.accuracy < 150 else { return a }
        let here = Anchor(p: f.p, since: f.t)
        guard let a else { return here }
        let moving = f.speed.isFinite && f.speed > stillSpeed
        let far = Geo.metres(a.p, f.p) > movedMetres + max(0, f.accuracy - 50)
        return moving || far ? here : a
    }

    /// One departure listed for the next leg.
    struct Listed: Equatable {
        let id: String
        let departure: Date
    }

    /// The first departure listed for the next leg after you got there: taken from the first live list that has one,
    /// then kept at its live time while it's still listed (a late one moves the clock on). Gone from the list:
    /// - older than where the list starts (`listFrom`, the time it was asked from): it aged out, it stays as it was, so
    ///   the clock doesn't slide on to the next one;
    /// - else it was dropped (cancelled: the planner leaves those out), and the next one listed at or after it (and
    ///   after you got there) counts instead; none: it stays as it was.
    static func firstListed(_ latched: Listed?, live list: [Listed], arrived: Date, listFrom: Date) -> Listed? {
        func first(from t: Date) -> Listed? { list.filter { $0.departure >= t }.min { $0.departure < $1.departure } }
        guard let l = latched else { return first(from: arrived) }
        if let now = list.first(where: { $0.id == l.id }) { return now }
        if l.departure < listFrom { return l }
        return first(from: max(arrived, l.departure)) ?? l
    }

    static let departureGrace: (before: TimeInterval, after: TimeInterval) = (60, 180)

    /// The trip ends an hour after the latest of: you got there (`since`), and the departures known for the next leg
    /// (`firstKnown`: the planned one, the first listed after you got there), and only while you've stood at the change
    /// (`standingSince`, the anchor) for 10 minutes; never from a minute before to 3 minutes after one listed for the
    /// next leg leaves (`listed`: you may be sitting on it, waiting for it to go).
    static func giveUp(since: Date, firstKnown: Date?, standingSince: Date?, listed: [Date] = [], now: Date) -> Bool {
        guard let s = standingSince, now.timeIntervalSince(s) >= standFor else { return false }
        if listed.contains(where: { now >= $0.addingTimeInterval(-departureGrace.before) && now <= $0.addingTimeInterval(departureGrace.after) }) {
            return false
        }
        let from = max(since, firstKnown ?? since)
        return now.timeIntervalSince(from) >= giveUpAfter
    }
}

/// After the last stop ("You're there"): the keep-alive sound and the music look stop once the arrival chime has played;
/// the finished trip ends by itself after a while.
enum AfterArrival {
    static let quietAfter: TimeInterval = 20         // the jingle and the announcement are done by then
    static let endAfter: TimeInterval = 600          // 10 minutes

    static func quiet(finishedAt: Date, now: Date) -> Bool { now.timeIntervalSince(finishedAt) >= quietAfter }
    static func end(finishedAt: Date, now: Date) -> Bool { now.timeIntervalSince(finishedAt) >= endAfter }
}

/// How often the Live Activity is updated (0.20.7): only when what it shows really changed, and then at most every
/// 30 s while riding (the countdown is a timer text on the lock screen: it runs without updates). A change of what it
/// says you should do (waking, ringing, the change, arriving, the vehicle) goes at once.
enum ActivityThrottle {
    static let every: TimeInterval = 30

    /// `changed`: what it shows changed; `phaseChanged`: what it says (the title, awake, ringing, the kicker) changed.
    static func send(changed: Bool, phaseChanged: Bool, sinceLast: TimeInterval) -> Bool {
        if phaseChanged { return true }
        return changed && (sinceLast >= every || sinceLast < 0)
    }

    /// A change held back now goes in this many seconds (when nothing newer has gone by then).
    static func later(sinceLast: TimeInterval) -> TimeInterval { min(every, max(1, every - sinceLast)) }

    /// The progress as the update key counts it: in 5% steps.
    static func progressStep(_ p: Double) -> Int { p.isFinite ? Int((min(1, max(0, p)) * 20).rounded()) : 0 }
}

/// One `/v1/map/trips` answer for the next look too, while you haven't really moved: within 10 s and 50 m of where it
/// was asked. Only for looks that start nothing on their own clock (Fastest trip watching for you to get on, a watched
/// line): never on a ride or at a change, where matching drives the alarm's trip.
/// At bus or train speed (0.20.7, `speed`): also from as far as that speed goes in that time (the box asked is a few
/// km across, and the trips in it by their times move on their own).
enum MapReuse {
    static let seconds: TimeInterval = 10
    static let metres = 50.0

    static func usable(age: TimeInterval, movedMetres: Double, allowed: Bool, speed: Double = 0) -> Bool {
        let v = speed.isFinite ? min(60, max(0, speed)) : 0
        return allowed && age >= 0 && age <= seconds && movedMetres.isFinite && movedMetres >= 0 && movedMetres <= metres + v * age
    }
}

/// The GPS speed the screens show: a new one only when it's worth drawing again (from or to unknown, across 1 m/s where
/// the ride screen shows "standing still", or half a metre a second off), not on every fix.
enum SpeedPublish {
    static func worth(old: Double?, new: Double?) -> Bool {
        switch (old, new) {
        case (nil, nil): return false
        case (nil, _), (_, nil): return true
        case let (a?, b?): return abs(a - b) >= 0.5 || (a > 1) != (b > 1)
        }
    }
}

/// One region the app watches (your stations, BUas).
struct RegionSpec: Equatable {
    let id: String
    let lat: Double
    let lon: Double
    let radius: Double
    let entry: Bool
    let exit: Bool
}

enum RegionPlan {
    /// The regions watched now are the ones wanted (same ids, centres, radii and what they tell): nothing to register
    /// again. (iOS keeps them across launches.)
    static func same(wanted: [RegionSpec], current: [RegionSpec]) -> Bool {
        guard wanted.count == current.count else { return false }
        var byId: [String: RegionSpec] = [:]
        for c in current { byId[c.id] = c }
        guard byId.count == current.count else { return false }
        return wanted.allSatisfy { w in
            guard let c = byId[w.id] else { return false }
            return abs(c.lat - w.lat) < 1e-6 && abs(c.lon - w.lon) < 1e-6 && abs(c.radius - w.radius) < 0.5
                && c.entry == w.entry && c.exit == w.exit
        }
    }
}
