package nl.haltewekker

import nl.haltewekker.core.GeoPoint
import nl.haltewekker.data.DoorTrip
import nl.haltewekker.data.HomeAlight
import nl.haltewekker.data.HomeAlight.Call
import nl.haltewekker.data.HomeAlight.Own
import nl.haltewekker.data.Ride
import nl.haltewekker.data.TripStop
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** iOS 0.42.10 `HomeAlightTests`, the same vectors. */
class HomeAlightTest {
    private val base = 1_795_737_600.0
    private fun hm(h: Int, m: Int) = base + (h * 60.0 + m) * 60
    private val calls = listOf(
        Call("dbs", "'s-Hertogenbosch, Centraal Station", GeoPoint(51.69, 5.29), hm(15, 35)),
        Call("rem", "Veghel, Rembrandtlaan", GeoPoint(51.620, 5.530), hm(16, 3)),
        Call("bus", "Veghel, Busstation", GeoPoint(51.6160, 5.5440), hm(16, 7)),
        Call("far", "Uden, Busstation", GeoPoint(51.66, 5.62), hm(16, 25)))
    private val home = GeoPoint(51.6150, 5.5450)

    @Test fun fullName() = assertEquals("Veghel, Busstation", HomeAlight.fullName(" Veghel, Busstation "))

    @Test fun offAtYourOwnStop() {
        assertEquals(2, HomeAlight.pick(calls, 0, 1, listOf(Own("bus", null)), home, 1.35))
        assertEquals(2, HomeAlight.pick(calls, 0, 1, listOf(Own("x", GeoPoint(51.6162, 5.5441))), home, 1.35))
    }

    @Test fun keepsThePlannersWhenItIsYoursOrNoneIsCalledAt() {
        assertNull(HomeAlight.pick(calls, 0, 2, listOf(Own("bus", null)), home, 1.35))
        assertNull(HomeAlight.pick(calls, 0, 1, listOf(Own("nope", null)), home, 1.35))
        assertNull(HomeAlight.pick(calls, 0, 1, emptyList(), home, 1.35))
        assertNull(HomeAlight.pick(calls, 2, 3, listOf(Own("bus", null)), home, 1.35))
    }

    @Test fun theOneWithTheShortestWalk() {
        assertEquals(2, HomeAlight.pick(calls, 0, 3, listOf(Own("rem", null), Own("bus", null)), home, 1.35))
        assertEquals(3, HomeAlight.walkMinutes(calls[2].point, home, 1.35))
    }

    @Test fun indexOfTheRidesStops() {
        assertEquals(0, HomeAlight.index("dbs", null, calls))
        assertEquals(1, HomeAlight.index("", GeoPoint(51.6201, 5.5301), calls, 0))
        assertNull(HomeAlight.index("", GeoPoint(52.0, 5.0), calls))
    }

    @Test fun theWayHomeIsRetimedToYourStop() {
        val r = Ride("306-1", "306", "306", false, hm(15, 35), hm(15, 35), hm(16, 3), hm(16, 3), "'s-Hertogenbosch, Centraal Station", "dbs",
            "Veghel, Rembrandtlaan", live = true, fromLat = 51.69, fromLon = 5.29, toLat = 51.620, toLon = 5.530)
        val t = DoorTrip(listOf(r), hm(15, 30), hm(16, 15))
        val stops = calls.map { TripStop(it.name, it.point, it.arrival, it.arrival) }
        val f = HomeAlight.apply(t, stops, listOf(Own("", GeoPoint(51.6160, 5.5440))), home, 1.35)!!
        assertEquals("Veghel, Busstation", f.last.toStop)
        assertEquals(hm(16, 7), f.last.arrival, 0.0)
        assertEquals(hm(16, 10), f.end, 0.0)
    }
}
