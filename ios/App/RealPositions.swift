import Foundation

/// One bus's or train's GPS position as the open data gives it (OVapi's GTFS-Realtime vehicle positions, from KV6; a
/// train's from NS's Virtual Train API, 0.20.3): where it was, which way it pointed, and when.
struct GPSFix: Equatable, Sendable {
    let lat: Double
    let lon: Double
    let bearing: Double?            // degrees, 0 north, when the vehicle sent one
    let at: Date                    // the fix's own time (typically 20–90 s before the feed is fetched)
    var startDate: String? = nil    // its trip's service date, "20261117"
    var stopSequence: Int? = nil    // the stop it's at or going to, as the feed numbers them
    var stopped: Bool? = nil        // standing at that stop (STOPPED_AT)
    var speed: Double? = nil        // m/s, when the source gives one (NS: `snelheid`, km/h)

    var point: GeoPoint { GeoPoint(lat: lat, lon: lon) }
}

/// Real bus positions (0.20.2): reading OVapi's vehicle positions feed, finding a Transitous trip's fix in it, and
/// putting the bus on its road by that fix instead of by its stop times. Trains (0.20.3) from NS's positions of every
/// train, through the relay, by train number. The on-board matcher (0.20.3) judges a vehicle with a fix of at most
/// `matchFresh` by it (`VehicleMatch`).
enum RealPositions {
    static let feedURL = URL(string: "https://gtfs.ovapi.nl/nl/vehiclePositions.pb")!
    static let trainsPath = "/ns/vehicles"          // the relay's route to NS's positions of every train
    static let settingKey = "map.realPositions"     // the Settings switch (default on)

    static let fresh: TimeInterval = 180            // a fix this old or newer is drawn
    static let matchFresh: TimeInterval = 90        // …and this old or newer judged by (the matcher)
    static let maxOffRoute: Double = 150            // m: a fix further than this from its road isn't used
    static let maxAdvance: TimeInterval = 60        // s: a fix is moved on along its road for at most this long
    static let maxSpeed: Double = 30                // m/s: the fastest a piece's times move it (108 km/h)
    static let holdBack: Double = 50                // m: a new fix this little behind what's drawn waits for it
    static let every: TimeInterval = 30             // s between fetches
    static let logEvery: TimeInterval = 300         // s: one log line per kind of outcome at most this often

    // MARK: the feed

    /// What one fetch of the feed gives: each trip's newest fix, by OVapi's trip_id, and the feed's own time.
    struct Feed: Equatable, Sendable {
        var timestamp: Date?
        var fixes: [String: GPSFix] = [:]
        var entities = 0            // vehicle entities read (with or without a usable fix)
    }

    /// The feed's fixes. Never crashes: unknown fields (and OVapi's extensions, field numbers 1000 and up) are
    /// skipped; a message that is cut short or malformed is read up to there, and what was whole before it is kept.
    /// A vehicle without a trip_id or a position is left out; one without its own time has the feed's.
    static func parse(_ data: Data) -> Feed {
        data.withUnsafeBytes { raw -> Feed in
            var feed = Feed()
            var top = ProtoReader(raw, 0, raw.count)
            var entities: [(Int, Int)] = []
            while let f = top.next() {
                switch (f.number, f.value) {
                case (1, .bytes(let s, let e)):
                    var h = ProtoReader(raw, s, e)
                    while let g = h.next() {
                        if g.number == 3, case .varint(let v) = g.value, v > 0, v < 1 << 40 { feed.timestamp = Date(timeIntervalSince1970: TimeInterval(v)) }
                    }
                case (2, .bytes(let s, let e)): entities.append((s, e))
                default: continue
                }
            }
            for (s, e) in entities {
                var ent = ProtoReader(raw, s, e)
                var vehicle: (Int, Int)?
                while let f = ent.next() { if f.number == 4, case .bytes(let a, let b) = f.value { vehicle = (a, b) } }
                guard let (a, b) = vehicle else { continue }
                feed.entities += 1
                guard let (id, fix) = Self.vehicle(raw, a, b, feedTime: feed.timestamp) else { continue }
                if let old = feed.fixes[id], old.at >= fix.at { continue }
                feed.fixes[id] = fix
            }
            return feed
        }
    }

