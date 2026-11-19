package nl.haltewekker.friends

import kotlinx.serialization.Serializable
import java.time.Instant
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.max
import kotlin.math.min

// Friends extras, part B (0.30), the iOS `FriendExtrasB.swift`: free hours together today, the friends leaderboard and
// the ride history, as plain values and rules. (The live link is LiveLink.kt.) The `scores` box and the rules:
// docs/superpowers/specs/2026-11-18-friends-design.md, "As built (0.30)".

// MARK: free hours together

data class FreeTodaySlot(val start: Double, val end: Double, val with: List<String>)

object FreeToday {
    const val MAX_SHOWN = 3
    const val NOTE_FROM = 6
    const val NOTE_UNTIL = 11

    fun slots(mine: TimetableShare?, friends: List<Pair<String, TimetableShare>>, now: Double): List<FreeTodaySlot> {
        mine ?: return emptyList()
        val key = TimetableDays.key(now)
        if (!mine.covers(key)) return emptyList()
        val me = PersonDay("me", true, TimetableDays.byDay(mine.classes)[key] ?: emptyList())
        val out = mutableListOf<FreeTodaySlot>()
        for ((id, share) in friends) {
            if (!share.covers(key)) continue
            val theirs = PersonDay(id, true, TimetableDays.byDay(share.classes)[key] ?: emptyList())
            for (s in Compare.freeTogether(CompareDay(key, listOf(me, theirs)), limit = 4)) {
                if (s.end <= now) continue
                val i = out.indexOfFirst { it.start == s.start && it.end == s.end }
                if (i >= 0) {
                    if (id !in out[i].with) out[i] = out[i].copy(with = (out[i].with + id).sorted())
                } else out.add(FreeTodaySlot(s.start, s.end, listOf(id)))
            }
        }
        return out.sortedWith(compareBy<FreeTodaySlot> { it.start }.thenBy { it.end }).take(MAX_SHOWN)
    }

    fun line(s: FreeTodaySlot, names: List<String>, now: Double): String {
        val who = CompareWords.names(listOf("you") + names)
        val both = if (names.size == 1) "both" else "all"
        if (s.start <= now) return "Now: $who are $both free until ${TimetableDays.hhmm(s.end)}"
        return "Today: $who are $both free ${TimetableDays.hhmm(s.start)}–${TimetableDays.hhmm(s.end)}"
    }

    fun note(slots: List<FreeTodaySlot>, names: (String) -> String, now: Double): String =
        slots.joinToString("\n") { s ->
            val l = line(s, s.with.map(names), now)
            TravelWords.capitalFirst(l.removePrefix("Today: "))
        }

    fun noteDue(on: Boolean, lastDay: String?, slots: List<FreeTodaySlot>, now: Double): Boolean {
        val first = slots.firstOrNull() ?: return false
        if (!on || first.start <= now) return false
        if (lastDay == TimetableDays.key(now)) return false
        val h = Instant.ofEpochMilli((now * 1000).toLong()).atZone(TimetableDays.zone).hour
        return h >= NOTE_FROM && h < NOTE_UNTIL
    }
}

// MARK: the friends leaderboard

/** The body of a `scores` box (slot `scores`, ttl 14 days). `on: false` takes it back. */
@Serializable
data class ScoresShare(
    val on: Boolean,
    val month: String? = null,
    val best: List<Best>? = null,
    val mbest: List<Best>? = null,
    val rides: Int? = null,
) {
    @Serializable
    data class Best(val route: String, val home: Boolean, val mins: Double, val at: Double)

    companion object {
        const val MAX_ROUTES = 8
        const val ROUTE_LENGTH = 40

        fun valid(s: ScoresShare): ScoresShare {
            fun clean(list: List<Best>?): List<Best>? = list?.mapNotNull { b ->
                val r = FriendNames.takeChars(FriendNames.clean(b.route), ROUTE_LENGTH)
                if (r.isEmpty() || b.mins < 5 || b.mins > 600) null else b.copy(route = r)
            }?.take(MAX_ROUTES)
            if (!s.on) return ScoresShare(on = false)
            val m = s.month?.takeIf { ScoresRules.isMonth(it) }
            return ScoresShare(on = true, month = m, best = clean(s.best), mbest = if (m != null) clean(s.mbest) else null,
                rides = if (m != null) s.rides?.takeIf { it in 0..1000 } else null)
        }
    }
}

@Serializable data class ScoresSeen(val share: ScoresShare, val t: Long, val got: Double)

