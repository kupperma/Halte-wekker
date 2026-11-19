package nl.haltewekker.friends

import kotlinx.serialization.Serializable
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.school.ManualWeek
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

// Friends (0.28), the iOS `FriendTimetable.swift`: your class timetable and start area as shared with friends (the
// `timetable` box in slot `tt`, ttl 21 days; `area` in slot `area`, ttl 30 days), and when they go. Unix seconds.

@Serializable
data class TimetableClass(val start: Double, val end: Double? = null, val title: String? = null, val room: String? = null) {
    companion object {
        const val MAX_TITLE = 80
        const val MAX_ROOM = 60
        const val MAX_LENGTH = 12 * 3600.0
    }
}

/** Every class from `from` (the first day's midnight) to `to` (exclusive), Amsterdam time. */
@Serializable
data class TimetableShare(
    val from: Double,
    val to: Double,
    val classes: List<TimetableClass>,
    val src: String? = null,
    val off: Boolean? = null,
) {
    val isOff: Boolean get() = off == true

    fun covers(day: String): Boolean {
        val d = TimetableDays.date(day) ?: return false
        return d >= from - 60 && d < to
    }

    companion object {
        const val MAX_CLASSES = 300
        const val MAX_WINDOW = 16 * 86400.0
        const val DAYS = 14

        fun takenBack(now: Double) = TimetableShare(from = now, to = now, classes = emptyList(), off = true)

        /** As kept (null: not a timetable): classes in the window, cleaned, sorted, at most 300. */
        fun valid(t: TimetableShare): TimetableShare? {
            if (t.isOff) return takenBack(t.from)
            if (t.to <= t.from || t.to - t.from > MAX_WINDOW) return null
            val out = t.classes.filter { it.start >= t.from && it.start < t.to }.map { c ->
                var e = c.end
                if (e != null && (e <= c.start || e - c.start > TimetableClass.MAX_LENGTH)) e = null
                c.copy(end = e,
                    title = c.title?.let { FriendNames.takeChars(FriendNames.cleanLine(it), TimetableClass.MAX_TITLE) }?.ifEmpty { null },
                    room = c.room?.let { FriendNames.takeChars(FriendNames.cleanLine(it), TimetableClass.MAX_ROOM) }?.ifEmpty { null })
            }.sortedWith(compareBy<TimetableClass> { it.start }.thenBy { it.end ?: it.start })
            return t.copy(classes = out.take(MAX_CLASSES))
        }
    }
}

@Serializable
data class TimetableArea(
    val stops: List<TripCard.Spot>,
    val station: Station? = null,
    val school: TripCard.Spot,
    val early: Int? = null,
) {
    @Serializable
    data class Station(val name: String, val code: String? = null, val id: String? = null, val lat: Double, val lon: Double) {
        val point: GeoPoint get() = GeoPoint(lat, lon)
    }

    /** Where a trip from home starts: the nearest stop, else the station. */
    val start: TripCard.Spot?
        get() = stops.firstOrNull() ?: station?.let { TripCard.Spot(it.name, it.id, it.lat, it.lon) }

    val earlyMinutes: Int get() = early ?: 10

    companion object {
        const val MAX_STOPS = 4

        fun valid(a: TimetableArea): TimetableArea? {
            if (a.school.point == null) return null
            val name = FriendNames.clean(a.school.name)
            return a.copy(
                stops = a.stops.filter { it.point != null && it.name.isNotEmpty() }.take(MAX_STOPS),
                school = a.school.copy(name = name.ifEmpty { "School" }),
                early = a.early?.coerceIn(0, 60),
            )
        }
    }
}

@Serializable data class TimetableSeen(val share: TimetableShare, val t: Long, val at: Double)
@Serializable data class AreaSeen(val area: TimetableArea, val t: Long, val at: Double)

/** Days as the timetables key them: yyyy-MM-dd in Amsterdam time. */
object TimetableDays {
    val zone: ZoneId = ZoneId.of("Europe/Amsterdam")
    private val ymd = DateTimeFormatter.ofPattern("yyyy-MM-dd")

    fun localDate(t: Double): LocalDate = Instant.ofEpochMilli(Math.floor(t * 1000).toLong()).atZone(zone).toLocalDate()
    fun key(t: Double): String = localDate(t).format(ymd)
    fun key(d: LocalDate): String = d.format(ymd)
    fun date(key: String): Double? = try { midnight(LocalDate.parse(key, ymd)) } catch (_: Exception) { null }
    fun midnight(d: LocalDate): Double = d.atStartOfDay(zone).toInstant().toEpochMilli() / 1000.0

