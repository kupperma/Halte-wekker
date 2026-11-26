import Foundation

/// Walking turn by turn to the stop (0.41): "In 40 m · turn right onto Hoogstraat", with a big arrow, like a navigation
/// app. The route comes from the map's walking directions (`WalkGuideModel`), as steps: each step's words (the map's
/// own, in the phone's language), its length and its shape. The steps don't say which way they turn, so the arrow comes
/// from the shape: the direction coming into the step's start against the direction going out of it.
/// The step you're on is the stretch you're walking; the turn shown is the one at its end (the next step's start).
/// It moves on to the next step within `advanceWithin` of the turn (or once you're past it along the route), buzzes at
/// `warnAt` and at the turn, finds a new route when you've been more than `offRouteMetres` off it for `offRouteFor`
/// (at most every `rerouteEvery`), and says you're there within `arriveWithin` of the stop.
/// Plain values, so the rules are tested. Foundation only.
enum WalkGuide {
    /// Metres before a turn at which it counts as reached: the next step is shown.
    static let advanceWithin = 15.0
    /// Metres before a turn at which a buzz says it's coming.
    static let warnAt = 30.0
    /// A step shorter than this has no warning buzz of its own (the buzz at the turn before it is enough).
    static let warnStepAtLeast = 40.0
    /// Further than this from the route counts as off it…
    static let offRouteMetres = 40.0
    /// …for this long: then a new route.
    static let offRouteFor: TimeInterval = 10
    /// At most one new route this often.
    static let rerouteEvery: TimeInterval = 20
    /// This close to the stop: you're there.
    static let arriveWithin = 25.0
    /// A fix less sure than this (metres) doesn't move the guide, take you off the route or say you're there.
    static let worstFix = 65.0
    /// How far before and after a turn the directions in and out are measured (metres).
    static let bearingSpan = 12.0
    /// The planner's walking speed, when yours isn't known (m/s).
    static let defaultSpeed = 1.2

    // MARK: the arrow

    enum Turn: String, Equatable, Sendable, CaseIterable {
        case depart, straight, slightLeft, left, sharpLeft, slightRight, right, sharpRight, uTurn, arrive

        /// Its SF Symbol.
        var symbol: String {
            switch self {
            case .depart, .straight: return "arrow.up"
            case .slightLeft: return "arrow.up.left"
            case .left: return "arrow.turn.up.left"
            case .sharpLeft: return "arrow.down.left"
            case .slightRight: return "arrow.up.right"
            case .right: return "arrow.turn.up.right"
            case .sharpRight: return "arrow.down.right"
            case .uTurn: return "arrow.uturn.down"
            case .arrive: return "mappin.and.ellipse"
            }
        }

        /// A text arrow, for the lock screen: "→ 40 m · Hoogstraat".
        var glyph: String {
            switch self {
            case .depart, .straight: return "↑"
            case .slightLeft: return "↖"
            case .left: return "←"
            case .sharpLeft: return "↙"
            case .slightRight: return "↗"
            case .right: return "→"
            case .sharpRight: return "↘"
            case .uTurn: return "↩"
            case .arrive: return "◉"
            }
        }

        /// For VoiceOver: "Turn right".
        var words: String {
            switch self {
            case .depart: return "Start"
            case .straight: return "Straight on"
            case .slightLeft: return "Keep left"
            case .left: return "Turn left"
            case .sharpLeft: return "Sharp left"
            case .slightRight: return "Keep right"
            case .right: return "Turn right"
            case .sharpRight: return "Sharp right"
            case .uTurn: return "Turn around"
            case .arrive: return "Arrive"
            }
        }
    }

    /// The turn from direction `from` to direction `to` (compass degrees), in -180…180: positive is to the right.
    static func change(from: Double, to: Double) -> Double {
        let d: Double = (to - from).truncatingRemainder(dividingBy: 360)
        let w: Double = (d + 540).truncatingRemainder(dividingBy: 360) - 180
        return w == -180 ? 180 : w
    }

    /// The arrow for a turn of `change` degrees (positive: right).
    static func turn(change c: Double) -> Turn {
        let a: Double = abs(c)
        let right: Bool = c > 0
        if a < 20 { return .straight }
        if a < 45 { return right ? .slightRight : .slightLeft }
        if a < 120 { return right ? .right : .left }
        if a < 165 { return right ? .sharpRight : .sharpLeft }
        return .uTurn
    }

    /// Which side the words say, when they say one ("Turn right", "Sla linksaf"); nil: neither or both.
    static func side(_ text: String) -> Bool? {
        let words: [String] = text.lowercased().split { !$0.isLetter }.map(String.init)
        let r: Bool = words.contains { ["right", "rechts", "rechtsaf"].contains($0) }
        let l: Bool = words.contains { ["left", "links", "linksaf"].contains($0) }
        if r == l { return nil }
        return r
    }

