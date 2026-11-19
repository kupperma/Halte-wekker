import Foundation

// Friends (0.31): where you sit, roughly. The seat picker's sums as plain values, tested without NS or the UI.
// Foundation only.
//
// The whole train: its coaches from NS's drawing (units and their coaches), each single- or double-deck by the unit's
// type; without NS, the coaches NS counted (or 6), a Sprinter single-deck and an Intercity double-deck. A coach, seen
// from the platform: 11 windows a row (one row, or two: the top row the upper deck, the bottom row the lower). Your
// window goes to friends with your coach, counted from the back of the coach (`TravelState.Seat`).

enum SeatMap {
    /// Windows in a row: it's "where roughly", not a seat number.
    static let windows = 11
    /// Coaches drawn when nothing says how many.
    static let defaultCoaches = 6
    /// The most coaches drawn (NS's longest trains are 12; two coupled sets of 6, plus a little).
    static let maxCoaches = 16

    enum Deck: String, CaseIterable {
        case upper, lower, none

        /// "upper deck", "lower deck", nil (one deck).
        var words: String? {
            switch self {
            case .upper: return "upper deck"
            case .lower: return "lower deck"
            case .none: return nil
            }
        }
    }

    static func deck(_ s: TravelState.Seat) -> Deck { Deck(rawValue: s.deck) ?? .none }

    // MARK: the train

    /// Whether a unit of this type has two decks (NS's `type`, or its drawing's name, like "VIRM-6", "virmm1_6",
    /// "DDZ-4", "SNG-3", "nsr_flirt_4"). Nil: a type this doesn't know.
    static func doubleDeck(kind: String) -> Bool? {
        let k: String = kind.uppercased().filter { $0.isLetter || $0.isNumber }
        guard !k.isEmpty else { return nil }
        // two decks: VIRM (and VIRMm), DDZ/NID (the rebuilt DD-IRM), DD-AR / mDDM
        let double: [String] = ["VIRM", "DDZ", "DDIRM", "NID", "DDAR", "MDDM", "DDM"]
        if double.contains(where: { k.hasPrefix($0) || k.contains($0) }) { return true }
        // one deck: Sprinters (SNG, SLT, FLIRT, SGM, GTW…), the Koploper (ICM), ICNG, and the international trains
        let single: [String] = ["SNG", "SLT", "FLIRT", "SGM", "GTW", "ICM", "ICNG", "ICR", "ICE", "THALYS", "EUROSTAR",
                                "EUROCITY", "I11", "TRAXX", "LINT", "PROTOS", "WINK", "DESIRO", "SPRINTER", "MAT64"]
        if single.contains(where: { k.hasPrefix($0) || k.contains($0) }) { return false }
        return nil
    }

    /// Without NS's word: an Intercity ("IC", "ICD", "Intercity") has two decks; a Sprinter and anything else one.
    static func defaultDouble(line: String?) -> Bool {
        let l: String = (line ?? "").uppercased().trimmingCharacters(in: .whitespaces)
        return ["IC", "ICD", "INTERCITY", "INTERCITY DIRECT", "IC DIRECT"].contains(l)
    }

    /// One coach as the picker draws it.
    struct Coach: Equatable {
        /// Drawn from the left, 0-based.
        var drawn: Int
        /// Its number as friends get it: from the front (`front`), else from the left.
        var n: Int
        var front: Bool
        var double: Bool
        /// (0.31.1) Its 1st-class parts (`SeatClass`): [] none; nil not known.
        var first: [SeatClass.Section]? = nil

        /// 2nd, part 1st, all 1st (nil: not known).
        var kind: SeatClass.Kind? { first.map(SeatClass.kind) }
    }

    /// The whole train, left to right.
    struct Train: Equatable {
        var coaches: [Coach]
        /// "left" or "right": the side the front is drawn on (nil: not known; numbered from the left).
        var dir: String?
        /// From NS's drawing (false: the picker's guess).
        var fromNS: Bool

