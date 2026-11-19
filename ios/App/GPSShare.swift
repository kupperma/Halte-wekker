import Foundation

// 0.32: Help improve Haltewekker › Share GPS points during rides (off unless you turn it on). While a trip runs, a GPS
// point every few seconds is kept on the phone; when the trip ends the first and last 500 m of it go, and so does every
// point near your places (Home, School, the others you saved). What's left goes with the ride-log uploads, tagged with
// the leg and the vehicle as the log lines name them, so the two line up. Plain values, so every rule can be tested.

/// Who makes the app, and so who gets what's shared. (One place for the name, for every text that says it.)
enum Maker {
    static let name = "Nana"
}

/// One GPS point as it leaves the phone: its time (unix seconds, to 0.1 s), where (5 decimals: about a metre), its
/// accuracy (m), speed (m/s) and course (degrees), -1 when the phone didn't know them; the leg ("1/3") and the vehicle
/// ("bus 305·7821") as the log lines name them, and the trip's random id.
struct SharedFix: Codable, Equatable, Sendable {
    var t: Double
    var lat: Double
    var lon: Double
    var acc: Double
    var spd: Double
    var crs: Double
    var leg: String?
    var veh: String?
    var ride: String?

    var point: GeoPoint { GeoPoint(lat: lat, lon: lon) }
}

/// The trip that's running: its random id and its points so far (not trimmed yet: that needs its end).
struct GPSShareRide: Codable, Equatable, Sendable {
    var ride: String
    var fixes: [SharedFix] = []
}

/// What's kept on the phone between uploads: the trip that's running, and the trimmed points of trips that ended,
/// oldest first, waiting to go.
struct GPSShareQueue: Codable, Equatable, Sendable {
    var current: GPSShareRide?
    var ready: [SharedFix] = []

    /// Read back defensively: a broken copy is an empty queue.
    static func decode(_ data: Data?) -> GPSShareQueue {
        guard let data, let q = try? JSONDecoder().decode(GPSShareQueue.self, from: data) else { return GPSShareQueue() }
        return q
    }
}

enum GPSShareRules {
    /// At most one point this often (s).
    static let every: TimeInterval = 3
    /// A worse fix isn't kept (the matcher leaves it out too).
    static let maxAccuracy = 150.0
    /// The first and the last this many metres of every trip go.
    static let trimEnds = 500.0
    /// Nothing within this many metres of one of your places goes.
    static let zoneRadius = 500.0
    /// One trip keeps at most this many points (5 hours at one every 3 s); later ones are dropped.
    static let maxRide = 6000
    /// Waiting to go: at most this many (the oldest go first when there are more).
    static let maxReady = 20000
    /// Bytes of points (as JSON) in one upload, and in a day.
    static let perUpload = 600 * 1024
    static let perDay = 4 * 1024 * 1024
    /// Characters a vehicle tag may have (and which: the relay leaves out any other).
    static let maxTag = 40

    private static func round(_ x: Double, _ digits: Double) -> Double {
        let k = pow(10, digits)
        return (x * k).rounded() / k
    }

    /// A vehicle tag the relay takes: letters, digits, spaces and `·.+/_'()?-`, at most 40 characters.
    static func tag(_ s: String?) -> String? {
        guard let s else { return nil }
        let allowed = CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: " ·.+/_'()?-"))
        let clean = String(String.UnicodeScalarView(s.unicodeScalars.map { allowed.contains($0) ? $0 : "-" })).prefix(maxTag)
        let t = clean.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    /// A fix as it's kept: rounded, the tags made safe. Nil: not a usable fix (no place, too rough).
    static func fix(at: Date, lat: Double, lon: Double, accuracy: Double, speed: Double, course: Double,
                    leg: String?, vehicle: String?, ride: String?) -> SharedFix? {
        guard lat.isFinite, lon.isFinite, abs(lat) <= 90, abs(lon) <= 180, !(lat == 0 && lon == 0),
              accuracy.isFinite, accuracy >= 0, accuracy <= maxAccuracy else { return nil }
        let t = at.timeIntervalSince1970
        guard t.isFinite, t > 1.5e9 else { return nil }
        return SharedFix(t: round(t, 1), lat: round(lat, 5), lon: round(lon, 5), acc: round(accuracy, 0),
                         spd: speed.isFinite && speed >= 0 ? round(min(speed, 200), 1) : -1,
                         crs: course.isFinite && course >= 0 ? round(min(course, 360), 0) : -1,
                         leg: leg, veh: tag(vehicle), ride: ride)
    }

    /// "1/3": the leg as the log lines say it (nil with no legs).
    static func leg(index: Int, count: Int) -> String? {
        guard count > 0, index >= 0 else { return nil }
        return "\(min(index, count - 1) + 1)/\(count)"
    }

    /// Whether a new fix is kept after the last one kept: `every` seconds on (a clock that stepped back starts again).
    static func keep(_ f: SharedFix, after last: SharedFix?) -> Bool {
        guard let last else { return true }
        let gap = f.t - last.t
        return gap < 0 || gap >= every - 0.05
    }

    /// The points of a trip as they may go: none of the first `ends` metres travelled, none of the last, and none within
    /// `ends` (in a straight line) of where it started or ended. Oldest first, as given.
    static func trimmed(_ fixes: [SharedFix], ends: Double = trimEnds) -> [SharedFix] {
        let sorted = fixes.sorted { $0.t < $1.t }
        guard let first = sorted.first, let last = sorted.last else { return [] }
        var along: [Double] = [0]
        for i in sorted.indices.dropFirst() { along.append(along[i - 1] + Geo.metres(sorted[i - 1].point, sorted[i].point)) }
        let total = along.last ?? 0
        return sorted.indices.filter { i in
            along[i] >= ends && total - along[i] >= ends
                && Geo.metres(sorted[i].point, first.point) > ends && Geo.metres(sorted[i].point, last.point) > ends
        }.map { sorted[$0] }
    }

    /// None within `radius` of one of your places.
    static func outsideZones(_ fixes: [SharedFix], zones: [GeoPoint], radius: Double = zoneRadius) -> [SharedFix] {
        let real = zones.filter { $0.lat.isFinite && $0.lon.isFinite && !($0.lat == 0 && $0.lon == 0) }
        return fixes.filter { f in !real.contains { Geo.metres($0, f.point) <= radius } }
    }

    /// A trip that ended: its points as they may go.
    static func finished(_ ride: GPSShareRide, zones: [GeoPoint]) -> [SharedFix] {
        outsideZones(trimmed(ride.fixes), zones: zones)
    }

    /// Bytes one point takes in an upload (its JSON and the comma before it).
    static func size(_ f: SharedFix) -> Int {
        ((try? JSONEncoder().encode(f))?.count ?? 200) + 1
    }

    /// The oldest waiting points that fit in `budget` bytes.
    static func batch(_ ready: [SharedFix], budget: Int) -> (fixes: [SharedFix], bytes: Int, more: Bool) {
        var out: [SharedFix] = [], bytes = 0
        let limit = max(0, budget)
        for f in ready {
            let s = size(f)
            if bytes + s > limit { return (out, bytes, true) }
            out.append(f)
            bytes += s
        }
        return (out, bytes, false)
    }

    /// Bytes of points still allowed now: 600 KB, less near the day's 4 MB.
    static func budget(_ s: LogShareState, today: String) -> Int {
        let used = s.day == today ? (s.fixBytesToday ?? 0) : 0
        return max(0, min(perUpload, perDay - used))
    }

    /// A new random id for a trip (8 hex).
    static func rideId(random: (Int) -> [UInt8] = LogShareState.randomBytes) -> String { LogShareState.hex(random(4)) }
}

