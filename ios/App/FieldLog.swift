import Foundation

/// One line of the field log: a request or a matching look.
struct FieldEntry: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case net, match }
    let at: Date
    let kind: Kind
    let text: String
}

/// The last requests and vehicle choices, newest first, kept on this phone. Holds paths, lanes, statuses, sizes, seconds,
/// attempts, lines and the last 4 characters of trip ids: never coordinates or query strings.
final class FieldLog: @unchecked Sendable {
    static let shared = FieldLog(defaults: .standard)

    private let defaults: UserDefaults
    private let key: String
    private let limit: Int
    private let lock = NSLock()
    private var list: [FieldEntry]
    private var dirty = false
    private var pending = false

    init(defaults: UserDefaults, key: String = "fieldLog.v1", limit: Int = 400) {
        self.defaults = defaults
        self.key = key
        self.limit = limit
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode([FieldEntry].self, from: data) {
            list = Array(saved.prefix(limit))
        } else {
            list = []
        }
    }

    /// Newest first. Written to disk at most every 5 s (and by `flush`).
    func add(_ kind: FieldEntry.Kind, _ text: String, at: Date = Date()) {
        lock.lock()
        list.insert(FieldEntry(at: at, kind: kind, text: text), at: 0)
        if list.count > limit { list.removeLast(list.count - limit) }
        dirty = true
        let schedule = !pending
        pending = true
        lock.unlock()
        if schedule {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [weak self] in self?.flush() }
        }
    }

    func flush() {
        lock.lock()
        pending = false
        guard dirty else { lock.unlock(); return }
        dirty = false
        let data = try? JSONEncoder().encode(list)
        lock.unlock()
        if let data { defaults.set(data, forKey: key) }
    }

    var entries: [FieldEntry] {
        lock.lock(); defer { lock.unlock() }
        return list
    }

    func clear() {
        lock.lock()
        list = []
        dirty = true
        lock.unlock()
    }

    /// A line per entry, newest first: "08:12:03 net <text>".
    func export(timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "HH:mm:ss"
        return entries.map { "\(f.string(from: $0.at)) \($0.kind.rawValue) \($0.text)" }.joined(separator: "\n")
    }
}

/// The wording of the log's lines. Nothing here takes a coordinate or a query.
enum FieldFormat {
    static func net(_ path: String, lane: Lane, status: Int?, error: URLError.Code?, bytes: Int, seconds: Double, attempts: Int) -> String {
        let bare = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? path
        let result: String
        if let error {
            switch error {
            case .timedOut: result = "timed out"
            case .notConnectedToInternet: result = "offline"
            case .networkConnectionLost: result = "connection lost"
            case .cancelled: result = "cancelled"
            default: result = "error \(error.rawValue)"
            }
        } else {
            result = status.map(String.init) ?? "no answer"
        }
        let size = bytes < 1024 ? "\(max(0, bytes)) B" : String(format: "%.1f KB", Double(bytes) / 1024)
        return "\(bare) · \(result) · \(size) · \(String(format: "%.1f", seconds)) s · \(attempts) \(attempts == 1 ? "try" : "tries") · \(lane.rawValue)"
    }

    /// "306·a1b2": the line, "·", the last 4 characters of the trip id.
    static func label(_ id: String, _ lines: [String: String]) -> String {
        "\(lines[id] ?? "?")·\(id.suffix(4))"
    }

    static func reject(_ r: Reject, _ e: Evidence?) -> String {
        func n(_ x: Double?) -> String { x.map { String(Int($0.rounded())) } ?? "?" }
        switch r {
        case .tooFewFixes: return "too few fixes"
        case .offItsPath: return e.map { "off its path \(n($0.crossTrack)) m" } ?? "off its path"
        case .wrongWay: return "going the other way"
        case .implausibleSpeed: return "wrong speed (you \(n(e?.yourSpeed)) m/s, it \(n(e?.itsSpeed)))"
        case .standing: return "standing by its times"
        case .drifting: return e.map { "drifting \(n(abs($0.drift))) m/s" } ?? "drifting"
        case .tooFarFromTimes: return e.map { "\(n(abs($0.offset))) m from its times" } ?? "far from its times"
        case .noTimes: return "no times now"
        }
    }

    /// "detect · IC·a1b2 live 30 s | 306·c3d4 timetable off its path 180 m → keep IC·a1b2": the ones that passed first
    /// (by cost), then the rejected; at most 6.
    static func match(_ place: String, _ judged: [Judgement], outcome: String) -> String {
        func label(_ j: Judgement) -> String { "\(j.line)·\(j.id.suffix(4))" }
        func kind(_ j: Judgement) -> String { j.realTime ? "live" : "timetable" }
        var passed: [(Double, String)] = [], rejected: [String] = []
        for j in judged {
            switch j.result {
            case .success(let c): passed.append((c, "\(label(j)) \(kind(j)) \(Int(c.rounded())) s"))
            case .failure(let r): rejected.append("\(label(j)) \(kind(j)) \(reject(r, j.evidence))")
            }
        }
        let items = (passed.sorted { $0.0 < $1.0 }.map(\.1) + rejected).prefix(6)
        return "\(place) · \(items.isEmpty ? "no vehicles" : items.joined(separator: " | ")) → \(outcome)"
    }

    static func outcome(_ d: Decision, lines: [String: String]) -> String {
        switch d {
        case .keep(let id): return "keep \(label(id, lines))"
        case .switchTo(let id): return "switch to \(label(id, lines))"
        case .undecided(let ids): return "undecided: " + ids.map { label($0, lines) }.joined(separator: ", ")
        case .none: return "none"
        }
    }

    /// "detect · not sure (4 fixes, 12 s)": the matcher had too few fixes to judge by (of the last half minute).
    static func notSure(_ place: String, fixes: Int, span: TimeInterval) -> String {
        "\(place) · not sure (\(fixes) \(fixes == 1 ? "fix" : "fixes"), \(Int(max(0, span).rounded())) s)"
    }

    static func classic(_ place: String, _ found: [(label: String, metres: Double)]) -> String {
        "\(place) (classic) · " + (found.isEmpty ? "none" : found.prefix(6).map { "\($0.label) \(Int($0.metres.rounded())) m" }.joined(separator: " | "))
    }
}

/// The Settings switch that brings back the way the app chose buses and trains before the new matcher.
enum MatchSettings {
    static let key = "classicMatching"
    static func classic(_ d: UserDefaults = .standard) -> Bool { d.bool(forKey: key) }
}
