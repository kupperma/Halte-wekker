package nl.haltewekker.ride

import kotlin.math.max
import kotlin.math.min

/**
 * (A6, iOS 0.34 `DeadReckon.swift`) following the ride in tunnels and dead zones: once the newest good fix (≤ 100 m)
 * is more than 15 s old, the ride's place goes on along the vehicle's route at its pace. Safety: a dead-reckoned place
 * alone never rings by distance, only when the time rule agrees. Pure, so it can be tested.
 */
object DeadReckon {
    const val QUIET_AFTER = 15.0
    const val POOR_ACCURACY = 100.0
    const val MAX_FOR = 15 * 60.0
    const val EVERY = 5.0

    enum class Source(val raw: String) { GPS("gps"), TIMES("times"), PACE("pace") }

    data class Estimate(val metres: Double, val source: Source)

    fun good(accuracy: Double) = accuracy.isFinite() && accuracy >= 0 && accuracy <= POOR_ACCURACY

    fun needed(lastGoodAt: Double?, now: Double): Boolean {
        val l = lastGoodAt ?: return false
        val quiet = now - l
        return quiet > QUIET_AFTER && quiet <= MAX_FOR
    }

    fun pace(remaining: Double, arrival: Double?, now: Double, lastSpeed: Double?, isTrain: Boolean): Double? {
        val top = WakeRule.top(isTrain)
        if (arrival != null && arrival - now >= 30 && remaining.isFinite() && remaining >= 0) return min(top, remaining / (arrival - now))
        val v = lastSpeed ?: return null
        if (!v.isFinite() || v < 0) return null
        return min(top, v)
    }

    fun along(from: Double, at: Double, now: Double, pace: Double?, gps: Double?, times: Double?, end: Double, isTrain: Boolean = false): Estimate {
        val dt = max(0.0, min(MAX_FOR, now - at))
        fun clamp(m: Double) = min(max(from, end), max(from, m))
        if (gps != null && gps.isFinite()) return Estimate(clamp(gps), Source.GPS)
        if (times != null && times.isFinite() && times - from <= WakeRule.top(isTrain) * dt + 50) return Estimate(clamp(times), Source.TIMES)
        val v = pace?.takeIf { it.isFinite() && it > 0 } ?: 0.0
        return Estimate(clamp(from + v * dt), Source.PACE)
    }

    /** The wake rules on a dead-reckoned place: the time rule only. */
    fun decide(i: WakeRule.Input): WakeRule.Fire? = WakeRule.decide(i.copy(by = WakeBy.TIME, wakeMetres = -1.0))

    fun mayRing(fire: WakeRule.Fire?, deadReckoned: Boolean): Boolean {
        fire ?: return false
        if (!deadReckoned) return true
        return fire is WakeRule.Fire.Time
    }
}
