package nl.haltewekker

import kotlinx.coroutines.runBlocking
import nl.haltewekker.data.DoorTrip
import nl.haltewekker.data.Ride
import nl.haltewekker.school.AlarmOp
import nl.haltewekker.school.Lesson
import nl.haltewekker.school.OnTheWay
import nl.haltewekker.school.OnTheWay.Decision
import nl.haltewekker.school.OnTheWay.Live
import nl.haltewekker.school.OnTheWay.Reason
import nl.haltewekker.school.OnTheWay.Seen
import nl.haltewekker.school.Planned
import nl.haltewekker.school.SchoolArrive
import nl.haltewekker.school.SchoolConfig
import nl.haltewekker.school.SchoolPlan
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

/** iOS 0.42.6 `SchoolArriveTests`, the same vectors (minutes after 2026-11-27 00:00 UTC, clock in UTC); and the plan with a changed day. */
class SchoolArriveTest {
    private val base = 1_795_737_600.0
    private val day = "2026-11-27"
    private fun t(m: Double) = base + m * 60
    private fun hm(h: Int, m: Int) = t(h * 60.0 + m)
    private val fmt = DateTimeFormatter.ofPattern("HH:mm").withZone(ZoneOffset.UTC)
    private val clock: (Double) -> String = { fmt.format(Instant.ofEpochSecond(it.toLong())) }

    // MARK: be there at

    @Test fun beThereIsTheTimetablesUnlessChanged() {
        val cls = hm(11, 0)
        assertEquals(hm(10, 50), SchoolArrive.timetable(cls, 10), 0.0)
        assertEquals(hm(10, 50), SchoolArrive.beThere(cls, 10, null), 0.0)
        assertEquals(hm(9, 0), SchoolArrive.beThere(cls, 10, hm(9, 0)), 0.0)
    }

    @Test fun quickChoicesFromTheTimetable() {
        val tt = hm(10, 50)
        assertEquals(hm(9, 50), SchoolArrive.quick(SchoolArrive.Quick.HOUR_EARLIER, tt), 0.0)
        assertEquals(hm(8, 50), SchoolArrive.quick(SchoolArrive.Quick.TWO_HOURS_EARLIER, tt), 0.0)
        assertEquals(hm(11, 20), SchoolArrive.quick(SchoolArrive.Quick.HALF_HOUR_LATER, tt), 0.0)
        assertEquals(listOf("1 h earlier", "2 h earlier", "30 min later"), SchoolArrive.Quick.entries.map { it.title })
    }

    @Test fun normalizedWholeMinutesNotTheTimetablesOwnNotAnotherDay() {
        val tt = hm(10, 50); val cls = hm(11, 0)
        assertEquals(hm(9, 0), SchoolArrive.normalized(t(540.5), tt, cls)!!, 0.0)
        assertNull(SchoolArrive.normalized(hm(10, 50), tt, cls))
        assertNull(SchoolArrive.normalized(hm(23, 30), tt, cls))
        assertEquals(hm(22, 0), SchoolArrive.normalized(hm(22, 0), tt, cls)!!, 0.0)
    }

    @Test fun changesExpireAfterTheirDay() {
        val o = mapOf("2026-11-26" to hm(9, 0), "2026-11-27" to hm(9, 0), "2026-11-28" to hm(8, 0))
        assertEquals(setOf("2026-11-27", "2026-11-28"), SchoolArrive.prune(o, day).keys)
        assertEquals(emptySet<String>(), SchoolArrive.prune(o, "2026-11-29").keys)
    }

    @Test fun wordsAndTheAlarmsLabel() {
        assertEquals("Changed: be there 09:00 (class 11:00)", SchoolArrive.changedLine(hm(9, 0), hm(11, 0), clock))
        assertEquals("Time to get up" to "Leave 09:40 for your 11:00 class", SchoolArrive.alarmText(hm(9, 40), hm(11, 0), hm(10, 50), false, clock))
        assertEquals("Time to get up · be there 09:00" to "Leave 07:50 to be there 09:00 (class 11:00)",
            SchoolArrive.alarmText(hm(7, 50), hm(11, 0), hm(9, 0), true, clock))
    }

    @Test fun noAnswerAfterAChangeMovesTheOldTrip() {
        assertEquals(hm(7, 40), SchoolArrive.shiftedLeave(hm(9, 40), hm(10, 50), hm(8, 50)), 0.0)
        assertEquals(hm(10, 10), SchoolArrive.shiftedLeave(hm(9, 40), hm(10, 50), hm(11, 20)), 0.0)
    }

    // MARK: never ring when you're already going

