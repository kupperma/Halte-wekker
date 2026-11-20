import Foundation

// 0.36: NS disruptions and planned engineering works on the trains you usually take (home ⇄ school, your planned
// trips), today and the next 7 days. Read from the relay's `/ns/disruptions?stations=…` (NS's Reisinformatie API v3,
// slimmed), matched to your rides here. Foundation only, so the matching and the words are tested.

enum RailWorks {
    /// When it's on, and what it does then.
    struct Span: Equatable, Sendable {
        let start: Date
        let end: Date
        /// NS runs buses instead ("er rijden (stop)bussen").
        var buses = false
        /// No trains on the stretch (NS: "geen treinen", or buses instead), else fewer.
        var noTrains = false
    }

    /// One disruption or planned works, as NS publishes it.
    struct Item: Equatable, Sendable {
        let id: String
        /// Planned engineering works (NS's MAINTENANCE), else a disruption.
        let works: Bool
        let title: String
        let spans: [Span]
        /// The stretches it touches, each its stations in order (NS's codes): the consequence's when given, else the section's.
        let stretches: [[String]]
        /// The stations' names, by code ("TB": "Tilburg").
        let names: [String: String]
    }

    /// A train ride you usually take: from one station to another (NS's codes).
    struct Ride: Hashable, Codable, Sendable {
        let from: String
        let to: String
    }

    // MARK: reading NS's answer

