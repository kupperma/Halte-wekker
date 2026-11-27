package nl.haltewekker.ride

import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

// iOS 0.42.9 (`RideSaver.swift`), Android 0.10.6: a long ride for less battery and data. The same rules and numbers as
// iOS, checked against the same vectors (`docs/battery-vectors.json`). Nothing here makes the alarm later: the rough
// GPS is only on while the nearest you can be to the stop (the fix's distance, less its accuracy, less how far the
// vehicle can have gone since at its top speed) is beyond the wake distance plus 2 km plus what it covers until the
// next look, and while its arrival is more than 6 minutes off.

/** The GPS of a ride far from its stop (iOS `RideAccuracy`): rough while the vehicle is confirmed and the stop far. */
object RideAccuracy {
    enum class Tier { BEST, REDUCED }

    const val REDUCED_FILTER = 300.0
    const val ENTER_SECONDS = 8 * 60.0
    const val EXIT_SECONDS = 6 * 60.0
    const val ENTER_METRES = 8000.0
    const val EXIT_MARGIN = 2000.0
    const val HYSTERESIS = 1000.0
    const val LOOK_EVERY = 30.0
    const val BUS_BEST = 3000.0
    const val BOARDING = 120.0
    const val BUS_TOP = 25.0
    const val TRAIN_TOP = 45.0
    const val ENTER_ACCURACY = 100.0
    const val MAX_ACCURACY = 2000.0
    const val FRESH_FIX = 300.0
    const val CONFIRM_FRESH = 600.0

    /** Android asks for this "interval" for the rough tier: the network provider (and the passive one), no GPS chip. */
    const val REDUCED_MS = 61_000L

    data class Input(
        val enabled: Boolean = true,
        val asleep: Boolean = true,
        val confirmed: Boolean = false,
        val confirmedAge: Double? = null,
        val isTrain: Boolean,
        val metresToStop: Double? = null,
        val accuracy: Double? = null,
        val fixAge: Double? = null,
        val speed: Double? = null,
        val wakeMetres: Double,
        val secondsToStop: Double? = null,
        val legAge: Double,
        val backstop: Boolean = false,
        val needBest: Boolean = false,
        val wasReduced: Boolean = false,
    )

    fun top(isTrain: Boolean, speed: Double?): Double {
        val own = speed?.takeIf { it.isFinite() && it > 0 } ?: 0.0
        return max(if (isTrain) TRAIN_TOP else BUS_TOP, own)
    }

    fun nearest(metresToStop: Double?, accuracy: Double?, fixAge: Double?, top: Double): Double? {
        val d = metresToStop?.takeIf { it.isFinite() && it >= 0 } ?: return null
        val a = accuracy?.takeIf { it.isFinite() && it >= 0 } ?: return null
        val age = fixAge?.takeIf { it.isFinite() && it >= 0 } ?: return null
        return max(0.0, d - (min(a, MAX_ACCURACY) + top * age))
    }

    fun exitLine(wakeMetres: Double, isTrain: Boolean, top: Double): Double {
        val w = max(0.0, if (wakeMetres.isFinite()) wakeMetres else 0.0)
        val line = w + EXIT_MARGIN + top * LOOK_EVERY
        return if (isTrain) line else max(line, BUS_BEST)
    }

    fun enterLine(wakeMetres: Double, isTrain: Boolean, top: Double): Double =
        max(ENTER_METRES, exitLine(wakeMetres, isTrain, top) + HYSTERESIS)

