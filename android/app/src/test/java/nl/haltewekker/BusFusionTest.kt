package nl.haltewekker

import nl.haltewekker.live.BusFusion
import nl.haltewekker.live.StopTimes
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.exp

/** iOS `BusFusionTests` and `WaitMarkerTests` (0.40.1). */
class BusFusionTest {
    private val t0 = 7_000_000.0
    private fun at(s: Double) = t0 + s

    private fun trip(times: List<Pair<Double, Double>>, delay: Double = 0.0): List<BusFusion.Stop> = times.mapIndexed { i, (a, d) ->
        val sa = at(a); val sd = at(d)
        BusFusion.Stop(i * 1000.0, StopTimes(if (i == 0) null else sa + delay, sd + delay, if (i == 0) null else sa, sd))
    }

    private val plain get() = trip(listOf(0.0 to 0.0, 120.0 to 120.0, 240.0 to 240.0, 360.0 to 360.0))

    private fun fuse(stops: List<BusFusion.Stop>, fix: BusFusion.Fix?, live: Boolean = true, mine: Int? = 3, now: Double) =
        BusFusion.fuse(BusFusion.Input(stops, fix, live, at(now), mine, now = at(now)))

    @Test fun byTimes_secondsLeftAtTheTimetablesSpeed() {
        val b = BusFusion.byTimes(plain, at(300.0))
        assertEquals(2500.0, b!!.metres, 0.01); assertEquals(3, b.next)
        assertTrue(BusFusion.byTimes(plain, at(241.0))!!.metres >= 2000)
        val slow = plain.toMutableList(); slow[3] = slow[3].copy(times = slow[3].times.copy(arrival = at(900.0)))
        assertEquals(2000.0, BusFusion.byTimes(slow, at(300.0))!!.metres, 0.01)
    }

    @Test fun gpsBehind_etaAhead_blended() {
        val e = fuse(plain, BusFusion.Fix(2100.0, at(252.0), 5.0), now = 300.0)
        assertEquals(2340.0, e.gps!!, 0.01); assertEquals(2500.0, e.eta!!, 0.01); assertEquals(2410.5, e.metres!!, 1.0)
        assertTrue(e.metres!! > e.gps!! && e.metres!! < e.eta!!)
        assertEquals(BusFusion.Note.NONE, e.note)
        assertEquals("bus fused · 305·9449 · gps 48 s old +240 m · eta says +400 m · drawn +310 m",
            BusFusion.logLine("bus", "305·9449", e, e.metres!!))
    }

    @Test fun oldGPS_countsLittle() {
        val fresh = fuse(plain, BusFusion.Fix(1300.0, at(280.0), 4.0), now = 300.0)
        val old = fuse(plain, BusFusion.Fix(1300.0, at(150.0), 4.0), now = 300.0)
        assertEquals(0.10, old.gpsWeight, 0.001); assertEquals(1925.0, old.gps!!, 0.5)
        assertTrue(old.metres!! > 2400 && old.metres!! <= 2500)
        assertEquals(1.0, fresh.gpsWeight, 0.0); assertTrue(fresh.metres!! < old.metres!!)
        assertEquals(1925.0, old.hint!!.first, 0.5); assertEquals(2500.0, old.hint!!.second, 0.5)
    }

    @Test fun gpsWeight_byAge() {
        assertEquals(1.0, BusFusion.gpsWeight(10.0), 0.0)
        assertEquals(0.575, BusFusion.gpsWeight(70.0), 0.001)
        assertEquals(0.15, BusFusion.gpsWeight(120.0), 0.001)
        assertEquals(0.05, BusFusion.gpsWeight(400.0), 0.001)
        assertTrue(BusFusion.etaWeight(10.0, 60.0) > BusFusion.etaWeight(300.0, 1200.0))
    }

    @Test fun noGPS_byItsTimes() {
        val e = fuse(plain, null, now = 300.0)
        assertEquals(2500.0, e.metres!!, 0.01); assertNull(e.gps)
        assertEquals("bus fused · 305·9449 · no gps · drawn by its times", BusFusion.logLine("bus", "305·9449", e, 2500.0))
    }

    @Test fun noLiveTimes_byItsGPS() {
        val e = fuse(plain, BusFusion.Fix(2100.0, at(252.0), 5.0), live = false, now = 300.0)
        assertEquals(2340.0, e.metres!!, 0.01); assertNull(e.eta); assertNull(e.hint)
    }

    @Test fun standingAtATimingStop() {
        val s = trip(listOf(0.0 to 0.0, 120.0 to 120.0, 240.0 to 360.0, 480.0 to 480.0))
        assertTrue(BusFusion.isTiming(s, 2))
        val e = fuse(s, BusFusion.Fix(2005.0, at(250.0), 0.0), now = 300.0)
        assertEquals(2005.0, e.gps!!, 0.01); assertEquals(2005.0, e.metres!!, 0.01)
        assertEquals(2000.0, BusFusion.ahead(s, BusFusion.Fix(1500.0, at(200.0), 8.33), at(300.0)), 0.01)
        assertFalse(BusFusion.isTiming(plain, 2))
        assertEquals(2333.3, BusFusion.ahead(plain, BusFusion.Fix(1500.0, at(200.0), 8.3333), at(300.0)), 0.5)
    }

