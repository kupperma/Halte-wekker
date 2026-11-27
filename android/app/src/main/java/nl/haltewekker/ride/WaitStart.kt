package nl.haltewekker.ride

import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.match.Fix
import nl.haltewekker.motion.MotionNow
import nl.haltewekker.motion.MotionRules
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * (0.10.3, iOS 0.42.4 `WaitStart.swift`) Starting the trip while Fastest trip watches. From the field report of 27
 * November: on at Veghel bus station, a stop before the planned one (Biezendijk) and an earlier 305 than the planned
 * 09:52, the ride never started. One look decides it now, whatever is on screen:
 * - you move like a bus or train: at `VEHICLE_SPEED` for `MOVING_FOR` of the last `WINDOW` (a stop on the way still
 *   counts), or for `MOTION_FOR` while motion says automotive (never on Android: no Play Services, so by speed only);
 *   never while it says you walk or cycle (below `MotionRules.AFOOT_TOP`), never standing at the stop while a bus goes by;
 * - the matcher's candidates that fit about as well as the best (`Rules.close`) are counted look by look; among them
 *   the one that takes you on (to the planned ride's stop, a later ride's, or the destination) is the pick: the planned
 *   ride first, then any ride of its line, then the best fit;
 * - by its own GPS one look is enough for the planned ride or its line (this close: `Rules.oneLook`), else two; by its
 *   times alone one for the planned ride (that close), two for its line, three for another line;
 * - none of them takes you on, and the best has had its own GPS with you for `WrongBus.GPS_FOR`: the wrong-bus alert,
 *   once for that one.
 * Where you got on is the stop of its trip nearest to where you started moving (`boardedAt`). Plain values, tested
 * with every iOS vector (`WaitStartTest`).
 */
object WaitStart {
    /** m/s: bus or train speed. */
    const val VEHICLE_SPEED = 6.0
    /** s at that speed in the last `WINDOW` before it's a ride. */
    const val MOVING_FOR = 30.0
    /** …or this long while motion says automotive. */
    const val MOTION_FOR = 10.0
    /** s of fixes looked at. */
    const val WINDOW = 120.0
    /** s: a longer gap between two fixes says nothing about the speed in between. */
    const val MAX_STEP = 30.0
    /** s: its own GPS fix at most this old makes it "by its GPS". */
    const val GPS_FRESH = 90.0
    /** s: below speed for longer than this, the moving starts again (where you got on). */
    const val RUN_BREAK = 90.0
    /** m: the stop you got on at is at most this far from where you started moving. */
    const val BOARDED_WITHIN = 400.0
    /** m: a stop that close to the planned one is the planned one. */
    const val SAME_PLACE = 150.0
    /** m: a trip "takes you on" when one of its stops ahead is this close to a stop of your trip or the destination. */
    const val REACH_WITHIN = 600.0
    /** s: a trip's "takes you on" is kept this long. */
    const val REACH_KEPT = 120.0

    // MARK: moving like a bus or train

    data class Moving(val seconds: Double, val speed: Double)

    /** What motion says, as far as this goes. */
    enum class Hint { NONE, VEHICLE, AFOOT, STILL }

    fun hint(m: MotionNow?): Hint = when {
        MotionRules.inVehicle(m) -> Hint.VEHICLE
        MotionRules.afoot(m) -> Hint.AFOOT
        MotionRules.still(m) -> Hint.STILL
        else -> Hint.NONE
    }

    /** The speed between two fixes: the GPS's own when it has one, else the distance over the time when that's more than their accuracy. */
    fun stepSpeed(a: Fix, b: Fix): Double {
        val dt = b.t - a.t
        if (dt <= 0) return 0.0
        if (b.speed.isFinite() && b.speed >= 0) return b.speed
        val d = Geo.metres(a.p, b.p)
        val acc = max(a.accuracy, b.accuracy)
        return if (d > acc) d / dt else 0.0
    }

    private fun usable(fixes: List<Fix>, now: Double): List<Fix> =
        fixes.filter { f -> f.accuracy >= 0 && f.accuracy < 150 && now - f.t <= WINDOW && f.t <= now + 5 }.sortedBy { it.t }

    /** How long you've moved at bus or train speed in the last `WINDOW`, and how fast now. */
    fun moving(fixes: List<Fix>, now: Double): Moving {
        val list = usable(fixes, now)
        var seconds = 0.0
        var last = 0.0
        if (list.size >= 2) {
            for (i in 1 until list.size) {
                val a = list[i - 1]; val b = list[i]
                val dt = b.t - a.t
                if (dt <= 0 || dt > MAX_STEP) continue
                val v = stepSpeed(a, b)
                if (v >= VEHICLE_SPEED) seconds += dt
                last = v
            }
        } else list.lastOrNull()?.let { if (it.speed.isFinite() && it.speed >= 0) last = it.speed }
        return Moving(seconds, last)
    }

