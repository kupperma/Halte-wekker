package nl.haltewekker.travel

import kotlinx.serialization.Serializable
import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.match.Fix
import java.time.DayOfWeek
import java.time.Instant
import java.time.ZoneId
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/** Swift's `rounded()` (half away from zero) to `k` (10 = one decimal). */
internal fun roundTo(x: Double, k: Double): Double { val r = floor(abs(x) * k + 0.5) / k; return if (x < 0) -r else r }

/**
 * (A6, iOS 0.34 `Habits.swift`) what the app learns from your own rides and walks, on the phone only: how fast you walk,
 * how much time you need to change, and stops you get on at more often than the planner has you.
 */
@Serializable
data class HabitBook(
    val walks: List<Double> = emptyList(),
    val changes: List<Double> = emptyList(),
    val boardedAt: Map<String, Int> = emptyMap(),
    val plannedAt: Map<String, Int> = emptyMap(),
    val names: Map<String, String> = emptyMap(),
) {
    val isEmpty: Boolean get() = walks.isEmpty() && changes.isEmpty() && boardedAt.isEmpty() && plannedAt.isEmpty()

    fun addWalk(speed: Double): HabitBook {
        if (!speed.isFinite() || speed < Habits.WALK_MIN || speed > Habits.WALK_MAX) return this
        return copy(walks = (walks + roundTo(speed, 100.0)).takeLast(Habits.KEEP))
    }

    fun addChange(minutes: Double): HabitBook {
        if (!minutes.isFinite() || minutes < 0 || minutes > Habits.CHANGE_MAX) return this
        return copy(changes = (changes + roundTo(minutes, 10.0)).takeLast(Habits.KEEP))
    }

    fun boarded(stop: String): HabitBook {
        val k = Habits.key(stop)
        if (k.isEmpty()) return this
        return copy(boardedAt = boardedAt + (k to (boardedAt[k] ?: 0) + 1), names = names + (k to stop.trim())).trim()
    }

    fun plannedFrom(stop: String): HabitBook {
        val k = Habits.key(stop)
        if (k.isEmpty()) return this
        return copy(plannedAt = plannedAt + (k to (plannedAt[k] ?: 0) + 1), names = if (names[k] == null) names + (k to stop.trim()) else names).trim()
    }

    private fun trim(): HabitBook {
        fun keep(m: Map<String, Int>) = if (m.size <= Habits.STOPS) m else m.entries.sortedByDescending { it.value }.take(Habits.STOPS).associate { it.key to it.value }
        val b = keep(boardedAt); val p = keep(plannedAt)
        val used = b.keys + p.keys
        return copy(boardedAt = b, plannedAt = p, names = names.filterKeys { it in used })
    }
}

object Habits {
    const val PLANNER_WALK = 1.2
    const val WALK_MIN = 0.6
    const val WALK_MAX = 2.6
    const val WALK_FOR = 60.0
    const val WALK_ACCURACY = 25.0
    const val WALKS_NEEDED = 5
    const val CHANGES_NEEDED = 3
    const val CHANGE_MAX = 20.0
    const val CHANGE_NEAR = 50.0
    const val PREFERRED_NEEDED = 3
    const val PREFERRED_BONUS = 2.0
    const val KEEP = 40
    const val STOPS = 60

    fun key(stop: String) = stop.trim().lowercase()

    fun walkSpeed(fixes: List<Fix>): Double? {
        val f = fixes.filter { it.accuracy.isFinite() && it.accuracy >= 0 && it.accuracy <= WALK_ACCURACY }.sortedBy { it.t }
        if (f.size < 3) return null
        val speeds = ArrayList<Double>(); var time = 0.0
        for (i in 1 until f.size) {
            val dt = f[i].t - f[i - 1].t
            if (dt <= 0 || dt > 20) continue
            val v = if (f[i].speed.isFinite() && f[i].speed >= 0) f[i].speed else Geo.metres(f[i - 1].p, f[i].p) / dt
            if (v < WALK_MIN || v > WALK_MAX) continue
            speeds.add(v); time += dt
        }
        if (time < WALK_FOR) return null
        return median(speeds)
    }

    fun walkSpeed(b: HabitBook): Double? = if (b.walks.size < WALKS_NEEDED) null else median(b.walks)

    fun walkMinutes(minutes: Int, b: HabitBook): Int {
        val v = walkSpeed(b)
        if (minutes <= 0 || v == null || v <= 0) return minutes
        return ceil(minutes * PLANNER_WALK / v - 1e-9).toInt()
    }

    fun pedestrianSpeed(b: HabitBook): Double? {
        val v = walkSpeed(b) ?: return null
        if (abs(v - PLANNER_WALK) < 0.1 - 1e-9) return null
        return roundTo(min(WALK_MAX, max(WALK_MIN, v)), 10.0)
    }

