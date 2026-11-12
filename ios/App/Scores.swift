import Foundation

/// One finished trip on the leaderboard.
struct TripScore: Codable, Identifiable, Equatable {
    let id: String
    let at: Date
    let home: Bool
    let route: String           // "Via Den Bosch"
    let mins: Double
    let score: Int              // out of 500
    let grade: String           // S A B C D F
    let ref: Int                // the fastest possible, in minutes
    let est: Bool               // no fastest time known yet: compared with your own trips
}

struct ScoreResult: Equatable {
    let entry: TripScore
    let fastestWeek: Bool
    let fastestEver: Bool
    let firstWeek: Bool
    var flag: String? {
        let w = entry.home ? "home" : "to Breda"
        if fastestEver { return "🏆 Your fastest trip \(w) ever!" }
        if fastestWeek { return "🏆 Fastest trip \(w) this week!" }
        if firstWeek { return "First trip \(w) this week" }
        return nil
    }
}

/// Trip score out of 500: the fastest the route gets (fastest bus and train seen, plus 5 min to change) against your time.
@MainActor
final class ScoreBook: ObservableObject {
    static let shared = ScoreBook()
    @Published private(set) var trips: [TripScore]
    private static let changeMinutes = 5.0

    private init() {
        trips = UserDefaults.standard.data(forKey: "trips").flatMap { try? JSONDecoder().decode([TripScore].self, from: $0) } ?? []
    }
    private func persist() { UserDefaults.standard.set(try? JSONEncoder().encode(trips), forKey: "trips") }

    static func letter(_ n: Int) -> String { n >= 475 ? "S" : n >= 425 ? "A" : n >= 375 ? "B" : n >= 325 ? "C" : n >= 275 ? "D" : "F" }

    static var weekStart: Date {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return c.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
    }

    func ideal(_ r: RoutePlan, home: Bool) -> Double? {
        let x = r.station.key
        let parts = home ? ["c:bd>\(x)", "c:\(x)>veghel"] : ["c:veghel>\(x)", "c:\(x)>bd"]
        let b = parts.compactMap { Ratings.shared.best($0) }
        guard b.count == parts.count else { return nil }
        return b.reduce(0, +) + Self.changeMinutes
    }

    /// At the end of a trip from your first stop: score it and put it on the board.
    func log(route r: RoutePlan, home: Bool, start: Date, end: Date = Date()) -> ScoreResult? {
        let mins = (end.timeIntervalSince(start) / 6).rounded() / 10
        guard mins >= 5 else { return nil }
        let same = trips.filter { $0.home == home && $0.route == r.name }
        let ideal = ideal(r, home: home)
        let ref = ideal ?? same.map(\.mins).min() ?? mins
        let score = Int((500 * min(1, ref / mins)).rounded())
        let e = TripScore(id: "t" + String(Int(end.timeIntervalSince1970), radix: 36), at: end, home: home, route: r.name, mins: mins,
                          score: score, grade: Self.letter(score), ref: Int(ref.rounded()), est: ideal == nil)
        let mine = trips.filter { $0.home == home }
        let week = mine.filter { $0.at >= Self.weekStart }
        let res = ScoreResult(entry: e, fastestWeek: !week.isEmpty && week.allSatisfy { $0.mins > mins },
                              fastestEver: !mine.isEmpty && mine.allSatisfy { $0.mins > mins }, firstWeek: week.isEmpty)
        trips.insert(e, at: 0)
        if trips.count > 300 { trips = Array(trips.prefix(300)) }
        persist()
        return res
    }

    func remove(_ id: String) { trips.removeAll { $0.id == id }; persist() }
    func reset() { trips = []; persist() }

    func board(home: Bool, week: Bool) -> [TripScore] {
        let all = trips.filter { $0.home == home }
        return (week ? all.filter { $0.at >= Self.weekStart } : all).sorted { $0.mins != $1.mins ? $0.mins < $1.mins : $0.score > $1.score }
    }
    func bestThisWeek(home: Bool) -> TripScore? { board(home: home, week: true).first }
}
