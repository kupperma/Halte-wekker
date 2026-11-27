package nl.haltewekker.data

import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * (iOS 0.42.7 `PlanFix`) Ways kept and ordered by their live times (a late train whose timetable time has passed stays),
 * and walks timed by their distance with a short first hop swapped for the walk. Plain rules, tested with the iOS
 * vectors (`PlanFixTest`). Times in seconds since 1970.
 */
object LiveKeep {
    fun askAt(now: Double, atStation: Boolean): Double = now - if (atStation) 15 * 60 else 120

    fun count(n: Int, atStation: Boolean): Int = if (atStation) n + 3 else n

    data class Way(val departure: Double, val scheduled: Double, val start: Double, val cancelled: Boolean = false)

    fun keep(w: Way, now: Double): Boolean = !w.cancelled && w.departure >= now - 30 && w.start >= now - 90

    fun order(ws: List<Way>): List<Int> = ws.indices.sortedBy { ws[it].departure }

    fun connects(arrivals: List<Double>, departures: List<Double>, walks: List<Int>): Boolean {
        if (arrivals.size != departures.size || departures.size != walks.size) return false
        for (k in 1 until departures.size) if (departures[k] - arrivals[k - 1] < max(1, walks[k]) * 60.0) return false
        return true
    }

    fun lateWords(line: String, to: String, scheduled: Double, departure: Double, platform: String?, clock: (Double) -> String): String {
        val m = ((departure - scheduled) / 60).roundToInt()
        return "The ${clock(scheduled)} $line to $to is $m min late — leaves ${clock(departure)}" + (platform?.let { " from platform $it" } ?: "")
    }
}

object WalkFirst {
    const val PLANNER_SPEED = 1.2
    const val WALKS_NEEDED = 5
    const val STREETS = 1.3
    const val ODD = 2.0

    fun speed(learned: Double?, walks: Int): Double = if (learned != null && learned > 0 && walks >= WALKS_NEEDED) learned else PLANNER_SPEED

    fun metres(planner: Double?, straight: Double?): Double? {
        if (planner != null && planner > 0) {
            if (straight != null && straight > 0 && planner > straight * ODD) return straight * STREETS
            return planner
        }
        return straight?.let { it * STREETS }
    }

    fun minutes(metres: Double, speed: Double): Int = max(1, ceil(metres / max(0.3, speed) / 60).toInt())

    fun walk(plannerMinutes: Int, metres: Double?, speed: Double): Int {
        if (plannerMinutes <= 0 || metres == null) return plannerMinutes
        return min(plannerMinutes, minutes(metres, speed))
    }

    fun walkInstead(rideMinutes: Double, now: Double, start: Double, nextDeparture: Double, walkMetres: Double, speed: Double): Int? {
        if (rideMinutes > 6 || walkMetres <= 0) return null
        val w = minutes(walkMetres, speed)
        val leave = max(now, start)
        if (now + (w + 1) * 60.0 > nextDeparture) return null
        val hop = (nextDeparture - leave) / 60
        if (w > 1.3 * hop) return null
        return w
    }

    fun logLine(plannerMinutes: Int, plannerMetres: Double?, yours: Int, speed: Double, usedYours: Boolean): String =
        "walk · planner $plannerMinutes min" + (plannerMetres?.let { " (${it.roundToInt()} m)" } ?: "") +
            " · yours $yours min (${String.format(java.util.Locale.ROOT, "%.2f", speed)} m/s) · used ${if (usedYours) "yours" else "the planner's"}"

    /** A way's first walk by its distance, and a short first hop swapped for the walk (iOS `Transit.walkFixed`). */
    fun fixed(t: DoorTrip, here: nl.haltewekker.core.GeoPoint, now: Double, used: Double): Pair<DoorTrip, String?> {
        val f = t.rides.firstOrNull() ?: return t to null
        if (f.fromId == "onboard") return t to null
        if (t.rides.size > 1) {
            val next = t.rides[1]
            val la = next.fromLat; val lo = next.fromLon
            if (la != null && lo != null) {
                val m = nl.haltewekker.core.Geo.metres(here, nl.haltewekker.core.GeoPoint(la, lo)) * STREETS
                val w = walkInstead((f.arrival - f.departure) / 60, now, t.start, next.departure, m, used)
                if (w != null) return DoorTrip(listOf(next.copy(walkBefore = w)) + t.rides.drop(2), next.departure - w * 60.0, t.end) to
                    "walk · straight to ${next.fromStop} ($w min) instead of the ${f.line} there"
            }
        }
        if (f.walkBefore <= 0) return t to null
        val straight = f.fromLat?.let { a -> f.fromLon?.let { o -> nl.haltewekker.core.Geo.metres(here, nl.haltewekker.core.GeoPoint(a, o)) } }
        val m = metres(f.walkMetres, straight)
        val w = walk(f.walkBefore, m, used)
        val line = logLine(f.walkBefore, f.walkMetres ?: straight, w, used, w < f.walkBefore)
        if (w >= f.walkBefore) return t to line
        return DoorTrip(listOf(f.copy(walkBefore = w, walkMetres = m)) + t.rides.drop(1), f.departure - w * 60.0, t.end) to line
    }
}
