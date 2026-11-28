import Foundation

/// (0.42.17) Belgian trains from iRail (open NMBS/SNCB data), through the relay's `/be/liveboard`, `/be/vehicle` and
/// `/be/composition` (relay/irail.js): read here, pure, the same on Android (`IRail.kt`), checked on
/// docs/belgium-vectors.json. Transitous already has SNCB's trains and often their live times, but no platforms: iRail
/// gives the platform (and whether it changed), cancellations, the delay and how busy it is.
/// iRail has no GPS: a Belgian train is placed by its stop times and delays, as any train without GPS.
enum IRail {
    /// One departure on a Belgian station's board, as NS's board rows are read (`NSDeparture`).
    struct Departure: Equatable, Sendable {
        var num: String
        var planned: Date?
        var actual: Date?
        var track: String
        /// iRail has no planned platform: the platform when it didn't change, else "".
        var plannedTrack: String
        var changed: Bool
        var cancelled: Bool
        /// 1 quiet, 2 busy, 3 very busy, 0 not known (as NS's crowd forecast).
        var crowd: Int
    }

    static func date(_ a: Any?) -> Date? {
        guard let s = a as? String, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    static func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

    private static func text(_ a: Any?) -> String {
        if let s = a as? String { return s }
        if let n = a as? NSNumber { return n.stringValue }
        return ""
    }

    private static func seconds(_ a: Any?) -> Double { (a as? NSNumber)?.doubleValue ?? Double(text(a)) ?? 0 }

    private static func json(_ data: Data?) -> [String: Any]? {
        guard let data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The relay's `/be/liveboard` answer. Nil: not one.
    static func departures(_ data: Data?) -> [Departure]? {
        guard let d = json(data), let list = d["departures"] as? [[String: Any]] else { return nil }
        return list.map { x -> Departure in
            let planned: Date? = date(x["planned"])
            let track: String = text(x["platform"])
            let changed: Bool = (x["platformChanged"] as? Bool) ?? false
            let crowd: Int = ["low": 1, "medium": 2, "high": 3][text(x["occupancy"])] ?? 0
            return Departure(num: text(x["num"]), planned: planned, actual: planned.map { $0.addingTimeInterval(seconds(x["delay"])) },
                             track: track, plannedTrack: changed ? "" : track, changed: changed,
                             cancelled: (x["canceled"] as? Bool) ?? false, crowd: crowd)
        }
    }

    /// The relay's `/be/composition` answer: carriages and seats (nil: none known).
    static func composition(_ data: Data?) -> (cars: Int, seats: Int)? {
        guard let d = json(data) else { return nil }
        let cars: Int = Int(seconds(d["cars"]))
        guard cars > 0 else { return nil }
        return (cars, Int(seconds(d["seats"])))
    }

    /// A rail leg, as Transitous names its mode.
    static func isRail(_ mode: String) -> Bool {
        mode.contains("RAIL") || mode == "LONG_DISTANCE" || mode == "SUBURBAN"
    }

    /// The train number to ask iRail about for a Transitous trip: its first rail leg with a plain number that stops in
    /// Belgium. Nil: none (a Dutch train, a bus).
    static func trainNumber(_ trip: [String: Any]) -> String? {
        for l in (trip["legs"] as? [[String: Any]]) ?? [] {
            guard isRail(text(l["mode"])) else { continue }
            let n: String = text(l["tripShortName"])
            guard (1...6).contains(n.count), n.allSatisfy({ $0.isASCII && $0.isNumber }) else { continue }
            if stops(l).contains(where: { s in Country.of(id: text(s["stopId"]), lat: s["lat"] as? Double, lon: s["lon"] as? Double) == .be }) { return n }
        }
        return nil
    }

    /// The relay's question for that train: `/be/vehicle?id=9235&date=281126` (its service day from the trip id, when it
    /// has one). Nil: no number.
    static func vehiclePath(tripId: String, num: String) -> String? {
        guard (1...6).contains(num.count), num.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        let day: Substring = tripId.prefix { $0 != "_" }
        if day.count == 8, day.allSatisfy({ $0.isASCII && $0.isNumber }) {
            let y = day.dropFirst(2).prefix(2), m = day.dropFirst(4).prefix(2), dd = day.dropFirst(6).prefix(2)
            return "/be/vehicle?id=\(num)&date=\(dd)\(m)\(y)"
        }
        return "/be/vehicle?id=\(num)"
    }

    private static func stops(_ leg: [String: Any]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        if let f = leg["from"] as? [String: Any] { out.append(f) }
        out += (leg["intermediateStops"] as? [[String: Any]]) ?? []
        if let t = leg["to"] as? [String: Any] { out.append(t) }
        return out
    }

    /// The iRail stop a Transitous stop is: the same UIC, else the nearest within 400 m.
    private static func match(_ s: [String: Any], in list: [[String: Any]]) -> [String: Any]? {
        if let u = Country.uic(text(s["stopId"])), let hit = list.first(where: { text($0["uic"]) == u }) { return hit }
        guard let la = s["lat"] as? Double, let lo = s["lon"] as? Double else { return nil }
        let p = GeoPoint(lat: la, lon: lo)
        var best: (stop: [String: Any], m: Double)? = nil
        for x in list {
            guard let a = x["lat"] as? Double, let b = x["lon"] as? Double else { continue }
            let m: Double = Geo.metres(p, GeoPoint(lat: a, lon: b))
            if m <= 400, best.map({ m < $0.m }) ?? true { best = (x, m) }
        }
        return best?.stop
    }

    /// One Transitous stop with iRail's: its platform when Transitous has none, cancelled when iRail says, and (when
    /// `retime`: Transitous had no live times) its timetable times moved by iRail's delays. `live`: iRail said
    /// something live about it.
    private static func patch(_ s: [String: Any], with v: [String: Any], retime: Bool) -> (stop: [String: Any], live: Bool) {
        var o: [String: Any] = s
        let platform: String = text(v["platform"])
        let changed: Bool = (v["platformChanged"] as? Bool) ?? false
        if !platform.isEmpty {
            if text(o["track"]).isEmpty { o["track"] = platform }
            if text(o["scheduledTrack"]).isEmpty && !changed { o["scheduledTrack"] = platform }
        }
        if ((v["arrivalCanceled"] as? Bool) ?? false) || ((v["departureCanceled"] as? Bool) ?? false) { o["cancelled"] = true }
        let ad: Double = seconds(v["arrivalDelay"]), dd: Double = seconds(v["departureDelay"])
        let live: Bool = ad != 0 || dd != 0 || ((v["arrived"] as? Bool) ?? false) || ((v["left"] as? Bool) ?? false)
        if retime {
            if let a = date(o["scheduledArrival"]) { o["arrival"] = iso(a.addingTimeInterval(ad)) }
            if let d = date(o["scheduledDeparture"]) { o["departure"] = iso(d.addingTimeInterval(dd)) }
        }
        return (o, live)
    }

    /// A Transitous trip (`/v5/trip`) with iRail's answer for its train (`/be/vehicle`) laid over it: on each rail leg
    /// of that train, each Belgian stop gets its platform, its cancellation and, when Transitous had no live times,
    /// iRail's delays (the leg is then live). Dutch stops are left to NS. Another train's answer changes nothing.
    static func overlay(trip: [String: Any], vehicle: [String: Any]) -> [String: Any] {
        let num: String = text(vehicle["num"])
        let list: [[String: Any]] = (vehicle["stops"] as? [[String: Any]]) ?? []
        guard !num.isEmpty, !list.isEmpty, var legs = trip["legs"] as? [[String: Any]] else { return trip }
        for k in legs.indices {
            var l: [String: Any] = legs[k]
            guard isRail(text(l["mode"])), text(l["tripShortName"]) == num else { continue }
            let retime: Bool = !((l["realTime"] as? Bool) ?? false)
            var live = false
            func one(_ s: [String: Any]) -> [String: Any] {
                guard let v = match(s, in: list), text(v["uic"]).hasPrefix("88") else { return s }
                let r = patch(s, with: v, retime: retime)
                if r.live { live = true }
                return r.stop
            }
            if let f = l["from"] as? [String: Any] { l["from"] = one(f) }
            if let mid = l["intermediateStops"] as? [[String: Any]] { l["intermediateStops"] = mid.map(one) }
            if let t = l["to"] as? [String: Any] { l["to"] = one(t) }
            if retime && live {
                l["realTime"] = true
                if let d = (l["from"] as? [String: Any])?["departure"] { l["startTime"] = d }
                if let a = (l["to"] as? [String: Any])?["arrival"] { l["endTime"] = a }
            }
            legs[k] = l
        }
        var out: [String: Any] = trip
        out["legs"] = legs
        return out
    }

    /// The same on the answers' bytes (the app keeps Transitous's answer as it came): nil when either isn't one.
    static func overlay(tripData: Data, vehicleData: Data?) -> Data? {
        guard let t = json(tripData), let v = json(vehicleData) else { return nil }
        return try? JSONSerialization.data(withJSONObject: overlay(trip: t, vehicle: v))
    }
}
