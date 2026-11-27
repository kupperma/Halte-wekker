package nl.haltewekker.match

import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * (0.10.6, iOS 0.42.9 `BetterStop.swift`) the best place to get off: a few later stops of the vehicle you're on (within
 * 90 min, nearest your destination first, 3 at most) planned from, once each (every 5 min at most); one that gets you
 * there 3 min sooner, or as soon with fewer changes, is offered ("Do this" / "Keep my plan"). Pure.
 */
object BetterStop {
    const val HORIZON = 90 * 60.0
    const val MAX_CANDIDATES = 3
    const val EVERY = 300.0
    const val GAIN = 180.0
    const val SAME_WITHIN = 60.0
    const val CHANGE_ROOM = 60.0

    fun candidates(calls: List<TrainRules.Call>, after: Int, dest: GeoPoint, now: Double): List<Int> {
        if (after < 0 || after + 1 >= calls.size) return emptyList()
        val until = now + HORIZON
        return ((after + 1) until calls.size)
            .filter { i -> calls[i].arrival.let { it != null && it > now && it <= until } }
            .sortedWith(compareBy<Int>({ Geo.metres(calls[it].p, dest) }, { it }))
            .take(MAX_CANDIDATES)
    }

    data class Option(val stop: Int, val arrival: Double, val changes: Int)

    fun best(current: Double, currentChanges: Int, options: List<Option>): Option? {
        for (o in options.sortedWith(compareBy<Option>({ it.arrival }, { it.changes }, { it.stop }))) {
            val saved = current - o.arrival
            if (saved >= GAIN) return o
            if (abs(saved) <= SAME_WITHIN && o.changes < currentChanges) return o
        }
        return null
    }

    fun offerText(stop: String, dest: String, newAt: String, oldAt: String, then: String?): String =
        "Stay on to $stop — $dest $newAt instead of $oldAt" + (then?.let { " ($it)" } ?: "")

    fun log(stop: String, dest: String, newAt: String, minutes: Int): String =
        "better stop · stay on to $stop · $dest $newAt (−${max(0, minutes)} min)"

    fun minutesSooner(current: Double, better: Double): Int = ((current - better) / 60).roundToInt()
}
