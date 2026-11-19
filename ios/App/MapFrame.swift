import Foundation

// Friends (0.31): what the Friends map and a friend's map frame, and the bit of a route they draw. Plain values, tested
// without MapKit. Foundation only.
//
// (0.31's fix) A friend's page used to leave the camera to MapKit (`.automatic`), which frames the content once, as
// the map first gets it, and never again: assigning `.automatic` when it already is `.automatic` changes nothing, so
// a trip that came in (or moved) after that kept whatever the map showed first, and a map first laid out before its
// pins were there showed MapKit's own default region instead of the trip. Now the region is worked out here from the
// friend's position and the trip's from and to, and set every time they change.

enum MapFrame {
    /// A region: its middle and how many degrees it spans.
    struct Region: Equatable {
        var lat: Double
        var lon: Double
        var latDelta: Double
        var lonDelta: Double

        func contains(_ p: GeoPoint) -> Bool {
            abs(p.lat - lat) <= latDelta / 2 + 1e-9 && abs(p.lon - lon) <= lonDelta / 2 + 1e-9
        }
    }

    /// A point worth framing: a real coordinate (finite, on the globe, not 0,0, which is what a missing one decodes to).
    static func valid(_ p: GeoPoint) -> Bool {
        p.lat.isFinite && p.lon.isFinite && abs(p.lat) <= 90 && abs(p.lon) <= 180 && !(abs(p.lat) < 1e-6 && abs(p.lon) < 1e-6)
    }

    static func point(lat: Double?, lon: Double?) -> GeoPoint? {
        guard let lat, let lon else { return nil }
        let p = GeoPoint(lat: lat, lon: lon)
        return valid(p) ? p : nil
    }

    /// What a friend's map frames: where they are, where they got on and where they get off (whichever are known).
    static func points(_ s: TravelState) -> [GeoPoint] {
        var out: [GeoPoint] = []
        if let p = s.pos, let g = point(lat: p.lat, lon: p.lon) { out.append(g) }
        if let g = point(lat: s.from.lat, lon: s.from.lon) { out.append(g) }
        if let g = point(lat: s.to.lat, lon: s.to.lon) { out.append(g) }
        return out
    }

    /// The region that shows every point in the part of the map a sheet leaves free: `aspect` is the map's height over
    /// its width, `cover` the share of its height a sheet hides at the bottom (0…0.9). `pad` adds room around the
    /// points; `minMetres` keeps one point (or two close ones) from zooming in to a street. Nil: no point.
    static func fit(_ points: [GeoPoint], aspect: Double, cover: Double = 0, pad: Double = 1.35, minMetres: Double = 1600) -> Region? {
        let pts: [GeoPoint] = points.filter(valid)
        guard let first = pts.first else { return nil }
        var minLat = first.lat, maxLat = first.lat, minLon = first.lon, maxLon = first.lon
        for p in pts.dropFirst() {
            minLat = min(minLat, p.lat); maxLat = max(maxLat, p.lat)
            minLon = min(minLon, p.lon); maxLon = max(maxLon, p.lon)
        }
        let midLat: Double = (minLat + maxLat) / 2
        let midLon: Double = (minLon + maxLon) / 2
        let k: Double = max(0.05, cos(midLat * .pi / 180))
        let minDeg: Double = minMetres / 111_320
        // the points' box with room, in degrees of latitude (north-south) and of longitude
        let spanLat: Double = max(minDeg, (maxLat - minLat) * pad)
        let spanLon: Double = max(minDeg / k, (maxLon - minLon) * pad)
        let free: Double = 1 - min(0.9, max(0, cover))
        let a: Double = aspect.isFinite && aspect > 0 ? aspect : 1
        // the whole map's height in degrees: the box in the free part, and wide enough for its width
        let latDelta: Double = min(170, max(spanLat / free, spanLon * k * a))
        let lonDelta: Double = min(350, latDelta / (k * a))
        // the free part's middle is `cover / 2` of the map's height above the map's middle
        let lat: Double = midLat - latDelta * (1 - free) / 2
        return Region(lat: lat, lon: midLon, latDelta: latDelta, lonDelta: lonDelta)
    }

    // MARK: the route

    /// The nearest point of `path` to `p` from `start` on (its index).
    static func nearest(_ path: [GeoPoint], to p: GeoPoint, from start: Int = 0) -> Int? {
        guard start < path.count else { return nil }
        var best: Int = start
        var d: Double = .greatestFiniteMagnitude
        for i in start..<path.count {
            let m: Double = Geo.metres(path[i], p)
            if m < d { d = m; best = i }
        }
        return best
    }

    /// The bit of a vehicle's whole route a friend rides: from where they got on to where they get off. Without a
    /// route (fewer than two points): a straight line from where they got on, through where they are, to where they
    /// get off.
    static func route(_ s: TravelState, path: [GeoPoint]) -> [GeoPoint] {
        let from: GeoPoint? = point(lat: s.from.lat, lon: s.from.lon)
        let to: GeoPoint? = point(lat: s.to.lat, lon: s.to.lon)
        let shape: [GeoPoint] = path.filter(valid)
        if shape.count >= 2 {
            let i: Int = from.flatMap { nearest(shape, to: $0) } ?? 0
            let j: Int = to.flatMap { nearest(shape, to: $0, from: i) } ?? shape.count - 1
            if j > i { return Array(shape[i...j]) }
        }
        var out: [GeoPoint] = []
        if let from { out.append(from) }
        if let p = s.pos, let g = point(lat: p.lat, lon: p.lon) { out.append(g) }
        if let to { out.append(to) }
        return out.count >= 2 ? out : []
    }
}
