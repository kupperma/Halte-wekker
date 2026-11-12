import Foundation

// What NS knows about a train, through your Cloudflare relay (which holds the NS key):
// the real platform, cancellations, how busy it is, how long it is and where 1st class stops.

struct TrainZone: Hashable { let a: Double; let b: Double }                  // 0…1 along the whole train
struct TrainUnit: Hashable { let x: Double; let w: Double; let zones: [TrainZone]? }
struct PlatformLetter: Hashable { let letter: String; let x: Double }

struct TrainLayout: Hashable {
    let units: [TrainUnit]
    let letters: [PlatformLetter]
    let dir: String?                    // "left" / "right": which way it leaves

    /// "1st class near A, D · 2nd class everywhere else" (only where the platform has letters).
    var firstClassText: String? {
        let zones = units.flatMap { $0.zones ?? [] }
        guard !zones.isEmpty, !letters.isEmpty else { return nil }
        var near: [String] = []
        for z in zones {
            let inside = letters.filter { $0.x >= z.a - 0.03 && $0.x <= z.b + 0.03 }
            let mid = (z.a + z.b) / 2
            let pick = inside.isEmpty ? [letters.min { abs($0.x - mid) < abs($1.x - mid) }!] : inside
            for l in pick where !near.contains(l.letter) { near.append(l.letter) }
        }
        near.sort()
        return "1st class near \(near.joined(separator: ", ")) · 2nd class everywhere else"
    }
}

struct TrainSize: Hashable {
    let cars: Int
    let seats: Int
    let cut: Bool                       // NS shortened it
    let layout: TrainLayout?
    var text: String {
        let base = "\(cars) carriage\(cars == 1 ? "" : "s")\(seats > 0 ? " · \(seats) seats" : "")"
        if cut { return "Shortened · \(base)" }
        if cars <= 4 { return "Short train · \(base)" }
        return base
    }
    var warn: Bool { cut || cars <= 4 }
}

struct RailInfo: Hashable {
    var track: String?
    var plannedTrack: String?
    var cancelled = false
    var crowd = 0                       // 1 quiet, 2 busy, 3 very busy
    var size: TrainSize?
    var trackChanged: Bool {
        guard let t = track, let p = plannedTrack, !t.isEmpty, !p.isEmpty else { return false }
        return t != p
    }
}

struct NSDeparture {
    let num: String
    let planned: Date?
    let plannedTrack: String
    let actualTrack: String
    let cancelled: Bool
}

@MainActor
final class NSStore: ObservableObject {
    static let shared = NSStore()
    nonisolated static let relay = "https://haltewekker-relay.tsfaw1.workers.dev"
    nonisolated static func code(_ p: Place) -> String? { ["ehv": "EHV", "ht": "HT", "bd": "BD"][p.key] }

    @Published private(set) var info: [String: RailInfo] = [:]      // by the first ride's id
    @Published private(set) var available: Bool?                     // false: the relay has no NS key

    private var boards: [String: (at: Date, list: [NSDeparture])] = [:]
    private var tripsAsked: [String: Date] = [:]
    private var crowd: [String: Int] = [:]
    private var sizes: [String: (at: Date, v: TrainSize?)] = [:]
    private var offUntil = Date.distantPast

    func rail(_ r: Ride) -> RailInfo? { info[r.id] }

    // MARK: talking to the relay

    private func fetch(_ path: String, timeout: Double = 12) async -> (json: Any?, status: Int) {
        guard let url = URL(string: Self.relay + path) else { return (nil, 0) }
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        r.setValue(Transit.userAgent, forHTTPHeaderField: "User-Agent")
        guard let res = try? await URLSession.shared.data(for: r), let http = res.1 as? HTTPURLResponse else { return (nil, -1) }
        let json = (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("json")
        return (http.statusCode == 200 && json ? try? JSONSerialization.jsonObject(with: res.0) : nil, http.statusCode)
    }

    private static let nsTime: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"; return f
    }()
    private static func time(_ a: Any?) -> Date? {
        guard let s = a as? String else { return nil }
        return nsTime.date(from: s) ?? Transit.date(s)
    }
    private static func num(_ a: Any?) -> Double { (a as? NSNumber)?.doubleValue ?? 0 }

