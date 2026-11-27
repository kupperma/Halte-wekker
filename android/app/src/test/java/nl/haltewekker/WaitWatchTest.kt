package nl.haltewekker

import nl.haltewekker.core.GeoPoint
import nl.haltewekker.data.DoorTrip
import nl.haltewekker.data.Ride
import nl.haltewekker.ride.WaitStart
import nl.haltewekker.ride.WaitWatch
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * (0.10.3, iOS 0.42.4) Fastest trip's watching as plain state (`WaitWatch`): it belongs to the watching, not to a
 * screen. Nothing in it takes the screen: it starts, looks and stops the same whatever is in front; only its first log
 * line says where the app was.
 */
class WaitWatchTest {
    private val t0 = 7_000_000.0
    private val home = GeoPoint(51.6170, 5.5440)
    private val school = GeoPoint(51.4430, 5.4800)

    private fun ride(trip: String, line: String, dep: Double, arr: Double, from: GeoPoint, to: GeoPoint) =
        Ride(trip, line, line, false, dep, dep, arr, arr, "A", "a", "B", fromLat = from.lat, fromLon = from.lon, toLat = to.lat, toLon = to.lon)

    private val change = GeoPoint(51.60, 5.52)
    private val way = DoorTrip(listOf(ride("trip-0952", "305", t0 + 600, t0 + 1500, home, change),
        ride("trip-0400", "400", t0 + 1800, t0 + 2400, GeoPoint(51.601, 5.521), school)), t0 + 300, t0 + 2500)
    private val req = WaitWatch.Request("School", "school-id", school, listOf(way))

    @Test fun beginsAndEnds_withItsLines_whateverIsOnScreen() {
        val (on, line) = WaitWatch.begin(WaitWatch.State(), t0, inFront = true, watchedFirst = way.first.departure)
        assertTrue(on.watching)
        assertEquals("wait · watching on · its look at what you get on runs (in front)", line)
        // the screen goes (another screen, the phone locked): nothing to call, it still watches, its looks go on
        val looked = WaitWatch.paced(on, fast = false, moving = WaitStart.Moving(0.0, 0.0), key = null, now = t0 + 6)
        assertTrue(looked.watching)
        assertEquals(WaitWatch.EVERY, WaitWatch.nextLook(looked, fast = false, progress = 0, now = t0 + 6), 0.0)
        // another destination: watching again
        assertEquals("wait · watching again · its look at what you get on runs (behind the screen)",
            WaitWatch.begin(looked, t0 + 60, inFront = false, watchedFirst = null).second)
        val (off, offLine) = WaitWatch.end(looked, "the trip started")
        assertFalse(off.watching)
        assertEquals("wait · watching off · the trip started", offLine)
        // stopping what doesn't watch says nothing
        assertNull(WaitWatch.end(off, "closed").second)
    }

    @Test fun looksEvery6s_forTheFirst3MinutesAtBusSpeed_thenBacksOff() {
        var s = WaitWatch.begin(WaitWatch.State(), t0, inFront = false, watchedFirst = null).first
        val fastMove = WaitStart.Moving(40.0, 9.0)
        var t = t0
        val waits = ArrayList<Double>()
        while (t <= t0 + 300) {
            s = WaitWatch.paced(s, fast = true, moving = fastMove, key = "trip-3306", now = t)
            val w = WaitWatch.nextLook(s, fast = true, progress = 0, now = t)
            waits.add(w)
            t += w
        }
        assertTrue("every 6 s in the first 3 minutes", waits.takeWhile { it == 6.0 }.size >= 30)
        assertEquals("then the back-off up to 30 s", 30.0, waits.last(), 0.0)
        // one on its way to starting keeps them at 6 s
        assertEquals(6.0, WaitWatch.nextLook(s, fast = true, progress = 1, now = t), 0.0)
        // a stop on the way keeps the 3 minutes going (some steps still at speed); standing ends them
        val stopped = WaitWatch.paced(s, fast = false, moving = WaitStart.Moving(20.0, 0.0), key = null, now = t)
        assertEquals(s.fastSince, stopped.fastSince)
        assertNull(WaitWatch.paced(s, fast = false, moving = WaitStart.Moving(0.0, 0.0), key = null, now = t).fastSince)
    }

    @Test fun stopsByItself_threeHours_gone_there() {
        val s = WaitWatch.begin(WaitWatch.State(), t0, inFront = true, watchedFirst = way.first.departure).first
        assertNull(WaitWatch.autoStop(s, home, 10.0, school, t0 + 60))
        assertEquals("after 3 hours", WaitWatch.autoStop(s, home, 10.0, school, t0 + 3 * 3600 + 1))
        // the one it watched first left 20 minutes ago and you stayed here
        val stayed = WaitWatch.moved(WaitWatch.moved(s, home, 10.0), GeoPoint(51.6175, 5.5445), 10.0)
        assertEquals("the trip you waited for has gone", WaitWatch.autoStop(stayed, home, 10.0, school, way.first.departure + 20 * 60))
        // you went (more than 300 m): it keeps watching
        val went = WaitWatch.moved(stayed, GeoPoint(51.60, 5.52), 10.0)
        assertNull(WaitWatch.autoStop(went, GeoPoint(51.60, 5.52), 10.0, school, way.first.departure + 20 * 60))
        assertEquals("you're there", WaitWatch.autoStop(went, GeoPoint(51.4440, 5.4805), 20.0, school, t0 + 600))
        // a rough fix near it isn't
        assertNull(WaitWatch.autoStop(went, GeoPoint(51.4440, 5.4805), 300.0, school, t0 + 600))
        assertNull(WaitWatch.autoStop(WaitWatch.State(), home, 10.0, school, t0 + 4 * 3600))
    }

    @Test fun takesYouOnTo_theDestination_theFirstRidesStop_laterRidesStops() {
        val targets = WaitWatch.targets(req)
        assertEquals(listOf(school, change, GeoPoint(51.601, 5.521)), targets)
    }

    @Test fun theWayOnScreen_aLongWayRound_atItsStop_theNearbySearch() {
        assertEquals(way, WaitWatch.wayOn(req, "trip-0952"))
        assertNull(WaitWatch.wayOn(req, "trip-2718"))
        assertNull(WaitWatch.wayOn(null, "trip-0952"))
        assertFalse("the same line is never a long way round", WaitWatch.longWayRound(way, "305", way.end + 3600))
        assertTrue(WaitWatch.longWayRound(way, "150", way.end + 31 * 60))
        assertFalse(WaitWatch.longWayRound(way, "150", way.end + 29 * 60))
        assertTrue(WaitWatch.atItsStop(500.0, 20.0))
        assertFalse(WaitWatch.atItsStop(700.0, 20.0))
        assertTrue(WaitWatch.atItsStop(700.0, 300.0))
        assertFalse(WaitWatch.atItsStop(null, 10.0))
        assertTrue(WaitWatch.nearbySearches(atVehicleSpeed = false))
        assertFalse(WaitWatch.nearbySearches(atVehicleSpeed = true))
    }
}
