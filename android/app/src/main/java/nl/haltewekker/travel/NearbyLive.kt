package nl.haltewekker.travel

import kotlin.math.roundToInt

/**
 * (iOS 0.42.8 `NearbyLive`) The stops around you by live times: a way's legs freshened by newer live times of the same
 * trips (by trip id: the stop's board), and how a time is shown ("14:41 +3", the planned one struck through). Plain
 * rules, tested with the iOS vectors (`NearbyLiveTest`). Times in seconds since 1970.
 */
object NearbyLive {
    data class Leg(val tripId: String, val departure: Double, val scheduledDeparture: Double, val arrival: Double,
                   val scheduledArrival: Double, val live: Boolean, val toStop: String = "")

    data class Update(val tripId: String, val departureDelay: Double, val arrivalDelay: Double? = null, val toStop: String? = null,
                      val live: Boolean, val asOf: Double)

    fun update(l: Leg, asOf: Double) = Update(l.tripId, l.departure - l.scheduledDeparture, l.arrival - l.scheduledArrival, l.toStop, l.live, asOf)

    fun update(board: String, time: Double, scheduled: Double, live: Boolean, asOf: Double) = Update(board, time - scheduled, live = live, asOf = asOf)

    /** The newest live update per trip (a timetable answer never overrides live times). */
    fun merge(a: Map<String, Update>, more: List<Update>): Map<String, Update> {
        val out = a.toMutableMap()
        for (u in more) {
            if (!u.live) continue
            val old = out[u.tripId]
            if (old != null && old.asOf >= u.asOf) continue
            out[u.tripId] = u
        }
        return out
    }

    fun apply(l: Leg, u: Update?, answered: Double?): Leg {
        if (u == null || !u.live || u.tripId != l.tripId) return l
        if (answered != null && u.asOf <= answered) return l
        val dep = l.scheduledDeparture + u.departureDelay
        val ownDep = l.departure - l.scheduledDeparture
        val ownArr = l.arrival - l.scheduledArrival
        var arr = ownArr + (u.departureDelay - ownDep)
        if (u.arrivalDelay != null && !u.toStop.isNullOrEmpty() && u.toStop == l.toStop) arr = u.arrivalDelay
        return l.copy(departure = dep, arrival = maxOf(l.scheduledArrival + arr, dep), live = true)
    }

    data class Trip(val start: Double, val end: Double, val legs: List<Leg>)

    fun trip(start: Double, end: Double, legs: List<Leg>, updates: Map<String, Update>, answered: Double?): Trip {
        if (legs.isEmpty()) return Trip(start, end, legs)
        val fresh = legs.map { apply(it, updates[it.tripId], answered) }
        return Trip(start + (fresh.first().departure - legs.first().departure), end + (fresh.last().arrival - legs.last().arrival), fresh)
    }

    data class Shown(val time: Double, val planned: Double?, val word: String, val late: Boolean)

    fun shown(departure: Double, scheduled: Double, live: Boolean, cancelled: Boolean): Shown {
        if (cancelled) return Shown(scheduled, null, "cancelled", true)
        if (!live) return Shown(scheduled, null, "timetable", false)
        val d = ((departure - scheduled) / 60).roundToInt()
        if (d == 0) return Shown(departure, null, "live", false)
        return Shown(departure, scheduled, if (d > 0) "+$d" else "$d", true)
    }

    fun fastest(arrivals: List<Double>, changes: List<Int>, departures: List<Double>): Int? {
        if (arrivals.isEmpty() || arrivals.size != changes.size || changes.size != departures.size) return null
        return arrivals.indices.minWithOrNull(compareBy<Int> { arrivals[it] }.thenBy { changes[it] }.thenByDescending { departures[it] })
    }
}
