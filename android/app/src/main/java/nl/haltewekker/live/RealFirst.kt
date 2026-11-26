package nl.haltewekker.live

import nl.haltewekker.live.BusFusion.roundHalfAway
import kotlin.math.max
import kotlin.math.min

/**
 * (iOS 0.40.3 `RealFirst`) the bus or train you wait for or ride, drawn where it really is, in metres along its road:
 * at its last fix itself (on its road within `ON_ROAD`, else at the fix), moved on only while it was clearly going, at
 * most `ADVANCE_FOR` s, never past the next stop it must stop at nor into your stop; `BusFusion`'s estimate only as a
 * faint ghost ahead; "Arriving" / "Waiting" / "It's at your stop" only by a fresh close fix; no usable GPS: by its
 * times before your stop; on board: where your phone is. Pure, tested with the iOS vectors.
 */
object RealFirst {
    const val ADVANCE_FOR = 20.0
    const val MOVING = 2.0
    const val ON_ROAD = 60.0
    const val FRESH = 180.0
    const val GHOST_AHEAD = 150.0
    const val GHOST_AT_STOP_ETA = 30.0
    const val GHOST_SHORT = 100.0
    const val HERE_FRESH = 90.0
    const val HERE_NEAR = 80.0
    const val AT_STOP = BusFusion.AT_STOP
    const val PASSED = 20.0
    const val RAW_TOP = 40.0
    const val RAW_SLACK = 3000.0
    const val ME_FRESH = 30.0
    const val ME_ACCURACY = 100.0

    enum class Source { ON_BOARD, GPS, BY_TIMES, NONE }

    sealed class Here {
        object Arriving : Here() { override fun toString() = "Arriving" }
        data class Waiting(val leaves: Double) : Here()
        object AtStop : Here() { override fun toString() = "AtStop" }
    }

    data class Fix(val metres: Double?, val at: Double, val speed: Double? = null, val stopped: Boolean = false,
                   val toMine: Double? = null, val crossTrack: Double = 0.0)

    data class Input(val stops: List<BusFusion.Stop>, val fix: Fix?, val live: Boolean, val timesAt: Double?, val mine: Int?,
                     val mineLeaves: Double? = null, val now: Double, val fromStart: Boolean = true,
                     val isTrain: Boolean = false, val onBoard: Fix? = null)

    data class Shown(val source: Source, var metres: Double?, var atFix: Boolean = false, val raw: Double? = null,
                     val fixAge: Double? = null, var advanced: Double = 0.0, var ghost: Double? = null, var here: Here? = null,
                     var why: String? = null, val estimate: BusFusion.Estimate) {
        val waiting: Double? get() = (here as? Here.Waiting)?.leaves
        val isHere: Boolean get() = here == Here.AtStop || here is Here.Waiting
    }

    fun show(x: Input): Shown {
        val e = BusFusion.fuse(fusionInput(x))
        val mine = x.mine?.takeIf { it in x.stops.indices }
        val me = x.onBoard
        if (me != null) {
            val age = max(0.0, x.now - me.at)
            val out = Shown(Source.ON_BOARD, me.metres, atFix = me.metres == null, raw = me.metres, fixAge = age, estimate = e)
            out.here = here(me, age, x, mine)
            return out
        }
        var why = "no fix"
        val f = x.fix
        if (f != null) {
            val age = max(0.0, x.now - f.at)
            why = when {
                age > FRESH -> "fix ${age.roundHalfAway()} s old"
                f.metres != null && e.note == BusFusion.Note.GPS_IGNORED -> "fix not this journey"
                f.metres == null && !plausibleOffRoad(f, x, mine) -> "fix off its road"
                else -> return byGPS(f, age, x, e, mine)
            }
        }
        return byTimes(x, e, mine, why)
    }

