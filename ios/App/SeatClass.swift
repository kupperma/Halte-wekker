import Foundation

// Friends (0.31.1): where 1st class is in each coach, for the seat picker. Foundation only, tested.
//
// What NS says: NS's virtual-train answer (`/ns/train`, through the relay) lists a train's units (`materieeldelen`),
// each with its type ("VIRMm1 VI"), its drawing (`afbeelding`, ".../virmm1_6.png"), its coaches (`bakken`: empty
// objects, nothing in them) and its seats (`zitplaatsen.zitplaatsEersteKlas`: how many 1st-class seats the unit has).
// It doesn't say which coach the 1st class is in. NS's drawings do: they mark it, as the trains do, with "1" by the
// doors and a thin line along the 1st-class windows (on each deck). The table below is read off those drawings
// (vt.ns-mlab.nl/v1/images/<drawing>.png, November 2026): for each drawing, where its coaches meet (shares of the
// unit's length), and in each coach the 1st-class part (shares of the coach, from the left of the drawing; per deck in
// a double-deck coach). So it's NS's own picture, not the real seats: the picker says "1st class (about here)" for a
// part of a coach, and "1st class" for a coach that's 1st class all through (the Koploper ICM-4's third coach).
// A unit NS says has no 1st-class seats gets none; a drawing not in the table (ICE, international trains): not known.

enum SeatClass {
    /// A 1st-class part of a coach: from `a` to `b`, shares of the coach as NS draws it, from its left. On `deck` in a
    /// double-deck coach (`.upper`, `.lower`); `.none`: on every deck (and the only one of a single-deck coach).
    struct Section: Equatable {
        var a: Double
        var b: Double
        var deck: SeatMap.Deck = .none
    }

    /// A coach as a whole.
    enum Kind: Equatable {
        /// No 1st class in it.
        case second
        /// A part of it is 1st class.
        case part
        /// All of it.
        case first
    }

    /// One of NS's drawings: where its coaches meet (shares of the unit, inside it: one fewer than its coaches), and
    /// each coach's 1st-class parts, left to right.
    struct Drawing: Equatable {
        let edges: [Double]
        let coaches: [[Section]]
    }

    private static func s(_ a: Double, _ b: Double, _ deck: SeatMap.Deck = .none) -> Section { Section(a: a, b: b, deck: deck) }
    /// The whole coach.
    static let whole = Section(a: 0, b: 1, deck: .none)

    private static let virm4: [Double] = [0.2523, 0.5033, 0.7477]
    private static let virm6: [Double] = [0.1688, 0.3323, 0.4997, 0.6677, 0.8312]
    private static let ddzCab: [Section] = [s(0.21, 0.50, .upper), s(0.21, 0.37, .lower)]
    private static let ddzMid: [Section] = [s(0.59, 0.78, .upper), s(0.44, 0.78, .lower)]
    private static let virmmEnd: [Section] = [s(0.54, 0.76, .upper), s(0.46, 0.76, .lower)]
    private static let icng8 = Drawing(edges: [0.1434, 0.2555, 0.3674, 0.5, 0.6326, 0.7445, 0.8566],
                                       coaches: [[], [], [s(0.27, 1.0)], [s(0.0, 0.13)], [s(0.87, 1.0)], [s(0.0, 0.67)], [], []])

