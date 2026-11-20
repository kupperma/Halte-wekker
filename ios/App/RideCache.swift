import Foundation

// 0.39: without signal. When a trip starts (and each time its bus or train answers), the trip's rides are saved on the
// phone: every stop with its times and platform, the road it takes, its line. In a tunnel or on bad 5G, when the live
// answer doesn't come, the ride screen, the wake distance and time and the following without GPS (`DeadReckon`) go on
// from the saved copy; once the network is back it asks again. Small and bounded (a few rides, their stops and a thinned
// road), and gone when the trip ends. Plain values, so it can be tested.

/// One ride as saved: its stops and the road it takes.
struct SavedRide: Codable, Equatable, Sendable {
    struct Stop: Codable, Equatable, Sendable {
        var name: String
        var lat: Double
        var lon: Double
        var arrival: Date?
        var departure: Date?
        var scheduled: Date?
        var platform: String?

        var point: GeoPoint { GeoPoint(lat: lat, lon: lon) }
    }

    var tripId: String
    var line: String
    var headsign: String = ""
    var isTrain: Bool
    var live: Bool
    var mode: String = ""
    var savedAt: Date
    var stops: [Stop]
    var shape: [GeoPoint]
}

/// The saved rides of the trip that runs.
struct SavedTrip: Codable, Equatable, Sendable {
    /// When the trip started (the copy is for that trip only).
    var trip: Date
    var rides: [SavedRide] = []
}

enum RideCache {
    static let maxRides = 4
    static let maxStops = 120
    static let maxShape = 400
    /// The whole copy at most (bytes, as JSON).
    static let maxBytes = 160_000
    /// Older than this, a copy is no use (and goes).
    static let maxAge: TimeInterval = 6 * 3600
    /// A ride's copy is written again at most this often.
    static let every: TimeInterval = 120
    /// A saved stop this far from yours isn't it.
    static let near = 1500.0

    /// The road thinned to `limit` points at most: the first and the last kept, the rest evenly picked.
    static func thin(_ path: [GeoPoint], limit: Int = maxShape) -> [GeoPoint] {
        guard limit >= 2, path.count > limit else { return path }
        let last = path.count - 1
        return (0..<limit).map { i in path[Int((Double(i) * Double(last) / Double(limit - 1)).rounded())] }
    }

    /// A ride kept within bounds: at most `maxStops` stops, the road thinned.
    static func bounded(_ r: SavedRide) -> SavedRide {
        var b = r
        if b.stops.count > maxStops { b.stops = Array(b.stops.prefix(maxStops)) }
        b.shape = thin(b.shape)
        return b
    }

    /// The trip's copy with `ride` in it (in place of an older copy of the same ride): for the trip that started at
    /// `trip` (another trip's copy is dropped), the newest `maxRides`.
    static func put(_ ride: SavedRide, into saved: SavedTrip?, trip: Date) -> SavedTrip {
        var s = saved.flatMap { $0.trip == trip ? $0 : nil } ?? SavedTrip(trip: trip)
        s.rides.removeAll { $0.tripId == ride.tripId }
        s.rides.append(bounded(ride))
        if s.rides.count > maxRides { s.rides = Array(s.rides.suffix(maxRides)) }
        return s
    }

    /// The saved copy of a ride, for the trip that runs (started at `trip`) and not older than `maxAge`.
    static func ride(_ tripId: String, in saved: SavedTrip?, trip: Date?, now: Date) -> SavedRide? {
        guard let s = saved, let t = trip, s.trip == t else { return nil }
        return s.rides.last { $0.tripId == tripId && now.timeIntervalSince($0.savedAt) <= maxAge }
    }

    /// Keep the copy? Not when no trip runs, it's another trip's, or it's older than `maxAge`.
    static func keep(_ saved: SavedTrip?, trip: Date?, now: Date) -> Bool {
        guard let s = saved, let t = trip, s.trip == t else { return false }
        return now.timeIntervalSince(t) <= maxAge
    }

    /// Write a ride's copy now: a new ride, or the last copy is `every` old.
    static func due(lastSaved: Date?, now: Date) -> Bool {
        guard let l = lastSaved else { return true }
        return now.timeIntervalSince(l) >= every
    }

    /// The copy as JSON within `maxBytes`: the oldest rides dropped until it fits (nil: not even one fits).
    static func encode(_ s: SavedTrip) -> Data? {
        var t = s
        let enc = JSONEncoder()
        while true {
            guard let d = try? enc.encode(t) else { return nil }
            if d.count <= maxBytes { return d }
            guard t.rides.count > 1 else { return nil }
            t.rides.removeFirst()
        }
    }

    /// Each stop's time as the ride goes by it: the first one when it leaves, the rest when it gets there.
    static func times(_ r: SavedRide) -> [Date?] {
        r.stops.enumerated().map { i, s in i == 0 ? (s.departure ?? s.arrival) : (s.arrival ?? s.departure) }
    }

    /// The saved stop nearest `p` (within `near`), after `from` (nil: any).
    static func stop(near p: GeoPoint, in r: SavedRide, after from: Int? = nil) -> Int? {
        let list = r.stops.indices.filter { from == nil || $0 > from! }
        guard let i = list.min(by: { Geo.metres(r.stops[$0].point, p) < Geo.metres(r.stops[$1].point, p) }),
              Geo.metres(r.stops[i].point, p) <= near else { return nil }
        return i
    }

    /// Minutes late at a stop (live against the timetable, rounded); nil without both, or not live.
    static func delay(_ r: SavedRide, at i: Int) -> Int? {
        guard r.live, r.stops.indices.contains(i), let s = r.stops[i].scheduled else { return nil }
        guard let t = i == 0 ? (r.stops[i].departure ?? r.stops[i].arrival) : (r.stops[i].arrival ?? r.stops[i].departure) else { return nil }
        return Int((t.timeIntervalSince(s) / 60).rounded())
    }

    /// Ask again now: the network is back after it was gone.
    static func backOnline(wasOffline: Bool, online: Bool) -> Bool { wasOffline && online }
}
