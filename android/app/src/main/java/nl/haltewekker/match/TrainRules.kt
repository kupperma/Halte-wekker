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
    const val STAY_ROOM = 120.0

    data class Call(val p: GeoPoint, val arrival: Double?)

    /** The furthest later leg `k` whose end the train you're on calls at (in time for the ride after it), and the call. */
    fun stayOn(index: Int, ends: List<GeoPoint>, departures: List<Double?>, calls: List<Call>, now: Double): Pair<Int, Int>? {
        if (index + 1 >= ends.size) return null
        for (k in ends.size - 1 downTo index + 1) {
            val c = calls.indices.firstOrNull { i ->
                val a = calls[i].arrival
                a != null && a > now && Geo.metres(calls[i].p, ends[k]) <= STAY_NEAR
            } ?: continue
            val arr = calls[c].arrival ?: continue
            if (k + 1 < ends.size) {
                val next = departures.getOrNull(k + 1) ?: continue
                if (arr > next - STAY_ROOM) continue
            }
            return k to c
        }
        return null
    }
}
