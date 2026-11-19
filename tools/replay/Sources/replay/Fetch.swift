import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The vehicles around a real ride, from Transitous's timetable (the same /v1/map/trips the app asks, for the ride's
// own time: its open data keeps past days). Live times and the vehicles' own GPS of that moment aren't kept there, so a
// replay of a real ride judges by the timetable (and by live times when Transitous still has them).

enum Fetch {
    static let base = "https://api.transitous.org/api"

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let isoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func date(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        return iso.date(from: s) ?? isoFraction.date(from: s)
    }

    /// The app's polyline decoding (`Transit.decodePolyline`).
    static func polyline(_ s: String, precision: Int = 5) -> [GeoPoint] {
        let scale = pow(10.0, Double(precision))
        var pts: [GeoPoint] = [], lat = 0, lng = 0
        let b = Array(s.utf8)
        var i = 0
        while i < b.count {
            var vals = [0, 0]
            for k in 0..<2 {
                var r = 0, sh = 0
                while i < b.count {
                    let c = Int(b[i]) - 63
                    i += 1
                    r |= (c & 0x1f) << sh
                    sh += 5
                    if c < 0x20 { break }
                }
                vals[k] = (r & 1) != 0 ? ~(r >> 1) : (r >> 1)
            }
            lat += vals[0]; lng += vals[1]
            pts.append(GeoPoint(lat: Double(lat) / scale, lon: Double(lng) / scale))
        }
        return pts
    }

    /// One answer of /v1/map/trips as the matcher's pieces: every trip on a piece (as the app's matcher asks, `allTrips`).
    static func pieces(_ list: [[String: Any]]) -> [MapPiece] {
        list.flatMap { s -> [MapPiece] in
            guard let trips = s["trips"] as? [[String: Any]], let dep = date(s["departure"]), let arr = date(s["arrival"]),
                  let poly = s["polyline"] as? String else { return [] }
            let mode = (s["mode"] as? String) ?? ""
            guard mode != "AIRPLANE" else { return [] }
            let path = polyline(poly), live = (s["realTime"] as? Bool) ?? false
            let train = !(mode.contains("BUS") || mode.contains("COACH"))
            return trips.compactMap { t -> MapPiece? in
                guard let id = t["tripId"] as? String else { return nil }
                return MapPiece(tripId: id, line: (t["routeShortName"] as? String) ?? "?", isTrain: train, realTime: live,
                                piece: TimedPiece(departure: dep, arrival: arr, path: path))
            }
        }
    }

    /// One answer, waited for (the replay is a plain command-line run).
    private final class Answer: @unchecked Sendable {
        var data: Data?
        var failure: Error?
    }

    static func get(_ url: URL) throws -> Data {
        let a = Answer()
        let done = DispatchSemaphore(value: 0)
        var r = URLRequest(url: url)
        r.timeoutInterval = 40
        r.setValue("haltewekker-replay", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: r) { d, resp, e in
            if let e { a.failure = e }
            else if let h = resp as? HTTPURLResponse, h.statusCode != 200 { a.failure = URLError(.badServerResponse) }
            else { a.data = d }
            done.signal()
        }.resume()
        done.wait()
        if let f = a.failure { throw f }
        return a.data ?? Data()
    }

    /// The vehicles around a leg: its points in 5-minute stretches, each asked for the box around them (the app's
    /// radius, 0.02° by 0.032°, wider at train speed) and its time (150 s before to 90 s after).
    static func tracks(for leg: ReplayLeg, log: (String) -> Void = { _ in }) -> [VehicleTrack] {
        var pieces: [MapPiece] = []
        var chunk: [ExportFix] = []
        func ask() {
            guard let a = chunk.first, let b = chunk.last else { return }
            let fast = chunk.contains { ($0.spd ?? 0) > 15 }
            let r = fast ? 0.04 : 0.02
            let lats = chunk.map(\.lat), lons = chunk.map(\.lon)
            var c = URLComponents(string: base + "/v1/map/trips")!
            c.queryItems = [
                .init(name: "min", value: "\(lats.min()! - r),\(lons.min()! - r * 1.6)"),
                .init(name: "max", value: "\(lats.max()! + r),\(lons.max()! + r * 1.6)"),
                .init(name: "startTime", value: iso.string(from: Date(timeIntervalSince1970: a.t - 150))),
                .init(name: "endTime", value: iso.string(from: Date(timeIntervalSince1970: b.t + 90))),
                .init(name: "zoom", value: "15"),
            ]
            do {
                let d = try get(c.url!)
                let list = (try JSONSerialization.jsonObject(with: d) as? [[String: Any]]) ?? []
                let got = Fetch.pieces(list)
                log("  fetched \(got.count) pieces for \(iso.string(from: Date(timeIntervalSince1970: a.t)))")
                pieces += got
            } catch {
                log("  couldn't fetch the vehicles for \(iso.string(from: Date(timeIntervalSince1970: a.t))): \(error)")
            }
        }
        for f in leg.fixes {
            if let a = chunk.first, f.t - a.t > 300 { ask(); chunk = [] }
            chunk.append(f)
        }
        ask()
        return VehicleTrack.group(pieces)
    }
}
