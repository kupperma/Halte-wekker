import CoreLocation
import Foundation

/// One bus or train ride inside a trip.
struct Ride: Identifiable, Hashable, Codable {
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
    var fromLat: Double? = nil      // where the stops are, for a trip that isn't one of your two routes
    var fromLon: Double? = nil
    var toLat: Double? = nil
    var toLon: Double? = nil
    var delay: Int { live ? Int((departure.timeIntervalSince(scheduledDeparture) / 60).rounded()) : 0 }
    var rideMinutes: Int { Fmt.mins(arrival.timeIntervalSince(departure)) }
    var badge: String { isTrain ? line : "BUS \(line)" }
    var grade: String? { Ratings.shared.grade(key: "\(fromId)>\(toStop)", minutes: arrival.timeIntervalSince(departure) / 60,
                                              scheduled: scheduledArrival.timeIntervalSince(scheduledDeparture) / 60, cancelled: cancelled) }
    /// The same speed rank, only read (`grade` also remembers a new fastest time): for the room a change after it needs.
    var speedGrade: String? { Ratings.shared.peekGrade(key: "\(fromId)>\(toStop)", minutes: arrival.timeIntervalSince(departure) / 60,
                                                       scheduled: scheduledArrival.timeIntervalSince(scheduledDeparture) / 60, cancelled: cancelled) }
}

extension Ride {
    /// The same ride, with another walk to it.
    func walking(_ minutes: Int) -> Ride {
        Ride(tripId: tripId, line: line, name: name, isTrain: isTrain, departure: departure, scheduledDeparture: scheduledDeparture,
             arrival: arrival, scheduledArrival: scheduledArrival, fromStop: fromStop, fromId: fromId, toStop: toStop, platform: platform,
             live: live, cancelled: cancelled, walkBefore: minutes, num: num, headsign: headsign, plannedPlatform: plannedPlatform,
             fromLat: fromLat, fromLon: fromLon, toLat: toLat, toLon: toLon)
    }

    /// The same ride, got on at another stop of its trip (`BoardAt`, 0.25.1), with the walk there: its time, platform
    /// and place there; the rest as it was.
    func boarding(at s: BoardAt.Stop, walk minutes: Int) -> Ride {
        let dep: Date = s.departure ?? departure
        let sched: Date = s.scheduledDeparture ?? dep
        let platform: String? = s.track ?? s.scheduledTrack
        let planned: String? = s.scheduledTrack ?? s.track
        let stopName: String = s.name.isEmpty ? fromStop : s.name
        let stopId: String = s.id.isEmpty ? fromId : s.id
        return Ride(tripId: tripId, line: line, name: name, isTrain: isTrain, departure: dep, scheduledDeparture: sched,
                    arrival: arrival, scheduledArrival: scheduledArrival, fromStop: stopName,
                    fromId: stopId, toStop: toStop, platform: platform,
                    live: live, cancelled: cancelled, walkBefore: minutes, num: num, headsign: headsign, plannedPlatform: planned,
                    fromLat: s.point.lat, fromLon: s.point.lon, toLat: toLat, toLon: toLon)
    }
}

extension DoorTrip {
    /// The same trip, its first ride got on at another stop of its trip (`BoardAt`): you leave by then minus the walk.
    func boardingFirst(at s: BoardAt.Stop, walk minutes: Int) -> DoorTrip {
        let f = first.boarding(at: s, walk: minutes)
        return DoorTrip(rides: [f] + rides.dropFirst(), start: f.departure.addingTimeInterval(-Double(minutes) * 60), end: end)
    }
}

/// A door-to-door trip from the planner: the rides plus where it starts and ends.
struct DoorTrip: Identifiable, Hashable, Codable {
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
    /// The corridor's hub this trip changes at ("Den Bosch", "Eindhoven"); none off the corridor.
    var via: String? {
        guard let hubs = RoleSnapshot.corridor?.hubs.map(\.short) else { return nil }
        return rides.map { Fmt.place($0.toStop) }.first { hubs.contains($0) }
    }
}

// (the planner's answers are kept in a `Memo`, 0.20.7)
extension Ride: @unchecked Sendable {}
extension DoorTrip: @unchecked Sendable {}

/// A departure from a stop's board (the Veghel buses).
struct BoardDeparture: Identifiable, Hashable, Codable {
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
    var heading: Heading? = nil         // which way it goes from here
    var train = false
    var delay: Int { live ? Int((time.timeIntervalSince(scheduled) / 60).rounded()) : 0 }
    /// The same departure, under another stop of the board.
    func at(_ stop: String) -> BoardDeparture {
        stop == stopId ? self : BoardDeparture(tripId: tripId, stopId: stop, stopName: stopName, line: line, headsign: headsign, time: time,
                                               scheduled: scheduled, live: live, cancelled: cancelled, platform: platform, heading: heading, train: train)
    }
}

/// Which way a bus or train goes from a stop: the compass direction (0 is north, 90 east), and the next places it passes.
struct Heading: Hashable, Codable {
    let degrees: Double
    var via: String? = nil              // "De Muntelaar → Uden"
    /// "NE"
    var compass: String {
        let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let d = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return names[Int((d + 22.5) / 45) % 8]
    }
    /// "northeast"
    var spoken: String {
        ["N": "north", "NE": "northeast", "E": "east", "SE": "southeast", "S": "south", "SW": "southwest", "W": "west", "NW": "northwest"][compass] ?? compass
    }
    static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let dx = (b.longitude - a.longitude) * cos(a.latitude * .pi / 180), dy = b.latitude - a.latitude
        return (atan2(dx, dy) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }
    /// From a ride's stop to where you get off.
    static func of(_ r: Ride) -> Heading? {
        guard let a = r.fromLat, let o = r.fromLon, let ta = r.toLat, let to = r.toLon else { return nil }
        return Heading(degrees: bearing(.init(latitude: a, longitude: o), .init(latitude: ta, longitude: to)))
    }
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
    var realTime = false                // its times are live (else timetable only)
    var toLat: Double? = nil            // where the piece's next stop is
    var toLon: Double? = nil
    var scheduledDeparture: Date? = nil // the timetable's times (`departure` and `arrival` are live when it is)
    var scheduledArrival: Date? = nil
    var mode = ""                       // as the live data names it: "BUS", "TRAM", "REGIONAL_RAIL"…

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