    /// One VehiclePosition: its trip_id and fix.
    private static func vehicle(_ raw: UnsafeRawBufferPointer, _ s: Int, _ e: Int, feedTime: Date?) -> (String, GPSFix)? {
        var tripId: String?, startDate: String?
        var lat: Float?, lon: Float?, bearing: Float?
        var ts: UInt64?, seq: UInt64?, status: UInt64?
        var vp = ProtoReader(raw, s, e)
        while let f = vp.next() {
            switch (f.number, f.value) {
            case (1, .bytes(let a, let b)):
                var t = ProtoReader(raw, a, b)
                while let g = t.next() {
                    if case .bytes(let x, let y) = g.value {
                        if g.number == 1 { tripId = ProtoReader.string(raw, x, y) }
                        if g.number == 3 { startDate = ProtoReader.string(raw, x, y) }
                    }
                }
            case (2, .bytes(let a, let b)):
                var p = ProtoReader(raw, a, b)
                while let g = p.next() {
                    guard case .fixed32(let bits) = g.value else { continue }
                    let v = Float(bitPattern: bits)
                    switch g.number { case 1: lat = v; case 2: lon = v; case 3: bearing = v; default: break }
                }
            case (3, .varint(let v)): seq = v
            case (4, .varint(let v)): status = v
            case (5, .varint(let v)): ts = v
            default: continue
            }
        }
        guard let id = tripId, !id.isEmpty, let lat, let lon, lat.isFinite, lon.isFinite,
              abs(lat) <= 90, abs(lon) <= 180, !(lat == 0 && lon == 0) else { return nil }
        let at: Date
        if let ts, ts > 0, ts < 1 << 40 { at = Date(timeIntervalSince1970: TimeInterval(ts)) }
        else if let feedTime { at = feedTime }
        else { return nil }
        let b = bearing.flatMap { $0.isFinite && $0 >= 0 && $0 <= 360 ? Double($0) : nil }
        return (id, GPSFix(lat: Double(lat), lon: Double(lon), bearing: b, at: at, startDate: startDate,
                           stopSequence: seq.flatMap { $0 < 100_000 ? Int($0) : nil }, stopped: status.map { $0 == 1 }))
    }

    // MARK: which fix is a trip's

    /// The feed's trip_id for a Transitous trip: what follows "nl-OpenOV_" in
    /// "20261117_11:57_nl-OpenOV_374105578". Nil when it isn't an OpenOV trip (those can't be in the feed).
    static func key(_ transitousTripId: String) -> String? {
        guard let r = transitousTripId.range(of: "nl-OpenOV_") else { return nil }
        let k = transitousTripId[r.upperBound...]
        return k.isEmpty ? nil : String(k)
    }

    /// 0.42.3: why a trip with a key has no fix in the feed, for the log: "no ovapi match for trip_id 400100123
    /// (started 22:40)", or before its start ("… : not started yet, starts 23:05": a bus is in the feed only once its
    /// journey has begun). The key is OVapi's own trip_id, the same one the feed carries (checked against the feed: the
    /// trips missing at night were simply not in it, so they go by their times).
    static func noMatchReason(_ transitousTripId: String, key k: String, now: Date) -> String {
        let base: String = "no ovapi match for trip_id \(k)"
        guard let st = startTime(transitousTripId) else { return base }
        if now < st.at { return "\(base): not started yet, starts \(st.text)" }
        return "\(base) (started \(st.text))"
    }