    fun tier(i: Input): Tier {
        if (!i.enabled || !i.asleep || !i.confirmed || i.backstop || i.needBest) return Tier.BEST
        val c = i.confirmedAge ?: return Tier.BEST
        if (!c.isFinite() || c < 0 || c > CONFIRM_FRESH) return Tier.BEST
        if (!i.legAge.isFinite() || i.legAge < BOARDING) return Tier.BEST
        if (!i.wakeMetres.isFinite() || i.wakeMetres < 0) return Tier.BEST
        val a = i.accuracy ?: return Tier.BEST
        if (!a.isFinite() || a < 0 || a >= (if (i.wasReduced) MAX_ACCURACY else ENTER_ACCURACY)) return Tier.BEST
        val age = i.fixAge ?: return Tier.BEST
        if (!age.isFinite() || age < 0 || age > FRESH_FIX) return Tier.BEST
        i.secondsToStop?.let { s -> if (!(s.isFinite() && s > (if (i.wasReduced) EXIT_SECONDS else ENTER_SECONDS))) return Tier.BEST }
        val v = top(i.isTrain, i.speed)
        val near = nearest(i.metresToStop, a, age, v) ?: return Tier.BEST
        val line = if (i.wasReduced) exitLine(i.wakeMetres, i.isTrain, v) else enterLine(i.wakeMetres, i.isTrain, v)
        return if (near > line) Tier.REDUCED else Tier.BEST
    }
}

/** Waiting at a change (iOS `ChangeWait`): rough GPS once you've stood 3 minutes, until 3 minutes before the next ride. */
object ChangeWait {
    const val STAND_FOR = 180.0
    const val LEAD = 180.0
    const val FILTER = 100.0

    fun low(standingFor: Double?, nextIn: Double?, moving: Boolean, inVehicle: Boolean): Boolean {
        if (moving || inVehicle) return false
        val s = standingFor?.takeIf { it.isFinite() } ?: return false
        if (s < STAND_FOR) return false
        val n = nextIn?.takeIf { it.isFinite() } ?: return false
        return n > LEAD
    }
}

/** How often the ongoing ride notification is posted again (iOS `ActivityCadence`, the Live Activity's rule). */
object ActivityCadence {
    enum class Change { NONE, LOOK, MEANINGFUL, SAY }

    const val FAR_GAP = 60.0
    const val NEAR_GAP = 20.0
    const val QUIET_GAP = 180.0
    const val NEAR_WITHIN = 5 * 60.0

    fun near(secondsToStop: Double?, awake: Boolean): Boolean {
        if (awake) return true
        val s = secondsToStop?.takeIf { it.isFinite() } ?: return false
        return s <= NEAR_WITHIN
    }

    fun change(say: Boolean, meaningful: Boolean, look: Boolean): Change =
        if (say) Change.SAY else if (meaningful) Change.MEANINGFUL else if (look) Change.LOOK else Change.NONE

    fun gap(c: Change, near: Boolean): Double? = when (c) {
        Change.NONE -> null
        Change.SAY -> 0.0
        Change.MEANINGFUL -> if (near) NEAR_GAP else FAR_GAP
        Change.LOOK -> if (near) NEAR_GAP else QUIET_GAP
    }

    fun send(c: Change, near: Boolean, sinceLast: Double): Boolean {
        val g = gap(c, near) ?: return false
        return sinceLast < 0 || sinceLast >= g
    }

    fun later(c: Change, near: Boolean, sinceLast: Double): Double? {
        val g = gap(c, near) ?: return null
        return max(1.0, g - max(0.0, sinceLast))
    }

    /** Seconds since 1970 to the minute (0: none). */
    fun minute(t: Double?): Long = t?.let { floor(it / 60).toLong() } ?: 0L

    fun distanceStep(m: Double?): Int {
        val x = m?.takeIf { it.isFinite() && it >= 0 } ?: return -1
        return if (x < 2000) (x / 100).toInt() else 20 + (x / 500).toInt()
    }
}

/** A ride's network (iOS `RideNet`): the trip's live times every 2 minutes far from the stop, 45 s near it. */
object RideNet {
    const val TRIP_FAR = 120.0
    const val TRIP_NEAR = 45.0
    const val NEAR_WITHIN = 10 * 60.0
    const val NEAR_MARGIN = 5000.0
    const val BACKGROUND_WAYS = 3

