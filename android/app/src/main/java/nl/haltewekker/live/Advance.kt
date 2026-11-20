package nl.haltewekker.live

import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * (A6, iOS 0.34 `RealPositions` "putting it on its road" and "moving an old fix on") an old bus GPS fix moved on along
 * its road: at the speed it was seen going (its fix's own speed, else between its last two fixes 5–180 s apart, 0–46
 * m/s) for up to 120 s (else its timetable speed for 60 s); standing 10 s at least at a stop on its way, and leaving no
 * earlier than its departure plus how late it is. Pure. `ageSlack` gives an older fix more room in the matcher.
 */
object Advance {
    const val MAX_OFF_ROUTE = 150.0
    const val MAX_ADVANCE = 60.0
    const val MAX_SPEED = 30.0
    const val MAX_ADVANCE_SEEN = 120.0
    const val DWELL = 10.0
    const val SEEN_MIN = 5.0
    const val SEEN_MAX = 180.0
    const val SEEN_TOP = 46.0
    const val SLACK_FROM = 30.0
    const val SLACK_SHARE = 0.2
    const val MAX_SLACK = 600.0

    /** A stop-to-stop piece of a vehicle's road with its times; `start`: metres along the whole road. */
    data class Leg(val start: Double, val path: List<GeoPoint>, val departure: Double, val arrival: Double) {
        val length: Double = Geo.length(path)
        val speed: Double get() = if (length <= 0) 0.0 else min(MAX_SPEED, length / max(1.0, arrival - departure))
    }

    data class Piece(val path: List<GeoPoint>, val departure: Double, val arrival: Double)

    fun chained(pieces: List<Piece>): List<Leg> {
        val out = ArrayList<Leg>()
        var at = 0.0
        for (p in pieces) {
            val l = Leg(at, p.path, p.departure, p.arrival)
            if (l.length <= 0) continue
            out.add(l); at += l.length
        }
        return out
    }

    data class Spot(val leg: Int, val along: Double, val crossTrack: Double)

    data class Pace(val speed: Double? = null, val late: Double? = null)

    fun timeMetres(legs: List<Leg>, t: Double): Double? {
        val first = legs.firstOrNull() ?: return null
        if (t <= first.departure) return first.start
        var last = first.start
        for (l in legs) {
            if (t < l.departure) return last
            if (t <= l.arrival) {
                val f = (t - l.departure) / max(1.0, l.arrival - l.departure)
                return l.start + min(1.0, max(0.0, f)) * l.length
            }
            last = l.start + l.length
        }
        return last
    }

    fun snap(fix: GPSFix, legs: List<Leg>): Spot? {
        val p = fix.point
        val all = ArrayList<Pair<Spot, Double>>()
        legs.forEachIndexed { k, l ->
            if (l.length <= 0) return@forEachIndexed
            for (pass in Geo.passes(p, l.path)) if (pass.projection.crossTrack.isFinite())
                all.add(Spot(k, pass.projection.along, pass.projection.crossTrack) to l.start + pass.projection.along)
        }
        val nearest = all.minOfOrNull { it.first.crossTrack } ?: return null
        if (nearest > MAX_OFF_ROUTE) return null
        val close = all.filter { it.first.crossTrack <= min(MAX_OFF_ROUTE, nearest + 30) }
        val want = timeMetres(legs, fix.at) ?: return close.firstOrNull()?.first
        return close.minWithOrNull(compareBy({ abs(it.second - want) }, { it.first.crossTrack }))?.first
    }

    fun observedSpeed(fix: GPSFix, previous: GPSFix?, legs: List<Leg>): Double? {
        fix.speed?.let { if (it.isFinite() && it >= 0 && it <= 60) return it }
        val q = previous ?: return null
        val dt = fix.at - q.at
        if (dt < SEEN_MIN || dt > SEEN_MAX) return null
        val a = snap(fix, legs) ?: return null
        val b = snap(q, legs) ?: return null
        val v = ((legs[a.leg].start + a.along) - (legs[b.leg].start + b.along)) / dt
        return if (v.isFinite() && v >= 0 && v <= SEEN_TOP) v else null
    }

    fun lateness(spot: Spot, at: Double, legs: List<Leg>): Double? {
        val l = legs.getOrNull(spot.leg) ?: return null
        val span = l.arrival - l.departure
        if (span <= 0 || l.length <= 0) return null
        val f = min(1.0, max(0.0, spot.along / l.length))
        val late = at - (l.departure + f * span)
        return if (late.isFinite()) late else null
    }

    fun ageSlack(age: Double, speed: Double): Double {
        if (!age.isFinite() || !speed.isFinite() || age <= SLACK_FROM) return 0.0
        return min(MAX_SLACK, SLACK_SHARE * max(0.0, speed) * (age - SLACK_FROM))
    }

    fun advance(spot: Spot, at: Double, legs: List<Leg>, now: Double, pace: Pace = Pace()): Spot {
        if (spot.leg !in legs.indices) return spot
        val seen = pace.speed?.takeIf { it.isFinite() && it > 0.5 }?.let { min(it, 60.0) }
        val late = pace.late?.let { if (it.isFinite()) max(0.0, min(it, 1800.0)) else 0.0 } ?: 0.0
        val end = min(now, at + if (seen != null) MAX_ADVANCE_SEEN else MAX_ADVANCE)
        var t = at; var k = spot.leg; var a = min(max(0.0, spot.along), legs[k].length)
        if (a <= 15 && t < legs[k].departure + late) t = legs[k].departure + late
        while (t < end) {
            val l = legs[k]; val v = seen ?: l.speed
            if (v <= 0) break
            val need = (l.length - a) / v
            if (t + need >= end) { a += v * (end - t); break }
            t += need; a = l.length
            if (k + 1 >= legs.size) break
            t = max(t + if (seen != null) DWELL else 0.0, legs[k + 1].departure + late)
            if (t >= end) break
            k += 1; a = 0.0
        }
        return Spot(k, min(a, legs[k].length), spot.crossTrack)
    }

    fun place(fix: GPSFix, previous: GPSFix?, legs: List<Leg>, now: Double): Pair<Double, Spot>? {
        val s = snap(fix, legs) ?: return null
        val pace = Pace(observedSpeed(fix, previous, legs), lateness(s, fix.at, legs))
        val moved = advance(s, fix.at, legs, now, if (pace.speed == null) Pace() else pace)
        return legs[moved.leg].start + moved.along to moved
    }
}
