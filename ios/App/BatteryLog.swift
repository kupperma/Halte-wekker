import Foundation

// The battery and data log (0.20.7): what the app itself costs, counted cheaply as it happens (a few integer adds under
// a lock, no strings, no I/O per event) and written with the field log's flush. iOS gives an app no energy figure of
// its own, so this is the app's own count: GPS minutes, requests and bytes, radio wakes, CPU time, time in front and
// behind, Live Activity updates, matcher checks, and the battery level around each ride. No coordinates, no place or
// stop names, no queries: kinds, counts, bytes, seconds and percent only.

/// GPS accuracy as the log counts it.
enum GPSMode: String, Codable, CaseIterable, Sendable {
    case best, tenMetres, hundredMetres

    var label: String {
        switch self {
        case .best: return "best"
        case .tenMetres: return "10 m"
        case .hundredMetres: return "100 m"
        }
    }

    /// A rough weight per minute, for the bars (the best is 1).
    var weight: Double {
        switch self {
        case .best: return 1
        case .tenMetres: return 0.8
        case .hundredMetres: return 0.2
        }
    }
}

/// Why GPS was on.
enum GPSReason: String, Codable, CaseIterable, Sendable {
    case ride, change, fastest, regionLook, lineWatch, home, walk

    var label: String {
        switch self {
        case .ride: return "rides"
        case .change: return "changes"
        case .fastest: return "Fastest trip"
        case .regionLook: return "station look"
        case .lineWatch: return "line watch"
        case .home: return "home screen"
        case .walk: return "walking with arrows"
        }
    }
}

/// What a request was for.
enum CostKind: String, Codable, CaseIterable, Sendable {
    case plan, trip, stoptimes, mapTrips, mapStops, geocode, ovapi, nsVehicles, relay, spotify, weather, directions, other

    var label: String {
        switch self {
        case .plan: return "plans"
        case .trip: return "trips"
        case .stoptimes: return "boards"
        case .mapTrips: return "map trips"
        case .mapStops: return "map stops"
        case .geocode: return "search"
        case .ovapi: return "OVapi positions"
        case .nsVehicles: return "NS positions"
        case .relay: return "NS and alerts"
        case .spotify: return "Spotify"
        case .weather: return "weather"
        case .directions: return "walking routes"
        case .other: return "other"
        }
    }

    /// The kind of a request by its address: the host for the feeds and services, else the path (a Transitous path as
    /// the field log names it, "/v5/plan", or a whole URL's path, "/api/v5/plan").
    static func of(path: String, host: String? = nil) -> CostKind {
        let h = (host ?? "").lowercased(), p = path.lowercased()
        if h.contains("spotify") { return .spotify }
        if h.contains("open-meteo") { return .weather }
        if h.contains("ovapi") || p.hasSuffix("vehiclepositions.pb") { return .ovapi }
        if p.contains("/ns/vehicles") { return .nsVehicles }
        if p.contains("/map/trips") { return .mapTrips }
        if p.contains("/map/stops") { return .mapStops }
        if p.contains("/plan") { return .plan }
        if p.contains("stoptimes") { return .stoptimes }
        if p.contains("geocode") { return .geocode }
        if p.contains("/v5/trip") || p.hasSuffix("/trip") { return .trip }
        if p.hasPrefix("/ns/") || p.contains("/ns/") || p.hasPrefix("/watch") || p.hasPrefix("/push") { return .relay }
        return .other
    }
}

/// Requests of one kind: how many, the bytes of their bodies, and (when measured: `URLSessionTaskMetrics`) the bytes
/// really sent and received, and of those over a mobile network.
struct NetCount: Codable, Equatable, Sendable {
    var requests = 0
    var body = 0
    var wire = 0
    var mobile = 0
    var measured = 0                 // requests whose real bytes were measured

    /// The bytes to show: the measured ones when there are any, else the body size.
    var shown: Int { measured > 0 ? wire : body }
}