    /// The words say you're there ("The destination is on your right", "Arrive at…", "Je bestemming…").
    static func saysArrive(_ text: String) -> Bool {
        let t: String = text.lowercased()
        return ["destination", "arrive", "bestemming", "aankomst"].contains { t.contains($0) }
    }

    // MARK: the words

    /// The map's words, tidied: no spaces around or doubled, no full stop at the end. "Turn right onto Hoogstraat."
    /// → "Turn right onto Hoogstraat".
    static func short(_ text: String) -> String {
        let parts: [Substring] = text.split(whereSeparator: { $0.isWhitespace })
        var t: String = parts.joined(separator: " ")
        while let last = t.last, last == "." || last == "," || last == ";" { t.removeLast() }
        return t
    }

    /// The words to follow "In 40 m · ": the first letter small unless the first word is all capitals or a name
    /// ("turn right onto Hoogstraat").
    static func lowerFirst(_ text: String) -> String {
        guard let first = text.first, first.isUppercase else { return text }
        let firstWord: Substring = text.split(separator: " ").first ?? Substring(text)
        if firstWord.count > 1 && firstWord.allSatisfy({ $0.isUppercase || !$0.isLetter }) { return text }
        return first.lowercased() + text.dropFirst()
    }

    /// "40 m", "1.2 km": 5 m steps under 100 m, 10 m steps under a kilometre.
    static func metres(_ m: Double) -> String {
        let v: Double = m.isFinite ? max(0, m) : 0
        if v < 100 { return "\(max(5, Int((v / 5).rounded()) * 5)) m" }
        if v < 995 { return "\(Int((v / 10).rounded()) * 10) m" }
        return String(format: "%.1f km", v / 1000)
    }

    /// The big line: "In 40 m · turn right onto Hoogstraat"; at the stop's step "In 20 m · the destination is on your
    /// right". Without words: the arrow's ("In 40 m · turn right").
    static func phrase(metres m: Double, step: Step) -> String {
        let words: String = step.text.isEmpty ? step.turn.words : step.text
        return "In \(metres(m)) · \(lowerFirst(words))"
    }

    /// The same, to be spoken: "In 40 metres, turn right onto Hoogstraat".
    static func spoken(metres m: Double, step: Step) -> String {
        let words: String = step.text.isEmpty ? step.turn.words : step.text
        let d: String = metres(m).replacingOccurrences(of: " km", with: " kilometres").replacingOccurrences(of: " m", with: " metres")
        return "In \(d), \(lowerFirst(words))"
    }

    /// The street a step turns into ("Turn right onto Hoogstraat" → "Hoogstraat", "Sla rechtsaf naar de Kerkstraat" →
    /// "Kerkstraat"); nil when the words name none.
    static func street(_ text: String) -> String? {
        let t: String = short(text)
        var best: String.Index?
        for m in [" onto ", " into ", " on ", " naar ", " op "] {
            if let r = t.range(of: m, options: [.backwards, .caseInsensitive]) {
                if best.map({ r.upperBound > $0 }) ?? true { best = r.upperBound }
            }
        }
        guard let start = best else { return nil }
        var s: String = String(t[start...]).trimmingCharacters(in: .whitespaces)
        for article in ["de ", "het ", "the "] where s.lowercased().hasPrefix(article) { s = String(s.dropFirst(article.count)) }
        return s.isEmpty ? nil : s
    }

    /// The lock screen's line while walking: "→ 40 m · Hoogstraat" (the street, else the words, cut short).
    /// At the stop's step: the stop's name (`stop`).
    static func lockLine(metres m: Double, step: Step, stop: String) -> String {
        let words: String = step.text.isEmpty ? step.turn.words : step.text
        let name: String = step.turn == .arrive ? stop : (street(step.text) ?? words)
        let cut: String = name.count > 32 ? String(name.prefix(31)) + "…" : name
        return "\(step.turn.glyph) \(metres(m)) · \(cut)"
    }

    // MARK: the route

    /// A step as the map gives it: its words, its length in metres and its shape.
    struct RawStep: Equatable, Sendable {
        let text: String
        let distance: Double
        let path: [GeoPoint]
    }

    /// A step to follow: its words (tidied), its arrow (the turn at its start), and where it starts and ends along the
    /// route (metres).
    struct Step: Equatable, Sendable {
        let text: String
        let turn: Turn
        let start: Double
        let end: Double
        var length: Double { max(0, end - start) }
    }

    /// The whole walk: its shape (all steps' shapes, one after the other) and the steps to follow.
    struct Route: Equatable, Sendable {
        let path: [GeoPoint]
        let steps: [Step]
        let length: Double
    }

