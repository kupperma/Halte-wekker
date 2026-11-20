import Foundation

/// 0.37: how many OV-fiets (NS rental bikes) are left at a station — the relay's answer (`/ns/ovfiets?station=BD`:
/// NS's Places API, slimmed), read here; which station of a trip it's for; and the line on the
/// Go card, the ride screen's last train and the station sheet. Plain values (Foundation only), tested.
enum OVFiets {
    /// One rental point at the station ("Breda Belcrum"): how many bikes are there (nil: NS doesn't say).
    struct Point: Equatable, Sendable {
        let name: String
        let code: String
        let bikes: Int?
        let open: Bool?
    }

    struct Answer: Equatable, Sendable {
        let station: String
        let points: [Point]
        /// The bikes at the points that say how many (nil: none says).
        var total: Int? {
            let known = points.compactMap(\.bikes)
            return known.isEmpty ? nil : known.reduce(0, +)
        }
        /// Every staffed point is closed now (NS's "open": "No"); nil when NS doesn't say.
        var closed: Bool? {
            let o = points.compactMap(\.open)
            guard !o.isEmpty else { return nil }
            return !o.contains(true)
        }
    }

    /// The relay's answer: `{"station":"BD","locations":[{"name","code","bikes","lat","lon","open"}]}`. NS's own (a
    /// `payload[].locations[]` with `extra.rentalBikes` as text) is read too.
    static func parse(_ data: Data, station: String) -> Answer? {
        guard let j = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return parse(json: j, station: station)
    }

    static func parse(json: Any, station: String) -> Answer? {
        func int(_ a: Any?) -> Int? {
            if let n = a as? NSNumber { return n.intValue >= 0 ? n.intValue : nil }
            if let s = a as? String, let n = Int(s.trimmingCharacters(in: .whitespaces)), n >= 0 { return n }
            return nil
        }
        func open(_ a: Any?) -> Bool? {
            guard let s = (a as? String)?.lowercased() else { return nil }
            if s == "yes" { return true }
            if s == "no" { return false }
            return nil
        }
        let want = station.uppercased()
        if let d = json as? [String: Any], let list = d["locations"] as? [[String: Any]] {
            let pts = list.map { m in
                Point(name: (m["name"] as? String) ?? "", code: (m["code"] as? String) ?? "", bikes: int(m["bikes"]), open: open(m["open"]))
            }
            return Answer(station: ((d["station"] as? String) ?? want).uppercased(), points: pts)
        }
        // NS's own answer
        guard let payload = (json as? [String: Any])?["payload"] as? [[String: Any]] else { return nil }
        var pts: [Point] = []
        for p in payload {
            for m in (p["locations"] as? [[String: Any]]) ?? [] {
                if let sc = (m["stationCode"] as? String)?.uppercased(), sc != want { continue }
                let extra = m["extra"] as? [String: Any] ?? [:]
                pts.append(Point(name: (m["name"] as? String) ?? "", code: (extra["locationCode"] as? String) ?? "",
                                 bikes: int(extra["rentalBikes"]), open: open(m["open"])))
            }
        }
        return Answer(station: want, points: pts)
    }

    /// "OV-fiets: 12 left", "OV-fiets: 1 left", "OV-fiets: none left"; "· closed now" when every staffed point is shut.
    /// Nothing when NS has no count for the station (or it has no OV-fiets).
    static func text(_ a: Answer) -> String? {
        guard let n = a.total else { return nil }
        let left = n == 0 ? "none left" : "\(n) left"
        return "OV-fiets: \(left)" + (a.closed == true ? " · closed now" : "")
    }

    /// Few enough to say it warmly (it may be gone by the time you're there).
    static func low(_ a: Answer) -> Bool { (a.total ?? 99) <= 5 }

    /// How long an answer is good for (NS counts every few minutes; the relay keeps it 5 min too).
    static let ttl: TimeInterval = 5 * 60
    static func fresh(_ at: Date, now: Date) -> Bool { now.timeIntervalSince(at) < ttl && now >= at.addingTimeInterval(-60) }

    /// A ride of a trip, as far as it matters here: a train or not, and the NS code of the station it arrives at.
    struct Ride: Equatable, Sendable {
        let train: Bool
        let toCode: String?
    }

    /// The station whose bikes a trip wants: where its last train arrives, when there's more of the trip after it (a
    /// bus on, or a walk of 5 minutes or more — the station nearest school or home). Nil: no train, or the trip ends at
    /// the station.
    static func station(_ rides: [Ride], walkAfter: Int) -> String? {
        guard let i = rides.lastIndex(where: \.train), let code = rides[i].toCode else { return nil }
        let after = rides.count - 1 - i
        return after > 0 || walkAfter >= 5 ? code : nil
    }
}
