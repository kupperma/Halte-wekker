package nl.haltewekker.match

import kotlinx.serialization.Serializable
import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.live.GPSFix
import nl.haltewekker.logs.FieldFormat
import java.time.Instant
import java.time.ZoneId
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

// (A7) iOS 0.38 `PickRules.swift` (with 0.39.1's changes): the moment you left the stop, your usual line, the bus
// stopping pattern and asking sooner. Plain values only, tested with the iOS vectors (`PickRulesTest`).

/** You stood at a stop, then went: where, how long you stood, and the moment you left (your last fix still standing). */
data class Departure(val t: Double, val p: GeoPoint, val stood: Double)

/** What one vehicle's own GPS or live times say about the moment you left. */
data class DepartClue(
    val id: String,
    var offBy: Double? = null,
    var elsewhere: Boolean = false,
    var byGPS: Boolean = false,
    var atStop: Boolean = false,
)

object DepartMatch {
    const val STAND_FOR = 15.0
    const val STAND_DRIFT = 25.0
    const val MOVE_AWAY = 60.0
    const val MOVE_SPEED = 4.0
    const val MAX_ACCURACY = 60.0
    const val FRESH = 4 * 60.0
    const val WINDOW = 60.0
    const val NOT_THEN = 90.0
    const val NOT_THEN_LIVE = 180.0
    const val CLEARER = 45.0
    const val STOP_NEAR = 80.0
    const val GPS_NEAR = 80.0
    const val GPS_AWAY = 300.0
    const val GPS_AROUND = 30.0
    const val STILL_THERE = 60.0
    const val BONUS = 30.0
    const val LOOKS = 2

    fun moment(fixes: List<Fix>): Departure? {
        val f = fixes.filter { it.accuracy.isFinite() && it.accuracy >= 0 && it.accuracy <= MAX_ACCURACY && it.p.lat.isFinite() && it.p.lon.isFinite() }
            .sortedBy { it.t }
        if (f.size < 3) return null
        val newest = f.last()
        var found: Departure? = null
        var i = 0
        while (i < f.size - 1) {
            val lim = max(STAND_DRIFT, 1.5 * f[i].accuracy)
            var j = i
            while (j + 1 < f.size && Geo.metres(f[j + 1].p, f[i].p) <= lim) j++
            val stood = f[j].t - f[i].t
            if (j > i && j < f.size - 1 && stood >= STAND_FOR) { found = Departure(f[j].t, f[i].p, stood); i = j + 1 } else i++
        }
        val d = found ?: return null
        if (Geo.metres(newest.p, d.p) < max(MOVE_AWAY, 2 * newest.accuracy)) return null
        return if (moving(f)) d else null
    }

    private fun moving(f: List<Fix>): Boolean {
        val last = f.lastOrNull() ?: return false
        if (last.speed.isFinite() && last.speed >= 0) return last.speed >= MOVE_SPEED
        if (f.size < 2) return false
        val prev = f[f.size - 2]
        val dt = last.t - prev.t
        if (!(dt > 0)) return false
        return Geo.metres(prev.p, last.p) / dt >= MOVE_SPEED
    }

    fun usable(d: Departure?, now: Double): Departure? {
        d ?: return null
        val age = now - d.t
        return if (age >= -5 && age <= FRESH) d else null
    }

    fun clue(v: VehicleTrack, d: Departure): DepartClue {
        val c = DepartClue(v.tripId)
        val g = v.gps
        if (g != null) {
            val fixes: List<GPSFix> = listOf(g.fix) + listOfNotNull(g.previous)
            for ((k, x) in fixes.withIndex()) {
                val dt = x.at - d.t
                val m = Geo.metres(x.point, d.p)
                if (!dt.isFinite() || !m.isFinite()) continue
                if (m <= GPS_NEAR) {
                    if (dt > STILL_THERE) {
                        if (k == 0) { c.elsewhere = true; c.byGPS = true; c.offBy = null; c.atStop = false; return c }
                        continue
                    }
                    if (dt >= -(d.stood + WINDOW)) c.atStop = true
                    if (dt >= -WINDOW) {
                        val off = abs(dt)
                        c.offBy = min(c.offBy ?: off, off); c.byGPS = true
                    }
                } else if (m >= GPS_AWAY && abs(dt) <= GPS_AROUND) {
                    c.elsewhere = true; c.byGPS = true; c.offBy = null; c.atStop = false
                    return c
                }
            }
            if (c.offBy != null) return c
        }
        if (!v.realTime) return c
        val offs = v.pieces.filter { p -> p.path.firstOrNull()?.let { Geo.metres(it, d.p) <= STOP_NEAR } ?: false }
            .map { abs(it.departure - d.t) }.filter { it.isFinite() }
        offs.minOrNull()?.let { c.offBy = it }
        return c
    }

