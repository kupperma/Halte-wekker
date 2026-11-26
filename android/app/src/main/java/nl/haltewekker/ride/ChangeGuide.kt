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

    data class Ride(val tripId: String, val line: String, val isTrain: Boolean, val departure: Double, val platform: String? = null, val walk: Int = 0,
                    /** (A9, iOS 0.42.3) where it leaves from, when known (`MissCall.sane`). */
                    val from: nl.haltewekker.core.GeoPoint? = null)

    data class Guide(
        val target: Ride, val minutes: Int, val platforms: String?, val walk: String?, val countdown: String,
        val tight: Boolean, val missed: Boolean, val planned: Ride?, val missText: String?,
        /** (A9, iOS 0.42.3) the call, and "Look out for it" / "Tight — run". */
        val call: MissCall.Call = MissCall.Call.FINE, val note: String? = null,
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
              learned: Double?, now: Double, hhmm: (Double) -> String, atChange: Boolean = false, notLeft: Boolean = false,
              seen: MissCall.Next? = null, fresh: Boolean = true, call: MissCall.Call? = null,
              feeding: MissCall.Feeding? = null, changeAt: List<nl.haltewekker.core.GeoPoint> = emptyList()): Guide {
        val from = max(arrive, now)
        var c = call ?: call(arrive, next, learned, now, atChange, notLeft, seen, fresh)
        var target = next
        var instead: Ride? = null
        if (c == MissCall.Call.MISSED) {
            instead = nextMade(next, MissCall.sane(later, next, feeding, changeAt), from, learned)
            // (0.42.3) on the way with no sane one instead: tight, run (at the change it has gone: "likely missed")
            if (instead != null) target = instead else if (!atChange) c = MissCall.Call.TIGHT
        }
        val missed = c == MissCall.Call.MISSED
        val m = floor((target.departure - from) / 60).toInt()
        val note = ChangeRoom.changeNote(m, max(0, target.walk), fromTrain, grade)
        val (countdown, words) = countdownWords(c, m)
        val walk = if (target.walk > 0) "${target.walk} min walk" else null
        val text = if (missed) missWords(next, instead, hhmm) else null
        val tight = missed || note.red || c == MissCall.Call.TIGHT || c == MissCall.Call.MAYBE
        return Guide(target, m, platforms(arrivePlatform, target), walk, countdown, tight, missed, if (missed) next else null, text, c, words)
    }

    fun call(arrive: Double, next: Ride, learned: Double?, now: Double, atChange: Boolean, notLeft: Boolean = false,
             seen: MissCall.Next? = null, fresh: Boolean = true): MissCall.Call {
        if (atChange) {
            val n = seen ?: MissCall.Next(true, if (notLeft) MissCall.Seen.NOT_LEFT else MissCall.Seen.NONE)
            return MissCall.atChange(next.departure, n, now)
        }
        return MissCall.onTheWay(arrive, next.departure, need(next.walk, learned), now, fresh)
    }

    fun countdownWords(c: MissCall.Call, m: Int): Pair<String, String?> = when (c) {
        MissCall.Call.LOOK_OUT -> "Should be leaving now" to "Look out for it"
        MissCall.Call.MAYBE -> "May have left" to "Look out for it"
        MissCall.Call.TIGHT -> if (m <= 0) "Tight — run" to null else "$m min to change" to "Tight — run"
        else -> (if (m < 0) "It leaves before you’re there" else "$m min to change") to null
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

/**
 * (A9, iOS 0.42.3 `MissCall`) no false "You'll miss" at a change: a next ride without live times or its own GPS is
 * looked out for, not missed, until 3 min past its time (never within 150 m of its stop); with live times a minute's
 * grace, then "May have left"; its own fresh GPS decides first; a miss is told once it held a minute; on the way,
 * missed only more than a minute short with fresh data (else "Tight — run"); the ride offered instead continues from
 * the change. Pure, tested with the iOS vectors.
 */
object MissCall {
    const val MARGIN = 1.0
    const val GPS_FRESH = 90.0
    const val LIVE_FRESH = 120.0
    const val UNSURE = 180.0
    const val NEAR_STOP = 150.0
    const val HOLD = 60.0
    const val CHANGE_RADIUS = 500.0
    const val GONE_SLACK = 150.0

    enum class Call { FINE, TIGHT, LOOK_OUT, MAYBE, MISSED }
    enum class Seen { NONE, NOT_LEFT, GONE }

    data class Next(val live: Boolean = true, val seen: Seen = Seen.NONE, val youMetres: Double? = null)
    data class Feeding(val tripId: String?, val line: String, val isTrain: Boolean)

    fun seen(vehicleMetres: Double?, stopMetres: Double?, fixAge: Double?): Seen {
        if (MissRule.notLeft(vehicleMetres, stopMetres, fixAge)) return Seen.NOT_LEFT
        if (vehicleMetres == null || stopMetres == null || fixAge == null || !vehicleMetres.isFinite() || !stopMetres.isFinite() || !fixAge.isFinite()) return Seen.NONE
        if (fixAge < -60 || fixAge > GPS_FRESH) return Seen.NONE
        return if (vehicleMetres > stopMetres + GONE_SLACK) Seen.GONE else Seen.NONE
    }

    fun fresh(gpsAge: Double?, liveAge: Double?): Boolean =
        (gpsAge != null && gpsAge.isFinite() && gpsAge >= -60 && gpsAge <= GPS_FRESH) ||
            (liveAge != null && liveAge.isFinite() && liveAge >= -60 && liveAge <= LIVE_FRESH)

    fun onTheWay(arrive: Double, departure: Double, need: Double, now: Double, fresh: Boolean): Call {
        val short = need - (departure - max(arrive, now)) / 60
        if (short <= 0) return Call.FINE
        if (short > MARGIN && fresh) return Call.MISSED
        return Call.TIGHT
    }

    fun atChange(departure: Double, next: Next, now: Double): Call {
        val past = now - departure
        when (next.seen) {
            Seen.NOT_LEFT -> return Call.FINE
            Seen.GONE -> if (past > -MissRule.GRACE) return Call.MISSED
            Seen.NONE -> {}
        }
        val near = (next.youMetres ?: Double.POSITIVE_INFINITY) <= NEAR_STOP
        if (!next.live) {
            if (past < 0) return Call.FINE
            if (past <= UNSURE || near) return Call.LOOK_OUT
            return Call.MISSED
        }
        if (past <= MissRule.GRACE) return Call.FINE
        if (past <= UNSURE) return if (near) Call.LOOK_OUT else Call.MAYBE
        return Call.MISSED
    }

    data class Hold(val key: String? = null, val since: Double? = null, val told: Boolean = false)
    data class Step(val hold: Hold, val call: Call, val retract: Boolean)

    fun step(h: Hold, call: Call, key: String, now: Double): Step {
        val n = if (h.key == key) h else Hold(key)
        if (call != Call.MISSED) return Step(n.copy(since = null, told = false), call, n.told)
        val since = n.since ?: now
        if (n.told || now - since >= HOLD) return Step(n.copy(since = since, told = true), Call.MISSED, false)
        return Step(n.copy(since = since), Call.MAYBE, false)
    }

    fun sane(later: List<ChangeGuide.Ride>, planned: ChangeGuide.Ride, feeding: Feeding?, changeAt: List<nl.haltewekker.core.GeoPoint>): List<ChangeGuide.Ride> =
        later.filter { r ->
            if (feeding != null) {
                val id = feeding.tripId
                if (!id.isNullOrEmpty() && r.tripId == id) return@filter false
                val sameAsFeeding = r.line == feeding.line && r.isTrain == feeding.isTrain
                val plannedSame = planned.line == feeding.line && planned.isTrain == feeding.isTrain
                if (sameAsFeeding && !plannedSame) return@filter false
            }
            val p = r.from
            if (p != null && changeAt.isNotEmpty() && changeAt.none { nl.haltewekker.core.Geo.metres(it, p) <= CHANGE_RADIUS }) return@filter false
            true
        }
}

/**
 * (A9, iOS 0.42.3 `ShortLeg`) a short hop never rings: a leg within the wake distance (or 800 m) wakes quietly with
 * "Get off at the next stop"; nothing rings in a leg's first minute. Pure, tested with the iOS vectors.
 */
object ShortLeg {
    const val NO_RING_FOR = 60.0
    const val START_WINDOW = 20.0
    const val NOTICE_BEFORE = 90.0
    const val ARRIVE_MOST = 450.0
    const val ARRIVE_LEAST = 200.0
    const val HOP = 800.0

    fun isShort(spanMetres: Double?, wakeMetres: Double): Boolean {
        if (spanMetres == null || !spanMetres.isFinite() || spanMetres < 0) return false
        return spanMetres <= max(if (wakeMetres.isFinite()) max(0.0, wakeMetres) else 0.0, HOP)
    }

    enum class OnFire { RING, QUIET, WAIT }

    fun onFire(legAge: Double, short: Boolean): OnFire = when {
        short -> OnFire.QUIET
        legAge < START_WINDOW -> OnFire.QUIET
        legAge < NO_RING_FOR -> OnFire.WAIT
        else -> OnFire.RING
    }

    fun noticeDue(legAge: Double, told: Boolean, beforeReached: Boolean, secondsLeft: Double?, metres: Double?, startedMetres: Double?): Boolean {
        if (told || legAge < NO_RING_FOR) return false
        if (beforeReached) return true
        if (secondsLeft != null && secondsLeft.isFinite()) return secondsLeft <= NOTICE_BEFORE
        if (metres != null && startedMetres != null && metres.isFinite() && startedMetres.isFinite() && startedMetres > 0) return metres <= startedMetres / 2
        return false
    }

    fun arriveMetres(startedMetres: Double?): Double =
        if (startedMetres == null || !startedMetres.isFinite() || startedMetres <= 0) ARRIVE_MOST else min(ARRIVE_MOST, max(ARRIVE_LEAST, startedMetres / 2))

    fun mayArrive(legAge: Double, metres: Double, startedMetres: Double?): Boolean = legAge >= NO_RING_FOR && metres <= arriveMetres(startedMetres)

    fun words(stop: String): Pair<String, String> {
        val name = stop.trim().ifEmpty { "Your stop" }
        return "Get off at the next stop" to "$name is next. A short ride: this is your reminder, no alarm."
    }
}

/** (A9, iOS 0.42.3 `RideGuards.plannedNextAmong`) the next leg's planned vehicle among those on your road. */
object NextLegGuard {
    fun plannedNextAmong(onRoad: List<String>, plannedNext: String?): String? =
        plannedNext?.takeIf { it.isNotEmpty() && it in onRoad }
}