    /// When a Transitous trip starts, from its id ("20261201_22:40_nl-OpenOV_…": the service date and its start, which
    /// may be 24:00 or later for a night bus), in Dutch time, and as written ("22:40"). Nil when the id doesn't say.
    static func startTime(_ transitousTripId: String) -> (at: Date, text: String)? {
        let parts = transitousTripId.split(separator: "_", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, let d = serviceDate(transitousTripId) else { return nil }
        let hm = parts[1].split(separator: ":")
        guard hm.count == 2, let h = Int(hm[0]), let m = Int(hm[1]), h >= 0, h < 48, m >= 0, m < 60 else { return nil }
        guard let y = Int(d.prefix(4)), let mo = Int(d.dropFirst(4).prefix(2)), let da = Int(d.suffix(2)) else { return nil }
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = da; c.hour = 0; c.minute = 0
        guard let midnight = dutch.date(from: c) else { return nil }
        let at: Date = midnight.addingTimeInterval(TimeInterval(h * 3600 + m * 60))
        return (at, String(parts[1]))
    }

    /// The dataset a Transitous trip id comes from ("nl-OpenOV" in "20261201_22:40_nl-OpenOV_400100123"), for the
    /// log; nil when it doesn't say.
    static func dataset(_ transitousTripId: String) -> String? {
        let parts = transitousTripId.split(separator: "_", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count >= 4, serviceDate(transitousTripId) != nil, !parts[2].isEmpty else { return nil }
        return String(parts[2])
    }

    /// The service date a Transitous trip id starts with ("20261117"), if it does.
    static func serviceDate(_ transitousTripId: String) -> String? {
        let d = transitousTripId.prefix { $0 != "_" }
        return d.count == 8 && d.allSatisfy(\.isNumber) ? String(d) : nil
    }

    private static let dutch: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Amsterdam") ?? .current
        return c
    }()

    /// "20261117": a day as the feed writes it, in Dutch time.
    static func day(_ t: Date) -> String {
        let d = dutch.dateComponents([.year, .month, .day], from: t)
        return String(format: "%04d%02d%02d", d.year ?? 0, d.month ?? 0, d.day ?? 0)
    }

    /// The fix to draw a Transitous trip by at `now`, if there's one: in the feed under its key, `fresh` (no older
    /// than 3 minutes, and not more than a minute ahead of the phone's clock), of the same service date as the trip,
    /// and that date today (or yesterday: a night bus after midnight).
    /// `fresh`: the oldest a fix may be (`matchFresh` for the matcher).
    static func usable(_ fixes: [String: GPSFix], tripId: String, now: Date, fresh: TimeInterval = fresh) -> GPSFix? {
        guard let k = key(tripId), let f = fixes[k] else { return nil }
        return usable(f, tripId: tripId, now: now, fresh: fresh)
    }

    /// The same rules for one fix of that trip (a train's, found by its number).
    static func usable(_ f: GPSFix, tripId: String, now: Date, fresh: TimeInterval = fresh) -> GPSFix? {
        let age = now.timeIntervalSince(f.at)
        guard age <= fresh, age >= -60 else { return nil }
        let tripDay = serviceDate(tripId)
        if let a = tripDay, let b = f.startDate, a != b { return nil }
        guard let d = tripDay ?? f.startDate else { return f }
        return d == day(now) || d == day(now.addingTimeInterval(-86_400)) ? f : nil
    }

    /// Each vehicle's fix before its newest, after a new fetch: for a key whose newest fix is newer than the one it had,
    /// the one it had; else the one before it stays (when still older than the newest). For its speed between them.
    static func previous<K: Hashable>(old: [K: GPSFix], previous: [K: GPSFix], new: [K: GPSFix]) -> [K: GPSFix] {
        var out: [K: GPSFix] = [:]
        for (k, f) in new {
            if let o = old[k], o.at < f.at { out[k] = o }
            else if let p = previous[k], p.at < f.at { out[k] = p }
        }
        return out
    }

    // MARK: trains (NS)

    /// A trip of this mode (as the live data names it) is a train NS may have the position of: rail ("REGIONAL_RAIL",
    /// "HIGHSPEED_RAIL", "LONG_DISTANCE", "SUBURBAN"…), not a tram, metro, bus or coach (whose trip numbers aren't NS's).
    static func isRail(mode: String) -> Bool {
        let m = mode.uppercased()
        return m.contains("RAIL") || m == "LONG_DISTANCE" || m == "SUBURBAN" || m == "TRAIN"
    }

    /// The train number in a Transitous trip's short name ("3561", or "IC 3561"): its last group of digits, 1 to 6 of
    /// them, not 0. Nil when there is none.
    static func trainNumber(_ shortName: String) -> Int? {
        let groups = shortName.split { !$0.isNumber }
        guard let last = groups.last, last.count <= 6, last.allSatisfy({ $0.isASCII }), let n = Int(last), n > 0 else { return nil }
        return n
    }

    /// NS's positions of every train (the relay's `/ns/vehicles`: `{"payload":{"treinen":[{"treinNummer":1234,
    /// "lat":51.5,"lng":5.3,"snelheid":120.0,"richting":45.0,…}]}}`), by train number, each at `at` (the answer has no
    /// time of its own). Read defensively: a number may come as a string, a field may be missing (`ritId` stands in for
    /// a missing `treinNummer`); a train without a number or a real place is left out. Nil when it isn't such an answer.
    static func parseTrains(_ data: Data, at: Date) -> [Int: GPSFix]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let payload = json["payload"] as? [String: Any] ?? json
        guard let list = payload["treinen"] as? [Any] else { return nil }
        func number(_ a: Any?) -> Double? {
            if let n = a as? NSNumber { let d = n.doubleValue; return d.isFinite ? d : nil }
            if let s = a as? String, let d = Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")), d.isFinite { return d }
            return nil
        }
        func train(_ a: Any?) -> Int? {
            if let s = a as? String { return trainNumber(s) }
            guard let d = number(a), d >= 1, d < 1_000_000, d == d.rounded() else { return nil }
            return Int(d)
        }
        var out: [Int: GPSFix] = [:]
        for item in list {
            guard let t = item as? [String: Any], let n = train(t["treinNummer"]) ?? train(t["ritId"]),
                  let lat = number(t["lat"]), let lon = number(t["lng"] ?? t["lon"]),
                  abs(lat) <= 90, abs(lon) <= 180, !(lat == 0 && lon == 0) else { continue }
            let kmh = number(t["snelheid"]).flatMap { $0 >= 0 && $0 <= 400 ? $0 : nil }
            let dir = number(t["richting"]).flatMap { $0 >= 0 && $0 <= 360 ? $0 : nil }
            out[n] = GPSFix(lat: lat, lon: lon, bearing: dir, at: at, speed: kmh.map { $0 / 3.6 })
        }
        return out
    }

