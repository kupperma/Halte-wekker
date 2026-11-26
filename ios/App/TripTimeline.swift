import Foundation

/// The whole trip as a line on a time axis (0.42, from concept N4), for the next departures from a stop on "Fastest
/// trip, zoomed out": the walk from you to the stop, the wait, each ride in its line's colour, the walk and wait of a
/// change, the walk at the end, with the times at the ends and the change stations named. Every row shares one axis.
/// Plain values, so the layout is tested; Foundation only. Drawn in NearbyDetail.swift.
enum TripTimeline {
    enum Kind: String, Equatable, Sendable { case walk, wait, ride }

    /// One ride of a trip, as the timeline takes it.
    struct Leg: Equatable, Sendable {
        let line: String
        let train: Bool
        let live: Bool
        let departure: Date
        let arrival: Date
        let from: String            // where you get on (a change station after the first)
        let walkBefore: Int         // minutes of walking before it (the first: from you)
    }

    struct Part: Equatable, Sendable {
        let kind: Kind
        let start: Date
        let end: Date
        var line: String = ""
        var train = false
        var live = false
    }

    /// A trip's parts in order: walk, wait, ride, (walk, wait, ride)…, walk to the door. `leave`: when you set off;
    /// `end`: when you're there. Parts shorter than half a minute are left out; nothing runs backwards.
    static func parts(leave: Date, legs: [Leg], end: Date) -> [Part] {
        var out: [Part] = []
        var t: Date = leave
        func add(_ k: Kind, _ to: Date, _ l: Leg? = nil) {
            let e: Date = max(t, to)
            if e.timeIntervalSince(t) >= 30 {
                var p = Part(kind: k, start: t, end: e)
                if let l { p.line = l.line; p.train = l.train; p.live = l.live }
                out.append(p)
            }
            t = e
        }
        for l in legs {
            let walked: Date = min(t.addingTimeInterval(Double(max(0, l.walkBefore)) * 60), l.departure)
            add(.walk, walked)
            add(.wait, l.departure)
            add(.ride, l.arrival, l)
        }
        add(.walk, end)
        return out
    }

    /// The shared axis: from the earliest start to the latest end, out to whole `roundTo` minutes, at least `minSpan`.
    struct Axis: Equatable, Sendable {
        let start: Date
        let end: Date

        var span: TimeInterval { max(60, end.timeIntervalSince(start)) }

        /// Where a time sits on it (0…1).
        func at(_ d: Date) -> Double {
            let f: Double = d.timeIntervalSince(start) / span
            return f.isFinite ? min(1, max(0, f)) : 0
        }

        /// The tick marks on an axis `width` points wide: the start and the end always, and between them every
        /// `tickStep` minutes, none closer than `tickSpacing` to another (0.42.2: an axis from 23:30 to 06:00 had its
        /// times every 30 minutes on top of each other).
        func ticks(width: Double) -> [Date] {
            let w: Double = width.isFinite && width > 0 ? width : 320
            let step: Double = TripTimeline.tickStep(span: span, width: w) * 60
            let room: Double = TripTimeline.tickSpacing / w * span          // seconds between two labels, at least
            var out: [Date] = [start]
            var t: Double = (start.timeIntervalSince1970 / step).rounded(.up) * step
            let e: Double = end.timeIntervalSince1970
            while t < e {
                let last: Double = out[out.count - 1].timeIntervalSince1970
                if t - last >= room && e - t >= room { out.append(Date(timeIntervalSince1970: t)) }
                t += step
            }
            if e - start.timeIntervalSince1970 >= room { out.append(end) }
            return out
        }
    }

    /// The steps the ticks may take (minutes), and the least room between two of their labels (points).
    static let tickSteps: [Double] = [10, 15, 30, 60, 120, 180, 360]
    static let tickSpacing = 56.0

    /// The smallest step whose labels are at least `tickSpacing` apart on an axis of `span` seconds, `width` points.
    static func tickStep(span: TimeInterval, width: Double) -> Double {
        let perMinute: Double = width / max(60, span) * 60          // points per minute
        for m in tickSteps where m * perMinute >= tickSpacing { return m }
        return tickSteps[tickSteps.count - 1]
    }

    static let roundTo = 5.0                // minutes
    static let minSpan = 20.0               // minutes

