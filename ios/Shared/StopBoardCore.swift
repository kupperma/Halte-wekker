import Foundation

/// 0.37: the next departures from one stop, for the home-screen widget and Siri — read straight from Transitous
/// (`/v6/stoptimes`, `/v1/geocode`), with no App Group: the widget asks itself, on its own timeline. Plain values and
/// pure functions (Foundation only), shared by the app, the widget and the tests.
enum StopBoardCore {
    static let base = "https://api.transitous.org/api"
    static let userAgent = "Haltewekker-iOS/0.37 (https://github.com/kupperma/Halte-wekker)"

    // MARK: a departure

    struct Departure: Equatable, Hashable, Codable, Sendable {
        let line: String            // "305", "IC", "SPR"
        let headsign: String
        let time: Date              // when it leaves: live, else planned
        let scheduled: Date
        let live: Bool
        let cancelled: Bool
        let train: Bool
        var platform: String? = nil
        /// Minutes late (negative: early); 0 without live times.
        var delay: Int { live ? Int((time.timeIntervalSince(scheduled) / 60).rounded()) : 0 }
    }

    /// A train's line as the app shows it: "IC", "ICD", "SPR", else its first four letters.
    static func trainLabel(_ n: String) -> String {
        let l = n.lowercased()
        if l.contains("intercity direct") { return "ICD" }
        if l.contains("intercity") { return "IC" }
        if l.contains("sprinter") { return "SPR" }
        return String(n.prefix(4))
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    static func date(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        return iso.date(from: s) ?? isoFrac.date(from: s)
    }
    static func isoString(_ d: Date) -> String { iso.string(from: d) }

    /// Transitous's `/v6/stoptimes` answer: its departures, soonest first (an arrival-only one, the end of a line, is
    /// left out).
    static func parseStoptimes(_ data: Data) -> [Departure] {
        guard let j = try? JSONSerialization.jsonObject(with: data) else { return [] }
        return parseStoptimes(json: j)
    }

    static func parseStoptimes(json: Any) -> [Departure] {
        guard let list = (json as? [String: Any])?["stopTimes"] as? [[String: Any]] else { return [] }
        let out: [Departure] = list.compactMap { st in
            let p = st["place"] as? [String: Any] ?? [:]
            guard let t = date(p["departure"]) else { return nil }
            let mode = (st["mode"] as? String) ?? "BUS"
            let train = !(mode.contains("BUS") || mode.contains("COACH") || mode.contains("TRAM") || mode.contains("SUBWAY")
                          || mode.contains("METRO") || mode.contains("FERRY"))
            let short = (st["routeShortName"] as? String) ?? ""
            let name = short.isEmpty ? ((st["displayName"] as? String) ?? (st["routeLongName"] as? String) ?? "?") : short
            let cancelled = ((st["cancelled"] as? Bool) ?? false) || ((st["tripCancelled"] as? Bool) ?? false)
                || ((p["cancelled"] as? Bool) ?? false)
            return Departure(line: train ? trainLabel(name) : name, headsign: (st["headsign"] as? String) ?? "",
                             time: t, scheduled: date(p["scheduledDeparture"]) ?? t, live: (st["realTime"] as? Bool) ?? false,
                             cancelled: cancelled, train: train,
                             platform: (p["track"] as? String) ?? (p["scheduledTrack"] as? String))
        }
        return out.sorted { $0.time < $1.time }
    }

    // MARK: a stop

    struct Stop: Equatable, Hashable, Codable, Sendable {
        let id: String              // Transitous's stop id
        let name: String
        var town: String = ""
        let lat: Double
        let lon: Double
        var rail = false
    }

    /// Transitous's `/v1/geocode` answer (type STOP): the stops it found.
    static func parseGeocode(_ data: Data) -> [Stop] {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return list.compactMap { m in
            guard let id = m["id"] as? String, !id.isEmpty, let name = m["name"] as? String,
                  let la = m["lat"] as? Double, let lo = m["lon"] as? Double else { return nil }
            if let t = m["type"] as? String, t != "STOP" { return nil }
            let areas = (m["areas"] as? [[String: Any]]) ?? []
            let a = areas.first { ($0["default"] as? Bool) == true } ?? areas.first { ($0["matched"] as? Bool) == true } ?? areas.first
            let modes = (m["modes"] as? [String]) ?? []
            let rail = modes.contains { $0.contains("RAIL") || $0 == "LONG_DISTANCE" || $0 == "HIGHSPEED" }
                || (modes.isEmpty && name.lowercased().hasPrefix("station "))
            return Stop(id: id, name: name, town: (a?["name"] as? String) ?? "", lat: la, lon: lo, rail: rail)
        }
    }

    /// A stop as one string (an App Intents entity's id, kept by the widget's settings and by Shortcuts): everything
    /// needed to ask for it again, without the app's data. Fields joined by a unit separator.
    static func encode(_ s: Stop) -> String {
        let sep = "\u{1F}"
        func clean(_ t: String) -> String { t.replacingOccurrences(of: sep, with: " ") }
        return ["s1", clean(s.id), clean(s.name), clean(s.town), String(format: "%.6f", s.lat), String(format: "%.6f", s.lon),
                s.rail ? "1" : "0"].joined(separator: sep)
    }

    static func decode(_ id: String) -> Stop? {
        let f = id.components(separatedBy: "\u{1F}")
        guard f.count == 7, f[0] == "s1", !f[1].isEmpty, let la = Double(f[4]), let lo = Double(f[5]) else { return nil }
        return Stop(id: f[1], name: f[2], town: f[3], lat: la, lon: lo, rail: f[6] == "1")
    }

    // MARK: asking Transitous

    static func stoptimesURL(stopId: String, from: Date, n: Int = 12) -> URL? {
        var c = URLComponents(string: base + "/v6/stoptimes")
        c?.queryItems = [.init(name: "stopId", value: stopId), .init(name: "n", value: String(n)),
                         .init(name: "time", value: isoString(from))]
        return c?.url
    }

    static func geocodeURL(_ text: String, near: (lat: Double, lon: Double)? = nil) -> URL? {
        var c = URLComponents(string: base + "/v1/geocode")
        var q: [URLQueryItem] = [.init(name: "text", value: text), .init(name: "type", value: "STOP"), .init(name: "numResults", value: "12")]
        if let n = near { q.append(.init(name: "place", value: "\(n.lat),\(n.lon)")) }
        c?.queryItems = q
        return c?.url
    }

    // MARK: opening the app on a stop

    /// haltewekker://stop?id=…&name=…&lat=…&lon=…&rail=1 (the widget's tap).
    static func link(_ s: Stop) -> URL? {
        // (each value fully escaped: an id or a name with "&" or "=" in it stays one value)
        let ok = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func e(_ t: String) -> String { t.addingPercentEncoding(withAllowedCharacters: ok) ?? "" }
        let q = "id=\(e(s.id))&name=\(e(s.name))&lat=\(String(format: "%.6f", s.lat))&lon=\(String(format: "%.6f", s.lon))&rail=\(s.rail ? "1" : "0")"
        return URL(string: "haltewekker://stop?" + q)
    }

    static func parseLink(_ url: URL) -> Stop? {
        guard url.scheme?.lowercased() == "haltewekker", url.host?.lowercased() == "stop",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func v(_ k: String) -> String? { items.first { $0.name == k }?.value }
        guard let id = v("id"), !id.isEmpty, let la = v("lat").flatMap(Double.init), let lo = v("lon").flatMap(Double.init),
              (-90...90).contains(la), (-180...180).contains(lo) else { return nil }
        return Stop(id: id, name: v("name") ?? "Stop", lat: la, lon: lo, rail: v("rail") == "1")
    }

    // MARK: the widget's timeline

    struct Entry: Equatable, Sendable {
        let date: Date
        /// What leaves from then on, soonest first (at most `count`).
        let departures: [Departure]
    }

    /// The departures still to leave at `at` (one that left in the last half minute stays a moment; a cancelled one
    /// shows until its time).
    static func upcoming(_ deps: [Departure], at: Date, count: Int) -> [Departure] {
        Array(deps.filter { $0.time.addingTimeInterval(30) > at }.sorted { $0.time < $1.time }.prefix(count))
    }

    /// A timeline from one answer: an entry now, then one just after each departure leaves (so the list moves up
    /// without asking again), until the next refresh — every `refresh` seconds (WidgetKit's budget: some 10–15 min),
    /// sooner when the answer runs out of departures to show, later (30 min) with nothing leaving at all.
    static func timeline(_ deps: [Departure], now: Date, count: Int, refresh: TimeInterval = 12 * 60,
                         maxEntries: Int = 12) -> (entries: [Entry], reloadAt: Date) {
        let sorted = deps.sorted { $0.time < $1.time }
        let first = upcoming(sorted, at: now, count: count)
        guard !first.isEmpty else { return ([Entry(date: now, departures: [])], now.addingTimeInterval(30 * 60)) }
        var reload = now.addingTimeInterval(refresh)
        // the answer only knows so far: ask again before the list would run short
        let known = sorted.filter { $0.time.addingTimeInterval(30) > now }
        if known.count > count {
            let shortAt = known[known.count - count].time.addingTimeInterval(30)
            if shortAt < reload { reload = max(now.addingTimeInterval(5 * 60), shortAt) }
        } else {
            reload = max(now.addingTimeInterval(5 * 60), min(reload, known.first!.time.addingTimeInterval(30)))
        }
        var entries = [Entry(date: now, departures: first)]
        for d in known {
            let at = d.time.addingTimeInterval(30)
            guard at > now, at < reload, entries.count < maxEntries else { continue }
            if let last = entries.last, at.timeIntervalSince(last.date) < 20 { continue }
            entries.append(Entry(date: at, departures: upcoming(sorted, at: at, count: count)))
        }
        return (entries, reload)
    }

    // MARK: the words

    /// "Bus 305", "IC", "Tram 4"… as a departure's name.
    static func title(_ d: Departure) -> String {
        if d.train { return d.line }
        return d.line.allSatisfy({ $0.isNumber || $0.isLetter }) && d.line.count <= 5 ? "Bus \(d.line)" : d.line
    }

    /// "07:41 (+2)", "07:41 (−1)", "07:41" (on time or no live times), "07:41 cancelled".
    static func timeText(_ d: Departure, hhmm: (Date) -> String) -> String {
        if d.cancelled { return "\(hhmm(d.scheduled)) cancelled" }
        let late = d.delay
        if late > 0 { return "\(hhmm(d.time)) (+\(late))" }
        if late < 0 { return "\(hhmm(d.time)) (−\(-late))" }
        return hhmm(d.time)
    }

    /// What Siri says: "Bus 305 to Uden leaves Veghel, Busstation at 07:41, 2 minutes late — in 6 minutes. Then the 306
    /// at 07:52." Nothing leaving: says so.
    static func spoken(_ deps: [Departure], stop: String, now: Date, hhmm: (Date) -> String) -> String {
        let next = upcoming(deps.filter { !$0.cancelled }, at: now, count: 2).filter { $0.time >= now.addingTimeInterval(-30) }
        guard let a = next.first else { return "Nothing leaves \(stop) in the next while." }
        let to = a.headsign.isEmpty ? "" : " to \(a.headsign)"
        let m = max(0, Int((a.time.timeIntervalSince(now) / 60).rounded(.down)))
        let when = m == 0 ? "now" : m == 1 ? "in 1 minute" : "in \(m) minutes"
        var late = ""
        if a.delay > 0 { late = ", \(a.delay) minute\(a.delay == 1 ? "" : "s") late" }
        else if a.delay < 0 { late = ", \(-a.delay) minute\(a.delay == -1 ? "" : "s") early" }
        var s = "\(title(a))\(to) leaves \(stop) at \(hhmm(a.time))\(late) — \(when)."
        if next.count > 1 {
            let b = next[1]
            s += " Then the \(b.line) at \(hhmm(b.time))."
        }
        return s
    }
}
