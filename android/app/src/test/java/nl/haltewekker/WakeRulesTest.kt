package nl.haltewekker

import nl.haltewekker.ride.Phase
import nl.haltewekker.ride.RideGPS
import nl.haltewekker.ride.WakeRules
import nl.haltewekker.ride.WakeRules.Action
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WakeRulesTest {
    @Test fun defaultsAreTheIOSOnes() {
        assertEquals(2.0, WakeRules.wakeKm(false), 0.0)
        assertEquals(5.0, WakeRules.wakeKm(true), 0.0)
        assertEquals(3.5, WakeRules.wakeKm(false, busKm = 3.5), 0.0)
    }

    @Test fun ringsWithinTheWakeDistance() {
        val wake = 2000.0
        assertEquals(Action.NONE, WakeRules.onFix(Phase.SLEEPING, 2400.0, 20.0, 300.0, wake))
        assertEquals(Action.RING, WakeRules.onFix(Phase.SLEEPING, 1990.0, 20.0, 300.0, wake))
        // a poor fix (a cell tower) never rings
        assertEquals(Action.NONE, WakeRules.onFix(Phase.SLEEPING, 1500.0, 300.0, 300.0, wake))
        // started this close to the stop: awake, no alarm
        assertEquals(Action.AWAKE_SILENTLY, WakeRules.onFix(Phase.SLEEPING, 1500.0, 20.0, 5.0, wake))
        // ringing: nothing more until it's stopped
        assertEquals(Action.NONE, WakeRules.onFix(Phase.ALARM, 100.0, 20.0, 600.0, wake))
        assertEquals(Action.NONE, WakeRules.onFix(Phase.SLEEPING, Double.NaN, 20.0, 600.0, wake))
        assertEquals(Action.NONE, WakeRules.onFix(Phase.SLEEPING, 100.0, -1.0, 600.0, wake))
    }

    @Test fun arrivesAt450m() {
        assertEquals(Action.NONE, WakeRules.onFix(Phase.AWAKE, 500.0, 20.0, 600.0, 2000.0))
        assertEquals(Action.ARRIVE, WakeRules.onFix(Phase.AWAKE, 440.0, 500.0, 600.0, 2000.0))
        assertEquals(Action.NONE, WakeRules.onFix(Phase.AWAKE, 440.0, 700.0, 600.0, 2000.0))
    }

    @Test fun headphonesOnly() {
        assertTrue(WakeRules.quiet(headphonesOnly = true, privateOutput = false))
        assertFalse(WakeRules.quiet(headphonesOnly = true, privateOutput = true))
        assertFalse(WakeRules.quiet(headphonesOnly = false, privateOutput = false))
    }

    @Test fun backupAlarmByTime() {
        val now = 1_000_000.0
        // a bus, 2 km: 200 s before arrival
        assertEquals(now + 1800 - 200, WakeRules.backupAt(now + 1800, false, 2000.0, now)!!, 0.0)
        // a train, 5 km: 200 s; at least 2 minutes
        assertEquals(now + 1800 - 200, WakeRules.backupAt(now + 1800, true, 5000.0, now)!!, 0.0)
        assertEquals(now + 1800 - 120, WakeRules.backupAt(now + 1800, true, 1000.0, now)!!, 0.0)
        assertNull(WakeRules.backupAt(now + 100, false, 2000.0, now))
        assertNull(WakeRules.backupAt(null, false, 2000.0, now))
        assertNull(WakeRules.backupAt(now + 1800, false, 2000.0, now, enabled = false))
    }

    @Test fun texts() {
        assertEquals("1.8 km", WakeRules.distanceText(1830.0))
        assertEquals("450 m", WakeRules.distanceText(447.0))
        assertEquals("Attention please. We are now approaching Breda station. Please get ready to leave the train.",
            WakeRules.announcement("Breda", isTrain = true, approach = true))
        assertEquals("Arriving at Veghel, Busstation. This is your stop. Please leave the bus here.",
            WakeRules.announcement("Veghel, Busstation", isTrain = false, approach = false))
    }

    @Test fun roughGPSOnlyFarAndConfirmed() {
        val base = RideGPS.Input(confirmed = true, metresToStop = 30_000.0, accuracy = 20.0, fixAge = 5.0, wakeMetres = 5000.0, isTrain = true)
        // 5 km + 8 min at 39 m/s = 23.72 km, +1 km to switch on
        assertTrue(RideGPS.far(base))
        assertFalse(RideGPS.far(base.copy(metresToStop = 24_000.0)))
        assertTrue(RideGPS.far(base.copy(metresToStop = 24_000.0, wasFar = true)))
        assertFalse(RideGPS.far(base.copy(confirmed = false)))
        assertFalse(RideGPS.far(base.copy(asleep = false)))
        assertFalse(RideGPS.far(base.copy(secondsToStop = 300.0)))
        assertFalse(RideGPS.far(base.copy(accuracy = 150.0)))
        assertEquals(25_000L, RideGPS.intervalMs(true))
    }
}