    // MARK: putting it on its road

    /// A stop-to-stop piece of a vehicle's road, with its times: it leaves the stop at the start at `departure` and
    /// gets to the one at the end at `arrival`. `start`: metres along the whole road where the piece begins (pieces
    /// may leave gaps).
    struct Leg: Equatable, Sendable {
        let start: Double
        let path: [GeoPoint]
        let departure: Date
        let arrival: Date
        let length: Double

        init(start: Double, path: [GeoPoint], departure: Date, arrival: Date) {
            self.start = start; self.path = path; self.departure = departure; self.arrival = arrival
            length = Geo.length(path)
        }

        /// m/s by its times (`maxSpeed` at most; 0 for a piece without length).
        var speed: Double {
            guard length > 0 else { return 0 }
            return min(maxSpeed, length / max(1, arrival.timeIntervalSince(departure)))
        }
    }

    /// Pieces one after another, from 0 m: each starts where the one before ends.
    static func chained(_ pieces: [(path: [GeoPoint], departure: Date, arrival: Date)]) -> [Leg] {
        var out: [Leg] = [], at = 0.0
        for p in pieces {
            let l = Leg(start: at, path: p.path, departure: p.departure, arrival: p.arrival)
            guard l.length > 0 else { continue }
            out.append(l); at += l.length
        }
        return out
    }

    /// Where a fix is on the road: which piece, how far along it, and how far beside it.
    struct Spot: Equatable, Sendable {
        let leg: Int
        let along: Double
        let crossTrack: Double
    }

    /// Metres along the whole road by the times at `t`: on the piece it's on, by time; between pieces, at the end
    /// of the one before; before the first, at its start; after the last, at its end.
    static func timeMetres(_ legs: [Leg], at t: Date) -> Double? {
        guard let first = legs.first else { return nil }
        if t <= first.departure { return first.start }
        var last = first.start
        for l in legs {
            if t < l.departure { return last }
            if t <= l.arrival {
                let f = t.timeIntervalSince(l.departure) / max(1, l.arrival.timeIntervalSince(l.departure))
                return l.start + min(1, max(0, f)) * l.length
            }
            last = l.start + l.length
        }
        return last
    }

