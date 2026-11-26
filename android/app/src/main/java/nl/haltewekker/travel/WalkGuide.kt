package nl.haltewekker.travel

import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/**
 * (A9, iOS 0.41 `WalkGuide`) walking turn by turn to the stop: "In 40 m · turn right onto Hoogstraat", with a big
 * arrow. The arrow from the shape (the direction into a step's start against the direction out of it) when the
 * route's own maneuver doesn't say (`Turn.of`, OSRM's type and modifier); following the steps (never back, not while
 * off the route), the buzz 30 m before a turn, a new route after 10 s more than 40 m off (at most every 20 s), there
 * within 25 m. Pure, tested with the iOS vectors.
 */
object WalkGuide {
    const val ADVANCE_WITHIN = 15.0
    const val WARN_AT = 30.0
    const val WARN_STEP_AT_LEAST = 40.0
    const val OFF_ROUTE_METRES = 40.0
    const val OFF_ROUTE_FOR = 10.0
    const val REROUTE_EVERY = 20.0
    const val ARRIVE_WITHIN = 25.0
    const val WORST_FIX = 65.0
    const val BEARING_SPAN = 12.0
    const val DEFAULT_SPEED = 1.2

    enum class Turn(val glyph: String, val words: String) {
        DEPART("↑", "Start"), STRAIGHT("↑", "Straight on"), SLIGHT_LEFT("↖", "Keep left"), LEFT("←", "Turn left"),
        SHARP_LEFT("↙", "Sharp left"), SLIGHT_RIGHT("↗", "Keep right"), RIGHT("→", "Turn right"), SHARP_RIGHT("↘", "Sharp right"),
        U_TURN("↩", "Turn around"), ARRIVE("◉", "Arrive");

        /** Arrow rotation in degrees for drawing one "up" arrow (0: straight on; the U-turn and the stop drawn apart). */
        val degrees: Float get() = when (this) {
            SLIGHT_LEFT -> -45f; LEFT -> -90f; SHARP_LEFT -> -135f; SLIGHT_RIGHT -> 45f; RIGHT -> 90f; SHARP_RIGHT -> 135f
            U_TURN -> 180f; else -> 0f
        }

        companion object {
            /** (Android) OSRM's maneuver (type, modifier): its arrow; null when it doesn't say (the shape decides). */
            fun of(type: String?, modifier: String?): Turn? {
                when (type) {
                    "depart" -> return DEPART
                    "arrive" -> return ARRIVE
                }
                return when (modifier) {
                    "uturn" -> U_TURN
                    "sharp right" -> SHARP_RIGHT
                    "right" -> RIGHT
                    "slight right" -> SLIGHT_RIGHT
                    "straight" -> STRAIGHT
                    "slight left" -> SLIGHT_LEFT
                    "left" -> LEFT
                    "sharp left" -> SHARP_LEFT
                    else -> null
                }
            }
        }
    }

    fun change(from: Double, to: Double): Double {
        val d = (to - from) % 360
        val w = ((d + 540) % 360) - 180
        return if (w == -180.0) 180.0 else w
    }

    fun turn(change: Double): Turn {
        val a = abs(change)
        val right = change > 0
        if (a < 20) return Turn.STRAIGHT
        if (a < 45) return if (right) Turn.SLIGHT_RIGHT else Turn.SLIGHT_LEFT
        if (a < 120) return if (right) Turn.RIGHT else Turn.LEFT
        if (a < 165) return if (right) Turn.SHARP_RIGHT else Turn.SHARP_LEFT
        return Turn.U_TURN
    }

    private fun words(text: String) = text.lowercase().split(Regex("[^\\p{L}]+")).filter { it.isNotEmpty() }

    fun side(text: String): Boolean? {
        val w = words(text)
        val r = w.any { it in setOf("right", "rechts", "rechtsaf") }
        val l = w.any { it in setOf("left", "links", "linksaf") }
        if (r == l) return null
        return r
    }

    fun saysArrive(text: String): Boolean {
        val t = text.lowercase()
        return listOf("destination", "arrive", "bestemming", "aankomst").any { t.contains(it) }
    }

    fun short(text: String): String {
        var t = text.split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ")
        while (t.isNotEmpty() && t.last() in ".,;") t = t.dropLast(1)
        return t
    }

    fun lowerFirst(text: String): String {
        val first = text.firstOrNull() ?: return text
        if (!first.isUpperCase()) return text
        val firstWord = text.split(" ").firstOrNull() ?: text
        if (firstWord.length > 1 && firstWord.all { it.isUpperCase() || !it.isLetter() }) return text
        return first.lowercase() + text.drop(1)
    }

