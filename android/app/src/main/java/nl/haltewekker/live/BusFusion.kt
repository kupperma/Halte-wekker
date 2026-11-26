package nl.haltewekker.live

import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min

/** A stop's times (iOS `StopTimes`): live and the timetable's, seconds since 1970. */
data class StopTimes(val arrival: Double? = null, val departure: Double? = null, val scheduledArrival: Double? = null,
                     val scheduledDeparture: Double? = null) {
    val at: Double? get() = arrival ?: departure
    val leaves: Double? get() = departure ?: arrival
    val scheduledAt: Double? get() = scheduledArrival ?: scheduledDeparture
    val scheduledLeaves: Double? get() = scheduledDeparture ?: scheduledArrival
}

/**
 * (iOS 0.40.1 `BusFusion`) the bus you wait for, where its GPS and its live times together put it, in metres along its
 * road: its fix moved on at its seen speed (capped by the timetable's), its live times at the timetable's speed of the
 * piece, weighed by how sure each is, kept between them, drawn without jumps (`Glide`). Since 0.40.3 only the faint
 * "expected" ghost (`RealFirst`), or Settings › Map › Bus position: Estimated. Pure, tested with the iOS vectors.
 */
object BusFusion {
    const val MAX_AGE = 180.0
    const val FULL_FIX = 20.0
    const val LOW_FIX = 120.0
    const val TRUST_FIX = 90.0
    const val FAR_APART = 1000.0
    const val AHEAD_FOR = 120.0
    const val WRONG_WAY = 50.0
    const val AT_STOP = 35.0
    const val BEFORE_START = 150.0
    const val TOP_SPEED = 30.0
    const val PLAIN_SPEED = 8.0
    const val CAP_SHARE = 1.5
    const val TIMING_DWELL = 30.0
    const val HINT_APART = 200.0
    const val WAIT_LEAD = 60.0
    const val ETA_SHARE = 0.6

    data class Stop(val metres: Double, val times: StopTimes, val timing: Boolean = false)

    data class Fix(val metres: Double, val at: Double, val speed: Double? = null)

    data class Piece(val start: Double, val length: Double, val departure: Double, val arrival: Double,
                     val scheduledDeparture: Double? = null, val scheduledArrival: Double? = null)

    data class Input(val stops: List<Stop>, val fix: Fix?, val live: Boolean, val timesAt: Double?, val mine: Int?,
                     val mineLeaves: Double? = null, val now: Double, val fromStart: Boolean = true)

    enum class Note { NONE, GPS_TRUSTED, GPS_IGNORED }

    data class Estimate(var metres: Double?, var gps: Double? = null, var eta: Double? = null, var raw: Double? = null,
                        var gpsAge: Double? = null, var gpsWeight: Double = 0.0, var etaWeight: Double = 0.0,
                        var note: Note = Note.NONE, var waiting: Double? = null, var started: Boolean = true) {
        /** The stretch between its GPS and its times when they're more than `HINT_APART` apart (from, to). */
        val hint: Pair<Double, Double>?
            get() {
                val g = gps ?: return null; val e = eta ?: return null
                if (waiting != null || abs(g - e) <= HINT_APART) return null
                return min(g, e) to max(g, e)
            }
    }

    fun isTiming(stops: List<Stop>, i: Int): Boolean {
        if (i !in stops.indices) return false
        if (stops[i].timing || i == 0) return true
        val a = stops[i].times.scheduledArrival ?: return false
        val d = stops[i].times.scheduledDeparture ?: return false
        return d - a >= TIMING_DWELL
    }

    fun speed(stops: List<Stop>, segment: Int): Double {
        val k = segment
        if (k < 0 || k + 1 >= stops.size) return PLAIN_SPEED
        val length = stops[k + 1].metres - stops[k].metres
        if (length <= 0) return PLAIN_SPEED
        val from = stops[k].times.scheduledLeaves ?: stops[k].times.leaves ?: return PLAIN_SPEED
        val to = stops[k + 1].times.scheduledAt ?: stops[k + 1].times.at ?: return PLAIN_SPEED
        val secs = max(30.0, to - from)
        return min(TOP_SPEED, max(2.0, length / secs))
    }

    fun segment(stops: List<Stop>, at: Double): Int? {
        if (stops.size < 2) return null
        for (k in 0 until stops.size - 1) if (stops[k + 1].metres > at) return k
        return null
    }

    fun plannedSpeed(stops: List<Stop>, at: Double): Double = speed(stops, segment(stops, at) ?: max(0, stops.size - 2))

    fun stops(pieces: List<Piece>): List<Stop> {
        val first = pieces.firstOrNull() ?: return emptyList()
        val out = arrayListOf(Stop(first.start, StopTimes(null, first.departure, null, first.scheduledDeparture)))
        for (k in pieces.indices) {
            val p = pieces[k]
            val next = pieces.getOrNull(k + 1)
            out.add(Stop(p.start + p.length, StopTimes(p.arrival, next?.departure, p.scheduledArrival, next?.scheduledDeparture)))
        }
        return out
    }

