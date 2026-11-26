package nl.haltewekker

import nl.haltewekker.core.GeoPoint
import nl.haltewekker.live.RealPositions
import nl.haltewekker.ride.ChangeGuide
import nl.haltewekker.ride.MissCall
import nl.haltewekker.ride.MissCall.Call as C
import nl.haltewekker.ride.NextLegGuard
import nl.haltewekker.ride.ShortLeg
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.ZoneId
import java.time.ZonedDateTime

/** iOS `MissCallTests` and `ShortLegTests` (0.42.3). */
class MissCallTest {
    private val t0 = 1_800_000_000.0
    private fun at(s: Double) = t0 + s
    private val hhmm: (Double) -> String = { "+${Math.floorDiv((it - t0).toLong(), 60L)}" }
    private fun bus(id: String, line: String, s: Double, walk: Int = 1, from: GeoPoint? = null) = ChangeGuide.Ride(id, line, false, at(s), null, walk, from)
    private fun train(id: String, s: Double, walk: Int = 2, from: GeoPoint? = null) = ChangeGuide.Ride(id, "IC", true, at(s), "3", walk, from)
    private val station = GeoPoint(51.5950, 4.7800)
    private val away = GeoPoint(51.6200, 4.7900)

    @Test fun noLiveNoGPS_lookOut() {
        val blind = MissCall.Next(false, MissCall.Seen.NONE, 400.0)
        assertEquals(C.FINE, MissCall.atChange(at(0.0), blind, at(-120.0))); assertEquals(C.LOOK_OUT, MissCall.atChange(at(0.0), blind, at(78.0)))
        assertEquals(C.LOOK_OUT, MissCall.atChange(at(0.0), blind, at(179.0))); assertEquals(C.MISSED, MissCall.atChange(at(0.0), blind, at(181.0)))
        assertEquals(C.LOOK_OUT, MissCall.atChange(at(0.0), MissCall.Next(false, MissCall.Seen.NONE, 40.0), at(600.0)))
        assertEquals(C.MISSED, MissCall.atChange(at(0.0), MissCall.Next(false, MissCall.Seen.NONE, null), at(181.0)))
    }

    @Test fun guideSaysLookOut() {
        val g = ChangeGuide.guide(at(-280.0), null, true, null, bus("city-1", "1", 0.0), listOf(bus("city-8", "8", 300.0)), null, at(78.0), hhmm,
            atChange = true, seen = MissCall.Next(false, MissCall.Seen.NONE, 60.0))
        assertFalse(g.missed); assertNull(g.missText); assertEquals(C.LOOK_OUT, g.call)
        assertEquals("Should be leaving now", g.countdown); assertEquals("Look out for it", g.note); assertEquals("city-1", g.target.tripId)
    }

    @Test fun noMissToldThatsTakenBack() {
        var hold = MissCall.Hold()
        val told = ArrayList<Double>()
        var t = 18.0
        while (t <= 240) {
            val n = MissCall.Next(false, if (t >= 184) MissCall.Seen.NOT_LEFT else MissCall.Seen.NONE, 200.0)
            val step = MissCall.step(hold, MissCall.atChange(at(0.0), n, at(t)), "1|city-1", at(t))
            hold = step.hold
            if (step.call == C.MISSED) told.add(t)
            t += 30
        }
        assertEquals(emptyList<Double>(), told)
    }

    @Test fun liveWithoutGPS_mayHaveLeft() {
        val live = MissCall.Next(true, MissCall.Seen.NONE, 400.0)
        assertEquals(C.FINE, MissCall.atChange(at(0.0), live, at(50.0))); assertEquals(C.MAYBE, MissCall.atChange(at(0.0), live, at(90.0)))
        assertEquals(C.LOOK_OUT, MissCall.atChange(at(0.0), MissCall.Next(true, MissCall.Seen.NONE, 30.0), at(90.0)))
        assertEquals(C.MISSED, MissCall.atChange(at(0.0), live, at(200.0)))
        assertEquals(C.FINE, MissCall.atChange(at(0.0), MissCall.Next(true, MissCall.Seen.NOT_LEFT), at(400.0)))
        assertEquals(C.MISSED, MissCall.atChange(at(0.0), MissCall.Next(false, MissCall.Seen.GONE), at(10.0)))
        assertEquals(C.FINE, MissCall.atChange(at(0.0), MissCall.Next(true, MissCall.Seen.GONE), at(-300.0)))
    }

