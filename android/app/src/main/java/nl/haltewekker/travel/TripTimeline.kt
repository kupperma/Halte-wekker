package nl.haltewekker.travel

import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/**
 * (A9, iOS 0.42 / 0.42.2 `TripTimeline`) a whole trip as a line on a time axis: the walk to the stop, the wait, each
 * ride in its line's colour, a change's walk and wait, the walk at the end; the change stations named, the gap minutes,
 * the ride minutes, ticks that never overlap. Pure, tested with the iOS vectors. Times are seconds since 1970.
 */
object TripTimeline {
    enum class Kind { WALK, WAIT, RIDE }

    data class Leg(val line: String, val train: Boolean, val live: Boolean, val departure: Double, val arrival: Double,
                   val from: String, val walkBefore: Int)

    data class Part(val kind: Kind, val start: Double, val end: Double, val line: String = "", val train: Boolean = false, val live: Boolean = false)

    fun parts(leave: Double, legs: List<Leg>, end: Double): List<Part> {
        val out = ArrayList<Part>()
        var t = leave
        fun add(k: Kind, to: Double, l: Leg? = null) {
            val e = max(t, to)
            if (e - t >= 30) out.add(if (l != null) Part(k, t, e, l.line, l.train, l.live) else Part(k, t, e))
            t = e
        }
        for (l in legs) {
            add(Kind.WALK, min(t + max(0, l.walkBefore) * 60.0, l.departure))
            add(Kind.WAIT, l.departure)
            add(Kind.RIDE, l.arrival, l)
        }
        add(Kind.WALK, end)
        return out
    }

    val TICK_STEPS = listOf(10.0, 15.0, 30.0, 60.0, 120.0, 180.0, 360.0)
    const val TICK_SPACING = 56.0
    const val ROUND_TO = 5.0
    const val MIN_SPAN = 20.0
    const val MIN_WIDTH = 0.01
    const val MIN_GAP = 0.16
    const val EDGE = 0.12
    const val TIME_WIDTH = 40.0
    const val LABEL_ROOM = 6.0
    const val RISKY_CHANGE = 3.0

    data class Axis(val start: Double, val end: Double) {
        val span: Double get() = max(60.0, end - start)
        fun at(d: Double): Double { val f = (d - start) / span; return if (f.isFinite()) min(1.0, max(0.0, f)) else 0.0 }

        fun ticks(width: Double): List<Double> {
            val w = if (width.isFinite() && width > 0) width else 320.0
            val step = tickStep(span, w) * 60
            val room = TICK_SPACING / w * span
            val out = arrayListOf(start)
            var t = ceil(start / step) * step
            while (t < end) {
                if (t - out.last() >= room && end - t >= room) out.add(t)
                t += step
            }
            if (end - start >= room) out.add(end)
            return out
        }
    }

    fun tickStep(span: Double, width: Double): Double {
        val perMinute = width / max(60.0, span) * 60
        for (m in TICK_STEPS) if (m * perMinute >= TICK_SPACING) return m
        return TICK_STEPS.last()
    }

    fun axis(rows: List<List<Part>>): Axis? {
        val a = rows.mapNotNull { it.firstOrNull()?.start }.minOrNull() ?: return null
        val b = rows.mapNotNull { it.lastOrNull()?.end }.maxOrNull() ?: return null
        val r = ROUND_TO * 60
        val s = floor(a / r) * r
        var e = ceil(b / r) * r
        if (e - s < MIN_SPAN * 60) e = s + MIN_SPAN * 60
        return Axis(s, e)
    }

    data class Placed(val part: Part, val x: Double, val width: Double)

    fun place(parts: List<Part>, a: Axis): List<Placed> = parts.map { p ->
        val x = a.at(p.start)
        val w = max(MIN_WIDTH, a.at(p.end) - x)
        val cx = min(x, 1 - MIN_WIDTH)
        Placed(p, cx, min(w, 1 - cx))
    }

    enum class Anchor { LEADING, CENTER, TRAILING }

    data class Label(val text: String, val x: Double, val anchor: Anchor)

    fun anchor(x: Double): Anchor = if (x < EDGE) Anchor.LEADING else if (x > 1 - EDGE) Anchor.TRAILING else Anchor.CENTER

