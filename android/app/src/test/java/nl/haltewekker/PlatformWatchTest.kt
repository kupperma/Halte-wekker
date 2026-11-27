package nl.haltewekker

import nl.haltewekker.data.DoorTrip
import nl.haltewekker.data.Ride
import nl.haltewekker.ride.PlatformWatch
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** (0.10.1) Every train of the trip is watched for a new platform or a cancellation, from the planner's platform on. */
class PlatformWatchTest {
    private val now = 1_800_000_000.0
    private fun ride(id: String, train: Boolean, from: String, dep: Double, plat: String? = null, planned: String? = null, num: String = "") =
        Ride(id, if (train) "IC" else "305", if (train) "Intercity" else "305", train, dep, dep, dep + 1800, dep + 1800, from, "s:$from", "Next",
            platform = plat, plannedPlatform = planned, num = num, headsign = "Breda")
    private val trip = DoorTrip(listOf(
        ride("bus", false, "Veghel", now - 600),
        ride("ic1", true, "Eindhoven Centraal", now + 900, plat = "5", num = "3512"),
        ride("ic2", true, "Breda", now + 4000, planned = "3", num = "1144"),
        ride("ic3", true, "Rotterdam Centraal", now + 4 * 3600, num = "2000"),
    ), now - 900, now + 5 * 3600)
    private val code: (Ride) -> String? = { r -> mapOf("Eindhoven Centraal" to "EHV", "Breda" to "BD", "Rotterdam Centraal" to "RTD")[r.fromStop] }

    @Test fun whichLegs() {
        // on the bus: both trains within 3 hours (not the bus, not the one 4 hours on)
        assertEquals(listOf(1 to "EHV", 2 to "BD"), PlatformWatch.legs(trip, 0, boarded = true, now = now, code = code))
        // waiting at the change for the first train: it too (not boarded yet)
        assertEquals(listOf(1 to "EHV", 2 to "BD"), PlatformWatch.legs(trip, 1, boarded = false, now = now, code = code))
        // on it: only the ones after it
        assertEquals(listOf(2 to "BD"), PlatformWatch.legs(trip, 1, boarded = true, now = now, code = code))
        // a train that left more than 10 minutes ago: no more (up to 10: a late one is still to come)
        assertEquals(listOf(1 to "EHV", 2 to "BD"), PlatformWatch.legs(trip, 1, boarded = false, now = now + 900 + 9 * 60, code = code))
        assertEquals(listOf(2 to "BD"), PlatformWatch.legs(trip, 1, boarded = false, now = now + 900 + 11 * 60, code = code))
        // later on, the far one comes within 3 hours
        assertEquals(listOf(3 to "RTD"), PlatformWatch.legs(trip, 3, boarded = false, now = now + 2 * 3600, code = code))
        // not an NS station: not watched
        assertTrue(PlatformWatch.legs(trip, 0, true, now) { null }.isEmpty())
    }

    @Test fun seededWithThePlannedPlatform() {
        val w = PlatformWatch.seed(trip.rides[1], 1, "EHV", PlatformWatch.label(trip.rides[1]) { "09:15" })
        assertEquals("5", w.track)
        assertEquals("09:15 Intercity to Breda", w.label)
        assertEquals("3", PlatformWatch.seed(trip.rides[2], 2, "BD", "x").track)   // the planner's planned platform when there's no live one
        assertEquals("", PlatformWatch.seed(trip.rides[3], 3, "RTD", "x").track)
    }

    @Test fun whatToTell() {
        val w = PlatformWatch.seed(trip.rides[1], 1, "EHV", "09:15 Intercity to Breda")
        fun dep(actual: String, cancelled: Boolean = false) = PlatformWatch.Dep("3512", now + 900, "5", actual, cancelled)
        // the same platform: nothing
        assertNull(PlatformWatch.look(w, dep("5")).second)
        assertNull(PlatformWatch.look(w, dep("")).second)   // no actual platform: the planned one
        // a change before NS's first answer still counts (the watch starts at the planner's platform)
        val (w2, a) = PlatformWatch.look(w, dep("7"))
        assertEquals("Platform 7", a!!.title)
        assertEquals("Your 09:15 Intercity to Breda now leaves Eindhoven Centraal from platform 7 instead of 5.", a.body)
        assertEquals("7", w2.track)
        assertNull(PlatformWatch.look(w2, dep("7")).second)   // told once
        // cancelled: told once
        val (w3, c) = PlatformWatch.look(w2, dep("7", cancelled = true))
        assertTrue(c!!.cancelled)
        assertEquals("Your 09:15 Intercity to Breda from Eindhoven Centraal has been cancelled.", c.body)
        assertNull(PlatformWatch.look(w3, dep("7", cancelled = true)).second)
        // "5" and "5b" are the same platform (the plan often leaves the part out)
        assertNull(PlatformWatch.look(w, dep("5b")).second)
        assertTrue(PlatformWatch.same("5", "5B"))
        assertTrue(!PlatformWatch.same("5a", "5b") && !PlatformWatch.same("5", "15"))
        // no platform to start from: NS's own planned one is what it was
        val empty = w.copy(track = "")
        val (w4, none) = PlatformWatch.look(empty, PlatformWatch.Dep("3512", now + 900, "", "8", false))
        assertNull(none)
        assertEquals("8", w4.track)
        val moved = PlatformWatch.look(empty, PlatformWatch.Dep("3512", now + 900, "5", "8", false)).second
        assertEquals("Your 09:15 Intercity to Breda now leaves Eindhoven Centraal from platform 8 instead of 5.", moved!!.body)
        // on the trip: the leg gets it
        assertEquals("7", PlatformWatch.applied(trip, a).rides[1].platform)
        assertTrue(PlatformWatch.applied(trip, c).rides[1].cancelled)
    }

    @Test fun nsBoard() {
        val text = """{"payload":{"departures":[{"product":{"number":"3512"},"plannedDateTime":"2027-01-15T09:15:00+0100","plannedTrack":"5","actualTrack":"7","cancelled":false},
            {"product":{"number":"1144"},"plannedDateTime":"2027-01-15T10:22:00+0100","plannedTrack":"3","cancelled":true}]}}"""
        val list = PlatformWatch.parse(text)!!
        assertEquals(2, list.size)
        assertEquals("7", list[0].actualTrack)
        assertEquals(1800000900.0, list[0].planned!!, 0.0)
        assertTrue(list[1].cancelled)
        assertEquals("1144", PlatformWatch.match(list, "1144", 0.0)!!.num)
        assertEquals("3512", PlatformWatch.match(list, "", 1800000930.0)!!.num)
        assertNull(PlatformWatch.parse("not json"))
    }
}
