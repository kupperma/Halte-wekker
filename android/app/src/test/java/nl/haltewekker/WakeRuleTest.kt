package nl.haltewekker

import nl.haltewekker.core.Geo
import nl.haltewekker.logs.FieldFormat
import nl.haltewekker.match.Fix
import nl.haltewekker.ride.RouteLeft
import nl.haltewekker.ride.SpeedSmoother
import nl.haltewekker.ride.WakeBy
import nl.haltewekker.ride.WakeRule
import nl.haltewekker.ride.WakeRule.Fire
import nl.haltewekker.ride.WakeRule.Source
import nl.haltewekker.ride.WakeSettings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** iOS `WakeRuleTests` (0.33): the time rule only ever rings earlier than the distance rule, on an estimate it trusts. */
class WakeRuleTest {
    private val t0 = Fx.t0

    private fun input(by: WakeBy = WakeBy.TIME, minutes: Int = 3, train: Boolean = true, metres: Double = 9000.0,
                      route: Double? = null, wake: Double = 5000.0, live: Double? = null, liveAge: Double? = null,
                      speed: Double? = null, fromStart: Double? = 20_000.0) =
        WakeRule.Input(by, minutes, train, metres, route, wake, live, liveAge, speed, fromStart, t0)

    @Test fun distanceRuleStillFires() {
        assertEquals(Fire.Distance, WakeRule.decide(input(metres = 4900.0)))
        assertEquals(Fire.Distance, WakeRule.decide(input(by = WakeBy.DISTANCE, metres = 4900.0)))
        assertEquals(Fire.Distance, WakeRule.decide(input(metres = 5000.0)))
        assertNull(WakeRule.decide(input(by = WakeBy.DISTANCE, metres = 5100.0)))
    }

    @Test fun distanceRuleWinsWhenBothHold() {
        assertEquals(Fire.Distance, WakeRule.decide(input(metres = 4000.0, live = t0 + 60, liveAge = 10.0)))
    }

    @Test fun byDistanceNeverRingsByTime() {
        assertNull(WakeRule.decide(input(by = WakeBy.DISTANCE, metres = 6000.0, live = t0 + 60, liveAge = 10.0, speed = 40.0)))
    }

    @Test fun liveArrivalWithinTheMinutes() {
        assertEquals(Fire.Time(3, Source.LIVE, 170.0), WakeRule.decide(input(metres = 6000.0, live = t0 + 170, liveAge = 20.0)))
        assertNull(WakeRule.decide(input(metres = 6000.0, live = t0 + 200, liveAge = 20.0)))
    }

    @Test fun staleLiveFallsBackToSpeed() {
        assertNull(WakeRule.decide(input(metres = 6000.0, live = t0 + 60, liveAge = 400.0, speed = 30.0)))
        val f = WakeRule.decide(input(metres = 6000.0, live = t0 + 60, liveAge = 400.0, speed = 36.0)) as Fire.Time
        assertEquals(3, f.minutes); assertEquals(Source.SPEED, f.source)
        assertEquals(6000.0 / 36, f.seconds, 0.01)
    }

    @Test fun liveThatCantBeRightIsntUsed() {
        assertNull(WakeRule.decide(input(metres = 7000.0, live = t0 + 60, liveAge = 10.0)))
        assertNull(WakeRule.decide(input(metres = 6000.0, live = t0 - 30, liveAge = 10.0)))
    }

    @Test fun haltedAtAStationBeforeYoursDoesntRing() {
        assertNull(WakeRule.decide(input(minutes = 2, train = false, metres = 2500.0, wake = 2000.0, speed = 0.5)))
        assertNull(WakeRule.decide(input(minutes = 2, train = false, metres = 2500.0, wake = 2000.0, speed = null)))
    }

    @Test fun alongTheRouteNotStraight() {
        assertNull(WakeRule.decide(input(metres = 5500.0, route = 12_000.0, speed = 40.0)))
        assertEquals(12_000.0, WakeRule.remaining(input(metres = 5500.0, route = 12_000.0)), 0.0)
        assertEquals(5500.0, WakeRule.remaining(input(metres = 5500.0, route = 5000.0)), 0.0)
        assertTrue(WakeRule.decide(input(metres = 5500.0, route = 6000.0, speed = 40.0)) is Fire.Time)
    }

    @Test fun neverFurtherThanTheMinutesAtTopSpeed() {
        assertNull(WakeRule.decide(input(metres = 9000.0, speed = 60.0)))
        assertEquals(3 * 60 * WakeRule.TRAIN_TOP, WakeRule.reach(true, 3), 0.0)
        assertEquals(2 * 60 * WakeRule.BUS_TOP, WakeRule.reach(false, 2), 0.0)
    }

    @Test fun notWhileStillAtTheLegsFirstStop() {
        assertNull(WakeRule.decide(input(metres = 6000.0, live = t0 + 170, liveAge = 10.0, fromStart = 150.0)))
        assertNotNull(WakeRule.decide(input(metres = 6000.0, live = t0 + 170, liveAge = 10.0, fromStart = null)))
    }

    @Test fun fastBusRingsBeforeItsDistance() {
        assertEquals(Fire.Time(2, Source.SPEED, 120.0),
            WakeRule.decide(input(minutes = 2, train = false, metres = 3000.0, wake = 2000.0, speed = 25.0)))
        assertNull(WakeRule.decide(input(minutes = 2, train = false, metres = 2100.0, wake = 2000.0, speed = 10.0)))
    }