    fun leftThen(c: DepartClue): Boolean {
        if (c.elsewhere) return false
        val o = c.offBy ?: return false
        return o <= WINDOW
    }

    fun notThen(c: DepartClue, than: Double): Boolean {
        if (c.elsewhere) return true
        val o = c.offBy ?: return false
        if (!c.byGPS) return o >= NOT_THEN_LIVE
        return o >= NOT_THEN || o >= than + CLEARER
    }

    fun severalAtStop(clues: List<DepartClue>, ids: List<String>): Boolean {
        val set = ids.toSet()
        return clues.count { it.id in set && it.atStop && !it.elsewhere } >= 2
    }

    fun pick(clues: List<DepartClue>, ids: List<String>): String? {
        val byId = LinkedHashMap<String, DepartClue>()
        for (c in clues) if (c.id !in byId) byId[c.id] = c
        if (severalAtStop(clues, ids)) return null
        val near = ids.mapNotNull { byId[it] }.filter(::leftThen)
        if (near.size != 1 || ids.size <= 1) return null
        val one = near[0]
        val o = one.offBy ?: return null
        val clear = ids.filter { it != one.id }.all { id -> byId[id]?.let { notThen(it, o) } ?: false }
        return if (clear) one.id else null
    }

    fun bonuses(clues: List<DepartClue>, ids: List<String>): Map<String, Double> {
        val set = ids.toSet()
        if (severalAtStop(clues, ids)) return emptyMap()
        val near = clues.filter { it.id in set && leftThen(it) }
        if (near.size != 1) return emptyMap()
        return mapOf(near[0].id to -BONUS)
    }

    fun logLine(d: Departure, clues: List<DepartClue>, lines: Map<String, String>, zone: ZoneId): String {
        val z = Instant.ofEpochMilli((d.t * 1000).toLong()).atZone(zone)
        val at = "%02d:%02d:%02d".format(z.hour, z.minute, z.second)
        val parts = clues.map { x ->
            val how = if (x.byGPS) "gps" else "live"
            val label = FieldFormat.label(x.id, lines)
            if (x.elsewhere) return@map "$label not then (gps elsewhere)"
            val o = x.offBy ?: return@map "$label no word"
            val s = Math.round(o).toInt()
            val word = if (o <= WINDOW) "left then" else if (x.byGPS || o >= NOT_THEN_LIVE) "not then" else "not sure"
            "$label $word ($how $s s)"
        }
        val ids = clues.map { it.id }
        val both = if (severalAtStop(clues, ids)) " · ${clues.count { it.atStop && !it.elsewhere }} at the stop: says nothing" else ""
        return "depart · stood ${Math.round(d.stood)} s, left $at" + (if (parts.isEmpty()) "" else " · " + parts.joinToString(" · ")) + both
    }
}

/** One ride on a line, as learned (`HabitBook.lines`). */
@Serializable
data class LineRide(val line: String, val train: Boolean, val minute: Int, val weekend: Boolean, val weight: Int)

object UsualLine {
    const val SLOT = 20
    const val NEEDED = 3
    const val SHARE = 0.7
    const val KEEP = 150
    const val ENTER_GAP = 15.0
    const val EXIT_GAP = 40.0
    const val BONUS = 20.0
    const val CONFIRMED = 1
    const val SAID = 2
    const val NOT_THIS = -1

    fun minute(t: Double, zone: ZoneId): Int {
        val z = Instant.ofEpochMilli((t * 1000).toLong()).atZone(zone)
        return z.hour * 60 + z.minute
    }

    fun learnsFound(line: String, train: Boolean, plannedLine: String?, plannedTrain: Boolean?): Boolean {
        val p = plannedLine?.trim()
        if (p.isNullOrEmpty()) return true
        if (plannedTrain != null && plannedTrain != train) return false
        return p.lowercase() == line.trim().lowercase()
    }

