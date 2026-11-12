import CoreLocation
import Foundation

/// One bus or train ride inside a trip.
struct Ride: Identifiable, Hashable {
    var id: String { "\(tripId)|\(departure.timeIntervalSince1970)" }
    let tripId: String
    let line: String            // "306", "IC", "SPR"
    let name: String            // "Intercity", "306"
    let isTrain: Bool
    let departure: Date
    let scheduledDeparture: Date
    let arrival: Date
    let scheduledArrival: Date
    let fromStop: String
    let fromId: String
    let toStop: String
    let platform: String?
    let live: Bool
    let cancelled: Bool
    let walkBefore: Int         // minutes of walking before this ride
    var num: String = ""        // the train number ("3561"), for NS
    var headsign: String = ""
    var plannedPlatform: String? = nil
    var delay: Int { live ? Int((departure.timeIntervalSince(scheduledDeparture) / 60).rounded()) : 0 }
    var rideMinutes: Int { Fmt.mins(arrival.timeIntervalSince(departure)) }
    var badge: String { isTrain ? line : "BUS \(line)" }
    var grade: String? { Ratings.shared.grade(key: "\(fromId)>\(toStop)", minutes: arrival.timeIntervalSince(departure) / 60,
                                              scheduled: scheduledArrival.timeIntervalSince(scheduledDeparture) / 60, cancelled: cancelled) }
}

/// A door-to-door trip from the planner: the rides plus where it starts and ends.
struct DoorTrip: Identifiable, Hashable {
    var id: String { rides.map(\.id).joined(separator: "+") }
    let rides: [Ride]
    let start: Date
    let end: Date
    var first: Ride { rides[0] }
    var last: Ride { rides[rides.count - 1] }
    var changes: [String] { rides.dropFirst().map { Fmt.place($0.fromStop) } }
    /// On board, with the wait at a change: first departure to last arrival.
    var rideMinutes: Double { last.arrival.timeIntervalSince(first.departure) / 60 }
    var scheduledMinutes: Double { last.scheduledArrival.timeIntervalSince(first.scheduledDeparture) / 60 }
    var walkAfter: Int { max(0, Fmt.mins(end.timeIntervalSince(last.arrival))) }
    /// "24 min ride", "1 h 05 min incl. change"
    var rideLabel: String { "\(Fmt.rideText(rideMinutes)) \(rides.count > 1 ? "incl. change" : "ride")" }
    var via: String? { rides.map { Fmt.place($0.toStop) }.first { $0 == "Den Bosch" || $0 == "Eindhoven" } }
}

/// A departure from a stop's board (the Veghel buses).
struct BoardDeparture: Identifiable, Hashable {
    var id: String { "\(tripId)|\(stopId)" }
    let tripId: String
    let stopId: String
    let stopName: String
    let line: String
    let headsign: String
    let time: Date
    let scheduled: Date
    let live: Bool
    let cancelled: Bool
    let platform: String?
    var delay: Int { live ? Int((time.timeIntervalSince(scheduled) / 60).rounded()) : 0 }
}

/// A stop-to-stop piece of a running vehicle, from the live map (used to find the bus or train you're on).
struct VehicleSegment {
    let tripId: String
    let line: String
    let isTrain: Bool
    let fromName: String
    let toName: String
    let departure: Date
    let arrival: Date
    let path: [CLLocationCoordinate2D]

    /// Where the vehicle should be at `t`, by time along its path.
    func position(at t: Date) -> CLLocationCoordinate2D? {
        guard t >= departure.addingTimeInterval(-30), t <= arrival.addingTimeInterval(30), path.count > 1 else { return nil }
        let span = max(1, arrival.timeIntervalSince(departure))
        let f = min(1, max(0, t.timeIntervalSince(departure) / span))
        var lens: [Double] = [], total = 0.0
        for i in 1..<path.count {
            let d = CLLocation(latitude: path[i - 1].latitude, longitude: path[i - 1].longitude)
                .distance(from: CLLocation(latitude: path[i].latitude, longitude: path[i].longitude))
            lens.append(d); total += d
        }
        var want = f * total
        for i in 0..<lens.count {
            if want <= lens[i] || i == lens.count - 1 {
                let u = lens[i] > 0 ? want / lens[i] : 0
                let a = path[i], b = path[i + 1]
                return .init(latitude: a.latitude + (b.latitude - a.latitude) * u, longitude: a.longitude + (b.longitude - a.longitude) * u)
            }
            want -= lens[i]
        }
        return path.last
    }
}

