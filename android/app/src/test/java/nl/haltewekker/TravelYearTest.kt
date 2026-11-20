package nl.haltewekker

import nl.haltewekker.friends.ScoreTrip
import nl.haltewekker.travel.RideRecord
import nl.haltewekker.travel.TravelLog
import nl.haltewekker.travel.TravelStats
import nl.haltewekker.travel.TravelYear
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.ZoneId

/** iOS `TravelYearTests` (0.35). */
class TravelYearTest {
    private val t0 = 1_800_000_000.0
    private val zone = ZoneId.of("Europe/Amsterdam")
    private fun t(s: Double) = t0 + s
    private val day = 86400.0

    private fun ride(id: String, trip: Double, dep: Double, mins: Double, train: Boolean, label: String, from: String, km: Double, late: Double? = null, coach: Int? = null) =
        RideRecord(id, trip, dep, dep + mins * 60, train, label, from, "x", km, late, coach)

    private val rides: List<RideRecord> get() {
        val d1 = t(-2 * day - 2 * 3600); val d2 = t(-day - 2 * 3600 - 19 * 60)
        return listOf(ride("a", d1, d1, 30.0, false, "Bus 305", "Veghel, Busstation", 20.0),
            ride("b", d1, d1 + 40 * 60, 45.0, true, "Intercity", "'s-Hertogenbosch", 50.0, coach = 3),
            ride("c", d2, d2, 30.0, false, "Bus 305", "Veghel, Busstation", 20.0, late = 4.0),
            ride("d", d2, d2 + 45 * 60, 50.0, true, "Intercity", "'s-Hertogenbosch", 50.0, late = 23.0, coach = 3))
    }

    @Test fun co2() {
        assertEquals(22.6, TravelYear.co2Saved(40.0, 100.0), 0.0001)
        assertEquals(0.0, TravelYear.co2Saved(-5.0, 0.0), 0.0)
        assertEquals(13.0, TravelYear.km(10_000.0, false), 0.0001)
        assertEquals(11.5, TravelYear.km(10_000.0, true), 0.0001)
    }

    @Test fun stats() {
        val old = ScoreTrip("Via Den Bosch", false, 60.0, t(-30 * day))
        val s = TravelYear.stats(rides, listOf(old), listOf(t(-day), t(-400 * day)), t0, zone)
        assertEquals(4, s.rides); assertEquals(3, s.trips)
        assertEquals(60.0, s.busMinutes, 1e-9); assertEquals(95.0, s.trainMinutes, 1e-9); assertEquals(60.0, s.earlierMinutes, 0.0)
        assertEquals(140.0, s.km, 0.0)
        assertEquals(TravelStats.Fav("Intercity", 2), s.line)
        assertEquals(TravelStats.Fav("Coach 3", 2), s.coach)
        assertEquals(TravelStats.Delay("Intercity", 23.0, rides[3].dep), s.delay)
        assertEquals(rides[2].dep, s.earliest!!, 0.0)
        assertEquals(1, s.friends); assertFalse(s.fullYear)
        assertEquals(t(-30 * day - 3600), s.since!!, 0.0)
    }

    @Test fun cards() {
        val s = TravelYear.stats(rides, emptyList(), listOf(t(-day)), t0, zone)
        val cards = TravelYear.cards(s, zone)
        assertEquals(listOf("intro", "hours", "km", "co2", "favourite", "early", "delay", "friends"), cards.map { it.id })
        assertEquals("Your travel so far", cards[0].title); assertEquals("2 trips", cards[0].value)
        assertEquals("Since Wed 13 Jan, on buses and trains.", cards[0].sub)
        assertEquals("3 h", cards[1].value); assertEquals("2 h by train · 1 h by bus.", cards[1].sub)
        assertEquals("140 km", cards[2].value); assertEquals("23 kg", cards[3].value)
        assertEquals("Intercity", cards[4].value)
        assertEquals("2 rides · most often from 's-Hertogenbosch · coach 3 on the train.", cards[4].sub)
        assertEquals("2 rides · coach 3 on the train.", cards[4].shareSub)
        assertEquals("06:41", cards[5].value)
        assertEquals("The Intercity on Thu 14 Jan. You made it anyway.", cards[6].sub)
        assertEquals("1 ride", cards[7].value)
        assertEquals(emptyList<Any>(), TravelYear.cards(TravelStats(), zone))
    }

    @Test fun fullYearAndWords() {
        val first = ride("z", t(-370 * day), t(-370 * day), 20.0, false, "Bus 305", "A", 10.0)
        val s = TravelYear.stats(listOf(first) + rides, emptyList(), emptyList(), t0, zone)
        assertTrue(s.fullYear); assertEquals(4, s.rides)
        assertEquals("Your year in travel", TravelYear.cards(s, zone).first().title)
        assertEquals("1,240", TravelYear.grouped(1240)); assertEquals("999", TravelYear.grouped(999)); assertEquals("1,000,000", TravelYear.grouped(1_000_000))
        assertEquals("30 min", TravelYear.hours(0.5)); assertEquals("38 h", TravelYear.hours(37.6))
    }

    @Test fun seasonal() {
        val dec = 1_796_202_000.0
        assertEquals(2026, TravelYear.seasonal(dec, dec - 60 * day, 5, null, zone))
        assertNull(TravelYear.seasonal(dec, null, 4, null, zone))
        assertNull(TravelYear.seasonal(dec, null, 9, 2026, zone))
        assertNull(TravelYear.seasonal(t0, t(-100 * day), 9, null, zone))
        assertEquals(2027, TravelYear.seasonal(t0, t(-370 * day), 9, 2026, zone))
        assertNull(TravelYear.seasonal(t0, t(-380 * day), 9, null, zone))
    }

    @Test fun logKeeps() {
        var list = emptyList<RideRecord>()
        list = TravelLog.add(list, rides[1], t0); list = TravelLog.add(list, rides[0], t0); list = TravelLog.add(list, rides[0], t0)
        assertEquals(listOf("a", "b"), list.map { it.id })
        val ancient = ride("old", t(-900 * day), t(-900 * day), 10.0, false, "Bus 1", "A", 1.0)
        assertEquals(listOf("a", "b"), TravelLog.add(list, ancient, t0).map { it.id })
    }
}