/** A finished trip on your own board, as the friends board counts it. */
@Serializable data class ScoreTrip(val route: String, val home: Boolean, val mins: Double, val at: Double)

object ScoresRules {
    const val SLOT = "scores"
    const val TTL = 14 * 86400
    const val CHANGED_GAP = 12 * 3600.0
    const val REFRESH = 7 * 86400.0
    const val OFF_TTL = 14 * 86400

    fun month(t: Double): String = TimetableDays.key(t).take(7)

    fun isMonth(s: String): Boolean {
        val p = s.split("-")
        if (s.length != 7 || p.size != 2 || p[0].length != 4 || p[1].length != 2) return false
        if (!p.all { part -> part.all { it in '0'..'9' } }) return false
        return p[1].toInt() in 1..12
    }

    fun build(trips: List<ScoreTrip>, rides: Int, now: Double): ScoresShare {
        val m = month(now)
        return ScoresShare(on = true, month = m, best = bests(trips), mbest = bests(trips.filter { month(it.at) == m }), rides = rides.clampTo(0, 1000))
    }

    fun bests(trips: List<ScoreTrip>): List<ScoresShare.Best> {
        val by = LinkedHashMap<String, ScoreTrip>()
        for (t in trips) {
            if (t.mins < 5 || t.mins > 600 || t.route.isEmpty()) continue
            val k = "${t.home}|${t.route}"
            val had = by[k]
            if (had != null && had.mins <= t.mins) continue
            by[k] = t
        }
        return by.values.sortedWith(compareBy<ScoreTrip> { it.home }.thenBy { it.mins }.thenBy { it.route })
            .take(ScoresShare.MAX_ROUTES)
            .map { ScoresShare.Best(FriendNames.takeChars(it.route, ScoresShare.ROUTE_LENGTH), it.home, it.mins.roundTenth(), it.at) }
    }

    fun fingerprint(s: ScoresShare): String = TimetableShareRules.fingerprint(FriendJson.encode(ScoresShare.serializer(), s))

    fun due(last: TimetableShareRules.Sent?, hash: String, friends: List<String>, now: Double): List<String> {
        if (friends.isEmpty()) return emptyList()
        if (last == null) return friends.sorted()
        val age = now - last.at
        if (age < 0 || age >= REFRESH || (hash != last.hash && age >= CHANGED_GAP)) return friends.sorted()
        val had = last.to.toSet()
        return friends.filter { it !in had }.sorted()
    }
}

data class ScoresPerson(val id: String, val share: ScoresShare)
data class ScoreRow(val who: String, val mins: Double, val at: Double)
data class ScoreGroup(val home: Boolean, val route: String, val rows: List<ScoreRow>) { val id: String get() = "$home|$route" }
data class RidesRow(val who: String, val n: Int)

object ScoreBoard {
    fun groups(people: List<ScoresPerson>, month: String?): List<ScoreGroup> {
        val by = LinkedHashMap<String, Pair<ScoresShare.Best, MutableList<ScoreRow>>>()
        for (p in people) {
            if (!p.share.on) continue
            val list = if (month != null) {
                if (p.share.month != month) continue
                p.share.mbest ?: emptyList()
            } else p.share.best ?: emptyList()
            for (b in list) {
                val k = "${b.home}|${b.route}"
                val rows = by.getOrPut(k) { b to mutableListOf() }.second
                val i = rows.indexOfFirst { it.who == p.id }
                if (i >= 0) { if (b.mins < rows[i].mins) rows[i] = ScoreRow(p.id, b.mins, b.at) }
                else rows.add(ScoreRow(p.id, b.mins, b.at))
            }
        }
        return by.values.map { (b, rows) -> ScoreGroup(b.home, b.route, rows.sortedWith(compareBy<ScoreRow> { it.mins }.thenBy { it.at })) }
            .sortedWith(compareBy<ScoreGroup> { it.home }.thenByDescending { it.rows.size }.thenBy { it.route })
    }

    fun rides(people: List<ScoresPerson>, month: String): List<RidesRow> =
        people.mapNotNull { p ->
            val n = p.share.rides
            if (!p.share.on || p.share.month != month || n == null || n <= 0) null else RidesRow(p.id, n)
        }.sortedWith(compareByDescending<RidesRow> { it.n }.thenBy { it.who })

    /** "Home → school", "School → home", else "Via Den Bosch · to school" / "· home". */
    fun label(g: ScoreGroup): String = when (g.route) {
        DoorScore.TO_SCHOOL -> "Home → school"
        DoorScore.TO_HOME -> "School → home"
        else -> "${g.route} · ${if (g.home) "home" else "to school"}"
    }
}

