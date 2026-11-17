import Foundation

/// Where to stand to catch a ride, said the way it's signed there (0.20.4, the "Go to" card): "Platform 5" for a
/// train, "Stop U" or "Stop B1" for a bus or tram stop with a letter, else the stop's own name. And the words around it:
/// which one you take, how late, the walk, and the one sentence VoiceOver reads.
///
/// Where the letters come from: the planner's `track` (live) and `scheduledTrack` (planned) on the stop you board at
/// (a train's platform; at a bus station the stop's letter or code, "U", "B1"), NS's actual and planned track for a
/// train, and, when a bus stop has no track, a letter some stop names carry ("Eindhoven, Station perron E2").
enum StopLabel {
    enum Kind: Equatable { case train, tram, bus }

    /// A train, a tram (or metro: its line is a number) or a bus. (The planner calls everything that isn't a bus or a
    /// coach a train: a tram's line is "1", a train's "IC", "SPR".)
    static func kind(isTrain: Bool, line: String) -> Kind {
        guard isTrain else { return .bus }
        let l = line.trimmingCharacters(in: .whitespaces)
        return !l.isEmpty && l.allSatisfy(\.isNumber) ? .tram : .train
    }

    struct Where: Equatable {
        let kind: Kind
        /// The platform ("5", "14b") or the stop's letter or code ("U", "B1"), when it's known.
        let code: String?
        /// The station or stop: "Eindhoven Centraal", "Breda, Centraal Station" (without a letter that came in its name).
        let place: String
        /// Not where it was planned to leave from.
        let changed: Bool
        /// The planned one, when it changed.
        let was: String?

        /// "Platform", "Stop"
        var word: String { kind == .train ? "Platform" : "Stop" }
        /// The big words: "Platform 5", "Stop U", or the stop's name.
        var big: String { chip ?? place }
        /// Under the big words: the station or stop (nothing when the big words are its name).
        var under: String? { code == nil ? nil : place }
        /// On the timeline, by the stop: "Platform 5", "Stop U" (nothing when it isn't known).
        var chip: String? { code.map { "\(word) \($0)" } }
        /// "Platform changed to 5 (was 4)"
        var changeNote: String? {
            guard changed, let c = code else { return nil }
            return "\(word) changed to \(c)" + (was.map { " (was \($0))" } ?? "")
        }
        /// A train whose platform isn't out yet.
        var unknownNote: String? { kind == .train && code == nil ? "Platform not known yet" : nil }
    }

    /// Where to go. `track` and `planned`: the live and the planned platform or stop letter (NS's for a train when it
    /// has them, else the planner's), `stop` the stop's name as the planner gives it.
    static func make(kind: Kind, stop: String, track: String?, planned: String?) -> Where {
        let now = clean(track), plan = clean(planned)
        let place = stop.trimmingCharacters(in: .whitespaces)
        if kind == .train {
            let code = (now ?? plan).flatMap { $0.count <= 6 ? $0 : nil }
            let changed = code != nil && now != nil && plan != nil && now!.lowercased() != plan!.lowercased()
            return Where(kind: kind, code: code, place: place, changed: changed, was: changed ? plan : nil)
        }
        // a bus or tram: a short code from the track; else a letter in the stop's name
        if let c = now ?? plan, isCode(c, strict: false) {
            let changed = now != nil && plan != nil && isCode(plan!, strict: false) && now!.lowercased() != plan!.lowercased()
            return Where(kind: kind, code: c, place: place, changed: changed, was: changed ? plan : nil)
        }
        if let n = fromName(place) { return Where(kind: kind, code: n.code, place: n.place, changed: false, was: nil) }
        return Where(kind: kind, code: nil, place: place, changed: false, was: nil)
    }

    /// "Perron 5" → "5", " U " → "U", "" → nil.
    static func clean(_ s: String?) -> String? {
        guard var t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        let l = t.lowercased()
        for w in words where l.hasPrefix(w + " ") {
            t = String(t.dropFirst(w.count + 1)).trimmingCharacters(in: .whitespaces)
            break
        }
        return t.isEmpty ? nil : t
    }

    /// The words a stop's letter comes after: "perron U", "platform 2", "spoor 3", "bay 4", "stand B".
    private static let words = ["perron", "platform", "spoor", "track", "bay", "stand"]

    /// A stop's code: one to three letters or digits ("U", "B1", "12"). `strict` (one in brackets in a name, which
    /// may as well be a province, "Oosterhout (NB)"): one character, or a letter with digits, or digits only.
    static func isCode(_ c: String, strict: Bool) -> Bool {
        guard (1...3).contains(c.count), c.allSatisfy({ $0.isLetter || $0.isNumber }), c.allSatisfy(\.isASCII) else { return false }
        guard strict, c.count > 1 else { return true }
        let rest = c.dropFirst()
        return rest.allSatisfy(\.isNumber)
    }

