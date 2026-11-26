package nl.haltewekker

import kotlinx.coroutines.runBlocking
import nl.haltewekker.data.DoorTrip
import nl.haltewekker.data.Ride
import nl.haltewekker.school.AlarmOp
import nl.haltewekker.school.Lesson
import nl.haltewekker.school.Planned
import nl.haltewekker.school.SchoolConfig
import nl.haltewekker.school.SchoolPlan
import nl.haltewekker.school.SchoolSkip
import nl.haltewekker.school.ScheduleSource
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The school alarm's plan: the trip, the alarm time, skipped days, what's planned again (iOS `SchoolSkipTests` and the plan). */
class SchoolPlanTest {
    private val now = 1_800_000_000.0
    private val h = 3600.0

    private fun ride(id: String, dep: Double, arr: Double, line: String = "306") =
        Ride(tripId = id, line = line, name = line, isTrain = false, departure = dep, scheduledDeparture = dep, arrival = arr,
            scheduledArrival = arr, fromStop = "A", fromId = "a", toStop = "B")

    private fun trip(id: String, start: Double, end: Double, rides: Int = 1): DoorTrip {
        val l = (0 until rides).map { ride("$id-$it", start + 300 + it * 600, end - 300 - (rides - 1 - it) * 600) }
        return DoorTrip(l, start, end)
    }

    private val cfg = SchoolConfig(on = true, earlyMinutes = 10, wakeMinutes = 60)

    @Test fun picksTheLatestTripThatStillGetsYouThereAndFewerChangesOnATie() {
        val be = now + 10 * h
        val a = trip("a", be - 2 * h, be - 30 * 60)
        val b = trip("b", be - 1 * h, be + 30)              // a minute's slack: in time
        val c = trip("c", be - 50 * 60, be + 5 * 60)         // too late
        val d = trip("d", be - 1 * h, be - 60, rides = 2)    // same start, a change more
        assertEquals("b", SchoolPlan.best(listOf(a, d, c, b), be, now)!!.first.tripId.substringBefore('-'))
        // a trip already gone doesn't count
        assertNull(SchoolPlan.best(listOf(trip("x", now - 600, be - 600)), be, now + 0))
    }

    @Test fun plansTheAlarmAnHourBeforeYouLeave() = runBlocking {
        val cls = now + 12 * h
        val classes = mapOf("2027-01-15" to Lesson("2027-01-15", "Design", "HA 2.14", cls))
        var asked = 0.0
        val r = SchoolPlan.plan(emptyList(), classes, cfg, emptySet(), now, force = false) { be -> asked = be; listOf(trip("t", cls - 2 * h, cls - 15 * 60)) }
        assertEquals(cls - 10 * 60, asked, 0.0)
        val p = r.week.single()
        assertEquals(cls - 2 * h, p.leave!!, 0.0)
        assertEquals(cls - 3 * h, p.alarm!!, 0.0)
        assertTrue(p.alarmSet)
        assertEquals(listOf(AlarmOp.Set("2027-01-15", cls - 3 * h, cls - 2 * h, cls, "Design")), r.ops)
        assertEquals(1, r.added.size)
        // planned a minute later with the same answer: due again only after 14 minutes, and then the alarm is kept
        val again = SchoolPlan.plan(r.week, classes, cfg, emptySet(), now + 60, force = false) { error("not due") }
        assertEquals(r.week, again.week)
        val later = SchoolPlan.plan(r.week, classes, cfg, emptySet(), now + 15 * 60, force = false) { listOf(trip("t", cls - 2 * h, cls - 15 * 60)) }
        assertTrue(later.ops.isEmpty())
        assertTrue(later.week.single().alarmSet)
    }

    @Test fun theBusesChangeTheAlarmMovesAndAClassGoneTakesItAway() = runBlocking {
        val cls = now + 12 * h
        val classes = mapOf("d1" to Lesson("d1", "Design", null, cls))
        val r = SchoolPlan.plan(emptyList(), classes, cfg, emptySet(), now, false) { listOf(trip("t", cls - 2 * h, cls - 15 * 60)) }
        val moved = SchoolPlan.plan(r.week, classes, cfg, emptySet(), now, force = true) { listOf(trip("u", cls - 2.5 * h, cls - 40 * 60)) }
        assertEquals(cls - 3.5 * h, moved.week.single().alarm!!, 0.0)
        assertTrue(moved.ops.single() is AlarmOp.Set)
        assertTrue(moved.added.isEmpty())                     // it was set already: moved, not new
        val gone = SchoolPlan.plan(moved.week, emptyMap(), cfg, emptySet(), now, false) { error("nothing to plan") }
        assertTrue(gone.week.isEmpty())
        assertEquals(listOf(AlarmOp.Cancel("d1")), gone.ops)
    }