        var count: Int { coaches.count }
        var anyDouble: Bool { coaches.contains(where: \.double) }
        /// (0.31.1) Some coach has 1st class drawn in.
        var anyFirst: Bool { coaches.contains { ($0.first ?? []).isEmpty == false } }
        /// (0.31.1) Some coach's 1st class isn't known (NS's drawing isn't one the table has).
        var firstUnknown: Bool { coaches.contains { $0.first == nil } }
    }

    /// The train from NS's drawing: its units (with each one's type in `kinds`, the same order) and `totalCars` (NS's
    /// length), going `dir`. Without units: `totalCars` coaches (or 6), front on the right (so you can still say
    /// "third from the front"), decks by the line. (0.31.1) Each unit's drawing's name in `drawings` and its 1st-class
    /// seats in `firstSeats` (the same order) give each coach its 1st class (`SeatClass`); the guess has none known.
    static func train(units: [CoachMap.Unit], kinds: [String], totalCars: Int, dir: String?, line: String?,
                      drawings: [String] = [], firstSeats: [Int?] = []) -> Train {
        let fallbackDouble: Bool = defaultDouble(line: line)
        let spots: [CoachMap.Spot] = units.isEmpty ? [] : CoachMap.spots(units, totalCars: totalCars)
        if spots.isEmpty {
            let n: Int = min(maxCoaches, max(1, totalCars > 0 ? totalCars : defaultCoaches))
            let list: [Coach] = (0..<n).map { i in
                let num = CoachMap.number(drawn: i, of: n, dir: "right")
                return Coach(drawn: i, n: num.n, front: num.front, double: fallbackDouble)
            }
            return Train(coaches: list, dir: "right", fromNS: false)
        }
        let shown: [CoachMap.Spot] = Array(spots.prefix(maxCoaches))
        // the unit each coach is in: the one its middle falls in
        let unitOf: [Int] = spots.map { s in
            let u: Int = units.lastIndex(where: { $0.x <= s.mid + 1e-9 }) ?? 0
            return min(max(0, u), units.count - 1)
        }
        var list: [Coach] = []
        for s in shown {
            let u: Int = unitOf[s.drawn]
            let kind: String = u < kinds.count ? kinds[u] : ""
            let double: Bool = doubleDeck(kind: kind) ?? fallbackDouble
            let num = CoachMap.number(drawn: s.drawn, of: shown.count, dir: dir)
            // its place in its unit, and the unit's coaches (as drawn)
            let inUnit: Int = unitOf[..<s.drawn].filter { $0 == u }.count
            let cars: Int = unitOf.filter { $0 == u }.count
            let image: String = u < drawings.count ? drawings[u] : ""
            let seats: Int? = u < firstSeats.count ? firstSeats[u] : nil
            let first: [SeatClass.Section]? = SeatClass.sections(drawing: SeatClass.drawing(image: image, type: kind),
                                                                 coach: inUnit, cars: cars, firstSeats: seats)
            list.append(Coach(drawn: s.drawn, n: num.n, front: num.front, double: double, first: first))
        }
        return Train(coaches: list, dir: dir, fromNS: true)
    }

    // MARK: the windows

    /// The window drawn at `drawn` (from the left, 0-based) as a seat counts it: from the back of the coach when the
    /// front is drawn on the right (the back is then on the left) or the left; from the left when it isn't known.
    static func window(drawn: Int, of n: Int = windows, dir: String?) -> Int {
        dir == "left" ? n - drawn : drawn + 1
    }

    /// Back to the drawing: where window `w` is drawn (from the left, 0-based). Nil: not a window of `n`.
    static func drawnWindow(_ w: Int, of n: Int = windows, dir: String?) -> Int? {
        guard w >= 1, w <= n else { return nil }
        return dir == "left" ? n - w : w - 1
    }

    /// The seat for a window tapped in a coach: the top row is the upper deck, the bottom the lower; one row: "none".
    static func seat(drawn: Int, row: Int, double: Bool, dir: String?) -> TravelState.Seat {
        let deck: Deck = double ? (row == 0 ? .upper : .lower) : .none
        return TravelState.Seat(deck: deck.rawValue, w: window(drawn: drawn, dir: dir), of: windows)
    }