    /// The fix on the road: the nearest place on it, when that's within `maxOffRoute`. Where the road passes the fix
    /// more than once (a loop, there and back on the same street), of the passes within 30 m of the nearest, the one
    /// nearest to where its times had it at the fix's own time.
    static func snap(_ fix: GPSFix, on legs: [Leg]) -> Spot? {
        let p = fix.point
        var all: [(spot: Spot, metres: Double)] = []
        for (k, l) in legs.enumerated() where l.length > 0 {
            for pass in Geo.passes(p, on: l.path) where pass.projection.crossTrack.isFinite {
                all.append((Spot(leg: k, along: pass.projection.along, crossTrack: pass.projection.crossTrack), l.start + pass.projection.along))
            }
        }
        guard let nearest = all.map(\.spot.crossTrack).min(), nearest <= maxOffRoute else { return nil }
        let close = all.filter { $0.spot.crossTrack <= min(maxOffRoute, nearest + 30) }
        guard let want = timeMetres(legs, at: fix.at) else { return close.first?.spot }
        return close.min { a, b in
            let da = abs(a.metres - want), db = abs(b.metres - want)
            return da != db ? da < db : a.spot.crossTrack < b.spot.crossTrack
        }?.spot
    }

    // MARK: moving an old fix on (0.34)

    static let maxAdvanceSeen: TimeInterval = 120   // s: moved on this long at most at the pace it was seen going
    static let dwell: TimeInterval = 10             // s it stands at a stop on its way, at least (at its seen pace)
    static let seenMin: TimeInterval = 5            // s: its two fixes at least this far apart…
    static let seenMax: TimeInterval = 180          // …and at most this
    static let seenTop = 46.0                       // m/s: faster than this between two fixes isn't sane (165 km/h)
    static let slackFrom: TimeInterval = 30         // s: a fix older than this gets more room…
    static let slackShare = 0.2                     // …a fifth of what it went since then (its pace may have changed)…
    static let maxSlack = 600.0                     // m: …this much at most

    /// How it's going: the speed it was seen going (`observedSpeed`), and how late it is (`lateness`), when known.
    struct Pace: Equatable, Sendable {
        var speed: Double? = nil
        var late: TimeInterval? = nil
    }

    /// The speed it was seen going: the one its fix gives (a train's, from NS), else along its road between its fix
    /// before and this one, `seenMin` to `seenMax` apart, both on its road, forwards and at most `seenTop`. Nil: not
    /// known, or not sane.
    static func observedSpeed(_ fix: GPSFix, previous: GPSFix?, on legs: [Leg]) -> Double? {
        if let v = fix.speed, v.isFinite, v >= 0, v <= 60 { return v }
        guard let q = previous else { return nil }
        let dt = fix.at.timeIntervalSince(q.at)
        guard dt >= seenMin, dt <= seenMax, let a = snap(fix, on: legs), let b = snap(q, on: legs) else { return nil }
        let d = (legs[a.leg].start + a.along) - (legs[b.leg].start + b.along)
        let v = d / dt
        guard v.isFinite, v >= 0, v <= seenTop else { return nil }
        return v
    }

    /// How late it is at its fix (`at`, on `spot`): the fix's time minus when its times have it there (negative: early).
    /// Nil: no times there to go by.
    static func lateness(_ spot: Spot, at: Date, on legs: [Leg]) -> TimeInterval? {
        guard legs.indices.contains(spot.leg) else { return nil }
        let l = legs[spot.leg]
        let span = l.arrival.timeIntervalSince(l.departure)
        guard span > 0, l.length > 0 else { return nil }
        let f = min(1, max(0, spot.along / l.length))
        let late = at.timeIntervalSince(l.departure.addingTimeInterval(f * span))
        return late.isFinite ? late : nil
    }

    /// m more room for a fix `age` seconds old of one going `speed`: none up to `slackFrom`, then `slackShare` of the
    /// way it went since, `maxSlack` at most.
    static func ageSlack(age: TimeInterval, speed: Double) -> Double {
        guard age.isFinite, speed.isFinite, age > slackFrom else { return 0 }
        return min(maxSlack, slackShare * max(0, speed) * (age - slackFrom))
    }

