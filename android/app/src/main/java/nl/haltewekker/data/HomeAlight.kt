package nl.haltewekker.data

import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import kotlin.math.ceil
import kotlin.math.max

/**
 * (iOS 0.42.9 `HomeAlight`) On the way home, off at your own home stop (the setup's) when the last ride calls there:
 * the one with the shortest walk home at your speed, not the planner's first stop in town. Plain rules, tested with
 * the iOS vectors (`HomeAlightTest`). Times in seconds since 1970.
 */
object HomeAlight {
    data class Call(val id: String, val name: String, val point: GeoPoint, val arrival: Double?)
    data class Own(val id: String, val point: GeoPoint?)

    const val SAME_STOP = 60.0
    const val STREETS = 1.3

    fun fullName(n: String) = n.trim()

    fun walkMinutes(a: GeoPoint, b: GeoPoint, speed: Double): Int = max(1, ceil(Geo.metres(a, b) * STREETS / max(0.3, speed) / 60).toInt())

    fun isOwn(c: Call, own: List<Own>): Boolean = own.any { o -> (o.id.isNotEmpty() && o.id == c.id) || (o.point != null && Geo.metres(o.point, c.point) <= SAME_STOP) }

    fun pick(calls: List<Call>, from: Int, plannerTo: Int, own: List<Own>, place: GeoPoint, speed: Double): Int? {
        if (own.isEmpty() || from < 0 || from >= calls.size) return null
        var best: Pair<Int, Int>? = null
        for (i in from + 1 until calls.size) {
            val c = calls[i]
            if (c.arrival == null || !isOwn(c, own)) continue
            val w = walkMinutes(c.point, place, speed)
            if (best == null || w < best.second) best = i to w
        }
        val b = best ?: return null
        if (b.first == plannerTo) return null
        if (plannerTo in calls.indices && isOwn(calls[plannerTo], own) && walkMinutes(calls[plannerTo].point, place, speed) <= b.second) return null
        return b.first
    }

    fun index(id: String, point: GeoPoint?, calls: List<Call>, after: Int = -1): Int? {
        val range = calls.indices.filter { it > after }
        if (id.isNotEmpty()) range.firstOrNull { calls[it].id == id }?.let { return it }
        val p = point ?: return null
        val near = range.minByOrNull { Geo.metres(calls[it].point, p) } ?: return null
        return if (Geo.metres(calls[near].point, p) <= 150) near else null
    }

    /** A way home with its last ride got off at your own stop, by its trip's calls (null: as it was). */
    fun apply(t: DoorTrip, stops: List<TripStop>, own: List<Own>, place: GeoPoint, speed: Double): DoorTrip? {
        val r = t.last
        val calls = stops.map { Call("", it.name, it.point, it.arrival ?: it.departure) }
        val fi = index("", r.fromLat?.let { a -> r.fromLon?.let { GeoPoint(a, it) } }, calls) ?: return null
        val ti = index("", r.to, calls, fi) ?: return null
        val pi = pick(calls, fi, ti, own, place, speed) ?: return null
        val c = calls[pi]
        val at = c.arrival ?: return null
        val late = r.arrival - r.scheduledArrival
        val ride = r.copy(toStop = c.name, arrival = at, scheduledArrival = at - late, toLat = c.point.lat, toLon = c.point.lon)
        return DoorTrip(t.rides.dropLast(1) + ride, t.start, at + walkMinutes(c.point, place, speed) * 60.0)
    }
}