    fun weekend(t: Double, zone: ZoneId): Boolean {
        val w = Instant.ofEpochMilli((t * 1000).toLong()).atZone(zone).dayOfWeek.value
        return w == 6 || w == 7
    }

    fun add(r: LineRide, rides: List<LineRide>): List<LineRide> {
        if (r.line.trim().isEmpty() || r.minute < 0 || r.minute >= 1440) return rides
        return (rides + r).takeLast(KEEP)
    }

    fun score(line: String, train: Boolean, minute: Int, weekend: Boolean, rides: List<LineRide>): Int {
        val k = line.lowercase()
        return rides.sumOf { r -> if (r.train == train && r.weekend == weekend && r.line.lowercase() == k && abs(r.minute - minute) <= SLOT) r.weight else 0 }
    }

    data class Option(val id: String, val line: String, val train: Boolean)

    fun usual(cands: List<Option>, minute: Int, weekend: Boolean, rides: List<LineRide>): String? {
        val scores = LinkedHashMap<String, Int>()
        fun key(c: Option) = "${if (c.train) "t" else "b"}:${c.line.lowercase()}"
        for (c in cands) if (key(c) !in scores) scores[key(c)] = score(c.line, c.train, minute, weekend, rides)
        val total = scores.values.filter { it > 0 }.sum()
        val best = scores.entries.maxWithOrNull(Comparator { a, b -> if (a.value != b.value) a.value.compareTo(b.value) else b.key.compareTo(a.key) }) ?: return null
        if (best.value < NEEDED || best.value.toDouble() < SHARE * total) return null
        val of = cands.filter { key(it) == best.key }.map { it.id }
        return if (of.size == 1) of[0] else null
    }

    data class Cand(val id: String, val cost: Double, val byGPS: Boolean)

    fun tieBreak(cands: List<Cand>, usual: String?, held: String?): String? {
        val u = usual ?: return null
        val mine = cands.firstOrNull { it.id == u } ?: return null
        val best = cands.minOfOrNull { it.cost } ?: return null
        if (!mine.byGPS && cands.any { it.id != u && it.byGPS }) return null
        val room = if (held == u) EXIT_GAP else ENTER_GAP
        return if (mine.cost - best <= room) u else null
    }

    fun words(rides: List<LineRide>, limit: Int = 2): List<String> {
        data class Key(val line: String, val train: Boolean, val hour: Int, val weekend: Boolean)
        val n = HashMap<Key, Int>()
        val minutes = HashMap<Key, MutableList<Int>>()
        for (r in rides) {
            val k = Key(r.line, r.train, r.minute / 60, r.weekend)
            n[k] = (n[k] ?: 0) + r.weight
            if (r.weight > 0) minutes.getOrPut(k) { ArrayList() }.add(r.minute)
        }
        val good = n.keys.filter { (n[it] ?: 0) >= NEEDED && !minutes[it].isNullOrEmpty() }
        val sorted = good.sortedWith(Comparator { a, b ->
            val na = n[a] ?: 0; val nb = n[b] ?: 0
            when {
                na != nb -> nb.compareTo(na)
                a.hour != b.hour -> a.hour.compareTo(b.hour)
                else -> a.line.compareTo(b.line)
            }
        })
        return sorted.take(limit).map { k ->
            val ms = (minutes[k] ?: mutableListOf(0)).sorted()
            val m = ms[ms.size / 2]
            val what = if (k.train) (if (k.line == "IC") "Intercity" else if (k.line == "SPR") "Sprinter" else k.line) else k.line
            "$what at ${"%02d:%02d".format(m / 60, m % 60)} ${if (k.weekend) "at weekends" else "on weekdays"}"
        }
    }
}

object BusStops {
    enum class Seen { STOOD, THROUGH }

    const val STAND_FOR = 15.0
    const val STAND_NEAR = 40.0
    const val STAND_DRIFT = 25.0
    const val THROUGH_FROM = 120.0
    const val THROUGH_NEAR = 40.0
    const val THROUGH_SPEED = 4.0
    const val THROUGH_GAP = 15.0
    const val MAX_ACCURACY = 50.0
    const val SERVES = 60.0
    const val PASSES = 40.0
    const val DWELL = 45.0
    const val NEEDED = 2
    const val PENALTY = 20.0
    const val MAX_PENALTY = 60.0