    /// From the fix's spot at its own time to `now`: on along its road at each piece's speed by its times, for at
    /// most `maxAdvance`, waiting at a stop until it leaves there (a piece's departure), never on past a stop
    /// before then. Standing at the start of a piece before it leaves: it waits there too.
    /// With its `pace` (0.34): at the speed it was seen going, for up to `maxAdvanceSeen`, standing `dwell` at least at
    /// a stop on its way; late as it is, it leaves a stop that much after its departure.
    static func advance(_ spot: Spot, from at: Date, on legs: [Leg], now: Date, pace: Pace = Pace()) -> Spot {
        guard legs.indices.contains(spot.leg) else { return spot }
        let seen: Double? = pace.speed.flatMap { $0.isFinite && $0 > 0.5 ? min($0, 60) : nil }
        let late: TimeInterval = pace.late.map { $0.isFinite ? max(0, min($0, 1800)) : 0 } ?? 0
        let end = min(now, at.addingTimeInterval(seen != nil ? maxAdvanceSeen : maxAdvance))
        var t = at, k = spot.leg, a = min(max(0, spot.along), legs[k].length)
        if a <= 15, t < legs[k].departure.addingTimeInterval(late) { t = legs[k].departure.addingTimeInterval(late) }
        while t < end {
            let l = legs[k], v = seen ?? l.speed
            guard v > 0 else { break }
            let need = (l.length - a) / v
            if t.addingTimeInterval(need) >= end { a += v * end.timeIntervalSince(t); break }
            t = t.addingTimeInterval(need); a = l.length
            guard k + 1 < legs.count else { break }
            // at the stop between the two: it leaves at the next piece's departure (or now, when that has passed),
            // that much later when it's late, and not before it stood there a moment (at its seen pace)
            t = max(t.addingTimeInterval(seen != nil ? dwell : 0), legs[k + 1].departure.addingTimeInterval(late))
            guard t < end else { break }
            k += 1; a = 0
        }
        return Spot(leg: k, along: min(a, legs[k].length), crossTrack: spot.crossTrack)
    }

    /// Metres along the whole road to draw it at, at `now`, by the fix; nil when the fix isn't on its road.
    /// `previous`: its fix before (0.34), for the pace it was seen going.
    static func place(_ fix: GPSFix, previous: GPSFix? = nil, on legs: [Leg], now: Date) -> (metres: Double, spot: Spot)? {
        guard let s = snap(fix, on: legs) else { return nil }
        let pace = Pace(speed: observedSpeed(fix, previous: previous, on: legs), late: lateness(s, at: fix.at, on: legs))
        let moved = advance(s, from: fix.at, on: legs, now: now, pace: pace.speed == nil ? Pace() : pace)
        return (legs[moved.leg].start + moved.along, moved)
    }

    /// The spot `m` metres along the whole road: on the last piece that holds it; in a gap between two pieces, at the
    /// end of the one before; before the first, at its start; past the last, at its end.
    static func spot(atMetres m: Double, on legs: [Leg]) -> Spot? {
        guard let first = legs.first else { return nil }
        var best = Spot(leg: 0, along: 0, crossTrack: 0)
        guard m > first.start else { return best }
        for (k, l) in legs.enumerated() where m >= l.start {
            best = Spot(leg: k, along: min(l.length, m - l.start), crossTrack: 0)
        }
        return best
    }

    /// The point and the road's direction there, `along` metres into a piece.
    static func point(_ spot: Spot, on legs: [Leg]) -> (point: GeoPoint, bearing: Double?)? {
        guard legs.indices.contains(spot.leg), let p = Geo.point(atMetres: spot.along, on: legs[spot.leg].path) else { return nil }
        let l = legs[spot.leg]
        let lo = max(0, min(spot.along - 4, l.length - 8))
        let a = Geo.point(atMetres: lo, on: l.path), b = Geo.point(atMetres: min(l.length, lo + 8), on: l.path)
        guard let a, let b, Geo.metres(a, b) > 3 else { return (p, nil) }
        return (p, Geo.bearing(a, b))
    }

    /// No going back for nothing: a new place a little behind what's drawn (`holdBack` at most, a fix that put it a
    /// bit ahead of itself) keeps what's drawn until the bus gets there; one further back is a real correction.
    static func hold(shown: Double?, new: Double) -> Double {
        guard let shown, shown.isFinite, new < shown, shown - new <= holdBack else { return new }
        return shown
    }

    // MARK: fetching

    /// Seconds to the next fetch after `failures` failed ones in a row: `every`, then 60, 120, 240, at most 5 minutes.
    static func backoff(failures: Int) -> TimeInterval {
        guard failures > 0 else { return every }
        return min(300, 60 * pow(2, Double(min(failures, 10) - 1)))
    }

