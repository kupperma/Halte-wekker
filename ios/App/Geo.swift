import Foundation

/// A place on the map, in degrees. Plain values, so the matching rules can be tested without CoreLocation.
struct GeoPoint: Hashable, Codable, Sendable {
    var lat: Double
    var lon: Double
}

/// Distances, directions and positions along a road, on a flat earth (good to well under a metre over the few
/// kilometres matching looks at).
enum Geo {
    /// Metres per degree of latitude.
    private static let ky = 110_540.0
    /// Metres per degree of longitude at a latitude.
    private static func kx(_ lat: Double) -> Double { cos(lat * .pi / 180) * 111_320 }

    /// Straight-line metres from `a` to `b` (east-west scaled at `a`'s latitude).
    static func metres(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let dx = (b.lon - a.lon) * kx(a.lat), dy = (b.lat - a.lat) * ky
        return (dx * dx + dy * dy).squareRoot()
    }

    /// The compass direction from `a` to `b`: 0 is north, 90 east, in 0..<360.
    static func bearing(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let dx = (b.lon - a.lon) * cos(a.lat * .pi / 180), dy = b.lat - a.lat
        return (atan2(dx, dy) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Metres along a path, point to point.
    static func length(_ path: [GeoPoint]) -> Double {
        guard path.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<path.count { total += metres(path[i - 1], path[i]) }
        return total
    }

    /// Where a point is beside a path: how far from it, how far along it (metres from its start, and 0 to 1), and which
    /// way the path runs there.
    struct Projection: Equatable {
        let crossTrack: Double
        let along: Double
        let fraction: Double
        let bearing: Double
    }

    /// One place where a path passes a point (the nearest spot of one stretch of it), and the segment it is on: the
    /// index of the segment's first point.
    struct Pass: Equatable {
        let projection: Projection
        let segment: Int
    }

    /// The nearest place on `path` to `p`. Nil for fewer than 2 points or a path of length 0.
    static func project(_ p: GeoPoint, on path: [GeoPoint]) -> Projection? {
        pass(p, on: path, near: nil, within: 0)?.projection
    }

    /// Where `path` passes `p`: when it passes more than once within `within` metres of the nearest pass (a road it
    /// comes in and goes out by, a there-and-back detour), the pass whose along-position is closest to `near`. Without
    /// `near`, the nearest. Nil for fewer than 2 points or a path of length 0.
    static func pass(_ p: GeoPoint, on path: [GeoPoint], near: Double?, within: Double) -> Pass? {
        let all = passes(p, on: path)
        guard let nearest = all.map({ $0.projection.crossTrack }).min() else { return nil }
        let close = all.filter { $0.projection.crossTrack <= nearest + max(0, within) }
        guard let near, near.isFinite else { return close.first { $0.projection.crossTrack == nearest } }
        return close.min { a, b in
            let da = abs(a.projection.along - near), db = abs(b.projection.along - near)
            return da != db ? da < db : a.projection.crossTrack < b.projection.crossTrack
        }
    }

    /// Every place `path` passes `p`, in path order: each spot where the distance to `p` is least for a stretch of the
    /// path (the foot of a perpendicular, a corner pointing at `p`, or an end it lies beyond).
    static func passes(_ p: GeoPoint, on path: [GeoPoint]) -> [Pass] {
        guard path.count >= 2, p.lat.isFinite, p.lon.isFinite else { return [] }
        var lens: [Double] = [], total = 0.0
        for i in 1..<path.count {
            let l = metres(path[i - 1], path[i])
            lens.append(l); total += l
        }
        guard total > 0, total.isFinite else { return [] }
        let sx = kx(p.lat), sy = ky
        var feet: [(d: Double, along: Double, u: Double, seg: Int)] = []
        var acc = 0.0
        for i in 1..<path.count {
            let start = acc
            acc += lens[i - 1]
            let ax = (path[i - 1].lon - p.lon) * sx, ay = (path[i - 1].lat - p.lat) * sy
            let bx = (path[i].lon - p.lon) * sx, by = (path[i].lat - p.lat) * sy
            let dx = bx - ax, dy = by - ay, l2 = dx * dx + dy * dy
            // A repeated point (where two pieces join) has no direction: its neighbours cover that spot.
            guard l2 > 0 else { continue }
            let u = max(0, min(1, -(ax * dx + ay * dy) / l2))
            let px = ax + u * dx, py = ay + u * dy, d = (px * px + py * py).squareRoot()
            guard d.isFinite else { continue }
            feet.append((d, start + u * lens[i - 1], u, i - 1))
        }
        func made(_ f: (d: Double, along: Double, u: Double, seg: Int)) -> Pass {
            Pass(projection: Projection(crossTrack: f.d, along: f.along, fraction: min(1, max(0, f.along / total)),
                                        bearing: bearing(path[f.seg], path[f.seg + 1])),
                 segment: f.seg)
        }
        var out: [Pass] = []
        for (k, f) in feet.enumerated() {
            // A stretch's nearest spot at its start counts only at the path's start or at a corner (the stretch before
            // ends there too); one at its end only at the path's end (the next stretch has it, or something nearer).
            let isPass = f.u <= 0 ? (k == 0 || feet[k - 1].u >= 1) : f.u >= 1 ? k == feet.count - 1 : true
            if isPass { out.append(made(f)) }
        }
        if out.isEmpty, let f = feet.min(by: { $0.d < $1.d }) { out.append(made(f)) }
        return out
    }

    /// The point `m` metres along `path`, clamped to its ends. Nil for an empty path.
    static func point(atMetres m: Double, on path: [GeoPoint]) -> GeoPoint? {
        guard let first = path.first else { return nil }
        var want = m.isNaN ? 0 : m
        guard want > 0 else { return first }
        for i in 1..<path.count {
            let a = path[i - 1], b = path[i], l = metres(a, b)
            if want <= l {
                guard l > 0 else { return b }
                let u = want / l
                return GeoPoint(lat: a.lat + (b.lat - a.lat) * u, lon: a.lon + (b.lon - a.lon) * u)
            }
            want -= l
        }
        return path.last
    }
}