/// One day's counts.
struct BatteryDay: Codable, Equatable, Sendable {
    var day: String                                  // "2026-11-17", the phone's own time zone
    var gps: [String: Double] = [:]                  // "mode|reason" → seconds
    var net: [String: NetCount] = [:]                // CostKind → requests
    var bursts = 0                                   // radio wakes: a request more than 12 s after the one before
    var burstSeconds: Double = 0                     // …roughly how long the radio stayed up (10 s after each)
    var cpu: Double = 0                              // seconds of CPU time (user and system)
    var foreground: Double = 0                       // seconds on screen
    var background: Double = 0                       // seconds running behind
    var activityUpdates = 0
    var checks = 0                                   // matcher looks
    var drop: Double = 0                             // battery percent lost while unplugged
    var unplugged: Double = 0                        // seconds those drops were measured over

    init(day: String) { self.day = day }

    func gpsSeconds(_ mode: GPSMode) -> Double { gps.filter { $0.key.hasPrefix(mode.rawValue + "|") }.values.reduce(0, +) }
    func gpsSeconds(reason: GPSReason) -> Double { gps.filter { $0.key.hasSuffix("|" + reason.rawValue) }.values.reduce(0, +) }
    var gpsTotal: Double { gps.values.reduce(0, +) }
    var requests: Int { net.values.map(\.requests).reduce(0, +) }
    var bytes: Int { net.values.map(\.shown).reduce(0, +) }
    var mobile: Int { net.values.map(\.mobile).reduce(0, +) }
    var measured: Bool { net.values.contains { $0.measured > 0 } }
}

/// One ride, from its start to its end: what it cost.
struct RideCost: Codable, Equatable, Sendable {
    var start: Date
    var end: Date?
    var legs = 1
    var batteryStart: Double?                        // 0…1
    var batteryEnd: Double?
    var unplugged = true                             // unplugged at both ends and in between, as far as seen
    var gps: [String: Double] = [:]                  // mode → seconds
    var body = 0
    var wire = 0
    var mobile = 0
    var measured = 0
    var checks = 0
    var activityUpdates = 0
    var cpu: Double = 0

    init(start: Date, batteryStart: Double? = nil, unplugged: Bool = true) {
        self.start = start
        self.batteryStart = batteryStart
        self.unplugged = unplugged
    }

    var bytes: Int { measured > 0 ? wire : body }
    /// Percent lost (nil: not known, or charging meanwhile).
    var drop: Double? {
        guard unplugged, let a = batteryStart, let b = batteryEnd, a >= 0, b >= 0 else { return nil }
        return max(0, (a - b) * 100)
    }
}

/// The log: today's and the last 13 days' counts, the last 30 rides, the ride on now. Thread-safe; written at most
/// every `every` seconds while something changed (and by `flush`, which the field log's flush calls too).
final class BatteryLog: @unchecked Sendable {
    static let shared = BatteryLog(file: BatteryLog.appFile)
    static let keepDays = 14
    static let keepRides = 30
    /// A request this long after the one before wakes the radio again (it stays up some 10 s after a transfer).
    static let burstGap: TimeInterval = 12
    static let tail: TimeInterval = 10

    static var appFile: URL {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("batterylog.json")
    }

    struct Saved: Codable, Equatable {
        var days: [BatteryDay] = []                  // oldest first
        var rides: [RideCost] = []                   // oldest first
        var ride: RideCost?                          // the one on now
    }

    /// CPU time of the process so far (seconds), read at each settle (set by the app; nil in tests).
    var cpuReader: (@Sendable () -> Double?)?

    private let load: () -> Data?
    private let store: (Data) -> Void
    private let every: TimeInterval
    private let calendar: Calendar
    private let lock = NSLock()
    private let writing = NSLock()
    private var saved: Saved
    private var open: [String: (bucket: String, since: Date)] = [:]   // channel → the interval running now
    private var lastNet: Date?
    private var lastCPU: Double?
    private var lastBattery: (level: Double, unplugged: Bool, at: Date)?
    private var dirty = false
    private var pending = false
    private let dayFormat: DateFormatter

