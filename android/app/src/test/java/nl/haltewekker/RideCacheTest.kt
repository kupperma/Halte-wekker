package nl.haltewekker

import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.ride.RideCache
import nl.haltewekker.ride.SavedRide
import nl.haltewekker.ride.SavedTrip
import nl.haltewekker.ride.WalkPlan
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** iOS `RideCacheTests` (0.39) and `WalkPlanTests` (0.40). */
class RideCacheTest {
    private val t0 = 1_800_000_000.0
    private fun at(m: Double) = t0 + m * 60

    private fun ride(id: String, stops: Int = 4, shape: Int = 10, saved: Double? = null, live: Boolean = true): SavedRide {
        val st = (0 until stops).map { i -> SavedRide.Stop("S$i", 51.6 + i * 0.01, 5.3, at(i * 5 + 1.0), at(i * 5 + 2.0), at(i * 5.0), if (i == stops - 1) "5" else null) }
        val path = (0 until shape).map { GeoPoint(51.6 + it * 0.001, 5.3) }
        return SavedRide(id, "IC", isTrain = true, live = live, savedAt = saved ?: t0, stops = st, shape = path)
    }

    @Test fun thinKeepsTheEndsAndTheBound() {
        val path = (0 until 1000).map { GeoPoint(it.toDouble(), 0.0) }
        val t = RideCache.thin(path, 50)
        assertEquals(50, t.size); assertEquals(path.first(), t.first()); assertEquals(path.last(), t.last())
        assertEquals(30, RideCache.thin(path.take(30), 50).size)
    }

    @Test fun boundedStopsAndShape() {
        val b = RideCache.bounded(ride("a", 300, 5000))
        assertEquals(RideCache.MAX_STOPS, b.stops.size); assertEquals(RideCache.MAX_SHAPE, b.shape.size)
    }

    @Test fun putReplacesKeepsTheNewestAndDropsAnotherTrip() {
        var s = RideCache.put(ride("a"), null, t0)
        s = RideCache.put(ride("b"), s, t0)
        s = RideCache.put(ride("a", saved = at(3.0)), s, t0)
        assertEquals(listOf("b", "a"), s.rides.map { it.tripId })
        assertEquals(at(3.0), s.rides.last().savedAt, 0.0)
        for (k in 0 until 6) s = RideCache.put(ride("x$k"), s, t0)
        assertEquals(RideCache.MAX_RIDES, s.rides.size); assertEquals("x5", s.rides.last().tripId)
        assertEquals(listOf("c"), RideCache.put(ride("c"), s, at(60.0)).rides.map { it.tripId })
    }

    @Test fun rideOnlyForTheRunningTripAndNotTooOld() {
        val s = RideCache.put(ride("a"), null, t0)
        assertNotNull(RideCache.ride("a", s, t0, at(10.0)))
        assertNull(RideCache.ride("a", s, at(1.0), at(10.0)))
        assertNull(RideCache.ride("a", s, null, at(10.0)))
        assertNull(RideCache.ride("b", s, t0, at(10.0)))
        assertNull(RideCache.ride("a", s, t0, t0 + RideCache.MAX_AGE + 1))
        assertTrue(RideCache.keep(s, t0, at(10.0))); assertFalse(RideCache.keep(s, null, at(10.0)))
    }

    @Test fun encodeStaysWithinBytes() {
        var s = SavedTrip(t0)
        for (k in 0 until RideCache.MAX_RIDES) s = RideCache.put(ride("r$k", 120, 400), s, t0)
        val d = RideCache.encode(s)!!
        assertTrue(d.toByteArray().size <= RideCache.MAX_BYTES)
        val back = RideCache.decode(d)!!
        assertTrue(back.rides.isNotEmpty())
        assertEquals(s.rides.last(), back.rides.last())
    }

    @Test fun timesStopsAndDelay() {
        val r = ride("a")
        val t = RideCache.times(r)
        assertEquals(at(2.0), t.first()!!, 0.0); assertEquals(at(16.0), t.last()!!, 0.0)
        assertEquals(3, RideCache.stop(GeoPoint(51.63, 5.3), r))
        assertNull(RideCache.stop(GeoPoint(52.5, 5.3), r))
        assertNull(RideCache.stop(GeoPoint(51.6, 5.3), r, after = 3))
        assertEquals(1, RideCache.delay(r, 3)); assertEquals(2, RideCache.delay(r, 0))
        assertNull(RideCache.delay(ride("b", live = false), 3))
        assertEquals("5", r.stops[3].platform)
    }

    @Test fun dueAndBackOnline() {
        assertTrue(RideCache.due(null, t0)); assertFalse(RideCache.due(t0, at(1.0))); assertTrue(RideCache.due(t0, at(2.0)))
        assertTrue(RideCache.backOnline(true, true)); assertFalse(RideCache.backOnline(false, true)); assertFalse(RideCache.backOnline(true, false))
    }

    // WalkPlanTests
    @Test fun walk_nothingLearned() {
        assertEquals(WalkPlan.Shown(10, 0, 0, false), WalkPlan.shown(10, 700.0, 1.6, 4, 1.2))
        val none = WalkPlan.shown(10, 700.0, null, 9, 1.2)
        assertFalse(none.learned); assertEquals(0, none.later)
    }

    @Test fun walk_fasterWalker() {
        val s = WalkPlan.shown(10, 570.0, 1.6, 12, 1.2)
        assertEquals(6, s.walk); assertEquals(2, s.spare); assertEquals(2, s.later)
        assertEquals(120.0, WalkPlan.leave(t0, s) - t0, 0.0)
        val m = WalkPlan.shown(10, null, 1.55, 5, 1.2)
        assertEquals(8, m.walk); assertEquals(0, m.later); assertEquals(2, m.spare)
        val slow = WalkPlan.shown(6, 600.0, 0.9, 20, 1.2)
        assertEquals(6, slow.walk); assertEquals(0, slow.later)
    }

    @Test fun walk_neverLaterThanTheDifferenceLessTheSpare() {
        for (planned in 1..25) {
            var metres = 50.0
            while (metres <= 2000) {
                val s = WalkPlan.shown(planned, metres, 1.9, 10, 1.2)
                assertTrue(s.later <= maxOf(0, planned - s.walk - WalkPlan.SPARE)); assertTrue(s.later >= 0)
                assertEquals(planned, s.walk + s.spare + s.later)
                metres += 75
            }
        }
    }

    @Test fun walk_words() {
        val s = WalkPlan.Shown(6, 2, 2, true)
        assertEquals("6 min walk · leave in 4 min (2 min spare)", WalkPlan.words(s, 4, null))
        assertEquals("6 min walk · leave by 08:04 (2 min spare)", WalkPlan.words(s, null, "08:04"))
        assertEquals("6 min walk · leave now (2 min spare)", WalkPlan.words(s, 0, null))
        assertEquals("10 min walk", WalkPlan.words(WalkPlan.Shown(10, 0, 0, false), null, null))
        assertEquals(0, WalkPlan.walk(0, 30.0, 1.5, 10, 1.2))
    }
}
