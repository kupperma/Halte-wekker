package nl.haltewekker.friends

import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.JsonArray
import nl.haltewekker.core.GeoPoint
import java.time.Instant
import java.time.ZoneId
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.roundToInt

/**
 * (A6, iOS 0.35 `ScoreRules.swift`) the leaderboard's rule: which board a finished trip goes on. Not the demo, started
 * at the trip's first leg; a planned trip that started near Home (where you were if that fix was ≤ 10 min old, else its
 * first stop) and ended near School, or the other way (`DoorScore`), on or off the corridor. Pure.
 */
object ScoreRules {
    const val FRESH_START = 600.0

    data class Finished(
        val demo: Boolean = false,
        val startedAtLeg: Int,
        /** Where it started, best first: where you were when it started (if that fix was fresh), then the first stop. */
        val starts: List<GeoPoint>,
        val end: GeoPoint?,
        val home: GeoPoint,
        val school: GeoPoint,
    )

    fun board(f: Finished): Pair<String, Boolean>? {
        if (f.demo || f.startedAtLeg != 0) return null
        val end = f.end ?: return null
        for (s in f.starts) DoorScore.key(s, end, f.home, f.school)?.let { return it }
        return null
    }

    /** The starts, best first: the fix where it started when it was fresh (≤ 10 min before the start), then the first stop. */
    fun starts(fix: GeoPoint?, fixAt: Double?, startedAt: Double, firstStop: GeoPoint?): List<GeoPoint> =
        listOfNotNull(fix?.takeIf { fixAt != null && startedAt - fixAt <= FRESH_START && fixAt - startedAt <= FRESH_START }, firstStop)

    /** The saved board, entry by entry: one that doesn't read is skipped, not the whole board. */
    fun decode(text: String?): List<ScoreTrip> {
        text ?: return emptyList()
        FriendJson.decode(ListSerializer(ScoreTrip.serializer()), text)?.let { return it }
        val arr = FriendJson.parse(text.toByteArray()) as? JsonArray ?: return emptyList()
        return arr.mapNotNull { FriendJson.decode(ScoreTrip.serializer(), it) }
    }

    /** The worst late ride so far, with one more ride's delay: the later one stays. */
    fun worse(had: Pair<String, Double>?, new: Pair<String, Double>): Pair<String, Double> = if (had == null || new.second > had.second) new else had
}

/** One of today's trips, as the `scores` box carries it (0.35, additive). */
@Serializable
data class DayTrip(
    val home: Boolean,
    val mins: Double,
    val at: Double,
    val plan: Double? = null,
    val line: String? = null,
    val late: Double? = null,
) {
    companion object {
        const val MAX_COUNT = 12
        const val LINE_LENGTH = 20

        fun valid(list: List<DayTrip>?): List<DayTrip>? {
            list ?: return null
            return list.mapNotNull { t ->
                if (t.mins < 5 || t.mins > 600) return@mapNotNull null
                var v = DayTrip(t.home, t.mins, t.at)
                t.plan?.let { if (it >= 5 && it <= 600) v = v.copy(plan = it) }
                val l = clean(t.line ?: "")
                val m = t.late
                if (l.isNotEmpty() && m != null && m >= 1 && m <= 600) v = v.copy(line = l, late = m)
                v
            }.take(MAX_COUNT)
        }

        fun clean(s: String): String {
            val words = s.split(Regex("\\s+")).map { w -> w.filter { !Character.isISOControl(it) } }.filter { it.isNotEmpty() }
            return words.joinToString(" ").take(LINE_LENGTH).trim()
        }
    }
}

/** (A6, iOS 0.35 `DailyRank.swift`) today's best and worst trip, per direction. Today is the phone's own day. */
object DailyRank {
    const val USUAL_DAYS = 28
    const val USUAL_FROM = 3
    const val LATE_FROM = 3.0
    const val OVER_PLAN_FROM = 5.0
    const val ABOUT_USUAL = 2.0

    private fun date(t: Double, zone: ZoneId) = Instant.ofEpochMilli(floor(t * 1000).toLong()).atZone(zone).toLocalDate()

    fun isToday(t: Double, now: Double, zone: ZoneId) = date(t, zone) == date(now, zone)

