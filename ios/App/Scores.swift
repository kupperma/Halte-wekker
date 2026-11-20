import Foundation

// `TripScore` and the rules are in ScoreRules.swift (0.35, tested).

struct ScoreResult: Equatable {
    let entry: TripScore
    let fastestWeek: Bool
    let fastestEver: Bool
    let firstWeek: Bool
    var flag: String? {
        let w = entry.home ? "home" : "to \(RoleWords.current.toSchoolWord)"
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
        trips = ScoreRules.decode(UserDefaults.standard.data(forKey: "trips"))
    }
    private func persist() { UserDefaults.standard.set(try? JSONEncoder().encode(trips), forKey: "trips") }

    static func letter(_ n: Int) -> String { ScoreRules.letter(n) }

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
        log(name: r.name, ideal: ideal(r, home: home), home: home, start: start, end: end)
    }

    /// A door-to-door trip between Home and School (0.24 off the corridor; 0.35 on it too: `ScoreRules.board`), against
    /// your own fastest. `plan`, `lateLine`, `late`: for today's ranking (0.35).
    func log(door key: String, home: Bool, start: Date, end: Date = Date(), plan: Double? = nil, lateLine: String? = nil, late: Double? = nil) -> ScoreResult? {
        log(name: key, ideal: nil, home: home, start: start, end: end, plan: plan, lateLine: lateLine, late: late)
    }

    private func log(name: String, ideal: Double?, home: Bool, start: Date, end: Date, plan: Double? = nil, lateLine: String? = nil, late: Double? = nil) -> ScoreResult? {
        guard let s = ScoreRules.score(name: name, ideal: ideal, home: home, start: start, end: end, trips: trips, weekStart: Self.weekStart,
                                       plan: plan, lateLine: lateLine, late: late) else { return nil }
        trips.insert(s.entry, at: 0)
        if trips.count > 300 { trips = Array(trips.prefix(300)) }
        persist()
        return ScoreResult(entry: s.entry, fastestWeek: s.fastestWeek, fastestEver: s.fastestEver, firstWeek: s.firstWeek)
    }

    /// A ride of a scored trip turned out late (its delay at your stop comes in after the trip was scored): the trip keeps
    /// its latest ride, for today's ranking.
    func noteLate(_ id: String, line: String, mins: Double) {
        guard let i = trips.firstIndex(where: { $0.id == id }), mins > (trips[i].late ?? -.infinity) else { return }
        trips[i].lateLine = line
        trips[i].late = (mins * 10).rounded() / 10
        persist()
    }

    func remove(_ id: String) { trips.removeAll { $0.id == id }; persist() }
    func reset() { trips = []; persist() }

    func board(home: Bool, week: Bool) -> [TripScore] {
        let all = trips.filter { $0.home == home }
        return (week ? all.filter { $0.at >= Self.weekStart } : all).sorted { $0.mins != $1.mins ? $0.mins < $1.mins : $0.score > $1.score }
    }
    func bestThisWeek(home: Bool) -> TripScore? { board(home: home, week: true).first }
}