    /// The route from the map's steps. Steps without words (the map's first, where you stand) are joined to their
    /// neighbour. The first step is the start; the last is the stop (added when the map's last one turns).
    static func route(_ raw: [RawStep]) -> Route {
        var path: [GeoPoint] = []
        var starts: [Double] = []
        var total: Double = 0
        for s in raw {
            starts.append(total)
            for p in s.path where p.lat.isFinite && p.lon.isFinite {
                if let last = path.last {
                    if last == p { continue }
                    total += Geo.metres(last, p)
                }
                path.append(p)
            }
        }
        let kept: [Int] = raw.indices.filter { !short(raw[$0].text).isEmpty }
        guard !kept.isEmpty, total > 0 else {
            let only = Step(text: "", turn: .arrive, start: 0, end: total)
            return Route(path: path, steps: [only], length: total)
        }
        var steps: [Step] = []
        for (k, i) in kept.enumerated() {
            let start: Double = k == 0 ? 0 : starts[i]
            let end: Double = k + 1 < kept.count ? starts[kept[k + 1]] : total
            let text: String = short(raw[i].text)
            let turn: Turn
            if k == 0 {
                turn = .depart
            } else if k == kept.count - 1 && (end - start < warnAt || saysArrive(text)) {
                turn = .arrive
            } else {
                turn = Self.turn(at: start, on: path, text: text)
            }
            steps.append(Step(text: text, turn: turn, start: start, end: max(start, end)))
        }
        if steps.count < 2 || steps[steps.count - 1].turn != .arrive {
            steps.append(Step(text: "", turn: .arrive, start: total, end: total))
        }
        return Route(path: path, steps: steps, length: total)
    }

    /// The arrow at `along` metres on `path`: the direction in against the direction out; the words decide when the
    /// shape can't (too short), and turn a straight shape that the words say goes one way into a slight turn.
    static func turn(at along: Double, on path: [GeoPoint], text: String) -> Turn {
        let side: Bool? = Self.side(text)
        let before: GeoPoint? = Geo.point(atMetres: along - bearingSpan, on: path)
        let at: GeoPoint? = Geo.point(atMetres: along, on: path)
        let after: GeoPoint? = Geo.point(atMetres: along + bearingSpan, on: path)
        guard let b = before, let a = at, let c = after, Geo.metres(b, a) > 2, Geo.metres(a, c) > 2 else {
            guard let s = side else { return .straight }
            return s ? .right : .left
        }
        let t: Turn = turn(change: change(from: Geo.bearing(b, a), to: Geo.bearing(a, c)))
        if t == .straight, let s = side { return s ? .slightRight : .slightLeft }
        return t
    }

    // MARK: following it

    /// Where you are on the route: the step you're walking (its turn is at its end), how far along, how far off it, to
    /// the turn and to the stop; `advanced`: it just moved on.
    struct Position: Equatable, Sendable {
        let step: Int
        let along: Double
        let off: Double
        let toTurn: Double
        let left: Double
        let advanced: Bool
    }

    /// Your place on `r` at `p`: from the step you were on (`current`, never back), the pass of the route nearest to
    /// where you were along it (`lastAlong`, so a route that comes back past you doesn't jump). It moves on while you're
    /// within `advanceWithin` of the step's end (or past it), and only on the route (not when off it).
    static func locate(_ p: GeoPoint, on r: Route, step current: Int, lastAlong: Double?) -> Position? {
        guard !r.steps.isEmpty, let pass = Geo.pass(p, on: r.path, near: lastAlong, within: 20, previous: lastAlong) else { return nil }
        let along: Double = pass.projection.along
        let off: Double = pass.projection.crossTrack
        let last: Int = r.steps.count - 1
        var step: Int = min(max(0, current), last)
        if off <= offRouteMetres {
            while step < last && r.steps[step].end - along <= advanceWithin { step += 1 }
        }
        let toTurn: Double = max(0, r.steps[step].end - along)
        let left: Double = max(0, r.length - along)
        return Position(step: step, along: along, off: off, toTurn: toTurn, left: left, advanced: step > current)
    }

    /// The turn to show while walking step `k`: the next step's (the one at its end), or the stop's at the last.
    static func next(_ r: Route, step k: Int) -> Step? {
        guard !r.steps.isEmpty else { return nil }
        return r.steps[min(max(0, k + 1), r.steps.count - 1)]
    }

    /// The one after it, small: nil when the next is the stop.
    static func then(_ r: Route, step k: Int) -> Step? {
        let i: Int = k + 2
        guard i >= 1, i < r.steps.count else { return nil }
        return r.steps[i]
    }

    /// Time for the buzz that says a turn is coming: within `warnAt` of it, not yet at it, not told yet, on a step long
    /// enough to have its own warning, and on the route.
    static func warn(_ pos: Position, on r: Route, warned: Bool) -> Bool {
        guard !warned, pos.off <= offRouteMetres, pos.step < r.steps.count - 1 else { return false }
        let step: Step = r.steps[pos.step]
        return step.length >= warnStepAtLeast && pos.toTurn <= warnAt && pos.toTurn > advanceWithin
    }