    convenience init(file: URL, every: TimeInterval = 30, calendar: Calendar = .current) {
        self.init(load: { try? Data(contentsOf: file) }, store: { try? $0.write(to: file, options: .atomic) }, every: every, calendar: calendar)
    }

    init(load: @escaping () -> Data?, store: @escaping (Data) -> Void, every: TimeInterval, calendar: Calendar = .current) {
        self.load = load
        self.store = store
        self.every = every
        self.calendar = calendar
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        dayFormat = f
        if let d = load(), let s = try? JSONDecoder().decode(Saved.self, from: d) { saved = s } else { saved = Saved() }
        saved.ride = nil                             // (a ride doesn't outlive the app: as the trip itself)
    }

    func dayKey(_ d: Date) -> String { dayFormat.string(from: d) }

    // MARK: counting

    /// GPS on `channel` ("trip", "home") now runs in `mode` for `reason` (nil: off).
    func gps(_ channel: String, mode: GPSMode?, reason: GPSReason?, at: Date = Date()) {
        change { closeOpen("gps:" + channel, at: at); if let mode, let reason { open["gps:" + channel] = (mode.rawValue + "|" + reason.rawValue, at) } }
    }

    /// The app is now in front (or behind).
    func scene(foreground: Bool, at: Date = Date()) {
        change { closeOpen("scene", at: at); open["scene"] = (foreground ? "fg" : "bg", at) }
    }

    /// A request was answered (or failed after sending): `body` bytes came back.
    func request(_ kind: CostKind, body: Int, at: Date = Date()) {
        change {
            withDay(at) { d in
                d.net[kind.rawValue, default: NetCount()].requests += 1
                d.net[kind.rawValue, default: NetCount()].body += max(0, body)
                if let l = lastNet, at.timeIntervalSince(l) >= 0, at.timeIntervalSince(l) <= Self.burstGap {
                    d.burstSeconds += at.timeIntervalSince(l)
                } else {
                    d.bursts += 1; d.burstSeconds += Self.tail
                }
            }
            lastNet = at
            saved.ride?.body += max(0, body)
        }
    }

    /// A request's real bytes, both ways (headers and the body as sent), from its metrics; `mobile`: over a mobile network.
    func wire(_ kind: CostKind, bytes: Int, mobile: Bool, at: Date = Date()) {
        change {
            let b = max(0, bytes)
            withDay(at) { d in
                d.net[kind.rawValue, default: NetCount()].wire += b
                d.net[kind.rawValue, default: NetCount()].measured += 1
                if mobile { d.net[kind.rawValue, default: NetCount()].mobile += b }
            }
            saved.ride?.wire += b
            saved.ride?.measured += 1
            if mobile { saved.ride?.mobile += b }
        }
    }

    /// The process's CPU time so far: what's new since the last reading is counted (a lower one starts over).
    func cpu(total: Double, at: Date = Date()) {
        change { addCPU(total, at: at) }
    }

    func activityUpdate(at: Date = Date()) {
        change { withDay(at) { $0.activityUpdates += 1 }; saved.ride?.activityUpdates += 1 }
    }

    func check(at: Date = Date()) {
        change { withDay(at) { $0.checks += 1 }; saved.ride?.checks += 1 }
    }

    /// The battery level now (0…1; below 0: not known) and whether it's unplugged. A drop between two readings that were
    /// both unplugged counts.
    func battery(level: Double, unplugged: Bool, at: Date = Date()) {
        guard level.isFinite, level >= 0 else { return }
        change {
            if let l = lastBattery, l.unplugged, unplugged, at > l.at {
                let drop = max(0, l.level - level) * 100
                let span = at.timeIntervalSince(l.at)
                withDay(at) { d in d.drop += drop; d.unplugged += span }
            }
            lastBattery = (level, unplugged, at)
            if !unplugged { saved.ride?.unplugged = false }
        }
    }