    private fun r1(x: Double) = Math.round(x * 10) / 10.0

    fun today(trips: List<ScoreTrip>, now: Double, zone: ZoneId): List<DayTrip> {
        val list = trips.filter { isToday(it.at, now, zone) && it.at <= now + 60 }.sortedByDescending { it.at }
            .map { DayTrip(it.home, r1(it.mins), it.at, it.plan, it.lateLine, it.late) }
        return DayTrip.valid(list) ?: emptyList()
    }

    fun usual(trips: List<ScoreTrip>, home: Boolean, now: Double, zone: ZoneId): Double? {
        val todayStart = date(now, zone).atStartOfDay(zone).toEpochSecond().toDouble()
        val from = date(now, zone).minusDays(USUAL_DAYS.toLong()).atStartOfDay(zone).toEpochSecond().toDouble()
        val xs = trips.filter { it.home == home && it.at >= from && it.at < todayStart }.map { it.mins }.sorted()
        if (xs.size < USUAL_FROM) return null
        val m = xs.size / 2
        return if (xs.size % 2 == 1) xs[m] else (xs[m - 1] + xs[m]) / 2
    }

    data class Pick(val who: String, val trip: DayTrip)
    data class Row(val home: Boolean, val fastest: Pick, val slowest: Pick?, val mine: Boolean, val usual: Double?, val count: Int)

    fun rows(people: List<Pair<String, List<DayTrip>>>, mine: List<ScoreTrip>, now: Double, zone: ZoneId): List<Row> {
        val out = ArrayList<Row>()
        for (home in listOf(false, true)) {
            val all = people.flatMap { (id, trips) -> trips.filter { it.home == home && isToday(it.at, now, zone) && it.mins >= 5 }.map { Pick(id, it) } }
            if (all.isEmpty()) continue
            val tie = compareBy<Pick>({ it.trip.at }, { if (it.who == "me") 0 else 1 }, { it.who })
            val fast = all.sortedWith(compareBy<Pick> { it.trip.mins }.then(tie)).first()
            val slow = all.sortedWith(compareByDescending<Pick> { it.trip.mins }.then(tie)).first()
            val onlyMine = all.all { it.who == "me" }
            out.add(Row(home, fast, if (all.size > 1) slow else null, onlyMine, if (onlyMine) usual(mine, home, now, zone) else null, all.size))
        }
        return out
    }

    fun duration(mins: Double): String {
        val m = mins.roundToInt()
        if (m < 60) return "$m min"
        val h = m / 60; val r = m % 60
        return if (r == 0) "$h h" else "$h h ${if (r < 10) "0" else ""}$r"
    }

    fun why(t: DayTrip): String {
        val l = t.line; val m = t.late
        if (l != null && m != null && m >= LATE_FROM) return " — the $l was ${m.roundToInt()} min late"
        val p = t.plan
        if (p != null && t.mins - p >= OVER_PLAN_FROM) return " — ${(t.mins - p).roundToInt()} min more than planned"
        return ""
    }

    fun vsUsual(mins: Double, usual: Double?): String {
        val u = usual ?: return ""
        val d = mins - u
        if (abs(d) < ABOUT_USUAL) return " · about your usual"
        return " · ${abs(d).roundToInt()} min ${if (d < 0) "quicker" else "slower"} than usual"
    }

    fun lines(r: Row, name: (String) -> String): List<String> {
        fun who(p: Pick) = if (p.who == "me") "you" else name(p.who)
        if (r.mine) {
            val s = r.slowest ?: return listOf("Today: ${duration(r.fastest.trip.mins)}${vsUsual(r.fastest.trip.mins, r.usual)}")
            return listOf("🏆 Fastest today: ${duration(r.fastest.trip.mins)}${vsUsual(r.fastest.trip.mins, r.usual)}",
                "🐌 Slowest today: ${duration(s.trip.mins)}${why(s.trip)}")
        }
        val out = mutableListOf("🏆 Fastest today: ${who(r.fastest)}, ${duration(r.fastest.trip.mins)}")
        r.slowest?.let { out.add("🐌 Slowest today: ${who(it)}, ${duration(it.trip.mins)}${why(it.trip)}") }
        return out
    }
}