struct TripStop { let name: String; let coordinate: CLLocationCoordinate2D; let arrival: Date? }

/// Talks to Transitous (free, volunteer-run; keep requests light).
enum Transit {
    static let base = "https://api.transitous.org/api"
    static let userAgent = "Haltewekker-iOS/0.2 (https://github.com/kupperma/Halte-wekker)"

    private static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }()
    private static let isoFrac: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    static func date(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        return iso.date(from: s) ?? isoFrac.date(from: s)
    }

    static func get(_ path: String, _ items: [URLQueryItem]) async throws -> Any {
        var c = URLComponents(string: base + path)!
        c.queryItems = items
        var req = URLRequest(url: c.url!, timeoutInterval: 25)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONSerialization.jsonObject(with: data)
    }

    static func text(_ a: Any?) -> String {
        if let s = a as? String { return s }
        if let n = a as? NSNumber { return n.stringValue }
        return ""
    }

    struct StopHit: Identifiable, Hashable { let id: String; let name: String; let town: String; let lat: Double; let lon: Double }

    /// Stop search, closest to Veghel first.
    static func findStops(_ q: String) async -> [StopHit] {
        let items: [URLQueryItem] = [.init(name: "text", value: q), .init(name: "type", value: "STOP"), .init(name: "numResults", value: "12"),
                                     .init(name: "place", value: "\(Place.veghel.coordinate.latitude),\(Place.veghel.coordinate.longitude)")]
        guard let list = try? await get("/v1/geocode", items) as? [[String: Any]] else { return [] }
        return list.compactMap { m in
            guard let id = m["id"] as? String, let name = m["name"] as? String, let la = m["lat"] as? Double, let lo = m["lon"] as? Double else { return nil }
            let areas = (m["areas"] as? [[String: Any]]) ?? []
            let a = areas.first { ($0["default"] as? Bool) == true } ?? areas.first { ($0["matched"] as? Bool) == true } ?? areas.first
            return StopHit(id: id, name: name, town: (a?["name"] as? String) ?? "", lat: la, lon: lo)
        }
    }

    static func trainLabel(_ n: String) -> String {
        let l = n.lowercased()
        if l.contains("intercity direct") { return "ICD" }
        if l.contains("intercity") { return "IC" }
        if l.contains("sprinter") { return "SPR" }
        return String(n.prefix(4))
    }

    static func parseItinerary(_ it: [String: Any]) -> DoorTrip? {
        let legs = (it["legs"] as? [[String: Any]]) ?? []
        var rides: [Ride] = []
        for (i, l) in legs.enumerated() where (l["mode"] as? String) != "WALK" {
            let mode = (l["mode"] as? String) ?? ""
            let train = !(mode.contains("BUS") || mode.contains("COACH"))
            let from = l["from"] as? [String: Any] ?? [:], to = l["to"] as? [String: Any] ?? [:]
            guard let dep = date(l["startTime"]), let arr = date(l["endTime"]) else { continue }
            let short = (l["routeShortName"] as? String) ?? (l["displayName"] as? String) ?? "?"
            var walk = 0
            if i > 0, (legs[i - 1]["mode"] as? String) == "WALK", let a = date(legs[i - 1]["startTime"]), let b = date(legs[i - 1]["endTime"]) {
                walk = Fmt.mins(b.timeIntervalSince(a))
            }
            rides.append(Ride(tripId: (l["tripId"] as? String) ?? UUID().uuidString, line: train ? trainLabel(short) : short, name: short, isTrain: train,
                              departure: dep, scheduledDeparture: date(l["scheduledStartTime"]) ?? dep,
                              arrival: arr, scheduledArrival: date(l["scheduledEndTime"]) ?? arr,
                              fromStop: (from["name"] as? String) ?? "", fromId: (from["stopId"] as? String) ?? ((from["name"] as? String) ?? ""),
                              toStop: (to["name"] as? String) ?? "",
                              platform: (from["track"] as? String) ?? (from["scheduledTrack"] as? String),
                              live: (l["realTime"] as? Bool) ?? false, cancelled: (l["cancelled"] as? Bool) ?? false, walkBefore: walk,
                              num: Self.text(l["tripShortName"]), headsign: (l["headsign"] as? String) ?? "",
                              plannedPlatform: (from["scheduledTrack"] as? String) ?? (from["track"] as? String)))
        }
        guard !rides.isEmpty, let s = date(it["startTime"]), let e = date(it["endTime"]) else { return nil }
        return DoorTrip(rides: rides, start: s, end: e)
    }

    /// The planner. `modes` nil means every kind of transport.
    static func plan(from: String, to: String, modes: String?, at: Date, count: Int, maxTransfers: Int) async -> [DoorTrip] {
        var q: [URLQueryItem] = [.init(name: "fromPlace", value: from), .init(name: "toPlace", value: to),
                                 .init(name: "numItineraries", value: String(count)), .init(name: "maxTransfers", value: String(maxTransfers)),
                                 .init(name: "time", value: iso.string(from: at))]
        if let m = modes { q.append(.init(name: "transitModes", value: m)) }
        guard let json = try? await get("/v5/plan", q) as? [String: Any], let its = json["itineraries"] as? [[String: Any]] else { return [] }
        return its.compactMap(parseItinerary)
    }

    static func plan(from: Place, to: Place, modes: String?, at: Date, count: Int, maxTransfers: Int) async -> [DoorTrip] {
        await withTaskGroup(of: [DoorTrip].self) { g in
            for a in from.ids { for b in to.ids {
                g.addTask { await plan(from: a, to: b, modes: modes, at: at, count: count, maxTransfers: maxTransfers) }
            } }
            var all: [DoorTrip] = []
            for await r in g { all += r }
            var seen = Set<String>()
            return all.filter { seen.insert($0.id).inserted }.sorted { $0.first.departure < $1.first.departure }
        }
    }

    /// Next door-to-door trips, without the ones a later trip beats.
    static func nextTrips(_ dir: Direction) async -> [DoorTrip] {
        let from: Place = dir == .toSchool ? .veghel : .buas, to: Place = dir == .toSchool ? .buas : .veghel
        let now = Date()
        let all = await plan(from: from, to: to, modes: nil, at: now.addingTimeInterval(-120), count: 4, maxTransfers: 3)
            .filter { $0.first.departure >= now.addingTimeInterval(-60) }
        let kept = all.filter { t in !all.contains { $0.id != t.id && $0.first.departure >= t.first.departure && $0.end < t.end } }
        return Array(kept.prefix(4))
    }

    static func board(stopIds: [String]) async -> [BoardDeparture] {
        await withTaskGroup(of: [BoardDeparture].self) { g in
            for id in stopIds {
                g.addTask {
                    guard let json = try? await get("/v6/stoptimes", [.init(name: "stopId", value: id), .init(name: "n", value: "30")]) as? [String: Any],
                          let list = json["stopTimes"] as? [[String: Any]] else { return [] }
                    return list.compactMap { st in
                        let p = st["place"] as? [String: Any] ?? [:]
                        guard let t = date(p["departure"]) ?? date(p["arrival"]) else { return nil }
                        return BoardDeparture(tripId: (st["tripId"] as? String) ?? "", stopId: id, stopName: (p["name"] as? String) ?? "",
                                              line: (st["routeShortName"] as? String) ?? "?", headsign: (st["headsign"] as? String) ?? "",
                                              time: t, scheduled: date(p["scheduledDeparture"]) ?? t, live: (st["realTime"] as? Bool) ?? false,
                                              cancelled: ((st["cancelled"] as? Bool) ?? false) || ((st["tripCancelled"] as? Bool) ?? false),
                                              platform: (p["track"] as? String) ?? (p["scheduledTrack"] as? String))
                    }
                }
            }
            var all: [BoardDeparture] = []
            for await r in g { all += r }
            return all.sorted { $0.time < $1.time }
        }
    }

    /// Vehicles running near a point right now.
    static func vehicles(near c: CLLocationCoordinate2D, radiusDeg: Double = 0.02) async -> [VehicleSegment] {
        let now = Date()
        let q: [URLQueryItem] = [.init(name: "min", value: "\(c.latitude - radiusDeg),\(c.longitude - radiusDeg * 1.6)"),
                                 .init(name: "max", value: "\(c.latitude + radiusDeg),\(c.longitude + radiusDeg * 1.6)"),
                                 .init(name: "startTime", value: iso.string(from: now.addingTimeInterval(-90))),
                                 .init(name: "endTime", value: iso.string(from: now.addingTimeInterval(90))),
                                 .init(name: "zoom", value: "15")]
        guard let list = try? await get("/v1/map/trips", q) as? [[String: Any]] else { return [] }
        return list.compactMap { s in
            guard let trips = s["trips"] as? [[String: Any]], let t = trips.first, let id = t["tripId"] as? String,
                  let dep = date(s["departure"]), let arr = date(s["arrival"]), let poly = s["polyline"] as? String else { return nil }
            let mode = (s["mode"] as? String) ?? ""
            return VehicleSegment(tripId: id, line: (t["routeShortName"] as? String) ?? "?", isTrain: !(mode.contains("BUS") || mode.contains("COACH")),
                                  fromName: ((s["from"] as? [String: Any])?["name"] as? String) ?? "", toName: ((s["to"] as? [String: Any])?["name"] as? String) ?? "",
                                  departure: dep, arrival: arr, path: decodePolyline(poly))
        }
    }

    /// Every stop of one trip with its live arrival.
    static func tripStops(_ tripId: String) async -> [TripStop] {
        guard let json = try? await get("/v5/trip", [.init(name: "tripId", value: tripId)]) as? [String: Any],
              let legs = json["legs"] as? [[String: Any]] else { return [] }
        var out: [TripStop] = []
        for l in legs {
            func stop(_ o: [String: Any]?, _ key: String) -> TripStop? {
                guard let o, let la = o["lat"] as? Double, let lo = o["lon"] as? Double else { return nil }
                return TripStop(name: (o["name"] as? String) ?? "", coordinate: .init(latitude: la, longitude: lo), arrival: date(o[key]))
            }
            if let s = stop(l["from"] as? [String: Any], "departure") { out.append(s) }
            for s in (l["intermediateStops"] as? [[String: Any]]) ?? [] { if let x = stop(s, "arrival") { out.append(x) } }
            if let s = stop(l["to"] as? [String: Any], "arrival") { out.append(s) }
        }
        return out
    }

    static func decodePolyline(_ s: String) -> [CLLocationCoordinate2D] {
        var pts: [CLLocationCoordinate2D] = [], lat = 0, lng = 0
        let b = Array(s.utf8); var i = 0
        while i < b.count {
            var vals = [0, 0]
            for k in 0..<2 {
                var r = 0, sh = 0
                while i < b.count {
                    let c = Int(b[i]) - 63; i += 1
                    r |= (c & 0x1f) << sh; sh += 5
                    if c < 0x20 { break }
                }
                vals[k] = (r & 1) != 0 ? ~(r >> 1) : (r >> 1)
            }
            lat += vals[0]; lng += vals[1]
            pts.append(.init(latitude: Double(lat) / 1e5, longitude: Double(lng) / 1e5))
        }
        return pts
    }
}