    /// Off the route: since when you've been further than `offRouteMetres` from it, and the last new route.
    struct OffRoute: Equatable, Sendable {
        var since: Date? = nil
        var lastReroute: Date? = nil
    }

    /// The new state with a fix `off` metres from the route (as sure as `accuracy`), and whether to find a new route
    /// now: off it for `offRouteFor`, and the last new route at least `rerouteEvery` ago. An unsure fix changes nothing.
    static func offRoute(_ s: OffRoute, off: Double, accuracy: Double, now: Date) -> (state: OffRoute, reroute: Bool) {
        guard accuracy >= 0, accuracy <= worstFix, off.isFinite else { return (s, false) }
        var n: OffRoute = s
        guard off > offRouteMetres else { n.since = nil; return (n, false) }
        let since: Date = s.since ?? now
        n.since = since
        let long: Bool = now.timeIntervalSince(since) >= offRouteFor
        let free: Bool = s.lastReroute.map { now.timeIntervalSince($0) >= rerouteEvery } ?? true
        guard long && free else { return (n, false) }
        n.since = nil
        n.lastReroute = now
        return (n, true)
    }

    /// You're at the stop: within `arriveWithin` metres, by a fix sure enough.
    static func arrived(metres m: Double, accuracy: Double) -> Bool {
        accuracy >= 0 && accuracy <= worstFix && m.isFinite && m <= arriveWithin
    }

    /// The route split where you are: the part walked (drawn dimmed) and the part ahead.
    static func split(_ path: [GeoPoint], at along: Double) -> (walked: [GeoPoint], ahead: [GeoPoint]) {
        guard path.count >= 2, along > 0 else { return ([], path) }
        var walked: [GeoPoint] = [path[0]]
        var acc: Double = 0
        for i in 1..<path.count {
            let l: Double = Geo.metres(path[i - 1], path[i])
            if acc + l >= along {
                let cut: GeoPoint = Geo.point(atMetres: along, on: path) ?? path[i]
                walked.append(cut)
                return (walked, [cut] + path[i...])
            }
            acc += l
            walked.append(path[i])
        }
        return (walked, [path[path.count - 1]])
    }

    // MARK: will you make it

    enum Pace: Equatable, Sendable {
        case fine       // at your pace, a minute or more to spare
        case faster     // a bit faster and you're there in time
        case hurry      // even faster it's tight
        case gone       // it leaves now
    }

    struct Hurry: Equatable, Sendable {
        let walkMinutes: Int
        let leavesIn: Int?
        let pace: Pace?
        /// "Your bus leaves in 6 min · you’ll make it"
        let text: String?
    }

    /// With `left` metres to go at `speed` (m/s; else the planner's), and the ride leaving at `leaves`: the minutes of
    /// walk left and the hint. `what`: "your bus", "your train".
    static func hurry(left: Double, speed: Double?, leaves: Date?, now: Date, what: String) -> Hurry {
        let v: Double = speed.flatMap { $0.isFinite && $0 >= 0.5 && $0 <= 2.5 ? $0 : nil } ?? defaultSpeed
        let m: Double = left.isFinite ? max(0, left) : 0
        let walkSecs: Double = m / v
        let walkMinutes: Int = m <= 0 ? 0 : max(1, Int((walkSecs / 60).rounded(.up)))
        guard let leaves else { return Hurry(walkMinutes: walkMinutes, leavesIn: nil, pace: nil, text: nil) }
        let secs: Double = leaves.timeIntervalSince(now)
        let name: String = what.prefix(1).uppercased() + what.dropFirst()
        guard secs > 30 else {
            return Hurry(walkMinutes: walkMinutes, leavesIn: 0, pace: .gone, text: "\(name) leaves now")
        }
        let mins: Int = Int((secs / 60).rounded(.down))
        let spare: Double = secs - walkSecs
        let pace: Pace
        let hint: String
        if spare >= 60 {
            pace = .fine; hint = "you’ll make it"
        } else if secs - walkSecs / 1.25 >= 0 {
            pace = .faster; hint = "walk a bit faster"
        } else {
            pace = .hurry; hint = "hurry, it’s tight"
        }
        let when: String = mins <= 0 ? "in under a minute" : "in \(mins) min"
        return Hurry(walkMinutes: walkMinutes, leavesIn: mins, pace: pace, text: "\(name) leaves \(when) · \(hint)")
    }

    /// "4 min · 320 m to go"
    static func left(metres m: Double, minutes: Int) -> String {
        "\(max(1, minutes)) min · \(metres(m)) to go"
    }
}
