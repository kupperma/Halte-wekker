package nl.haltewekker.school

import java.time.ZoneId

/** One event of a calendar you picked, as `CalendarContract.Instances` gives it. */
data class CalEvent(
    val title: String,
    val location: String?,
    val start: Double,
    val end: Double,
    val allDay: Boolean = false,
    val cancelled: Boolean = false,
)

/** A day's first class: from a calendar's first event of the day, or your week. */
data class Lesson(val day: String, val title: String?, val room: String?, val start: Double)

/** Where the first classes come from (iOS `ScheduleSource`). */
enum class ScheduleSource { NONE, CALENDARS, MANUAL }

/** Reading a timetable: the first class of each day (iOS `SchoolAlarm.calendarFirstClasses`), plain and tested. */
object Timetable {
    val amsterdam: ZoneId = ZoneId.of("Europe/Amsterdam")

    private val cancelledWords = listOf("cancelled", "canceled", "geannuleerd", "vervalt", "vervallen")
    fun isCancelled(title: String): Boolean { val l = title.lowercase(); return cancelledWords.any { l.contains(it) } }

    /** The first class of each day, by day (yyyy-MM-dd in `tz`): all-day and cancelled ones don't count. */
    fun firstClasses(events: List<CalEvent>, tz: ZoneId = amsterdam): Map<String, Lesson> {
        val out = HashMap<String, Lesson>()
        for (e in events) {
            if (e.allDay || e.cancelled || isCancelled(e.title) || !e.start.isFinite()) continue
            val k = ManualWeek.dayKey(e.start, tz)
            val had = out[k]
            if (had == null || e.start < had.start) out[k] = Lesson(k, e.title.ifBlank { null }, e.location?.ifBlank { null }, e.start)
        }
        return out
    }

    /** Your week's first classes for the next `days` days (today counts), titled as you named them. */
    fun fromWeek(w: ManualWeek, now: Double, days: Int = 8, tz: ZoneId = amsterdam): Map<String, Lesson> =
        w.lessons(now, days, tz).associate { it.day to Lesson(it.day, it.title ?: "Class", null, it.start) }

    /** When a day's last class ends (for Your day), if it has classes. */
    fun classesEnd(events: List<CalEvent>, day: String, tz: ZoneId = amsterdam): Double? =
        events.filter { !it.allDay && !it.cancelled && !isCancelled(it.title) && ManualWeek.dayKey(it.start, tz) == day }.maxOfOrNull { it.end }
}
