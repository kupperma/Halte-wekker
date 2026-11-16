import Foundation

/// The live buses and trains on the home map: when they may be asked for, and which to draw. Plain values, so the
/// gating is tested: only while the home is on screen and the app active, at most every 15 s, not zoomed out past a
/// town, not in Low Power Mode, not with the setting off; at most 60 drawn, the nearest to the middle of the map first.
enum VehiclePick {
    static let minZoom = 13.0
    static let interval: TimeInterval = 15
    static let maxDrawn = 60
    /// The box asked for never grows past this (half-spans in degrees), however far out the map is.
    static let maxHalfLat = 0.06
    static let maxHalfLon = 0.09

    struct Gate: Equatable {
        var enabled: Bool           // Settings → Map → Live vehicles
        var visible: Bool           // the home is on screen (not under Fastest trip, the ride, a full sheet)
        var active: Bool            // the app is in front
        var lowPower: Bool          // Low Power Mode
        var zoom: Double
    }

    /// Should vehicles be drawn at all now.
    static func shows(_ g: Gate) -> Bool { g.enabled && !g.lowPower && g.zoom >= minZoom }

    /// May the map ask for them now (`last`: when it last asked).
    static func mayAsk(_ g: Gate, last: Date?, now: Date) -> Bool {
        guard shows(g), g.visible, g.active else { return false }
        return last.map { now.timeIntervalSince($0) >= interval } ?? true
    }

    struct Box: Equatable { let minLat: Double; let minLon: Double; let maxLat: Double; let maxLon: Double }

    /// The box to ask for: what's on screen, but never more than `maxHalfLat` by `maxHalfLon` around its middle.
    static func box(center: GeoPoint, latDelta: Double, lonDelta: Double) -> Box {
        let la = min(max(latDelta / 2, 0.005), maxHalfLat), lo = min(max(lonDelta / 2, 0.008), maxHalfLon)
        return Box(minLat: center.lat - la, minLon: center.lon - lo, maxLat: center.lat + la, maxLon: center.lon + lo)
    }

    /// The ones to draw: inside `box`, the nearest to `center` first, at most `limit`.
    static func nearest<V>(_ vs: [V], point: (V) -> GeoPoint, center: GeoPoint, box: Box, limit: Int = maxDrawn) -> [V] {
        let inside = vs.filter { v in
            let p = point(v)
            return p.lat >= box.minLat && p.lat <= box.maxLat && p.lon >= box.minLon && p.lon <= box.maxLon
        }
        return Array(inside.map { ($0, Geo.metres(center, point($0))) }.sorted { $0.1 < $1.1 }.prefix(limit).map(\.0))
    }
}