    fun fusionInput(x: Input): BusFusion.Input {
        val f = x.fix
        val m = f?.metres
        val fix = if (f != null && m != null) BusFusion.Fix(m, f.at, if (f.stopped) 0.0 else f.speed) else null
        return BusFusion.Input(x.stops, fix, x.live, x.timesAt, x.mine, x.mineLeaves, x.now, x.fromStart)
    }

    fun plausibleOffRoad(f: Fix, x: Input, mine: Int?): Boolean {
        val d = f.toMine
        if (mine == null || d == null) return x.now - f.at <= HERE_FRESH
        val due = x.stops[mine].times.at
        val secs = max(0.0, due?.let { it - x.now } ?: 0.0)
        return d <= RAW_TOP * secs + RAW_SLACK
    }

    fun byGPS(f: Fix, age: Double, x: Input, e: BusFusion.Estimate, mine: Int?): Shown {
        val out = Shown(Source.GPS, f.metres, atFix = f.metres == null, raw = f.metres, fixAge = age, estimate = e)
        out.here = here(f, age, x, mine)
        val m0 = f.metres ?: return out
        if (f.crossTrack > ON_ROAD) out.atFix = true
        var drawn = m0
        if (!out.atFix) drawn = advance(f, m0, age, x, mine)
        if (out.isHere && mine != null) drawn = x.stops[mine].metres
        out.metres = drawn
        out.advanced = max(0.0, drawn - m0)
        out.ghost = ghost(e.metres, drawn, x, mine)
        return out
    }

    fun advance(f: Fix, from: Double, age: Double, x: Input, mine: Int?): Double {
        val v = f.speed
        if (f.stopped || v == null || !v.isFinite() || v < MOVING) return from
        val secs = min(max(0.0, age), ADVANCE_FOR)
        val want = from + min(v, BusFusion.TOP_SPEED) * secs
        var cap = want
        nextMustStop(x, from, mine)?.let { cap = min(cap, x.stops[it].metres) }
        if (mine != null) {
            val me = x.stops[mine].metres
            if (from < me - AT_STOP) cap = min(cap, me - AT_STOP)
        }
        return max(from, min(want, cap))
    }

    fun nextMustStop(x: Input, after: Double, mine: Int?): Int? {
        val last = x.stops.size - 1
        for (i in x.stops.indices) {
            if (x.stops[i].metres <= after + 1) continue
            if (x.isTrain || i == mine || i == last || BusFusion.isTiming(x.stops, i)) return i
        }
        return null
    }

    fun ghost(estimate: Double?, drawn: Double, x: Input, mine: Int?): Double? {
        var g = estimate ?: return null
        if (!g.isFinite()) return null
        if (mine != null) {
            val me = x.stops[mine].metres
            if (drawn > me + PASSED) return null
            val due = x.stops[mine].times.at?.let { it - x.now }
            val soon = due != null && due <= GHOST_AT_STOP_ETA
            if (!soon && g > me - GHOST_SHORT) g = me - GHOST_SHORT
        }
        return if (g - drawn > GHOST_AHEAD) g else null
    }

    fun here(f: Fix, age: Double, x: Input, mine: Int?): Here? {
        if (age > HERE_FRESH || mine == null) return null
        val m = f.metres; val t = f.toMine
        val d = when { m != null -> m - x.stops[mine].metres; t != null -> -t; else -> return null }
        if (d < -HERE_NEAR || d > PASSED) return null
        if (d < -AT_STOP) return Here.Arriving
        val leaves = x.mineLeaves ?: x.stops[mine].times.leaves
        if (leaves != null && leaves - x.now > BusFusion.WAIT_LEAD) return Here.Waiting(leaves)
        return Here.AtStop
    }

    fun byTimes(x: Input, e: BusFusion.Estimate, mine: Int?, why: String): Shown {
        val b = BusFusion.byTimes(x.stops, x.now) ?: return Shown(Source.NONE, null, why = "$why, no times", estimate = e)
        if (mine != null && mine == 0 && b.next == 0 && !b.done) {
            val road = if (x.fromStart) "trip not started" else "road before your stop not known"
            return Shown(Source.NONE, null, why = "$why, $road", estimate = e)
        }
        var m = b.metres
        if (mine != null) {
            val me = x.stops[mine].metres
            val leaves = x.stops[mine].times.leaves
            val gone = leaves?.let { x.now >= it } ?: true
            if (!gone && m > me - AT_STOP) m = me - AT_STOP
        }
        return Shown(Source.BY_TIMES, m, why = why, estimate = e)
    }