/** The door-to-door board's keys (iOS `DoorScore`): a trip from near Home to near School, or back. */
object DoorScore {
    const val TO_SCHOOL = "home→school"
    const val TO_HOME = "school→home"
    const val START_METRES = 2500.0
    const val END_METRES = 1500.0

    fun key(start: nl.haltewekker.core.GeoPoint, end: nl.haltewekker.core.GeoPoint, home: nl.haltewekker.core.GeoPoint,
            school: nl.haltewekker.core.GeoPoint): Pair<String, Boolean>? {
        val m = nl.haltewekker.core.Geo::metres
        val sh = m(start, home); val ss = m(start, school); val eh = m(end, home); val es = m(end, school)
        if (sh <= START_METRES && es <= END_METRES && sh < ss && es < eh) return TO_SCHOOL to false
        if (ss <= START_METRES && eh <= END_METRES && ss < sh && eh < es) return TO_HOME to true
        return null
    }

    /** Minutes, one decimal, from starting the alarm to the last stop; null under 5 minutes. */
    fun minutes(start: Double, end: Double): Double? {
        val mins = Math.round((end - start) / 6) / 10.0
        return if (mins >= 5) mins else null
    }
}

// MARK: ride history together

/** A ride you shared with friends, kept on this phone only: one per vehicle per day. */
@Serializable
data class RideTogether(val trip: String, val day: String, val label: String, val from: String, val to: String, val dep: Double, val with: List<String>) {
    val id: String get() = "$day|$trip"
}

object RideHistory {
    const val KEEP_DAYS = 400
    const val MAX_KEPT = 1000
    const val SHOWN_LAST = 10
    const val CARD_AGE = 24 * 3600.0

    fun riders(trip: String, travel: List<Pair<String, TravelState>>, cards: List<Pair<TripCard, List<String>>>, me: String): List<String> {
        if (trip.isEmpty()) return emptyList()
        val out = HashSet<String>()
        for ((from, st) in travel) if (st.trip == trip && st.stage == TravelState.Stage.RIDING) out.add(from)
        for ((card, riders) in cards) {
            val s = TripTake.shared(card) ?: continue
            if (s.trip == trip) out.addAll(riders)
        }
        out.remove(me)
        return out.sorted()
    }

    fun add(list: List<RideTogether>, r: RideTogether, now: Double): List<RideTogether> {
        if (r.with.isEmpty() || r.trip.isEmpty()) return list
        val out = list.toMutableList()
        val i = out.indexOfFirst { it.id == r.id }
        if (i >= 0) out[i] = out[i].copy(with = (out[i].with.toSet() + r.with).sorted())
        else out.add(r.copy(with = r.with.toSet().sorted()))
        val oldest = now - KEEP_DAYS * 86400.0
        return out.filter { it.dep >= oldest }.sortedWith(compareByDescending<RideTogether> { it.dep }.thenBy { it.trip }).take(MAX_KEPT)
    }

    fun count(list: List<RideTogether>, with: String, now: Double): Int {
        val m = ScoresRules.month(now)
        return list.count { it.day.startsWith(m) && with in it.with }
    }

    fun count(list: List<RideTogether>, now: Double): Int {
        val m = ScoresRules.month(now)
        return list.count { it.day.startsWith(m) }
    }

    fun last(list: List<RideTogether>, with: String, limit: Int = SHOWN_LAST): List<RideTogether> =
        list.filter { with in it.with }.sortedByDescending { it.dep }.take(limit)

    fun keep(list: List<RideTogether>, friends: Set<String>): List<RideTogether> =
        list.mapNotNull { r -> r.copy(with = r.with.filter { it in friends }).takeIf { it.with.isNotEmpty() } }
}

object RideHistoryWords {
    fun month(n: Int): String = when (n) {
        0 -> "No rides together this month yet"
        1 -> "You rode together once this month"
        2 -> "You rode together twice this month"
        else -> "You rode together $n times this month"
    }

    private val dayFormat = DateTimeFormatter.ofPattern("EEE d MMM", Locale.UK).withZone(TimetableDays.zone)

    fun row(r: RideTogether): String =
        "${dayFormat.format(Instant.ofEpochMilli((r.dep * 1000).toLong()))} · ${TimetableDays.hhmm(r.dep)} · ${r.label} · ${r.from} → ${r.to}"
}