    @Test fun seenByItsOwnGPS() {
        assertEquals(MissCall.Seen.NOT_LEFT, MissCall.seen(1900.0, 2000.0, 20.0)); assertEquals(MissCall.Seen.NONE, MissCall.seen(2100.0, 2000.0, 20.0))
        assertEquals(MissCall.Seen.GONE, MissCall.seen(2400.0, 2000.0, 20.0)); assertEquals(MissCall.Seen.NONE, MissCall.seen(2400.0, 2000.0, 150.0))
        assertEquals(MissCall.Seen.NONE, MissCall.seen(null, 2000.0, 20.0))
    }

    @Test fun holdTellsAfterAMinute() {
        var s = MissCall.step(MissCall.Hold(), C.MISSED, "k", at(0.0)); assertEquals(C.MAYBE, s.call)
        s = MissCall.step(s.hold, C.MISSED, "k", at(30.0)); assertEquals(C.MAYBE, s.call)
        s = MissCall.step(s.hold, C.MISSED, "k", at(61.0)); assertEquals(C.MISSED, s.call)
        s = MissCall.step(s.hold, C.FINE, "k", at(90.0)); assertEquals(C.FINE, s.call); assertTrue(s.retract)
        s = MissCall.step(s.hold, C.MISSED, "other", at(100.0)); assertEquals(C.MAYBE, s.call); assertFalse(s.retract)
    }

    @Test fun onTheWay() {
        assertEquals(C.TIGHT, MissCall.onTheWay(at(0.0), at(90.0), 3.0, at(-60.0), false))
        assertEquals(C.MISSED, MissCall.onTheWay(at(0.0), at(90.0), 3.0, at(-60.0), true))
        assertEquals(C.TIGHT, MissCall.onTheWay(at(0.0), at(130.0), 3.0, at(-60.0), true))
        assertEquals(C.FINE, MissCall.onTheWay(at(0.0), at(240.0), 3.0, at(-60.0), true))
    }

    @Test fun freshness() {
        assertTrue(MissCall.fresh(60.0, null)); assertFalse(MissCall.fresh(120.0, null)); assertTrue(MissCall.fresh(300.0, 100.0))
        assertFalse(MissCall.fresh(300.0, 200.0)); assertFalse(MissCall.fresh(null, null))
    }

    @Test fun onTheBus_staleData_tight() {
        val g = ChangeGuide.guide(at(0.0), null, false, null, train("ic-1940", 60.0, 3, station), listOf(train("ic-2010", 30 * 60.0, 3, station)), 4.0,
            at(-120.0), hhmm, fresh = false, feeding = MissCall.Feeding("bus4-a", "4", false), changeAt = listOf(station))
        assertFalse(g.missed); assertNull(g.missText); assertEquals(C.TIGHT, g.call); assertEquals("Tight — run", g.note); assertEquals("ic-1940", g.target.tripId)
    }

    @Test fun insteadContinuesFromTheChange() {
        val feeding = MissCall.Feeding("bus4-a", "4", false)
        val later = listOf(bus("bus4-b", "4", 19 * 60.0), bus("bus4-a", "4", 25 * 60.0), bus("bus7", "7", 10 * 60.0, from = away),
            train("ic-2010", 30 * 60.0, from = station), bus("bus9", "9", 12 * 60.0))
        assertEquals(listOf("ic-2010", "bus9"), MissCall.sane(later, train("ic-1940", 0.0, from = station), feeding, listOf(station)).map { it.tripId })
        assertEquals(listOf("bus4-b"), MissCall.sane(listOf(bus("bus4-b", "4", 19 * 60.0, from = station)), bus("bus4-p", "4", 0.0), feeding, listOf(station)).map { it.tripId })
    }

    @Test fun neverTheLineYouAreOn() {
        val next = train("ic-1940", 60.0, 3, station)
        val later = listOf(bus("bus4-b", "4", 19 * 60.0))
        val feeding = MissCall.Feeding("bus4-a", "4", false)
        val g = ChangeGuide.guide(at(0.0), null, false, null, next, later, 4.0, at(-120.0), hhmm, fresh = true, call = C.MISSED, feeding = feeding, changeAt = listOf(station))
        assertFalse(g.missed); assertNull(g.missText); assertEquals(C.TIGHT, g.call)
        val ok = ChangeGuide.guide(at(0.0), null, false, null, next, later + train("ic-2010", 30 * 60.0, 3, station), 4.0, at(-120.0), hhmm,
            fresh = true, call = C.MISSED, feeding = feeding, changeAt = listOf(station))
        assertTrue(ok.missed); assertEquals("You’ll miss the +1 — take the +30 from platform 3", ok.missText)
    }