    /** Null: you move like a bus or train. Else the rule that holds. */
    fun movingRule(m: Moving, motion: Hint): String? {
        if (motion == Hint.AFOOT && m.speed < MotionRules.AFOOT_TOP) return "walking or cycling (motion)"
        if (m.seconds >= MOVING_FOR) return null
        if (motion == Hint.VEHICLE && m.seconds >= MOTION_FOR) return null
        if (m.seconds <= 0 && m.speed < 2) return "standing"
        return "not at bus speed for ${MOVING_FOR.toInt()} s yet"
    }

    /**
     * Where the moving at bus speed began (the first fix of the run that goes on until now): where you got on. Only a
     * run with a slower fix before it in the window; one that began before the window isn't a boarding it saw.
     */
    fun startedMoving(fixes: List<Fix>, now: Double): GeoPoint? {
        val list = usable(fixes, now)
        if (list.size < 2) return null
        var start: Int? = null
        var lastFast: Double? = null
        for (i in 1 until list.size) {
            val a = list[i - 1]; val b = list[i]
            val dt = b.t - a.t
            if (dt <= 0 || dt > MAX_STEP || stepSpeed(a, b) < VEHICLE_SPEED) continue
            val broken = lastFast?.let { a.t - it > RUN_BREAK } ?: true
            if (start == null || broken) start = i - 1
            lastFast = b.t
        }
        val k = start ?: return null
        if (k <= 0) return null
        return list[k].p
    }

    // MARK: the one you're on

    /** One the matcher found moving with you. `cost`: s off its times; `gpsAge`: by its own GPS fix this old (null: by its times). */
    data class Candidate(
        val id: String,
        val label: String,
        val line: String,
        val cost: Double,
        val gpsAge: Double? = null,
        val gpsFor: Double? = null,
        val reaches: Boolean? = null,
        val planned: Boolean = false,
        val plannedLine: Boolean = false,
    ) {
        val byGPS: Boolean get() = gpsAge?.let { it <= GPS_FRESH } ?: false
    }

    data class Rules(val oneLook: Double, val close: Double)

    /** The Android matcher's (seconds off its times): iOS `MatchRules.seconds`'s `oneLookWatched` and `close`. */
    val RULES = Rules(oneLook = 20.0, close = 60.0)

    data class State(val looks: Map<String, Int> = emptyMap(), val told: Set<String> = emptySet())

    sealed class Call {
        data class Start(val id: String) : Call()
        data class Hold(val why: String) : Call()
        data class WrongBus(val id: String) : Call()
    }

    data class Outcome(val state: State, val call: Call, val line: String, val progress: Int)

    /** Looks needed before it starts on `c`. */
    fun needed(c: Candidate, rules: Rules): Int {
        val ours = c.planned || c.plannedLine
        if (c.byGPS) return if (ours && c.cost < rules.oneLook) 1 else 2
        if (c.planned && c.cost < rules.oneLook) return 1
        return if (c.plannedLine) 2 else 3
    }

    /** One look while it waits for you to get on. */
    fun step(s: State, moving: Moving, motion: Hint, candidates: List<Candidate>, rules: Rules): Outcome {
        var st = s
        fun done(call: Call, progress: Int = 0) = Outcome(st, call, logLine(moving, candidates, call), progress)
        movingRule(moving, motion)?.let { why ->
            st = st.copy(looks = emptyMap())
            return done(Call.Hold(why))
        }
        val top = candidates.firstOrNull() ?: run {
            st = st.copy(looks = emptyMap())
            return done(Call.Hold("no bus or train fits your gps"))
        }
        val near = candidates.filter { it.cost <= top.cost + rules.close }
        val looks = HashMap<String, Int>()
        for (c in near) looks[c.id] = (st.looks[c.id] ?: 0) + 1
        st = st.copy(looks = looks)
        val going = near.filter { it.reaches == true }
        val pick = going.firstOrNull { it.planned } ?: going.firstOrNull { it.plannedLine } ?: going.firstOrNull()
        if (pick != null) {
            val n = looks[pick.id] ?: 0
            val need = needed(pick, rules)
            if (n >= need) return done(Call.Start(pick.id), n)
            return done(Call.Hold("seen $n of $need looks"), n)
        }
        if (near.any { it.reaches == null }) return done(Call.Hold("its stops not known yet"))
        // none of them takes you on: sure of the best by its own GPS, the wrong-bus alert (once for it)
        val sure = top.byGPS && (top.gpsFor ?: 0.0) >= WrongBus.GPS_FOR
        if (sure && top.id !in st.told) {
            st = st.copy(told = st.told + top.id)
            return done(Call.WrongBus(top.id))
        }
        return done(Call.Hold(if (top.id in st.told) "not your way (told)" else "not your way"))
    }

