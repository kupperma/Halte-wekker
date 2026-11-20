import Foundation

// 0.33: wake by time on trains (and fast buses). Before, the alarm rang at a fixed distance before a leg's last stop
// (a train 5 km, a bus 2 km). Now it also rings once the time to your stop is N minutes or less (a train 3, a bus 2;
// Settings › Trips & alarm › "Wake me … before my stop"), by the stop's live arrival while that's fresh and could be
// right, else by the distance left along the route at your smoothed speed. The distance rule stays as it was, the
// safety net: whichever comes first, so never later than it. Plain values, so it can be tested (and replayed).

/// How the alarm before your stop is timed.
enum WakeBy: String, CaseIterable, Sendable { case time, distance }

/// Settings › Trips & alarm › "Wake me … before my stop".
struct WakeSettings: Equatable, Sendable {
    var by: WakeBy = .time
    var trainMinutes = 3
    var busMinutes = 2

    static let byKey = "wake.by"
    static let trainKey = "wake.trainMin"
    static let busKey = "wake.busMin"
    static let range = 1...10

    func minutes(isTrain: Bool) -> Int { isTrain ? trainMinutes : busMinutes }

    static func load(_ d: UserDefaults = .standard) -> WakeSettings {
        func mins(_ k: String, _ fallback: Int) -> Int {
            guard let v = d.object(forKey: k) as? Int else { return fallback }
            return min(range.upperBound, max(range.lowerBound, v))
        }
        let by = d.string(forKey: byKey).flatMap(WakeBy.init(rawValue:)) ?? .time
        return WakeSettings(by: by, trainMinutes: mins(trainKey, 3), busMinutes: mins(busKey, 2))
    }

    func save(_ d: UserDefaults = .standard) {
        d.set(by.rawValue, forKey: Self.byKey)
        d.set(trainMinutes, forKey: Self.trainKey)
        d.set(busMinutes, forKey: Self.busKey)
    }
}

/// Your speed, smoothed (a time constant of 30 s), for the time to your stop: one fast or slow fix doesn't move it
/// much, a halt at a station brings it down within a minute. Not known until it has 20 s of readings, nor once it has
/// had none for 90 s.
struct SpeedSmoother: Equatable, Sendable {
    static let tau: TimeInterval = 30
    static let gap: TimeInterval = 90
    static let warmUp: TimeInterval = 20
    /// m/s: faster than this is a GPS glitch.
    static let ceiling = 100.0

    private(set) var value: Double?
    private(set) var since: Date?
    private(set) var last: Date?

    mutating func add(_ speed: Double, at t: Date) {
        guard speed.isFinite, speed >= 0, speed <= Self.ceiling else { return }
        guard let v = value, let l = last, t.timeIntervalSince(l) <= Self.gap else {
            value = speed; since = t; last = t
            return
        }
        let dt = t.timeIntervalSince(l)
        guard dt > 0 else { return }
        let a = 1 - exp(-dt / Self.tau)
        value = v + a * (speed - v)
        last = t
    }

    func speed(now: Date) -> Double? {
        guard let v = value, let s = since, let l = last else { return nil }
        guard now.timeIntervalSince(l) <= Self.gap, l.timeIntervalSince(s) >= Self.warmUp else { return nil }
        return v
    }

    /// The speed a fix says: the GPS's own (from the Doppler shift), else from the previous fix, when both are good
    /// (50 m or better) and 2 s or more apart.
    static func reading(_ f: Fix, previous p: Fix?) -> Double? {
        if f.speed.isFinite, f.speed >= 0 { return f.speed }
        guard let p, f.accuracy >= 0, f.accuracy <= 50, p.accuracy >= 0, p.accuracy <= 50 else { return nil }
        let dt = f.t.timeIntervalSince(p.t)
        guard dt >= 2 else { return nil }
        return Geo.metres(p.p, f.p) / dt
    }
}

/// The distance left to the end of a route (the stops from where you got on to yours), from where you are on it.
enum RouteLeft {
    /// Further than this from the route: it isn't the one you're on (or the stops are wrong).
    static let offRoute = 1500.0

    static func metres(from p: GeoPoint, along path: [GeoPoint]) -> Double? {
        guard path.count >= 2, let pr = Geo.project(p, on: path), pr.crossTrack <= offRoute else { return nil }
        return max(0, Geo.length(path) - pr.along)
    }
}

