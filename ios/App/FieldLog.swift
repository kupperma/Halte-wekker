import Foundation

/// One line of the field log: a request, a matching look, or what a ride did (started, refused, woke, rang, arrived).
struct FieldEntry: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable, CaseIterable { case net, match, ride }
    let at: Date
    let kind: Kind
    let text: String
}

/// The last requests, vehicle choices and ride events, newest first, kept on this phone. Holds paths, lanes, statuses,
/// sizes, seconds, attempts, lines, metres rounded to 10 and the last 4 characters of trip ids: never coordinates, place
/// names or query strings.
final class FieldLog: @unchecked Sendable {
    /// In a small file in Application Support (written at most every 30 s, and when the app goes to the background),
    /// not in the app's settings: those are read whole at every launch and were written whole every 5 s.
    static let shared = FieldLog(file: FieldLog.appFile, migrating: (defaults: UserDefaults.standard, key: "fieldLog.v1"))
    /// The newest this many of each kind are kept, so a burst of requests can't push a ride out of the log.
    static let caps: [FieldEntry.Kind: Int] = [.net: 300, .match: 200, .ride: 100]

    static var appFile: URL {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("fieldlog.json")
    }

    private let load: () -> Data?
    private let store: (Data) -> Void
    private let every: TimeInterval                  // written at most this often (and by `flush`)
    private let limit: Int?                          // one cap for all kinds together (else `caps` per kind)
    private let kindCaps: [FieldEntry.Kind: Int]
    private let lock = NSLock()
    private let writing = NSLock()                   // one write at a time, in order (without holding up `add`)
    private var list: [FieldEntry]
    private var dirty = false
    private var pending = false

    /// The newest `limit` entries, whatever their kind.
    convenience init(defaults: UserDefaults, key: String = "fieldLog.v1", limit: Int) {
        self.init(load: { defaults.data(forKey: key) }, store: { defaults.set($0, forKey: key) }, every: 5, limit: limit, caps: [:])
    }

    /// The newest of each kind, up to its cap.
    convenience init(defaults: UserDefaults, key: String = "fieldLog.v1", caps: [FieldEntry.Kind: Int] = FieldLog.caps) {
        self.init(load: { defaults.data(forKey: key) }, store: { defaults.set($0, forKey: key) }, every: 5, limit: nil, caps: caps)
    }

    /// In a file, written at most every `every` seconds. `migrating`: where an older version kept it (read once when
    /// there's no file yet, written to the file, and only then removed there).
    convenience init(file: URL, every: TimeInterval = 30, caps: [FieldEntry.Kind: Int] = FieldLog.caps,
                     migrating old: (defaults: UserDefaults, key: String)? = nil) {
        self.init(load: {
            if let d = try? Data(contentsOf: file) { return d }
            guard let old, let d = old.defaults.data(forKey: old.key) else { return nil }
            if (try? d.write(to: file, options: .atomic)) != nil { old.defaults.removeObject(forKey: old.key) }
            return d
        }, store: { try? $0.write(to: file, options: .atomic) }, every: every, limit: nil, caps: caps)
    }

    private init(load: @escaping () -> Data?, store: @escaping (Data) -> Void, every: TimeInterval, limit: Int?, caps: [FieldEntry.Kind: Int]) {
        self.load = load
        self.store = store
        self.every = every
        self.limit = limit
        self.kindCaps = caps
        if let data = load(), let saved = try? JSONDecoder().decode([FieldEntry].self, from: data) {
            list = FieldLog.pruned(saved, limit: limit, caps: caps)
        } else {
            list = []
        }
    }

    /// Newest first, the oldest of a kind dropped once it's over its cap (or the oldest of all over `limit`).
    static func pruned(_ list: [FieldEntry], limit: Int?, caps: [FieldEntry.Kind: Int]) -> [FieldEntry] {
        if let limit { return Array(list.prefix(max(0, limit))) }
        var seen: [FieldEntry.Kind: Int] = [:]
        return list.filter { e in
            seen[e.kind, default: 0] += 1
            return seen[e.kind]! <= (caps[e.kind] ?? 100)
        }
    }