    /** "wait · moving 9 m/s 40 s · candidates 305·2718 gps 12 s fits, 306·1234 times elsewhere · start 305·2718" */
    fun logLine(m: Moving, c: List<Candidate>, call: Call): String {
        val parts = mutableListOf("wait · moving ${round(m.speed)} m/s ${round(m.seconds)} s")
        parts.add(if (c.isEmpty()) "no candidates" else "candidates " + c.take(3).joinToString(", ") { describe(it) })
        parts.add(when (call) {
            is Call.Start -> "start " + (c.firstOrNull { it.id == call.id }?.label ?: call.id)
            is Call.Hold -> "held by " + call.why
            is Call.WrongBus -> "wrong bus " + (c.firstOrNull { it.id == call.id }?.label ?: call.id)
        })
        return parts.joinToString(" · ")
    }

    /** Swift's `Int(x.rounded())`: half away from zero. */
    private fun round(x: Double): Int = if (x >= 0) Math.floor(x + 0.5).toInt() else -Math.floor(-x + 0.5).toInt()

    private fun describe(c: Candidate): String {
        val how = c.gpsAge?.takeIf { c.byGPS }?.let { "gps ${round(max(0.0, it))} s" } ?: "times"
        val goes = when (c.reaches) { true -> "fits"; false -> "elsewhere"; null -> "stops ?" }
        return "${c.label} $how $goes"
    }

    /** "wait · watching on · its look at what you get on runs (in front)": Fastest trip began watching. */
    fun onLine(again: Boolean, inFront: Boolean) =
        "wait · watching ${if (again) "again" else "on"} · its look at what you get on runs (${if (inFront) "in front" else "behind the screen"})"

    /** "wait · watching off · you're there": it stopped watching, and why. */
    fun offLine(why: String) = "wait · watching off · $why"

    /** The look at what you got on runs now (null), or why not. Nothing about the screen. */
    fun lookRuns(watching: Boolean, tripIdle: Boolean, demo: Boolean): String? = when {
        !watching -> "not watching"
        !tripIdle -> "a trip runs"
        demo -> "the demo"
        else -> null
    }

    /** A look's line goes to the field log: each one while you move or something moves with you, else once a minute while its call stays the same. */
    fun logDue(key: String, last: Pair<String, Double>?, busy: Boolean, now: Double): Boolean {
        if (busy) return true
        val l = last ?: return true
        return l.first != key || now - l.second >= 60
    }

    /** The same line (a departure of the planned one's line, earlier or later). */
    fun sameLine(a: String, b: String): Boolean {
        val x = WrongBus.norm(a); val y = WrongBus.norm(b)
        return x.isNotEmpty() && x == y
    }

    // MARK: where it goes, where you got on

    /** A stop of the vehicle's trip, with when it's there (null: not known). */
    data class Stop(val name: String, val point: GeoPoint, val time: Double?)

    private fun nearest(stops: List<Stop>, p: GeoPoint): Int? = stops.indices.minByOrNull { Geo.metres(stops[it].point, p) }

    /** It takes you on: a stop of its trip from the one nearest to you on (not one it passed more than 2 minutes ago) within `REACH_WITHIN` of one of `targets`. */
    fun reaches(stops: List<Stop>, here: GeoPoint?, targets: List<GeoPoint>, now: Double): Boolean {
        if (stops.isEmpty() || targets.isEmpty()) return false
        val from = here?.let { nearest(stops, it) } ?: 0
        for (i in from until stops.size) {
            val t = stops[i].time
            if (t != null && t < now - 120) continue
            val p = stops[i].point
            if (targets.any { Geo.metres(it, p) <= REACH_WITHIN }) return true
        }
        return false
    }

    /** Where you got on: of its stops up to the one nearest to you now, the one nearest to where you started moving, within `BOARDED_WITHIN`. */
    fun boardedAt(stops: List<Stop>, startedAt: GeoPoint, here: GeoPoint): Int? {
        if (stops.isEmpty()) return null
        val hi = nearest(stops, here) ?: (stops.size - 1)
        return (0..hi).filter { Geo.metres(stops[it].point, startedAt) <= BOARDED_WITHIN }
            .minByOrNull { Geo.metres(stops[it].point, startedAt) }
    }

    /** The stop the leg should start at instead of `planned` (null: on board, none): where you got on, when that's another stop. Null: keep it. */
    fun repoint(stops: List<Stop>, startedAt: GeoPoint?, here: GeoPoint, planned: GeoPoint?): Int? {
        val s = startedAt ?: return null
        val i = boardedAt(stops, s, here) ?: return null
        if (planned != null && Geo.metres(planned, stops[i].point) <= SAME_PLACE) return null
        return i
    }

    /** "1040 m": rounded to 10 m, as the log says it. */
    fun offMetres(a: GeoPoint?, b: GeoPoint): Int = a?.let { (Geo.metres(it, b) / 10).roundToInt() * 10 } ?: 0
}