    private fun decide(seen: Seen, live: Live = Live(), alarm: Double? = hm(8, 40), now: Double = hm(7, 30), d: String = day) =
        OnTheWay.decide(d, day, alarm, now, hm(3, 0), seen, live)

    @Test fun aNormalMorningRings() {
        assertEquals(Decision.Ring, decide(Seen(day)))
        assertEquals(Decision.Ring, decide(Seen(day), Live(homeMetres = 20.0, fixAt = hm(7, 29))))
    }

    @Test fun aTripToSchoolSkips() {
        val s = Seen(day, tripAt = hm(7, 12), schoolTripAt = hm(7, 12))
        assertEquals(Decision.Skip(Reason.Going(hm(7, 12))), decide(s, Live(running = true, runningToSchool = true)))
        assertEquals("already on the way (trip 07:12)", OnTheWay.words(Reason.Going(hm(7, 12)), clock))
        assertEquals("school alarm · skipped: already on the way (trip 07:12)", OnTheWay.logLine(Reason.Going(hm(7, 12)), clock))
        assertEquals(Decision.Skip(Reason.Going(hm(7, 12))), decide(s, Live(running = true, runningToSchool = true, homeMetres = 300.0, fixAt = hm(7, 29))))
        assertEquals(Decision.Ring, decide(s, Live(homeMetres = 200.0, fixAt = hm(7, 25))))
        assertEquals(Decision.Skip(Reason.Going(hm(7, 12))), decide(s))
    }

    @Test fun atSchoolSkips() {
        assertEquals(Decision.Skip(Reason.AtSchool(hm(7, 20))), decide(Seen(day, atSchool = hm(7, 20))))
        assertEquals("already at school (07:20)", OnTheWay.words(Reason.AtSchool(hm(7, 20)), clock))
    }

    @Test fun leftHomeWithARideSkips() {
        val s = Seen(day, tripAt = hm(6, 30), leftHome = hm(6, 25))
        assertEquals(Decision.Skip(Reason.Going(hm(6, 30))), decide(s))
        assertEquals(Decision.Skip(Reason.Going(hm(6, 30))), decide(s, Live(homeMetres = 100.0, fixAt = hm(6, 50))))
        assertEquals(Decision.Ring, decide(s, Live(homeMetres = 100.0, fixAt = hm(7, 28))))
        val far = Seen(day, tripAt = hm(6, 30))
        assertEquals(Decision.Skip(Reason.Going(hm(6, 30))), decide(far, Live(homeMetres = 2500.0, fixAt = hm(7, 26))))
        assertEquals(Decision.Ring, decide(far, Live(homeMetres = 600.0, fixAt = hm(7, 26))))
    }

    @Test fun movingAroundAtHomeNeverSkips() {
        assertEquals(Decision.Ring, decide(Seen(day, leftHome = hm(7, 0)), Live(homeMetres = 2000.0, fixAt = hm(7, 29))))
        assertEquals(Decision.Ring, decide(Seen(day, tripAt = hm(7, 0))))
    }

    @Test fun onlyThisMorningAndOnlyAnAlarmStillToRing() {
        assertEquals(Decision.Ring, decide(Seen(day, tripAt = hm(2, 0), schoolTripAt = hm(2, 0), leftHome = hm(1, 55))))
        assertEquals(Decision.Ring, decide(Seen(day, schoolTripAt = hm(7, 40))))
        val s = Seen(day, schoolTripAt = hm(7, 12))
        assertEquals(Decision.Ring, decide(s, alarm = hm(7, 0)))
        assertEquals(Decision.Ring, decide(s, alarm = null))
        assertEquals(Decision.Ring, decide(s, d = "2026-11-28"))
        assertEquals(Decision.Ring, decide(s.copy(day = "2026-11-26")))
    }

    @Test fun whereTheTripGoesAndBeingAtSchool() {
        assertTrue(OnTheWay.towardSchool(null, true))
        assertTrue(OnTheWay.towardSchool(1200.0, false))
        assertFalse(OnTheWay.towardSchool(1600.0, false))
        assertFalse(OnTheWay.towardSchool(null, false))
        assertTrue(OnTheWay.atSchool(350.0, hm(7, 28), hm(7, 30)))
        assertFalse(OnTheWay.atSchool(350.0, hm(7, 10), hm(7, 30)))
        assertFalse(OnTheWay.atSchool(450.0, hm(7, 28), hm(7, 30)))
        assertFalse(OnTheWay.atSchool(null, null, hm(7, 30)))
    }

    @Test fun aNewDayStartsANewRecord() {
        assertEquals(Seen(day), OnTheWay.fresh(Seen("2026-11-26", tripAt = hm(7, 0)), day))
        val k = Seen(day, tripAt = hm(7, 0))
        assertEquals(k, OnTheWay.fresh(k, day))
        assertEquals(Seen(day), OnTheWay.fresh(null, day))
        assertEquals(setOf("2026-11-27"), OnTheWay.prune(mapOf("2026-11-26" to "a", "2026-11-27" to "b"), day).keys)
    }