    /// Newest first. Written to disk at most every `every` seconds (and by `flush`).
    func add(_ kind: FieldEntry.Kind, _ text: String, at: Date = Date()) {
        lock.lock()
        list.insert(FieldEntry(at: at, kind: kind, text: text), at: 0)
        if let limit {
            if list.count > limit { list.removeLast(list.count - limit) }
        } else if list.lazy.filter({ $0.kind == kind }).count > (kindCaps[kind] ?? 100), let i = list.lastIndex(where: { $0.kind == kind }) {
            list.remove(at: i)
        }
        dirty = true
        let schedule = !pending
        pending = true
        lock.unlock()
        if schedule {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + every) { [weak self] in self?.flush() }
        }
    }

    /// Writes are one at a time, each taking the list as it is once it's its turn, so an older copy can never land
    /// after a newer one. (`add` meanwhile only waits for the copy, not for the write.)
    func flush() {
        do {
            writing.lock()
            defer { writing.unlock() }
            lock.lock()
            pending = false
            if dirty {
                dirty = false
                let snapshot = list
                lock.unlock()
                if let data = try? JSONEncoder().encode(snapshot) { store(data) }
            } else {
                lock.unlock()
            }
        }
        alsoFlush?()
    }

    /// Written with it (0.20.7: the battery and data log, at the same moments: the app going to the background, a
    /// ride's end, and after each burst of lines). Set once at launch.
    var alsoFlush: (@Sendable () -> Void)?

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
    /// `note`: what else to say, at the end ("shared": another caller's request answered it). A request that was never
    /// sent has only the note as its result ("cooling down").
    static func net(_ path: String, lane: Lane, status: Int?, error: URLError.Code?, bytes: Int, seconds: Double, attempts: Int,
                    note: String? = nil) -> String {
        let bare = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? path
        let result: String
        var tail = note.map { " · \($0)" } ?? ""
        if let error {
            switch error {
            case .timedOut: result = "timed out"
            case .notConnectedToInternet: result = "offline"
            case .networkConnectionLost: result = "connection lost"
            case .cancelled: result = "cancelled"
            default: result = "error \(error.rawValue)"
            }
        } else if let status {
            result = String(status)
        } else if let note {
            result = note; tail = ""
        } else {
            result = "no answer"
        }
        let size = bytes < 1024 ? "\(max(0, bytes)) B" : String(format: "%.1f KB", Double(bytes) / 1024)
        return "\(bare) · \(result) · \(size) · \(String(format: "%.1f", seconds)) s · \(attempts) \(attempts == 1 ? "try" : "tries") · \(lane.rawValue)\(tail)"
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

    /// "detect · n=9 · IC·a1b2 live 30 s | 306·c3d4 timetable off its path 180 m → keep IC·a1b2" ("305·4779 gps 12 s": judged
    /// by its own GPS fix): the ones that passed
    /// first (by cost), then the rejected, nearest their path first (so the one you're on isn't hidden behind long-distance
    /// trains and coaches whose paths cross the area); at most 6. `planned` (the planned, picked or shown one) is always
    /// there, marked "(planned)" (beyond the 6 too), or "planned ·a1b2 not in answer" ("… excluded" when it was in the
    /// answer but left out before judging: one already ruled out, or the other kind). `count`: how many were judged.
    static func match(_ place: String, _ judged: [Judgement], outcome: String, planned: String? = nil, count: Int? = nil,
                      plannedExcluded: Bool = false) -> String {
        func label(_ j: Judgement) -> String { "\(j.line)·\(j.id.suffix(4))" + (planned != nil && j.id == planned ? " (planned)" : "") }
        // (judged by its own GPS fix: "gps", else by its live times or its timetable)
        func kind(_ j: Judgement) -> String { j.evidence?.gps == true ? "gps" : j.realTime ? "live" : "timetable" }
        var passed: [(cost: Double, id: String, text: String)] = []
        var rejected: [(near: Double, id: String, text: String)] = []
        for j in judged {
            switch j.result {
            case .success(let c): passed.append((c, j.id, "\(label(j)) \(kind(j)) \(Int(c.rounded())) s"))
            case .failure(let r):
                // off its path by how far; not sure yet (no evidence) after those; dropped by the quick box test last
                let near = j.evidence.map { $0.crossTrack.isFinite ? $0.crossTrack : 1e8 } ?? (r.notSure ? 1e8 : 1e9)
                rejected.append((near, j.id, "\(label(j)) \(kind(j)) \(reject(r, j.evidence))"))
            }
        }
        let ordered = passed.sorted { $0.cost < $1.cost }.map { (id: $0.id, text: $0.text) }
            + rejected.enumerated().sorted { $0.element.near != $1.element.near ? $0.element.near < $1.element.near : $0.offset < $1.offset }
                .map { (id: $0.element.id, text: $0.element.text) }
        var items = Array(ordered.prefix(6)).map(\.text)
        if let planned {
            if let p = ordered.dropFirst(6).first(where: { $0.id == planned }) { items.append(p.text) }
            else if !judged.contains(where: { $0.id == planned }) {
                items.append("planned ·\(planned.suffix(4)) \(plannedExcluded ? "excluded" : "not in answer")")
            }
        }
        let n = count.map { "n=\($0) · " } ?? ""
        return "\(place) · \(n)\(items.isEmpty ? "no vehicles" : items.joined(separator: " | ")) → \(outcome)"
    }

    /// `choosing`: what was found is only chosen between (it switches later, if at all): "choose" for the clear best.
    static func outcome(_ d: Decision, lines: [String: String], choosing: Bool = false) -> String {
        switch d {
        case .keep(let id): return "keep \(label(id, lines))"
        case .switchTo(let id): return "\(choosing ? "choose" : "switch to") \(label(id, lines))"
        case .undecided(let ids): return "undecided: " + ids.map { label($0, lines) }.joined(separator: ", ")
        case .none: return "none"
        }
    }

    /// One look while choosing: what it decided, or, sure after 12 minutes, the one it settles on (which can be another
    /// than the one shown while the decision says keep).
    static func outcome(_ c: ChoiceLook, shown: String?, lines: [String: String]) -> String {
        if c.why == .timedOut, let id = c.settle { return "\(id == shown ? "keep" : "switch to") \(label(id, lines))" }
        return outcome(c.decision, lines: lines)
    }

    /// "detect · not sure (4 fixes, 12 s)": the matcher had too few fixes to judge by (of the last half minute).
    static func notSure(_ place: String, fixes: Int, span: TimeInterval) -> String {
        "\(place) · not sure (\(fixes) \(fixes == 1 ? "fix" : "fixes"), \(Int(max(0, span).rounded())) s)"
    }

    /// "board · fast lane · 305·4779 · GPS 120 m from you, 40 s old · 2 fixes, 9 s · you 24 m/s": the fast lane took it
    /// (`MatchRules.fastLane`). Metres rounded to 10; the trip id by its last 4 characters.
    static func fastLane(_ place: String, label: String, metres: Double?, gpsAge: TimeInterval?, fixes: Int, span: TimeInterval,
                         speed: Double) -> String {
        "\(place) · fast lane · \(label) · GPS \(Self.metres(metres)) from you\(age(gpsAge)) · \(fixes) \(fixes == 1 ? "fix" : "fixes"), "
            + "\(Int(max(0, span).rounded())) s · you \(Int(max(0, speed.isFinite ? speed : 0).rounded())) m/s"
    }

    /// "same bus · kept by GPS · 305·4779 · 120 m from you, 40 s old (drifting 8 m/s)": its own GPS kept the ride's one
    /// where its judging alone would not have (`VehicleMatch.gpsKeeps`); `instead`: what that said.
    static func keptByGPS(label: String, metres: Double?, gpsAge: TimeInterval?, instead: String) -> String {
        "same bus · kept by GPS · \(label) · \(Self.metres(metres)) from you\(age(gpsAge))\(instead.isEmpty ? "" : " (\(instead))")"
    }

    private static func age(_ a: TimeInterval?) -> String {
        guard let a, a.isFinite else { return "" }
        return ", \(Int(max(0, a).rounded())) s old"
    }

    static func classic(_ place: String, _ found: [(label: String, metres: Double)]) -> String {
        "\(place) (classic) · " + (found.isEmpty ? "none" : found.prefix(6).map { "\($0.label) \(Int($0.metres.rounded())) m" }.joined(separator: " | "))
    }

    // MARK: ride lines: how a ride started, what it refused, when it woke you, rang and arrived

    /// Metres rounded to 10: "180 m"; "? m" when not known.
    static func metres(_ m: Double?) -> String {
        guard let m, m.isFinite else { return "? m" }
        return "\(Int((min(max(0, m), 1e7) / 10).rounded()) * 10) m"
    }

    /// "bus 321·1280", "train IC·a1b2": the kind, the line, the last 4 characters of the trip id.
    static func vehicle(line: String, tripId: String, isTrain: Bool) -> String {
        "\(isTrain ? "train" : "bus") \(line)·\(tripId.suffix(4))"
    }

    /// "start · replan at a change · bus 321·1280 · its stop 180 m from you · leg 1/3". `how`: hand, Go board, Go hand,
    /// auto (station left), next leg, replan at a change, replan on board, wrong way, switch, demo.
    static func rideStart(how: String, vehicle: String?, stopMetres: Double?, leg: Int, of legs: Int) -> String {
        "start · \(how) · \(vehicle ?? "no vehicle yet") · its stop \(metres(stopMetres)) from you · leg \(leg)/\(legs)"
    }

    /// "refused · replan onto bus 406·4068: its stop 120 m from you (±20)"
    static func rideRefused(_ what: String, vehicle: String, stopMetres: Double?, accuracy: Double?) -> String {
        "refused · \(what) \(vehicle): its stop \(metres(stopMetres)) from you\(accuracy.map { $0 >= 0 && $0.isFinite ? " (±\(Int($0.rounded())))" : "" } ?? "")"
    }

    /// "wait · at a change: not going yet (30 m in 30 s, 90 m from the stop)"
    static func rideWait(moved: Double?, fromStop: Double?) -> String {
        "wait · at a change: not going yet (\(moved.map { "\(metres($0)) in 30 s" } ?? "too few fixes"), \(metres(fromStop)) from the stop)"
    }

    /// "wake · silently (started 1940 m from its stop)": a leg that started inside its wake distance.
    static func rideWake(startedMetres: Double?, after: TimeInterval? = nil) -> String {
        "wake · silently (started \(metres(startedMetres)) from its stop\(after.map { ", first fix \(Int(max(0, $0).rounded())) s in" } ?? ""))"
    }

    /// "ring · approach · 1600 m · leg 25 s old · started 1940 m"
    static func rideRing(_ why: String, metres m: Double?, legAge: TimeInterval, started: Double?) -> String {
        "ring · \(why) · \(metres(m)) · leg \(Int(max(0, legAge).rounded())) s old · started \(metres(started))"
    }

    /// "arrive · by GPS · 230 m (±15) · leg 12 s old · started 180 m"
    static func rideArrive(why: String, metres m: Double?, accuracy: Double?, legAge: TimeInterval, started: Double?) -> String {
        let acc = accuracy.map { $0 >= 0 && $0.isFinite ? " (±\(Int($0.rounded())))" : "" } ?? ""
        return "arrive · \(why) · \(metres(m))\(acc) · leg \(Int(max(0, legAge).rounded())) s old · started \(metres(started))"
    }

    /// "end · 10 min after the last stop": the trip ended by itself.
    static func rideEnd(_ why: String) -> String { "end · \(why)" }

    /// "tight · bus 306·a1b2 C-rank · 4 min to change": a slow bus with a change ahead that has too little room.
    static func rideTight(_ vehicle: String, grade: String, minutes: Double) -> String {
        "tight · \(vehicle) \(grade)-rank · \(minutes.isFinite ? Int(minutes.rounded()) : 0) min to change"
    }

    /// "pick kept · train IC·a1b2: 40 m from its road", or "… its road not known": the one picked or planned holds
    /// against another that doesn't go where the leg goes.
    static func pickKept(_ vehicle: String, metres m: Double?) -> String {
        "pick kept · \(vehicle): " + (m.map { $0.isFinite ? "\(metres($0)) from its road" : "its road not known" } ?? "its road not known")
    }

    // MARK: picked by hand during a ride (0.20.5, the "I'm actually on…" sheet)

    /// "hand pick · bus 306·4942 (was 305·4779) · 120 m · gps": you said in the ride which one you're on; `was` the one it
    /// had ("306·4942": the line and the trip id's last 4 characters; nil: none), how far it was from you and by what
    /// (`byGPS`: its own fix, else its times; nil: not known). `vehicle` nil: "none of these", by your location.
    static func handPick(_ vehicle: String?, was: String?, metres m: Double?, byGPS: Bool?) -> String {
        let before = "(was \(was ?? "none"))"
        guard let vehicle else { return "hand pick · none of these: by your location \(before)" }
        let how = byGPS.map { $0 ? " · gps" : " · times" } ?? ""
        return "hand pick · \(vehicle) \(before) · \(metres(m))\(how)"
    }

    /// "hand pick · asked: still on bus 306·4942? · off its road 3 min · 420 m": the one you picked, off its road a while.
    static func stillOnAsked(_ vehicle: String, offFor: TimeInterval, metres m: Double?) -> String {
        let minutes = offFor.isFinite ? Int((max(0, offFor) / 60).rounded()) : 0
        return "hand pick · asked: still on \(vehicle)? · off its road \(minutes) min · \(metres(m))"
    }

    /// "hand pick · still on bus 306·4942: yes", "…: pick again", "… (from the notification)".
    static func stillOnAnswered(_ vehicle: String, yes: Bool, fromNotification: Bool = false) -> String {
        "hand pick · still on \(vehicle): \(yes ? "yes" : "pick again")\(fromNotification ? " (from the notification)" : "")"
    }
}

/// The Settings switch that brings back the way the app chose buses and trains before the new matcher.
enum MatchSettings {
    static let key = "classicMatching"
    static func classic(_ d: UserDefaults = .standard) -> Bool { d.bool(forKey: key) }
}