    @Test fun neverFasterThanTheTimetableAllows() {
        assertEquals(2500.0, BusFusion.ahead(plain, BusFusion.Fix(2000.0, at(260.0), 20.0), at(300.0)), 0.01)
        val far = trip(listOf(0.0 to 0.0, 1200.0 to 1200.0, 2400.0 to 2400.0))
        assertEquals(360.0, BusFusion.ahead(far, BusFusion.Fix(0.0, at(0.0), null), at(600.0)), 0.5)
    }

    @Test fun disagreeingByAKilometre_trustsFreshGPS() {
        val e = fuse(plain, BusFusion.Fix(1000.0, at(290.0), 0.0), now = 300.0)
        assertEquals(BusFusion.Note.GPS_TRUSTED, e.note); assertEquals(e.gps!!, e.metres!!, 0.01); assertTrue(e.metres!! < 1100)
        assertTrue(BusFusion.logLine("bus", "305·9449", e, e.metres!!).endsWith("far apart: gps trusted"))
    }

    @Test fun seenFurtherOn_trustsFreshGPS() {
        val e = fuse(plain, BusFusion.Fix(2700.0, at(290.0), 8.3333), now = 300.0)
        assertEquals(BusFusion.Note.GPS_TRUSTED, e.note); assertEquals(2783.3, e.metres!!, 0.5)
    }

    @Test fun aKilometreAhead_isntThisJourney() {
        val e = fuse(plain, BusFusion.Fix(2700.0, at(140.0), null), now = 150.0)
        assertEquals(BusFusion.Note.GPS_IGNORED, e.note); assertEquals(1250.0, e.metres!!, 0.01)
        assertEquals("bus fused · 305·9449 · gps not this journey · drawn by its times", BusFusion.logLine("bus", "305·9449", e, 1250.0))
    }

    @Test fun notAtYourStopByMovingItOn() {
        val e = fuse(plain, BusFusion.Fix(1500.0, at(40.0), 8.3333), mine = 2, now = 200.0)
        assertTrue(e.metres!! < 1965.01 && e.metres!! > 1500)
    }

    @Test fun stopsFromPieces() {
        val p = listOf(BusFusion.Piece(0.0, 800.0, at(0.0), at(100.0), at(0.0), at(90.0)), BusFusion.Piece(800.0, 400.0, at(110.0), at(160.0)))
        val s = BusFusion.stops(p)
        assertEquals(listOf(0.0, 800.0, 1200.0), s.map { it.metres })
        assertEquals(at(100.0), s[1].times.at); assertEquals(at(110.0), s[1].times.leaves); assertEquals(at(90.0), s[1].times.scheduledAt)
        assertNull(s[2].times.departure)
    }

    @Test fun glide_neverBackwards() {
        val g = BusFusion.Glide()
        assertEquals(1000.0, g.step(1000.0, at(0.0), 8.0), 0.0)
        assertEquals(1000.0, g.step(700.0, at(1.0), 8.0), 0.0)
        assertEquals(1000.0, g.step(800.0, at(2.0), 8.0), 0.0)
        val v = g.step(1010.0, at(3.0), 8.0); assertTrue(v > 1000 && v <= 1010)
    }

    @Test fun glide_noTeleport() {
        val g = BusFusion.Glide(); g.step(1000.0, at(0.0), 8.0)
        assertEquals(1025.0, g.step(2000.0, at(1.0), 8.0), 0.01)
        assertEquals(1050.0, g.step(2000.0, at(2.0), 8.0), 0.01)
        assertEquals(1050.0, g.step(2000.0, at(2.0), 8.0), 0.01)
    }

    @Test fun glide_maxSpeed() {
        val g = BusFusion.Glide(); g.step(1000.0, at(0.0), 20.0)
        assertEquals(1030.0, g.step(3000.0, at(1.0), 20.0), 0.01)
        assertEquals(1180.0, g.step(3000.0, at(11.0), 20.0), 0.01)
    }

    @Test fun glide_easesIn() {
        val g = BusFusion.Glide(); g.step(1000.0, at(0.0), 0.0)
        assertEquals(1000 + 10 * (1 - exp(-0.5)), g.step(1010.0, at(1.0), 0.0), 0.01)
        val h = BusFusion.Glide(); h.step(1000.0, at(0.0), 8.0)
        assertEquals(1008.0, h.step(1010.0, at(1.0), 8.0), 0.01)
        assertEquals(1010.0, h.step(1010.0, at(2.0), 8.0), 0.01)
    }

