package nl.haltewekker.match

import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import kotlin.math.max

/**
 * (A6, iOS 0.34 `TrainRules.swift`) two trains on the same track: `rivals` (the confirmed train isn't with you by its
 * own NS position, another on your track is: choose), the stopping pattern (`seen`, `outByStops`), `ask` (still tied
 * after 2 minutes with different destinations: ask once) and `stayOn` (the trip follows the train you're on). Pure.
 */
object TrainRules {
    const val RIVAL_EVERY = 120.0
    const val RIVAL_COUNT = 2

    fun rivals(shown: Judgement?, others: List<Judgement>): List<String> {
        if (shown != null && ChooseGPS.passedByGPS(shown)) return emptyList()
        return others.mapNotNull { j ->
            val c = j.cost
            if (!j.isTrain || j.id == shown?.id || !ChooseGPS.passedByGPS(j) || c == null) null else j.id to c
        }.sortedWith(compareBy({ it.second }, { it.first })).take(RIVAL_COUNT).map { it.first }
    }

    enum class Seen { STOPPED, PASSED_THROUGH }

    const val NEAR = 300.0
    const val STOP_NEAR = 250.0
    const val STOP_FOR = 20.0
    const val STOP_DRIFT = 40.0
    const val PASS_SPEED = 8.0
    const val PASS_FROM = 600.0
    const val PASS_GAP = 20.0
    const val MAX_ACCURACY = 100.0

    fun seen(fixes: List<Fix>, s: GeoPoint): Seen? {
        val f = fixes.filter { it.accuracy.isFinite() && it.accuracy >= 0 && it.accuracy <= MAX_ACCURACY }.sortedBy { it.t }
        if (f.size < 3) return null
        val d = f.map { Geo.metres(it.p, s) }
        for (i in f.indices) {
            if (d[i] > STOP_NEAR) continue
            val lim = max(STOP_DRIFT, 1.5 * f[i].accuracy)
            var j = i
            while (j + 1 < f.size && Geo.metres(f[j + 1].p, f[i].p) <= lim) j++
            if (j > i && f[j].t - f[i].t >= STOP_FOR) return Seen.STOPPED
        }
        val k = d.indices.minByOrNull { d[it] } ?: return null
        if (d[k] > NEAR) return null
        val a = (0 until k).lastOrNull { d[it] >= PASS_FROM } ?: return null
        val b = ((k + 1) until f.size).firstOrNull { d[it] >= PASS_FROM } ?: return null
        if (Geo.metres(f[a].p, f[b].p) < 0.8 * (d[a] + d[b])) return null
        for (i in a until b) {
            val dt = f[i + 1].t - f[i].t
            if (dt <= 0 || dt > PASS_GAP) return null
            if (Geo.metres(f[i].p, f[i + 1].p) / dt < PASS_SPEED) return null
        }
        for (i in a..b) if (f[i].speed.isFinite() && f[i].speed >= 0 && f[i].speed < PASS_SPEED) return null
        return Seen.PASSED_THROUGH
    }

    fun outByStops(calls: Map<String, Set<String>>, runsThrough: Map<String, Set<String>>, seen: Map<String, Seen>): Set<String> {
        val out = HashSet<String>()
        for ((id, stations) in calls) for ((s, what) in seen) when (what) {
            Seen.PASSED_THROUGH -> if (s in stations) out.add(id)
            Seen.STOPPED -> if (s !in stations && runsThrough[id]?.contains(s) == true) out.add(id)
        }
        return if (out.size >= calls.size) emptySet() else out
    }

    const val ASK_AFTER = 120.0

    fun ask(alive: List<String>, choosingFor: Double, trains: Boolean, destinations: Map<String, String>, asked: Boolean): Pair<String, String>? {
        if (!trains || asked || alive.size != 2 || choosingFor <= ASK_AFTER) return null
        val a = alive[0]; val b = alive[1]
        val da = destinations[a] ?: return null
        val db = destinations[b] ?: return null
        val na = da.trim().lowercase(); val nb = db.trim().lowercase()
        if (na.isEmpty() || nb.isEmpty() || na == nb) return null
        return a to b
    }

    fun askTitle(a: Pair<String, String>, b: Pair<String, String>) = "${answer(a.first, a.second)} or ${answer(b.first, b.second)}?"

    fun answer(line: String, to: String) = if (to.isEmpty()) line else "$line to $to"

    const val STAY_NEAR = 400.0
    const val STAY_NAME_NEAR = 1500.0
    const val STAY_ROOM = 120.0
    const val STAY_LATE = 120.0
    const val STAY_CATCH = 60.0

    /** One leg as the stay-on rule needs it (iOS 0.42.9 `TrainRules.StayLeg`). Times in seconds since 1970. */
    data class StayLeg(val from: GeoPoint, val to: GeoPoint, val fromName: String = "", val toName: String = "",
                       val departure: Double? = null, val arrival: Double? = null, val tripId: String = "", val num: String = "")