    /// The departure board of a station (kept 45 s).
    @discardableResult
    func board(_ code: String) async -> [NSDeparture]? {
        if let b = boards[code], Date().timeIntervalSince(b.at) < 45 { return b.list }
        if Date() < offUntil { return boards[code]?.list }
        let (j, st) = await fetch("/ns/departures?station=\(code)")
        guard let d = j as? [String: Any] else {
            if st == -1 { offUntil = Date().addingTimeInterval(120) } else { offUntil = Date().addingTimeInterval(600); available = false }
            return boards[code]?.list
        }
        let deps = ((d["payload"] as? [String: Any])?["departures"] as? [[String: Any]]) ?? []
        let list = deps.map { x in
            NSDeparture(num: Transit.text((x["product"] as? [String: Any])?["number"]), planned: Self.time(x["plannedDateTime"]),
                        plannedTrack: Transit.text(x["plannedTrack"]),
                        actualTrack: Transit.text(x["actualTrack"]).isEmpty ? Transit.text(x["plannedTrack"]) : Transit.text(x["actualTrack"]),
                        cancelled: (x["cancelled"] as? Bool) ?? false)
        }
        boards[code] = (Date(), list); available = true
        return list
    }

    func match(_ code: String, num: String, planned: Date) -> NSDeparture? {
        guard let list = boards[code]?.list else { return nil }
        if !num.isEmpty { return list.first { $0.num == num } }
        return list.first { d in d.planned.map { abs($0.timeIntervalSince(planned)) < 60 } ?? false }
    }

    /// NS's crowd forecast for the trains between two stations around a time (kept 5 min per half hour).
    private func loadCrowd(from: String, to: String, at: Date) async {
        let k = "\(from)>\(to)@\(Int(at.timeIntervalSince1970 / 1800))"
        if let c = tripsAsked[k], Date().timeIntervalSince(c) < 300 { return }
        guard Date() >= offUntil else { return }
        tripsAsked[k] = Date()
        let when = ISO8601DateFormatter().string(from: max(at, Date()).addingTimeInterval(-300))
        let (j, st) = await fetch("/ns/trips?from=\(from)&to=\(to)&dateTime=\(when.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? when)", timeout: 15)
        guard let d = j as? [String: Any] else {
            if st != 400 && st != -1 { offUntil = Date().addingTimeInterval(600); available = false }
            return
        }
        for tr in (d["trips"] as? [[String: Any]]) ?? [] {
            for l in (tr["legs"] as? [[String: Any]]) ?? [] {
                let n = Transit.text((l["product"] as? [String: Any])?["number"])
                if !n.isEmpty, let lv = ["LOW": 1, "MEDIUM": 2, "HIGH": 3][((l["crowdForecast"] as? String) ?? "").uppercased()] { crowd[n] = lv }
            }
        }
        available = true
    }

    /// Carriages, seats and the layout along the platform (kept 15 min).
    func trainSize(num: String, code: String) async -> TrainSize? {
        let k = "\(num)@\(code)"
        if let c = sizes[k], Date().timeIntervalSince(c.at) < 900 { return c.v }
        guard Date() >= offUntil else { return sizes[k]?.v }
        let (j, st) = await fetch("/ns/train?num=\(num)&station=\(code)&features=zitplaats")
        guard let d = j as? [String: Any] else {
            if st == 501 { offUntil = Date().addingTimeInterval(600) }
            if st != -1 { sizes[k] = (Date(), nil) }
            return sizes[k]?.v
        }
        let parts = (d["materieeldelen"] as? [[String: Any]]) ?? []
        var seats = 0
        for m in parts {
            let z = (m["zitplaatsen"] as? [String: Any]) ?? [:]
            seats += Int(Self.num(z["zitplaatsEersteKlas"]) + Self.num(z["zitplaatsTweedeKlas"]))
        }
        let length = Int(Self.num(d["lengte"]))
        let cars = length > 0 ? length : parts.reduce(0) { $0 + ((($1["bakken"] as? [Any]) ?? []).count) }
        let v = cars > 0 ? TrainSize(cars: cars, seats: seats, cut: (d["ingekort"] as? Bool) ?? false, layout: Self.layout(d)) : nil
        sizes[k] = (Date(), v)
        return v
    }

