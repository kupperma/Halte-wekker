package nl.haltewekker.school

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.Transient
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter

/**
 * "Same times every week" (iOS `ManualWeek`, 0.23 and 0.28): the first class of each weekday with school, with an
 * optional end and title. Weekdays as the iOS calendar numbers them (1 Sunday, 2 Monday … 7 Saturday), so a week can
 * be shared with the iOS app later. Saved in the profile; the school alarm plans from it as from a calendar.
 */
@Serializable
data class WeekDay(val weekday: Int, val minutes: Int, val end: Int? = null, val title: String? = null) {
    /** The title as shared: single spaces, trimmed (null: none). */
    val shownTitle: String? get() = title?.split(Regex("\\s+"))?.filter { it.isNotEmpty() }?.joinToString(" ")?.ifEmpty { null }
}

@Serializable
data class ManualWeek(@SerialName("days") private val given: List<WeekDay> = emptyList()) {
    /** At most one per weekday, in weekday order; days that don't make sense are left out. */
    @Transient val days: List<WeekDay> = clean(given)

    fun minutes(weekday: Int): Int? = days.firstOrNull { it.weekday == weekday }?.minutes
    fun end(weekday: Int): Int? = days.firstOrNull { it.weekday == weekday }?.end
    fun title(weekday: Int): String? = days.firstOrNull { it.weekday == weekday }?.title
    val isEmpty: Boolean get() = days.isEmpty()

    /** Sets (or clears, with null) a weekday's first class. A day that had an end time and a title keeps them. */
    fun set(weekday: Int, minutes: Int?): ManualWeek {
        val had = days.firstOrNull { it.weekday == weekday }
        val l = days.filter { it.weekday != weekday }.toMutableList()
        if (minutes != null) l.add(WeekDay(weekday, minutes, had?.end, had?.title))
        return ManualWeek(clean(l))
    }

    /** Sets a day's end (null: none); ignored for a day without school, or an end not after its start. */
    fun setEnd(weekday: Int, minutes: Int?): ManualWeek =
        ManualWeek(clean(days.map { if (it.weekday == weekday) it.copy(end = minutes) else it }))

    /** Sets a day's title (empty: none). */
    fun setTitle(weekday: Int, title: String?): ManualWeek =
        ManualWeek(clean(days.map { if (it.weekday == weekday) it.copy(title = title) else it }))

    /** A day's first class: its day (yyyy-MM-dd in the week's time zone) and when it starts. */
    data class Lesson(val day: String, val start: Double, val end: Double? = null, val title: String? = null)

    /**
     * The first classes from the start of `now`'s day for `count` days (today counts as the first), in `tz`. A time
     * that's already past is left out; the clock time stays the same across a change to or from summer time.
     */
    fun lessons(now: Double, count: Int, tz: ZoneId): List<Lesson> {
        val first = Instant.ofEpochMilli((now * 1000).toLong()).atZone(tz).toLocalDate()
        val out = ArrayList<Lesson>()
        for (i in 0 until maxOf(0, count)) {
            val day = first.plusDays(i.toLong())
            val wd = weekdayOf(day)
            val m = minutes(wd) ?: continue
            val start = at(day, m, tz)
            if (start <= now) continue
            out.add(Lesson(dayKey(day), start, end(wd)?.let { at(day, it, tz) }, days.firstOrNull { it.weekday == wd }?.shownTitle))
        }
        return out
    }

    companion object {
        const val MAX_TITLE = 40

        /** Monday to Friday at 08:30: where "Same times every week" starts. */
        val workdays = ManualWeek((2..6).map { WeekDay(it, 8 * 60 + 30) })

        private val ymd: DateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd")
        fun dayKey(d: LocalDate): String = d.format(ymd)
        fun dayKey(t: Double, tz: ZoneId): String = dayKey(Instant.ofEpochMilli((t * 1000).toLong()).atZone(tz).toLocalDate())

        /** The iOS weekday number of a date: 1 Sunday … 7 Saturday. */
        fun weekdayOf(d: LocalDate): Int = d.dayOfWeek.value % 7 + 1

        fun at(day: LocalDate, minutes: Int, tz: ZoneId): Double =
            ZonedDateTime.of(day.atTime(minutes / 60, minutes % 60), tz).toInstant().toEpochMilli() / 1000.0

        fun clean(l: List<WeekDay>): List<WeekDay> {
            val by = HashMap<Int, WeekDay>()
            for (d in l) {
                if (d.weekday !in 1..7 || d.minutes !in 0 until 1440) continue
                var k = d
                if (d.end != null && !(d.end > d.minutes && d.end < 1440)) k = k.copy(end = null)
                if (d.title != null) {
                    val c = d.title.replace("\n", " ").take(MAX_TITLE)
                    k = k.copy(title = c.ifEmpty { null })
                }
                by[d.weekday] = k
            }
            return by.keys.sorted().map { by.getValue(it) }
        }

        private val names = listOf("Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat")
        fun dayName(weekday: Int): String = names[(weekday - 1).coerceIn(0, 6)]
        fun clock(m: Int): String = "%02d:%02d".format(m / 60, m % 60)

        /** "Mon–Fri 08:30", "Mon 08:30 · Wed 10:15", with an end "Mon–Fri 08:30–15:00" (iOS `SetupLogic.weekWords`). */
        fun words(w: ManualWeek): String {
            if (w.days.isEmpty()) return "No days yet"
            fun span(d: WeekDay) = d.end?.let { clock(d.minutes) + "–" + clock(it) } ?: clock(d.minutes)
            val times = w.days.map(::span).toSet()
            val wds = w.days.map { it.weekday }
            if (times.size == 1 && wds.size >= 3 && wds == (wds.first()..wds.last()).toList()) {
                return "${dayName(wds.first())}–${dayName(wds.last())} ${span(w.days[0])}"
            }
            return w.days.joinToString(" · ") { "${dayName(it.weekday)} ${span(it)}" }
        }
    }
}
