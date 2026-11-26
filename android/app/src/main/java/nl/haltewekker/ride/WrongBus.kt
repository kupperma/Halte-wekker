package nl.haltewekker.ride

import kotlin.math.abs
import kotlin.math.max

// (A7) iOS 0.39.1 `WrongBus.swift`: a leg never started by its timetable long before it leaves, "you're on the 154,
// not your 306", and another line's bus at your stop. Plain values, tested with the iOS vectors (`WrongBusTest`).

object TimetableStart {
    const val BEFORE = 120.0
    const val AFTER = 20 * 60.0

    fun allowed(now: Double, departure: Double): Boolean { val dt = now - departure; return dt >= -BEFORE && dt < AFTER }

    fun waitLine(label: String, leaves: String, minutes: Int) =
        "wait · not by its timetable: $label leaves $leaves (in ${max(0, minutes)} min) · finding the one you're on"
}

object WrongBus {
    const val ID_PREFIX = "wrongbus-"
    const val GPS_FOR = 75.0
    const val GPS_GAP = 180.0
    const val FRESH = 120.0

    data class Run(val first: Double, val last: Double)
    data class Alert(val title: String, val body: String, val tripId: String)

    fun note(runs: Map<String, Run>, fitted: List<String>, now: Double): Map<String, Run> {
        val out = runs.filterValues { now - it.last <= GPS_GAP }.toMutableMap()
        for (id in fitted) {
            val r = out[id]
            out[id] = if (r != null) r.copy(last = max(r.last, now)) else Run(now, now)
        }
        return out
    }

    fun sure(run: Run?, split: Boolean, now: Double): Boolean {
        if (split) return true
        val r = run ?: return false
        if (now - r.last > FRESH) return false
        return r.last - r.first >= GPS_FOR
    }

    fun differs(plannedLine: String, plannedTo: String, line: String, to: String): Boolean {
        val pl = norm(plannedLine); val ol = norm(line)
        if (pl.isEmpty() || ol.isEmpty()) return false
        if (pl != ol) return true
        val pt = norm(plannedTo); val ot = norm(to)
        return pt.isNotEmpty() && ot.isNotEmpty() && pt != ot
    }

    fun due(differs: Boolean, sure: Boolean, byHand: Boolean, told: Boolean) = differs && sure && !byHand && !told

    fun title(line: String, to: String, planned: String): String {
        val w = if (to.trim().isEmpty()) "" else " to ${to.trim()}"
        return "You’re on the $line$w, not your $planned"
    }

    fun fix(getOff: String, nextStop: Boolean, then: String?, at: String?): String {
        if (then == null || at == null) return "Stay on to $getOff: it gets you there"
        return if (nextStop) "Get off at $getOff — $then back at $at" else "Stay on to $getOff — $then from there at $at"
    }

    const val NO_FIX = "Get off at the next stop, and plan again from there"

    fun id(tripStart: Double) = ID_PREFIX + tripStart.toLong().toString()

    fun logLine(label: String, to: String, planned: String, fix: String) =
        "wrong bus · on $label${if (to.isEmpty()) "" else " to $to"}, planned $planned · $fix"

    fun norm(s: String) = s.trim().lowercase()
}

object OtherAtStop {
    const val ID_PREFIX = "otherbus-"
    const val NEAR = 150.0
    const val AT_YOU = 80.0
    const val FIX_FRESH = 120.0
    const val WITHIN = 10 * 60.0
    const val LEAVING = 5 * 60.0

    data class Seen(val tripId: String, val line: String, val to: String, val departure: Double, val metres: Double?, val fixAge: Double?)
    data class Yours(val line: String, val departure: Double, val lines: Set<String>)

    fun pick(seen: List<Seen>, yours: Yours?, youToStop: Double?, now: Double): Seen? {
        val y = yours ?: return null
        val d = youToStop ?: return null
        if (!d.isFinite() || d > NEAR) return null
        val wait = y.departure - now
        if (wait < -60 || wait > WITHIN) return null
        val mine = y.lines.map(WrongBus::norm).toSet() + WrongBus.norm(y.line)
        val here = seen.filter { s ->
            if (WrongBus.norm(s.line) in mine || WrongBus.norm(s.line).isEmpty()) return@filter false
            val m = s.metres ?: return@filter false
            val a = s.fixAge ?: return@filter false
            if (!m.isFinite() || m > AT_YOU || a < -60 || a > FIX_FRESH) return@filter false
            abs(s.departure - now) <= LEAVING && s.departure <= y.departure + 60
        }
        return here.minWithOrNull(compareBy<Seen> { it.metres ?: 0.0 }.thenBy { it.tripId })
    }

    fun words(s: Seen, yours: Yours, now: Double): Pair<String, String> {
        val to = s.to.trim()
        val title = "That’s the ${s.line}${if (to.isEmpty()) "" else " to $to"} — not yours"
        val m = kotlin.math.floor((yours.departure - now) / 60).toInt()
        return title to "Your ${yours.line}: ${if (m < 1) "due" else "$m min"}"
    }

    fun id(tripId: String) = ID_PREFIX + tripId
}