    /** Today's midnight to the end of the 14th day. */
    fun window(now: Double, days: Int = TimetableShare.DAYS): Pair<Double, Double> {
        val a = localDate(now)
        return midnight(a) to midnight(a.plusDays(days.toLong()))
    }

    fun byDay(classes: List<TimetableClass>): Map<String, List<TimetableClass>> =
        classes.groupBy { key(it.start) }.mapValues { (_, v) -> v.sortedBy { it.start } }

    fun short(key: String): String = try { LocalDate.parse(key, ymd).format(DateTimeFormatter.ofPattern("EEE d", Locale.UK)) } catch (_: Exception) { key }
    fun weekday(key: String): String = try { LocalDate.parse(key, ymd).format(DateTimeFormatter.ofPattern("EEE", Locale.UK)) } catch (_: Exception) { key }
    fun hhmm(t: Double): String = TripCardWords.hhmm(t)
}

/** Your week's classes for `days` days from today: one per school day, first class to the day's end, with its title. */
fun ManualWeek.friendClasses(now: Double, days: Int, tz: ZoneId): List<TimetableClass> {
    val first = Instant.ofEpochMilli((now * 1000).toLong()).atZone(tz).toLocalDate()
    val out = ArrayList<TimetableClass>()
    for (i in 0 until maxOf(0, days)) {
        val day = first.plusDays(i.toLong())
        val d = this.days.firstOrNull { it.weekday == ManualWeek.weekdayOf(day) } ?: continue
        val start = ManualWeek.at(day, d.minutes, tz)
        val end = d.end?.takeIf { it > d.minutes }?.let { ManualWeek.at(day, it, tz) }
        out.add(TimetableClass(start, end, d.shownTitle, null))
    }
    return out
}

/** Your switches (on this phone and in the vault as `"timetable"`). */
@Serializable
data class TimetableSettings(val answered: Boolean? = null, val on: Boolean? = null, val off: List<String>? = null, val groups: List<String>? = null)

object TimetableShareRules {
    const val MIN_GAP = 3 * 3600.0
    const val REFRESH = 20 * 3600.0
    const val AREA_REFRESH = 7 * 86400.0
    const val LOOK_EVERY = 30 * 60.0
    const val TIMETABLE_TTL = 21 * 86400
    const val AREA_TTL = 30 * 86400
    const val TIMETABLE_SLOT = "tt"
    const val AREA_SLOT = "area"

    @Serializable data class Sent(val hash: String, val at: Double, val to: List<String>)

    fun due(last: Sent?, hash: String, recipients: List<String>, at: Double, every: Double = REFRESH): List<String> {
        if (recipients.isEmpty()) return emptyList()
        if (last == null) return recipients.sorted()
        val age = at - last.at
        if (age < 0 || age >= every || (hash != last.hash && age >= MIN_GAP)) return recipients.sorted()
        val had = last.to.toSet()
        return recipients.filter { it !in had }.sorted()
    }

    fun after(last: Sent?, hash: String, sent: List<String>, everyone: List<String>, at: Double): Sent {
        if (last != null && (sent.toSet() != everyone.toSet() || sent.isEmpty())) {
            return Sent(last.hash, last.at, (last.to.toSet() + sent).sorted())
        }
        return Sent(hash, at, everyone.sorted())
    }

    fun takeBack(last: Sent?, recipients: List<String>): List<String> {
        last ?: return emptyList()
        val keep = recipients.toSet()
        return last.to.filter { it !in keep }.sorted()
    }

    fun afterTakeBack(last: Sent?, gone: List<String>): Sent? {
        last ?: return null
        val g = gone.toSet()
        return last.copy(to = last.to.filter { it !in g })
    }

    /** FNV-1a 64 over the JSON (sorted keys), in hex. */
    fun fingerprint(data: ByteArray): String {
        var h = -0x340d631b7bdddcdbL       // 0xcbf29ce484222325
        for (b in data) { h = h xor (b.toLong() and 0xff); h *= 0x100000001b3L }
        return java.lang.Long.toUnsignedString(h, 16)
    }

    fun recipients(friends: List<String>, off: Set<String>, groupMembers: List<String>, me: String, on: Boolean): List<String> {
        if (!on) return emptyList()
        val out = friends.filter { it !in off }.toMutableSet()
        for (m in groupMembers) if (m !in off) out.add(m)
        out.remove(me)
        return out.sorted()
    }
}