    fun near(secondsToStop: Double?, metresToStop: Double?, wakeMetres: Double, awake: Boolean): Boolean {
        if (awake) return true
        val s = secondsToStop?.takeIf { it.isFinite() }
        val d = metresToStop?.takeIf { it.isFinite() && it >= 0 }
        if (s == null && d == null) return true
        if (s != null && s <= NEAR_WITHIN) return true
        val w = if (wakeMetres.isFinite()) max(0.0, wakeMetres) else 0.0
        if (d != null && d <= w + NEAR_MARGIN) return true
        return false
    }

    fun tripEvery(near: Boolean): Double = if (near) TRIP_NEAR else TRIP_FAR

    fun ways(wanted: Int, inFront: Boolean): Int = if (inFront) wanted else min(wanted, BACKGROUND_WAYS)
}

/** Before the matcher judges anyone (iOS `CandidatePrefilter`): the ones that can't be the one you're on, left out. */
object CandidatePrefilter {
    enum class Why { COACH, ROUTE, FAR }

    const val ROUTE_NEAR = 1000.0
    const val BUS_FAR = 3000.0
    const val TRAIN_FAR = 10_000.0
    const val BUS_TOP = 25.0
    const val TRAIN_TOP = 45.0
    val COACH_WORDS = listOf("flixbus", "flix bus", "blablacar", "eurolines", "regiojet", "megabus", "ouibus", "pinkbus")

    data class Candidate(val tripId: String, val line: String, val isTrain: Boolean, val paths: List<List<GeoPoint>>,
                         val gps: GeoPoint? = null, val gpsAge: Double? = null)

    data class Counts(val coach: Int = 0, val route: Int = 0, val far: Int = 0) {
        val total: Int get() = coach + route + far
        fun add(w: Why): Counts = when (w) {
            Why.COACH -> copy(coach = coach + 1)
            Why.ROUTE -> copy(route = route + 1)
            Why.FAR -> copy(far = far + 1)
        }
        operator fun plus(o: Counts) = Counts(coach + o.coach, route + o.route, far + o.far)
    }

    fun isCoach(line: String): Boolean {
        val l = line.lowercase()
        return COACH_WORDS.any { l.contains(it) }
    }

    fun routeMetres(paths: List<List<GeoPoint>>, you: List<GeoPoint>): Double? {
        var best: Double? = null
        for (path in paths) for (p in you) {
            val d = when {
                path.size >= 2 -> Geo.project(p, path)?.crossTrack
                path.size == 1 -> Geo.metres(p, path[0])
                else -> null
            }
            if (d != null && d.isFinite()) best = min(best ?: d, d)
        }
        return best
    }

    fun drop(c: Candidate, you: List<GeoPoint>, planned: String?): Why? {
        if (planned != null && c.tripId == planned) return null
        if (isCoach(c.line)) return Why.COACH
        val newest = you.lastOrNull() ?: return null
        routeMetres(c.paths, you)?.let { if (it > ROUTE_NEAR) return Why.ROUTE }
        c.gps?.let { g ->
            val age = c.gpsAge?.takeIf { it.isFinite() }?.let { max(0.0, it) } ?: 0.0
            val limit = (if (c.isTrain) TRAIN_FAR else BUS_FAR) + (if (c.isTrain) TRAIN_TOP else BUS_TOP) * age
            if (Geo.metres(newest, g) > limit) return Why.FAR
        }
        return null
    }

    fun <T> filter(items: List<T>, you: List<GeoPoint>, planned: String?, candidate: (T) -> Candidate): Pair<List<T>, Counts> {
        val kept = ArrayList<T>()
        var counts = Counts()
        for (x in items) {
            val w = drop(candidate(x), you, planned)
            if (w != null) counts = counts.add(w) else kept.add(x)
        }
        return kept to counts
    }

    fun line(place: String, dropped: Counts, total: Int): String =
        "prefilter · $place · ${dropped.total} of $total left out (${dropped.coach} coaches, ${dropped.route} off their route, ${dropped.far} far by their GPS)"
}
