import Foundation

/// One weigh-in or waist measurement on a recomp day.
struct Measure: Codable, Equatable {
    var day: DayKey
    var value: Double
}

enum AdviceKind: String, Codable {
    case eatLess, eatMore
}

/// Advice that stays on screen until the person taps "adjusted" (or three weeks pass).
struct PendingAdvice: Codable, Equatable {
    var kind: AdviceKind
    /// A Monday.
    var shownOn: DayKey
}

struct CheckState: Codable, Equatable {
    var pending: PendingAdvice? = nil
    var baseline: DayKey? = nil
}