    @Test fun noAnswerKeepsWhatItHadAndARangAlarmIsLeftAlone() = runBlocking {
        val cls = now + 12 * h
        val classes = mapOf("d1" to Lesson("d1", "Design", null, cls))
        val r = SchoolPlan.plan(emptyList(), classes, cfg, emptySet(), now, false) { listOf(trip("t", cls - 2 * h, cls - 15 * 60)) }
        val none = SchoolPlan.plan(r.week, classes, cfg, emptySet(), now, force = true) { emptyList() }
        assertEquals(r.week, none.week)
        val afterRing = r.week.single().alarm!! + 1
        val rang = SchoolPlan.plan(r.week, classes, cfg, emptySet(), afterRing, force = true) { error("rang: not planned") }
        assertEquals(r.week, rang.week)
        // a class within 20 minutes isn't planned any more
        val close = SchoolPlan.plan(emptyList(), mapOf("d2" to Lesson("d2", null, null, now + 600)), cfg, emptySet(), now, true) { error("too close") }
        assertTrue(close.week.isEmpty())
    }

    @Test fun skippedDayHasNoAlarmButKeepsItsTrip() = runBlocking {
        val cls = now + 12 * h
        val classes = mapOf("d1" to Lesson("d1", "Design", null, cls))
        val r = SchoolPlan.plan(emptyList(), classes, cfg, setOf("d1"), now, false) { listOf(trip("t", cls - 2 * h, cls - 15 * 60)) }
        val p = r.week.single()
        assertNull(p.alarm); assertFalse(p.alarmSet); assertEquals(cls - 2 * h, p.leave!!, 0.0)
        assertTrue(r.ops.isEmpty())
        // skipped after it was set: its alarm goes
        val set = SchoolPlan.plan(emptyList(), classes, cfg, emptySet(), now, false) { listOf(trip("t", cls - 2 * h, cls - 15 * 60)) }
        val off = SchoolPlan.plan(set.week, classes, cfg, setOf("d1"), now, true) { listOf(trip("t", cls - 2 * h, cls - 15 * 60)) }
        assertEquals(listOf(AlarmOp.Cancel("d1")), off.ops)
        assertNull(off.week.single().alarm)
    }

    @Test fun anAlarmTimeAlreadyPastIsShownNotSet() = runBlocking {
        val cls = now + 1.5 * h                     // leave in 30 min: the alarm (an hour before) has passed
        val r = SchoolPlan.plan(emptyList(), mapOf("d" to Lesson("d", null, null, cls)), cfg, emptySet(), now, false) { listOf(trip("t", now + 30 * 60, cls - 15 * 60)) }
        val p = r.week.single()
        assertEquals(now - 30 * 60, p.alarm!!, 0.0)
        assertFalse(p.alarmSet)
        assertTrue(r.ops.isEmpty())
        assertEquals("Class", p.title)
    }

    @Test fun skipRules() {
        assertEquals(SchoolSkip.Action.Clear, SchoolSkip.decide(now + h, "d", setOf("d"), now + h, true, now))
        assertEquals(SchoolSkip.Action.Keep, SchoolSkip.decide(now + h, "d", setOf("d"), null, false, now))
        assertEquals(SchoolSkip.Action.Keep, SchoolSkip.decide(now + h + 20, "d", emptySet(), now + h, true, now))
        assertEquals(SchoolSkip.Action.Set(now + h + 70, true), SchoolSkip.decide(now + h + 70, "d", emptySet(), now + h, true, now))
        assertEquals(SchoolSkip.Action.Set(now + 30, false), SchoolSkip.decide(now + 30, "d", emptySet(), null, false, now))
        assertEquals(now + h, SchoolSkip.restore(now + 2 * h, 60, now)!!, 0.0)
        assertNull(SchoolSkip.restore(now + h + 30, 60, now))
        assertNull(SchoolSkip.restore(null, 60, now))
        assertEquals(setOf("2026-11-19", "2026-11-20"), SchoolSkip.prune(setOf("2026-11-18", "2026-11-19", "2026-11-20"), "2026-11-19"))
    }

    @Test fun dueRules() {
        val cls = now + 12 * h
        val p = Planned(day = "d", title = "x", classStart = cls, beThere = cls - 600, checked = now)
        assertFalse(SchoolPlan.due(p, cls, cls - 600, now + 13 * 60, false))
        assertTrue(SchoolPlan.due(p, cls, cls - 600, now + 14 * 60, false))
        assertTrue(SchoolPlan.due(p, cls + 900, cls + 300, now + 60, false))      // the class moved
        val far = p.copy(classStart = now + 3 * 86400.0, beThere = now + 3 * 86400.0 - 600)
        assertFalse(SchoolPlan.due(far, far.classStart, far.beThere, now + 5 * h, false))
        assertTrue(SchoolPlan.due(far, far.classStart, far.beThere, now + 6 * h, false))
        assertEquals("Pick your school calendar.", SchoolPlan.note(ScheduleSource.CALENDARS, true, false, true))
        assertNull(SchoolPlan.note(ScheduleSource.MANUAL, false, false, false))
    }
}