    static func axis(_ rows: [[Part]]) -> Axis? {
        let starts: [Date] = rows.compactMap { $0.first?.start }
        let ends: [Date] = rows.compactMap { $0.last?.end }
        guard let a = starts.min(), let b = ends.max() else { return nil }
        let r: Double = roundTo * 60
        let s: Double = (a.timeIntervalSince1970 / r).rounded(.down) * r
        var e: Double = (b.timeIntervalSince1970 / r).rounded(.up) * r
        if e - s < minSpan * 60 { e = s + minSpan * 60 }
        return Axis(start: Date(timeIntervalSince1970: s), end: Date(timeIntervalSince1970: e))
    }

    /// A part on the axis: where it starts and how wide (fractions of the axis; at least `minWidth` so it shows).
    struct Placed: Equatable, Sendable {
        let part: Part
        let x: Double
        let width: Double
    }
    static let minWidth = 0.01

    static func place(_ parts: [Part], on a: Axis) -> [Placed] {
        parts.map { p in
            let x: Double = a.at(p.start)
            let w: Double = max(minWidth, a.at(p.end) - x)
            return Placed(part: p, x: min(x, 1 - minWidth), width: min(w, 1 - min(x, 1 - minWidth)))
        }
    }

    // MARK: the labels

    enum Anchor: String, Equatable, Sendable { case leading, center, trailing }

    struct Label: Equatable, Sendable {
        let text: String
        let x: Double               // the point it names (0…1)
        let anchor: Anchor          // which side of it the text goes, to stay on the axis
    }

    /// Labels closer than this (a fraction of the axis) to the one before are left out.
    static let minGap = 0.16
    /// Near an end, a label hangs inwards.
    static let edge = 0.12

    static func anchor(_ x: Double) -> Anchor { x < edge ? .leading : x > 1 - edge ? .trailing : .center }

    /// The change stations, at the start of each ride after the first (the walk across before it: at its start),
    /// leaving out the ones too close to the one before (`minGap`) and to the trip's two end times (`ends`).
    static func changeLabels(_ legs: [Leg], parts: [Placed], ends: (Double, Double)?) -> [Label] {
        let rides: [Placed] = parts.filter { $0.part.kind == .ride }
        guard legs.count > 1, rides.count == legs.count else { return [] }
        var out: [Label] = []
        var last: Double = -1
        for i in 1..<legs.count {
            let x: Double = rides[i - 1].x + rides[i - 1].width          // where the ride before ends
            if x - last < minGap { continue }
            if let e = ends, abs(x - e.0) < minGap || abs(x - e.1) < minGap { continue }
            out.append(Label(text: legs[i].from, x: x, anchor: anchor(x)))
            last = x
        }
        return out
    }

    /// Where the two end times go, as the left edge of each (fractions of the row): when you set off at the row's
    /// start, when you're there at its end, both always (0.42.2: a short row lost its time to leave). Too close
    /// together for both inside, they move apart around the row's middle, and stay on the row. `label`: a time's
    /// width (points) on a row `width` points wide.
    struct Ends: Equatable, Sendable {
        let leave: Double
        let arrive: Double
    }
    static let timeWidth = 40.0
    static let labelRoom = 6.0

    static func ends(start: Double, end: Double, width: Double, label: Double = timeWidth) -> Ends {
        let w: Double = width.isFinite && width > 0 ? width : 320
        let lw: Double = min(0.5, label / w)
        let g: Double = labelRoom / w
        var a: Double = start
        var b: Double = end - lw
        if b < a + lw + g {
            let mid: Double = (start + end) / 2
            a = mid - lw - g / 2
            b = mid + g / 2
        }
        if a < 0 { b -= a; a = 0 }
        if b + lw > 1 { let over: Double = b + lw - 1; a -= over; b -= over }
        return Ends(leave: max(0, a), arrive: max(0, b))
    }

    // MARK: the minutes between (0.42.2)

    // "Could you add how many minutes are between my gaps": each walk and wait gets its minutes, each ride its own.

    enum Tone: String, Equatable, Sendable { case plain, tight, risky }

    /// A gap's minutes: centred on it, or under the bar (`below`, with a tick, in row `lane`) when it's too narrow.
    struct GapLabel: Equatable, Sendable {
        let text: String
        let x: Double               // the label's centre (0…1)
        let below: Bool
        let lane: Int
        let tone: Tone
    }

