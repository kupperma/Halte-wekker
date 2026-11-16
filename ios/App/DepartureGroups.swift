import Foundation

/// The departure cards at the bottom of the home: one stop per card (the station you're near first, then the nearest
/// bus stops), each with its next few departures. Plain values, so the grouping and the order are tested.
enum DepartureGroups {
    struct Stop: Equatable {
        let id: String
        let name: String
        let rail: Bool
        let metres: Double?
        let lat: Double?
        let lon: Double?
        init(id: String, name: String, rail: Bool, metres: Double?, lat: Double? = nil, lon: Double? = nil) {
            self.id = id; self.name = name; self.rail = rail; self.metres = metres; self.lat = lat; self.lon = lon
        }
    }

    struct Departure: Equatable, Identifiable {
        var id: String { "\(tripId)|\(stopId)" }
        let tripId: String
        let stopId: String
        let line: String
        let headsign: String
        let time: Date              // live (or planned)
        let scheduled: Date
        let live: Bool
        let cancelled: Bool
        let platform: String?
        let train: Bool
        var stopName: String = ""
        var delay: Int { live ? Int((time.timeIntervalSince(scheduled) / 60).rounded()) : 0 }
        /// When it goes (a cancelled one: when it would have).
        var leaves: Date { cancelled ? scheduled : time }
    }

    struct Card: Equatable, Identifiable {
        var id: String { stop.id }
        let stop: Stop
        let departures: [Departure]
    }

    /// A station this close comes first (you're near it); further away, the stops by distance.
    static let stationFirstWithin = 1200.0

    /// The cards: at most `maxCards`, each with its next `perCard` departures (from a minute ago on, each trip once).
    static func cards(stops: [Stop], departures: [Departure], now: Date, perCard: Int = 3, maxCards: Int = 3) -> [Card] {
        let ordered = order(stops)
        var out: [Card] = []
        for s in ordered.prefix(maxCards) {
            var seen = Set<String>()
            let next = departures
                .filter { $0.stopId == s.id && $0.leaves > now.addingTimeInterval(-60) }
                .sorted { $0.leaves < $1.leaves }
                .filter { seen.insert($0.tripId.isEmpty ? $0.id : $0.tripId).inserted }
            out.append(Card(stop: s, departures: Array(next.prefix(perCard))))
        }
        return out
    }

    /// The station you're near first, then by distance (unknown distances last, in the order given).
    static func order(_ stops: [Stop]) -> [Stop] {
        var seen = Set<String>()
        let unique = stops.filter { seen.insert($0.id).inserted }
        let station = unique.filter { $0.rail && ($0.metres ?? .infinity) <= stationFirstWithin }
            .min { ($0.metres ?? .infinity) < ($1.metres ?? .infinity) }
        let rest = unique.enumerated().filter { $0.element.id != station?.id }
            .sorted { a, b in
                let x = a.element.metres ?? .infinity, y = b.element.metres ?? .infinity
                return x != y ? x < y : a.offset < b.offset
            }
            .map(\.element)
        return (station.map { [$0] } ?? []) + rest
    }

    /// "now", "5 min", or past an hour the time itself (`clock` formats it).
    static func countdown(_ d: Departure, now: Date, clock: (Date) -> String) -> String {
        let m = Int((d.leaves.timeIntervalSince(now) / 60).rounded(.down))
        if m < 1 { return "now" }
        if m >= 60 { return clock(d.leaves) }
        return "\(m) min"
    }

    /// "+4" for a live departure 1 minute or more late (nil: on time, not live, or cancelled).
    static func lateText(_ d: Departure) -> String? {
        guard !d.cancelled, d.delay >= 1 else { return nil }
        return "+\(d.delay)"
    }

    /// "4 min walk" at about 80 m a minute.
    static func walkText(metres: Double?) -> String? {
        guard let m = metres, m.isFinite, m >= 0 else { return nil }
        return "\(max(1, Int((m / 80).rounded()))) min walk"
    }

    // MARK: the next-trip nudge

    /// "Leave in 9 min" (nil once it's more than 5 minutes past: then the departures show again).
    static func leaveText(leave: Date, now: Date) -> String? {
        let s = leave.timeIntervalSince(now)
        guard s > -5 * 60 else { return nil }
        let m = Int((s / 60).rounded(.down))
        return m < 1 ? "Leave now" : "Leave in \(m) min"
    }
}