    /// A ride started (one already on ends first, there).
    func rideStart(at: Date = Date(), battery: Double? = nil, unplugged: Bool = true) {
        change {
            settleLocked(at: at)
            if saved.ride != nil { endLocked(at: at, battery: battery, unplugged: unplugged, legs: nil) }
            saved.ride = RideCost(start: at, batteryStart: battery.flatMap { $0 >= 0 ? $0 : nil }, unplugged: unplugged)
        }
    }

    /// The ride ended: its costs, kept with the last 30 (nil: no ride was on).
    @discardableResult
    func rideEnd(at: Date = Date(), battery: Double? = nil, unplugged: Bool = true, legs: Int? = nil) -> RideCost? {
        var out: RideCost?
        change {
            settleLocked(at: at)
            out = endLocked(at: at, battery: battery, unplugged: unplugged, legs: legs)
        }
        return out
    }

    /// Everything so far, the running intervals counted up to `at`.
    func snapshot(at: Date = Date()) -> Saved {
        lock.lock(); defer { lock.unlock() }
        settleLocked(at: at)
        return saved
    }

    func clear() {
        lock.lock()
        saved = Saved()
        lastNet = nil
        dirty = true
        lock.unlock()
    }

    /// Written now (the running intervals counted up to now first).
    func flush() {
        writing.lock()
        defer { writing.unlock() }
        lock.lock()
        pending = false
        settleLocked(at: Date())
        guard dirty else { lock.unlock(); return }
        dirty = false
        let copy = saved
        lock.unlock()
        if let data = try? JSONEncoder().encode(copy) { store(data) }
    }

    // MARK: inside the lock

    private func change(_ body: () -> Void) {
        lock.lock()
        body()
        dirty = true
        let schedule = !pending && every.isFinite
        pending = true
        lock.unlock()
        if schedule {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + every) { [weak self] in self?.flush() }
        }
    }

    /// The running intervals are counted up to `at` and go on from there; the CPU time too.
    private func settleLocked(at: Date) {
        for (k, v) in open where at > v.since {
            add(k, v.bucket, from: v.since, to: at)
            open[k] = (v.bucket, at)
        }
        if let total = cpuReader?() { addCPU(total, at: at) }
        dirty = true
    }

    private func addCPU(_ total: Double, at: Date) {
        guard total.isFinite, total >= 0 else { return }
        if let l = lastCPU, total >= l {
            let d = total - l
            withDay(at) { $0.cpu += d }
            saved.ride?.cpu += d
        }
        lastCPU = total
    }

    private func closeOpen(_ k: String, at: Date) {
        if let v = open[k], at > v.since { add(k, v.bucket, from: v.since, to: at) }
        open[k] = nil
    }

    /// An interval's seconds, each day's part to that day.
    private func add(_ channel: String, _ bucket: String, from: Date, to: Date) {
        var a = from
        while a < to {
            let next = calendar.nextDate(after: a, matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime) ?? to
            let b = min(to, next > a ? next : to)
            let s = b.timeIntervalSince(a)
            if channel == "scene" {
                withDay(a) { d in if bucket == "fg" { d.foreground += s } else { d.background += s } }
            } else {
                withDay(a) { $0.gps[bucket, default: 0] += s }
                if let mode = bucket.split(separator: "|").first, saved.ride.map({ a >= $0.start }) ?? false {
                    saved.ride?.gps[String(mode), default: 0] += s
                }
            }
            a = b
        }
    }

    private func withDay(_ at: Date, _ body: (inout BatteryDay) -> Void) {
        let k = dayKey(at)
        if let i = saved.days.lastIndex(where: { $0.day == k }) {
            body(&saved.days[i])
            return
        }
        var d = BatteryDay(day: k)
        body(&d)
        saved.days.append(d)
        saved.days.sort { $0.day < $1.day }
        if saved.days.count > Self.keepDays { saved.days.removeFirst(saved.days.count - Self.keepDays) }
    }

    @discardableResult
    private func endLocked(at: Date, battery: Double?, unplugged: Bool, legs: Int?) -> RideCost? {
        guard var r = saved.ride else { return nil }
        r.end = at
        if let b = battery, b >= 0 { r.batteryEnd = b }
        if !unplugged { r.unplugged = false }
        if let legs { r.legs = max(1, legs) }
        saved.ride = nil
        saved.rides.append(r)
        if saved.rides.count > Self.keepRides { saved.rides.removeFirst(saved.rides.count - Self.keepRides) }
        return r
    }
}

