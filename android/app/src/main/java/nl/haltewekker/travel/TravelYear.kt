package nl.haltewekker.travel

import kotlinx.serialization.Serializable
import nl.haltewekker.friends.ScoreTrip
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.roundToInt

/** (A6, iOS 0.35 `TravelYear.swift`) one ride (a leg), as the phone keeps it for Your year in travel. Never sent. */
@Serializable
data class RideRecord(
    val id: String,
    val trip: Double,
    val dep: Double,
    val arr: Double,
    val train: Boolean,
    val label: String,
    val from: String,
    val to: String,
    val km: Double,
    val late: Double? = null,
    val coach: Int? = null,
) {
    val minutes: Double get() = max(0.0, (arr - dep) / 60)
}

object TravelLog {
    const val KEEP_DAYS = 800
    const val MAX_KEPT = 6000

    fun add(list: List<RideRecord>, r: RideRecord, now: Double): List<RideRecord> {
        val oldest = now - KEEP_DAYS * 86400.0
        return (list.filter { it.id != r.id } + r).filter { it.dep >= oldest }.sortedBy { it.dep }.takeLast(MAX_KEPT)
    }
}

data class TravelStats(
    val since: Double? = null,
    val fullYear: Boolean = false,
    val trips: Int = 0,
    val rides: Int = 0,
    val busMinutes: Double = 0.0,
    val trainMinutes: Double = 0.0,
    val earlierMinutes: Double = 0.0,
    val busKm: Double = 0.0,
    val trainKm: Double = 0.0,
    val line: Fav? = null,
    val stop: Fav? = null,
    val coach: Fav? = null,
    val earliest: Double? = null,
    val delay: Delay? = null,
    val friends: Int = 0,
) {
    data class Fav(val label: String, val n: Int)
    data class Delay(val label: String, val mins: Double, val at: Double)

    val hours: Double get() = (busMinutes + trainMinutes + earlierMinutes) / 60
    val km: Double get() = busKm + trainKm
    val co2Saved: Double get() = TravelYear.co2Saved(busKm, trainKm)
    val empty: Boolean get() = trips == 0 && rides == 0
}

/** A card of Your year in travel; `shareSub`: the line on the shared picture when it isn't `sub` (no places in it). */
data class YearCard(val id: String, val title: String, val value: String, val sub: String, val shareSub: String? = null)

object TravelYear {
    const val CAR_KG_PER_KM = 0.19
    const val BUS_KG_PER_KM = 0.05
    const val TRAIN_KG_PER_KM = 0.02
    const val WINDOW_DAYS = 365

    fun co2Saved(busKm: Double, trainKm: Double) = max(0.0, busKm) * (CAR_KG_PER_KM - BUS_KG_PER_KM) + max(0.0, trainKm) * (CAR_KG_PER_KM - TRAIN_KG_PER_KM)

    fun km(metres: Double, train: Boolean) = max(0.0, metres) / 1000 * if (train) 1.15 else 1.3

    fun stats(rides: List<RideRecord>, trips: List<ScoreTrip>, together: List<Double>, now: Double, zone: ZoneId): TravelStats {
        val from = now - WINDOW_DAYS * 86400.0
        val mine = rides.filter { it.dep >= from && it.dep <= now }
        val firstRide = rides.minOfOrNull { it.dep }
        val earlier = trips.filter { it.at >= from && it.at <= now && (firstRide == null || it.at < firstRide) }
        val firstAny = listOfNotNull(firstRide, trips.minOfOrNull { it.at - it.mins * 60 }).minOrNull()
        var bus = 0.0; var train = 0.0; var bkm = 0.0; var tkm = 0.0
        for (r in mine) if (r.train) { train += r.minutes; tkm += r.km } else { bus += r.minutes; bkm += r.km }
        val starts = mine.map { it.dep } + earlier.map { it.at - it.mins * 60 }
        val d = mine.filter { (it.late ?: 0.0) >= 1 }.maxWithOrNull(compareBy<RideRecord> { it.late ?: 0.0 }.thenByDescending { it.dep })
        return TravelStats(
            since = listOfNotNull(mine.minOfOrNull { it.dep }, earlier.minOfOrNull { it.at - it.mins * 60 }).minOrNull(),
            fullYear = firstAny?.let { it <= from } ?: false,
            trips = mine.map { it.trip }.toSet().size + earlier.size,
            rides = mine.size,
            busMinutes = bus, trainMinutes = train, earlierMinutes = earlier.sumOf { it.mins }, busKm = bkm, trainKm = tkm,
            line = favourite(mine.map { it.label }),
            stop = favourite(mine.map { it.from }),
            coach = favourite(mine.mapNotNull { r -> if (r.train) r.coach?.let { "Coach $it" } else null }, least = 2),
            earliest = starts.minByOrNull { secondOfDay(it, zone) },
            delay = d?.let { TravelStats.Delay(it.label, it.late ?: 0.0, it.dep) },
            friends = together.count { it >= from && it <= now },
        )
    }

