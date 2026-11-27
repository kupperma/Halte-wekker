package nl.haltewekker

import nl.haltewekker.profile.Settings
import nl.haltewekker.profile.migrated
import nl.haltewekker.ride.WakeRules
import nl.haltewekker.ride.WakeRules.RingKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** (0.10.5, iOS 0.42.8) Without headphones the alarm stays vibration only; every ring rings on the lock screen. */
class OutLoudOffTest {
    @Test fun outLoudLaterIsOffForEveryoneOnce() {
        assertFalse(Settings().outLoudLater)
        val before = Settings().copy(outLoudLater = true, outLoudLaterOffOnce = false)
        val after = before.migrated()
        assertFalse(after.outLoudLater)
        assertTrue(after.outLoudLaterOffOnce)
        val again = after.copy(outLoudLater = true)
        assertEquals(again, again.migrated())
    }

    @Test fun noHeadphonesNeverGoesLoudByItself() {
        assertFalse(WakeRules.loudLater(quiet = true, outLoudLater = false))
        assertTrue(WakeRules.loudLater(quiet = true, outLoudLater = true))
        assertFalse("with headphones it plays as it always did", WakeRules.loudLater(quiet = false, outLoudLater = true))
    }

    @Test fun everyRingKindRingsOnTheLockScreen() {
        for (k in listOf(RingKind.ALARM, RingKind.HEADPHONES_QUIET, RingKind.PHONE_IN_USE, RingKind.BY_TIME, RingKind.RECKONED, RingKind.BACKUP, RingKind.AGAIN))
            assertTrue(k.name, WakeRules.lockRinging(k))
        for (k in listOf(RingKind.SHORT_NOTICE, RingKind.GET_READY, RingKind.ARRIVED)) assertFalse(k.name, WakeRules.lockRinging(k))
    }
}
