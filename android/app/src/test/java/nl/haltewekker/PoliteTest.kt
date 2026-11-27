package nl.haltewekker

import kotlinx.coroutines.runBlocking
import nl.haltewekker.data.Polite
import nl.haltewekker.data.Polite.Lane
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** (0.10.0) iOS `Net.Polite`'s rules: a few at a time, urgent first, a pause after a 429 that doubles. */
class PoliteTest {
    private var now = 1000.0
    private fun polite() = Polite(clock = { now })

    @Test fun pauseAfter429Doubles() {
        val p = polite()
        assertNull(p.coolingLeft)
        p.slowDown(null, p.sending())
        assertEquals(20.0, p.coolingLeft!!, 0.001)
        p.slowDown(null, p.sending())                       // sent during the pause: doubled
        assertEquals(40.0, p.coolingLeft!!, 0.001)
        val before = Polite.Sent(0, false)                  // on its way before the pause began: no longer
        p.slowDown(null, before)
        assertEquals(40.0, p.coolingLeft!!, 0.001)
        now += 41
        assertNull(p.coolingLeft)
        p.answered()
        p.slowDown("7", p.sending())                        // an answer came: from the start, as Retry-After asks
        assertEquals(7.0, p.coolingLeft!!, 0.001)
        assertEquals(120.0, p.asked("900")!!, 0.0); assertEquals(5.0, p.asked("1")!!, 0.0); assertNull(p.asked("Wed, 21 Oct"))
    }

    @Test fun backgroundRefusedWhileCooling() = runBlocking {
        val p = polite()
        p.slowDown(null, p.sending())
        var refused = false
        try { p.enter(Lane.BACKGROUND, 1.0) } catch (_: Polite.Refused) { refused = true }
        assertTrue(refused)
        // urgent ones one at a time
        assertTrue(p.enter(Lane.URGENT, 1.0))
        assertFalse(p.enter(Lane.URGENT, 0.05))
        p.exit(Lane.URGENT)
        assertTrue(p.enter(Lane.URGENT, 1.0))
    }

    @Test fun fourAtATimeTwoInBackground() = runBlocking {
        val p = polite()
        assertTrue(p.enter(Lane.BACKGROUND, 1.0)); assertTrue(p.enter(Lane.BACKGROUND, 1.0))
        assertFalse(p.enter(Lane.BACKGROUND, 0.05))          // two background at most
        assertTrue(p.enter(Lane.URGENT, 1.0)); assertTrue(p.enter(Lane.URGENT, 1.0))
        assertFalse(p.enter(Lane.URGENT, 0.05))              // four in all
        assertEquals(2 to 2, p.inFlight)
        p.exit(Lane.BACKGROUND)
        assertTrue(p.enter(Lane.URGENT, 1.0))
        assertEquals(3 to 1, p.inFlight)
    }
}