    // MARK: the plan with a changed day

    private fun ride(id: String, dep: Double, arr: Double) =
        Ride(tripId = id, line = "306", name = "306", isTrain = false, departure = dep, scheduledDeparture = dep, arrival = arr,
            scheduledArrival = arr, fromStop = "A", fromId = "a", toStop = "B")

    private fun trip(id: String, start: Double, end: Double) = DoorTrip(listOf(ride(id, start + 300, end - 300)), start, end)

    private val cfg = SchoolConfig(on = true, earlyMinutes = 10, wakeMinutes = 60)

    @Test fun aChangedDayIsPlannedForItsTimeAndSaysSo() = runBlocking {
        val now = hm(0, 30)
        val classes = mapOf(day to Lesson(day = day, title = "Design", room = null, start = hm(11, 0)))
        val asked = ArrayList<Double>()
        val r = SchoolPlan.plan(emptyList(), classes, cfg, emptySet(), now, force = true, arrive = mapOf(day to hm(9, 0))) { be ->
            asked.add(be); listOf(trip("a", be - 70 * 60, be - 5 * 60))
        }
        assertEquals(listOf(hm(9, 0)), asked)
        val p = r.week.single()
        assertEquals(hm(9, 0), p.beThere, 0.0)
        assertEquals(hm(7, 50), p.leave!!, 0.0)
        assertEquals(hm(6, 50), p.alarm!!, 0.0)
        val set = r.ops.single() as AlarmOp.Set
        assertEquals(hm(6, 50), set.at, 0.0)
        assertEquals(hm(9, 0).toLong().toString(), p.label)
        // as the timetable says: the be-there time, and words as before
        val n = SchoolPlan.plan(emptyList(), classes, cfg, emptySet(), now, force = true) { be -> listOf(trip("a", be - 70 * 60, be - 5 * 60)) }
        assertEquals(hm(10, 50), n.week.single().beThere, 0.0)
        assertEquals("", n.week.single().label)
        // back to the timetable with the alarm on the same minute: set again (its words change) while it's ahead
        val back = SchoolPlan.plan(r.week, classes, cfg, emptySet(), now, force = true) { listOf(trip("a", hm(9, 0) - 70 * 60, hm(9, 0) - 5 * 60)) }
        assertTrue(back.ops.single() is AlarmOp.Set)
        assertEquals("", back.week.single().label)
        // kept as it is when nothing changed
        val same = SchoolPlan.plan(back.week, classes, cfg, emptySet(), now, force = true) { listOf(trip("a", hm(9, 0) - 70 * 60, hm(9, 0) - 5 * 60)) }
        assertTrue(same.ops.isEmpty())
    }

    @Test fun noAnswerRightAfterAChangeMovesTheAlarmWithIt() = runBlocking {
        val now = hm(0, 30)
        val classes = mapOf(day to Lesson(day = day, title = "Design", room = null, start = hm(11, 0)))
        val old = Planned(day = day, title = "Design", classStart = hm(11, 0), beThere = hm(10, 50), leave = hm(9, 40), arrive = hm(10, 45),
            alarm = hm(8, 40), alarmSet = true, checked = now - 60, label = "")
        val r = SchoolPlan.plan(listOf(old), classes, cfg, emptySet(), now, force = false, arrive = mapOf(day to hm(8, 50))) { emptyList() }
        val p = r.week.single()
        assertEquals(hm(7, 40), p.leave!!, 0.0)
        assertEquals(hm(6, 40), p.alarm!!, 0.0)
        assertEquals(0.0, p.checked, 0.0)                    // planned again at the next chance
        assertTrue(r.ops.any { it is AlarmOp.Set && it.at == hm(6, 40) })
        // nothing changed and no answer: kept as it was
        val k = SchoolPlan.plan(listOf(old), classes, cfg, emptySet(), now, force = true) { emptyList() }
        assertEquals(old, k.week.single())
        assertTrue(k.ops.isEmpty())
    }

    @Test fun aDayOffForBeingOnTheWayGetsNoAlarm() = runBlocking {
        val now = hm(6, 0)
        val classes = mapOf(day to Lesson(day = day, title = "Design", room = null, start = hm(11, 0)))
        val r = SchoolPlan.plan(emptyList(), classes, cfg, setOf(day), now, force = true) { be -> listOf(trip("a", be - 70 * 60, be - 5 * 60)) }
        assertNull(r.week.single().alarm)
        assertTrue(r.ops.isEmpty())
    }
}
