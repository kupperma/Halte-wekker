package nl.haltewekker.live

import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.data.TransitParse
import nl.haltewekker.logs.FieldLog
import kotlin.math.max

/**
 * (A8.1, iOS 0.40.3 `BusFusionLive`) the bus or train you wait for or ride, placed for a map: its whole trip's stops in
 * metres along its road, its OVapi or NS fix put on that road (`RealFirst.Fix`), `RealFirst.show` (or `estimated` for
 * Settings › Map › Bus position: Estimated), the glides, and the log line once a minute. The on-board matcher keeps its
 * own raw GPS: none of this reaches it.
 */
class WaitVehicle {
    data class Placed(val shown: RealFirst.Shown, val point: GeoPoint?, val ghost: GeoPoint?) {
        val drawn: Boolean get() = shown.source != RealFirst.Source.NONE && point != null
        val tag: String get() = RealFirst.tag(shown)
        val dim: Boolean get() = shown.source == RealFirst.Source.BY_TIMES
    }

    /** Your phone's fix (on board). */
    data class Me(val point: GeoPoint, val at: Double, val accuracy: Double, val speed: Double?)

    private class Road(val path: List<GeoPoint>, val stops: List<BusFusion.Stop>)

    private var roadKey = ""
    private var road: Road? = null
    private val main = RealFirst.Glide()
    private val ghostGlide = RealFirst.Glide()
    private val old = BusFusion.Glide()
    private var lastFix: GPSFix? = null
    private var previousFix: GPSFix? = null
    private var loggedAt = 0.0
    private var glideId = ""

    private fun road(t: TransitParse.LiveTrip): Road {
        val key = "${t.stops.size}|${t.path.size}|${t.stops.firstOrNull()?.departure}|${t.stops.lastOrNull()?.arrival}|${t.stops.sumOf { (it.arrival ?: 0.0) + (it.departure ?: 0.0) }}"
        road?.let { if (key == roadKey) return it }
        val path = if (t.path.size >= 2) t.path else t.stops.map { it.point }
        var prev = 0.0
        val stops = t.stops.map { s ->
            val along = Geo.pass(s.point, path, prev, 40.0)?.projection?.along ?: prev
            prev = max(prev, along)
            BusFusion.Stop(prev, StopTimes(s.arrival, s.departure, s.scheduledArrival, s.scheduledDeparture))
        }
        return Road(path, stops).also { road = it; roadKey = key }
    }

    /** Its fix as `RealFirst` takes it: on its road (with the speed it was seen going), else off it (metres to your stop). */
    private fun fix(f: GPSFix, prev: GPSFix?, r: Road, mine: Int?, now: Double): RealFirst.Fix {
        val toMine = mine?.let { tripStop?.getOrNull(it) }?.let { Geo.metres(f.point, it) }
        val stopped = f.stopped ?: false
        val near = BusFusion.byTimes(r.stops, f.at)?.metres
        val pass = Geo.pass(f.point, r.path, near, 30.0) ?: return RealFirst.Fix(null, f.at, f.speed, stopped, toMine)
        if (pass.projection.crossTrack > Advance.MAX_OFF_ROUTE) return RealFirst.Fix(null, f.at, f.speed, stopped, toMine)
        val m = pass.projection.along
        var seen = f.speed?.takeIf { it.isFinite() && it >= 0 && it <= 60 }
        if (seen == null && prev != null) {
            val dt = f.at - prev.at
            val q = Geo.pass(prev.point, r.path, m, 30.0)?.projection
            if (dt in Advance.SEEN_MIN..Advance.SEEN_MAX && q != null && q.crossTrack <= Advance.MAX_OFF_ROUTE) {
                val v = (m - q.along) / dt
                if (v.isFinite() && v >= 0 && v <= Advance.SEEN_TOP) seen = v
            }
        }
        return RealFirst.Fix(m, f.at, seen, stopped, toMine, pass.projection.crossTrack)
    }

    private var tripStop: List<GeoPoint>? = null

    /**
     * Where to draw it now. `mine`: your stop on its trip; `mineLeaves`: when it leaves there as the card says it;
     * `gps`: its own fix (OVapi by trip, NS by train number); `me`: your phone's fix while you ride it.
     */
    fun place(t: TransitParse.LiveTrip, tripId: String, line: String, isTrain: Boolean, mine: Int?, mineLeaves: Double?, timesAt: Double?,
              now: Double, gps: GPSFix?, feed: String, me: Me? = null, estimated: Boolean = false): Placed {
        if (glideId != tripId) { main.reset(); ghostGlide.reset(); old.reset(); lastFix = null; previousFix = null; glideId = tripId; loggedAt = 0.0 }
        val r = road(t)
        tripStop = t.stops.map { it.point }
        val m = mine?.takeIf { it in r.stops.indices }
        if (gps != null && gps.at != lastFix?.at) { previousFix = lastFix; lastFix = gps }
        val f = gps?.let { fix(it, previousFix?.takeIf { p -> p.at < it.at }, r, m, now) }
        val train = isTrain || RealPositions.isRail(t.mode)
        var input = RealFirst.Input(r.stops, f, t.live, timesAt, m, mineLeaves, now, true, train)
        var point: GeoPoint? = null
        if (me != null && now - me.at >= -5 && now - me.at <= RealFirst.ME_FRESH && me.accuracy >= 0 && me.accuracy <= RealFirst.ME_ACCURACY) {
            val on = fix(GPSFix(me.point.lat, me.point.lon, null, me.at), null, r, m, now).copy(speed = me.speed)
            input = input.copy(onBoard = on)
            point = me.point
        }
        val est = estimated && input.onBoard == null
        val s = if (est) RealFirst.estimated(input) else RealFirst.show(input)
        if (s.source != RealFirst.Source.ON_BOARD) point = null
        if (s.atFix && s.source == RealFirst.Source.GPS && gps != null) point = gps.point
        // the glides: along its road only
        var along: Double? = null
        val sm = s.metres
        if (sm != null && !s.atFix && (s.source == RealFirst.Source.GPS || s.source == RealFirst.Source.BY_TIMES)) {
            along = if (est) old.step(sm, now, BusFusion.plannedSpeed(r.stops, sm), gps?.at, s.fixAge) else main.step(sm, now)
        } else { main.reset(); old.reset() }
        val g = s.ghost
        val ghostAt = if (g != null) ghostGlide.step(g, now) else { ghostGlide.reset(); null }
        if (point == null && along != null) point = Geo.pointAtMetres(along, r.path)
        if (s.source == RealFirst.Source.NONE) point = null
        if (now - loggedAt >= 60 || now < loggedAt) {
            loggedAt = now
            FieldLog.match(RealFirst.logLine("$line·${tripId.takeLast(4)}", feed, s, est))
        }
        return Placed(s, point, ghostAt?.let { Geo.pointAtMetres(it, r.path) })
    }

    fun reset() { glideId = ""; road = null; roadKey = "" }

    companion object {
        /** Your stop on its trip: the stop nearest where you get on (within 400 m), else by its name. */
        fun mine(t: TransitParse.LiveTrip, at: GeoPoint?, name: String): Int? {
            if (at != null) {
                val i = t.stops.indices.minByOrNull { Geo.metres(t.stops[it].point, at) }
                if (i != null && Geo.metres(t.stops[i].point, at) <= 400) return i
            }
            val n = name.trim().lowercase()
            return t.stops.indexOfFirst { it.name.trim().lowercase() == n }.takeIf { it >= 0 }
        }
    }
}
