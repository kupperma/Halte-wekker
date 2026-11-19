import Foundation

// What /logs/v1/export?format=json gives (docs/logs-export.md), and the rides in it.

/// One GPS point as the relay keeps it (the app's `SharedFix`).
struct ExportFix: Codable, Equatable {
    var t: Double
    var lat: Double
    var lon: Double
    var acc: Double?
    var spd: Double?
    var crs: Double?
    var leg: String?
    var veh: String?
    var ride: String?

    var fix: Fix {
        Fix(t: Date(timeIntervalSince1970: t), p: GeoPoint(lat: lat, lon: lon), accuracy: acc ?? 50,
            speed: spd ?? -1, course: crs ?? -1)
    }
}

struct ExportUpload: Codable {
    var id: Int
    var install: String
    var app: String
    var at: Double
    var lines: [String]
    var fixes: [ExportFix]?
    var tz: Int?
}

/// A vehicle's pieces, as the fixture (or `--tracks`, `--save-tracks`) keeps them: times in unix seconds, paths as
/// [lat, lon] pairs.
struct SavedTrack: Codable, Equatable {
    struct Piece: Codable, Equatable {
        var departure: Double
        var arrival: Double
        var path: [[Double]]
    }
    var tripId: String
    var line: String
    var isTrain: Bool
    var realTime: Bool
    var pieces: [Piece]

    var track: VehicleTrack {
        VehicleTrack(tripId: tripId, line: line, isTrain: isTrain, realTime: realTime,
                     pieces: pieces.map { p in
                         TimedPiece(departure: Date(timeIntervalSince1970: p.departure), arrival: Date(timeIntervalSince1970: p.arrival),
                                    path: p.path.compactMap { $0.count == 2 ? GeoPoint(lat: $0[0], lon: $0[1]) : nil })
                     }.sorted { $0.departure < $1.departure })
    }

    init(_ v: VehicleTrack) {
        tripId = v.tripId; line = v.line; isTrain = v.isTrain; realTime = v.realTime
        pieces = v.pieces.map { Piece(departure: $0.departure.timeIntervalSince1970, arrival: $0.arrival.timeIntervalSince1970,
                                      path: $0.path.map { [$0.lat, $0.lon] }) }
    }
}

/// An export answer (or several pages of one in a JSON array). A fixture may also carry `tracks` (the vehicles near
/// the ride, made up) and `truth` (ride id › leg › the vehicle you were on, "305·7821"), which a real export doesn't.
struct Export {
    var uploads: [ExportUpload] = []
    var tracks: [SavedTrack] = []
    var truth: [String: [String: String]] = [:]

    private struct Page: Codable {
        var uploads: [ExportUpload]
        var tracks: [SavedTrack]?
        var truth: [String: [String: String]]?
    }

    static func read(_ data: Data) throws -> Export {
        let d = JSONDecoder()
        var e = Export()
        let pages: [Page]
        if let one = try? d.decode(Page.self, from: data) { pages = [one] } else { pages = try d.decode([Page].self, from: data) }
        for p in pages {
            e.uploads += p.uploads
            e.tracks += p.tracks ?? []
            for (ride, legs) in p.truth ?? [:] { e.truth[ride, default: [:]].merge(legs) { a, _ in a } }
        }
        return e
    }
}

/// One log line, at its UTC time (the line's own clock is the phone's: minus the upload's `tz`).
struct LogLine: Equatable {
    var at: Date
    var kind: String
    var text: String

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// "2026-11-19 07:33:58 ride start · …" with the phone `tz` seconds east of UTC.
    static func parse(_ s: String, tz: Int) -> LogLine? {
        let parts = s.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4, let local = clock.date(from: "\(parts[0]) \(parts[1])") else { return nil }
        return LogLine(at: local.addingTimeInterval(-Double(tz)), kind: String(parts[2]), text: String(parts[3]))
    }
}

/// "bus 305·7821", "train IC·a1b2", "305·7821" → "305·7821": how a vehicle is compared.
func vehicleKey(_ s: String?) -> String? {
    guard var t = s?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
    for p in ["bus ", "train "] where t.hasPrefix(p) { t.removeFirst(p.count) }
    return t
}

/// One leg of one ride: its GPS points, the log lines in its time, and the vehicle you were on (as far as the export
/// says).
struct ReplayLeg {
    var install: String
    var ride: String
    var leg: String
    var fixes: [ExportFix]
    var lines: [LogLine]
    var truth: String?
    /// Where `truth` comes from: "given" (the fixture's), "hand pick" (you said in the ride which one), "ended on" (the
    /// one the app showed at the leg's end).
    var truthFrom: String

    var start: Date { Date(timeIntervalSince1970: fixes.first?.t ?? 0) }
    var end: Date { Date(timeIntervalSince1970: fixes.last?.t ?? 0) }
}

enum Rides {
    /// "hand pick · bus 306·4942 (was 305·4779) · …" → "306·4942"; nil for "none of these" and the other hand-pick lines.
    static func handPicked(_ text: String) -> String? {
        let p = "hand pick · "
        guard text.hasPrefix(p), text.contains("(was ") else { return nil }
        let rest = text.dropFirst(p.count)
        guard !rest.hasPrefix("none of these"), let cut = rest.range(of: " (was ") else { return nil }
        return vehicleKey(String(rest[..<cut.lowerBound]))
    }

    /// The legs in an export, by install, ride and leg, in time order. A leg needs GPS points (lines alone don't say
    /// where you were).
    static func legs(_ e: Export) -> [ReplayLeg] {
        var out: [ReplayLeg] = []
        let byInstall = Dictionary(grouping: e.uploads, by: \.install)
        for install in byInstall.keys.sorted() {
            let ups = byInstall[install]!.sorted { $0.id < $1.id }
            // (an upload of lines only has no tz: the install's own from its others, else UTC)
            let tz0 = ups.compactMap(\.tz).first ?? 0
            let lines = ups.flatMap { u in u.lines.compactMap { LogLine.parse($0, tz: u.tz ?? tz0) } }.sorted { $0.at < $1.at }
            var seen = Set<Double>()
            let fixes = ups.flatMap { $0.fixes ?? [] }.sorted { $0.t < $1.t }.filter { seen.insert($0.t).inserted }
            let rides = Dictionary(grouping: fixes) { $0.ride ?? "?" }
            for ride in rides.keys.sorted(by: { (rides[$0]!.first!.t) < (rides[$1]!.first!.t) }) {
                let byLeg = Dictionary(grouping: rides[ride]!) { $0.leg ?? "?" }
                for leg in byLeg.keys.sorted(by: { (byLeg[$0]!.first!.t) < (byLeg[$1]!.first!.t) }) {
                    let f = byLeg[leg]!
                    let from = Date(timeIntervalSince1970: f.first!.t - 120), to = Date(timeIntervalSince1970: f.last!.t + 60)
                    let mine = lines.filter { $0.at >= from && $0.at <= to }
                    var truth: String?, truthFrom = "none"
                    if let given = e.truth[ride]?[leg] { truth = vehicleKey(given); truthFrom = "given" }
                    else if let hand = mine.compactMap({ handPicked($0.text) }).last { truth = hand; truthFrom = "hand pick" }
                    else if let last = f.last(where: { $0.veh != nil })?.veh { truth = vehicleKey(last); truthFrom = "ended on" }
                    out.append(ReplayLeg(install: install, ride: ride, leg: leg, fixes: f, lines: mine, truth: truth, truthFrom: truthFrom))
                }
            }
        }
        return out
    }
}
