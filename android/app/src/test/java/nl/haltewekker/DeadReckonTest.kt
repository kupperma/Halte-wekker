package nl.haltewekker

import nl.haltewekker.ride.DeadReckon
import nl.haltewekker.ride.WakeBy
import nl.haltewekker.ride.WakeRule
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** iOS `DeadReckonTests` (0.34): following the ride in tunnels and dead zones. */
class DeadReckonTest {
    private val t = 1_800_000_000.0

    @Test fun neededOnceTheGoodFixesStop() {
        assertFalse(DeadReckon.needed(t - 10, t))
        assertTrue(DeadReckon.needed(t - 16, t))
        assertFalse(DeadReckon.needed(null, t))
        assertFalse(DeadReckon.needed(t - 3600, t))
    }

    @Test fun goodFix() {
        assertTrue(DeadReckon.good(65.0)); assertFalse(DeadReckon.good(120.0)); assertFalse(DeadReckon.good(-1.0))
    }

    @Test fun onAtItsPaceNeverPastYourStop() {
        val e = DeadReckon.along(1000.0, t, t + 30, 20.0, null, null, 5000.0)
        assertEquals(1600.0, e.metres, 0.1); assertEquals(DeadReckon.Source.PACE, e.source)
        assertEquals(1200.0, DeadReckon.along(1000.0, t, t + 30, 20.0, null, null, 1200.0).metres, 0.0)
        assertEquals(10 * DeadReckon.MAX_FOR, DeadReckon.along(0.0, t, t + 7200, 10.0, null, null, 1e9).metres, 0.1)
        assertEquals(1000.0, DeadReckon.along(1000.0, t, t + 30, null, null, null, 5000.0).metres, 0.0)
    }

    @Test fun itsOwnGPSThenItsTimesComeFirst() {
        val gps = DeadReckon.along(1000.0, t, t + 30, 20.0, 1450.0, 1700.0, 5000.0)
        assertEquals(1450.0, gps.metres, 0.0); assertEquals(DeadReckon.Source.GPS, gps.source)
        val times = DeadReckon.along(1000.0, t, t + 30, 20.0, null, 1700.0, 5000.0)
        assertEquals(1700.0, times.metres, 0.0); assertEquals(DeadReckon.Source.TIMES, times.source)
        assertEquals(1000.0, DeadReckon.along(1000.0, t, t + 30, 20.0, 800.0, null, 5000.0).metres, 0.0)
        assertEquals(DeadReckon.Source.PACE, DeadReckon.along(1000.0, t, t + 30, 20.0, null, 9000.0, 20000.0, isTrain = true).source)
    }

    @Test fun pace() {
        assertEquals(20.0, DeadReckon.pace(3000.0, t + 150, t, 8.0, true) ?: 0.0, 0.01)
        assertEquals(8.0, DeadReckon.pace(3000.0, t - 5, t, 8.0, true)!!, 0.0)
        assertNull(DeadReckon.pace(3000.0, null, t, null, false))
        assertEquals(WakeRule.BUS_TOP, DeadReckon.pace(30000.0, t + 100, t, null, false)!!, 0.0)
    }

    @Test fun ringsOnADeadReckonedPlaceOnlyByTime() {
        assertFalse(DeadReckon.mayRing(WakeRule.Fire.Distance, true))
        assertTrue(DeadReckon.mayRing(WakeRule.Fire.Time(3, WakeRule.Source.LIVE, 170.0), true))
        assertTrue(DeadReckon.mayRing(WakeRule.Fire.Distance, false))
        assertFalse(DeadReckon.mayRing(null, true))
    }

    @Test fun wakeRuleOnTheEstimate() {
        val live = WakeRule.Input(WakeBy.TIME, 3, true, 4000.0, 4200.0, 5000.0, t + 150, 30.0, 25.0, 20000.0, t)
        assertTrue(DeadReckon.mayRing(DeadReckon.decide(live), true))
        val far = live.copy(liveArrival = t + 600, speed = 5.0)
        assertFalse(DeadReckon.mayRing(DeadReckon.decide(far), true))
        // set to by distance, the reckoned place still only rings by time
        assertTrue(DeadReckon.decide(live.copy(by = WakeBy.DISTANCE)) is WakeRule.Fire.Time)
    }
}
