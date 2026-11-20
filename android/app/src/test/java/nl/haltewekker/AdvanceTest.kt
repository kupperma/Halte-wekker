package nl.haltewekker

import nl.haltewekker.core.GeoPoint
import nl.haltewekker.live.Advance
import nl.haltewekker.live.Advance.Pace
import nl.haltewekker.live.GPSFix
import nl.haltewekker.match.VehicleGPS
import nl.haltewekker.match.VehicleMatch
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs
import kotlin.math.cos

/** iOS `AdvanceTests` (0.34): an old bus GPS fix moved forward by the bus's own pace. */
class AdvanceTest {
    private val t = 1_794_900_000.0
    private val kx = cos(51.6 * Math.PI / 180) * 111_320

    private fun p(m: Double) = GeoPoint(51.6, 5.3 + m / kx)
    private fun fix(m: Double, at: Double, speed: Double? = null) = GPSFix(51.6, 5.3 + m / kx, 90.0, at, speed = speed)

    private val long get() = Advance.chained(listOf(Advance.Piece(listOf(p(0.0), p(1500.0), p(3000.0)), t, t + 300)))
    private val short get() = Advance.chained((0 until 3).map { k ->
        val d = t + k * 180.0
        Advance.Piece(listOf(p(k * 600.0), p(k * 600.0 + 300), p((k + 1) * 600.0)), d, d + 120)
    })

    @Test fun observedSpeedBetweenItsLastTwoFixes() {
        val legs = long
        val now = t + 100
        assertEquals(10.0, Advance.observedSpeed(fix(800.0, now), fix(500.0, now - 30), legs) ?: 0.0, 0.5)
        assertEquals(33.0, Advance.observedSpeed(fix(800.0, now, 33.0), null, legs)!!, 0.0)
        assertNull(Advance.observedSpeed(fix(800.0, now), fix(790.0, now - 2), legs))
        assertNull(Advance.observedSpeed(fix(800.0, now), fix(0.0, now - 300), legs))
        assertNull(Advance.observedSpeed(fix(2800.0, now), fix(0.0, now - 30), legs))
        assertNull(Advance.observedSpeed(fix(500.0, now), fix(800.0, now - 30), legs))
        assertNull(Advance.observedSpeed(fix(800.0, now), null, legs))
    }

    @Test fun movesOnAtItsObservedSpeedUpToTwoMinutes() {
        val legs = long
        val now = t + 200
        val old = fix(500.0, now - 100)
        val s = Advance.snap(old, legs)!!
        assertEquals(1100.0, Advance.advance(s, old.at, legs, now).along, 2.0)
        assertEquals(1300.0, Advance.advance(s, old.at, legs, now, Pace(8.0, null)).along, 2.0)
        val older = fix(500.0, now - 150)
        val s2 = Advance.snap(older, legs)!!
        assertEquals(1460.0, Advance.advance(s2, older.at, legs, now, Pace(8.0, null)).along, 2.0)
    }

    @Test fun aLateBusLeavesItsStopLate() {
        val legs = short
        val now = t + 230
        val f = fix(550.0, now - 60)
        val s = Advance.snap(f, legs)!!
        val late = Advance.lateness(s, f.at, legs)
        assertEquals(60.0, late ?: 0.0, 3.0)
        val a = Advance.advance(s, f.at, legs, now, Pace(5.0, late))
        assertEquals(0, a.leg)
        assertEquals(600.0, a.along, 1.0)
        assertEquals(1, Advance.advance(s, f.at, legs, now).leg)
    }

    @Test fun standsAMomentAtAStopOnItsWay() {
        val legs = short
        val now = t + 420
        val f = fix(1150.0, now - 60)
        val s = Advance.snap(f, legs)!!
        val a = Advance.advance(s, f.at, legs, now, Pace(5.0, null))
        assertEquals(1200 + 5 * (60 - 10 - Advance.DWELL), legs[a.leg].start + a.along, 2.0)
    }

    @Test fun placeUsesItsFixBefore() {
        val legs = long
        val now = t + 200
        val f = fix(1000.0, now - 80); val before = fix(760.0, now - 110)
        assertEquals(1000.0 + 8 * 80, Advance.place(f, before, legs, now)?.first ?: 0.0, 3.0)
        assertEquals(1600.0, Advance.place(f, null, legs, now)?.first ?: 0.0, 3.0)
    }

    @Test fun moreRoomForAnOlderFix() {
        assertEquals(0.0, Advance.ageSlack(20.0, 10.0), 0.0)
        assertEquals(0.2 * 10 * 60, Advance.ageSlack(90.0, 10.0), 0.1)
        assertTrue(Advance.ageSlack(600.0, 40.0) <= Advance.MAX_SLACK)
        assertEquals(0.0, Advance.ageSlack(Double.NaN, 10.0), 0.0)
    }

    @Test fun matcherJudgesAgainstTheAdvancedFix() {
        val you = Fx.fixes(2000.0, 14.0, 15, start = Fx.t0)
        val newest = you.last().t
        val back = 14.0 * 85
        val at = Fx.east(2000 + 14 * 28 - back)
        val before = Fx.east(2000 + 14 * 28 - back - 14 * 30)
        val bus = Fx.track("305", line = "305", train = false, path = Fx.railway, at = 1500.0, speed = 7.0)
            .copy(gps = VehicleGPS(GPSFix(at.lat, at.lon, 90.0, newest - 85), GPSFix(before.lat, before.lon, 90.0, newest - 115)))
        val j = VehicleMatch.judgeAll(you, listOf(bus), strictTimes = false)
        assertEquals(true, j.first().evidence?.gps)
        assertNotNull("$j", Fx.ok(j, "305"))
        assertTrue(abs(j.first().evidence?.offset ?: 9999.0) < 100)
    }
}