/// What the Battery & data screen and the field log say, from the log's counts.
enum BatteryReport {
    struct Bar: Equatable {
        let title: String
        let value: String
        let detail: String
        let fraction: Double                         // 0…1, against the day's biggest
    }

    /// Rough weights for the bars (the screen says they're a guess): a minute of the best GPS is 1.
    static let burstWeight = 0.15                    // a radio wake
    static let cpuWeight = 1.0                       // a CPU minute
    static let backgroundWeight = 0.05               // a minute running behind (it keeps the phone from sleeping)

    static func mb(_ bytes: Int) -> String {
        let m = Double(max(0, bytes)) / 1_048_576
        return m >= 10 ? String(format: "%.0f MB", m) : String(format: "%.1f MB", m)
    }

    /// "6 min", "1 h 05", "40 s"
    static func duration(_ s: Double) -> String {
        guard s.isFinite, s > 0 else { return "0 min" }
        if s < 60 { return "\(Int(s.rounded())) s" }
        let m = Int((s / 60).rounded())
        return m >= 60 ? "\(m / 60) h \(String(format: "%02d", m % 60))" : "\(m) min"
    }

    /// Today's bars: GPS, network, CPU, background.
    static func bars(_ d: BatteryDay) -> [Bar] {
        let gpsW = GPSMode.allCases.map { d.gpsSeconds($0) / 60 * $0.weight }.reduce(0, +)
        let netW = Double(d.bursts) * burstWeight
        let cpuW = d.cpu / 60 * cpuWeight
        let bgW = d.background / 60 * backgroundWeight
        let top = max(gpsW, netW, cpuW, bgW)
        func f(_ w: Double) -> Double { top > 0 ? min(1, max(0, w / top)) : 0 }
        let modes = GPSMode.allCases.filter { d.gpsSeconds($0) > 0 }.map { "\($0.label) \(duration(d.gpsSeconds($0)))" }
        let why = GPSReason.allCases.filter { d.gpsSeconds(reason: $0) > 0 }.map { "\($0.label) \(duration(d.gpsSeconds(reason: $0)))" }
        let gpsDetail = (modes.isEmpty ? "off all day" : modes.joined(separator: " · ")) + (why.isEmpty ? "" : "\nwhy: " + why.joined(separator: " · "))
        let kinds = kinds(d).prefix(4).map { "\($0.kind.label) \(mb($0.bytes))" }.joined(separator: " · ")
        return [
            Bar(title: "GPS", value: duration(d.gpsTotal), detail: gpsDetail, fraction: f(gpsW)),
            Bar(title: "Network", value: mb(d.bytes), detail: "\(d.requests) requests · \(d.bursts) radio wakes" + (kinds.isEmpty ? "" : "\n" + kinds)
                + (d.measured ? "" : "\n(body sizes: real bytes not measured)"), fraction: f(netW)),
            Bar(title: "CPU", value: duration(d.cpu), detail: "\(d.checks) matcher checks · \(d.activityUpdates) Live Activity updates", fraction: f(cpuW)),
            Bar(title: "Background", value: duration(d.background), detail: "on screen \(duration(d.foreground))", fraction: f(bgW)),
        ]
    }

