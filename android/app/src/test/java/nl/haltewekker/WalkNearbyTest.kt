package nl.haltewekker

import nl.haltewekker.core.GeoPoint
import nl.haltewekker.data.DoorTrip
import nl.haltewekker.data.Ride
import nl.haltewekker.travel.Nearby
import nl.haltewekker.travel.NearbyStore
import nl.haltewekker.travel.WalkGuide
import nl.haltewekker.travel.WalkRoute
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** (0.10.0) The OSRM foot route's steps, and the nearby search's grouping and window inputs. */
class WalkNearbyTest {
    private val osrm = """{"code":"Ok","routes":[{"legs":[{"steps":[
        {"name":"Stationsplein","distance":120.5,"maneuver":{"type":"depart","modifier":"left"},"geometry":{"coordinates":[[5.0,52.0],[5.0017,52.0]]}},
        {"name":"Hoogstraat","distance":80,"maneuver":{"type":"turn","modifier":"right"},"geometry":{"coordinates":[[5.0017,52.0],[5.0017,51.9993]]}},
        {"name":"","distance":0,"maneuver":{"type":"arrive"},"geometry":{"coordinates":[[5.0017,51.9993]]}}]}]}]}"""

    @Test fun osrmSteps() {
        val steps = WalkRoute.parse(osrm)!!
        assertEquals(3, steps.size)
        assertEquals("Head out on Stationsplein", steps[0].text)
        assertEquals("Turn right onto Hoogstraat", steps[1].text)
        assertEquals(WalkGuide.Turn.RIGHT, steps[1].maneuver)
        assertEquals(GeoPoint(52.0, 5.0017), steps[1].path.first())
        assertEquals("Arrive", steps[2].text)
        val r = WalkGuide.route(steps)
        assertTrue(r.length > 150)
        assertNull(WalkRoute.parse("""{"code":"NoRoute","routes":[]}"""))
        assertEquals("Take the roundabout onto Markt", WalkRoute.words("roundabout", "right", "Markt"))
        assertEquals("Keep left", WalkRoute.words("fork", "slight left", ""))
    }

    private fun ride(id: String, fromId: String, from: String, lat: Double, lon: Double, dep: Double, arr: Double, walk: Int, train: Boolean = false) =
        Ride(id, if (train) "IC" else "306", if (train) "Intercity" else "306", train, dep, dep, arr, arr, from, fromId, "Centrum",
            walkBefore = walk, fromLat = lat, fromLon = lon)

    @Test fun waysGoWithTheirStops() {
        val here = GeoPoint(51.60, 5.50)
        val stops = listOf(Nearby.Stop("s1", "Markt", 51.601, 5.501, false, 130.0), Nearby.Stop("s2", "Markt", 51.6012, 5.5011, false, 150.0),
            Nearby.Stop("s3", "Kerk", 51.604, 5.505, false, 560.0))
        val groups = Nearby.groups(stops, Nearby.DOTS_RADIUS)
        val t0 = 1_800_000_000.0
        val a = DoorTrip(listOf(ride("a", "s2", "Markt", 51.6012, 5.5011, t0 + 300, t0 + 1500, 2)), t0 + 180, t0 + 1600)
        val b = DoorTrip(listOf(ride("b", "far", "Station", 51.62, 5.52, t0 + 900, t0 + 1800, 25, train = true)), t0 - 600, t0 + 1900)
        val store = NearbyStore("dest", emptyList())
        val (gs, ws) = store.place(here, groups, listOf(a, b), emptyMap())
        assertEquals(listOf("a"), ws[groups.first { it.name == "Markt" }.id]!!.map { it.first.tripId })
        val station = gs.first { it.rail }
        assertEquals("rail:far", station.id)
        assertEquals(listOf("b"), ws[station.id]!!.map { it.first.tripId })
        // the window: leaving your door before you set off doesn't count
        val w = Nearby.window(Nearby.Leave.NOW, t0)
        assertNotNull(Nearby.best(listOf(store.dep(a)), w))
        assertNull(Nearby.best(listOf(store.dep(b)), w))
        assertEquals(0.0, store.dep(a).longestWait, 0.1)
    }
}