    data class ByTimes(val metres: Double, val next: Int, val started: Boolean, val done: Boolean, val toNext: Double?)

    fun byTimes(stops: List<Stop>, now: Double): ByTimes? {
        if (stops.isEmpty()) return null
        for (i in stops.indices) {
            val a = stops[i].times.at
            if (i > 0 && a != null && now < a) {
                val left = a - now
                val lo = stops[i - 1].metres
                val hi = stops[i].metres
                val back = left * speed(stops, i - 1)
                return ByTimes(min(hi, max(lo, hi - back)), i, true, false, left)
            }
            val d = stops[i].times.leaves
            if (d != null && now < d) return ByTimes(stops[i].metres, i, i > 0, false, 0.0)
        }
        val last = stops.size - 1
        return ByTimes(stops[last].metres, last, true, true, null)
    }

    fun ahead(stops: List<Stop>, fix: Fix, now: Double): Double {
        val end = min(now, fix.at + MAX_AGE)
        var t = fix.at
        var m = fix.metres
        if (stops.size < 2 || t >= end) return m
        val moving = (fix.speed ?: 0.0) >= 1.5
        val near = stops.indices.filter { abs(stops[it].metres - m) <= AT_STOP }
        val s = near.minByOrNull { abs(stops[it].metres - m) }
        if (!moving && s != null && m <= stops[s].metres + 15) {
            val d = stops[s].times.leaves
            if (d != null && d > t) t = d
        }
        var steps = 0
        while (t < end && steps <= stops.size) {
            steps += 1
            val k = segment(stops, m) ?: break
            val plan = speed(stops, k)
            var v = plan
            val seen = fix.speed
            if (seen != null && seen.isFinite() && seen >= 0) v = max(seen, 0.5 * plan)
            v = minOf(v, plan * CAP_SHARE, TOP_SPEED)
            if (v <= 0) break
            val next = stops[k + 1].metres
            val need = (next - m) / v
            val left = end - t
            if (need >= left) { m += v * left; break }
            t += need
            m = next
            if (isTiming(stops, k + 1)) {
                val d = stops[k + 1].times.leaves
                if (d != null && d > t) t = d
            }
        }
        return m
    }

    fun gpsWeight(age: Double): Double {
        val a = max(0.0, age)
        if (a <= FULL_FIX) return 1.0
        if (a <= LOW_FIX) return 1 - 0.85 * (a - FULL_FIX) / (LOW_FIX - FULL_FIX)
        return max(0.05, 0.15 - 0.10 * (a - LOW_FIX) / (MAX_AGE - LOW_FIX))
    }

    fun etaWeight(timesAge: Double?, toGo: Double?): Double {
        val age = max(0.0, timesAge ?: 0.0)
        val fresh = if (age <= 60) 1.0 else max(0.5, 1 - 0.5 * (age - 60) / 180)
        val go = max(0.0, toGo ?: 600.0)
        val close = if (go <= 120) 1.0 else max(0.5, 1 - 0.5 * (go - 120) / 780)
        return ETA_SHARE * fresh * close
    }

    fun notThisJourney(f: Fix, stops: List<Stop>, times: ByTimes, live: Boolean, fromStart: Boolean): Boolean {
        val s0 = stops.firstOrNull()
        val d0 = s0?.times?.leaves
        if (fromStart && !times.started && s0 != null && f.metres > s0.metres + BEFORE_START && d0 != null && f.at < d0 - 60) return true
        if (!live) return false
        val limit = max(FAR_APART, AHEAD_FOR * plannedSpeed(stops, times.metres))
        return f.metres > times.metres + limit
    }

