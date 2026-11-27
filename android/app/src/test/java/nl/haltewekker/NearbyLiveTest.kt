package nl.haltewekker

import nl.haltewekker.data.DoorTrip
import nl.haltewekker.data.Ride
import nl.haltewekker.travel.NearbyLive
import nl.haltewekker.travel.NearbyLive.Leg
import nl.haltewekker.travel.NearbyLive.Shown
import nl.haltewekker.travel.NearbyLive.Update
import nl.haltewekker.travel.NearbyStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** iOS 0.42.7 `NearbyLiveTests`, the same vectors (minutes after 2026-11-27 00:00 UTC). */
class NearbyLiveTest {
    private val base = 1_795_737_600.0
    private fun hm(h: Int, m: Int) = base + (h * 60.0 + m) * 60

    private val bus5 = Leg("5-1438", hm(14, 38), hm(14, 38), hm(14, 52), hm(14, 52), true, "Breda, Centraal Station")
    private val train = Leg("ic-3600", hm(15, 4), hm(15, 4), hm(16, 0), hm(16, 0), true, "Eindhoven Centraal")

    @Test fun timeShownIsLiveWhenPresent() {
        assertEquals(Shown(hm(14, 41), hm(14, 38), "+3", true), NearbyLive.shown(hm(14, 41), hm(14, 38), true, false))
        assertEquals(Shown(hm(14, 38), null, "live", false), NearbyLive.shown(hm(14, 38), hm(14, 38), true, false))
        assertEquals(Shown(hm(14, 38), null, "timetable", false), NearbyLive.shown(hm(14, 38), hm(14, 38), false, false))
        assertEquals("-1", NearbyLive.shown(hm(14, 37), hm(14, 38), true, false).word)
        assertEquals("cancelled", NearbyLive.shown(hm(14, 41), hm(14, 38), true, true).word)
    }

    @Test fun aNewerUpdateMovesTheLegByItsDelay() {
        val u = Update("5-1438", 180.0, live = true, asOf = hm(14, 37))
        val l = NearbyLive.apply(bus5, u, hm(14, 33))
        assertEquals(hm(14, 41), l.departure, 0.0)
        assertEquals(hm(14, 55), l.arrival, 0.0)
        assertEquals(true, l.live)
        assertEquals(l, NearbyLive.apply(l, u, hm(14, 33)))
        assertEquals(bus5, NearbyLive.apply(bus5, u, hm(14, 38)))
        assertEquals(bus5, NearbyLive.apply(bus5, u.copy(live = false), hm(14, 33)))
        assertEquals(bus5, NearbyLive.apply(bus5, u.copy(tripId = "x"), hm(14, 33)))
        val a = Update("5-1438", 180.0, 60.0, "Breda, Centraal Station", true, hm(14, 37))
        assertEquals(hm(14, 53), NearbyLive.apply(bus5, a, hm(14, 33)).arrival, 0.0)
    }

    @Test fun anUpdateFromAnotherStopOfTheSameTripFits() {
        val there = Leg("5-1438", hm(14, 43), hm(14, 40), hm(14, 55), hm(14, 52), true, "Breda, Centraal Station")
        val l = NearbyLive.apply(bus5, NearbyLive.update(there, hm(14, 37)), hm(14, 33))
        assertEquals(hm(14, 41), l.departure, 0.0)
        assertEquals(hm(14, 55), l.arrival, 0.0)
    }

    @Test fun theWholeTripMovesWithItsLegs() {
        val ups = NearbyLive.merge(emptyMap(), listOf(Update("5-1438", 180.0, live = true, asOf = hm(14, 37))))
        val r = NearbyLive.trip(hm(14, 30), hm(16, 5), listOf(bus5, train), ups, hm(14, 33))
        assertEquals(hm(14, 33), r.start, 0.0)
        assertEquals(hm(16, 5), r.end, 0.0)
        assertEquals(hm(14, 41), r.legs[0].departure, 0.0)
        val late = NearbyLive.merge(ups, listOf(Update("ic-3600", 300.0, 420.0, "Eindhoven Centraal", true, hm(14, 37))))
        assertEquals(hm(16, 12), NearbyLive.trip(hm(14, 30), hm(16, 5), listOf(bus5, train), late, hm(14, 33)).end, 0.0)
    }

    @Test fun mergeKeepsTheNewestLiveOne() {
        val a = Update("t", 60.0, live = true, asOf = hm(14, 30))
        val b = Update("t", 180.0, live = true, asOf = hm(14, 35))
        val old = Update("t", 0.0, live = true, asOf = hm(14, 20))
        val plan = Update("t", 0.0, live = false, asOf = hm(14, 40))
        assertEquals(b, NearbyLive.merge(emptyMap(), listOf(a, b, old, plan))["t"])
    }

    @Test fun fastestByLiveArrival() {
        assertEquals(0, NearbyLive.fastest(listOf(hm(16, 5), hm(16, 8)), listOf(2, 1), listOf(hm(14, 38), hm(14, 45))))
        assertEquals(1, NearbyLive.fastest(listOf(hm(16, 12), hm(16, 8)), listOf(2, 1), listOf(hm(14, 41), hm(14, 45))))
        assertEquals(1, NearbyLive.fastest(listOf(hm(16, 8), hm(16, 8)), listOf(2, 1), listOf(hm(14, 41), hm(14, 30))))
        assertEquals(0, NearbyLive.fastest(listOf(hm(16, 8), hm(16, 8)), listOf(1, 1), listOf(hm(14, 41), hm(14, 30))))
        assertNull(NearbyLive.fastest(emptyList(), emptyList(), emptyList()))
    }

    @Test fun theStoreFreshensItsWaysByTheBoard() {
        val s = NearbyStore("dest", emptyList())
        val r = Ride(tripId = "5-1438", line = "5", name = "5", isTrain = false, departure = hm(14, 38), scheduledDeparture = hm(14, 38),
            arrival = hm(14, 52), scheduledArrival = hm(14, 52), fromStop = "St.Ignatiusstraat", fromId = "a", toStop = "Breda, Centraal Station", live = true)
        val t = DoorTrip(listOf(r), hm(14, 33), hm(14, 58))
        s.freshen(listOf(NearbyLive.update(board = "5-1438", time = hm(14, 41), scheduled = hm(14, 38), live = true, asOf = hm(14, 37))))
        val f = s.fresh(t)
        assertEquals(hm(14, 41), f.first.departure, 0.0)
        assertEquals(3, f.first.delay)
        assertEquals(hm(14, 36), f.start, 0.0)
        assertEquals(hm(15, 1), f.end, 0.0)
    }
}