    /// A seat as read from a friend: kept only when it makes sense (a window of 1…40, of at most 40).
    static func valid(_ s: TravelState.Seat?) -> TravelState.Seat? {
        guard let s, s.of >= 1, s.of <= 40, s.w >= 1, s.w <= s.of else { return nil }
        return s
    }

    /// (0.31.1) Whether a seat in coach `c` is in its 1st class: the whole coach is, or its window (in its row) is.
    static func isFirst(_ s: TravelState.Seat?, in c: Coach, dir: String?) -> Bool {
        guard let first = c.first else { return false }
        if SeatClass.kind(first) == .first { return true }
        guard let s, let w = drawnWindow(s, dir: dir) else { return false }
        return SeatClass.isFirst(window: w, row: row(s, double: c.double), double: c.double, sections: first)
    }

    /// (0.31.1) Whether someone's coach (with its seat, if any) is in 1st class in this train (as drawn at `station`).
    static func isFirst(_ c: TravelState.Coach, in t: Train, station: String?) -> Bool {
        guard let d = CoachMap.drawn(c, total: t.count, dir: t.dir, station: station),
              let coach = t.coaches.first(where: { $0.drawn == d }) else { return false }
        return isFirst(valid(c.seat), in: coach, dir: t.dir)
    }

    /// Which row a seat is drawn in: 0 the top (upper deck, or the only row), 1 the bottom (lower deck).
    static func row(_ s: TravelState.Seat, double: Bool) -> Int {
        double && deck(s) == .lower ? 1 : 0
    }

    /// A seat drawn in a coach of `n` windows: its window scaled to `n` when the friend's app drew another number.
    static func drawnWindow(_ s: TravelState.Seat, dir: String?, n: Int = windows) -> Int? {
        guard let v = valid(s) else { return nil }
        // (rounded up, in whole numbers)
        let w: Int = v.of == n ? v.w : max(1, min(n, (v.w * n + v.of - 1) / v.of))
        return drawnWindow(w, of: n, dir: dir)
    }

    // MARK: words

    /// "1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st".
    static func ordinal(_ n: Int) -> String {
        let tens: Int = (n / 10) % 10
        if tens == 1 { return "\(n)th" }
        switch n % 10 {
        case 1: return "\(n)st"
        case 2: return "\(n)nd"
        case 3: return "\(n)rd"
        default: return "\(n)th"
        }
    }

    /// "upper deck · 8th window from the back", "6th window from the back", "8th window from the left".
    static func seatWords(_ s: TravelState.Seat, front: Bool) -> String {
        let end: String = front ? "from the back" : "from the left"
        let win = "\(ordinal(s.w)) window \(end)"
        return deck(s).words.map { "\($0) · \(win)" } ?? win
    }

    /// "Coach 3 of 6 · upper deck · 8th window from the back"; without a seat 0.26's "Coach 3 of 6 · front".
    /// (0.31.1) `firstClass`: it's in 1st class (worked out from the train, never sent): "… · 1st class".
    static func label(_ c: TravelState.Coach, firstClass: Bool = false) -> String {
        let tail: String = firstClass ? " · 1st class" : ""
        guard let s = valid(c.seat) else { return CoachMap.label(c) + tail }
        return "Coach \(c.n) of \(c.of) · \(seatWords(s, front: c.front))\(tail)"
    }

    /// For VoiceOver: "Coach 3, upper deck, window 8 from the back".
    static func spoken(coach n: Int, deck: Deck, window w: Int, front: Bool) -> String {
        let end: String = front ? "from the back" : "from the left"
        let d: String = deck.words.map { ", \($0)" } ?? ""
        return "Coach \(n)\(d), window \(w) \(end)"
    }

    /// For VoiceOver, a coach: "Coach 3 of 6, from the front, two decks" (0.31.1: ", 1st class" all through, ", part
    /// 1st class" for a part).
    static func spokenCoach(_ c: Coach, of total: Int) -> String {
        let from: String = c.front ? ", from the front" : ""
        let cls: String
        switch c.kind {
        case .first?: cls = ", 1st class"
        case .part?: cls = ", part 1st class"
        default: cls = ""
        }
        return "Coach \(c.n) of \(total)\(from)\(c.double ? ", two decks" : "")\(cls)"
    }
}