    @Test fun logWords() {
        assertEquals("by distance", WakeRule.log(Fire.Distance))
        assertEquals("by time 3 min (live)", WakeRule.log(Fire.Time(3, Source.LIVE, 170.0)))
        assertEquals("by time 2 min (speed)", WakeRule.log(Fire.Time(2, Source.SPEED, 100.0)))
        assertEquals("ring · by time 3 min (live) · 5400 m · leg 600 s old · started 21000 m",
            FieldFormat.rideRing(WakeRule.log(Fire.Time(3, Source.LIVE, 170.0)), 5400.0, 600.0, 21_000.0))
        assertTrue(FieldFormat.rideRing(WakeRule.log(Fire.Distance), 1990.0, 300.0, 9000.0).startsWith("ring · by distance · "))
    }

    @Test fun whatItSays() {
        val time = WakeSettings(WakeBy.TIME, 3, 2)
        assertEquals("3 min before your stop (or 5 km)", WakeRule.says(time, true, 5000.0))
        assertEquals("2 min before your stop (or 2.5 km)", WakeRule.says(time, false, 2500.0))
        assertEquals("800 m before your stop", WakeRule.says(WakeSettings(WakeBy.DISTANCE, 3, 2), true, 800.0))
    }

    @Test fun gpsWakeMetres() {
        assertEquals(3 * 60 * WakeRule.TRAIN_TOP, WakeRule.gpsWakeMetres(5000.0, WakeSettings(), true), 0.0)
        assertEquals(9000.0, WakeRule.gpsWakeMetres(9000.0, WakeSettings(), true), 0.0)
        assertEquals(5000.0, WakeRule.gpsWakeMetres(5000.0, WakeSettings(by = WakeBy.DISTANCE), true), 0.0)
    }

    @Test fun settingsDefaultsAndBounds() {
        val s = WakeSettings()
        assertEquals(WakeSettings(WakeBy.TIME, 3, 2), s)
        assertEquals(3, s.minutes(true)); assertEquals(2, s.minutes(false))
        assertEquals(10, WakeSettings.clamp(40)); assertEquals(1, WakeSettings.clamp(0))
        // the settings' default (A6): by time, 3 and 2
        val st = nl.haltewekker.profile.Settings()
        assertEquals(WakeBy.TIME, st.wake.by)
    }

    @Test fun smootherWarmsUpAndFollows() {
        val s = SpeedSmoother()
        s.add(30.0, t0)
        assertNull(s.speed(t0))
        for (k in 1..10) s.add(30.0, t0 + k * 2)
        assertEquals(30.0, s.speed(t0 + 20) ?: 0.0, 0.01)
        for (k in 11..20) s.add(0.0, t0 + k * 2)
        val v = s.speed(t0 + 40) ?: -1.0
        assertTrue(v < 20); assertTrue(v > 5)
        for (k in 21..80) s.add(0.0, t0 + k * 2)
        assertTrue((s.speed(t0 + 160) ?: 99.0) < WakeRule.MIN_SPEED)
    }

    @Test fun smootherForgetsAfterAGap() {
        val s = SpeedSmoother()
        for (k in 0..15) s.add(30.0, t0 + k * 2)
        assertNotNull(s.speed(t0 + 30))
        assertNull(s.speed(t0 + 30 + SpeedSmoother.GAP + 1))
        s.add(10.0, t0 + 200)
        assertNull(s.speed(t0 + 200))
    }

    @Test fun smootherIgnoresNonsense() {
        val s = SpeedSmoother()
        for (k in 0..15) s.add(20.0, t0 + k * 2)
        s.add(-1.0, t0 + 32); s.add(Double.NaN, t0 + 33); s.add(400.0, t0 + 34)
        assertEquals(20.0, s.speed(t0 + 34) ?: 0.0, 0.01)
    }

    @Test fun readingFromAFix() {
        val a = Fix(t0, Fx.east(0.0), 10.0, -1.0, -1.0)
        val b = Fix(t0 + 10, Fx.east(300.0), 10.0, -1.0, -1.0)
        assertEquals(30.0, SpeedSmoother.reading(b, a) ?: 0.0, 0.5)
        assertEquals(22.0, SpeedSmoother.reading(Fix(t0 + 10, Fx.east(300.0), 10.0, 22.0, 90.0), a)!!, 0.0)
        assertNull(SpeedSmoother.reading(Fix(t0 + 10, Fx.east(300.0), 120.0, -1.0, -1.0), a))
        assertNull(SpeedSmoother.reading(b, null))
    }

    @Test fun routeLeft() {
        val path = listOf(Fx.east(0.0), Fx.east(3000.0), Fx.east(6900.0))
        assertEquals(5900.0, RouteLeft.metres(Fx.east(1000.0), path) ?: 0.0, 2.0)
        assertEquals(5900.0, RouteLeft.metres(Fx.east(1000.0, 200.0), path) ?: 0.0, 2.0)
        assertNull(RouteLeft.metres(Fx.east(1000.0, 3000.0), path))
        assertNull(RouteLeft.metres(Fx.east(1000.0), listOf(Fx.east(0.0))))
    }

    @Test fun routeLeftAroundABend() {
        val path = listOf(Fx.east(0.0), Fx.east(3000.0), Fx.east(3000.0, 1000.0), Fx.east(500.0, 1000.0))
        val you = Fx.east(800.0)
        assertEquals(2200.0 + 1000 + 2500, RouteLeft.metres(you, path) ?: 0.0, 3.0)
        assertTrue(Geo.metres(you, Fx.east(500.0, 1000.0)) < 1100)
    }
}