    fun fuse(x: Input): Estimate {
        val out = Estimate(null)
        val times = byTimes(x.stops, x.now) ?: return out
        val mine = x.mine?.takeIf { it in x.stops.indices }
        val started = times.started || !x.fromStart
        out.started = started
        out.eta = times.metres
        var fix = x.fix
        if (fix != null && notThisJourney(fix, x.stops, times, x.live, x.fromStart)) {
            fix = null
            out.note = Note.GPS_IGNORED
        }
        val f = fix
        if (f == null) {
            if (!started && mine == 0) return out
            out.metres = times.metres
            out.etaWeight = 1.0
            return out
        }
        val age = max(0.0, x.now - f.at)
        val g = ahead(x.stops, f, x.now)
        out.gps = g; out.raw = f.metres; out.gpsAge = age
        if (!x.live) out.eta = null
        if (mine != null && age <= TRUST_FIX && abs(f.metres - x.stops[mine].metres) <= AT_STOP) {
            val leaves = x.mineLeaves ?: x.stops[mine].times.leaves
            if (leaves != null && leaves - x.now > WAIT_LEAD) {
                out.metres = x.stops[mine].metres
                out.waiting = leaves
                out.gpsWeight = 1.0
                return out
            }
        }
        var fused = g
        if (x.live) {
            val e = times.metres
            var toGo = times.toNext
            if (mine != null) x.stops[mine].times.at?.let { toGo = it - x.now }
            val wg = gpsWeight(age)
            val we = etaWeight(x.timesAt?.let { x.now - it }, toGo)
            out.gpsWeight = wg; out.etaWeight = we
            val blend = (wg * g + we * e) / (wg + we)
            if (f.metres > e + WRONG_WAY) {
                if (age <= TRUST_FIX) { fused = g; out.note = Note.GPS_TRUSTED } else fused = max(f.metres, blend)
            } else if (e - g > FAR_APART && age <= TRUST_FIX) {
                fused = g
                out.note = Note.GPS_TRUSTED
            } else {
                val lo = f.metres
                val hi = max(e, f.metres)
                fused = min(hi, max(lo, blend))
            }
        } else {
            out.gpsWeight = 1.0
        }
        if (mine != null) {
            val me = x.stops[mine].metres
            if (f.metres < me - AT_STOP) fused = min(fused, me - AT_STOP)
        }
        out.metres = fused
        return out
    }

    /** Where it's drawn, step by step: towards where it is, never backwards for nothing, never in a jump. */
    class Glide {
        companion object {
            const val TAU = 2.0
            const val MIN_CAP = 25.0
            const val BACK_BY = 150.0
            const val BACK_FOR = 3.0
            const val FRESH_BACK = 60.0
            const val RESTART_AFTER = 20.0
            const val MAX_STEP = 5.0
        }

        var shown: Double? = null; private set
        var at: Double? = null; private set
        private var fixAt: Double? = null
        private var backFrom: Double? = null
        private var backStart: Double? = null

        fun step(target: Double, now: Double, speed: Double, fixAt: Double? = null, fixAge: Double? = null): Double {
            val newFix = fixAt != null && fixAt != this.fixAt
            if (fixAt != null) this.fixAt = fixAt
            if (!target.isFinite()) return shown ?: 0.0
            val s = shown; val last = at
            if (s == null || last == null || now < last || now - last > RESTART_AFTER) {
                shown = target; at = now; backFrom = null; backStart = null
                return target
            }
            val dt = min(MAX_STEP, now - last)
            at = now
            val fresh = (fixAge ?: Double.POSITIVE_INFINITY) <= FRESH_BACK
            if (newFix && fresh && target < s - BACK_BY) { backFrom = s; backStart = now }
            val from = backFrom; val start = backStart
            if (from != null && start != null) {
                val f = min(1.0, (now - start) / BACK_FOR)
                val v = from + (target - from) * f
                if (f >= 1 || target >= from) { backFrom = null; backStart = null }
                shown = v
                return v
            }
            if (target <= s) return s
            val gap = target - s
            val v = max(0.0, if (speed.isFinite()) speed else 0.0)
            val cap = max(MIN_CAP, CAP_SHARE * v) * dt
            val ease = gap * (1 - exp(-dt / TAU))
            val pace = v * dt
            val move = minOf(gap, cap, max(ease, pace))
            shown = s + move
            return s + move
        }

        fun reset() { shown = null; at = null; fixAt = null; backFrom = null; backStart = null }
    }

    fun waitingText(leaves: Double, clock: (Double) -> String): String = "Waiting · leaves ${clock(leaves)}"

    fun signed(m: Double): String {
        if (!m.isFinite()) return "? m"
        val r = (max(-1e7, min(1e7, m)) / 10).roundHalfAway() * 10
        return if (r >= 0) "+$r m" else "$r m"
    }

    /** Swift's `.rounded()`: half away from zero. */
    internal fun Double.roundHalfAway(): Long = if (this >= 0) (this + 0.5).toLong() else -((-this + 0.5).toLong())

    fun logLine(kind: String, vehicle: String, e: Estimate, drawn: Double): String {
        val parts = arrayListOf("$kind fused", vehicle)
        val raw = e.raw; val g = e.gps
        if (raw != null && g != null) {
            val age = (e.gpsAge ?: 0.0).roundHalfAway()
            parts.add("gps $age s old ${signed(g - raw)}")
            parts.add(e.eta?.let { "eta says ${signed(it - raw)}" } ?: "no live times")
            parts.add("drawn ${signed(drawn - raw)}")
        } else {
            parts.add(if (e.note == Note.GPS_IGNORED) "gps not this journey" else "no gps")
            parts.add("drawn by its times")
        }
        if (e.note == Note.GPS_TRUSTED) parts.add("far apart: gps trusted")
        if (e.waiting != null) parts.add("waiting at your stop")
        return parts.joinToString(" · ")
    }
}