    /// Questions someone is waiting for on screen (Fastest trip, what you're on). They go on their own connections: a
    /// phone keeps only a few open to one server, and the boards, the school alarm planning the week and the rest would
    /// otherwise have them queue.
    @TaskLocal static var urgent = false

    /// The last thing that went wrong with one of those, and when (so the screen can say why it found nothing).
    static let trouble = Trouble()
    final class Trouble: @unchecked Sendable {
        private let lock = NSLock()
        private var last: (text: String, at: Date)?
        func note(_ t: String) { lock.lock(); last = (t, Date()); lock.unlock() }
        /// What went wrong in the last `seconds`, if anything.
        func recent(_ seconds: Double = 40) -> String? {
            lock.lock(); defer { lock.unlock() }
            guard let l = last, Date().timeIntervalSince(l.at) < seconds else { return nil }
            return l.text
        }
    }
    /// One question to Transitous, within the lane's time limits (see `Net`). A slow connection or a busy server gets at
    /// most one more try a moment later, and never after a timeout.
    static func raw(_ path: String, _ items: [URLQueryItem]) async throws -> Data {
        var c = URLComponents(string: base + path)!
        c.queryItems = items
        var req = URLRequest(url: c.url!)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let isUrgent = urgent
        let answer: NetAnswer
        do {
            answer = try await Net.response(req, lane: isUrgent ? .urgent : .background, label: path)
        } catch let e as URLError {
            if isUrgent, e.code != .cancelled { trouble.note(e.code == .timedOut ? "Transitous didn’t answer in time" : e.localizedDescription) }
            throw e
        }
        let code = answer.status
        if code == 429 || code >= 500 {
            if isUrgent { trouble.note(code == 429 ? "Transitous asked to slow down (HTTP 429)" : "Transitous had a problem (HTTP \(code))") }
            throw URLError(.badServerResponse)
        }
        if code >= 400, isUrgent { trouble.note("Transitous said no (HTTP \(code))") }
        return answer.data
    }

    static func get(_ path: String, _ items: [URLQueryItem]) async throws -> Any {
        try JSONSerialization.jsonObject(with: try await raw(path, items))
    }

    static func text(_ a: Any?) -> String {
        if let s = a as? String { return s }
        if let n = a as? NSNumber { return n.stringValue }
        return ""
    }

    struct StopHit: Identifiable, Hashable { let id: String; let name: String; let town: String; let lat: Double; let lon: Double }

    /// Stop search, closest to Home first.
    static func findStops(_ q: String) async -> [StopHit] {
        let items: [URLQueryItem] = [.init(name: "text", value: q), .init(name: "type", value: "STOP"), .init(name: "numResults", value: "12"),
                                     .init(name: "place", value: "\(Place.home.coordinate.latitude),\(Place.home.coordinate.longitude)")]
        // (someone is typing and waiting for it)
        let answer = try? await Transit.$urgent.withValue(true) { () async throws -> Any in try await get("/v1/geocode", items) }
        guard let list = answer as? [[String: Any]] else { return [] }
        return list.compactMap { m in
            guard let id = m["id"] as? String, let name = m["name"] as? String, let la = m["lat"] as? Double, let lo = m["lon"] as? Double else { return nil }
            let areas = (m["areas"] as? [[String: Any]]) ?? []
            let a = areas.first { ($0["default"] as? Bool) == true } ?? areas.first { ($0["matched"] as? Bool) == true } ?? areas.first
            return StopHit(id: id, name: name, town: (a?["name"] as? String) ?? "", lat: la, lon: lo)
        }
    }

    /// A search hit that can also be an address or a named place (the setup's School and Home, 0.23).
    struct PlaceHit: Identifiable, Hashable, Sendable {
        enum Kind: String, Sendable { case stop, address, place }
        let id: String
        let name: String
        let town: String
        let lat: Double
        let lon: Double
        let kind: Kind
    }

    /// Search for an address, a named place, a stop or a station (Transitous's geocoder, any type), nearest to `near`
    /// first when given; only results in the Netherlands and its neighbours' border towns.
    static func findPlaces(_ q: String, near: CLLocationCoordinate2D?) async -> [PlaceHit] {
        var items: [URLQueryItem] = [.init(name: "text", value: q), .init(name: "numResults", value: "12")]
        if let c = near { items.append(.init(name: "place", value: "\(c.latitude),\(c.longitude)")) }
        let answer = try? await Transit.$urgent.withValue(true) { () async throws -> Any in try await get("/v1/geocode", items) }
        guard let list = answer as? [[String: Any]] else { return [] }
        return list.compactMap { m in
            guard let name = m["name"] as? String, let la = m["lat"] as? Double, let lo = m["lon"] as? Double,
                  ["NL", "BE", "DE", nil].contains(m["country"] as? String) else { return nil }
            let areas = (m["areas"] as? [[String: Any]]) ?? []
            let a = areas.first { ($0["default"] as? Bool) == true } ?? areas.first { ($0["matched"] as? Bool) == true } ?? areas.first
            let kind: PlaceHit.Kind = (m["type"] as? String) == "STOP" ? .stop : (m["type"] as? String) == "ADDRESS" ? .address : .place
            return PlaceHit(id: (m["id"] as? String) ?? "\(la),\(lo)", name: name, town: (a?["name"] as? String) ?? "", lat: la, lon: lo, kind: kind)
        }
    }