    @Test fun glide_back_onAFreshFix() {
        val g = BusFusion.Glide(); g.step(2000.0, at(0.0), 8.0, at(-30.0), 30.0)
        assertEquals(2000.0, g.step(1700.0, at(1.0), 8.0, at(-4.0), 5.0), 0.01)
        assertEquals(1900.0, g.step(1700.0, at(2.0), 8.0, at(-4.0), 6.0), 0.01)
        assertEquals(1800.0, g.step(1700.0, at(3.0), 8.0, at(-4.0), 7.0), 0.01)
        assertEquals(1700.0, g.step(1700.0, at(4.0), 8.0, at(-4.0), 8.0), 0.01)
        assertTrue(g.step(1720.0, at(5.0), 8.0, at(-4.0), 9.0) > 1700)
    }

    @Test fun glide_notBack_forAnOldFix() {
        val g = BusFusion.Glide(); g.step(2000.0, at(0.0), 8.0, at(-30.0), 30.0)
        assertEquals(2000.0, g.step(1700.0, at(1.0), 8.0, at(-100.0), 101.0), 0.0)
        assertEquals(2000.0, g.step(1900.0, at(2.0), 8.0, at(-1.0), 3.0), 0.0)
        assertEquals(2000.0, g.step(1700.0, at(3.0), 8.0, at(-1.0), 4.0), 0.0)
    }

    @Test fun glide_startsAgain() {
        val g = BusFusion.Glide(); g.step(1000.0, at(0.0), 8.0)
        assertEquals(3000.0, g.step(3000.0, at(60.0), 8.0), 0.0)
        g.reset()
        assertEquals(500.0, g.step(500.0, at(61.0), 8.0), 0.0)
    }

    @Test fun signedMetres() {
        assertEquals("+320 m", BusFusion.signed(318.0)); assertEquals("-80 m", BusFusion.signed(-84.0)); assertEquals("+0 m", BusFusion.signed(0.0))
    }

    // iOS WaitMarkerTests (by BusFusion since 0.40.1)
    private val later get() = trip(listOf(840.0 to 840.0, 960.0 to 960.0, 1080.0 to 1080.0))

    @Test fun wait_layoverAtTheTerminus() {
        val e = fuse(later, BusFusion.Fix(10.0, at(-20.0)), mine = 0, now = 0.0)
        assertEquals(0.0, e.metres!!, 0.0); assertEquals(at(840.0), e.waiting)
        assertEquals("Waiting · leaves 17:42", BusFusion.waitingText(at(840.0)) { "17:42" })
    }

    @Test fun wait_beforeItsTripStarts_noFix() {
        val e = fuse(later, null, mine = 0, now = 0.0); assertNull(e.metres); assertNull(e.waiting)
    }

    @Test fun wait_fixElsewhereBeforeStart() {
        val e = fuse(later, BusFusion.Fix(400.0, at(-20.0)), mine = 0, now = 0.0)
        assertEquals(BusFusion.Note.GPS_IGNORED, e.note); assertNull(e.metres)
    }

    @Test fun wait_previousJourneysGPS() {
        val e = fuse(plain, BusFusion.Fix(2005.0, at(62.0)), mine = 2, now = 72.0)
        assertEquals(BusFusion.Note.GPS_IGNORED, e.note); assertEquals(600.0, e.metres!!, 0.01); assertNull(e.waiting)
    }

    @Test fun wait_standingAtYourStop_freshFix() {
        val s = trip(listOf(0.0 to 0.0, 120.0 to 120.0, 240.0 to 480.0, 600.0 to 600.0))
        val e = fuse(s, BusFusion.Fix(1995.0, at(225.0), 0.0), mine = 2, now = 240.0)
        assertEquals(2000.0, e.metres!!, 0.0); assertEquals(at(480.0), e.waiting)
    }

    @Test fun wait_oldFix_saysNothing() {
        val s = trip(listOf(0.0 to 0.0, 120.0 to 120.0, 240.0 to 480.0, 600.0 to 600.0))
        val e = fuse(s, BusFusion.Fix(1995.0, at(90.0), 0.0), mine = 2, now = 240.0)
        assertNull(e.waiting); assertTrue(e.metres!! <= 2000)
    }

    @Test fun wait_leavingWithinAMinute() {
        val s = trip(listOf(0.0 to 0.0, 120.0 to 120.0, 240.0 to 280.0, 600.0 to 600.0))
        val e = fuse(s, BusFusion.Fix(1995.0, at(235.0), 0.0), mine = 2, now = 240.0)
        assertNull(e.waiting); assertEquals(1996.0, e.metres!!, 2.0)
    }

    @Test fun wait_closeAndDueSoon() {
        val e = fuse(plain, BusFusion.Fix(1900.0, at(225.0), 8.3333), mine = 2, now = 230.0)
        assertNotNull(e.metres); assertEquals(1925.0, e.metres!!, 15.0); assertTrue(e.metres!! < 1965.01)
    }
}
