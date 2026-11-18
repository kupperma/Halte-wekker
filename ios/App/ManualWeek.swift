import Foundation

/// "Same times every week": the first class of each weekday with school, in Amsterdam time. Saved in the profile.
/// (0.22 only keeps it; from 0.23 the school alarm plans from it.)
struct ManualWeek: Codable, Equatable, Sendable {
    struct Day: Codable, Equatable, Sendable {
        /// Calendar weekday: 1 is Sunday, 2 Monday … 7 Saturday.
        var weekday: Int
        /// The first class, in minutes after midnight.
        var minutes: Int
    }

    /// At most one per weekday, in weekday order.
    private(set) var days: [Day]

    init(days: [Day]) { self.days = Self.clean(days) }

    /// The first class on a weekday, in minutes after midnight (nil: no school that day).
    func minutes(weekday: Int) -> Int? { days.first { $0.weekday == weekday }?.minutes }

    // Postel: days that don't make sense are left out, a weekday given twice keeps the last one.
    enum CodingKeys: String, CodingKey { case days }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        days = Self.clean((try? c.decode([Day].self, forKey: .days)) ?? [])
    }

    private static func clean(_ l: [Day]) -> [Day] {
        var by: [Int: Day] = [:]
        for d in l where (1...7).contains(d.weekday) && (0..<1440).contains(d.minutes) { by[d.weekday] = d }
        return by.keys.sorted().compactMap { by[$0] }
    }
}
