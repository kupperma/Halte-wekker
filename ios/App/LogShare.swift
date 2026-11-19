import Foundation

// 0.28.1: Settings › Help improve Haltewekker › Share ride logs (off unless you turn it on). The matching and ride
// lines of the field log, scrubbed here first, go to the relay after a trip ends (and at most once an hour otherwise),
// grouped by a random install id that is not the Friends account. Plain values, so every rule can be tested.

/// What this phone knows that must never leave it in a shared line: the names of your places, people's names and
/// account ids. (Public stop and station names stay, unless one is the name of your Home or School.)
struct LogScrubKnown: Equatable, Sendable {
    var homes: [String] = []
    var schools: [String] = []
    var places: [String] = []
    var people: [String] = []
    var ids: [String] = []
}

enum LogScrub {
    /// A shorter name is never looked for (it would match inside the log's own words).
    static let minName = 3
    /// What a person's name becomes.
    static let person = "a friend"
    /// A line is cut to this many characters.
    static let maxLine = 2000
    /// Words of the log itself: a place or person with one of these names isn't looked for (it would rewrite the log
    /// and no line holds a name anyway).
    static let logWords: Set<String> = [
        "home", "school", "a place", "place", "a friend", "friend", "you", "bus", "train", "stop", "station", "start",
        "end", "ring", "wake", "arrive", "keep", "switch", "find", "choose", "detect", "board", "on board", "none", "live",
        "gps", "times", "timetable", "look", "tight", "cost", "wait", "refused", "same bus", "hand", "pick", "auto",
        "demo", "leg", "fast lane", "real position", "planned", "classic", "approach",
    ]

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // (the patterns are constants, and a name is escaped: a broken one is a bug the tests catch)
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    /// In this order: links, e-mail addresses, coordinates (a pair of numbers with 2 or more decimals, or one with 4 or
    /// more: no line of the log has more than 1), UUIDs, long hex (account and device ids are 32), long tokens.
    static let patterns: [(NSRegularExpression, String)] = [
        (regex(#"[A-Za-z][A-Za-z0-9+.-]*://\S+"#), "[link]"),
        (regex(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#), "[email]"),
        (regex(#"-?\d{1,3}[.,]\d{2,}\s*[,;/ ]\s*-?\d{1,3}[.,]\d{2,}"#), "[coord]"),
        (regex(#"-?\d{1,3}[.,]\d{4,}"#), "[coord]"),
        (regex(#"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#), "[id]"),
        (regex(#"(?<![0-9A-Za-z])[0-9A-Fa-f]{12,}(?![0-9A-Za-z])"#), "[id]"),
        (regex(#"(?<![0-9A-Za-z_-])(?=[A-Za-z0-9_-]*[0-9])(?=[A-Za-z0-9_-]*[A-Za-z])[A-Za-z0-9_-]{24,}(?![0-9A-Za-z_-])"#), "[id]"),
    ]

    /// The names to replace, longest first (so "Home Street 12" goes before "Home Street"), each once.
    static func names(_ k: LogScrubKnown) -> [(name: String, with: String)] {
        var out: [(name: String, with: String)] = []
        var seen = Set<String>()
        func add(_ list: [String], _ with: String) {
            for raw in list {
                let n = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = n.lowercased()
                guard n.count >= minName, !logWords.contains(key), seen.insert(key).inserted else { continue }
                out.append((n, with))
            }
        }
        add(k.homes, "Home")
        add(k.schools, "School")
        add(k.places, "a place")
        add(k.people, person)
        out.sort { a, b in a.name.count != b.name.count ? a.name.count > b.name.count : a.name < b.name }
        return out
    }

    /// One line as it may leave the phone.
    static func line(_ text: String, known: LogScrubKnown) -> String { LogScrubber(known).line(text) }
}

/// `LogScrub` with its names made ready once, for many lines.
struct LogScrubber {
    private let ids: [String]
    private let names: [(NSRegularExpression, String)]

    init(_ known: LogScrubKnown) {
        ids = known.ids.filter { $0.count >= 6 }
        names = LogScrub.names(known).map { (n: (name: String, with: String)) -> (NSRegularExpression, String) in
            let pattern = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: n.name) + #"(?![\p{L}\p{N}])"#
            // (people's names as written: "Max" goes, the log's own "max" stays; places in any case)
            let options: NSRegularExpression.Options = n.with == LogScrub.person ? [] : [.caseInsensitive]
            let re = try! NSRegularExpression(pattern: pattern, options: options)
            return (re, NSRegularExpression.escapedTemplate(for: n.with))
        }
    }

    private static func replace(_ re: NSRegularExpression, in t: String, with template: String) -> String {
        re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: template)
    }

    func line(_ text: String) -> String {
        var t = String(text.prefix(LogScrub.maxLine))
        for c in ["\r", "\n", "\t"] { t = t.replacingOccurrences(of: c, with: " ") }
        for id in ids { t = t.replacingOccurrences(of: id, with: "[id]", options: [.caseInsensitive]) }
        for (re, with) in LogScrub.patterns { t = Self.replace(re, in: t, with: with) }
        for (re, with) in names { t = Self.replace(re, in: t, with: with) }
        return t
    }
}

/// What goes in one upload: lines oldest first, and the newest one's time (where the next upload starts).
struct LogShareBatch: Equatable, Sendable {
    var lines: [String] = []
    var bytes = 0
    var through: Date?
    /// More new lines were left for the next upload (over the size for one).
    var more = false
}

/// When to send, how much, and what's kept between uploads.
enum LogShareRules {
    static let kinds: Set<FieldEntry.Kind> = [.match, .ride]
    static let perUpload = 200 * 1024
    static let perDay = 2 * 1024 * 1024
    /// Otherwise (not right after a trip) at most this often.
    static let every: TimeInterval = 3600
    /// Right after a trip: unless it tried this recently already.
    static let afterTripGap: TimeInterval = 60
    static let path = "/logs/v1/put"
    static let deletePath = "/logs/v1/delete"

    /// What the Settings screen shows when your own log has no line to show yet.
    static let sample = "2026-11-19 07:33:58 ride start · Home on board, by itself · bus 305·7821 · its stop 16630 m from you · leg 1/3"

    enum Trigger: Equatable, Sendable { case tripEnded, tick }

    /// "2026-11-19": the day the daily size counts on (your time zone).
    static func day(_ d: Date, timeZone: TimeZone = .current) -> String {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        let p = c.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", p.year ?? 0, p.month ?? 0, p.day ?? 0)
    }

    private static func clock(_ timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }

    private static func text(_ e: FieldEntry, _ scrub: LogScrubber, _ clock: DateFormatter) -> String {
        "\(clock.string(from: e.at)) \(e.kind.rawValue) \(scrub.line(e.text))"
    }

    /// "2026-11-19 07:33:58 ride <the scrubbed text>"
    static func text(_ e: FieldEntry, known: LogScrubKnown, timeZone: TimeZone = .current) -> String {
        text(e, LogScrubber(known), clock(timeZone))
    }

    /// The matching and ride lines after `after` (the field log is newest first), oldest first, while they fit in
    /// `budget` bytes (UTF-8, a newline between them).
    static func batch(_ entries: [FieldEntry], after: Date?, budget: Int, known: LogScrubKnown,
                      timeZone: TimeZone = .current) -> LogShareBatch {
        let fresh: [FieldEntry] = entries.filter { (e: FieldEntry) -> Bool in
            guard kinds.contains(e.kind) else { return false }
            guard let after else { return true }
            return e.at > after
        }.sorted { (a: FieldEntry, b: FieldEntry) -> Bool in a.at < b.at }
        let scrub = LogScrubber(known), f = clock(timeZone)
        let limit = max(0, budget)
        var b = LogShareBatch()
        for e in fresh {
            let line = text(e, scrub, f)
            let size = line.utf8.count + (b.lines.isEmpty ? 0 : 1)
            if b.bytes + size > limit { b.more = true; break }
            b.lines.append(line)
            b.bytes += size
            b.through = e.at
        }
        return b
    }

    /// The newest line of yours as it would be sent (for Settings), or nil when there's none yet.
    static func example(_ entries: [FieldEntry], known: LogScrubKnown, timeZone: TimeZone = .current) -> String? {
        guard let e = entries.first(where: { $0.kind == .ride }) ?? entries.first(where: { kinds.contains($0.kind) }) else { return nil }
        return text(e, known: known, timeZone: timeZone)
    }

    /// Bytes still allowed now: 200 KB, less near the day's 2 MB.
    static func budget(_ s: LogShareState, today: String) -> Int {
        let used = s.day == today ? s.sentToday : 0
        return max(0, min(perUpload, perDay - used))
    }

    /// Time to look for new lines and send them: on, no trip running, not in Low Power Mode, the day's 2 MB not used
    /// up, and the last try long enough ago (a minute after a trip, else an hour; a clock that stepped back doesn't hold it).
    static func due(_ s: LogShareState, enabled: Bool, trigger: Trigger, tripRunning: Bool, lowPower: Bool,
                    now: Date, today: String) -> Bool {
        guard enabled, !tripRunning, !lowPower, budget(s, today: today) > 0 else { return false }
        guard let last = s.lastTry else { return true }
        let age = now.timeIntervalSince(last)
        if age < 0 { return true }
        return age >= (trigger == .tripEnded ? afterTripGap : every)
    }

    /// After a try (sent or not).
    static func tried(_ s: LogShareState, now: Date) -> LogShareState {
        var n = s
        n.lastTry = now
        return n
    }

    /// After an upload the relay took.
    static func sent(_ s: LogShareState, _ b: LogShareBatch, now: Date, today: String) -> LogShareState {
        var n = s
        if n.day != today { n.day = today; n.sentToday = 0 }
        n.sentToday += b.bytes
        if let t = b.through { n.through = t }
        n.sentEver = true
        n.lastSent = now
        return n
    }
}

/// Kept between uploads: the install id and its secret (only this phone can delete what it sent), where the next
/// upload starts, and today's bytes.
struct LogShareState: Codable, Equatable, Sendable {
    /// 32 hex: groups this phone's uploads. Random, not the Friends account.
    var install: String
    /// 64 hex: the relay keeps its hash; a delete must bring it.
    var secret: String
    /// The newest line sent (or the moment sharing was turned on): only lines after it go.
    var through: Date?
    var lastTry: Date?
    var lastSent: Date?
    var day = ""
    var sentToday = 0
    /// Something went with this install id (so "Delete what I sent" has something to delete).
    var sentEver = false

    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    static func randomBytes(_ n: Int) -> [UInt8] {
        var g = SystemRandomNumberGenerator()
        return (0..<n).map { _ in UInt8.random(in: 0...255, using: &g) }
    }

    /// A new install id and secret; lines from `now` on.
    static func fresh(now: Date, random: (Int) -> [UInt8] = LogShareState.randomBytes) -> LogShareState {
        LogShareState(install: hex(random(16)), secret: hex(random(32)), through: now)
    }

    /// After "Delete what I sent": a new id and secret (what comes later isn't tied to what was deleted). Lines already
    /// sent aren't sent again; today's count stays.
    func rotated(random: (Int) -> [UInt8] = LogShareState.randomBytes) -> LogShareState {
        var n = self
        n.install = Self.hex(random(16))
        n.secret = Self.hex(random(32))
        n.sentEver = false
        n.lastSent = nil
        return n
    }

    /// Read back defensively: a broken or odd copy is none.
    static func decode(_ data: Data?) -> LogShareState? {
        guard let data, let s = try? JSONDecoder().decode(LogShareState.self, from: data) else { return nil }
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        guard s.install.count == 32, s.secret.count == 64,
              s.install.unicodeScalars.allSatisfy(hex.contains), s.secret.unicodeScalars.allSatisfy(hex.contains) else { return nil }
        return s
    }
}

/// The body of a put: what the relay is sent, and nothing else.
struct LogSharePut: Codable, Equatable, Sendable {
    var install: String
    var secret: String
    var app: String
    var lines: [String]
}

/// The body of a delete.
struct LogShareDelete: Codable, Equatable, Sendable {
    var install: String
    var secret: String
}

/// gzip around Apple's raw deflate (`NSData.compressed(using: .zlib)` gives RFC 1951 data, no header).
enum Gzip {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    private static func le(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    /// The gzip member: a 10-byte header, the deflate data, the CRC-32 and the size of the original.
    static func wrap(deflated: Data, original: Data) -> Data {
        var out = Data([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xFF])
        out.append(deflated)
        out.append(contentsOf: le(crc32(original)))
        out.append(contentsOf: le(UInt32(truncatingIfNeeded: original.count)))
        return out
    }

    /// nil: it couldn't be compressed (then it goes as it is).
    static func compress(_ data: Data) -> Data? {
        guard let deflated = try? (data as NSData).compressed(using: .zlib) else { return nil }
        return wrap(deflated: deflated as Data, original: data)
    }
}