    /// Where 1st class is in each kind of NS train, from NS's own drawings (share of the unit's length).
    private static let class1: [String: [[Double]]] = [
        "ddz_4": [[0.015, 0.12], [0.669, 0.774]], "ddz_6": [[0.01, 0.079], [0.439, 0.508], [0.783, 0.851]],
        "icm_3": [[0.537, 0.669]], "icm_4": [[0.498, 0.752]], "icng_5": [[0.41, 0.667]], "icng_8": [[0.272, 0.379], [0.62, 0.727]],
        "nsr_flirt_3": [[0.039, 0.206], [0.791, 0.958]], "nsr_flirt_4": [[0.03, 0.161], [0.837, 0.967]],
        "slt_4": [[0.02, 0.172], [0.825, 0.977]], "slt_6": [[0.014, 0.119], [0.879, 0.984]],
        "sng_3": [[0.038, 0.215], [0.823, 1.0]], "sng_4": [[0.03, 0.169], [0.861, 1.0]],
        "virm_4": [[0.376, 0.667]], "virm_6": [[0.223, 0.315], [0.582, 0.777]],
        "virmm1_4": [[0.376, 0.625]], "virmm1_6": [[0.25, 0.315], [0.582, 0.749]],
        "virmm2_4": [[0.376, 0.625]], "virmm2_6": [[0.25, 0.315], [0.582, 0.749]], "i11_eurocity": [[0.708, 0.851]],
    ]
    nonisolated static let cab = 0.045

    private static func layout(_ d: [String: Any]) -> TrainLayout? {
        let parts = (d["materieeldelen"] as? [[String: Any]]) ?? []
        let sum = parts.reduce(0.0) { $0 + num($1["breedte"]) }
        let total = num(d["lengteInPixels"]) > 0 ? num(d["lengteInPixels"]) : sum
        guard total > 0, !parts.isEmpty else { return nil }
        var x = 0.0
        var units: [TrainUnit] = []
        for m in parts {
            let w = num(m["breedte"])
            var key = ((m["afbeelding"] as? String) ?? "").split(separator: "/").last.map(String.init) ?? ""
            if key.hasSuffix(".png") { key = String(key.dropLast(4)) }
            // Every unit has a driver's cab at both ends; 1st class near an end starts right behind it.
            let zones = class1[key.lowercased()].map { list in
                list.map { z -> TrainZone in
                    let a = z[0] < 0.08 ? cab : z[0], b = z[1] > 0.92 ? 1 - cab : z[1]
                    return TrainZone(a: (x + a * w) / total, b: (x + b * w) / total)
                }
            }
            units.append(TrainUnit(x: x / total, w: w / total, zones: zones))
            x += w
        }
        let letters = ((d["perronVoorzieningen"] as? [[String: Any]]) ?? []).compactMap { p -> PlatformLetter? in
            guard (p["type"] as? String) == "PERRONLETTER", let l = p["description"] as? String, !l.isEmpty, p["paddingLeft"] != nil else { return nil }
            let pl = num(p["paddingLeft"])
            guard pl >= -0.03 * total, pl <= 1.03 * total else { return nil }
            return PlatformLetter(letter: l, x: pl / total)
        }
        let rr = d["rijrichting"] as? String
        return TrainLayout(units: units, letters: letters, dir: rr == "LINKS" ? "left" : rr == "RECHTS" ? "right" : nil)
    }

    // MARK: filling in the trains on screen

    /// Platform, cancellations, crowding and size for the trains in these trips. `from`/`to`: the places they were planned between.
    func enrich(_ items: [(trip: DoorTrip, from: Place, to: Place)]) async {
        let rail = items.filter { $0.trip.first.isTrain && Self.code($0.from) != nil }
        guard !rail.isEmpty else { return }
        for c in Set(rail.compactMap { Self.code($0.from) }) { await board(c) }
        var groups: [String: Date] = [:]
        for r in rail {
            guard let a = Self.code(r.from), let b = Self.code(r.to) else { continue }
            let k = "\(a)>\(b)", t = r.trip.first.scheduledDeparture
            if groups[k].map({ t < $0 }) ?? true { groups[k] = t }
        }
        for (k, at) in groups {
            let p = k.split(separator: ">").map(String.init)
            await loadCrowd(from: p[0], to: p[1], at: at)
        }
        for r in rail {
            let f = r.trip.first, code = Self.code(r.from)!
            var i = info[f.id] ?? RailInfo(track: f.platform, plannedTrack: f.plannedPlatform ?? f.platform, cancelled: f.cancelled)
            if let m = match(code, num: f.num, planned: f.scheduledDeparture) {
                if !m.plannedTrack.isEmpty { i.plannedTrack = m.plannedTrack }
                if !m.actualTrack.isEmpty { i.track = m.actualTrack }
                if m.cancelled { i.cancelled = true }
            }
            i.crowd = r.trip.rides.filter(\.isTrain).map { crowd[$0.num] ?? 0 }.max() ?? 0
            if !f.num.isEmpty, f.scheduledDeparture > Date().addingTimeInterval(-600), f.scheduledDeparture.timeIntervalSinceNow < 6 * 3600 {
                i.size = await trainSize(num: f.num, code: code)
            }
            info[f.id] = i
        }
    }
}