    fun changeMinutes(arrived: Double, fixes: List<Fix>, stop: GeoPoint): Double? {
        val f = fixes.filter { it.t >= arrived && it.accuracy.isFinite() && it.accuracy >= 0 && it.accuracy <= 50 }.sortedBy { it.t }
        val at = f.firstOrNull { Geo.metres(it.p, stop) <= max(CHANGE_NEAR, it.accuracy) } ?: return null
        val m = (at.t - arrived) / 60
        return if (m <= CHANGE_MAX) m else null
    }

    fun changeMinutes(b: HabitBook): Double? {
        if (b.changes.size < CHANGES_NEEDED) return null
        val s = b.changes.sorted()
        val rank = ceil(0.8 * s.size).toInt()
        return ceil(s[max(0, min(s.size - 1, rank - 1))])
    }

    fun preferred(stop: String, b: HabitBook): Boolean {
        val k = key(stop)
        val n = b.boardedAt[k] ?: 0
        return n >= PREFERRED_NEEDED && n > (b.plannedAt[k] ?: 0)
    }

    fun bonus(firstStop: String, b: HabitBook) = if (preferred(firstStop, b)) PREFERRED_BONUS else 0.0

    fun preferredStops(b: HabitBook): List<String> =
        b.boardedAt.entries.filter { preferred(it.key, b) }.sortedWith(compareBy({ -it.value }, { it.key })).map { b.names[it.key] ?: it.key }

    data class Row(val label: String, val value: String)

    fun rows(b: HabitBook): List<Row> {
        val walk = walkSpeed(b)?.let { String.format(java.util.Locale.ROOT, "%.1f km/h", it * 3.6) } ?: "not yet"
        val change = changeMinutes(b)?.let { "${it.toInt()} min" } ?: "not yet"
        val stops = preferredStops(b)
        return listOf(Row("Walking speed", walk), Row("Time you need to change", change),
            Row("Stops you prefer", if (stops.isEmpty()) "none yet" else stops.take(3).joinToString(", ")))
    }

    internal fun median(xs: List<Double>): Double? {
        val s = xs.sorted()
        if (s.isEmpty()) return null
        return if (s.size % 2 == 1) s[s.size / 2] else (s[s.size / 2 - 1] + s[s.size / 2]) / 2
    }
}

/** (A6, iOS 0.34 `ChangeOdds.swift`) per change and time of week, whether you made it: one outcome per day. */
@Serializable
data class ChangeBook(val days: Map<String, Map<String, Boolean>> = emptyMap()) {
    fun record(key: String, day: String, made: Boolean): ChangeBook {
        if (key.isEmpty() || day.isEmpty()) return this
        var d = (days[key] ?: emptyMap()) + (day to made)
        if (d.size > DAYS_KEPT) d = d.entries.sortedByDescending { it.key }.take(DAYS_KEPT).associate { it.key to it.value }
        var all = days + (key to d)
        if (all.size > KEYS_KEPT) {
            val keep = all.map { it.key to (it.value.keys.maxOrNull() ?: "") }.sortedByDescending { it.second }.take(KEYS_KEPT).map { it.first }.toSet()
            all = all.filterKeys { it in keep }
        }
        return ChangeBook(all)
    }

    fun tally(key: String): Pair<Int, Int> { val d = days[key] ?: emptyMap(); return d.values.count { it } to d.size }

    companion object { const val DAYS_KEPT = 30; const val KEYS_KEPT = 200 }
}

object ChangeOdds {
    const val NEEDED = 3
    const val WEIGHT_DAYS = 5.0
    const val HOPELESS = 0.9

    fun key(from: String, to: String, at: String, time: Double, zone: ZoneId) = "$from>$to@${at.trim().lowercase()}|${bucket(time, zone)}"

    fun bucket(t: Double, zone: ZoneId): String {
        val z = Instant.ofEpochMilli((t * 1000).toLong()).atZone(zone)
        val h = z.hour
        val part = if (h < 7) "early" else if (h < 9) "am" else if (h < 16) "day" else if (h < 19) "pm" else "eve"
        val we = z.dayOfWeek == DayOfWeek.SATURDAY || z.dayOfWeek == DayOfWeek.SUNDAY
        return "${if (we) "we" else "wd"}-$part"
    }

    fun day(t: Double, zone: ZoneId): String {
        val z = Instant.ofEpochMilli((t * 1000).toLong()).atZone(zone)
        return String.format(java.util.Locale.ROOT, "%04d%02d%02d", z.year, z.monthValue, z.dayOfMonth)
    }

    fun words(made: Int, days: Int): String? = if (days < NEEDED || made < 0 || made > days) null else "this change worked on $made of $days days"

    fun missChance(model: Double, made: Int, days: Int): Double {
        if (days < NEEDED || model >= HOPELESS) return model
        val w = days / (days + WEIGHT_DAYS)
        val missed = (days - min(made, days)).toDouble() / days
        return (1 - w) * model + w * missed
    }

    fun made(plannedTrip: String, plannedDeparture: Double, boardedTrip: String, boardedDeparture: Double?): Boolean? {
        if (boardedTrip == plannedTrip) return true
        val d = boardedDeparture ?: return null
        return d - plannedDeparture <= 60
    }
}
