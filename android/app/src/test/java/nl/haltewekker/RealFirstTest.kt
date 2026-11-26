package nl.haltewekker

import nl.haltewekker.live.BusFusion
import nl.haltewekker.live.RealFirst
import nl.haltewekker.live.StopTimes
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** iOS `RealFirstTests` (0.40.3). */
class RealFirstTest {
    private val t0 = 7_000_000.0
    private fun at(s: Double) = t0 + s

    private fun trip(times: List<Pair<Double, Double>>): List<BusFusion.Stop> = times.mapIndexed { i, (a, d) ->
        BusFusion.Stop(i * 1000.0, StopTimes(if (i == 0) null else at(a), at(d), if (i == 0) null else at(a), at(d)))
    }

    private val plain get() = trip(listOf(0.0 to 0.0, 120.0 to 120.0, 240.0 to 240.0, 360.0 to 360.0))

    private fun show(s: List<BusFusion.Stop>, fix: RealFirst.Fix?, mine: Int? = 3, now: Double, fromStart: Boolean = true,
                     train: Boolean = false, leaves: Double? = null, me: RealFirst.Fix? = null) =
        RealFirst.show(RealFirst.Input(s, fix, true, at(now), mine, leaves?.let { at(it) }, at(now), fromStart, train, me))

    private fun fix(m: Double?, t: Double, v: Double? = null, stopped: Boolean = false, toMine: Double? = null, cross: Double = 0.0) =
        RealFirst.Fix(m, at(t), v, stopped, toMine, cross)

    @Test fun minuteOldFix_atTheFix_movedOn20sAtMost_ghostAhead() {
        val s = show(plain, fix(2100.0, 240.0, 5.0), now = 300.0)
        assertEquals(RealFirst.Source.GPS, s.source)
        assertEquals(2200.0, s.metres!!, 0.01); assertEquals(100.0, s.advanced, 0.01)
        assertFalse(s.atFix); assertNull(s.here)
        assertEquals(2447.6, s.ghost!!, 1.0)
        assertEquals("GPS 60 s", RealFirst.tag(s))
        assertEquals("vehicle shown · 305·9449 · gps ovapi 60 s · real +100 m · ghost +350 m", RealFirst.logLine("305·9449", "ovapi", s))
    }

    @Test fun freshFix_noGhostWhenClose() {
        val s = show(plain, fix(2470.0, 296.0, 8.0), now = 300.0)
        assertEquals(2502.0, s.metres!!, 0.01); assertNull(s.ghost)
    }

    @Test fun stuckBus_isntMovedOn() {
        val still = show(plain, fix(2100.0, 240.0, 0.0), now = 300.0)
        assertEquals(2100.0, still.metres!!, 0.01); assertEquals(0.0, still.advanced, 0.0)
        assertEquals(2100.0, show(plain, fix(2100.0, 240.0, null), now = 300.0).metres!!, 0.01)
        assertEquals(2000.0, show(plain, fix(2000.0, 240.0, 5.0, stopped = true), now = 300.0).metres!!, 0.01)
        assertEquals(2100.0, show(plain, fix(2100.0, 240.0, 1.2), now = 300.0).metres!!, 0.01)
    }

    @Test fun neverPastTheNextStopItMustStopAt() {
        assertEquals(1000.0, show(plain, fix(950.0, 100.0, 20.0), now = 120.0, train = true).metres!!, 0.01)
        assertEquals(1350.0, show(plain, fix(950.0, 100.0, 20.0), now = 120.0).metres!!, 0.01)
        val timing = trip(listOf(0.0 to 0.0, 120.0 to 180.0, 300.0 to 300.0, 420.0 to 420.0))
        assertEquals(1000.0, show(timing, fix(950.0, 100.0, 20.0), now = 120.0).metres!!, 0.01)
    }

    @Test fun neverIntoYourStop_withoutAFreshCloseFix() {
        val s = show(plain, fix(2900.0, 285.0, 10.0), now = 300.0)
        assertEquals(2965.0, s.metres!!, 0.01); assertNull(s.here)
        val near = show(plain, fix(2940.0, 290.0, 6.0), now = 300.0)
        assertEquals(RealFirst.Here.Arriving, near.here); assertTrue(near.metres!! <= 2965.01)
        val old = show(plain, fix(2990.0, 180.0, 0.0), now = 300.0)
        assertNull(old.here); assertEquals(2990.0, old.metres!!, 0.01)
        val there = show(plain, fix(2990.0, 280.0, 0.0), now = 300.0)
        assertEquals(RealFirst.Here.AtStop, there.here); assertTrue(there.isHere); assertEquals(3000.0, there.metres!!, 0.01)
        val waiting = show(plain, fix(2990.0, 280.0, 0.0), now = 300.0, leaves = 480.0)
        assertEquals(at(480.0), waiting.waiting)
    }

    @Test fun ghost_notAtYourStop_unlessDueWithinHalfAMinute() {
        val s = show(plain, fix(1500.0, 290.0, 0.0), now = 300.0)
        assertEquals(1500.0, s.metres!!, 0.01); assertNotNull(s.ghost); assertTrue(s.ghost!! <= 2900.01)
        val x = RealFirst.Input(plain, null, true, at(340.0), 3, now = at(340.0))
        assertEquals(2990.0, RealFirst.ghost(2990.0, 2500.0, x, 3)!!, 0.01)
        val early = RealFirst.Input(plain, null, true, at(300.0), 3, now = at(300.0))
        assertEquals(2900.0, RealFirst.ghost(2990.0, 2500.0, early, 3)!!, 0.01)
        assertNull(RealFirst.ghost(2990.0, 2800.0, early, 3))
    }