    /** One stop of the vehicle you're on (its own stop list). */
    data class Call(val p: GeoPoint, val arrival: Double?, val name: String = "")

    /** Stay on through leg `leg`, at `call` of the vehicle's stops (null: the plan's own stop, the same train). */
    data class StayHit(val leg: Int, val call: Int?, val sameTrain: Boolean)

    /** "Eindhoven Centraal", "Eindhoven, Station" → "eindhoven". */
    fun stationKey(s: String): String {
        val folded = java.text.Normalizer.normalize(s, java.text.Normalizer.Form.NFD).replace(Regex("\\p{M}+"), "").lowercase()
        val drop = setOf("station", "centraal", "cs", "centraalstation", "busstation", "perron")
        return folded.split(Regex("[^\\p{L}\\p{N}]+")).filter { it.isNotEmpty() && it !in drop }.joinToString("")
    }

    fun digits(s: String): String = s.filter { it.isDigit() }

    fun sameTrain(l: StayLeg, tripId: String, num: String): Boolean {
        if (tripId.isNotEmpty() && l.tripId == tripId) return true
        val a = digits(l.num); val b = digits(num)
        return a.isNotEmpty() && a == b
    }

    fun callAt(p: GeoPoint, name: String, calls: List<Call>, now: Double): Int? {
        val key = stationKey(name)
        return calls.indices.firstOrNull { i ->
            val a = calls[i].arrival
            if (a == null || a <= now) false else {
                val m = Geo.metres(calls[i].p, p)
                m <= STAY_NEAR || (key.isNotEmpty() && m <= STAY_NAME_NEAR && stationKey(calls[i].name) == key)
            }
        }
    }

    /**
     * (iOS 0.42.9 `TrainRules.stayOn`) stay seated instead of changing: the plan's next legs are this very train (the
     * same trip or number): always; or it calls at a later leg's stop (where it gets off, or where the ride after it gets
     * on) no later than the planned ride (+2 min) and a minute before the ride after it. The furthest such leg.
     */
    fun stayOn(index: Int, legs: List<StayLeg>, tripId: String, num: String, calls: List<Call>, now: Double): StayHit? {
        if (index < 0 || index + 1 >= legs.size) return null
        var same = index
        while (same + 1 < legs.size && sameTrain(legs[same + 1], tripId, num)) same++
        for (k in legs.size - 1 downTo index + 1) {
            if (k <= same) break
            throughCall(k, legs, calls, now)?.let { return StayHit(k, it, false) }
        }
        if (same <= index) return null
        val end = legs[same]
        return StayHit(same, callAt(end.to, end.toName, calls, now), true)
    }

    private fun throughCall(k: Int, legs: List<StayLeg>, calls: List<Call>, now: Double): Int? {
        val l = legs[k]
        val after = legs.getOrNull(k + 1)
        val i = callAt(l.to, l.toName, calls, now) ?: after?.let { callAt(it.from, it.fromName, calls, now) } ?: return null
        val arr = calls[i].arrival ?: return null
        val nextDep = after?.departure
        if (l.arrival != null) {
            if (arr > l.arrival + STAY_LATE) return null
            if (nextDep != null && arr > nextDep - STAY_CATCH) return null
            return i
        }
        if (nextDep != null) return if (arr <= nextDep - STAY_ROOM) i else null
        return if (after == null) i else null
    }

    fun stayLog(vehicle: String, reaches: String, at: String, changeAt: String, changeTime: String, next: String, nextTime: String, sameTrain: Boolean): String {
        if (sameTrain) return "stay on · $vehicle is the next leg's train too: on to $reaches (plan split it at $changeAt)"
        val whenText = if (at.isEmpty()) "" else " $at"
        val changed = if (changeTime.isEmpty()) changeAt else "$changeAt $changeTime"
        val then = if (next.isEmpty()) "" else " → $next" + (if (nextTime.isEmpty()) "" else " $nextTime")
        return "stay on · $vehicle also reaches $reaches$whenText (plan changed at $changed$then)"
    }

    /** (iOS 0.42.9) The ride's headline by where the vehicle really goes, and where you get off. */
    fun headline(vehicle: String, headsign: String, legEnd: String, stayOnTo: String?): Pair<String, String?> {
        val sign = headsign.trim()
        val going = if (sign.isEmpty()) vehicle else "$vehicle to $sign"
        if (!stayOnTo.isNullOrEmpty()) return "Stay on to $stayOnTo" to going
        if (sign.isNotEmpty() && stationKey(sign) == stationKey(legEnd)) return going to null
        return going to (if (legEnd.isEmpty()) null else "Get off at $legEnd")
    }

    fun lockHeadline(vehicle: String, headsign: String, legEnd: String, stayOnTo: String?): String {
        val (t, d) = headline(vehicle, headsign, legEnd, stayOnTo)
        if (stayOnTo != null || d == null) return t
        return "$t · ${d.replaceFirstChar { it.lowercase() }}"
    }
}