extension GPSShareQueue {
    /// A fix heard while a trip runs: into the trip's points (a new trip with `newRide` when none runs yet), every few
    /// seconds, up to `maxRide`.
    mutating func heard(_ f: SharedFix, newRide: () -> String) {
        var r = current ?? GPSShareRide(ride: newRide())
        guard r.fixes.count < GPSShareRules.maxRide, GPSShareRules.keep(f, after: r.fixes.last) else { current = r; return }
        var tagged = f
        tagged.ride = r.ride
        r.fixes.append(tagged)
        current = r
    }

    /// The trip ended: its points trimmed (`GPSShareRules.finished`) join those waiting; the oldest go past `maxReady`.
    mutating func finishRide(zones: [GeoPoint]) {
        guard let r = current else { return }
        current = nil
        ready += GPSShareRules.finished(r, zones: zones)
        if ready.count > GPSShareRules.maxReady { ready.removeFirst(ready.count - GPSShareRules.maxReady) }
    }

    /// The first `n` waiting points went.
    mutating func sent(_ n: Int) {
        ready.removeFirst(min(max(0, n), ready.count))
    }
}

/// The question "Help improve Haltewekker" (0.32): in the first-run setup, and once, as a card, for someone whose setup
/// was done before it was asked there.
enum ShareAsk {
    /// It was answered (or put away): the card doesn't come back.
    static let askedKey = "share.asked.v1"

    /// The card on the home and at the top of Settings: once the setup is done, until it's answered or put away. Not
    /// while trying the setup as a new user (that setup asks itself).
    static func showCard(setupDone: Bool, asked: Bool, testLive: Bool) -> Bool {
        setupDone && !asked && !testLive
    }

    /// What it says, in full (the setup's step and the card).
    static let intro = "Haltewekker is made by \(Maker.name). If you like, this iPhone sends \(Maker.name) a little about your rides, so the app picks the right bus or train more often. It’s optional: both are off unless you turn them on, and you can change it any time in Settings › Help improve Haltewekker."
    static let logsTitle = "Share ride logs"
    static let logsText = "After each trip: how the app picked your bus or train and how the ride went (line numbers, distances in metres, what it decided). Never your places’ names, your friends or your account."
    static let fixesTitle = "Share GPS points during rides"
    static let fixesText = "Only while a trip runs: where the phone was every few seconds (time, place to about a metre, accuracy, speed and direction), with the leg and the bus or train it was on. The first and last 500 m of every trip are left out, and so is anything within 500 m of Home, School or another place you saved."
    /// A point as it's sent (made up), for Settings › What's sent and the docs.
    static let sampleFix = #"{"t":1763534038.2,"lat":51.69012,"lon":5.29871,"acc":8,"spd":12.4,"crs":87,"leg":"1/3","veh":"bus 305·7821","ride":"3f9a1c2e"}"#
    static let who = "It goes to \(Maker.name) only, under a random id made for this (not your Friends account), and is deleted after 60 days. Not during a trip, in Low Data Mode or in Low Power Mode. “Delete what I sent” in Settings › Help improve Haltewekker deletes it all at once."
}