    /// NS's drawings, by file name (lower case, no ".png").
    static let drawings: [String: Drawing] = [
        // VIRM (the first ones, "VIRM IV"/"VI"): 1st class in the middle, both decks (in the 4's second coach only below)
        "virm_4": Drawing(edges: virm4, coaches: [[], [s(0.45, 0.77, .lower)], [s(0.22, 0.54)], []]),
        "virm_6": Drawing(edges: virm6, coaches: [[], [s(0.45, 0.77)], [], [s(0.45, 0.78)], [s(0.22, 0.55)], []]),
        // VIRMm (rebuilt): the upper deck's 1st class is shorter than the lower's
        "virmm1_4": Drawing(edges: virm4, coaches: [[], virmmEnd, [s(0.22, 0.44, .upper), s(0.22, 0.52, .lower)], []]),
        "virmm1_6": Drawing(edges: virm6, coaches: [[], virmmEnd, [], virmmEnd,
                                                    [s(0.22, 0.44, .upper), s(0.22, 0.52, .lower)], []]),
        "virmm2_4": Drawing(edges: virm4, coaches: [[], [s(0.54, 0.76, .upper)],
                                                    [s(0.22, 0.45, .upper), s(0.22, 0.53, .lower)], []]),
        "virmm2_6": Drawing(edges: virm6, coaches: [[], virmmEnd, [], [s(0.54, 0.76, .upper)],
                                                    [s(0.22, 0.45, .upper), s(0.22, 0.53, .lower)], []]),
        // DDZ (the rebuilt DD-IRM): behind the cab, and in each middle coach with the bicycles
        "ddz_4": Drawing(edges: [0.2648, 0.5263, 0.7878], coaches: [ddzCab, [], ddzMid, []]),
        "ddz_6": Drawing(edges: [0.1739, 0.3456, 0.5173, 0.689, 0.8607], coaches: [ddzCab, [], ddzMid, [], ddzMid, []]),
        // ICM (the Koploper): part of the middle coach; the 4's third coach is 1st class all through
        "icm_3": Drawing(edges: [0.333, 0.666], coaches: [[], [s(0.43, 0.89)], []]),
        "icm_4": Drawing(edges: [0.2496, 0.4993, 0.75], coaches: [[], [], [whole], []]),
        // ICNG: around the middle, over a gangway
        "icng_5": Drawing(edges: [0.2159, 0.3847, 0.5844, 0.7841], coaches: [[], [], [s(0.25, 1.0)], [s(0.0, 0.32)], []]),
        "icng_8": icng8,
        // the Belgian-run ICNG (Amsterdam–Brussels, "icng_B_8"): drawn the same
        "icng_b_8": icng8,
        // Sprinters: behind a cab (both ends; the SNG-3 only at one)
        "slt_4": Drawing(edges: [0.2756, 0.5, 0.7237], coaches: [[s(0.24, 0.47)], [], [], [s(0.53, 0.76)]]),
        "slt_6": Drawing(edges: [0.1903, 0.345, 0.4997, 0.6545, 0.8092], coaches: [[s(0.24, 0.47)], [], [], [], [], [s(0.53, 0.76)]]),
        "sng_3": Drawing(edges: [0.3634, 0.6366], coaches: [[s(0.20, 0.42)], [], []]),
        "sng_4": Drawing(edges: [0.2854, 0.5, 0.7146], coaches: [[s(0.20, 0.42)], [], [], [s(0.58, 0.80)]]),
        "nsr_flirt_3": Drawing(edges: [0.361, 0.638], coaches: [[s(0.27, 0.41)], [], [s(0.59, 0.73)]]),
        "nsr_flirt_4": Drawing(edges: [0.2824, 0.4994, 0.7164], coaches: [[s(0.27, 0.41)], [], [], [s(0.59, 0.73)]]),
    ]

    // MARK: which drawing

    /// The drawing's name from NS's `afbeelding` (".../virmm1_6.png" → "virmm1_6"), else from the unit's type
    /// ("VIRMm1 VI" → "virmm1_6", "DDZ 4" → "ddz_4", "Flirt 3" → "nsr_flirt_3"). Nil: not one in the table.
    static func drawing(image: String, type: String = "") -> String? {
        var file: String = image.split(separator: "/").last.map(String.init) ?? ""
        if file.lowercased().hasSuffix(".png") { file = String(file.dropLast(4)) }
        let f: String = file.lowercased()
        if drawings[f] != nil { return f }
        let roman: [String: String] = ["ii": "2", "iii": "3", "iv": "4", "v": "5", "vi": "6", "viii": "8"]
        let words: [String] = type.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { roman[String($0)] ?? String($0) }
        guard !words.isEmpty else { return nil }
        let k: String = words.joined(separator: "_")
        for c in [k, "nsr_" + k] where drawings[c] != nil { return c }
        return nil
    }

    // MARK: a coach

    /// The 1st-class parts of coach `i` (from the left of the drawing, 0-based) of a unit drawn as `drawing` with
    /// `cars` coaches. `firstSeats`: NS's count of the unit's 1st-class seats (0: none at all; nil: not said).
    /// Nil: not known (a drawing not in the table, or NS lists another number of coaches than it draws).
    static func sections(drawing: String?, coach i: Int, cars: Int, firstSeats: Int?) -> [Section]? {
        if firstSeats == 0 { return [] }
        guard let drawing, let d = drawings[drawing], d.coaches.count == cars, i >= 0, i < cars else { return nil }
        return d.coaches[i]
    }

    static func kind(_ sections: [Section]) -> Kind {
        if sections.isEmpty { return .second }
        return sections.contains(where: { $0.deck == .none && $0.a <= 0.02 && $0.b >= 0.98 }) ? .first : .part
    }

    /// Whether window `drawn` (from the left, 0-based, of `n`) in `row` (0 the top: the upper deck or the only one; 1
    /// the lower deck) is in a 1st-class part: its middle is.
    static func isFirst(window drawn: Int, row: Int, double: Bool, sections: [Section], of n: Int = SeatMap.windows) -> Bool {
        guard drawn >= 0, drawn < n, n > 0 else { return false }
        let mid: Double = (Double(drawn) + 0.5) / Double(n)
        let deck: SeatMap.Deck = double ? (row == 0 ? .upper : .lower) : .none
        return sections.contains { s in
            (s.deck == .none || s.deck == deck || !double) && mid >= s.a - 1e-9 && mid <= s.b + 1e-9
        }
    }

