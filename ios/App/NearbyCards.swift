import Foundation

// 0.42.15: the stops on "Fastest trip, zoomed out" as mini cards (design M4b): a small dot at the stop and a card by
// it with its line, "leave 10:41 · 9 min walk", "arrive 12:07", how sure, and the tags: FASTEST (gold) and SUREST
// (green), both on one card when one way is both. The rules here are plain values, tested in `NearbyCardsTests`
// against docs/nearby-cards-vectors.json (Android has the same: `travel/NearbyCards.kt`, `NearbyCardsTest`).
// Foundation only.

enum NearbyCards {
    // MARK: the tags

    /// A stop's tags on the map and in the list: Fastest, Surest, or both.
    struct Badge: Equatable, Sendable {
        var fastest = false
        var surest = false
        var tagged: Bool { fastest || surest }
        var tags: [Nearby.Tag] { (fastest ? [Nearby.Tag.fastest] : []) + (surest ? [Nearby.Tag.surest] : []) }
    }

    /// The tags of the ranked ways (`Nearby.tags`: Fastest the earliest there by live times, Surest the most on time
    /// at `Nearby.surestAt` % at least, the fastest itself when it's as sure). "Slower" isn't shown any more.
    static func badges(_ options: [Nearby.Option]) -> [String: Badge] {
        var out: [String: Badge] = [:]
        for (id, tags) in Nearby.tags(options) {
            let b = Badge(fastest: tags.contains(.fastest), surest: tags.contains(.surest))
            if b.tagged { out[id] = b }
        }
        return out
    }

    /// A card's edge and its walk line: green when it's the surest, gold when only the fastest, grey else.
    enum Edge: String, Equatable, Sendable { case surest, fastest, plain }

    static func edge(_ b: Badge?) -> Edge {
        guard let b else { return .plain }
        if b.surest { return .surest }
        return b.fastest ? .fastest : .plain
    }

    /// The edge's colour (0xRRGGBB): green, gold, grey.
    static func color(_ e: Edge) -> UInt32 {
        switch e {
        case .surest: return 0x3DD598
        case .fastest: return 0xE8A33D
        case .plain: return 0x8A9099
        }
    }

    /// The edge's width (points): thicker for a tagged one.
    static func edgeWidth(_ e: Edge) -> Double { e == .plain ? 1.5 : 2.5 }

    /// The walk line from you to the stop: solid in its colour when tagged, dashed grey else.
    static func walkDashed(_ e: Edge) -> Bool { e == .plain }

    /// In a stop's sheet, the departure tagged Surest: the most on time (the earlier on a tie) at `Nearby.surestAt`
    /// % at least; the one there first (`fastest`) itself when it's as sure, so one departure can be both.
    static func surestBoth(_ percents: [Int], fastest: Int) -> Int? {
        guard percents.indices.contains(fastest), let top = percents.indices.max(by: { a, b in
            percents[a] != percents[b] ? percents[a] < percents[b] : a > b
        }) else { return nil }
        let p: Int = percents[top]
        guard p >= Nearby.surestAt else { return nil }
        return percents[fastest] >= p ? fastest : top
    }

    // MARK: the words (never the walking emoji)

    /// "leave 10:41 · 9 min walk".
    static func leaveWords(_ time: String, walk: Int) -> String { "leave \(time) · " + walkWords(walk) }

    /// "9 min walk".
    static func walkWords(_ walk: Int) -> String { "\(max(0, walk)) min walk" }

    /// "92% on time".
    static func onTimeWords(_ s: Nearby.Sure) -> String { "\(s.percent)% on time" }

    /// "estimate" when the % isn't from your own rides.
    static func estimateWord(_ s: Nearby.Sure) -> String? {
        if case .yours = s.source { return nil }
        return "estimate"
    }

    // MARK: the cards on the map, never on top of anything

    /// A point or a box on the screen (points, y down).
    struct Point: Equatable, Sendable {
        var x: Double
        var y: Double
    }

    struct Rect: Equatable, Sendable {
        var x: Double
        var y: Double
        var w: Double
        var h: Double
        var maxX: Double { x + w }
        var maxY: Double { y + h }

        /// Closer than `pad` to `o` (or on it).
        func touches(_ o: Rect, pad: Double) -> Bool {
            x < o.maxX + pad && o.x < maxX + pad && y < o.maxY + pad && o.y < maxY + pad
        }

        func contains(_ p: Point) -> Bool { p.x >= x && p.x <= maxX && p.y >= y && p.y <= maxY }

        /// Whether the line from `a` to `b` goes through the box (Liang–Barsky).
        func crossed(_ a: Point, _ b: Point) -> Bool {
            let dx: Double = b.x - a.x, dy: Double = b.y - a.y
            var t0: Double = 0, t1: Double = 1
            let ps: [Double] = [-dx, dx, -dy, dy]
            let qs: [Double] = [a.x - x, maxX - a.x, a.y - y, maxY - a.y]
            for k in 0..<4 {
                if ps[k] == 0 {
                    if qs[k] < 0 { return false }
                    continue
                }
                let t: Double = qs[k] / ps[k]
                if ps[k] < 0 { t0 = max(t0, t) } else { t1 = min(t1, t) }
                if t0 > t1 { return false }
            }
            return true
        }

        /// The point of the box nearest to `p`.
        func nearest(_ p: Point) -> Point { Point(x: min(max(p.x, x), maxX), y: min(max(p.y, y), maxY)) }
    }

    /// A stop to show: where its dot is, and whether its card has the tags row.
    struct Item: Equatable, Sendable {
        let id: String
        let at: Point
        let tagged: Bool
    }