    /// The kinds of requests, the most bytes first.
    static func kinds(_ d: BatteryDay) -> [(kind: CostKind, bytes: Int, requests: Int)] {
        d.net.compactMap { k, v in CostKind(rawValue: k).map { (kind: $0, bytes: v.shown, requests: v.requests) } }
            .filter { $0.requests > 0 }
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.kind.rawValue < $1.kind.rawValue }
    }

    /// Mobile data today and in the last 7 days (today included), in bytes; `measured`: any of it was measured.
    static func mobile(_ days: [BatteryDay], today: Date, calendar: Calendar, key: (Date) -> String) -> (today: Int, week: Int, measured: Bool) {
        let t = key(today)
        var week = Set<String>()
        for i in 0..<7 { if let d = calendar.date(byAdding: .day, value: -i, to: today) { week.insert(key(d)) } }
        let todayBytes = days.filter { $0.day == t }.map(\.mobile).reduce(0, +)
        let weekBytes = days.filter { week.contains($0.day) }.map(\.mobile).reduce(0, +)
        return (todayBytes, weekBytes, days.contains { week.contains($0.day) && $0.measured })
    }

    /// "−4%", "−<1%", "charging", "battery ?"
    static func drop(_ r: RideCost) -> String {
        if !r.unplugged { return "charging" }
        guard let d = r.drop else { return "battery ?" }
        return d < 1 ? "−<1%" : "−\(Int(d.rounded()))%"
    }

    /// The battery lost per hour while unplugged today ("1.9 %/h"), once 10 minutes of it were seen.
    static func perHour(_ d: BatteryDay) -> String? {
        guard d.unplugged >= 600 else { return nil }
        return String(format: "%.1f %%/h", d.drop / (d.unplugged / 3600))
    }

    /// "GPS best 6 min / 10 m 18 min"
    static func gps(_ r: RideCost) -> String {
        let parts = GPSMode.allCases.compactMap { m -> String? in
            guard let s = r.gps[m.rawValue], s >= 30 else { return nil }
            return "\(m.label) \(duration(s))"
        }
        return parts.isEmpty ? "GPS off" : "GPS " + parts.joined(separator: " / ")
    }

    /// "Ride 18:51–19:15 · 24 min · −4% · GPS best 6 min / 10 m 18 min · 2.1 MB"
    static func rideLine(_ r: RideCost, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "HH:mm"
        let end = r.end ?? r.start
        let minutes = Int((max(0, end.timeIntervalSince(r.start)) / 60).rounded())
        let legs = r.legs > 1 ? " (\(r.legs) legs)" : ""
        return "Ride \(f.string(from: r.start))–\(f.string(from: end)) · \(minutes) min\(legs) · \(drop(r)) · \(gps(r)) · \(mb(r.bytes))"
            + (r.measured > 0 ? "" : " (body size)")
    }

    /// The field log's line at a ride's end: the ride line, then its checks and Live Activity updates.
    static func fieldLine(_ r: RideCost, timeZone: TimeZone = .current) -> String {
        "cost · " + String(rideLine(r, timeZone: timeZone).dropFirst("Ride ".count))
            + (r.mobile > 0 ? " · mobile \(mb(r.mobile))" : "") + " · \(r.checks) checks · \(r.activityUpdates) LA updates · CPU \(duration(r.cpu))"
    }

    /// Everything as text, for "Copy as text".
    static func text(_ s: BatteryLog.Saved, today: Date, calendar: Calendar, key: (Date) -> String, timeZone: TimeZone = .current) -> String {
        var out: [String] = []
        let m = mobile(s.days, today: today, calendar: calendar, key: key)
        out.append("Battery & data · mobile today \(mb(m.today)) · this week \(mb(m.week))\(m.measured ? "" : " (not measured)")")
        for d in s.days.reversed() {
            out.append("\(d.day) · GPS \(duration(d.gpsTotal)) · \(mb(d.bytes)) in \(d.requests) requests (\(d.bursts) wakes) · mobile \(mb(d.mobile))"
                       + " · CPU \(duration(d.cpu)) · on screen \(duration(d.foreground)) · behind \(duration(d.background))"
                       + " · \(d.checks) checks · \(d.activityUpdates) LA" + (perHour(d).map { " · \($0) unplugged" } ?? ""))
            let k = kinds(d).map { "\($0.kind.label) \(mb($0.bytes))/\($0.requests)" }
            if !k.isEmpty { out.append("  " + k.joined(separator: " · ")) }
        }
        for r in s.rides.reversed() { out.append(rideLine(r, timeZone: timeZone)) }
        return out.joined(separator: "\n")
    }
}