    @Test fun offItsRoad_atTheFixItself() {
        val s = show(plain, fix(2100.0, 280.0, 8.0, cross = 90.0), now = 300.0)
        assertEquals(RealFirst.Source.GPS, s.source); assertTrue(s.atFix); assertEquals(0.0, s.advanced, 0.0)
    }

    @Test fun throughTrain_legStartsAtYourStop() {
        val leg = trip(listOf(540.0 to 600.0, 900.0 to 900.0))
        val s = show(leg, fix(null, -10.0, 30.0, toMine = 20_000.0), mine = 0, now = 0.0, fromStart = false, train = true)
        assertEquals(RealFirst.Source.GPS, s.source); assertTrue(s.atFix); assertNull(s.metres); assertNull(s.here)
        val none = show(leg, fix(null, -10.0, 30.0, toMine = 60_000.0), mine = 0, now = 0.0, fromStart = false, train = true)
        assertEquals(RealFirst.Source.NONE, none.source); assertNull(none.metres)
        assertEquals("fix off its road, road before your stop not known", none.why)
    }

    @Test fun noGPS_nineMinutesOut_byItsTimes() {
        val s = show(trip((0 until 10).map { it * 60.0 to it * 60.0 }), null, mine = 9, now = 1.0)
        assertEquals(RealFirst.Source.BY_TIMES, s.source)
        assertEquals(16.7, s.metres!!, 1.0); assertTrue(9000 - s.metres!! > 8900)
        assertEquals("by times", RealFirst.tag(s))
        assertEquals("vehicle shown · 305·9449 · no gps: no fix · by times", RealFirst.logLine("305·9449", "ovapi", s))
    }

    @Test fun noGPS_byTimes_notAtYourStopBeforeItLeaves() {
        val shown = show(trip(listOf(0.0 to 0.0, 120.0 to 120.0, 240.0 to 240.0, 300.0 to 420.0)), null, now = 330.0)
        assertEquals(2965.0, shown.metres!!, 0.01); assertNull(shown.here)
    }

    @Test fun noRoadBeforeYourStop_noMarker() {
        val leg = trip(listOf(540.0 to 600.0, 900.0 to 900.0))
        val s = show(leg, null, mine = 0, now = 0.0, fromStart = false)
        assertEquals(RealFirst.Source.NONE, s.source); assertNull(s.metres); assertEquals("", RealFirst.tag(s))
        assertEquals("vehicle shown · IC·3561 · no gps: no fix, road before your stop not known · not drawn", RealFirst.logLine("IC·3561", "ns", s))
        assertEquals(RealFirst.Source.NONE, show(leg, null, mine = 0, now = 0.0).source)
    }

    @Test fun fixThatCantBeThisJourney_isntUsed() {
        val s = show(plain, fix(2005.0, 62.0, 0.0), mine = 2, now = 72.0)
        assertEquals(RealFirst.Source.BY_TIMES, s.source); assertEquals("fix not this journey", s.why); assertNull(s.here)
        assertEquals(RealFirst.Source.BY_TIMES, show(plain, fix(1000.0, 0.0, 0.0), now = 200.0).source)
    }

    @Test fun onBoard_whereYouAre() {
        val s = show(plain, fix(1000.0, 240.0, 5.0), now = 300.0, me = fix(1500.0, 298.0))
        assertEquals(RealFirst.Source.ON_BOARD, s.source); assertEquals(1500.0, s.metres!!, 0.01); assertNull(s.ghost)
        assertEquals("you’re on it", RealFirst.tag(s))
    }

    @Test fun glide_toANewFix_overTwoSeconds() {
        val g = RealFirst.Glide()
        assertEquals(1000.0, g.step(1000.0, at(0.0)), 0.0)
        assertEquals(1010.0, g.step(1010.0, at(1.0)), 0.0)
        assertEquals(1010.0, g.step(900.0, at(2.0)), 0.0)
        assertEquals(955.0, g.step(900.0, at(3.0)), 0.01)
        assertEquals(900.0, g.step(900.0, at(4.0)), 0.01)
        assertEquals(900.0, g.step(1200.0, at(5.0)), 0.01)
        assertEquals(1050.0, g.step(1200.0, at(6.0)), 0.01)
        assertEquals(1200.0, g.step(1200.0, at(7.0)), 0.01)
        assertEquals(3000.0, g.step(3000.0, at(60.0)), 0.0)
    }

    @Test fun estimatedMode_isTheOldFusedPlace() {
        val x = RealFirst.Input(plain, fix(2100.0, 252.0, 5.0), true, at(300.0), 3, now = at(300.0))
        val s = RealFirst.estimated(x)
        assertEquals(RealFirst.Source.GPS, s.source); assertEquals(2410.5, s.metres!!, 1.0); assertNull(s.ghost)
    }

    @Test fun ageText() {
        assertEquals("40 s", RealFirst.ageText(40.4)); assertEquals("3 min", RealFirst.ageText(150.0))
    }
}