    private fun roundHalf(x: Double): Long = floor(x + 0.5).toLong()

    fun metres(m: Double): String {
        val v = if (m.isFinite()) max(0.0, m) else 0.0
        if (v < 100) return "${max(5L, roundHalf(v / 5) * 5)} m"
        if (v < 995) return "${roundHalf(v / 10) * 10} m"
        return String.format(java.util.Locale.ROOT, "%.1f km", v / 1000)
    }

    fun phrase(metres: Double, step: Step): String {
        val w = step.text.ifEmpty { step.turn.words }
        return "In ${metres(metres)} · ${lowerFirst(w)}"
    }

    fun spoken(metres: Double, step: Step): String {
        val w = step.text.ifEmpty { step.turn.words }
        val d = metres(metres).replace(" km", " kilometres").replace(" m", " metres")
        return "In $d, ${lowerFirst(w)}"
    }

    fun street(text: String): String? {
        val t = short(text)
        var best: Int? = null
        for (m in listOf(" onto ", " into ", " on ", " naar ", " op ")) {
            val r = t.lastIndexOf(m, ignoreCase = true)
            if (r >= 0) { val up = r + m.length; if (best == null || up > best) best = up }
        }
        val start = best ?: return null
        var s = t.substring(start).trim()
        for (article in listOf("de ", "het ", "the ")) if (s.lowercase().startsWith(article)) s = s.drop(article.length)
        return s.ifEmpty { null }
    }

    fun lockLine(metres: Double, step: Step, stop: String): String {
        val w = step.text.ifEmpty { step.turn.words }
        val name = if (step.turn == Turn.ARRIVE) stop else (street(step.text) ?: w)
        val cut = if (name.length > 32) name.take(31) + "…" else name
        return "${step.turn.glyph} ${metres(metres)} · $cut"
    }

    // MARK: the route

    /** A step as the router gives it: its words, length, shape, and (Android, OSRM) its maneuver's arrow when it says one. */
    data class RawStep(val text: String, val distance: Double, val path: List<GeoPoint>, val maneuver: Turn? = null)

    data class Step(val text: String, val turn: Turn, val start: Double, val end: Double) {
        val length: Double get() = max(0.0, end - start)
    }

    data class Route(val path: List<GeoPoint>, val steps: List<Step>, val length: Double)

    fun route(raw: List<RawStep>): Route {
        val path = ArrayList<GeoPoint>()
        val starts = ArrayList<Double>()
        var total = 0.0
        for (s in raw) {
            starts.add(total)
            for (p in s.path) {
                if (!p.lat.isFinite() || !p.lon.isFinite()) continue
                val last = path.lastOrNull()
                if (last != null) {
                    if (last == p) continue
                    total += Geo.metres(last, p)
                }
                path.add(p)
            }
        }
        val kept = raw.indices.filter { short(raw[it].text).isNotEmpty() }
        if (kept.isEmpty() || total <= 0) return Route(path, listOf(Step("", Turn.ARRIVE, 0.0, total)), total)
        val steps = ArrayList<Step>()
        for ((k, i) in kept.withIndex()) {
            val start = if (k == 0) 0.0 else starts[i]
            val end = if (k + 1 < kept.size) starts[kept[k + 1]] else total
            val text = short(raw[i].text)
            val t = when {
                k == 0 -> Turn.DEPART
                k == kept.size - 1 && (end - start < WARN_AT || saysArrive(text) || raw[i].maneuver == Turn.ARRIVE) -> Turn.ARRIVE
                else -> raw[i].maneuver?.takeIf { it != Turn.DEPART && it != Turn.ARRIVE } ?: turn(start, path, text)
            }
            steps.add(Step(text, t, start, max(start, end)))
        }
        if (steps.size < 2 || steps.last().turn != Turn.ARRIVE) steps.add(Step("", Turn.ARRIVE, total, total))
        return Route(path, steps, total)
    }

    fun turn(along: Double, path: List<GeoPoint>, text: String): Turn {
        val side = side(text)
        val b = Geo.pointAtMetres(along - BEARING_SPAN, path)
        val a = Geo.pointAtMetres(along, path)
        val c = Geo.pointAtMetres(along + BEARING_SPAN, path)
        if (b == null || a == null || c == null || Geo.metres(b, a) <= 2 || Geo.metres(a, c) <= 2) {
            val s = side ?: return Turn.STRAIGHT
            return if (s) Turn.RIGHT else Turn.LEFT
        }
        val t = turn(change(Geo.bearing(b, a), Geo.bearing(a, c)))
        if (t == Turn.STRAIGHT && side != null) return if (side) Turn.SLIGHT_RIGHT else Turn.SLIGHT_LEFT
        return t
    }

