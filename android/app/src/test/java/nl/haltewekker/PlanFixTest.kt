package nl.haltewekker

import nl.haltewekker.core.GeoPoint
import nl.haltewekker.data.DoorTrip
import nl.haltewekker.data.LiveKeep
import nl.haltewekker.data.Ride
import nl.haltewekker.data.TransitParse
import nl.haltewekker.data.WalkFirst
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

/** iOS 0.42.8 `PlanFixTests`, the same vectors (minutes after 2026-11-27 00:00 UTC). */
class PlanFixTest {
    private val base = 1_795_737_600.0
    private fun hm(h: Int, m: Int) = base + (h * 60.0 + m) * 60
    private val fmt = DateTimeFormatter.ofPattern("HH:mm").withZone(ZoneOffset.UTC)
    private val clock: (Double) -> String = { fmt.format(Instant.ofEpochSecond(it.toLong())) }

    @Test fun aLateTrainStillToLeaveIsKeptAndRankedFirst() {
        val now = hm(14, 45)
        val eindhoven = LiveKeep.Way(hm(14, 48), hm(14, 38), hm(14, 46))
        val zwolle = LiveKeep.Way(hm(14, 54), hm(14, 49), hm(14, 52))
        val gone = LiveKeep.Way(hm(14, 35), hm(14, 30), hm(14, 33))
        assertTrue(LiveKeep.keep(eindhoven, now))
        assertTrue(LiveKeep.keep(zwolle, now))
        assertFalse(LiveKeep.keep(gone, now))
        assertEquals(listOf(1, 0), LiveKeep.order(listOf(zwolle, eindhoven)))
        assertTrue(LiveKeep.keep(LiveKeep.Way(hm(14, 45) - 20, hm(14, 38), hm(14, 44)), now))
        assertFalse(LiveKeep.keep(LiveKeep.Way(hm(14, 45) - 40, hm(14, 38), hm(14, 44)), now))
        assertFalse(LiveKeep.keep(LiveKeep.Way(hm(14, 48), hm(14, 38), hm(14, 46), cancelled = true), now))
        assertFalse(LiveKeep.keep(LiveKeep.Way(hm(14, 48), hm(14, 38), hm(14, 43)), now))
    }

    @Test fun keepUsefulKeepsTheLateTrainByItsLiveTime() {
        val now = hm(14, 45)
        fun train(id: String, sched: Double, dep: Double, arr: Double) =
            Ride(id, "IC", "Intercity", true, dep, sched, arr, arr, "Breda", "bd", "Eindhoven Centraal", live = true, walkBefore = 1)
        val late = DoorTrip(listOf(train("3600", hm(14, 38), hm(14, 48), hm(15, 22))), hm(14, 47), hm(15, 52))
        val next = DoorTrip(listOf(train("3700", hm(14, 49), hm(14, 54), hm(15, 40))), hm(14, 53), hm(16, 10))
        val left = DoorTrip(listOf(train("3500", hm(14, 30), hm(14, 35), hm(15, 10))), hm(14, 34), hm(15, 40))
        assertEquals(listOf("3600", "3700"), TransitParse.keepUseful(listOf(next, left, late), now, 5).map { it.first.tripId }.sortedBy { it })
        assertEquals("3600", TransitParse.keepUseful(listOf(next, left, late), now, 5).first().first.tripId)
    }

    @Test fun askedFromFurtherBackAtAStation() {
        assertEquals(hm(14, 30), LiveKeep.askAt(hm(14, 45), true), 0.0)
        assertEquals(hm(14, 43), LiveKeep.askAt(hm(14, 45), false), 0.0)
        assertEquals(8, LiveKeep.count(5, true))
        assertEquals(5, LiveKeep.count(5, false))
    }

    @Test fun changesStillMadeAfterTheDelay() {
        assertTrue(LiveKeep.connects(listOf(hm(15, 22), hm(15, 50)), listOf(hm(14, 48), hm(15, 31)), listOf(3, 2)))
        assertFalse(LiveKeep.connects(listOf(hm(15, 22), hm(15, 50)), listOf(hm(14, 48), hm(15, 23)), listOf(3, 2)))
        assertTrue(LiveKeep.connects(listOf(hm(15, 22)), listOf(hm(14, 48)), listOf(3)))
    }

