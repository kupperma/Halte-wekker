import Foundation

enum SetStyle { case long, short, compact }

/// Copy for workouts. Pure, so it is tested in the hostless target.
enum WorkoutFormat {
    /// DateFormatter and NumberFormatter are not thread-safe: one per format and zone, behind a lock.
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var dates: [String: DateFormatter] = [:]
        private var grouped: NumberFormatter?

        func string(_ d: Date, format: String, zone: TimeZone) -> String {
            lock.lock()
            defer { lock.unlock() }
            let key = zone.identifier + "|" + format
            let f: DateFormatter
            if let c = dates[key] {
                f = c
            } else {
                f = DateFormatter()
                f.locale = Locale(identifier: "en_GB")
                f.timeZone = zone
                f.dateFormat = format
                dates[key] = f
            }
            return f.string(from: d)
        }

        func grouping(_ n: Int) -> String {
            lock.lock()
            defer { lock.unlock() }
            let f: NumberFormatter
            if let c = grouped {
                f = c
            } else {
                f = NumberFormatter()
                f.locale = Locale(identifier: "en_US")
                f.numberStyle = .decimal
                f.usesGroupingSeparator = true
                grouped = f
            }
            return f.string(from: NSNumber(value: n)) ?? String(n)
        }
    }

    private static let cache = Cache()

    /// Dot, at most 2 decimals, no trailing zeros: "57.5", "26", "1.25".
    static func kg(_ v: Double) -> String {
        var s = String(format: "%.2f", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        if s == "-0" { s = "0" }
        return s
    }

    static func set(_ s: LoggedSet, _ kind: ExerciseKind, _ style: SetStyle = .long) -> String {
        switch kind {
        case .time:
            guard let sec = s.seconds else { return "—" }
            return "\(sec) s"
        case .cardio:
            var parts: [String] = []
            if let km = s.km { parts.append("\(kg(km)) km") }
            if let sec = s.seconds { parts.append(rest(sec)) }
            return parts.isEmpty ? "—" : parts.joined(separator: " · ")
        case .bodyweight:
            return repsOnly(s.reps, style)
        case .weight, .weighted, .assisted:
            guard let w = s.kg, kind == .weight || w != 0 else { return repsOnly(s.reps, style) }
            let prefix = kind == .weighted ? "+" : (kind == .assisted ? "\u{2212}" : "")
            let weight = prefix + kg(w)
            guard let r = s.reps else { return style == .long ? weight + " kg" : weight }
            switch style {
            case .long: return "\(weight) kg × \(r)"
            case .short: return "\(weight) × \(r)"
            case .compact: return "\(weight)×\(r)"
            }
        }
    }

    private static func repsOnly(_ reps: Int?, _ style: SetStyle) -> String {
        guard let r = reps else { return "—" }
        return style == .long ? "\(r) reps" : "\(r)"
    }

    /// "2:30".
    static func rest(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func target(_ t: Target, _ kind: ExerciseKind) -> String {
        let unit = kind == .time ? " s" : ""
        let range = t.lo == t.hi ? "\(t.lo)" : "\(t.lo)–\(t.hi)"
        var out = "\(t.sets) × \(range)\(unit)"
        if let lo = t.rirLo {
            let hi = t.rirHi ?? lo
            out += lo == hi ? " · RIR \(lo)" : " · RIR \(lo)–\(hi)"
        }
        out += " · rest \(rest(t.rest))"
        return out
    }

    /// "Thu 12 Nov".
    static func day(_ d: Date, timeZone: TimeZone = .current) -> String {
        cache.string(d, format: "EEE d MMM", zone: timeZone)
    }

    /// "12 Nov 2026".
    static func date(_ d: Date, timeZone: TimeZone = .current) -> String {
        cache.string(d, format: "d MMM yyyy", zone: timeZone)
    }

    /// The counting sets of one day, compact: "Thu 12 Nov · 26×10 · 26×10 · 26×9".
    static func dayLine(_ start: Date, _ sets: [LoggedSet], _ kind: ExerciseKind, timeZone: TimeZone = .current) -> String {
        let parts = [day(start, timeZone: timeZone)] + sets.filter(\.counts).map { set($0, kind, .compact) }
        return parts.joined(separator: " · ")
    }

    static func ago(days: Int) -> String {
        switch days {
        case ...0: return "today"
        case 1: return "yesterday"
        default: return "\(days) days ago"
        }
    }

    static func minutes(_ start: Date, _ end: Date) -> String {
        "\(Int((end.timeIntervalSince(start) / 60).rounded())) min"
    }

    static func sets(_ n: Int) -> String { n == 1 ? "1 set" : "\(n) sets" }

    /// en_US grouping: "2,241".
    static func count(_ n: Int) -> String { cache.grouping(n) }

    /// "A", "A and B", "A, B and C".
    static func names(_ list: [String]) -> String {
        switch list.count {
        case 0: return ""
        case 1: return list[0]
        default: return list.dropLast().joined(separator: ", ") + " and " + list[list.count - 1]
        }
    }
}

enum WorkoutInput {
    private static func digits(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber } }

    /// Kilos (or extra weight, or help): 0...500.
    static func kg(_ text: String) -> Double? {
        guard let v = RecompInput.number(text), (0...500).contains(v) else { return nil }
        return v
    }

    /// A whole number 1...200.
    static func reps(_ text: String) -> Int? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard digits(s), s.count <= 3, let n = Int(s), (1...200).contains(n) else { return nil }
        return n
    }

    /// "45" or "1:30" (seconds under 60): 1...3600.
    static func seconds(_ text: String) -> Int? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = s.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let total: Int
        switch parts.count {
        case 1:
            guard digits(parts[0]), parts[0].count <= 5, let n = Int(parts[0]) else { return nil }
            total = n
        case 2:
            guard digits(parts[0]), digits(parts[1]), parts[0].count <= 3, parts[1].count <= 2,
                  let m = Int(parts[0]), let sec = Int(parts[1]), sec < 60 else { return nil }
            total = m * 60 + sec
        default:
            return nil
        }
        return (1...3600).contains(total) ? total : nil
    }
}
