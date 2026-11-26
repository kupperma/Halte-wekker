package nl.haltewekker

import nl.haltewekker.motion.MotionConfidence
import nl.haltewekker.motion.MotionConfidence.HIGH
import nl.haltewekker.motion.MotionConfidence.LOW
import nl.haltewekker.motion.MotionConfidence.MEDIUM
import nl.haltewekker.motion.MotionKind
import nl.haltewekker.motion.MotionKind.AUTOMOTIVE
import nl.haltewekker.motion.MotionKind.CYCLING
import nl.haltewekker.motion.MotionKind.RUNNING
import nl.haltewekker.motion.MotionKind.STATIONARY
import nl.haltewekker.motion.MotionKind.WALKING
import nl.haltewekker.motion.MotionNow
import nl.haltewekker.motion.MotionRules
import nl.haltewekker.motion.MotionSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** iOS `MotionRulesTests` (0.33), and the Android step detector's reading. */
class MotionRulesTest {
    private val t0 = Fx.t0
    private fun s(dt: Double, k: MotionKind, c: MotionConfidence = HIGH) = MotionSample(t0 + dt, k, c)
    private fun now(x: List<MotionSample>, at: Double, live: Boolean = true): MotionNow? = MotionRules.now(x, t0 + at, live)

    @Test fun nowIsTheLatestAndSinceWhen() {
        val m = now(listOf(s(0.0, WALKING), s(60.0, AUTOMOTIVE, MEDIUM), s(90.0, AUTOMOTIVE)), 120.0)
        assertEquals(AUTOMOTIVE, m?.kind); assertEquals(HIGH, m?.confidence); assertEquals(t0 + 60, m!!.since, 0.0)
        assertNull(now(emptyList(), 0.0))
    }

    @Test fun aLowConfidenceBlipDoesntBreakARun() {
        val m = now(listOf(s(0.0, AUTOMOTIVE), s(100.0, WALKING, LOW), s(110.0, AUTOMOTIVE)), 300.0)
        assertEquals(t0, m!!.since, 0.0)
        assertTrue(MotionRules.steadyVehicle(m, t0 + 300))
        assertEquals(t0 + 110, now(listOf(s(0.0, AUTOMOTIVE), s(100.0, WALKING, HIGH), s(110.0, AUTOMOTIVE)), 300.0)!!.since, 0.0)
    }

    @Test fun staleWithoutLiveUpdates() {
        val x = listOf(s(0.0, AUTOMOTIVE))
        assertNotNull(now(x, 20 * 60.0, true)); assertNotNull(now(x, MotionRules.STALE, false)); assertNull(now(x, MotionRules.STALE + 1, false))
    }

    @Test fun samplesInTheFutureArentNow() { assertEquals(WALKING, now(listOf(s(0.0, WALKING), s(500.0, AUTOMOTIVE)), 100.0)?.kind) }

    @Test fun inVehicleNeedsMediumOrHigh() {
        assertTrue(MotionRules.inVehicle(now(listOf(s(0.0, AUTOMOTIVE, MEDIUM)), 1.0)))
        assertTrue(MotionRules.inVehicle(now(listOf(s(0.0, AUTOMOTIVE, HIGH)), 1.0)))
        assertFalse(MotionRules.inVehicle(now(listOf(s(0.0, AUTOMOTIVE, LOW)), 1.0)))
        assertFalse(MotionRules.inVehicle(now(listOf(s(0.0, CYCLING)), 1.0)))
        assertFalse(MotionRules.inVehicle(null))
    }

    @Test fun steadyVehicleAfterThreeMinutes() {
        val x = listOf(s(0.0, AUTOMOTIVE))
        assertFalse(MotionRules.steadyVehicle(now(x, 179.0), t0 + 179)); assertTrue(MotionRules.steadyVehicle(now(x, 180.0), t0 + 180))
        assertFalse(MotionRules.steadyVehicle(now(listOf(s(0.0, AUTOMOTIVE, LOW)), 600.0), t0 + 600))
    }

    @Test fun cyclingOrWalkingQuicklyIsntAVehicle() {
        val bike = now(listOf(s(0.0, CYCLING, MEDIUM)), 1.0)
        assertTrue(MotionRules.notAVehicle(bike, 7.0)); assertFalse(MotionRules.movingLikeVehicle(true, bike, 7.0))
        assertFalse(MotionRules.movingLikeVehicle(true, now(listOf(s(0.0, RUNNING)), 1.0), 5.5))
        val aisle = now(listOf(s(0.0, WALKING)), 1.0)
        assertFalse(MotionRules.notAVehicle(aisle, 38.0)); assertTrue(MotionRules.movingLikeVehicle(true, aisle, 38.0))
        assertTrue(MotionRules.movingLikeVehicle(true, now(listOf(s(0.0, CYCLING, LOW)), 1.0), 7.0))
        assertTrue(MotionRules.movingLikeVehicle(true, null, 7.0)); assertFalse(MotionRules.movingLikeVehicle(false, null, 7.0))
    }

