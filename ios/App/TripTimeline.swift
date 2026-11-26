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

        /// The tick marks: every 10 minutes up to 40 on the axis, 15 up to 90, else 30.
        var ticks: [Date] {
            let mins: Double = span / 60
            let step: Double = mins <= 40 ? 10 : mins <= 90 ? 15 : 30
            let s: Double = step * 60
            var t: Double = (start.timeIntervalSince1970 / s).rounded(.up) * s
            var out: [Date] = []
            while t <= end.timeIntervalSince1970 + 1 {
                out.append(Date(timeIntervalSince1970: t))
                t += s
            }
            return out
        }
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

    /// The two end times: when you set off (at the row's start) and when you're there (its end). Too close together:
    /// only the arrival.
    static func endLabels(start: Double, end: Double) -> (leave: Bool, arrive: Bool) {
        (end - start >= minGap * 1.5, true)
    }
}
