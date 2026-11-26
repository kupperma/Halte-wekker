package nl.haltewekker

import nl.haltewekker.ride.AlarmStop
import nl.haltewekker.ride.NoticeExpiry
import nl.haltewekker.ride.WristNotice
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** iOS `WristNoticeTests` (0.37.1) and `AlarmStopTests` (0.42.1). */
class WristNoticeTest {
    private val t0 = 1_800_000_000.0

    @Test fun wakeUpSaysTheStopAndHowSoonFirst() {
        val t = WristNotice.ring(true, "Breda", "2 min")
        assertEquals("Get off at Breda · 2 min", t.title)
        assertEquals("Wake up: get ready to get off.", t.body)
        assertEquals("Get off at Breda · 800 m", WristNotice.ring(true, "Breda", "800 m").title)
    }

    @Test fun atTheStop() {
        val t = WristNotice.ring(false, "Breda", "0 m")
        assertEquals("Get off now at Breda", t.title); assertEquals("This is your stop.", t.body)
    }

    @Test fun headsUpWhenInUse() {
        assertEquals(WristNotice.Lines("Get off at Veghel, Busstation · 3 min", "Get ready to get off."), WristNotice.ring(true, "Veghel, Busstation", "3 min", inUse = true))
        assertEquals("This is your stop.", WristNotice.ring(false, "Uden", "", inUse = true).body)
    }

    @Test fun theRepeatSaysItStillRings() {
        assertEquals("Still ringing: wake up and get ready to get off.", WristNotice.ring(true, "Breda", "2 min", again = true).body)
        assertEquals("Still ringing: this is your stop.", WristNotice.ring(false, "Breda", "", again = true).body)
        assertEquals("Get off at Breda · 2 min", WristNotice.ring(true, "Breda", "2 min", again = true).title)
    }

    @Test fun longAndMissingStopNames() {
        assertEquals("your stop", WristNotice.stop(null))
        assertEquals("your stop", WristNotice.stop("   "))
        assertEquals("Breda", WristNotice.stop(" Breda "))
        assertEquals("Amsterdam Centraal", WristNotice.stop("Amsterdam Centraal"))
        val long = WristNotice.stop("'s-Hertogenbosch, Centraal Station perron")
        assertEquals(WristNotice.MAX_STOP, long.length)
        assertTrue(long.endsWith("…")); assertTrue(long.startsWith("'s-Hertogenbosch"))
        assertEquals("Get off at your stop · 1 min", WristNotice.ring(true, null, "1 min").title)
    }

    @Test fun minutesRoundUpAndAreAtLeastOne() {
        assertEquals("1 min", WristNotice.minutes(0.0)); assertEquals("2 min", WristNotice.minutes(61.0))
        assertEquals("2 min", WristNotice.minutes(120.0)); assertEquals("1 min", WristNotice.minutes(-5.0))
    }

    @Test fun arrivedAndBackup() {
        assertEquals(WristNotice.Lines("You’re at Breda", "Get off here: your trip is done."), WristNotice.arrived("Breda", null, true))
        assertEquals("Get off here.", WristNotice.arrived("Breda", null, false).body)
        assertEquals("Change to bus 305 at 07:41", WristNotice.arrived("Breda", "Change to bus 305 at 07:41", false).body)
        assertEquals("Get off at Breda soon", WristNotice.backup("Breda").title)
    }

    @Test fun titlesStillReadAsGo() {
        for (t in listOf(WristNotice.ring(true, "Breda", "2 min"), WristNotice.ring(false, "Breda", ""), WristNotice.backup("Breda")))
            assertTrue(t.title, t.title.lowercase().contains("get off"))
    }

    @Test fun schoolWakeTitles() {
        assertEquals("⏰ Time to get up", WristNotice.wakeTitle("Time to get up", 0))
        assertEquals("⏰ Time to get up (again)", WristNotice.wakeTitle("Time to get up", 2))
    }

    @Test fun repeatAfterThirtySecondsWhileStillRinging() {
        assertEquals(30.0, WristNotice.AGAIN_AFTER, 0.0)
        assertFalse(WristNotice.againDue(t0, t0 + 29, true, false))
        assertTrue(WristNotice.againDue(t0, t0 + 30, true, false))
        assertTrue(WristNotice.againDue(t0, t0 + 31, true, false))
        assertFalse(WristNotice.againDue(t0, t0 + 30, false, false))
        assertFalse(WristNotice.againDue(t0, t0 + 30, true, true))
        assertFalse(WristNotice.againDue(t0, t0 + 600, true, true))
    }

    @Test fun howSoonAtTheRepeat() {
        assertEquals(120.0, WristNotice.secsAtAgain(150.0)!!, 0.0)
        assertEquals(0.0, WristNotice.secsAtAgain(10.0)!!, 0.0)
        assertNull(WristNotice.secsAtAgain(null))
        assertEquals("2 min", WristNotice.minutes(WristNotice.secsAtAgain(150.0)!!))
    }