    /// The stops around a spot for the setup's home board: one per stop area or name, nearest first (nil: no answer).
    static func nearStopChoices(_ c: CLLocationCoordinate2D) async -> [SetupStop]? {
        let dLat = 0.008, dLon = 0.012
        let q: [URLQueryItem] = [.init(name: "min", value: "\(c.latitude - dLat),\(c.longitude - dLon)"),
                                 .init(name: "max", value: "\(c.latitude + dLat),\(c.longitude + dLon)")]
        guard let list = try? await Transit.$urgent.withValue(true, operation: { () async throws -> Any in try await get("/v1/map/stops", q) }) as? [[String: Any]]
        else { return nil }
        let here = GeoPoint(lat: c.latitude, lon: c.longitude)
        let raw = list.compactMap { m -> SetupStopRaw? in
            guard let id = m["stopId"] as? String, let name = m["name"] as? String, let la = m["lat"] as? Double, let lo = m["lon"] as? Double else { return nil }
            let modes = (m["modes"] as? [String]) ?? []
            let rail = modes.contains { $0.contains("RAIL") || $0 == "LONG_DISTANCE" || $0 == "HIGHSPEED" }
            return SetupStopRaw(id: id, name: name, parentId: m["parentId"] as? String, metres: Geo.metres(here, GeoPoint(lat: la, lon: lo)), rail: rail,
                                lat: la, lon: lo)
        }
        return SetupLogic.stopChoices(raw)
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
                              plannedPlatform: (from["scheduledTrack"] as? String) ?? (from["track"] as? String),
                              fromLat: from["lat"] as? Double, fromLon: from["lon"] as? Double, toLat: to["lat"] as? Double, toLon: to["lon"] as? Double))
        }
        guard !rides.isEmpty, let s = date(it["startTime"]), let e = date(it["endTime"]) else { return nil }
        return DoorTrip(rides: rides, start: s, end: e)
    }

    /// The planner. `modes` nil means every kind of transport. Asked to the minute (`at` rounded down), and the same
    /// question within 45 s gets the same answer (0.20.7, `planAnswers`).
    static func plan(from: String, to: String, modes: String?, at: Date, count: Int, maxTransfers: Int, arriveBy: Bool = false) async -> [DoorTrip] {
        let t = PlanMemo.minute(at)
        let key = PlanMemo.key(from: from, to: to, modes: modes, at: t, count: count, maxTransfers: maxTransfers, arriveBy: arriveBy)
        return await planAnswers.get(key, group: urgent ? 1 : 0) {
            await planAsked(from: from, to: to, modes: modes, at: t, count: count, maxTransfers: maxTransfers, arriveBy: arriveBy)
        } ?? []
    }

    /// One plan from Transitous (nil: no answer, or an empty one).
    private static func planAsked(from: String, to: String, modes: String?, at: Date, count: Int, maxTransfers: Int, arriveBy: Bool) async -> [DoorTrip]? {
        var q: [URLQueryItem] = [.init(name: "fromPlace", value: from), .init(name: "toPlace", value: to),
                                 .init(name: "numItineraries", value: String(count)), .init(name: "maxTransfers", value: String(maxTransfers)),
                                 .init(name: "time", value: iso.string(from: at)),
                                 .init(name: "detailedTransfers", value: "false")]          // a third smaller: no turn-by-turn for changes
        if arriveBy { q.append(.init(name: "arriveBy", value: "true")) }       // `at` is when you want to be there
        if let m = modes { q.append(.init(name: "transitModes", value: m)) }
        guard let json = try? await get("/v5/plan", q) as? [String: Any], let its = json["itineraries"] as? [[String: Any]] else { return nil }
        let trips = its.compactMap(parseItinerary)
        Task { @MainActor in LiveDelays.shared.note(trips) }          // how late each line is running now
        return trips.isEmpty ? nil : trips
    }

    static func plan(from: Place, to: Place, modes: String?, at: Date, count: Int, maxTransfers: Int, arriveBy: Bool = false) async -> [DoorTrip] {
        await withTaskGroup(of: [DoorTrip].self) { g in
            for a in PlanMemo.unique(from.ids) { for b in PlanMemo.unique(to.ids) {
                g.addTask { await plan(from: a, to: b, modes: modes, at: at, count: count, maxTransfers: maxTransfers, arriveBy: arriveBy) }
            } }
            var all: [DoorTrip] = []
            for await r in g { all += r }
            var seen = Set<String>()
            return all.filter { seen.insert($0.id).inserted }.sorted { $0.first.departure < $1.first.departure }
        }
    }

    /// Door-to-door trips from where you are to a place, without the ones a later trip beats. `publish` gets them as
    /// each plan comes in (from your spot, from the station you're at), before the rest.
    static func tripsFrom(_ c: CLLocationCoordinate2D, to: Place, count: Int = 5, keep: Int = 5,
                          publish: (@Sendable ([DoorTrip]) async -> Void)? = nil) async -> [DoorTrip] {
        let now = Date()
        let here = CLLocation(latitude: c.latitude, longitude: c.longitude)
        // all at once: from your spot, which station you're at (if any), then from the station too; each plan handed on
        // as soon as it's in, once it's known which station you're at (the filter needs it)
        var fromHere: [DoorTrip]?, fromStation: [DoorTrip]?
        var station: NearStop?, stationKnown = false
        await withTaskGroup(of: FromHerePart.self) { g in
            g.addTask { FromHerePart.spot(await planAll(from: "\(c.latitude),\(c.longitude)", to: to.ids, at: now.addingTimeInterval(-120), count: count)) }
            g.addTask { FromHerePart.station(await stationAt(c)) }
            while let part = await g.next() {
                switch part {
                case .spot(let trips):
                    fromHere = trips
                case .station(let s):
                    station = s
                    stationKnown = true
                    g.addTask { FromHerePart.fromStation(await planAll(from: s?.id, to: to.ids, at: now.addingTimeInterval(-120), count: count)) }
                case .fromStation(let trips):
                    // At a station: from the station itself too. From your GPS spot inside a big one, the walk to the
                    // platforms can come out long or odd, and a bus to the station you're standing in looks quicker. Your
                    // walk to the platform: about how far it is.
                    fromStation = trips.map { t in
                        let f = t.first
                        let m = f.fromLat.flatMap { a in f.fromLon.map { o in here.distance(from: CLLocation(latitude: a, longitude: o)) } } ?? 150
                        let walk = min(8, max(2, Int((m / 1.2 / 60).rounded(.up))))
                        return DoorTrip(rides: [f.walking(walk)] + t.rides.dropFirst(), start: f.departure.addingTimeInterval(-Double(walk) * 60), end: t.end)
                    }
                }
                guard let publish, stationKnown, fromHere != nil || fromStation != nil else { continue }
                await publish(keepUseful((fromHere ?? []) + (fromStation ?? []), here: here, station: station, now: now, keep: keep))
            }
        }
        var all = (fromHere ?? []) + (fromStation ?? [])
        // Out in the country (between Tilburg Reeshof and Gilze-Rijen, say) the planner finds no stop it'll walk to:
        // then from the nearest station and the nearest stop within about 3 km, with the walk there.
        if all.isEmpty {
            all = await fromNearest(here, to: to.ids, at: now.addingTimeInterval(-120), count: count)
        }
        return keepUseful(all, here: here, station: station, now: now, keep: keep)
    }

    /// What `tripsFrom` hears back, each as it comes in.
    private enum FromHerePart: Sendable {
        case spot([DoorTrip])
        case station(NearStop?)
        case fromStation([DoorTrip])
    }

    /// The trips worth showing, soonest first: no ride to where you are already, nothing that has left, none a later
    /// trip beats, at most `keep`.
    private static func keepUseful(_ all: [DoorTrip], here: CLLocation, station: NearStop?, now: Date, keep: Int) -> [DoorTrip] {
        var all = all
        // A ride that only takes you to where you are (the station you're at): you're there already. Only when there's
        // another way, though.
        let at = station.map { CLLocation(latitude: $0.lat, longitude: $0.lon) }
        func hop(_ t: DoorTrip) -> Bool {
            guard t.rides.count > 1, let a = t.first.toLat, let o = t.first.toLon else { return false }
            let end = CLLocation(latitude: a, longitude: o)
            return end.distance(from: here) < 350 || (at.map { end.distance(from: $0) < 400 } ?? false)
        }
        let direct = all.filter { !hop($0) }
        if !direct.isEmpty { all = direct }
        var seen = Set<String>()
        all = all.filter { $0.first.departure >= now.addingTimeInterval(-60) && $0.start >= now.addingTimeInterval(-90) && seen.insert($0.id).inserted }
            .sorted { $0.first.departure < $1.first.departure }
        let kept = all.filter { t in !all.contains { $0.id != t.id && $0.first.departure >= t.first.departure && $0.end < t.end } }
        return Array(kept.prefix(keep))
    }

    /// Earlier ways onto the same connection. At each place you get on (your first stop, and every change), what else
    /// leaves from there (the whole station, every platform) before the ride you'd take, once you can be there, and gets
    /// to where that ride takes you in time for the ride after it (or no later, at the end). Like the 08:31 Sprinter in
    /// Den Bosch that's in Breda before the 08:41 Intercity and makes the same bus to BUas, or the 306 seven minutes
    /// earlier that leaves time to spare for the same train. The planner leaves those out (the same arrival), but
    /// they're good to know: out of the cold sooner, and a change you won't miss.
    /// `at`: only these rides (nil: every one).
    /// `further`: at your first stop also (two) buses you can't be there for any more, but may catch at a later stop of
    /// theirs: Fastest trip gets you on wherever you make it (`BoardAt`, 0.25.1), and drops the ones you can't.
    static func earlierWays(onto best: DoorTrip, now: Date = Date(), at only: Set<Int>? = nil, further: Bool = false) async -> [DoorTrip] {
        await withTaskGroup(of: [DoorTrip].self) { g in
            for k in best.rides.indices where only?.contains(k) ?? true {
                g.addTask { await earlier(at: k, onto: best, now: now, further: further) }
            }
            var out: [DoorTrip] = []
            for await r in g { out += r }
            return out
        }
    }

    private static func earlier(at k: Int, onto best: DoorTrip, now: Date, further: Bool = false) async -> [DoorTrip] {
        let r = best.rides[k]
        guard let ta = r.toLat, let to = r.toLon, !r.fromId.isEmpty, r.fromId != "onboard" else { return [] }
        let change = CLLocation(latitude: ta, longitude: to)
        // when you can be there to get on: the walk from where you are (but looking no more than 35 minutes before it),
        // or when the ride before gets you there and the walk across
        let canBoard: Date
        let reach = now.addingTimeInterval(Double(r.walkBefore) * 60 + 30)        // (there in time, at the first stop)
        if k == 0 {
            canBoard = max(further ? now.addingTimeInterval(60) : reach, r.departure.addingTimeInterval(-35 * 60))
        } else {
            canBoard = best.rides[k - 1].arrival.addingTimeInterval(Double(max(2, r.walkBefore + 1)) * 60)
        }
        guard canBoard < r.departure.addingTimeInterval(-60) else { return [] }
        // in time for the ride after it, with the same time to change; at the end, there no later
        let inTime: Date
        if k + 1 < best.rides.count {
            let n = best.rides[k + 1]
            inTime = max(r.arrival, n.departure.addingTimeInterval(-Double(max(2, n.walkBefore + 1)) * 60))
        } else {
            inTime = r.arrival
        }
        let q: [URLQueryItem] = [.init(name: "stopId", value: r.fromId), .init(name: "time", value: iso.string(from: canBoard.addingTimeInterval(-60))),
                                 .init(name: "n", value: "40"), .init(name: "fetchStops", value: "true")]
        guard let json = try? await get("/v6/stoptimes", q) as? [String: Any], let list = json["stopTimes"] as? [[String: Any]] else { return [] }
        var out: [DoorTrip] = [], seen = Set<String>(), late = 0
        for st in list {
            let p = st["place"] as? [String: Any] ?? [:]
            guard let id = st["tripId"] as? String, id != r.tripId, seen.insert(id).inserted,
                  let dep = date(p["departure"]), dep >= canBoard, dep < r.departure.addingTimeInterval(-30),
                  !(((st["cancelled"] as? Bool) ?? false) || ((st["tripCancelled"] as? Bool) ?? false) || ((p["cancelled"] as? Bool) ?? false)) else { continue }
            // it calls where that ride takes you, in time
            let stops = (st["nextStops"] as? [[String: Any]]) ?? []
            guard let at = stops.first(where: { s in
                guard let a = s["lat"] as? Double, let o = s["lon"] as? Double else { return false }
                return change.distance(from: CLLocation(latitude: a, longitude: o)) < 400
            }), let arr = date(at["arrival"]) ?? date(at["departure"]), arr <= inTime else { continue }
            let mode = (st["mode"] as? String) ?? ""
            let train = !(mode.contains("BUS") || mode.contains("COACH"))
            let short = (st["routeShortName"] as? String) ?? (st["displayName"] as? String) ?? "?"
            let ride = Ride(tripId: id, line: train ? trainLabel(short) : short, name: short, isTrain: train,
                            departure: dep, scheduledDeparture: date(p["scheduledDeparture"]) ?? dep,
                            arrival: arr, scheduledArrival: date(at["scheduledArrival"]) ?? arr,
                            fromStop: (p["name"] as? String) ?? r.fromStop, fromId: (p["stopId"] as? String) ?? r.fromId,
                            toStop: (at["name"] as? String) ?? r.toStop,
                            platform: (p["track"] as? String) ?? (p["scheduledTrack"] as? String),
                            live: (st["realTime"] as? Bool) ?? false, cancelled: false, walkBefore: r.walkBefore,
                            num: text(st["tripShortName"]), headsign: (st["headsign"] as? String) ?? "",
                            plannedPlatform: (p["scheduledTrack"] as? String) ?? (p["track"] as? String),
                            fromLat: (p["lat"] as? Double) ?? r.fromLat, fromLon: (p["lon"] as? Double) ?? r.fromLon,
                            toLat: (at["lat"] as? Double) ?? ta, toLon: (at["lon"] as? Double) ?? to)
            var rides = best.rides
            rides[k] = ride
            let start = k == 0 ? dep.addingTimeInterval(-Double(r.walkBefore) * 60) : best.start
            // (one you can't be at this stop for: only to get on further along, at most two of those)
            let tooLate = k == 0 && dep < reach
            if tooLate { guard late < 2 else { continue }; late += 1 }
            out.append(DoorTrip(rides: rides, start: start, end: best.end))
            if out.count - late >= (k == 0 ? 3 : 2) { break }
        }
        return out
    }

    /// From the nearest train station and the nearest other stop within about 3 km, with the walk to it (a walk across
    /// fields is longer than a straight line: a third more, at 1.2 m/s).
    private static func fromNearest(_ here: CLLocation, to ids: [String], at: Date, count: Int) async -> [DoorTrip] {
        let c = here.coordinate, dLat = 0.03, dLon = 0.045
        let q: [URLQueryItem] = [.init(name: "min", value: "\(c.latitude - dLat),\(c.longitude - dLon)"),
                                 .init(name: "max", value: "\(c.latitude + dLat),\(c.longitude + dLon)")]
        guard let list = try? await get("/v1/map/stops", q) as? [[String: Any]] else { return [] }
        struct S { let id: String; let lat: Double; let lon: Double; let rail: Bool; let m: Double }
        let stops: [S] = list.compactMap { s in
            guard let id = s["stopId"] as? String, let a = s["lat"] as? Double, let o = s["lon"] as? Double else { return nil }
            let modes = (s["modes"] as? [String]) ?? []
            let rail = modes.contains { $0.contains("RAIL") || $0 == "LONG_DISTANCE" || $0 == "HIGHSPEED" }
            return S(id: rail ? ((s["parentId"] as? String) ?? id) : id, lat: a, lon: o, rail: rail,
                     m: here.distance(from: CLLocation(latitude: a, longitude: o)))
        }
        let picks = [stops.filter(\.rail).min { $0.m < $1.m }, stops.filter { !$0.rail }.min { $0.m < $1.m }].compactMap { $0 }.filter { $0.m < 3500 }
        // both at once (the answers keep the order: the station first)
        let jobs: [@Sendable () async -> [DoorTrip]] = picks.map { s in
            { @Sendable in
                let walk = max(2, Int((s.m * 1.33 / 1.2 / 60).rounded(.up)))
                // you can be there in `walk` minutes: plan from then
                let trips = await planAll(from: s.id, to: ids, at: max(at, Date().addingTimeInterval(Double(walk) * 60 - 60)), count: count)
                return trips.map { t in
                    let f = t.first
                    return DoorTrip(rides: [f.walking(walk)] + t.rides.dropFirst(), start: f.departure.addingTimeInterval(-Double(walk) * 60), end: t.end)
                }
            }
        }
        return await Progressive.all(jobs).flatMap { $0 }
    }

    /// The planner from one place to each of `ids`, all at once (nil: nothing).
    private static func planAll(from: String?, to ids: [String], at: Date, count: Int) async -> [DoorTrip] {
        guard let from else { return [] }
        return await withTaskGroup(of: [DoorTrip].self) { g in
            for b in ids { g.addTask { await plan(from: from, to: b, modes: nil, at: at, count: count, maxTransfers: 4) } }
            var all: [DoorTrip] = []
            for await r in g { all += r }
            return all
        }
    }

    /// The train station you're at, if any: within 350 m (big stations are a few hundred metres across, and the GPS
    /// wanders inside). Remembered for ten minutes per spot.
    static func stationAt(_ c: CLLocationCoordinate2D) async -> NearStop? {
        let key = "\(Int((c.latitude * 500).rounded())),\(Int((c.longitude * 300).rounded()))"         // about 200 m
        return await stations.get(key, group: urgent ? 1 : 0) {
            await nearStopsAnswer(c).map { StationAnswer(stop: $0.first { $0.rail && $0.meters < 350 }) }
        }?.stop
    }

    struct StationAnswer: Sendable { let stop: NearStop? }
    static let stations = Memo<String, StationAnswer>(ttl: 600)
    /// The raw /v5/trip answers, for 20 seconds: the live map, the stop list and the alarm ask for the same trip. (A ride's
    /// own looks take one of the last minute: `maxAge`.)
    static let tripAnswers = Memo<String, Data>(ttl: 20, limit: 50)
    /// The planner's answers (0.20.7): 45 s for the same question asked to the minute (`PlanMemo`), shared while on
    /// their way. An empty or failed answer isn't kept.
    static let planAnswers = Memo<String, [DoorTrip]>(ttl: PlanMemo.ttl, limit: 80)

    /// A stop near you: a bus stop, or a train station (by the station, not one platform).
    struct NearStop: Identifiable, Hashable, Codable {
        let id: String
        let name: String
        let lat: Double
        let lon: Double
        let rail: Bool
        let meters: Double
    }

    /// The stops within about 1.3 km of you, nearest first.
    static func nearStops(_ c: CLLocationCoordinate2D) async -> [NearStop] {
        await nearStopsAnswer(c) ?? []
    }

    /// The same, or nil when the request failed.
    static func nearStopsAnswer(_ c: CLLocationCoordinate2D) async -> [NearStop]? {
        let dLat = 0.012, dLon = 0.019
        let q: [URLQueryItem] = [.init(name: "min", value: "\(c.latitude - dLat),\(c.longitude - dLon)"),
                                 .init(name: "max", value: "\(c.latitude + dLat),\(c.longitude + dLon)")]
        guard let list = try? await get("/v1/map/stops", q) as? [[String: Any]] else { return nil }
        let here = CLLocation(latitude: c.latitude, longitude: c.longitude)
        var seen = Set<String>()
        return list.compactMap { m -> NearStop? in
            guard let id = m["stopId"] as? String, let name = m["name"] as? String, let la = m["lat"] as? Double, let lo = m["lon"] as? Double else { return nil }
            let modes = (m["modes"] as? [String]) ?? []
            let rail = modes.contains { $0.contains("RAIL") || $0 == "LONG_DISTANCE" || $0 == "HIGHSPEED" }
            let key = rail ? ((m["parentId"] as? String) ?? id) : id            // one entry per station
            guard seen.insert(key).inserted else { return nil }
            return NearStop(id: key, name: name, lat: la, lon: lo, rail: rail, meters: here.distance(from: CLLocation(latitude: la, longitude: lo)))
        }
        .sorted { $0.meters < $1.meters }
    }

    /// Next door-to-door trips, without the ones a later trip beats.
    static func nextTrips(_ dir: Direction) async -> [DoorTrip] {
        let from: Place = dir == .toSchool ? .home : .school, to: Place = dir == .toSchool ? .school : .home
        let now = Date()
        let all = await plan(from: from, to: to, modes: nil, at: now.addingTimeInterval(-120), count: 4, maxTransfers: 3)
            .filter { $0.first.departure >= now.addingTimeInterval(-60) }
        let kept = all.filter { t in !all.contains { $0.id != t.id && $0.first.departure >= t.first.departure && $0.end < t.end } }
        return Array(kept.prefix(4))
    }

    /// The departure board of stops. `from` a time in the past also gives the ones that already left (or were cancelled).
    static func board(stopIds: [String], from: Date? = nil, n: Int = 30, stops: Bool = false) async -> [BoardDeparture] {
        await withTaskGroup(of: [BoardDeparture].self) { g in
            for id in PlanMemo.unique(stopIds) {
                g.addTask {
                    var q: [URLQueryItem] = [.init(name: "stopId", value: id), .init(name: "n", value: String(n))]
                    if let from { q.append(.init(name: "time", value: iso.string(from: from))) }
                    if stops { q.append(.init(name: "fetchStops", value: "true")) }      // its next stops: which way it goes
                    var json = try? await get("/v6/stoptimes", q) as? [String: Any]
                    if json?["stopTimes"] == nil, stops {
                        // A big station's answer with every train's next stops is large: on a weak connection, ask again
                        // without them (a quarter of the size; only the "via" goes)
                        json = try? await get("/v6/stoptimes", q.filter { $0.name != "fetchStops" }) as? [String: Any]
                    }
                    guard let list = json?["stopTimes"] as? [[String: Any]] else { return [] }
                    return list.compactMap { st in
                        let p = st["place"] as? [String: Any] ?? [:]
                        guard let t = date(p["departure"]) ?? date(p["arrival"]) else { return nil }
                        return BoardDeparture(tripId: (st["tripId"] as? String) ?? "", stopId: id, stopName: (p["name"] as? String) ?? "",
                                              line: (st["routeShortName"] as? String) ?? "?", headsign: (st["headsign"] as? String) ?? "",
                                              time: t, scheduled: date(p["scheduledDeparture"]) ?? t, live: (st["realTime"] as? Bool) ?? false,
                                              cancelled: ((st["cancelled"] as? Bool) ?? false) || ((st["tripCancelled"] as? Bool) ?? false) || ((p["cancelled"] as? Bool) ?? false),
                                              platform: (p["track"] as? String) ?? (p["scheduledTrack"] as? String),
                                              heading: heading(st, p),
                                              train: { let m = (st["mode"] as? String) ?? "BUS"; return !(m.contains("BUS") || m.contains("COACH")) }())
                    }
                }
            }
            var all: [BoardDeparture] = []
            for await r in g { all += r }
            let seen = all
            Task { @MainActor in LiveDelays.shared.note(seen) }       // how late each line is running now
            return all.sorted { $0.time < $1.time }
        }
    }

    /// Which way a departure goes: towards its next stops a kilometre or so on (or else its last stop), and their names.
    private static func heading(_ st: [String: Any], _ p: [String: Any]) -> Heading? {
        guard let la = p["lat"] as? Double, let lo = p["lon"] as? Double else { return nil }
        let here = CLLocation(latitude: la, longitude: lo)
        var next: [(name: String, c: CLLocationCoordinate2D)] = ((st["nextStops"] as? [[String: Any]]) ?? []).compactMap { s in
            guard let a = s["lat"] as? Double, let o = s["lon"] as? Double else { return nil }
            return (name: (s["name"] as? String) ?? "", c: CLLocationCoordinate2D(latitude: a, longitude: o))
        }
        let fromStops = !next.isEmpty
        if next.isEmpty, let t = st["tripTo"] as? [String: Any], let a = t["lat"] as? Double, let o = t["lon"] as? Double {
            next = [(name: (t["name"] as? String) ?? "", c: CLLocationCoordinate2D(latitude: a, longitude: o))]
        }
        func far(_ c: CLLocationCoordinate2D) -> Double { here.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude)) }
        guard let ahead = next.first(where: { far($0.c) > 900 }) ?? next.last, far(ahead.c) > 60 else { return nil }
        guard fromStops else { return Heading(degrees: Heading.bearing(here.coordinate, ahead.c)) }
        // "via": the next stop (its own name in this town, or the town), then the next town it reaches
        let town: (String) -> String = { $0.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? $0 }
        let hereTown = town((p["name"] as? String) ?? "")
        var labels: [String] = []
        if let f = next.first { labels.append(town(f.name) == hereTown ? Fmt.place(f.name) : town(f.name)) }
        if let o = next.first(where: { town($0.name) != hereTown && town($0.name) != labels.first }) { labels.append(town(o.name)) }
        return Heading(degrees: Heading.bearing(here.coordinate, ahead.c), via: labels.isEmpty ? nil : labels.joined(separator: " → "))
    }

    /// The last `/v1/map/trips` answer per kind of question (the size of the box, the time around now, every trip or the
    /// first), with where and when it was asked: for `reuse`.
    private final class MapAnswers: @unchecked Sendable {
        private let lock = NSLock()
        private var last: [String: (at: Date, centre: GeoPoint, segs: [VehicleSegment])] = [:]
        func get(_ k: String, near c: GeoPoint, now: Date, speed: Double) -> [VehicleSegment]? {
            lock.lock(); defer { lock.unlock() }
            guard let a = last[k], MapReuse.usable(age: now.timeIntervalSince(a.at), movedMetres: Geo.metres(a.centre, c), allowed: true,
                                                   speed: speed) else { return nil }
            return a.segs
        }
        func put(_ k: String, centre: GeoPoint, segs: [VehicleSegment], at: Date) {
            lock.lock(); last[k] = (at, centre, segs); lock.unlock()
        }
    }
    private static let mapAnswers = MapAnswers()

    /// Vehicles running near a point right now.
    /// `back`/`ahead`: the stretch of time (by their timetables) to look at, around now.
    /// `allTrips`: a piece several trips share (coupled and through trains) gives one segment per trip, not just the first.
    /// `reuse`: the same question's answer of the last 10 s does, when it was asked within 50 m of here (`MapReuse`):
    /// standing about with Fastest trip open, a look every 6 s needn't download it all again. `speed` (yours, m/s; 0.20.7):
    /// at bus speed from as far as that goes in the answer's age too.
    static func vehicles(near c: CLLocationCoordinate2D, radiusDeg: Double = 0.02, back: TimeInterval = 150, ahead: TimeInterval = 90,
                         allTrips: Bool = false, reuse: Bool = false, speed: Double = 0) async -> [VehicleSegment] {
        let now = Date()
        let key = "\(radiusDeg)|\(back)|\(ahead)|\(allTrips)", here = GeoPoint(c)
        if reuse, let kept = mapAnswers.get(key, near: here, now: now, speed: speed) { return kept }
        let q: [URLQueryItem] = [.init(name: "min", value: "\(c.latitude - radiusDeg),\(c.longitude - radiusDeg * 1.6)"),
                                 .init(name: "max", value: "\(c.latitude + radiusDeg),\(c.longitude + radiusDeg * 1.6)"),
                                 .init(name: "startTime", value: iso.string(from: now.addingTimeInterval(-back))),
                                 .init(name: "endTime", value: iso.string(from: now.addingTimeInterval(ahead))),
                                 .init(name: "zoom", value: "15")]
        guard let list = try? await get("/v1/map/trips", q) as? [[String: Any]] else { return [] }
        let segs = vehicleSegments(list, allTrips: allTrips)
        mapAnswers.put(key, centre: here, segs: segs, at: now)
        return segs
    }

    private static func vehicleSegments(_ list: [[String: Any]], allTrips: Bool) -> [VehicleSegment] {
        list.flatMap { s -> [VehicleSegment] in
            guard let trips = s["trips"] as? [[String: Any]], let dep = date(s["departure"]), let arr = date(s["arrival"]),
                  let poly = s["polyline"] as? String else { return [] }
            let mode = (s["mode"] as? String) ?? ""
            let from = s["from"] as? [String: Any], to = s["to"] as? [String: Any]
            let path = decodePolyline(poly), live = (s["realTime"] as? Bool) ?? false
            // the first trip only (a piece whose first trip has no id is left out, as before), or every trip on it
            return (allTrips ? trips : Array(trips.prefix(1))).compactMap { t -> VehicleSegment? in
                guard let id = t["tripId"] as? String else { return nil }
                return VehicleSegment(tripId: id, line: (t["routeShortName"] as? String) ?? "?", isTrain: !(mode.contains("BUS") || mode.contains("COACH")),
                                      fromName: (from?["name"] as? String) ?? "", toName: (to?["name"] as? String) ?? "",
                                      departure: dep, arrival: arr, path: path,
                                      realTime: live, toLat: to?["lat"] as? Double, toLon: to?["lon"] as? Double,
                                      scheduledDeparture: date(s["scheduledDeparture"]), scheduledArrival: date(s["scheduledArrival"]), mode: mode)
            }
        }
    }

    /// Every bus and train running in an area now and in the next few minutes, for the live map of everything near you.
    static func liveVehicles(min a: CLLocationCoordinate2D, max b: CLLocationCoordinate2D) async -> [VehicleSegment] {
        let now = Date()
        let q: [URLQueryItem] = [.init(name: "min", value: "\(a.latitude),\(a.longitude)"), .init(name: "max", value: "\(b.latitude),\(b.longitude)"),
                                 .init(name: "startTime", value: iso.string(from: now.addingTimeInterval(-60))),
                                 .init(name: "endTime", value: iso.string(from: now.addingTimeInterval(240))),
                                 .init(name: "zoom", value: "15")]
        guard let list = try? await get("/v1/map/trips", q) as? [[String: Any]] else { return [] }
        return list.compactMap { s in
            let mode = (s["mode"] as? String) ?? ""
            guard mode != "AIRPLANE", let trips = s["trips"] as? [[String: Any]], let t = trips.first, let id = t["tripId"] as? String,
                  let dep = date(s["departure"]), let arr = date(s["arrival"]), let poly = s["polyline"] as? String else { return nil }
            let train = !(mode.contains("BUS") || mode.contains("COACH"))
            let line = (t["routeShortName"] as? String) ?? "?"
            return VehicleSegment(tripId: id, line: train ? trainLabel(line) : line, isTrain: train,
                                  fromName: ((s["from"] as? [String: Any])?["name"] as? String) ?? "", toName: ((s["to"] as? [String: Any])?["name"] as? String) ?? "",
                                  departure: dep, arrival: arr, path: decodePolyline(poly), realTime: (s["realTime"] as? Bool) ?? false,
                                  scheduledDeparture: date(s["scheduledDeparture"]), scheduledArrival: date(s["scheduledArrival"]), mode: mode)
        }
    }

    /// One /v5/trip answer, shared and remembered; only a body that is a trip (has `legs`) counts, so an error page is
    /// never stored and never replaces a good copy.
    /// `maxAge`: how old the remembered answer may be (nil: 20 s; a ride's own looks take a minute's: `RideTick.tripCache`).
    private static func tripAnswer(_ tripId: String, maxAge: TimeInterval? = nil) async -> Data? {
        await tripAnswers.get(tripId, group: urgent ? 1 : 0, maxAge: maxAge) {
            guard let d = try? await raw("/v5/trip", [.init(name: "tripId", value: tripId)]),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], j["legs"] is [Any] else { return nil }
            return d
        }
    }

    /// Every stop of one trip with its live arrival.
    static func tripStops(_ tripId: String, maxAge: TimeInterval? = nil) async -> [TripStop] {
        guard let data = await tripAnswer(tripId, maxAge: maxAge),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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

    /// Every stop of one trip where it leaves from, with its stop id, its (live) departure, its platform and whether you
    /// may get on there: for where to get on (`BoardAt`, 0.25.1). Nil: no answer.
    static func boardStops(_ tripId: String, maxAge: TimeInterval? = nil) async -> [BoardAt.Stop]? {
        guard let data = await tripAnswer(tripId, maxAge: maxAge),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let legs = json["legs"] as? [[String: Any]] else { return nil }
        var out: [BoardAt.Stop] = []
        func stop(_ o: [String: Any]?) -> BoardAt.Stop? {
            guard let o, let la = o["lat"] as? Double, let lo = o["lon"] as? Double else { return nil }
            let pickup = (o["pickupType"] as? String) ?? "NORMAL"
            let cancelled = (o["cancelled"] as? Bool) ?? false
            let id: String = (o["stopId"] as? String) ?? ""
            let name: String = (o["name"] as? String) ?? ""
            var s = BoardAt.Stop(id: id, name: name, point: GeoPoint(lat: la, lon: lo), departure: date(o["departure"]))
            s.scheduledDeparture = date(o["scheduledDeparture"])
            s.track = o["track"] as? String
            s.scheduledTrack = o["scheduledTrack"] as? String
            s.boarding = pickup != "NOT_ALLOWED" && !cancelled
            s.arrival = date(o["arrival"])
            s.cancelled = cancelled
            return s
        }
        var tripCancelled = false
        for l in legs {
            if out.isEmpty, let s = stop(l["from"] as? [String: Any]) { out.append(s) }
            for o in (l["intermediateStops"] as? [[String: Any]]) ?? [] { if let s = stop(o) { out.append(s) } }
            if let s = stop(l["to"] as? [String: Any]) { out.append(s) }
            if ((l["cancelled"] as? Bool) ?? false) || ((l["tripCancelled"] as? Bool) ?? false) { tripCancelled = true }
        }
        // (0.29) a trip cancelled as a whole: every stop is (only the delay alarm reads it)
        if tripCancelled { for i in out.indices { out[i].cancelled = true } }
        return out.count >= 2 ? out : nil
    }

    /// A bus or train's whole trip with its live times and the road it takes, for the live map.
    static func liveTrip(_ tripId: String, maxAge: TimeInterval? = nil) async -> LiveTrip? {
        if Demo.isDemo(tripId) { return await Demo.liveTrip(tripId) }
        guard let data = await tripAnswer(tripId, maxAge: maxAge),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parseLiveTrip(json)
    }

    /// The last answer for a trip, however old, without asking again.
    /// With the time it was asked, so the screen never shows it as fresh.
    static func cachedLiveTrip(_ tripId: String) async -> (trip: LiveTrip, at: Date)? {
        if Demo.isDemo(tripId) { return await Demo.liveTrip(tripId).map { ($0, Date()) } }
        guard let hit = await tripAnswers.peekDated(tripId),
              let json = try? JSONSerialization.jsonObject(with: hit.value) as? [String: Any],
              let t = parseLiveTrip(json) else { return nil }
        return (t, hit.at)
    }

    private static func parseLiveTrip(_ json: [String: Any]) -> LiveTrip? {
        guard let legs = json["legs"] as? [[String: Any]], !legs.isEmpty else { return nil }
        var stops: [LiveTrip.Stop] = [], path: [CLLocationCoordinate2D] = [], live = false, line = "", head = "", mode = "", num = ""
        func stop(_ o: [String: Any]?) -> LiveTrip.Stop? {
            guard let o, let la = o["lat"] as? Double, let lo = o["lon"] as? Double else { return nil }
            return LiveTrip.Stop(name: (o["name"] as? String) ?? "", coordinate: .init(latitude: la, longitude: lo),
                                 arrival: date(o["arrival"]), departure: date(o["departure"]),
                                 scheduled: date(o["scheduledArrival"]) ?? date(o["scheduledDeparture"]),
                                 scheduledArrival: date(o["scheduledArrival"]), scheduledDeparture: date(o["scheduledDeparture"]))
        }
        for l in legs {
            line = (l["routeShortName"] as? String) ?? line
            head = (l["headsign"] as? String) ?? head
            mode = (l["mode"] as? String) ?? mode
            if num.isEmpty { num = text(l["tripShortName"]) }
            live = live || ((l["realTime"] as? Bool) ?? false)
            if stops.isEmpty, let x = stop(l["from"] as? [String: Any]) { stops.append(x) }
            for o in (l["intermediateStops"] as? [[String: Any]]) ?? [] { if let x = stop(o) { stops.append(x) } }
            if let x = stop(l["to"] as? [String: Any]) { stops.append(x) }
            if let g = l["legGeometry"] as? [String: Any], let pts = g["points"] as? String {
                path += decodePolyline(pts, precision: (g["precision"] as? Int) ?? 5)
            }
        }
        guard stops.count >= 2 else { return nil }
        var t = LiveTrip(line: line, headsign: head, live: live, stops: stops, path: path, mode: mode)
        t.num = num
        return t
    }

    static func decodePolyline(_ s: String, precision: Int = 5) -> [CLLocationCoordinate2D] {
        let scale = pow(10.0, Double(precision))
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
            pts.append(.init(latitude: Double(lat) / scale, longitude: Double(lng) / scale))
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

    /// `grade` without remembering a new fastest time (it doesn't write anything).
    func peekGrade(key k: String, minutes: Double, scheduled: Double, cancelled: Bool) -> String? {
        ChangeRoom.speedGrade(minutes: minutes, scheduled: scheduled, best: best[k], cancelled: cancelled)
    }
}