    fun favourite(xs: List<String>, least: Int = 1): TravelStats.Fav? {
        val n = LinkedHashMap<String, Int>(); val last = HashMap<String, Int>()
        xs.forEachIndexed { i, x -> if (x.isNotEmpty()) { n[x] = (n[x] ?: 0) + 1; last[x] = i } }
        val best = n.entries.maxWithOrNull(compareBy<Map.Entry<String, Int>> { it.value }.thenBy { last[it.key] ?: 0 }) ?: return null
        return if (best.value >= least) TravelStats.Fav(best.key, best.value) else null
    }

    private fun z(t: Double, zone: ZoneId) = Instant.ofEpochMilli((t * 1000).toLong()).atZone(zone)

    fun secondOfDay(t: Double, zone: ZoneId): Int { val d = z(t, zone); return d.hour * 3600 + d.minute * 60 + d.second }

    fun grouped(n: Int): String {
        val s = abs(n).toString()
        val out = StringBuilder()
        s.reversed().forEachIndexed { i, ch -> if (i > 0 && i % 3 == 0) out.append(','); out.append(ch) }
        return (if (n < 0) "-" else "") + out.reverse().toString()
    }

    fun hours(h: Double): String = if (h < 1) "${(h * 60).roundToInt()} min" else "${grouped(h.roundToInt())} h"

    fun day(t: Double, zone: ZoneId): String = DateTimeFormatter.ofPattern("EEE d MMM", Locale.UK).format(z(t, zone))

    fun hhmm(t: Double, zone: ZoneId): String { val d = z(t, zone); return String.format(Locale.ROOT, "%02d:%02d", d.hour, d.minute) }

    fun cards(s: TravelStats, zone: ZoneId): List<YearCard> {
        if (s.empty) return emptyList()
        val out = ArrayList<YearCard>()
        val sinceWords = s.since?.let { "Since ${day(it, zone)}" } ?: "So far"
        out.add(YearCard("intro", if (s.fullYear) "Your year in travel" else "Your travel so far", if (s.trips == 1) "1 trip" else "${grouped(s.trips)} trips",
            if (s.fullYear) "The last 12 months on buses and trains." else "$sinceWords, on buses and trains."))
        if (s.hours > 0) {
            val parts = ArrayList<String>()
            if (s.trainMinutes > 0) parts.add("${hours(s.trainMinutes / 60)} by train")
            if (s.busMinutes > 0) parts.add("${hours(s.busMinutes / 60)} by bus")
            if (s.earlierMinutes > 0) parts.add("${hours(s.earlierMinutes / 60)} on earlier trips, door to door")
            out.add(YearCard("hours", "Time on board", hours(s.hours), parts.joinToString(" · ") + "."))
        }
        if (s.km >= 1) {
            val earth = 40_075.0
            val k = s.km.roundToInt()
            val around = if (s.km >= earth) String.format(Locale.ROOT, "%.1f× around the world", s.km / earth)
                else "${max(1, (s.km / earth * 100).roundToInt())}% of the way around the world"
            out.add(YearCard("km", "Distance", "${grouped(k)} km", "About $around."))
            val kg = s.co2Saved.roundToInt()
            if (kg >= 1) out.add(YearCard("co2", "CO₂ saved", "${grouped(kg)} kg",
                "About that much less than driving those ${grouped(k)} km alone in a car (car 0.19 kg/km, bus 0.05, train 0.02)."))
        }
        s.line?.let { l ->
            val bits = mutableListOf(if (l.n == 1) "1 ride" else "${grouped(l.n)} rides")
            val share = bits.toMutableList()
            s.stop?.let { bits.add("most often from ${it.label}") }
            s.coach?.let { bits.add("${it.label.lowercase()} on the train"); share.add("${it.label.lowercase()} on the train") }
            out.add(YearCard("favourite", "Your favourite", l.label, bits.joinToString(" · ") + ".", share.joinToString(" · ") + "."))
        }
        s.earliest?.let { out.add(YearCard("early", "Earliest start", hhmm(it, zone), "${day(it, zone)}. The early bird gets the seat.")) }
        s.delay?.let { out.add(YearCard("delay", "Longest delay survived", "${it.mins.roundToInt()} min", "The ${it.label} on ${day(it.at, zone)}. You made it anyway.")) }
        if (s.friends > 0) out.add(YearCard("friends", "With friends", if (s.friends == 1) "1 ride" else "${grouped(s.friends)} rides", "On the same bus or train as a friend."))
        return out
    }

    fun seasonal(now: Double, firstData: Double?, trips: Int, dismissed: Int?, zone: ZoneId): Int? {
        if (trips < 5) return null
        val n = z(now, zone)
        if (dismissed == n.year) return null
        if (n.monthValue == 12) return n.year
        if (firstData != null) {
            val a = firstData + WINDOW_DAYS * 86400.0
            if (now >= a && now < a + 14 * 86400) return n.year
        }
        return null
    }
}
