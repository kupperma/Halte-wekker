package nl.haltewekker.school

import android.Manifest
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.provider.CalendarContract
import androidx.core.content.ContextCompat

/** A calendar on the phone, as the setup and Settings show it. */
data class PhoneCalendar(val id: Long, val name: String, val account: String, val color: Int, val synced: Boolean)

/**
 * The phone's calendars (`CalendarContract`, READ_CALENDAR): only the ones you pick are read, and only their events'
 * times, titles and rooms. Any app that syncs a calendar to Android shows up here: Google Calendar, Outlook, a roster
 * link subscribed to with ICSx⁵, a school's own app. Everything here blocks: call it off the main thread.
 */
object Calendars {
    fun granted(c: Context) = ContextCompat.checkSelfPermission(c, Manifest.permission.READ_CALENDAR) == PackageManager.PERMISSION_GRANTED

    fun list(c: Context): List<PhoneCalendar> {
        if (!granted(c)) return emptyList()
        val cols = arrayOf(CalendarContract.Calendars._ID, CalendarContract.Calendars.CALENDAR_DISPLAY_NAME,
            CalendarContract.Calendars.ACCOUNT_NAME, CalendarContract.Calendars.CALENDAR_COLOR, CalendarContract.Calendars.SYNC_EVENTS)
        val out = ArrayList<PhoneCalendar>()
        try {
            c.contentResolver.query(CalendarContract.Calendars.CONTENT_URI, cols, null, null, null)?.use { k ->
                while (k.moveToNext()) {
                    out.add(PhoneCalendar(k.getLong(0), k.getString(1) ?: "Calendar", k.getString(2) ?: "", k.getInt(3), k.getInt(4) != 0))
                }
            }
        } catch (_: Exception) {}
        return out.sortedBy { it.name.lowercase() }
    }

    /** The events of `ids` between `from` and `to` (seconds), each repeat on its own. */
    fun events(c: Context, ids: Collection<Long>, from: Double, to: Double, withNotes: Boolean = false): List<CalEvent> =
        rows(c, ids, from, to, withNotes).map { it.first }

    private fun rows(c: Context, ids: Collection<Long>, from: Double, to: Double, withNotes: Boolean): List<Pair<CalEvent, String>> {
        if (!granted(c) || ids.isEmpty()) return emptyList()
        val b = CalendarContract.Instances.CONTENT_URI.buildUpon()
        ContentUris.appendId(b, (from * 1000).toLong())
        ContentUris.appendId(b, (to * 1000).toLong())
        val cols = arrayOf(CalendarContract.Instances.TITLE, CalendarContract.Instances.EVENT_LOCATION, CalendarContract.Instances.BEGIN,
            CalendarContract.Instances.END, CalendarContract.Instances.ALL_DAY, CalendarContract.Instances.STATUS,
            CalendarContract.Instances.DESCRIPTION)
        val sel = "${CalendarContract.Instances.CALENDAR_ID} IN (${ids.joinToString(",") { "?" }})"
        val out = ArrayList<Pair<CalEvent, String>>()
        try {
            c.contentResolver.query(b.build(), cols, sel, ids.map { it.toString() }.toTypedArray(), "${CalendarContract.Instances.BEGIN} ASC")?.use { k ->
                while (k.moveToNext()) {
                    val status = if (k.isNull(5)) -1 else k.getInt(5)
                    val e = CalEvent(title = k.getString(0) ?: "", location = k.getString(1), start = k.getLong(2) / 1000.0, end = k.getLong(3) / 1000.0,
                        allDay = k.getInt(4) != 0, cancelled = status == CalendarContract.Events.STATUS_CANCELED)
                    out.add(e to if (withNotes) listOfNotNull(k.getString(6), e.location).joinToString(" ") else "")
                }
            }
        } catch (_: Exception) {}
        return out
    }

    /** The calendars that look like your timetable (by name and account, else by their events' notes and rooms). */
    fun schoolLike(c: Context, all: List<PhoneCalendar>, hints: SchoolHints, now: Double): Set<Long> = all.filter { cal ->
        SchoolHints.matches(cal.name, cal.account, {
            rows(c, listOf(cal.id), now - 7 * 86400, now + 14 * 86400, true).take(60).map { it.second }
        }, hints)
    }.map { it.id }.toSet()
}