    /// The 1st-class windows of a row, as runs (first and last drawn window), left to right.
    static func runs(row: Int, double: Bool, sections: [Section], of n: Int = SeatMap.windows) -> [ClosedRange<Int>] {
        var out: [ClosedRange<Int>] = []
        var start: Int?
        for i in 0...n {
            let on: Bool = i < n && isFirst(window: i, row: row, double: double, sections: sections, of: n)
            if on, start == nil { start = i }
            if !on, let s = start {
                out.append(s...(i - 1))
                start = nil
            }
        }
        return out
    }

    /// Where along the coach (shares, from the left) any deck has 1st class, for the train strip's mark. Nil: none.
    static func span(_ sections: [Section]) -> ClosedRange<Double>? {
        guard let a = sections.map(\.a).min(), let b = sections.map(\.b).max(), b > a else { return nil }
        return max(0, a)...min(1, b)
    }

    // MARK: the whole unit (where 1st class stops on the platform)

    /// A drawing's 1st-class parts as shares of the whole unit (any deck), merged where they touch. Nil: not in the table.
    static func unitZones(_ drawing: String) -> [(a: Double, b: Double)]? {
        guard let d = drawings[drawing] else { return nil }
        let ends: [Double] = [0] + d.edges + [1]
        var list: [(a: Double, b: Double)] = []
        for (i, secs) in d.coaches.enumerated() where i + 1 < ends.count {
            let x0: Double = ends[i], w: Double = ends[i + 1] - ends[i]
            for s in secs { list.append((x0 + s.a * w, x0 + s.b * w)) }
        }
        list.sort { $0.a < $1.a }
        var out: [(a: Double, b: Double)] = []
        for z in list {
            if let last = out.last, z.a <= last.b + 0.005 {
                out[out.count - 1] = (last.a, max(last.b, z.b))
            } else {
                out.append(z)
            }
        }
        return out
    }

    // MARK: NS's answer

    /// One unit of NS's answer, as far as 1st class goes.
    struct Part: Equatable {
        /// Its type ("VIRMm1 VI").
        var type: String
        /// Its drawing's name ("virmm1_6", from `afbeelding`).
        var image: String
        /// Its drawn width (`breedte`).
        var width: Double
        /// Its coaches (`bakken`).
        var cars: Int
        /// Its 1st-class seats (`zitplaatsen.zitplaatsEersteKlas`; nil: not said).
        var firstSeats: Int?
    }

    /// The units of NS's `/ns/train` answer.
    static func parts(_ d: [String: Any]) -> [Part] {
        let list: [[String: Any]] = (d["materieeldelen"] as? [[String: Any]]) ?? []
        return list.map { m in
            var key: String = ((m["afbeelding"] as? String) ?? "").split(separator: "/").last.map(String.init) ?? ""
            if key.lowercased().hasSuffix(".png") { key = String(key.dropLast(4)) }
            let seats: [String: Any]? = m["zitplaatsen"] as? [String: Any]
            let first: Int? = (seats?["zitplaatsEersteKlas"] as? NSNumber)?.intValue
            return Part(type: (m["type"] as? String) ?? (m["materieelType"] as? String) ?? "", image: key.lowercased(),
                        width: (m["breedte"] as? NSNumber)?.doubleValue ?? 0, cars: ((m["bakken"] as? [Any]) ?? []).count,
                        firstSeats: first)
        }
    }

    /// The parts as the coach picker's units (where each starts and how long it is, shares of the train).
    static func units(_ parts: [Part]) -> [CoachMap.Unit] {
        let total: Double = parts.reduce(0) { $0 + $1.width }
        guard total > 0 else { return [] }
        var x: Double = 0
        var out: [CoachMap.Unit] = []
        for p in parts {
            out.append(CoachMap.Unit(x: x / total, w: p.width / total, cars: p.cars))
            x += p.width
        }
        return out
    }

    // MARK: words

    /// "1st class", "1st class (about here)" (a part of the coach), nil (2nd class).
    static func words(_ kind: Kind) -> String? {
        switch kind {
        case .first: return "1st class"
        case .part: return "1st class (about here)"
        case .second: return nil
        }
    }

    /// The picker's legend, after its "1" badge: "= 1st class (about here)", "… · gold coach: all 1st class".
    static func legend(part: Bool, whole: Bool) -> String {
        switch (part, whole) {
        case (true, true): return "= 1st class (about here) · gold coach: all 1st class"
        case (false, true): return "= 1st class · gold coach: all 1st class"
        default: return "= 1st class (about here)"
        }
    }

    /// The legend for VoiceOver.
    static func spokenLegend(part: Bool, whole: Bool) -> String {
        let p = "1st class is marked with a 1, about where it is"
        let w = "gold coaches are all 1st class"
        switch (part, whole) {
        case (true, true): return "\(p); \(w)"
        case (false, true): return TravelWords.capitalFirst(w)
        default: return p
        }
    }
}