/// Speed rating: compare a ride with the fastest timetabled ride ever seen on the same stretch.
final class Ratings {
    static let shared = Ratings()
    private var best: [String: Double]
    private let key = "bestTimes"
    private init() { best = UserDefaults.standard.dictionary(forKey: "bestTimes") as? [String: Double] ?? [:] }

    /// Remember the fastest timetabled time for a stretch, without grading anything.
    func learn(key k: String, minutes: Double) {
        guard minutes > 0, best[k] == nil || minutes < best[k]! - 0.05 else { return }
        best[k] = (minutes * 10).rounded() / 10
        UserDefaults.standard.set(best, forKey: key)
    }
    /// The fastest ride between two of your places ("c:ht>bd"), for the trip score.
    func learn(_ from: Place, _ to: Place, _ trips: [DoorTrip]) {
        for t in trips where !t.first.cancelled { learn(key: "c:\(from.key)>\(to.key)", minutes: t.scheduledMinutes) }
    }
    func best(_ k: String) -> Double? { best[k] }
    func reset() { best = [:]; UserDefaults.standard.removeObject(forKey: key) }

    func grade(key k: String, minutes: Double, scheduled: Double, cancelled: Bool) -> String? {
        guard !cancelled, minutes > 0 else { return nil }
        if scheduled > 0, best[k] == nil || scheduled < best[k]! - 0.05 {
            best[k] = (scheduled * 10).rounded() / 10
            UserDefaults.standard.set(best, forKey: key)
        }
        let b = best[k] ?? minutes, e = minutes - b, r = minutes / b
        if e <= 1 || r <= 1.06 { return "S" }
        if e <= 3 || r <= 1.18 { return "A" }
        if r <= 1.3 { return "B" }
        return "C"
    }
}