    enum Kind: String, Equatable, Sendable { case card, pill, hidden }

    /// Where a stop's card (or pill, "12:31") goes; `leader`: the point of it a line is drawn from to the dot, when it
    /// isn't right by it.
    struct Placed: Equatable, Sendable {
        let id: String
        let kind: Kind
        let rect: Rect
        let leader: Point?
    }

    static let cardWidth = 196.0
    static let cardHeight = 58.0            // line, leave, arrive and the %
    static let taggedHeight = 76.0          // and the tags row
    static let pillWidth = 56.0
    static let pillHeight = 26.0
    /// Between a card and its dot (its dot, and the room around it, stay clear).
    static let gap = 12.0
    /// The room kept between a card and anything else.
    static let pad = 4.0
    /// A stop's dot, and you (with the halo), as round as they're drawn.
    static let dotRadius = 7.0
    static let youRadius = 20.0
    /// From this many on, a stop gets a pill straight away (the map stays readable: Miller, Hick).
    static let maxCards = 4
    /// A leader line is never longer than this (a card that far off isn't clearly its stop's).
    static let maxLeader = 120.0

    /// The spots tried for a box `w` x `h` by a dot, as its top-left corner from the dot: above, below, the four
    /// diagonals, the sides, then one to three steps further up and down.
    static func offsets(w: Double, h: Double) -> [Point] {
        let g: Double = gap
        var out: [Point] = [Point(x: -w / 2, y: -g - h), Point(x: -w / 2, y: g),
                            Point(x: g, y: -g - h), Point(x: -w - g, y: -g - h),
                            Point(x: g, y: g), Point(x: -w - g, y: g),
                            Point(x: g, y: -h / 2), Point(x: -w - g, y: -h / 2)]
        for k in 1...3 {
            let s: Double = Double(k) * (h + g)
            out += [Point(x: -w / 2, y: -g - h - s), Point(x: -w / 2, y: g + s),
                    Point(x: g, y: -g - h - s), Point(x: -w - g, y: -g - h - s),
                    Point(x: g, y: g + s), Point(x: -w - g, y: g + s)]
        }
        return out
    }

    /// `r` moved inside `b` (to its left/top edge when it's wider).
    static func clamp(_ r: Rect, in b: Rect) -> Rect {
        let x: Double = r.w >= b.w ? b.x : min(max(r.x, b.x), b.maxX - r.w)
        let y: Double = r.h >= b.h ? b.y : min(max(r.y, b.y), b.maxY - r.h)
        return Rect(x: x, y: y, w: r.w, h: r.h)
    }

    private static func box(_ p: Point, _ r: Double) -> Rect { Rect(x: p.x - r, y: p.y - r, w: 2 * r, h: 2 * r) }

    /// The cards of `items` (most important first: `Nearby.ordered`) inside `bounds` (the map less its buttons and
    /// the sheet over it), each at the first spot (`offsets`, kept inside) that's clear of every card and pill placed
    /// before, of you (`you`) and of every dot (the stops', and `dots`, the others drawn), by `pad`. From `maxCards`
    /// on, or when no card fits, a pill; when no pill fits either (or the dot is off the map), none: its dot stays,
    /// and it's in the list. A spot not right by its dot gets a leader line, at most `maxLeader` long, through no
    /// other card or pill; and no card goes over a leader line drawn before.
    static func layout(_ items: [Item], bounds: Rect, you: Point?, dots: [Point] = []) -> [Placed] {
        var blocks: [Rect] = []
        if let you { blocks.append(box(you, youRadius)) }
        for p in dots { blocks.append(box(p, dotRadius)) }
        for i in items { blocks.append(box(i.at, dotRadius)) }
        var placed: [Rect] = []
        var leaders: [(Point, Point)] = []
        var out: [Placed] = []
        for (n, item) in items.enumerated() {
            guard bounds.contains(item.at) else {
                out.append(Placed(id: item.id, kind: .hidden, rect: Rect(x: item.at.x, y: item.at.y, w: 0, h: 0), leader: nil))
                continue
            }
            var tries: [(Kind, Double, Double)] = []
            if n < maxCards { tries.append((.card, cardWidth, item.tagged ? taggedHeight : cardHeight)) }
            tries.append((.pill, pillWidth, pillHeight))
            var done = false
            for (kind, w, h) in tries where !done {
                for o in offsets(w: w, h: h) {
                    let r: Rect = clamp(Rect(x: item.at.x + o.x, y: item.at.y + o.y, w: w, h: h), in: bounds)
                    if blocks.contains(where: { r.touches($0, pad: pad) }) { continue }
                    if placed.contains(where: { r.touches($0, pad: pad) }) { continue }
                    if leaders.contains(where: { r.crossed($0.0, $0.1) }) { continue }
                    let near: Point = r.nearest(item.at)
                    let dx: Double = near.x - item.at.x, dy: Double = near.y - item.at.y
                    let length: Double = (dx * dx + dy * dy).squareRoot()
                    let far: Bool = length > gap + 0.5
                    if far && length > maxLeader { continue }
                    if far && placed.contains(where: { $0.crossed(near, item.at) }) { continue }
                    if far { leaders.append((near, item.at)) }
                    placed.append(r)
                    out.append(Placed(id: item.id, kind: kind, rect: r, leader: far ? near : nil))
                    done = true
                    break
                }
            }
            if !done {
                out.append(Placed(id: item.id, kind: .hidden, rect: Rect(x: item.at.x, y: item.at.y, w: 0, h: 0), leader: nil))
            }
        }
        return out
    }
}
