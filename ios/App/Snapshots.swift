import Foundation

/// A saved answer, and when it was the live one.
struct Snapshot<T: Codable>: Codable {
    let at: Date
    let value: T
}

/// The last answers, one JSON file per key in `<Caches>/answers`, to show at once after launch or a planning-key
/// change. A file that can't be read (corrupt, or an older format) is deleted and counts as nothing saved.
final class SnapshotStore: @unchecked Sendable {
    static let shared = SnapshotStore(directory: (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                                                    ?? FileManager.default.temporaryDirectory).appendingPathComponent("answers", isDirectory: true))

    private let directory: URL
    private let lock = NSLock()

    init(directory: URL) { self.directory = directory }

    /// Saves `value` as the answer for `key`, as of `at`: the whole file or nothing (it's written aside, then moved).
    func save<T: Codable>(_ value: T, key: String, at: Date = Date()) {
        guard let data = try? JSONEncoder().encode(Snapshot(at: at, value: value)) else { return }
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file(key), options: .atomic)
    }

    /// The answer saved for `key`, if it's at most `maxAge` old. One that can't be read is deleted (nil).
    func load<T: Codable>(_ type: T.Type, key: String, maxAge: TimeInterval = 12 * 3600, now: Date = Date()) -> Snapshot<T>? {
        let url = file(key)
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let s = try? JSONDecoder().decode(Snapshot<T>.self, from: data) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        let age = now.timeIntervalSince(s.at)
        return age <= maxAge && age >= -60 ? s : nil            // (a minute ahead: the clock was set back a little)
    }

    /// The file for a key: anything outside [A-Za-z0-9._-] becomes "_", at most 120 characters, then ".json".
    static func fileName(_ key: String) -> String {
        let ok = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        return String(key.map { ok.contains($0) ? $0 : "_" }.prefix(120)) + ".json"
    }

    private func file(_ key: String) -> URL { directory.appendingPathComponent(Self.fileName(key)) }
}

/// The planning key: the direction, where you're going (a stop you picked, or "" for school or home), and whether
/// trips start from where you are or from your usual start.
struct PlanKey: Equatable, Sendable {
    let dir: String
    let dest: String
    let fromHere: Bool
    /// "toSchool||usual", "home|<stop id>|here"
    var text: String { "\(dir)|\(dest)|\(fromHere ? "here" : "usual")" }
}

/// What the lists do when the planning key changes.
enum KeyChange: Equatable, Sendable {
    case showSaved      // the new key's saved answer
    case keep           // only the start changed: the lists stay, marked "as of"
    case clear          // another direction or destination, and nothing saved: "Loading…"
}

enum Snapshots {
    /// What hasn't left yet (or left at most `grace` ago).
    static func upcoming<E>(_ items: [E], now: Date, grace: TimeInterval = 60, time: (E) -> Date) -> [E] {
        items.filter { time($0) > now.addingTimeInterval(-grace) }
    }

    /// "as of 08:12" (24-hour clock).
    static func asOf(_ at: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "HH:mm"
        return "as of \(f.string(from: at))"
    }

    /// The new key's saved answer if there is one; else, when only the start changed (usual ⇄ here, same direction and
    /// destination), the lists stay; else they answer another question and go.
    static func onKeyChange(from old: PlanKey?, to new: PlanKey, hasSaved: Bool) -> KeyChange {
        if hasSaved { return .showSaved }
        if let old, old.dir == new.dir, old.dest == new.dest { return .keep }
        return .clear
    }

    /// A saved answer asked from `saved` (nil: from your usual start, good anywhere) is used within `metres` of `here`.
    static func closeEnough(saved: (lat: Double, lon: Double)?, here: (lat: Double, lon: Double)?, metres: Double) -> Bool {
        guard let saved else { return true }
        guard let here else { return false }
        let kx = cos(saved.lat * .pi / 180) * 111_320, ky = 110_540.0
        let dx = (here.lon - saved.lon) * kx, dy = (here.lat - saved.lat) * ky
        return (dx * dx + dy * dy).squareRoot() <= metres
    }
}

/// Which lists show a live answer for the current planning key. The others show a saved answer, one kept from another
/// key, or nothing: the first live rows may replace those, while a live list waits for the whole answer (so it never
/// drops to one station's rows).
struct LiveLists<L: Hashable> {
    private var live: Set<L> = []

    init() {}

    /// The planning key changed: nothing shown is live for the new one.
    mutating func reset() { live = [] }
    /// `list` now shows a live answer for this key.
    mutating func shown(_ list: L) { live.insert(list) }
    func isLive(_ list: L) -> Bool { live.contains(list) }
    /// May a partial answer replace what `list` shows (`empty`: it shows nothing)?
    func takesPartial(_ list: L, empty: Bool) -> Bool { empty || !live.contains(list) }
    /// Some of these lists (the ones that show something) still show what isn't live, so they need their "as of".
    func anyStale(_ withContent: [L]) -> Bool { withContent.contains { !live.contains($0) } }
}
