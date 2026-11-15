import Foundation

/// What the workout Live Activity shows. The widget can't read the app's files, so everything it needs is in here.
/// Every text is at most `maxText` characters and `maxBytes` bytes, which keeps the state far under ActivityKit's 4 KB.
struct WorkoutLiveState: Codable, Hashable {
    static let maxText = 40
    static let maxBytes = 160

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
    var setId: UUID? = nil          // the LoggedSet.id of the set shown as next; nil when allDone

    /// A copy with every text cut by `cut(_:)`.
    var clipped: WorkoutLiveState {
        var s = self
        s.title = Self.cut(title)
        s.exercise = Self.cut(exercise)
        s.planned = Self.cut(planned)
        s.plannedShort = Self.cut(plannedShort)
        s.last = last.map(Self.cut)
        return s
    }

    /// The first `maxText` characters, then whole characters off the end until it fits in `maxBytes` of UTF-8.
    /// It counts grapheme clusters, so an emoji or a letter with its accents is never split.
    static func cut(_ text: String) -> String {
        var s = text.count > maxText ? String(text.prefix(maxText)) : text
        while s.utf8.count > maxBytes { s.removeLast() }
        return s
    }
}

private struct LiveKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

extension WorkoutLiveState {
    /// Tolerant: a missing or null field gets its default, so a state from an older version still decodes.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LiveKey.self)
        func get<T: Decodable>(_ key: String, _ fallback: T) throws -> T {
            try c.decodeIfPresent(T.self, forKey: LiveKey(key)) ?? fallback
        }
        func opt<T: Decodable>(_ key: String) throws -> T? {
            try c.decodeIfPresent(T.self, forKey: LiveKey(key))
        }
        title = try get("title", "")
        started = try get("started", Date(timeIntervalSince1970: 0))
        exercise = try get("exercise", "")
        exerciseNumber = try get("exerciseNumber", 0)
        exerciseCount = try get("exerciseCount", 0)
        setNumber = try get("setNumber", 0)
        setCount = try get("setCount", 0)
        warmup = try get("warmup", false)
        planned = try get("planned", "")
        plannedShort = try get("plannedShort", "")
        last = try opt("last")
        restStarted = try opt("restStarted")
        restEnds = try opt("restEnds")
        allDone = try get("allDone", false)
        setId = try opt("setId")
    }
}
