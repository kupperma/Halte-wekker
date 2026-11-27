package nl.haltewekker

import nl.haltewekker.profile.Settings
import nl.haltewekker.profile.migrated
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** (0.10.1) "Did you check out?" is off for everyone: new installs, and an install that had it on, once. */
class CheckOutOffTest {
    @Test fun offByDefaultAndOnceForEveryone() {
        assertFalse(Settings().checkOut)
        // an install from before (it was on): off, once
        val before = Settings().copy(checkOut = true, checkOutOffOnce = false)
        val after = before.migrated()
        assertFalse(after.checkOut)
        assertTrue(after.checkOutOffOnce)
        // turned on again after that: it stays on
        val again = after.copy(checkOut = true)
        assertEquals(again, again.migrated())
        assertTrue(again.migrated().checkOut)
    }
}
