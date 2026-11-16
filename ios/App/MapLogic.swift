import Foundation

/// The home map's rules, as plain numbers so they can be tested: how zoomed in it is, which tiles of stops to ask for
/// (and when), which stops to draw, and when the live vehicles may be asked for and which to draw.
enum MapZoom {
    /// The web-map zoom level for a span of longitude across a screen `width` points wide (15: streets, 13: a town).
    static func level(lonDelta: Double, width: Double = 390) -> Double {
        guard lonDelta > 0, width > 0 else { return 20 }
        return log2(360 * width / (256 * lonDelta))
    }
}

/// A tile of the stops on the map: a box about 2.7 by 2.6 km. Each is asked for once (`/v1/map/stops` for its box) and
/// kept for a while, so panning back and forth asks nothing again.
struct StopTile: Hashable, Sendable {
    let x: Int      // along longitude
    let y: Int      // along latitude
}

enum StopTiles {
    /// The box `Transit.nearStopsAnswer` asks around a point (±0.012° lat, ±0.019° lon): one tile.
    static let latSize = 0.024
    static let lonSize = 0.038
    /// Fewer stops than this zoom: none asked (a town or more on screen: too many to be useful, and a lot to download).
    static let minZoom = 13.0
    /// At most this often a new look at the map's stops, after the camera stops moving.
    static let minInterval: TimeInterval = 20
    /// A tile's stops are kept this long.
    static let ttl: TimeInterval = 6 * 3600

    static func tile(lat: Double, lon: Double) -> StopTile {
        StopTile(x: Int((lon / lonSize).rounded(.down)), y: Int((lat / latSize).rounded(.down)))
    }

    static func center(_ t: StopTile) -> GeoPoint {
        GeoPoint(lat: (Double(t.y) + 0.5) * latSize, lon: (Double(t.x) + 0.5) * lonSize)
    }

    /// The tiles a box on screen covers, the ones nearest its centre first, at most `limit`.
    static func covering(minLat: Double, minLon: Double, maxLat: Double, maxLon: Double, limit: Int = 6) -> [StopTile] {
        guard minLat <= maxLat, minLon <= maxLon else { return [] }
        let a = tile(lat: minLat, lon: minLon), b = tile(lat: maxLat, lon: maxLon)
        guard (b.x - a.x + 1) * (b.y - a.y + 1) <= 400 else { return [] }
        let mid = GeoPoint(lat: (minLat + maxLat) / 2, lon: (minLon + maxLon) / 2)
        var all: [StopTile] = []
        for y in a.y...b.y { for x in a.x...b.x { all.append(StopTile(x: x, y: y)) } }
        return Array(all.sorted { Geo.metres(mid, center($0)) < Geo.metres(mid, center($1)) }.prefix(limit))
    }

    /// The tiles of `wanted` to ask for now: never asked, or asked longer than `ttl` ago.
    static func due(_ wanted: [StopTile], asked: [StopTile: Date], now: Date) -> [StopTile] {
        wanted.filter { t in asked[t].map { now.timeIntervalSince($0) > ttl } ?? true }
    }

    /// May the map look for stops now: zoomed in enough, the screen visible, and the last look `minInterval` ago.
    static func mayLook(zoom: Double, visible: Bool, last: Date?, now: Date) -> Bool {
        guard visible, zoom >= minZoom else { return false }
        return last.map { now.timeIntervalSince($0) >= minInterval } ?? true
    }
}

/// Which stops the map draws at a zoom: stations from a town's view in, bus stops only close in (names closer still),
/// the nearest to the middle first, at most `maxStops` bus stops.
enum MapStopsDraw {
    static let stationZoom = 11.0
    static let stopZoom = 14.0
    static let nameZoom = 15.3
    static let maxStops = 80

    struct Pick: Equatable { let ids: [String]; let names: Bool }

    static func pick<S>(_ stops: [S], id: (S) -> String, point: (S) -> GeoPoint, rail: (S) -> Bool,
                        center: GeoPoint, zoom: Double) -> Pick {
        let stations = zoom >= stationZoom ? stops.filter(rail) : []
        let buses = zoom >= stopZoom
            ? Array(stops.filter { !rail($0) }.sorted { Geo.metres(center, point($0)) < Geo.metres(center, point($1)) }.prefix(maxStops))
            : []
        var seen = Set<String>(), ids: [String] = []
        for s in stations + buses where seen.insert(id(s)).inserted { ids.append(id(s)) }
        return Pick(ids: ids, names: zoom >= nameZoom)
    }
}
