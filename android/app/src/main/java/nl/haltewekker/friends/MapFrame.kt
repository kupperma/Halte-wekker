package nl.haltewekker.friends

import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min

// Friends (A5, iOS 0.31 `MapFrame.swift`): what the Friends map and a friend's map frame, and the bit of a route they
// draw. Plain values, tested without MapLibre.
//
// (iOS 0.31's fix, kept here from the start) The camera is never left to the map's default: the region is worked out
// from the friend's position and the trip's from and to, and set every time they (or the map's size) change.

object MapFrame {
    /** A region: its middle and how many degrees it spans. */
    data class Region(val lat: Double, val lon: Double, val latDelta: Double, val lonDelta: Double) {
        fun contains(p: GeoPoint): Boolean =
            abs(p.lat - lat) <= latDelta / 2 + 1e-9 && abs(p.lon - lon) <= lonDelta / 2 + 1e-9

        val south: Double get() = lat - latDelta / 2
        val north: Double get() = lat + latDelta / 2
        val west: Double get() = lon - lonDelta / 2
        val east: Double get() = lon + lonDelta / 2
    }

    /** A point worth framing: a real coordinate (finite, on the globe, not 0,0, which is what a missing one decodes to). */
    fun valid(p: GeoPoint): Boolean =
        p.lat.isFinite() && p.lon.isFinite() && abs(p.lat) <= 90 && abs(p.lon) <= 180 && !(abs(p.lat) < 1e-6 && abs(p.lon) < 1e-6)

    fun point(lat: Double?, lon: Double?): GeoPoint? {
        if (lat == null || lon == null) return null
        val p = GeoPoint(lat, lon)
        return if (valid(p)) p else null
    }

    /** What a friend's map frames: where they are, where they got on and where they get off (whichever are known). */
    fun points(s: TravelState): List<GeoPoint> = listOfNotNull(
        s.pos?.let { point(it.lat, it.lon) },
        point(s.from.lat, s.from.lon),
        point(s.to.lat, s.to.lon),
    )

    /**
     * The region that shows every point in the part of the map a sheet leaves free: `aspect` is the map's height over
     * its width, `cover` the share of its height a sheet hides at the bottom (0…0.9). `pad` adds room around the
     * points; `minMetres` keeps one point (or two close ones) from zooming in to a street. Null: no point.
     */
    fun fit(points: List<GeoPoint>, aspect: Double, cover: Double = 0.0, pad: Double = 1.35, minMetres: Double = 1600.0): Region? {
        val pts = points.filter(::valid)
        val first = pts.firstOrNull() ?: return null
        var minLat = first.lat; var maxLat = first.lat; var minLon = first.lon; var maxLon = first.lon
        for (p in pts.drop(1)) {
            minLat = min(minLat, p.lat); maxLat = max(maxLat, p.lat)
            minLon = min(minLon, p.lon); maxLon = max(maxLon, p.lon)
        }
        val midLat = (minLat + maxLat) / 2
        val midLon = (minLon + maxLon) / 2
        val k = max(0.05, cos(midLat * Math.PI / 180))
        val minDeg = minMetres / 111_320
        // the points' box with room, in degrees of latitude (north-south) and of longitude
        val spanLat = max(minDeg, (maxLat - minLat) * pad)
        val spanLon = max(minDeg / k, (maxLon - minLon) * pad)
        val free = 1 - min(0.9, max(0.0, cover))
        val a = if (aspect.isFinite() && aspect > 0) aspect else 1.0
        // the whole map's height in degrees: the box in the free part, and wide enough for its width
        val latDelta = min(170.0, max(spanLat / free, spanLon * k * a))
        val lonDelta = min(350.0, latDelta / (k * a))
        // the free part's middle is `cover / 2` of the map's height above the map's middle
        val lat = midLat - latDelta * (1 - free) / 2
        return Region(lat, midLon, latDelta, lonDelta)
    }

    // MARK: the route

    /** The nearest point of `path` to `p` from `start` on (its index). */
    fun nearest(path: List<GeoPoint>, p: GeoPoint, start: Int = 0): Int? {
        if (start >= path.size) return null
        var best = start
        var d = Double.MAX_VALUE
        for (i in start until path.size) {
            val m = Geo.metres(path[i], p)
            if (m < d) { d = m; best = i }
        }
        return best
    }

    /**
     * The bit of a vehicle's whole route a friend rides: from where they got on to where they get off. Without a route
     * (fewer than two points): a straight line from where they got on, through where they are, to where they get off.
     */
    fun route(s: TravelState, path: List<GeoPoint>): List<GeoPoint> {
        val from = point(s.from.lat, s.from.lon)
        val to = point(s.to.lat, s.to.lon)
        val shape = path.filter(::valid)
        if (shape.size >= 2) {
            val i = from?.let { nearest(shape, it) } ?: 0
            val j = to?.let { nearest(shape, it, i) } ?: (shape.size - 1)
            if (j > i) return shape.subList(i, j + 1).toList()
        }
        val out = listOfNotNull(from, s.pos?.let { point(it.lat, it.lon) }, to)
        return if (out.size >= 2) out else emptyList()
    }
}
