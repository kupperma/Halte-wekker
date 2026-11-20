package nl.haltewekker.ride

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.match.Fix
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

// (A6, iOS 0.33 `WakeRule.swift`) wake by time on trains (and fast buses). The distance rule stays as it was, the
// safety net: whichever comes first, so never later than it. Pure, so it can be tested.

/** How the alarm before your stop is timed. */
@Serializable
enum class WakeBy { @SerialName("time") TIME, @SerialName("distance") DISTANCE }

/** Settings › Trips & alarm › "Wake me … before my stop" (`wake.by`, `wake.trainMin`, `wake.busMin`). */
@Serializable
data class WakeSettings(val by: WakeBy = WakeBy.TIME, val trainMinutes: Int = 3, val busMinutes: Int = 2) {
    fun minutes(isTrain: Boolean) = if (isTrain) trainMinutes else busMinutes

    companion object {
        val RANGE = 1..10
        fun clamp(v: Int) = min(RANGE.last, max(RANGE.first, v))
    }
}

/**
 * Your speed, smoothed (a time constant of 30 s): not known until it has 20 s of readings, nor once it has had none
 * for 90 s (iOS `SpeedSmoother`).
 */
class SpeedSmoother {
    companion object {
        const val TAU = 30.0
        const val GAP = 90.0
        const val WARM_UP = 20.0
        const val CEILING = 100.0

        /** The GPS's own speed, else from the previous fix when both are 50 m or better and 2 s or more apart. */
        fun reading(f: Fix, previous: Fix?): Double? {
            if (f.speed.isFinite() && f.speed >= 0) return f.speed
            val p = previous ?: return null
            if (f.accuracy < 0 || f.accuracy > 50 || p.accuracy < 0 || p.accuracy > 50) return null
            val dt = f.t - p.t
            if (dt < 2) return null
            return Geo.metres(p.p, f.p) / dt
        }
    }

    var value: Double? = null; private set
    var since: Double? = null; private set
    var last: Double? = null; private set

    fun add(speed: Double, at: Double) {
        if (!speed.isFinite() || speed < 0 || speed > CEILING) return
        val v = value; val l = last
        if (v == null || l == null || at - l > GAP) { value = speed; since = at; last = at; return }
        val dt = at - l
        if (dt <= 0) return
        val a = 1 - exp(-dt / TAU)
        value = v + a * (speed - v)
        last = at
    }

    fun speed(now: Double): Double? {
        val v = value ?: return null; val s = since ?: return null; val l = last ?: return null
        if (now - l > GAP || l - s < WARM_UP) return null
        return v
    }

    fun reset() { value = null; since = null; last = null }
}

/** The distance left to the end of a route (the stops from where you got on to yours), from where you are on it. */
object RouteLeft {
    const val OFF_ROUTE = 1500.0
    fun metres(p: GeoPoint, path: List<GeoPoint>): Double? {
        if (path.size < 2) return null
        val pr = Geo.project(p, path) ?: return null
        if (pr.crossTrack > OFF_ROUTE) return null
        return max(0.0, Geo.length(path) - pr.along)
    }
}

object WakeRule {
    const val TRAIN_TOP = 45.0
    const val BUS_TOP = 28.0
    const val MIN_SPEED = 4.0
    const val LIVE_FRESH = 150.0
    const val LEFT_START = 300.0

    enum class Source(val raw: String) { LIVE("live"), SPEED("speed") }

    sealed class Fire {
        data object Distance : Fire()
        data class Time(val minutes: Int, val source: Source, val seconds: Double) : Fire()
    }

    data class Input(
        val by: WakeBy,
        val minutes: Int,
        val isTrain: Boolean,
        /** Straight-line metres to the leg's stop, from the newest good fix. */
        val metres: Double,
        val routeMetres: Double? = null,
        val wakeMetres: Double,
        val liveArrival: Double? = null,
        val liveAge: Double? = null,
        val speed: Double? = null,
        val fromStartMetres: Double? = null,
        val now: Double,
    )

    fun remaining(i: Input): Double {
        val r = i.routeMetres ?: return i.metres
        if (!r.isFinite()) return i.metres
        return max(i.metres, r)
    }

    fun top(isTrain: Boolean) = if (isTrain) TRAIN_TOP else BUS_TOP

    fun reach(isTrain: Boolean, minutes: Int): Double = max(0, minutes) * 60 * top(isTrain)

    fun estimate(i: Input): Pair<Double, Source>? {
        val left = remaining(i)
        val a = i.liveArrival; val age = i.liveAge
        if (a != null && age != null && age.isFinite() && age >= 0 && age <= LIVE_FRESH) {
            val s = a - i.now
            if (s > 0 && left / s <= top(i.isTrain)) return s to Source.LIVE
        }
        val v = i.speed
        if (v != null && v.isFinite() && v >= MIN_SPEED) return left / v to Source.SPEED
        return null
    }

    fun decide(i: Input): Fire? {
        if (i.metres <= i.wakeMetres) return Fire.Distance
        if (i.by != WakeBy.TIME || i.minutes <= 0) return null
        i.fromStartMetres?.let { if (it.isFinite() && it < LEFT_START) return null }
        if (remaining(i) > reach(i.isTrain, i.minutes)) return null
        val e = estimate(i) ?: return null
        if (e.first > i.minutes * 60.0) return null
        return Fire.Time(i.minutes, e.second, e.first)
    }

    fun log(f: Fire): String = when (f) {
        Fire.Distance -> "by distance"
        is Fire.Time -> "by time ${f.minutes} min (${f.source.raw})"
    }

    fun says(s: WakeSettings, isTrain: Boolean, wakeMetres: Double): String {
        val d = distanceWords(wakeMetres)
        return if (s.by == WakeBy.TIME) "${s.minutes(isTrain)} min before your stop (or $d)" else "$d before your stop"
    }

    fun distanceWords(m: Double): String {
        if (m < 1000) return "${(max(0.0, m) / 10).roundToInt() * 10} m"
        val km = Math.round(m / 100) / 10.0
        return if (km == Math.rint(km)) "${km.toInt()} km" else String.format(java.util.Locale.ROOT, "%.1f km", km)
    }

    fun gpsWakeMetres(wakeMetres: Double, s: WakeSettings, isTrain: Boolean): Double =
        if (s.by != WakeBy.TIME) wakeMetres else max(wakeMetres, reach(isTrain, s.minutes(isTrain)))
}