    @Test fun automotiveIsMovingLikeAVehicleAtOnce() { assertTrue(MotionRules.movingLikeVehicle(false, now(listOf(s(0.0, AUTOMOTIVE, MEDIUM)), 1.0), null)) }

    @Test fun lookPace() {
        val still = now(listOf(s(0.0, STATIONARY)), 1.0)
        assertEquals(MotionRules.SLOW_LOOK, MotionRules.lookWait(7.0, still, false), 0.0)
        assertEquals(7.0, MotionRules.lookWait(7.0, still, true), 0.0)
        assertEquals(7.0, MotionRules.lookWait(7.0, null, false), 0.0)
        assertEquals(7.0, MotionRules.lookWait(7.0, now(listOf(s(0.0, AUTOMOTIVE)), 1.0), false), 0.0)
        assertEquals(30.0, MotionRules.lookWait(30.0, still, false), 0.0)
    }

    @Test fun waitingOnTheLowGPS() {
        val still = now(listOf(s(0.0, STATIONARY, MEDIUM)), 1.0); val walk = now(listOf(s(0.0, WALKING, HIGH)), 1.0)
        assertTrue(MotionRules.waitLow(true, still, false, 20_000.0, 5000.0))
        assertTrue(MotionRules.waitLow(true, walk, false, 20_000.0, 5000.0))
        assertFalse(MotionRules.waitLow(false, still, false, 20_000.0, 5000.0))
        assertFalse(MotionRules.waitLow(true, now(listOf(s(0.0, AUTOMOTIVE)), 1.0), false, 20_000.0, 5000.0))
        assertFalse(MotionRules.waitLow(true, now(listOf(s(0.0, STATIONARY, LOW)), 1.0), false, 20_000.0, 5000.0))
        assertFalse(MotionRules.waitLow(true, null, false, 20_000.0, 5000.0))
        assertFalse(MotionRules.waitLow(true, still, true, 20_000.0, 5000.0))
        assertFalse(MotionRules.waitLow(true, still, false, 6500.0, 5000.0))
        assertFalse(MotionRules.waitLow(true, still, false, null, 5000.0))
        assertFalse(MotionRules.waitLow(true, now(listOf(s(0.0, CYCLING)), 1.0), false, 20_000.0, 5000.0))
    }

    @Test fun firstLookAfterLeavingAStation() {
        assertEquals(MotionRules.REGION_LOOK_SOON, MotionRules.firstRegionLook(now(listOf(s(0.0, AUTOMOTIVE)), 1.0)), 0.0)
        assertEquals(MotionRules.REGION_LOOK_USUAL, MotionRules.firstRegionLook(now(listOf(s(0.0, WALKING)), 1.0)), 0.0)
        assertEquals(MotionRules.REGION_LOOK_USUAL, MotionRules.firstRegionLook(null), 0.0)
    }

    @Test fun trimKeepsAQuarterOfAnHourAndTheOneBefore() {
        val x = listOf(s(0.0, WALKING), s(100.0, AUTOMOTIVE), s(2000.0, STATIONARY))
        assertEquals(listOf(AUTOMOTIVE, STATIONARY), MotionRules.trim(x, t0 + 2000).map { it.kind })
        assertEquals(1, MotionRules.trim(listOf(s(0.0, WALKING)), t0 + 5000).size)
    }

    @Test fun stepsAreWalking() {
        val steps = (0 until 8).map { t0 + it * 0.6 }
        val w = MotionRules.fromSteps(steps, t0 + 5)
        assertEquals(WALKING, w?.kind); assertEquals(MEDIUM, w?.confidence)
        assertNull("a few steps (getting up) aren't a walk", MotionRules.fromSteps(steps.take(4), t0 + 3))
        assertNull("stopped walking", MotionRules.fromSteps(steps, t0 + 30))
        assertNull("a long gap between steps", MotionRules.fromSteps(listOf(t0, t0 + 1, t0 + 2, t0 + 8, t0 + 9, t0 + 10), t0 + 10))
        // a walk isn't a vehicle under 43 km/h; in a train's aisle it doesn't say otherwise
        val m = MotionRules.now(listOfNotNull(w), t0 + 5, true)
        assertTrue(MotionRules.notAVehicle(m, 1.4)); assertFalse(MotionRules.notAVehicle(m, 30.0))
    }
}
