package nl.haltewekker.friends

import kotlinx.serialization.Serializable
import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import java.util.Locale

// Friends (0.27), the iOS `FriendTripCard.swift`: a trip sent to a friend or a group (the `trip` box), and what "Take
// this trip" makes of it. Times are unix seconds.

@Serializable
data class TripCard(
    val rides: List<Ride>,
    val to: Spot,
    val from: Spot? = null,
    val start: Double? = null,
    val end: Double? = null,
    val by: Double? = null,
    val note: String? = null,
) {
    @Serializable
    data class Spot(val name: String, val id: String? = null, val lat: Double? = null, val lon: Double? = null) {
        val point: GeoPoint? get() = if (lat != null && lon != null) GeoPoint(lat, lon) else null
    }

    @Serializable
    data class Ride(
        val mode: String,
        val line: String,
        val name: String? = null,
        val num: String? = null,
        val trip: String,
        val head: String? = null,
        val from: Spot,
        val to: Spot,
        val dep: Double,
        val arr: Double,
        val sdep: Double? = null,
        val sarr: Double? = null,
        val plat: String? = null,
        val walk: Int? = null,
    ) {
        val isTrain: Boolean get() = mode == "train"
        val label: String get() = if (isTrain) (num?.let { "$line $it" } ?: line) else "Bus $line"
    }

    val first: Ride? get() = rides.firstOrNull()
    val arrival: Double? get() = end ?: rides.lastOrNull()?.arr

    companion object {
        const val MAX_RIDES = 8
        const val MAX_NOTE = 200

        /** As taken: 1–8 rides, each arriving after it leaves, with a trip id. */
        fun valid(c: TripCard): TripCard? {
            if (c.rides.isEmpty() || c.rides.size > MAX_RIDES || !c.rides.all { it.arr >= it.dep && it.trip.isNotEmpty() }) return null
            val note = c.note?.let { FriendNames.takeChars(ChatText.clean(it), MAX_NOTE) }?.ifEmpty { null }
            return c.copy(note = note)
        }
    }
}

object TripTake {
    sealed class Way {
        data object Fastest : Way()
        data class BeThereBy(val out: Boolean, val tomorrow: Boolean) : Way()
        data object Plan : Way()
        data object Gone : Way()
    }

    const val SOON = 3600.0
    const val SAME_START_METRES = 600.0
    const val SAME_PLACE_METRES = 500.0
    val amsterdam: ZoneId = ZoneId.of("Europe/Amsterdam")

    fun sharedIndex(c: TripCard): Int {
        val t = c.rides.indexOfFirst { it.isTrain }
        if (t >= 0) return t
        var best = 0
        for ((i, r) in c.rides.withIndex()) if (r.arr - r.dep > c.rides[best].arr - c.rides[best].dep) best = i
        return best
    }

    fun shared(c: TripCard): TripCard.Ride? = if (c.rides.isEmpty()) null else c.rides[sharedIndex(c)]

    private fun day(t: Double, zone: ZoneId): LocalDate = Instant.ofEpochMilli((t * 1000).toLong()).atZone(zone).toLocalDate()

    fun way(c: TripCard, now: Double, home: GeoPoint?, school: GeoPoint?, zone: ZoneId = amsterdam): Way {
        val s = shared(c) ?: return Way.Plan
        if (s.dep < now - 60) return Way.Gone
        if (s.dep - now <= SOON) return Way.Fastest
        val d = ChronoUnit.DAYS.between(day(now, zone), day(c.by ?: c.arrival ?: s.arr, zone))
        val end = c.to.point ?: c.rides.lastOrNull()?.to?.point
        if ((d != 0L && d != 1L) || end == null) return Way.Plan
        if (school != null && Geo.metres(school, end) <= SAME_PLACE_METRES) return Way.BeThereBy(true, d == 1L)
        if (home != null && Geo.metres(home, end) <= SAME_PLACE_METRES) return Way.BeThereBy(false, d == 1L)
        return Way.Plan
    }

    fun sameStart(c: TripCard, you: GeoPoint?): Boolean {
        val f = c.first?.from?.point ?: return false
        return you != null && Geo.metres(you, f) <= SAME_START_METRES
    }

    /** Which of your planner's options (each its rides' trip ids) has the shared ride: the one sharing most of the card's. */
    fun pick(options: List<List<String>>, c: TripCard): Int? {
        val s = shared(c) ?: return null
        val mine = c.rides.map { it.trip }.toSet()
        var best: Pair<Int, Int>? = null
        for ((i, ids) in options.withIndex()) {
            if (s.trip !in ids) continue
            val n = ids.toSet().intersect(mine).size
            if (best == null || n > best.second) best = i to n
        }
        return best?.first
    }

    fun deadline(c: TripCard): Double? = c.by ?: c.arrival
}

object TripCardWords {
    fun hhmm(t: Double): String = DateTimeFormatter.ofPattern("HH:mm").withZone(TripTake.amsterdam).format(Instant.ofEpochMilli((t * 1000).toLong()))

    /** "Today", "Tomorrow", "Thursday" (within a week), "Thu 27 Nov". */
    fun day(t: Double, now: Double): String {
        val z = TripTake.amsterdam
        val a = Instant.ofEpochMilli((now * 1000).toLong()).atZone(z).toLocalDate()
        val b = Instant.ofEpochMilli((t * 1000).toLong()).atZone(z)
        val n = ChronoUnit.DAYS.between(a, b.toLocalDate())
        if (n == 0L) return "Today"
        if (n == 1L) return "Tomorrow"
        val f = DateTimeFormatter.ofPattern(if (n in 2..6) "EEEE" else "EEE d MMM", Locale.UK)
        return f.format(b)
    }

    fun headline(c: TripCard, now: Double, group: Boolean): String {
        if (!c.note.isNullOrEmpty()) return c.note
        val who = if (group) "us" else "me"
        c.by?.let { return "${day(it, now)}: be at ${c.to.name} by ${hhmm(it)}, this way" }
        val s = TripTake.shared(c) ?: return "A trip to ${c.to.name}"
        val d = day(s.dep, now)
        val t = hhmm(s.dep)
        val whenText = when (d) { "Today" -> t; "Tomorrow" -> "$t tomorrow"; else -> "$t on $d" }
        return "Take the $whenText with $who?"
    }

    fun ride(r: TripCard.Ride): String = "${if (r.isTrain) r.line else "Bus ${r.line}"} ${hhmm(r.dep)} ${r.from.name} → ${r.to.name}"

    fun short(c: TripCard): String {
        val f = c.first ?: return c.to.name
        return "${hhmm(f.dep)} to ${c.to.name}"
    }
}