    /** 0.40.1's: where its GPS and its times together put it (`BusFusion`), no ghost (Bus position: Estimated). */
    fun estimated(x: Input): Shown {
        val e = BusFusion.fuse(fusionInput(x))
        val src = if (e.metres == null) Source.NONE else if (e.raw == null) Source.BY_TIMES else Source.GPS
        val out = Shown(src, e.metres, raw = e.raw, fixAge = e.gpsAge, estimate = e)
        e.waiting?.let { out.here = Here.Waiting(it) }
        if (src == Source.NONE) out.why = "not known"
        return out
    }

    /** A new place (moved more than `JUMP` at once) glides there over `OVER` s (smoothstep), forward or back. */
    class Glide {
        companion object {
            const val OVER = 2.0
            const val JUMP = 25.0
            const val RESTART_AFTER = 20.0
        }

        var shown: Double? = null; private set
        private var at: Double? = null
        private var target: Double? = null
        private var from: Double? = null
        private var start: Double? = null

        fun step(t: Double, now: Double): Double {
            if (!t.isFinite()) return shown ?: 0.0
            val s = shown; val last = at
            if (s == null || last == null || now < last || now - last > RESTART_AFTER) {
                reset()
                shown = t; at = now; target = t
                return t
            }
            at = now
            val old = target
            if (old != null && kotlin.math.abs(t - old) > JUMP) { from = s; start = now }
            target = t
            val f = from; val st = start
            if (f == null || st == null) { shown = t; return t }
            val k = min(1.0, max(0.0, (now - st) / OVER))
            val ease = k * k * (3 - 2 * k)
            val v = f + (t - f) * ease
            if (k >= 1) { from = null; start = null }
            shown = v
            return v
        }

        fun reset() { shown = null; at = null; target = null; from = null; start = null }
    }

    fun tag(s: Shown): String = when (s.source) {
        Source.ON_BOARD -> "you’re on it"
        Source.GPS -> "GPS ${ageText(s.fixAge ?: 0.0)}"
        Source.BY_TIMES -> "by times"
        Source.NONE -> ""
    }

    fun ageText(age: Double): String {
        val a = max(0.0, age).roundHalfAway()
        return if (a < 100) "$a s" else "${(a / 60.0).roundHalfAway()} min"
    }

    fun logLine(vehicle: String, feed: String, s: Shown, estimated: Boolean = false): String {
        val parts = arrayListOf("vehicle shown", vehicle)
        when (s.source) {
            Source.ON_BOARD -> parts.add("on board: drawn where you are")
            Source.GPS -> {
                parts.add("gps $feed ${(s.fixAge ?: 0.0).roundHalfAway()} s")
                val raw = s.raw; val m = s.metres
                if (s.atFix) parts.add("real at its fix, off its road")
                else if (raw != null && m != null) {
                    parts.add("real ${BusFusion.signed(m - raw)}")
                    parts.add(s.ghost?.let { "ghost ${BusFusion.signed(it - raw)}" } ?: "no ghost")
                }
            }
            Source.BY_TIMES -> { parts.add("no gps: ${s.why ?: "no fix"}"); parts.add("by times") }
            Source.NONE -> { parts.add("no gps: ${s.why ?: "no fix"}"); parts.add("not drawn") }
        }
        when (s.here) {
            Here.Arriving -> parts.add("arriving")
            is Here.Waiting -> parts.add("waiting at your stop")
            Here.AtStop -> parts.add("at your stop")
            null -> {}
        }
        if (estimated) parts.add("estimated")
        return parts.joinToString(" · ")
    }
}