    fun changeLabels(legs: List<Leg>, parts: List<Placed>, ends: Pair<Double, Double>?): List<Label> {
        val rides = parts.filter { it.part.kind == Kind.RIDE }
        if (legs.size <= 1 || rides.size != legs.size) return emptyList()
        val out = ArrayList<Label>()
        var last = -1.0
        for (i in 1 until legs.size) {
            val x = rides[i - 1].x + rides[i - 1].width
            if (x - last < MIN_GAP) continue
            if (ends != null && (abs(x - ends.first) < MIN_GAP || abs(x - ends.second) < MIN_GAP)) continue
            out.add(Label(legs[i].from, x, anchor(x)))
            last = x
        }
        return out
    }

    data class Ends(val leave: Double, val arrive: Double)

    fun ends(start: Double, end: Double, width: Double, label: Double = TIME_WIDTH): Ends {
        val w = if (width.isFinite() && width > 0) width else 320.0
        val lw = min(0.5, label / w)
        val g = LABEL_ROOM / w
        var a = start
        var b = end - lw
        if (b < a + lw + g) { val mid = (start + end) / 2; a = mid - lw - g / 2; b = mid + g / 2 }
        if (a < 0) { b -= a; a = 0.0 }
        if (b + lw > 1) { val over = b + lw - 1; a -= over; b -= over }
        return Ends(max(0.0, a), max(0.0, b))
    }

    enum class Tone { PLAIN, TIGHT, RISKY }

    data class GapLabel(val text: String, val x: Double, val below: Boolean, val lane: Int, val tone: Tone)

    fun textWidth(s: String): Double {
        var w = 6.0
        s.codePoints().forEach { w += if (it < 128) 6.5 else 14.0 }
        return w
    }

    fun gapText(walk: Int, wait: Int, change: Boolean): String = when {
        // (0.10.11, iOS 0.42.15) words, no walking emoji
        walk > 0 && wait > 0 -> "$walk walk + $wait wait"
        walk > 0 -> "$walk min walk"
        else -> if (change) "$wait min" else "$wait wait"
    }

    private fun roundHalf(x: Double) = floor(x + 0.5).toInt()

    fun gapLabels(placed: List<Placed>, width: Double, changeNeeds: Double? = null): List<GapLabel> {
        val w = if (width.isFinite() && width > 0) width else 320.0
        val runs = ArrayList<Pair<Int, Int>>()
        var i = 0
        while (i < placed.size) {
            if (placed[i].part.kind == Kind.RIDE) { i++; continue }
            var j = i
            while (j + 1 < placed.size && placed[j + 1].part.kind != Kind.RIDE) j++
            runs.add(i to j); i = j + 1
        }
        val out = ArrayList<GapLabel>()
        val laneEnds = doubleArrayOf(-1.0, -1.0)
        for ((from, to) in runs) {
            var walk = 0.0; var wait = 0.0
            for (k in from..to) { val d = placed[k].part.end - placed[k].part.start; if (placed[k].part.kind == Kind.WALK) walk += d else wait += d }
            val wm = if (walk > 0) max(1, roundHalf(walk / 60)) else 0
            val tm = if (wait > 0) max(1, roundHalf(wait / 60)) else 0
            if (wm + tm <= 0) continue
            val change = from > 0 && to < placed.size - 1
            val text = gapText(wm, tm, change)
            var tone = Tone.PLAIN
            if (change) {
                val total = (walk + wait) / 60
                if (total < RISKY_CHANGE) tone = Tone.RISKY else if (changeNeeds != null && total < changeNeeds) tone = Tone.TIGHT
            }
            val x0 = placed[from].x
            val x1 = placed[to].x + placed[to].width
            val half = textWidth(text) / w / 2
            val centre = min(max((x0 + x1) / 2, half), 1 - half)
            if ((x1 - x0) * w >= textWidth(text) + 4) { out.add(GapLabel(text, centre, false, 0, tone)); continue }
            val gap = 4 / w
            val lane = laneEnds.indices.firstOrNull { laneEnds[it] + gap <= centre - half } ?: continue
            laneEnds[lane] = centre + half
            out.add(GapLabel(text, centre, true, lane, tone))
        }
        return out
    }

    data class RideLabel(val index: Int, val text: String)

    fun rideLabels(placed: List<Placed>, width: Double): List<RideLabel> {
        val w = if (width.isFinite() && width > 0) width else 320.0
        val out = ArrayList<RideLabel>()
        placed.forEachIndexed { i, p ->
            if (p.part.kind != Kind.RIDE) return@forEachIndexed
            val text = "${max(1, roundHalf((p.part.end - p.part.start) / 60))} min"
            if (p.width * w >= textWidth(text) + 8) out.add(RideLabel(i, text))
        }
        return out
    }
}
