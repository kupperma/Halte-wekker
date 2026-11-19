package nl.haltewekker.core

import kotlinx.serialization.Serializable
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/** A place on the map, in degrees (as iOS `GeoPoint`). */
@Serializable
data class GeoPoint(val lat: Double, val lon: Double)

/**
 * Distances, directions and positions along a road on a flat earth (good to well under a metre over the few
 * kilometres matching looks at). A port of iOS `Geo.swift`, number for number.
 */
object Geo {
    private const val KY = 110_540.0
    private fun kx(lat: Double) = cos(lat * Math.PI / 180) * 111_320

    fun metres(a: GeoPoint, b: GeoPoint): Double {
        val dx = (b.lon - a.lon) * kx(a.lat)
        val dy = (b.lat - a.lat) * KY
        return sqrt(dx * dx + dy * dy)
    }

    /** 0 is north, 90 east, in 0 until 360. */
    fun bearing(a: GeoPoint, b: GeoPoint): Double {
        val dx = (b.lon - a.lon) * cos(a.lat * Math.PI / 180)
        val dy = b.lat - a.lat
        return (Math.toDegrees(atan2(dx, dy)) + 360) % 360
    }

    fun length(path: List<GeoPoint>): Double {
        if (path.size < 2) return 0.0
        var total = 0.0
        for (i in 1 until path.size) total += metres(path[i - 1], path[i])
        return total
    }

    data class Projection(val crossTrack: Double, val along: Double, val fraction: Double, val bearing: Double)
    data class Pass(val projection: Projection, val segment: Int, val beforeStart: Boolean, val beyondEnd: Boolean)

    fun project(p: GeoPoint, path: List<GeoPoint>): Projection? = pass(p, path, null, 0.0)?.projection

    /** See iOS `Geo.pass`: of the passes within `within` of the nearest, the one closest to `near` (then `previous`). */
    fun pass(p: GeoPoint, path: List<GeoPoint>, near: Double?, within: Double, previous: Double? = null): Pass? {
        val all = passes(p, path)
        val nearest = all.minOfOrNull { it.projection.crossTrack } ?: return null
        val close = all.filter { it.projection.crossTrack <= nearest + max(0.0, within) }
        if (near == null || !near.isFinite()) return close.firstOrNull { it.projection.crossTrack == nearest }
        val off = close.map { abs(it.projection.along - near) }
        val best = off.minOrNull() ?: return null
        val tied = close.filterIndexed { i, _ -> off[i] <= best + 1 }
        fun byPrevious(x: Pass) = previous?.let { abs(x.projection.along - it) } ?: 0.0
        return tied.minWithOrNull { a, b ->
            val pa = byPrevious(a)
            val pb = byPrevious(b)
            if (pa != pb) pa.compareTo(pb) else a.projection.crossTrack.compareTo(b.projection.crossTrack)
        }
    }

    private class Foot(val d: Double, val along: Double, val u: Double, val seg: Int)

    /** Every place `path` passes `p`, in path order (iOS `Geo.passes`). */
    fun passes(p: GeoPoint, path: List<GeoPoint>): List<Pass> {
        if (path.size < 2 || !p.lat.isFinite() || !p.lon.isFinite()) return emptyList()
        val lens = ArrayList<Double>(path.size)
        var total = 0.0
        for (i in 1 until path.size) {
            val l = metres(path[i - 1], path[i]); lens.add(l); total += l
        }
        if (!(total > 0) || !total.isFinite()) return emptyList()
        val sx = kx(p.lat)
        val sy = KY
        val feet = ArrayList<Foot>()
        var acc = 0.0
        for (i in 1 until path.size) {
            val start = acc
            acc += lens[i - 1]
            val ax = (path[i - 1].lon - p.lon) * sx
            val ay = (path[i - 1].lat - p.lat) * sy
            val bx = (path[i].lon - p.lon) * sx
            val by = (path[i].lat - p.lat) * sy
            val dx = bx - ax
            val dy = by - ay
            val l2 = dx * dx + dy * dy
            if (!(l2 > 0)) continue
            val u = max(0.0, min(1.0, -(ax * dx + ay * dy) / l2))
            val px = ax + u * dx
            val py = ay + u * dy
            val d = sqrt(px * px + py * py)
            if (!d.isFinite()) continue
            feet.add(Foot(d, start + u * lens[i - 1], u, i - 1))
        }
        fun made(k: Int): Pass {
            val f = feet[k]
            return Pass(
                Projection(f.d, f.along, min(1.0, max(0.0, f.along / total)), bearing(path[f.seg], path[f.seg + 1])),
                f.seg, k == 0 && f.u <= 0, k == feet.size - 1 && f.u >= 1,
            )
        }
        val out = ArrayList<Pass>()
        for (k in feet.indices) {
            val f = feet[k]
            val isPass = if (f.u <= 0) (k == 0 || feet[k - 1].u >= 1) else if (f.u >= 1) k == feet.size - 1 else true
            if (isPass) out.add(made(k))
        }
        if (out.isEmpty() && feet.isNotEmpty()) out.add(made(feet.indices.minBy { feet[it].d }))
        return out
    }

    fun pointAtMetres(m: Double, path: List<GeoPoint>): GeoPoint? {
        val first = path.firstOrNull() ?: return null
        var want = if (m.isNaN()) 0.0 else m
        if (want <= 0) return first
        for (i in 1 until path.size) {
            val a = path[i - 1]
            val b = path[i]
            val l = metres(a, b)
            if (want <= l) {
                if (!(l > 0)) return b
                val u = want / l
                return GeoPoint(a.lat + (b.lat - a.lat) * u, a.lon + (b.lon - a.lon) * u)
            }
            want -= l
        }
        return path.last()
    }

    /** Degrees between two headings (0 to 180). */
    fun angle(a: Double, b: Double): Double {
        var t = abs(a - b) % 360
        if (t > 180) t = 360 - t
        return t
    }
}
