package nl.haltewekker.ride

import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/** (A7) iOS `ChangeRoom` (the part the change guide needs): the room a change needs after a slow bus. */
object ChangeRoom {
    const val USUAL = 2.0
    fun needed(afterGrade: String?) = when (afterGrade) { "C" -> 6.0; "B" -> 4.0; else -> USUAL }
    fun feederNeeded(isTrain: Boolean, grade: String?) = if (isTrain) USUAL else needed(grade)

    data class Note(val red: Boolean, val why: String?)
    fun changeNote(minutes: Int, walk: Int, isTrain: Boolean, grade: String?): Note {
        val room = (minutes - walk).toDouble(); val need = feederNeeded(isTrain, grade)
        if (room >= need) return Note(false, null)
        return Note(true, if (room >= USUAL) "slow bus, needs ${need.toInt()}" else null)
    }
}

/**
 * (A7/A8) iOS 0.39 `ChangeGuide` with 0.39.1's `MissRule`: the change ahead ("Platform 5 → 7", "3 min walk", "4 min to
 * change") and, when your ride's live times make it too late, "You’ll miss the 08:12 — take the 08:27 from platform 4".
 */
object ChangeGuide {
    const val LEAST = 1.0
    const val LEARNED_EXTRA_MAX = 2.0

    data class Ride(val tripId: String, val line: String, val isTrain: Boolean, val departure: Double, val platform: String? = null, val walk: Int = 0)

    data class Guide(
        val target: Ride, val minutes: Int, val platforms: String?, val walk: String?, val countdown: String,
        val tight: Boolean, val missed: Boolean, val planned: Ride?, val missText: String?,
    ) {
        val lockLine: String get() = listOfNotNull(platforms, walk).joinToString(" · ")
    }

    fun need(walk: Int, learned: Double?): Double {
        val w = max(0, walk).toDouble()
        val mine = learned?.takeIf { it.isFinite() }?.let { min(it, w + LEARNED_EXTRA_MAX) } ?: w
        return max(LEAST, max(w, mine))
    }

    fun platforms(arrive: String?, next: Ride): String? {
        val a = clean(arrive); val d = clean(next.platform)
        return when {
            a != null && d != null && next.isTrain -> if (a == d) "Same platform ($a)" else "Platform $a → $d"
            a != null && !next.isTrain -> "Platform $a → bus ${next.line}"
            a == null && d != null && next.isTrain -> "To platform $d"
            a != null && d == null -> "Arrive at platform $a"
            else -> null
        }
    }

    fun guide(arrive: Double, arrivePlatform: String?, fromTrain: Boolean, grade: String?, next: Ride, later: List<Ride>,
              learned: Double?, now: Double, hhmm: (Double) -> String, atChange: Boolean = false, notLeft: Boolean = false): Guide {
        val from = max(arrive, now)
        val needed = need(next.walk, learned)
        val missed = MissRule.missed(arrive, next.departure, needed, now, atChange, notLeft)
        var target = next
        var instead: Ride? = null
        if (missed) { instead = nextMade(next, later, from, learned); if (instead != null) target = instead }
        val m = floor((target.departure - from) / 60).toInt()
        val note = ChangeRoom.changeNote(m, max(0, target.walk), fromTrain, grade)
        val countdown = if (m < 0) "It leaves before you’re there" else "$m min to change"
        val walk = if (target.walk > 0) "${target.walk} min walk" else null
        val text = if (missed) missWords(next, instead, hhmm) else null
        return Guide(target, m, platforms(arrivePlatform, target), walk, countdown, missed || note.red, missed, if (missed) next else null, text)
    }

    fun nextMade(after: Ride, later: List<Ride>, from: Double, learned: Double?): Ride? =
        later.filter { it.tripId != after.tripId && it.departure > after.departure }.sortedBy { it.departure }
            .firstOrNull { (it.departure - from) / 60 >= need(it.walk, learned) }

    fun missWords(planned: Ride, instead: Ride?, hhmm: (Double) -> String): String {
        val i = instead ?: return "You’ll likely miss the ${hhmm(planned.departure)}"
        val head = "You’ll miss the ${hhmm(planned.departure)} — "
        if (!i.isTrain) return head + "take bus ${i.line} at ${hhmm(i.departure)}"
        return head + "take the ${hhmm(i.departure)}" + (clean(i.platform)?.let { " from platform $it" } ?: "")
    }

    fun pickPlan(firstRides: List<Pair<String, Double>>, instead: Ride): Int? {
        val k = firstRides.indexOfFirst { it.first == instead.tripId }
        if (k >= 0) return k
        return firstRides.indexOfFirst { abs(it.second - instead.departure) <= 60 }.takeIf { it >= 0 }
    }

    private fun clean(s: String?): String? = s?.trim()?.takeIf { it.isNotEmpty() }
}

/** iOS 0.39.1 `MissRule`: at the change, missed only once its live departure has gone by a minute without you. */
object MissRule {
    const val GRACE = 60.0
    const val AT_STOP_SLACK = 40.0
    const val FIX_FRESH = 180.0

    fun notLeft(vehicleMetres: Double?, stopMetres: Double?, fixAge: Double?): Boolean {
        val v = vehicleMetres ?: return false; val s = stopMetres ?: return false; val a = fixAge ?: return false
        if (!v.isFinite() || !s.isFinite() || !a.isFinite()) return false
        if (a < -60 || a > FIX_FRESH) return false
        return v <= s + AT_STOP_SLACK
    }

    fun missed(arrive: Double, departure: Double, need: Double, now: Double, atChange: Boolean, notLeft: Boolean): Boolean {
        if (atChange) { if (notLeft) return false; return now - departure > GRACE }
        val from = max(arrive, now)
        return (departure - from) / 60 < need
    }
}