enum WakeRule {
    /// m/s: 160 km/h. No train here is faster, so N minutes is never further than N minutes at this.
    static let trainTop = 45.0
    /// m/s: 100 km/h.
    static let busTop = 28.0
    /// m/s: slower than this (halting at a station, a jam) there's no time to go by your speed.
    static let minSpeed = 4.0
    /// s: a live arrival this old or newer is fresh (the ride asks for it every minute).
    static let liveFresh: TimeInterval = 150
    /// m: closer than this to the leg's first stop, you haven't left yet (the time rule waits; the distance rule doesn't).
    static let leftStart = 300.0

    enum Source: String, Sendable { case live, speed }

    enum Fire: Equatable, Sendable {
        case distance
        case time(minutes: Int, source: Source, seconds: Double)
    }

    struct Input: Equatable {
        var by: WakeBy
        var minutes: Int
        var isTrain: Bool
        /// Straight-line metres to the leg's stop, from the newest good fix (what the distance rule has always used).
        var metres: Double
        /// Metres left along the route (nil: not known).
        var routeMetres: Double?
        var wakeMetres: Double
        /// The stop's live arrival (nil: none live).
        var liveArrival: Date?
        /// How old the answer with that arrival is.
        var liveAge: TimeInterval?
        /// Your smoothed speed, m/s (nil: not known yet).
        var speed: Double?
        /// How far you are from the leg's first stop (nil: not known).
        var fromStartMetres: Double?
        var now: Date
    }

    /// The distance left: along the route when it's known, never less than straight.
    static func remaining(_ i: Input) -> Double {
        guard let r = i.routeMetres, r.isFinite else { return i.metres }
        return max(i.metres, r)
    }

    static func top(isTrain: Bool) -> Double { isTrain ? trainTop : busTop }

    /// The furthest the time rule rings from: `minutes` at top speed.
    static func reach(isTrain: Bool, minutes: Int) -> Double { Double(max(0, minutes)) * 60 * top(isTrain: isTrain) }

    /// The seconds to your stop, and from what: the live arrival while it's fresh and could be right (in the future,
    /// and not faster than top speed from here); else the distance left at your speed (`minSpeed` or more).
    static func estimate(_ i: Input) -> (seconds: Double, source: Source)? {
        let left = remaining(i)
        if let a = i.liveArrival, let age = i.liveAge, age.isFinite, age >= 0, age <= liveFresh {
            let s = a.timeIntervalSince(i.now)
            if s > 0, left / s <= top(isTrain: i.isTrain) { return (s, .live) }
        }
        if let v = i.speed, v.isFinite, v >= minSpeed { return (left / v, .speed) }
        return nil
    }

    /// Ring now? The distance rule first (as it always was), then, set to by time, the time rule: you've left the leg's
    /// first stop, the distance left is within `reach`, and the estimate is `minutes` or less.
    static func decide(_ i: Input) -> Fire? {
        if i.metres <= i.wakeMetres { return .distance }
        guard i.by == .time, i.minutes > 0 else { return nil }
        if let f = i.fromStartMetres, f.isFinite, f < leftStart { return nil }
        guard remaining(i) <= reach(isTrain: i.isTrain, minutes: i.minutes) else { return nil }
        guard let e = estimate(i), e.seconds <= Double(i.minutes) * 60 else { return nil }
        return .time(minutes: i.minutes, source: e.source, seconds: e.seconds)
    }

    /// For the ride log's ring line: "by time 3 min (live)", "by distance".
    static func log(_ f: Fire) -> String {
        switch f {
        case .distance: return "by distance"
        case .time(let m, let s, _): return "by time \(m) min (\(s.rawValue))"
        }
    }

    /// "3 min before your stop (or 5 km)", "800 m before your stop": what the notifications say it rings.
    static func says(_ s: WakeSettings, isTrain: Bool, wakeMetres: Double) -> String {
        let d = distanceWords(wakeMetres)
        return s.by == .time ? "\(s.minutes(isTrain: isTrain)) min before your stop (or \(d))" : "\(d) before your stop"
    }

    static func distanceWords(_ m: Double) -> String {
        guard m >= 1000 else { return "\(Int((max(0, m) / 10).rounded()) * 10) m" }
        let km = (m / 100).rounded() / 10
        return km == km.rounded() ? "\(Int(km)) km" : String(format: "%.1f km", km)
    }

    /// The wake distance the far GPS tier and its backstop keep clear of (`RideGPS`): by time, the time rule's `reach`
    /// when that's further.
    static func gpsWakeMetres(wakeMetres: Double, _ s: WakeSettings, isTrain: Bool) -> Double {
        guard s.by == .time else { return wakeMetres }
        return max(wakeMetres, reach(isTrain: isTrain, minutes: s.minutes(isTrain: isTrain)))
    }
}
