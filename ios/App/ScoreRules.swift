import Foundation

// The leaderboard's rules (0.35), Foundation only so they can be tested: which board a finished trip goes on, its score,
// and reading the saved board. `ScoreBook` (Scores.swift) keeps the board; `TripManager.legDone` hands in the trip.
//
// Why this exists (0.35): until 0.34 a trip was only scored when it was one of the corridor's two fixed routes ("Via Den
// Bosch") or, off the corridor only, a door-to-door trip. Since 0.19 the new look's home starts every trip as a planned
// trip (`RoutePlan.from(DoorTrip)`, a custom route: Go's board, "I'm on it", the home map, the auto-start off the
// corridor), and a fixed route that's planned again on board becomes one too. On the corridor those were never scored, so
// the leaderboard stopped getting trips. Now a custom trip between Home and School is scored on or off the corridor.

/// One finished trip on the leaderboard (saved in UserDefaults "trips", unchanged since 0.9.1).
struct TripScore: Codable, Identifiable, Equatable {
    let id: String
    let at: Date
    let home: Bool
    let route: String           // "Via Den Bosch", or "home→school" / "school→home" (door to door)
    let mins: Double
    let score: Int              // out of 500
    let grade: String           // S A B C D F
    let ref: Int                // the fastest possible, in minutes
    let est: Bool               // no fastest time known yet: compared with your own trips
    // 0.35, all optional (an older save reads; an older app ignores them):
    /// Planned minutes, from starting the alarm to the scheduled arrival at the last stop (a planned trip only).
    var plan: Double? = nil
    /// The ride that was latest at your stop ("305", "Intercity") and by how many minutes.
    var lateLine: String? = nil
    var late: Double? = nil
}

enum ScoreRules {
    /// What kind of trip ended.
    enum Kind: Equatable {
        /// One of the corridor's two routes, by its name ("Via Den Bosch").
        case fixed(String)
        /// A planned trip (rides one leg each), on or off the corridor.
        case custom
        /// "Wake me at a single stop": not a trip between two places.
        case single
    }

    /// A trip at its last stop, as the board needs it.
    struct Finished: Equatable {
        var kind: Kind
        var demo: Bool
        /// The leg it started at (0: from your first stop; a trip started at a change isn't a whole trip).
        var startedAtLeg: Int
        /// Going home (the trip's direction).
        var home: Bool
        /// Where it started, best first: where you were when the alarm started (if that fix was fresh), then the first
        /// stop. Any one of them near Home (or School) will do.
        var starts: [GeoPoint]
        /// Its last stop.
        var end: GeoPoint?
        var homePlace: GeoPoint
        var school: GeoPoint
    }

    /// The board's key for a finished trip and whether it went home; nil: it doesn't go on the board.
    static func board(_ f: Finished) -> (route: String, home: Bool)? {
        guard !f.demo, f.startedAtLeg == 0 else { return nil }
        switch f.kind {
        case .fixed(let name): return (name, f.home)
        case .single: return nil
        case .custom:
            guard let end = f.end else { return nil }
            for s in f.starts {
                if let k = DoorScore.key(start: s, end: end, home: f.homePlace, school: f.school) { return k }
            }
            return nil
        }
    }

    /// A fix this old or older isn't where the trip started.
    static let freshStart: TimeInterval = 600

    static func letter(_ n: Int) -> String { n >= 475 ? "S" : n >= 425 ? "A" : n >= 375 ? "B" : n >= 325 ? "C" : n >= 275 ? "D" : "F" }

    struct Scored: Equatable {
        var entry: TripScore
        var fastestWeek: Bool
        var fastestEver: Bool
        var firstWeek: Bool
    }

    /// A trip's score out of 500: `ideal` (the fastest the route gets) or else your fastest on that key against your
    /// time; nil under 5 minutes. `trips`: the board as it is; `weekStart`: this week's Monday 00:00.
    static func score(name: String, ideal: Double?, home: Bool, start: Date, end: Date, trips: [TripScore], weekStart: Date,
                      plan: Double? = nil, lateLine: String? = nil, late: Double? = nil) -> Scored? {
        let mins = (end.timeIntervalSince(start) / 6).rounded() / 10
        guard mins >= 5 else { return nil }
        let same = trips.filter { $0.home == home && $0.route == name }
        let ref = ideal ?? same.map(\.mins).min() ?? mins
        let score = Int((500 * min(1, ref / mins)).rounded())
        let e = TripScore(id: "t" + String(Int(end.timeIntervalSince1970), radix: 36), at: end, home: home, route: name, mins: mins,
                          score: score, grade: letter(score), ref: Int(ref.rounded()), est: ideal == nil,
                          plan: plan.map { ($0 * 10).rounded() / 10 }, lateLine: lateLine, late: late.map { ($0 * 10).rounded() / 10 })
        let mine = trips.filter { $0.home == home }
        let week = mine.filter { $0.at >= weekStart }
        return Scored(entry: e, fastestWeek: !week.isEmpty && week.allSatisfy { $0.mins > mins },
                      fastestEver: !mine.isEmpty && mine.allSatisfy { $0.mins > mins }, firstWeek: week.isEmpty)
    }

    /// The saved board. One entry that doesn't read any more is skipped, not the whole board (before 0.35 a single bad
    /// entry read as an empty board, and the next trip saved over everything).
    static func decode(_ data: Data?) -> [TripScore] {
        guard let data else { return [] }
        if let all = try? JSONDecoder().decode([TripScore].self, from: data) { return all }
        guard let some = try? JSONDecoder().decode([Lossy].self, from: data) else { return [] }
        return some.compactMap(\.value)
    }

    private struct Lossy: Decodable {
        let value: TripScore?
        init(from decoder: Decoder) throws { value = try? TripScore(from: decoder) }
    }

    /// The worst late ride of a trip so far, with one more ride's delay: the later one stays (nil: none known).
    static func worse(_ had: (line: String, mins: Double)?, _ new: (line: String, mins: Double)) -> (line: String, mins: Double) {
        guard let had else { return new }
        return new.mins > had.mins ? new : had
    }
}
