package nl.haltewekker

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import nl.haltewekker.school.CalEvent
import nl.haltewekker.school.ManualWeek
import nl.haltewekker.school.SchoolHints
import nl.haltewekker.school.Timetable
import nl.haltewekker.school.WeekDay
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneId

/** The timetable: your week (iOS `ManualWeekTests`), a calendar's first classes, the calendar hints. */
class SchoolTimetableTest {
    private val ams = ZoneId.of("Europe/Amsterdam")
    private fun t(y: Int, mo: Int, d: Int, h: Int, mi: Int) = ManualWeek.at(LocalDate.of(y, mo, d), h * 60 + mi, ams)

    @Test fun weekKeepsOneDayPerWeekdayAndDropsNonsense() {
        val w = ManualWeek(listOf(WeekDay(2, 510), WeekDay(2, 600), WeekDay(0, 500), WeekDay(8, 500), WeekDay(3, 1440), WeekDay(4, -1), WeekDay(6, 480)))
        assertEquals(listOf(2, 6), w.days.map { it.weekday })
        assertEquals(600, w.minutes(2))           // the last given wins
        assertNull(w.minutes(3))
    }

    @Test fun endMustBeAfterTheStartAndTitlesAreCut() {
        val w = ManualWeek(listOf(WeekDay(2, 510, end = 500), WeekDay(3, 510, end = 900, title = "  Design \n lab  "), WeekDay(4, 510, title = "x".repeat(60))))
        assertNull(w.end(2))
        assertEquals(900, w.end(3))
        assertEquals("Design lab", w.days[1].shownTitle)
        assertEquals(ManualWeek.MAX_TITLE, w.title(4)!!.length)
        assertNull(w.setEnd(5, 900).end(5))      // no school that day: ignored
        assertEquals(930, w.setEnd(2, 930).end(2))
        assertNull(w.setTitle(2, "").title(2))
    }

    @Test fun setKeepsEndAndTitle() {
        val w = ManualWeek(listOf(WeekDay(2, 510, 900, "Lectures")))
        val moved = w.set(2, 540)
        assertEquals(540, moved.minutes(2)); assertEquals(900, moved.end(2)); assertEquals("Lectures", moved.title(2))
        assertTrue(moved.set(2, null).isEmpty)
    }

    @Test fun lessonsFromTodaySkipThePastAndKeepTheClockAcrossSummerTime() {
        // Thursday 2026-11-19 at 09:00: today's 08:30 has gone, Friday's and Monday's count
        val now = t(2026, 11, 19, 9, 0)
        val l = ManualWeek.workdays.lessons(now, 8, ams)
        assertEquals(listOf("2026-11-20", "2026-11-23", "2026-11-24", "2026-11-25", "2026-11-26"), l.map { it.day })
        assertEquals(t(2026, 11, 20, 8, 30), l[0].start, 0.0)
        // across the change to winter time (Sunday 2026-10-25): Monday is still 08:30 local
        val before = t(2026, 10, 23, 12, 0)
        val mon = ManualWeek.workdays.lessons(before, 4, ams).first { it.day == "2026-10-26" }
        assertEquals(t(2026, 10, 26, 8, 30), mon.start, 0.0)
        assertEquals(mon.start - t(2026, 10, 23, 8, 30), 3 * 86400.0 + 3600, 0.0)
    }

    @Test fun weekdaysAreTheIOSNumbers() {
        assertEquals(1, ManualWeek.weekdayOf(LocalDate.of(2026, 11, 22)))   // Sunday
        assertEquals(2, ManualWeek.weekdayOf(LocalDate.of(2026, 11, 23)))   // Monday
        assertEquals(7, ManualWeek.weekdayOf(LocalDate.of(2026, 11, 21)))   // Saturday
    }

    @Test fun weekWords() {
        assertEquals("Mon–Fri 08:30", ManualWeek.words(ManualWeek.workdays))
        assertEquals("Mon 08:30 · Wed 10:15", ManualWeek.words(ManualWeek(listOf(WeekDay(2, 510), WeekDay(4, 615)))))
        assertEquals("Mon–Fri 08:30–15:00", ManualWeek.words(ManualWeek((2..6).map { WeekDay(it, 510, 900) })))
        assertEquals("No days yet", ManualWeek.words(ManualWeek()))
    }