    @Test fun lateWords() {
        assertEquals("The 14:38 IC to Eindhoven Centraal is 10 min late — leaves 14:48 from platform 3",
            LiveKeep.lateWords("IC", "Eindhoven Centraal", hm(14, 38), hm(14, 48), "3", clock))
    }

    @Test fun speedIsYoursAfterFiveWalks() {
        assertEquals(1.35, WalkFirst.speed(1.35, 5), 0.0)
        assertEquals(1.2, WalkFirst.speed(1.35, 4), 0.0)
        assertEquals(1.2, WalkFirst.speed(null, 9), 0.0)
    }

    @Test fun walkRetimedByItsDistance() {
        val m = WalkFirst.metres(780.0, 240.0)!!
        assertEquals(312.0, m, 0.01)
        assertEquals(4, WalkFirst.walk(10, m, 1.35))
        assertEquals(400.0, WalkFirst.metres(400.0, 300.0)!!, 0.0)
        assertEquals(5, WalkFirst.walk(10, 400.0, 1.35))
        assertEquals(3, WalkFirst.walk(3, 400.0, 1.35))
        assertEquals(10, WalkFirst.walk(10, null, 1.35))
        assertEquals(130.0, WalkFirst.metres(null, 100.0)!!, 0.01)
        assertEquals("walk · planner 10 min (780 m) · yours 4 min (1.35 m/s) · used yours", WalkFirst.logLine(10, 780.0, 4, 1.35, true))
    }

    @Test fun hopFirstReplacedWhenTheWalkMakesTheSameRide() {
        assertEquals(7, WalkFirst.walkInstead(4.0, hm(7, 20), hm(7, 22), hm(7, 40), 520.0, 1.35))
        assertNull(WalkFirst.walkInstead(4.0, hm(7, 20), hm(7, 20), hm(7, 26), 520.0, 1.35))
        assertNull(WalkFirst.walkInstead(8.0, hm(7, 20), hm(7, 22), hm(7, 40), 520.0, 1.35))
        assertNull(WalkFirst.walkInstead(4.0, hm(7, 20), hm(7, 28), hm(7, 40), 1500.0, 1.35))
    }

    @Test fun theWayItselfIsSwappedForTheWalk() {
        // at home (51.6, 5.5); the 4 min bus to the bus station 400 m away, then the 07:40 from there
        val home = GeoPoint(51.6, 5.5)
        val station = GeoPoint(51.6036, 5.5)
        val hop = Ride("hop", "1", "1", false, hm(7, 25), hm(7, 25), hm(7, 29), hm(7, 29), "Near home", "n", "Veghel, Busstation",
            walkBefore = 3, fromLat = 51.6005, fromLon = 5.5)
        val main = Ride("306", "306", "306", false, hm(7, 40), hm(7, 40), hm(8, 10), hm(8, 10), "Veghel, Busstation", "v", "Den Bosch",
            walkBefore = 1, fromLat = station.lat, fromLon = station.lon)
        val t = DoorTrip(listOf(hop, main), hm(7, 22), hm(8, 15))
        val (f, note) = WalkFirst.fixed(t, home, hm(7, 20), 1.35)
        assertEquals(listOf("306"), f.rides.map { it.tripId })
        assertEquals(7, f.first.walkBefore)           // 400 m × 1.3 at 1.35 m/s
        assertEquals(hm(7, 33), f.start, 0.0)
        assertTrue(note!!.startsWith("walk · straight to Veghel, Busstation"))
        // the 306 leaving 07:26: walking misses it, the hop stays
        val soon = DoorTrip(listOf(hop.copy(departure = hm(7, 21), arrival = hm(7, 24)), main.copy(departure = hm(7, 26))), hm(7, 20), hm(8, 0))
        assertEquals(listOf("hop", "306"), WalkFirst.fixed(soon, home, hm(7, 20), 1.35).first.rides.map { it.tripId })
    }
}