    /// The log line for a fetch: "vehiclePositions.pb · 200 · 184.6 KB · 3856 vehicles · parse 85 ms",
    /// "… · 304 · kept 3856 vehicles", "… · error -1001 · again in 120 s".
    /// `feed`/`unit`: "ns/vehicles" and "trains" for NS's.
    static func fetchLine(status: Int?, error: Int? = nil, bytes: Int, vehicles: Int, parseMs: Double?, next: TimeInterval,
                          feed: String = "vehiclePositions.pb", unit: String = "vehicles") -> String {
        let size = String(format: "%.1f KB", Double(max(0, bytes)) / 1024)
        var parts = [feed]
        if let error { parts.append("error \(error)") }
        else if let status { parts.append(String(status)) }
        else { parts.append("no answer") }
        if status == 200 && error == nil {
            parts += [size, "\(vehicles) \(unit)"]
            if let parseMs { parts.append("parse \(Int(parseMs.rounded())) ms") }
        } else if status == 304 && error == nil {
            parts.append("kept \(vehicles) \(unit)")
        } else {
            parts.append("again in \(Int(next.rounded())) s")
        }
        return parts.joined(separator: " · ")
    }

    /// The log line for a fix used for your own ride's vehicle: "real position · bus 306·5578 · GPS 40 s old · 270 m
    /// from its times (behind)". Metres rounded to 10; no coordinates, trip id only its last 4 characters.
    static func usedLine(vehicle: String, age: TimeInterval, metres: Double, behind: Bool) -> String {
        "real position · \(vehicle) · GPS \(Int(max(0, age).rounded())) s old · \(FieldFormat.metres(metres)) from its times\(metres >= 5 ? (behind ? " (behind)" : " (ahead)") : "")"
    }
}

/// A protobuf message read field by field, inside `[i, end)` of a buffer. Every read checks the bounds: anything cut
/// short, a varint longer than 10 bytes, a group (wire types 3 and 4) or field number 0 ends the message there.
struct ProtoReader {
    enum Value { case varint(UInt64), fixed64(UInt64), bytes(Int, Int), fixed32(UInt32) }
    struct Field { let number: UInt64; let value: Value }

    private let buf: UnsafeRawBufferPointer
    private var i: Int
    private let end: Int

    init(_ buf: UnsafeRawBufferPointer, _ start: Int, _ end: Int) {
        self.buf = buf
        self.i = max(0, start)
        self.end = min(max(0, end), buf.count)
    }

    private mutating func varint() -> UInt64? {
        var r: UInt64 = 0, shift: UInt64 = 0
        while i < end, shift < 64 {
            let c = buf[i]; i += 1
            r |= UInt64(c & 0x7f) << shift
            if c < 0x80 { return r }
            shift += 7
        }
        return nil
    }

    /// The next field, or nil at the end (or where the message can't be read on).
    mutating func next() -> Field? {
        guard i < end, let key = varint() else { i = end; return nil }
        let number = key >> 3
        guard number > 0 else { i = end; return nil }
        let value: Value
        switch key & 7 {
        case 0:
            guard let v = varint() else { i = end; return nil }
            value = .varint(v)
        case 1:
            guard end - i >= 8 else { i = end; return nil }
            var v: UInt64 = 0
            for k in 0..<8 { v |= UInt64(buf[i + k]) << (8 * UInt64(k)) }
            i += 8; value = .fixed64(v)
        case 2:
            guard let n = varint(), n <= UInt64(end - i) else { i = end; return nil }
            value = .bytes(i, i + Int(n)); i += Int(n)
        case 5:
            guard end - i >= 4 else { i = end; return nil }
            var v: UInt32 = 0
            for k in 0..<4 { v |= UInt32(buf[i + k]) << (8 * UInt32(k)) }
            i += 4; value = .fixed32(v)
        default:
            i = end; return nil
        }
        return Field(number: number, value: value)
    }

    static func string(_ buf: UnsafeRawBufferPointer, _ s: Int, _ e: Int) -> String? {
        guard s >= 0, e <= buf.count, s <= e else { return nil }
        return String(decoding: UnsafeRawBufferPointer(rebasing: buf[s..<e]), as: UTF8.self)
    }
}