    @Test fun weekRoundTripsAsJsonAndReadsAnOldOne() {
        val json = Json { ignoreUnknownKeys = true }
        val w = ManualWeek(listOf(WeekDay(2, 510, 900, "Design"), WeekDay(5, 600)))
        assertEquals(w.days, json.decodeFromString<ManualWeek>(json.encodeToString(w)).days)
        // an iOS 0.23 week: no end, no title; a broken day is left out
        val old = json.decodeFromString<ManualWeek>("""{"days":[{"weekday":2,"minutes":510},{"weekday":9,"minutes":1}]}""")
        assertEquals(listOf(WeekDay(2, 510)), old.days)
    }

    @Test fun firstClassOfEachDayFromTheCalendar() {
        val ev = listOf(
            CalEvent("Statistics", "HA 2.14", t(2026, 11, 20, 10, 45), t(2026, 11, 20, 12, 30)),
            CalEvent("Design", "Room 1", t(2026, 11, 20, 8, 45), t(2026, 11, 20, 10, 30)),
            CalEvent("Study day", null, t(2026, 11, 23, 0, 0), t(2026, 11, 24, 0, 0), allDay = true),
            CalEvent("Lecture CANCELLED", null, t(2026, 11, 23, 8, 30), t(2026, 11, 23, 10, 0)),
            CalEvent("Lab", null, t(2026, 11, 23, 13, 0), t(2026, 11, 23, 15, 0)),
            CalEvent("Gone", null, t(2026, 11, 24, 8, 30), t(2026, 11, 24, 10, 0), cancelled = true),
            CalEvent("Vervalt: werkcollege", null, t(2026, 11, 25, 8, 30), t(2026, 11, 25, 10, 0)),
        )
        val f = Timetable.firstClasses(ev, ams)
        assertEquals(setOf("2026-11-20", "2026-11-23"), f.keys)
        assertEquals("Design", f["2026-11-20"]!!.title); assertEquals("Room 1", f["2026-11-20"]!!.room)
        assertEquals("Lab", f["2026-11-23"]!!.title)
        assertEquals(t(2026, 11, 20, 12, 30), Timetable.classesEnd(ev, "2026-11-20", ams)!!, 0.0)
        // a class just after midnight UTC is still the Amsterdam day it's on
        val late = Timetable.firstClasses(listOf(CalEvent("Night", null, t(2026, 11, 21, 0, 30), t(2026, 11, 21, 1, 0))), ams)
        assertEquals(setOf("2026-11-21"), late.keys)
    }

    @Test fun weekLessonsAreNamedClassUnlessTitled() {
        val now = t(2026, 11, 19, 9, 0)
        val w = ManualWeek(listOf(WeekDay(6, 510, title = "Design")))
        val f = Timetable.fromWeek(w, now, 8, ams)
        assertEquals("Design", f["2026-11-20"]!!.title)
        assertEquals("Class", Timetable.fromWeek(ManualWeek.workdays, now, 8, ams)["2026-11-20"]!!.title)
    }

    @Test fun calendarHints() {
        val h = SchoolHints.make(listOf("BUas", "Breda University of Applied Sciences", "HvA"))
        assertTrue("buas" in h.names)
        assertFalse("hva" in h.names)                       // too short: would match too much
        assertTrue(SchoolHints.matches("Rooster", "me@example.org", { error("not read") }, h))
        assertTrue(SchoolHints.matches("My calendar", "Breda University of Applied Sciences", { error("not read") }, h))
        assertTrue(SchoolHints.matches("Imported", "local", { listOf("https://cloud.timeedit.net/buas/web") }, h))
        assertFalse(SchoolHints.matches("Birthdays", "local", { listOf("cake") }, h))
        assertEquals("hogeschool inholland", SchoolHints.fold(" Hogeschool Inhölland "))
    }
}