    // ShortLegTests
    @Test fun shortHop() {
        assertTrue(ShortLeg.isShort(530.0, 1000.0)); assertTrue(ShortLeg.isShort(700.0, 400.0)); assertFalse(ShortLeg.isShort(5200.0, 1000.0))
        assertFalse(ShortLeg.isShort(1200.0, 1000.0)); assertFalse(ShortLeg.isShort(null, 1000.0)); assertFalse(ShortLeg.isShort(Double.NaN, 1000.0))
        assertEquals(ShortLeg.OnFire.QUIET, ShortLeg.onFire(30.0, true)); assertEquals(ShortLeg.OnFire.QUIET, ShortLeg.onFire(300.0, true))
        assertEquals(ShortLeg.OnFire.QUIET, ShortLeg.onFire(10.0, false)); assertEquals(ShortLeg.OnFire.WAIT, ShortLeg.onFire(30.0, false))
        assertEquals(ShortLeg.OnFire.WAIT, ShortLeg.onFire(59.0, false)); assertEquals(ShortLeg.OnFire.RING, ShortLeg.onFire(60.0, false))
        assertEquals(ShortLeg.OnFire.RING, ShortLeg.onFire(900.0, false))
    }

    @Test fun quietWord() {
        assertFalse(ShortLeg.noticeDue(30.0, false, true, 40.0, 200.0, 530.0)); assertTrue(ShortLeg.noticeDue(70.0, false, true, 200.0, 400.0, 530.0))
        assertTrue(ShortLeg.noticeDue(70.0, false, false, 80.0, 400.0, 530.0)); assertFalse(ShortLeg.noticeDue(70.0, false, false, 200.0, 100.0, 530.0))
        assertTrue(ShortLeg.noticeDue(70.0, false, false, null, 250.0, 530.0)); assertFalse(ShortLeg.noticeDue(70.0, false, false, null, 400.0, 530.0))
        assertFalse(ShortLeg.noticeDue(70.0, true, true, 10.0, 10.0, 530.0))
        assertEquals("Get off at the next stop" to "Station is next. A short ride: this is your reminder, no alarm.", ShortLeg.words("Station"))
    }

    @Test fun shortLegArrive() {
        assertEquals(200.0, ShortLeg.arriveMetres(380.0), 0.0); assertEquals(265.0, ShortLeg.arriveMetres(530.0), 0.0)
        assertEquals(450.0, ShortLeg.arriveMetres(2000.0), 0.0); assertEquals(450.0, ShortLeg.arriveMetres(null), 0.0)
        assertFalse(ShortLeg.mayArrive(20.0, 100.0, 380.0)); assertFalse(ShortLeg.mayArrive(90.0, 300.0, 380.0)); assertTrue(ShortLeg.mayArrive(90.0, 150.0, 380.0))
    }

    @Test fun plannedNextAmong() {
        val onRoad = listOf("ic-other-5400", "ic-planned-8400", "bus-4")
        assertEquals("ic-planned-8400", NextLegGuard.plannedNextAmong(onRoad, "ic-planned-8400"))
        assertNull(NextLegGuard.plannedNextAmong(onRoad, "ic-elsewhere")); assertNull(NextLegGuard.plannedNextAmong(onRoad, null))
        assertNull(NextLegGuard.plannedNextAmong(onRoad, "")); assertNull(NextLegGuard.plannedNextAmong(emptyList(), "ic-planned-8400"))
    }

    private fun dutch(y: Int, mo: Int, d: Int, h: Int, mi: Int) = ZonedDateTime.of(y, mo, d, h, mi, 0, 0, ZoneId.of("Europe/Amsterdam")).toEpochSecond().toDouble()

    @Test fun ovapiKeyAndNoMatch() {
        assertEquals("400100123", RealPositions.key("20261201_22:40_nl-OpenOV_400100123")); assertNull(RealPositions.key("20261201_22:40_nl-other_123"))
        assertEquals("nl-OpenOV", RealPositions.dataset("20261201_22:40_nl-OpenOV_400100123")); assertNull(RealPositions.dataset("no-date-here"))
        val id = "20261201_22:40_nl-OpenOV_400100123"
        assertEquals("no ovapi match for trip_id 400100123 (started 22:40)", RealPositions.noMatchReason(id, "400100123", dutch(2026, 12, 1, 23, 5)))
        assertEquals("no ovapi match for trip_id 400100123: not started yet, starts 22:40", RealPositions.noMatchReason(id, "400100123", dutch(2026, 12, 1, 22, 30)))
        assertEquals("no ovapi match for trip_id 77", RealPositions.noMatchReason("odd-id", "77", dutch(2026, 12, 1, 22, 30)))
        val s = RealPositions.startTime("20261201_24:10_nl-OpenOV_400100200")
        assertEquals("24:10", s?.second); assertEquals(dutch(2026, 12, 2, 0, 10), s!!.first, 0.0)
        assertNull(RealPositions.startTime("20261201_xx_nl-OpenOV_1"))
    }
}
