package nl.haltewekker

import nl.haltewekker.auto.AutoRules
import nl.haltewekker.auto.TripResume
import nl.haltewekker.core.GeoPoint
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Auto-start and auto-home (iOS `RoleRegionsTests` off the corridor, `RegionLook`, `TripResumeTests`). */
class AutoRulesTest {
    private val home = GeoPoint(51.6167, 5.5486)
    private val school = GeoPoint(51.5853, 4.7929)
    private val stopA = GeoPoint(51.6170, 5.5490)
    private val stopAOther = GeoPoint(51.6171, 5.5492)   // the other side of the road (≈ 20 m)
    private val stopB = GeoPoint(51.6200, 5.5550)

    @Test fun regionsForAutoStartAndAutoHome() {
        val r = AutoRules.wanted(home, school, listOf(stopA, stopAOther, stopB), autoStart = true, autoHome = true)
        assertEquals(listOf("school", "home.0", "home.1"), r.map { it.id })
        assertTrue(r[0].entry && r[0].exit)
        assertTrue(r.drop(1).all { it.exit && !it.entry && it.radius == AutoRules.HOME_RADIUS })
        // auto-home only: School's entry, no home stops
        val h = AutoRules.wanted(home, school, listOf(stopA), autoStart = false, autoHome = true)
        assertEquals(1, h.size); assertTrue(h[0].entry); assertFalse(h[0].exit)
        // no stops: Home itself
        assertEquals(listOf("school", "home"), AutoRules.wanted(home, school, emptyList(), true, false).map { it.id })
        assertTrue(AutoRules.wanted(home, school, listOf(stopA), false, false).isEmpty())
    }

    @Test fun stopsMergeAndAtMostThree() {
        val many = (0 until 6).map { GeoPoint(51.60 + it * 0.01, 5.5) }
        assertEquals(3, AutoRules.merged(many).size)
        assertEquals(1, AutoRules.merged(listOf(stopA, stopAOther)).size)
        assertEquals(0, AutoRules.merged(listOf(GeoPoint(Double.NaN, 5.0))).size)
    }

    @Test fun roles() {
        assertEquals(AutoRules.Role.SCHOOL, AutoRules.role("school"))
        assertEquals(AutoRules.Role.HOME, AutoRules.role("home"))
        assertEquals(AutoRules.Role.HOME, AutoRules.role("home.2"))
        assertNull(AutoRules.role("homework"))
        val regions = AutoRules.wanted(home, school, listOf(stopA), true, true)
        assertEquals("home.0", AutoRules.regionAt(GeoPoint(51.6190, 5.5490), regions))   // ~220 m away
        assertNull(AutoRules.regionAt(GeoPoint(51.64, 5.60), regions))
    }

    @Test fun walkingAwayFromTheBusYouGotOffDoesntLook() {
        val now = 1_800_000_000.0
        assertTrue(AutoRules.skip("home.0", "home.0", now - 300, 1.2, now))
        assertFalse(AutoRules.skip("home.0", "home.0", now - 300, 9.0, now))     // at vehicle speed: you're on one
        assertFalse(AutoRules.skip("home.0", "home.0", now - 21 * 60, null, now))
        assertFalse(AutoRules.skip("home.0", "school", now - 300, null, now))
        assertFalse(AutoRules.skip("home.0", null, null, null, now))
    }

    @Test fun mayStartAndBlocked() {
        assertTrue(AutoRules.mayStart("t1", idle = true, running = null, blocked = emptySet()))
        assertFalse(AutoRules.mayStart("t1", idle = false, running = null, blocked = emptySet()))
        assertFalse(AutoRules.mayStart("t1", idle = true, running = "t1", blocked = emptySet()))
        assertFalse(AutoRules.mayStart("t1", idle = true, running = null, blocked = setOf("t1")))
        val now = 1_800_000_000.0
        assertEquals(setOf("b"), AutoRules.prune(mapOf("a" to now - 3 * 3600, "b" to now - 600), now).keys)
    }

    @Test fun tripResume() {
        assertEquals(1, TripResume.leg(atChange = true, finished = false, index = 0, count = 2))
        assertNull(TripResume.leg(atChange = true, finished = false, index = 1, count = 2))
        assertEquals(0, TripResume.leg(atChange = false, finished = false, index = 0, count = 2))
        assertNull(TripResume.leg(atChange = false, finished = false, index = 1, count = 2))
        assertNull(TripResume.leg(atChange = false, finished = true, index = 0, count = 2))
        val t = 1_800_000_000.0
        assertTrue(TripResume.offer(t, t + 600, idle = true, moving = true, metresToItsStop = null))
        assertTrue(TripResume.offer(t, t + 600, idle = true, moving = false, metresToItsStop = 800.0))
        assertFalse(TripResume.offer(t, t + 600, idle = true, moving = false, metresToItsStop = 1200.0))
        assertFalse(TripResume.offer(t, t + 31 * 60, idle = true, moving = true, metresToItsStop = 10.0))
        assertFalse(TripResume.offer(t, t + 60, idle = false, moving = true, metresToItsStop = 10.0))
        assertFalse(TripResume.offer(t, t - 60, idle = true, moving = true, metresToItsStop = 10.0))
    }
}
