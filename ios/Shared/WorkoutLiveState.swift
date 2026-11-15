import Foundation

/// What the workout Live Activity shows. The widget can't read the app's files, so everything it needs is in here.
/// Every text is at most `maxText` characters, which keeps the state far under ActivityKit's 4 KB.
struct WorkoutLiveState: Codable, Hashable {
    static let maxText = 40

    var title: String               // "Pull + legs"
    var started: Date
    var exercise: String            // "Lat pulldown"
    var exerciseNumber: Int         // 3 (of 9)
    var exerciseCount: Int
    var setNumber: Int              // 2 (of 3): counted among the work sets, or among the warm-ups
    var setCount: Int
    var warmup: Bool
    var planned: String             // "57.5 kg × 8"
    var plannedShort: String        // "57.5 × 8"
    var last: String?               // "55 × 11"
    var restStarted: Date?
    var restEnds: Date?
    var allDone: Bool               // nothing left: the set fields describe the last done set

    /// A copy with every text cut to `maxText` characters. It counts grapheme clusters, so an emoji is never split.
    var clipped: WorkoutLiveState {
        var s = self
        s.title = Self.cut(title)
        s.exercise = Self.cut(exercise)
        s.planned = Self.cut(planned)
        s.plannedShort = Self.cut(plannedShort)
        s.last = last.map(Self.cut)
        return s
    }

    static func cut(_ text: String) -> String {
        text.count > maxText ? String(text.prefix(maxText)) : text
    }
}