    @Test fun repeatIsNotSweptAway() {
        assertNull(NoticeExpiry.minutes(WristNotice.AGAIN_ID)); assertNull(NoticeExpiry.minutes(WristNotice.ALARM_ID))
        assertNotEquals(WristNotice.AGAIN_ID, WristNotice.ALARM_ID)
    }

    @Test fun groupedPerTrip() {
        assertEquals("trip-1800000000", WristNotice.thread(t0))
        assertEquals("trip", WristNotice.thread(null))
        assertNotEquals(WristNotice.thread(t0), WristNotice.thread(t0 + 3600))
        assertEquals("wake-2026-11-20", WristNotice.wakeThread("2026-11-20"))
    }

    @Test fun ringingOnesOnTop() {
        assertEquals(1.0, WristNotice.relevance(WristNotice.Kind.ALARM), 0.0)
        assertEquals(1.0, WristNotice.relevance(WristNotice.Kind.AGAIN), 0.0)
        assertTrue(WristNotice.relevance(WristNotice.Kind.HEADS_UP) > WristNotice.relevance(WristNotice.Kind.ARRIVED))
        for (k in WristNotice.Kind.values()) assertTrue(WristNotice.relevance(k) in 0.0..1.0)
    }

    @Test fun stopButtonIsTheOldStopPath() {
        assertEquals("STOP", WristNotice.STOP_ACTION); assertEquals("Stop alarm", WristNotice.STOP_TITLE)
        assertEquals("ALARM", WristNotice.ALARM_CATEGORY); assertEquals("WAKE", WristNotice.WAKE_CATEGORY)
    }

    // AlarmStopTests (0.42.1)
    private val open = "OPEN"
    private val dismiss = "DISMISS"

    @Test fun alarmStop_actionsAreToldApart() {
        assertEquals(AlarmStop.Action.STOP, AlarmStop.action(WristNotice.STOP_ACTION, open, dismiss))
        assertEquals(AlarmStop.Action.OPEN, AlarmStop.action(open, open, dismiss))
        assertEquals(AlarmStop.Action.DISMISS, AlarmStop.action(dismiss, open, dismiss))
        assertEquals(AlarmStop.Action.OTHER, AlarmStop.action("STILL_YES", open, dismiss))
    }

    @Test fun alarmStop_stopOnTheRingingAlarmStopsTheTrip() {
        for (id in listOf(WristNotice.ALARM_ID, WristNotice.AGAIN_ID)) for (a in listOf(AlarmStop.Action.STOP, AlarmStop.Action.OPEN, AlarmStop.Action.DISMISS)) {
            val p = AlarmStop.plan(id, a)
            assertTrue(p.stopTrip); assertTrue(p.wakeRepeats.isEmpty()); assertFalse(p.stopWake)
        }
    }

    @Test fun alarmStop_otherTripNotices() {
        for (id in listOf("backup", "heads-up-true", "arrived-1800000000")) {
            assertTrue(AlarmStop.plan(id, AlarmStop.Action.STOP).stopTrip)
            assertFalse(AlarmStop.plan(id, AlarmStop.Action.OPEN).stopTrip)
            assertFalse(AlarmStop.plan(id, AlarmStop.Action.DISMISS).stopTrip)
        }
        assertTrue(AlarmStop.plan("still-on", AlarmStop.Action.OTHER).none)
        assertTrue(AlarmStop.plan("friends-chat-abc", AlarmStop.Action.OPEN).none)
        assertFalse(AlarmStop.plan(WristNotice.ALARM_ID, AlarmStop.Action.OPEN).none)
    }

    @Test fun alarmStop_schoolWakeUpTakesTheDaysRepeatsAway() {
        val ids = listOf("wake-2026-11-27-0", "wake-2026-11-27-1", "wake-2026-11-27-2")
        val stop = AlarmStop.plan("wake-2026-11-27-1", AlarmStop.Action.STOP)
        assertEquals(ids, stop.wakeRepeats); assertTrue(stop.stopWake); assertFalse(stop.stopTrip)
        for (a in listOf(AlarmStop.Action.OPEN, AlarmStop.Action.DISMISS)) {
            val p = AlarmStop.plan("wake-2026-11-27-0", a)
            assertEquals(ids, p.wakeRepeats); assertFalse(p.stopWake); assertFalse(p.stopTrip)
        }
        assertEquals(listOf("wake-test-0", "wake-test-1", "wake-test-2"), AlarmStop.wakeRepeats("wake-test-0"))
        assertEquals(emptyList<String>(), AlarmStop.wakeRepeats("alarm"))
        assertEquals(emptyList<String>(), AlarmStop.wakeRepeats("wake-0"))
        assertEquals(emptyList<String>(), AlarmStop.wakeRepeats("wake-"))
        assertTrue(AlarmStop.tripDelivered.containsAll(listOf(WristNotice.ALARM_ID, WristNotice.AGAIN_ID, "backup")))
    }
}