    fun seen(fixes: List<Fix>, s: GeoPoint): Seen? {
        val f = fixes.filter { it.accuracy.isFinite() && it.accuracy >= 0 && it.accuracy <= MAX_ACCURACY }.sortedBy { it.t }
        if (f.size < 3) return null
        val d = f.map { Geo.metres(it.p, s) }
        for (i in f.indices) {
            if (d[i] > max(STAND_NEAR, min(60.0, f[i].accuracy))) continue
            val lim = max(STAND_DRIFT, 1.5 * f[i].accuracy)
            var j = i
            while (j + 1 < f.size && Geo.metres(f[j + 1].p, f[i].p) <= lim) j++
            if (j > i && f[j].t - f[i].t >= STAND_FOR) return Seen.STOOD
        }
        val k = d.indices.minByOrNull { d[it] } ?: return null
        if (d[k] > THROUGH_NEAR) return null
        val a = (0 until k).lastOrNull { d[it] >= THROUGH_FROM } ?: return null
        val b = ((k + 1) until f.size).firstOrNull { d[it] >= THROUGH_FROM } ?: return null
        for (i in a until b) {
            val dt = f[i + 1].t - f[i].t
            if (!(dt > 0) || dt > THROUGH_GAP) return null
            if (Geo.metres(f[i].p, f[i + 1].p) / dt < THROUGH_SPEED) return null
        }
        for (i in a..b) if (f[i].speed.isFinite() && f[i].speed >= 0 && f[i].speed < THROUGH_SPEED) return null
        return Seen.THROUGH
    }

    data class Stop(
        val key: String,
        val point: GeoPoint,
        val served: MutableSet<String> = HashSet(),
        val waits: MutableSet<String> = HashSet(),
        val passing: MutableSet<String> = HashSet(),
    )

    fun against(stops: List<Stop>, seen: Map<String, Seen>, ids: List<String>): Map<String, Int> {
        val n = HashMap<String, Int>()
        for (s in stops) {
            val what = seen[s.key] ?: continue
            for (id in ids) when (what) {
                Seen.STOOD -> if (id in s.passing && id !in s.served) n[id] = (n[id] ?: 0) + 1
                Seen.THROUGH -> if (id in s.waits) n[id] = (n[id] ?: 0) + 1
            }
        }
        return n
    }

    fun penalties(against: Map<String, Int>, ids: List<String>): Map<String, Double> {
        if (ids.size <= 1) return emptyMap()
        val least = ids.minOfOrNull { against[it] ?: 0 } ?: 0
        val out = HashMap<String, Double>()
        for (id in ids) {
            val extra = (against[id] ?: 0) - least
            if (extra >= NEEDED) out[id] = min(MAX_PENALTY, PENALTY * extra)
        }
        return out
    }
}

object AskSooner {
    const val AFTER = 60.0
    const val AFTER_HABIT = 180.0

    fun due(alive: List<String>, movingFor: Double, asked: Boolean, tieBroken: Boolean): Boolean {
        if (asked || alive.size != 2 || !movingFor.isFinite()) return false
        return movingFor >= (if (tieBroken) AFTER_HABIT else AFTER)
    }

    fun worthAsking(lines: Pair<String, String>, destinations: Pair<String, String>): Boolean {
        val l0 = lines.first.trim().lowercase(); val l1 = lines.second.trim().lowercase()
        if (l0.isNotEmpty() && l1.isNotEmpty() && l0 != l1) return true
        val d0 = destinations.first.trim().lowercase(); val d1 = destinations.second.trim().lowercase()
        return d0.isNotEmpty() && d1.isNotEmpty() && d0 != d1
    }

    fun answer(line: String, to: String, train: Boolean, sameLine: Boolean): String {
        if (train) return TrainRules.answer(line, to)
        val bus = "Bus ${line.ifEmpty { "?" }}"
        return if (sameLine && to.isNotEmpty()) "$bus to $to" else bus
    }

    fun title(a: Pair<String, String>, b: Pair<String, String>, train: Boolean): String {
        if (train) return TrainRules.askTitle(a, b)
        val same = a.first.lowercase() == b.first.lowercase()
        fun one(x: Pair<String, String>) = if (same && x.second.isNotEmpty()) "${x.first} to ${x.second}" else x.first
        return "${one(a)} or ${one(b)}?"
    }

    fun body(train: Boolean) = if (train) "Two trains run on the same track here. Which one are you on? Then it wakes you at the right stop."
    else "Two buses drive the same road here. Which one are you on? Then it wakes you at the right stop."
}