    /// A change shorter than this is a risky one.
    static let riskyChange = 3.0

    /// About how wide a label is (points): a digit or letter 6.5, anything wider 14.
    static func textWidth(_ s: String) -> Double {
        var w: Double = 6
        for ch in s { w += ch.isASCII ? 6.5 : 14 }
        return w
    }

    /// "2 walk", "3 walk + 5 wait", "6 min", "5 wait" (0.42.4: words, no walker emoji).
    static func gapText(walk: Int, wait: Int, change: Bool) -> String {
        if walk > 0 && wait > 0 { return "\(walk) walk + \(wait) wait" }
        if walk > 0 { return "\(walk) walk" }
        return change ? "\(wait) min" : "\(wait) wait"
    }

    /// The labels of a row's gaps (each run of walk and wait between the rides, and before the first and after the
    /// last): their minutes, centred on the gap when it fits (`width`: the row in points), else under the bar in the
    /// first of two rows where it overlaps nothing (left out when neither has room: never on top of another). A
    /// change shorter than `riskyChange` minutes is risky, one shorter than the time you need to change
    /// (`changeNeeds`, learned) tight.
    static func gapLabels(_ placed: [Placed], width: Double, changeNeeds: Double? = nil) -> [GapLabel] {
        let w: Double = width.isFinite && width > 0 ? width : 320
        var runs: [(from: Int, to: Int)] = []
        var i = 0
        while i < placed.count {
            if placed[i].part.kind == .ride { i += 1; continue }
            var j = i
            while j + 1 < placed.count && placed[j + 1].part.kind != .ride { j += 1 }
            runs.append((i, j))
            i = j + 1
        }
        var out: [GapLabel] = []
        var laneEnds: [Double] = [-1, -1]           // where each row under the bar is taken up to (fractions)
        for r in runs {
            var walk: TimeInterval = 0, wait: TimeInterval = 0
            for k in r.from...r.to {
                let d: TimeInterval = placed[k].part.end.timeIntervalSince(placed[k].part.start)
                if placed[k].part.kind == .walk { walk += d } else { wait += d }
            }
            let wm: Int = walk > 0 ? max(1, Int((walk / 60).rounded())) : 0
            let tm: Int = wait > 0 ? max(1, Int((wait / 60).rounded())) : 0
            guard wm + tm > 0 else { continue }
            let change: Bool = r.from > 0 && r.to < placed.count - 1
            let text: String = gapText(walk: wm, wait: tm, change: change)
            var tone: Tone = .plain
            if change {
                let total: Double = (walk + wait) / 60
                if total < riskyChange { tone = .risky } else if let need = changeNeeds, total < need { tone = .tight }
            }
            let x0: Double = placed[r.from].x
            let x1: Double = placed[r.to].x + placed[r.to].width
            let tw: Double = textWidth(text) / w
            let half: Double = tw / 2
            let centre: Double = min(max((x0 + x1) / 2, half), 1 - half)
            if (x1 - x0) * w >= textWidth(text) + 4 {
                out.append(GapLabel(text: text, x: centre, below: false, lane: 0, tone: tone))
                continue
            }
            let gap: Double = 4 / w
            guard let lane = laneEnds.indices.first(where: { laneEnds[$0] + gap <= centre - half }) else { continue }
            laneEnds[lane] = centre + half
            out.append(GapLabel(text: text, x: centre, below: true, lane: lane, tone: tone))
        }
        return out
    }

    /// A ride's own minutes inside its bar ("41 min"), when they fit: the index of the part and the text.
    struct RideLabel: Equatable, Sendable {
        let index: Int
        let text: String
    }

    static func rideLabels(_ placed: [Placed], width: Double) -> [RideLabel] {
        let w: Double = width.isFinite && width > 0 ? width : 320
        var out: [RideLabel] = []
        for (i, p) in placed.enumerated() where p.part.kind == .ride {
            let m: Int = max(1, Int((p.part.end.timeIntervalSince(p.part.start) / 60).rounded()))
            let text: String = "\(m) min"
            if p.width * w >= textWidth(text) + 8 { out.append(RideLabel(index: i, text: text)) }
        }
        return out
    }
}
