import Foundation

/// One option from the Transitous trip planner, reduced to what the app needs.
struct Ride {
    let line: String          // "306" or "Intercity"
    let isTrain: Bool
    let departure: Date       // first bus/train leaves (live)
    let arrival: Date         // last bus/train arrives (live)
    let start: Date           // including a walk at the start
    let fromStop: String
    let platform: String?
}

/// Talks to Transitous (free, volunteer-run; keep requests light).
enum Transit {
    static let base = "https://api.transitous.org/api"
    static let userAgent = "Haltewekker-iOS/0.1 (https://github.com/kupperma/Halte-wekker)"

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

    static func plan(from: String, to: String, mode: Mode, at: Date, count: Int) async throws -> [Ride] {
        var c = URLComponents(string: base + "/v5/plan")!
        c.queryItems = [
            .init(name: "fromPlace", value: from), .init(name: "toPlace", value: to),
            .init(name: "transitModes", value: mode.transitModes),
            .init(name: "numItineraries", value: String(count)),
            .init(name: "maxTransfers", value: mode == .train ? "1" : "0"),
            .init(name: "time", value: iso.string(from: at)),
        ]
        var req = URLRequest(url: c.url!, timeoutInterval: 20)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let its = json["itineraries"] as? [[String: Any]] else { return [] }
        return its.compactMap { it in
            let legs = (it["legs"] as? [[String: Any]]) ?? []
            let rides = legs.filter { ($0["mode"] as? String) != "WALK" }
            guard let f = rides.first, let z = rides.last,
                  let dep = date(f["startTime"]), let arr = date(z["endTime"]) else { return nil }
            let fromObj = f["from"] as? [String: Any]
            let mode = (f["mode"] as? String) ?? ""
            return Ride(line: (f["routeShortName"] as? String) ?? (f["displayName"] as? String) ?? "?",
                        isTrain: !(mode.contains("BUS") || mode.contains("COACH")),
                        departure: dep, arrival: arr, start: date(it["startTime"]) ?? dep,
                        fromStop: (fromObj?["name"] as? String) ?? "",
                        platform: (fromObj?["track"] as? String) ?? (fromObj?["scheduledTrack"] as? String))
        }
    }

    /// Every combination of stops between two places (Veghel has two stops).
    static func rides(from: Place, to: Place, mode: Mode, at: Date, count: Int) async -> [Ride] {
        await withTaskGroup(of: [Ride].self) { g in
            for a in from.ids { for b in to.ids {
                g.addTask { (try? await plan(from: a, to: b, mode: mode, at: at, count: count)) ?? [] }
            } }
            var all: [Ride] = []
            for await r in g { all += r }
            return all
        }
    }

    /// When you reach the end of the trip: the ride you're on now, then the first connection after it.
    static func estimate(legs: [Leg], index: Int, legStart: Date) async -> (arrival: Date, next: Ride?)? {
        guard index < legs.count else { return nil }
        let leg = legs[index]
        let options = await rides(from: leg.from, to: leg.to, mode: leg.mode, at: legStart.addingTimeInterval(-40 * 60), count: 8)
            .filter { $0.departure >= legStart.addingTimeInterval(-40 * 60) && $0.departure <= legStart.addingTimeInterval(15 * 60) }
        guard let on = options.min(by: { abs($0.departure.timeIntervalSince(legStart)) < abs($1.departure.timeIntervalSince(legStart)) }) else { return nil }
        var t = on.arrival
        var next: Ride?
        for k in (index + 1)..<max(index + 1, legs.count) {
            let l = legs[k]
            let opts = await rides(from: l.from, to: l.to, mode: l.mode, at: t.addingTimeInterval(120), count: 4)
                .filter { $0.start >= t.addingTimeInterval(60) }
            guard let best = opts.min(by: { ($0.arrival, $0.departure) < ($1.arrival, $1.departure) }) else { return nil }
            if next == nil { next = best }
            t = best.arrival
        }
        return (t, next)
    }
}
