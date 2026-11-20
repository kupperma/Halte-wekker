package nl.haltewekker

import nl.haltewekker.core.GeoPoint
import nl.haltewekker.travel.CheckOut
import nl.haltewekker.travel.DelayClaim
import nl.haltewekker.travel.LastTrip
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter

/** iOS `TravelHelpTests` (0.36): check-out, money back for a late train, the last way home. */
class TravelHelpTest {
    private val ams = ZoneId.of("Europe/Amsterdam")
    private fun at(y: Int, m: Int, d: Int, h: Int, min: Int = 0) = ZonedDateTime.of(y, m, d, h, min, 0, 0, ams).toEpochSecond().toDouble()
    private val hhmm: (Double) -> String = { DateTimeFormatter.ofPattern("HH:mm").withZone(ams).format(Instant.ofEpochSecond(it.toLong())) }

    @Test fun checkOutEndAndChanges() {
        val bus = CheckOut.Ride(false); val ns = CheckOut.Ride(true, "NS"); val arriva = CheckOut.Ride(true, "Arriva"); val train = CheckOut.Ride(true)
        assertTrue(CheckOut.due(0, listOf(bus)))
        assertTrue(CheckOut.due(0, listOf(train, bus)))
        assertTrue(CheckOut.due(0, listOf(bus, train)))
        assertTrue(CheckOut.due(0, listOf(bus, bus)))
        assertFalse(CheckOut.due(0, listOf(ns, ns)))
        assertFalse(CheckOut.due(0, listOf(train, train)))
        assertTrue(CheckOut.due(0, listOf(ns, arriva)))
        assertTrue(CheckOut.due(1, listOf(ns, ns)))
        assertFalse(CheckOut.due(2, listOf(ns, ns)))
        assertFalse(CheckOut.due(-1, listOf(ns)))
    }

    @Test fun checkOutStillAboard() {
        assertTrue(CheckOut.stillAboard(emptyList(), true))
        assertTrue(CheckOut.stillAboard(listOf(12.0, 9.5), false))
        assertFalse(CheckOut.stillAboard(listOf(12.0, 1.2), false))
        assertFalse(CheckOut.stillAboard(listOf(1.4, 1.3, Double.NaN), false))
        assertEquals(60.0, CheckOut.AFTER, 0.0)
    }

    @Test fun checkOutWords() {
        assertEquals("Did you check out?", CheckOut.text("Breda").first)
        assertTrue(CheckOut.text("Breda").second.contains("You’re at Breda"))
        assertTrue(CheckOut.text("Breda", true to false).second.contains("from train to bus"))
        assertTrue(CheckOut.text("Tilburg", true to true).second.contains("train company"))
    }

    @Test fun claimThreshold() {
        assertFalse(DelayClaim.due(29.0, false)); assertTrue(DelayClaim.due(30.0, false)); assertTrue(DelayClaim.due(29.6, false))
        assertTrue(DelayClaim.due(34.0, false)); assertFalse(DelayClaim.due(34.0, true))
        assertFalse(DelayClaim.due(null, false)); assertFalse(DelayClaim.due(Double.NaN, false))
    }

    @Test fun claimLateness() {
        val p = at(2026, 11, 20, 8, 30)
        assertEquals(32.0, DelayClaim.minutesLate(p, p + 32 * 60, listOf(8.0, 0.0))!!, 1e-9)
        assertEquals(34.0, DelayClaim.minutesLate(null, null, listOf(12.0, 34.0))!!, 0.0)
        assertEquals(3.0, DelayClaim.minutesLate(p, p - 60, listOf(3.0))!!, 0.0)
        assertNull(DelayClaim.minutesLate(null, null, emptyList()))
        assertEquals(1.0, DelayClaim.minutesLate(p, p + 32 * 60, listOf(1.0, 0.0))!!, 0.0)
        assertNull(DelayClaim.minutesLate(p, p + 32 * 60, emptyList()))
    }

    @Test fun claimWords() {
        val t = DelayClaim.text(34.2)
        assertEquals("Your train was 34 min late — you can claim money back from NS", t.first)
        assertTrue(t.second.contains("half the fare"))
        assertTrue(DelayClaim.text(61.0).second.contains("whole fare"))
        assertTrue(DelayClaim.CLAIM_URL.startsWith("https://www.ns.nl/"))
    }

    @Test fun lastTripWhenWanted() {
        assertFalse(LastTrip.wanted(at(2026, 11, 20, 19, 59), 10_000.0))
        assertTrue(LastTrip.wanted(at(2026, 11, 20, 20, 0), 10_000.0))
        assertTrue(LastTrip.wanted(at(2026, 11, 21, 1, 0), 10_000.0))
        assertFalse(LastTrip.wanted(at(2026, 11, 21, 4, 0), 10_000.0))
        assertFalse(LastTrip.wanted(at(2026, 11, 20, 22, 0), 2_900.0))
        assertFalse(LastTrip.wanted(at(2026, 11, 20, 22, 0), null))
    }

    @Test fun lastTripArriveByTimes() {
        assertEquals(listOf(at(2026, 11, 21, 4), at(2026, 11, 21, 2), at(2026, 11, 21, 1), at(2026, 11, 21, 0)), LastTrip.arriveBy(at(2026, 11, 20, 21, 0)))
        assertEquals(listOf(at(2026, 11, 21, 4), at(2026, 11, 21, 2)), LastTrip.arriveBy(at(2026, 11, 21, 0, 50)))
    }

    @Test fun lastTripPick() {
        val now = at(2026, 11, 20, 22, 0)
        fun o(lh: Int, lm: Int, arrive: Double, cancelled: Boolean = false, dep: Double? = null): LastTrip.Option {
            val l = if (lh < 12) at(2026, 11, 21, lh, lm) else at(2026, 11, 20, lh, lm)
            return LastTrip.Option(l, dep ?: (l + 300), arrive, "Breda", cancelled)
        }
        val list = listOf(o(23, 10, at(2026, 11, 21, 0, 5)), o(0, 12, at(2026, 11, 21, 1, 5)), o(0, 12, at(2026, 11, 21, 0, 58)),
            o(0, 40, at(2026, 11, 21, 1, 30), cancelled = true), o(1, 0, at(2026, 11, 21, 6, 30), dep = at(2026, 11, 21, 1, 5)),
            o(21, 50, at(2026, 11, 20, 22, 40)))
        assertEquals(2, LastTrip.pick(list, now))
        assertNull(LastTrip.pick(emptyList(), now))
        assertEquals("Last way home leaves 00:12 from Breda", LastTrip.cardText(list[2], hhmm))
        assertEquals(at(2026, 11, 20, 23, 42), LastTrip.warnAt(list[2], now)!!, 0.0)
        assertNull(LastTrip.warnAt(list[2], at(2026, 11, 20, 23, 50)))
        assertTrue(LastTrip.notice(list[2], hhmm).second.contains("00:12"))
    }

    @Test fun lastTripRefresh() {
        val now = at(2026, 11, 20, 22, 0); val here = GeoPoint(51.59, 4.78)
        assertTrue(LastTrip.refreshDue(null, null, here, null, now))
        assertFalse(LastTrip.refreshDue(now - 1800, here, here, null, now))
        assertTrue(LastTrip.refreshDue(now - 3600, here, here, null, now))
        assertTrue(LastTrip.refreshDue(now - 600, GeoPoint(51.60, 4.78), here, null, now))
        val gone = LastTrip.Option(now - 60, now, now + 3600, "Breda")
        assertTrue(LastTrip.refreshDue(now - 600, here, here, gone, now))
    }
}