    private static let nsTime: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"; return f
    }()
    static func time(_ a: Any?) -> Date? {
        guard let s = a as? String else { return nil }
        if let d = nsTime.date(from: s) { return d }
        let iso = ISO8601DateFormatter()
        return iso.date(from: s)
    }

    /// NS's list (an array, or `{ "payload": [...] }`). Calamities (no stretch) and entries without times are left out.
    static func parse(_ data: Data) -> [Item] {
        guard let j = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let list: [[String: Any]] = (j as? [[String: Any]]) ?? ((j as? [String: Any])?["payload"] as? [[String: Any]]) ?? []
        return list.compactMap(item)
    }

    static func item(_ d: [String: Any]) -> Item? {
        let id = text(d["id"])
        guard !id.isEmpty else { return nil }
        let type = text(d["type"]).uppercased()
        guard type != "CALAMITY" else { return nil }
        var names: [String: String] = [:]
        var stretches: [[String]] = []
        var anyNoTrains = false
        for p in (d["publicationSections"] as? [[String: Any]]) ?? [] {
            let cons = p["consequence"] as? [String: Any]
            func codes(_ sec: Any?) -> [String] {
                ((sec as? [String: Any])?["stations"] as? [[String: Any]] ?? []).compactMap { s in
                    let c = text(s["stationCode"]).uppercased()
                    guard !c.isEmpty else { return nil }
                    let n = text(s["name"])
                    if !n.isEmpty, names[c] == nil { names[c] = n }
                    return c
                }
            }
            let whole = codes(p["section"])
            let hit = codes(cons?["section"])
            let s = hit.count >= 2 ? hit : whole
            if !s.isEmpty { stretches.append(s) }
            let words = (text(cons?["description"]) + " " + text(cons?["level"])).lowercased()
            if noTrainsWords(words) { anyNoTrains = true }
        }
        guard !stretches.isEmpty else { return nil }
        var spans: [Span] = []
        for t in (d["timespans"] as? [[String: Any]]) ?? [] {
            guard let a = time(t["start"]) else { continue }
            let b = time(t["end"]) ?? a.addingTimeInterval(4 * 3600)
            let alt = text((t["alternativeTransport"] as? [String: Any])?["label"]).lowercased()
            let sit = text((t["situation"] as? [String: Any])?["label"]).lowercased()
            let buses = alt.contains("bus") || sit.contains("bussen")
            spans.append(Span(start: a, end: b, buses: buses, noTrains: buses || anyNoTrains || noTrainsWords(sit)))
        }
        if spans.isEmpty, let a = time(d["start"]) {
            spans.append(Span(start: a, end: time(d["end"]) ?? a.addingTimeInterval(4 * 3600), buses: false, noTrains: anyNoTrains))
        }
        guard !spans.isEmpty else { return nil }
        return Item(id: id, works: type == "MAINTENANCE", title: text(d["title"]), spans: spans, stretches: stretches, names: names)
    }

    private static func noTrainsWords(_ s: String) -> Bool {
        s.contains("geen trein") || s.contains("no_trains") || s.contains("no trains") || s.contains("rijden bussen")
            || s.contains("rijden er bussen") || s.contains("no_or_much_less")
    }

    private static func text(_ a: Any?) -> String {
        if let s = a as? String { return s }
        if let n = a as? NSNumber { return n.stringValue }
        return ""
    }

    // MARK: is it on your ride?

    /// Within this of the straight line between a ride's two stations, and between them, a station is on its way.
    static let corridorMetres = 2500.0

    /// The stations of `stretch` your ride passes: its own two, and those it goes past (near the straight line between
    /// them, not behind either end). `point`: where a station is.
    static func passed(_ ride: Ride, stretch: [String], point: (String) -> GeoPoint?) -> [String] {
        guard let a = point(ride.from), let b = point(ride.to) else {
            return stretch.filter { $0 == ride.from || $0 == ride.to }
        }
        let len = Geo.metres(a, b)
        return stretch.filter { c in
            if c == ride.from || c == ride.to { return true }
            guard let p = point(c), len > 0 else { return false }
            // (a flat projection is plenty over a few tens of kilometres)
            let kx = Geo.metres(GeoPoint(lat: a.lat, lon: a.lon), GeoPoint(lat: a.lat, lon: a.lon + 1))
            let ky = Geo.metres(GeoPoint(lat: a.lat, lon: a.lon), GeoPoint(lat: a.lat + 1, lon: a.lon))
            let bx = (b.lon - a.lon) * kx, by = (b.lat - a.lat) * ky
            let px = (p.lon - a.lon) * kx, py = (p.lat - a.lat) * ky
            let t = (px * bx + py * by) / (len * len)
            guard t > 0, t < 1 else { return false }
            let dx = px - t * bx, dy = py - t * by
            return (dx * dx + dy * dy).squareRoot() <= corridorMetres
        }
    }

    /// The part of the item's stretches your ride runs on (two of its stations or more on your way), the first such.
    static func hit(_ item: Item, _ ride: Ride, point: (String) -> GeoPoint?) -> [String]? {
        for s in item.stretches {
            let p = passed(ride, stretch: s, point: point)
            if p.count >= 2 { return p }
        }
        return nil
    }

    // MARK: on which days

    /// What's on a day you travel: the item, the ride it hits, and the stretch of it on your way (first–last).
    struct Impact: Equatable, Sendable {
        let id: String
        /// The day, "yyyy-MM-dd" (Amsterdam).
        let day: String
        let dayStart: Date
        let ride: Ride
        let fromName: String
        let toName: String
        let works: Bool
        let noTrains: Bool
        let buses: Bool
        /// Its first span that day (for the card).
        let start: Date
        let end: Date
        var key: String { "\(day)|\(id)|\(ride.from)>\(ride.to)" }
    }

    static let zone = TimeZone(identifier: "Europe/Amsterdam")!
    static var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = zone; return c }
    static func dayKey(_ d: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// When you'd be on the train that day, to check against: given (a school day's leave → class), else 05:00–24:00.
    static func defaultWindow(_ dayStart: Date) -> (Date, Date) {
        (dayStart.addingTimeInterval(5 * 3600), dayStart.addingTimeInterval(24 * 3600))
    }

    /// Today and the next `days` days: each item that's on during your travel window that day, on one of your rides.
    /// One impact per item, day and ride; the soonest first.
    static func impacts(_ items: [Item], rides: [Ride], now: Date, days: Int = 7,
                        window: (Date) -> (Date, Date)? = { RailWorks.defaultWindow($0) },
                        point: (String) -> GeoPoint?) -> [Impact] {
        let cal = calendar
        let today = cal.startOfDay(for: now)
        var out: [Impact] = []
        for n in 0...days {
            guard let start = cal.date(byAdding: .day, value: n, to: today), let w = window(start) else { continue }
            let from = max(w.0, n == 0 ? now : w.0), to = w.1
            guard to > from else { continue }
            for item in items {
                let on = item.spans.filter { $0.start < to && $0.end > from }
                guard let first = on.min(by: { $0.start < $1.start }) else { continue }
                for r in rides {
                    guard let stretch = hit(item, r, point: point) else { continue }
                    let a = stretch.first!, b = stretch.last!
                    out.append(Impact(id: item.id, day: dayKey(start), dayStart: start, ride: r,
                                      fromName: item.names[a] ?? a, toName: item.names[b] ?? b, works: item.works,
                                      noTrains: on.contains { $0.noTrains }, buses: on.contains { $0.buses },
                                      start: first.start, end: first.end))
                }
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.key).inserted }.sorted { ($0.dayStart, $0.start) < ($1.dayStart, $1.start) }
    }

    // MARK: the words

    /// "Today", "Tomorrow", "Thursday"
    static func dayWord(_ dayStart: Date, now: Date) -> String {
        let cal = calendar
        let today = cal.startOfDay(for: now)
        let n = cal.dateComponents([.day], from: today, to: dayStart).day ?? 0
        if n == 0 { return "Today" }
        if n == 1 { return "Tomorrow" }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.timeZone = zone; f.dateFormat = "EEEE"
        return f.string(from: dayStart)
    }

    /// How much earlier you'd leave than usual: the day's planned leave against the usual one (the usual door-to-door
    /// minutes before when you want to be there). Nil when it's less than 3 minutes, or not known.
    static func leaveEarlier(usualMinutes: Double?, newLeave: Date?, beThere: Date?) -> Int? {
        guard let u = usualMinutes, u.isFinite, u > 0, let l = newLeave, let t = beThere else { return nil }
        let usualLeave = t.addingTimeInterval(-u * 60)
        let m = Int((usualLeave.timeIntervalSince(l) / 60).rounded())
        return m >= 3 ? m : nil
    }

    /// "Thursday: no trains Tilburg–Breda (works). Leave 10 min earlier — buses replace trains"
    static func headline(_ i: Impact, now: Date, earlier: Int?) -> String {
        let what = i.noTrains ? "no trains" : "fewer trains"
        let why = i.works ? "works" : "disruption"
        var s = "\(dayWord(i.dayStart, now: now)): \(what) \(i.fromName)–\(i.toName) (\(why))."
        if let e = earlier {
            s += " Leave \(e) min earlier"
            if i.buses { s += " — buses replace trains" }
        } else if i.buses {
            s += " Buses replace trains — allow extra time"
        } else {
            s += " Allow extra time"
        }
        return s
    }

    // MARK: when to tell

    /// Fetched at most this often (a background refresh or the app coming to the front fetch, nothing else).
    static let fetchEvery: TimeInterval = 4 * 3600

    /// The evening before a day: its notification comes at 19:30 the day before.
    static func eveningBefore(_ dayStart: Date) -> Date {
        calendar.date(byAdding: .day, value: -1, to: dayStart)!.addingTimeInterval(19.5 * 3600)
    }

    /// The evening-before notification still makes sense now: before 23:00 the evening before (a later look tells at
    /// once when 19:30 has passed), and the day hasn't begun.
    static func tellNow(_ i: Impact, now: Date) -> Bool {
        let e = eveningBefore(i.dayStart)
        return now >= e && now < e.addingTimeInterval(3.5 * 3600)
    }
}