    /// A stop's letter at the end of its name: "Eindhoven, Station perron E2" → ("Eindhoven, Station", "E2");
    /// "Tilburg, Centraal Station (perron D)"; "Breda, Centraal Station (U)". Nil when there's none.
    static func fromName(_ name: String) -> (place: String, code: String)? {
        var n = name.trimmingCharacters(in: .whitespaces)
        var bracket = false
        if n.hasSuffix(")"), let open = n.lastIndex(of: "(") {
            let inside = String(n[n.index(after: open)..<n.index(before: n.endIndex)]).trimmingCharacters(in: .whitespaces)
            let head = String(n[..<open]).trimmingCharacters(in: .whitespaces)
            if let c = clean(inside), c != inside, isCode(c, strict: false), !head.isEmpty { return (trimTail(head), c) }
            if isCode(inside, strict: true), !head.isEmpty { return (trimTail(head), inside) }
            bracket = true
        }
        guard !bracket else { return nil }
        // "… perron E2", "…, perron E2", "… - perron E2"
        let parts = n.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 3 else { return nil }
        let code = parts[parts.count - 1], word = parts[parts.count - 2].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",-"))
        guard words.contains(word), isCode(code, strict: false) else { return nil }
        n = parts.dropLast(2).joined(separator: " ")
        let place = trimTail(n)
        return place.isEmpty ? nil : (place, code)
    }

    private static func trimTail(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: " ,-–"))
    }

    // MARK: which one you take

    /// "Intercity", "Sprinter", "Bus 305", "Tram 1". `name` the planner's (for a train "Intercity", or "IC").
    static func vehicle(kind: Kind, line: String, name: String) -> String {
        switch kind {
        case .bus: return "Bus \(line)"
        case .tram: return "Tram \(line)"
        case .train:
            let n = name.trimmingCharacters(in: .whitespaces), l = n.lowercased()
            if l.contains("intercity direct") || l == "icd" { return "Intercity direct" }
            if l.contains("intercity") || l == "ic" { return "Intercity" }
            if l.contains("sprinter") || l == "spr" { return "Sprinter" }
            if n.isEmpty { return line.isEmpty ? "Train" : line }
            return n
        }
    }

    /// "Bus 305 to Veghel", "Intercity to Den Haag Centraal"; `toward` its headsign (or where you get off).
    static func ride(_ vehicle: String, toward: String) -> String {
        let t = toward.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? vehicle : "\(vehicle) to \(t)"
    }

    /// How late: "+3 min", "2 min early", "on time", "Cancelled"; nil without live times. `spoken` for VoiceOver.
    static func delay(_ minutes: Int, live: Bool, cancelled: Bool) -> (text: String, spoken: String, warn: Bool)? {
        if cancelled { return ("Cancelled", "cancelled", true) }
        guard live else { return nil }
        if minutes >= 1 { return ("+\(minutes) min", "\(minutes) minute\(minutes == 1 ? "" : "s") late", true) }
        if minutes <= -1 { return ("\(-minutes) min early", "\(-minutes) minute\(minutes == -1 ? "" : "s") early", true) }
        return ("on time", "on time", false)
    }

    // MARK: the walk

    /// "700 m", "1.2 km": rounded the way a walk is (50 m under a kilometre).
    static func metres(_ m: Double) -> String {
        guard m.isFinite, m >= 0 else { return "" }
        if m < 1000 { return "\(max(50, Int((m / 50).rounded()) * 50)) m" }
        let tenths = Int((m / 100).rounded())
        return tenths % 10 == 0 ? "\(tenths / 10) km" : "\(tenths / 10).\(tenths % 10) km"
    }

    /// "9 min walk · 700 m · leave by 15:37". Nil when there's nothing to say.
    static func walk(minutes: Int, metres m: Double?, leaveBy: String?) -> String? {
        var parts: [String] = []
        if minutes > 0 { parts.append("\(minutes) min walk") }
        if let m, m >= 1, !metres(m).isEmpty { parts.append(metres(m)) }
        if let l = leaveBy, !l.isEmpty, !parts.isEmpty { parts.append("leave by \(l)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "9 minute walk, leave by 15:37"
    static func walkSpoken(minutes: Int, leaveBy: String?) -> String? {
        guard minutes > 0 else { return nil }
        return "\(minutes) minute walk" + (leaveBy.map { ", leave by \($0)" } ?? "")
    }

    /// You're at the stop: within about 60 m of it (within 120 m when the planner has no walk to it at all).
    static func isHere(metres m: Double?, walkMinutes: Int) -> Bool {
        guard let m, m.isFinite, m >= 0 else { return false }
        return m <= 60 || (walkMinutes == 0 && m < 120)
    }

    /// "Waiting for Bus 305 · in 4 min", "… · due now", "… · left 2 min ago".
    static func waiting(_ vehicle: String, minutes: Int) -> String {
        "Waiting for \(vehicle) · " + (minutes >= 1 ? "in \(minutes) min" : minutes <= -2 ? "left \(-minutes) min ago" : "due now")
    }

    // MARK: VoiceOver

    /// The card in one go: "Go to Platform 5, Eindhoven Centraal, Intercity to Den Haag Centraal at 15:46, 3 minutes
    /// late, 9 minute walk, leave by 15:37". At the stop: "You're here, Platform 5, …, waiting for it".
    static func spoken(_ w: Where, here: Bool, ride: String, time: String, delay: String?, walk: String?) -> String {
        var parts: [String] = [(here ? "You’re here, " : "Go to ") + w.big]
        if let u = w.under { parts.append(u) }
        if let c = w.changeNote { parts.append(c) }
        if let u = w.unknownNote { parts.append(u.lowercased()) }
        parts.append("\(ride) at \(time)")
        if let d = delay { parts.append(d) }
        if here { parts.append("waiting for it") } else if let walk { parts.append(walk) }
        return parts.joined(separator: ", ")
    }
}