    // MARK: following it

    data class Position(val step: Int, val along: Double, val off: Double, val toTurn: Double, val left: Double, val advanced: Boolean)

    fun locate(p: GeoPoint, r: Route, step: Int, lastAlong: Double?): Position? {
        if (r.steps.isEmpty()) return null
        val pass = Geo.pass(p, r.path, lastAlong, 20.0, lastAlong) ?: return null
        val along = pass.projection.along
        val off = pass.projection.crossTrack
        val last = r.steps.size - 1
        var k = min(max(0, step), last)
        if (off <= OFF_ROUTE_METRES) while (k < last && r.steps[k].end - along <= ADVANCE_WITHIN) k++
        return Position(k, along, off, max(0.0, r.steps[k].end - along), max(0.0, r.length - along), k > step)
    }

    fun next(r: Route, step: Int): Step? = if (r.steps.isEmpty()) null else r.steps[min(max(0, step + 1), r.steps.size - 1)]

    fun then(r: Route, step: Int): Step? {
        val i = step + 2
        return if (i >= 1 && i < r.steps.size) r.steps[i] else null
    }

    fun warn(pos: Position, r: Route, warned: Boolean): Boolean {
        if (warned || pos.off > OFF_ROUTE_METRES || pos.step >= r.steps.size - 1) return false
        val s = r.steps[pos.step]
        return s.length >= WARN_STEP_AT_LEAST && pos.toTurn <= WARN_AT && pos.toTurn > ADVANCE_WITHIN
    }

    data class OffRoute(val since: Double? = null, val lastReroute: Double? = null)

    fun offRoute(s: OffRoute, off: Double, accuracy: Double, now: Double): Pair<OffRoute, Boolean> {
        if (accuracy < 0 || accuracy > WORST_FIX || !off.isFinite()) return s to false
        if (off <= OFF_ROUTE_METRES) return s.copy(since = null) to false
        val since = s.since ?: now
        val long = now - since >= OFF_ROUTE_FOR
        val free = s.lastReroute?.let { now - it >= REROUTE_EVERY } ?: true
        if (!(long && free)) return s.copy(since = since) to false
        return OffRoute(null, now) to true
    }

    fun arrived(metres: Double, accuracy: Double): Boolean = accuracy >= 0 && accuracy <= WORST_FIX && metres.isFinite() && metres <= ARRIVE_WITHIN

    fun split(path: List<GeoPoint>, along: Double): Pair<List<GeoPoint>, List<GeoPoint>> {
        if (path.size < 2 || along <= 0) return emptyList<GeoPoint>() to path
        val walked = arrayListOf(path[0])
        var acc = 0.0
        for (i in 1 until path.size) {
            val l = Geo.metres(path[i - 1], path[i])
            if (acc + l >= along) {
                val cut = Geo.pointAtMetres(along, path) ?: path[i]
                walked.add(cut)
                return walked to (listOf(cut) + path.subList(i, path.size))
            }
            acc += l
            walked.add(path[i])
        }
        return walked to listOf(path.last())
    }

    // MARK: will you make it

    enum class Pace { FINE, FASTER, HURRY, GONE }

    data class Hurry(val walkMinutes: Int, val leavesIn: Int?, val pace: Pace?, val text: String?)

    fun hurry(left: Double, speed: Double?, leaves: Double?, now: Double, what: String): Hurry {
        val v = speed?.takeIf { it.isFinite() && it >= 0.5 && it <= 2.5 } ?: DEFAULT_SPEED
        val m = if (left.isFinite()) max(0.0, left) else 0.0
        val walkSecs = m / v
        val walkMinutes = if (m <= 0) 0 else max(1, ceil(walkSecs / 60).toInt())
        if (leaves == null) return Hurry(walkMinutes, null, null, null)
        val secs = leaves - now
        val name = what.take(1).uppercase() + what.drop(1)
        if (secs <= 30) return Hurry(walkMinutes, 0, Pace.GONE, "$name leaves now")
        val mins = floor(secs / 60).toInt()
        val spare = secs - walkSecs
        val (pace, hint) = when {
            spare >= 60 -> Pace.FINE to "you’ll make it"
            secs - walkSecs / 1.25 >= 0 -> Pace.FASTER to "walk a bit faster"
            else -> Pace.HURRY to "hurry, it’s tight"
        }
        val whenText = if (mins <= 0) "in under a minute" else "in $mins min"
        return Hurry(walkMinutes, mins, pace, "$name leaves $whenText · $hint")
    }

    fun left(metres: Double, minutes: Int): String = "${max(1, minutes)} min · ${metres(metres)} to go"
}
