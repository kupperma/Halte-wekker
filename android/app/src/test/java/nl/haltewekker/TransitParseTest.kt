package nl.haltewekker

import nl.haltewekker.core.GeoPoint
import nl.haltewekker.core.Iso
import nl.haltewekker.data.DoorTrip
import nl.haltewekker.data.Ride
import nl.haltewekker.data.TransitParse
import nl.haltewekker.data.VehicleKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Transitous answers saved on 2026-11-19 (trimmed), read as the iOS app reads them. */
class TransitParseTest {
    private val plan = String(Fx.resource("plan-utrecht-breda.json"))

    @Test fun readsThePlan() {
        val trips = TransitParse.parsePlan(plan)
        assertEquals(3, trips.size)
        val t = trips[1]
        assertEquals(listOf("IC", "IC", "1"), t.rides.map { it.line })
        assertEquals(listOf(true, true, false), t.rides.map { it.isTrain })
        val ic = t.first
        assertEquals("Utrecht Centraal", ic.fromStop)
        assertEquals("Rotterdam Centraal", ic.toStop)
        assertEquals("12", ic.platform)
        assertEquals(6, ic.walkBefore)                      // the walk to the platform, 15:27 to 15:33
        assertEquals("2854", ic.num)
        assertEquals("nl-OpenOV_2993990", ic.fromId)
        assertTrue(ic.live)
        assertEquals(Iso.parse("2026-11-19T15:33:00Z")!!, ic.departure, 0.0)
        assertEquals(Iso.parse("2026-11-19T15:27:00Z")!!, t.start, 0.0)
        assertEquals(Iso.parse("2026-11-19T16:50:00Z")!!, t.end, 0.0)
        assertEquals(VehicleKind.IC, ic.kind)
        assertEquals(VehicleKind.BUS, t.last.kind)
        assertEquals(3, t.walkAfter)
        assertEquals(listOf("Rotterdam Centraal", "Breda, Centraal Station"), t.changes)
        assertEquals(51.92, t.first.toLat!!, 0.01)
    }

    @Test fun garbageIsNoTrips() {
        assertTrue(TransitParse.parsePlan("").isEmpty())
        assertTrue(TransitParse.parsePlan("{\"itineraries\": 3}").isEmpty())
        assertTrue(TransitParse.parsePlan("<html>busy</html>").isEmpty())
        assertNull(TransitParse.parseTrip("{}"))
    }

    private fun ride(dep: Double, arr: Double, id: String) = Ride(id, "306", "306", false, dep, dep, arr, arr, "A", "a", "B")
    private fun trip(dep: Double, end: Double, id: String) = DoorTrip(listOf(ride(dep, end - 60, id)), dep - 120, end)

    @Test fun keepsOnlyUsefulTrips() {
        val now = 1_000_000.0
        val gone = trip(now - 600, now + 600, "gone")
        val a = trip(now + 300, now + 3000, "a")
        val beaten = trip(now + 200, now + 3600, "beaten")     // leaves earlier but a later one gets there sooner
        val b = trip(now + 900, now + 3300, "b")
        val kept = TransitParse.keepUseful(listOf(b, gone, beaten, a, a), now, 5)
        assertEquals(listOf("a", "b"), kept.map { it.first.tripId })
        assertEquals(1, TransitParse.keepUseful(listOf(a, b), now, 1).size)
    }

    @Test fun trainLabels() {
        assertEquals("IC", TransitParse.trainLabel("Intercity"))
        assertEquals("ICD", TransitParse.trainLabel("Intercity direct"))
        assertEquals("SPR", TransitParse.trainLabel("Sprinter"))
        assertEquals("S85", TransitParse.trainLabel("S85"))
        assertEquals(VehicleKind.SPRINTER, VehicleKind.of("REGIONAL_RAIL", "SPR", true))
        assertEquals(VehicleKind.TRAM, VehicleKind.of("TRAM", "21", true))
        assertEquals(VehicleKind.BUS, VehicleKind.of("", "306", false))
    }

    @Test fun nearStopsAndSetupChoices() {
        val body = String(Fx.resource("map-stops-breda.json"))
        val here = GeoPoint(51.5907, 4.7932)
        val near = TransitParse.parseNearStops(body, here)!!
        assertEquals(7, near.size)
        assertEquals("Breda, St.Ignatiusstraat", near.first().name)
        assertTrue(near.zipWithNext().all { (a, b) -> a.meters <= b.meters })
        assertFalse(near.first().rail)
        val choices = TransitParse.stopChoices(body, here, limit = 3)!!
        assertEquals(3, choices.size)
        assertEquals(choices.map { it.name.lowercase() }.distinct().size, choices.size)
        assertNull(TransitParse.parseNearStops("oops", here))
    }

    @Test fun geocodeKeepsTheNetherlandsAndNeighbours() {
        val body = """[{"type":"STOP","name":"Breda","id":"s1","lat":51.59,"lon":4.78,"country":"NL","areas":[{"name":"Breda","default":true}]},
            {"type":"PLACE","name":"Cairo University","id":"x","lat":30.0,"lon":31.2,"country":"EG"},
            {"type":"ADDRESS","name":"Hopmansstraat 2","lat":51.59,"lon":4.79,"areas":[{"name":"Breda","matched":true}]}]"""
        val hits = TransitParse.parseGeocode(body)
        assertEquals(listOf("Breda", "Hopmansstraat 2"), hits.map { it.name })
        assertEquals(listOf("stop", "address"), hits.map { it.kind })
        assertEquals("Breda", hits[1].town)
        assertEquals(1, TransitParse.parseGeocode(body, stopsOnly = true).size)
    }

    @Test fun stopTimes() {
        val body = """{"stopTimes":[{"place":{"name":"Breda","departure":"2026-11-19T16:15:00Z","scheduledDeparture":"2026-11-19T16:13:00Z","track":"3"},
            "mode":"REGIONAL_RAIL","realTime":true,"routeShortName":"Intercity","headsign":"Roosendaal","tripId":"t1"},
            {"place":{"name":"Breda","departure":"2026-11-19T16:20:00Z"},"mode":"BUS","routeShortName":"1","tripCancelled":true,"tripId":"t2"},
            {"place":{"name":"no time"}}]}"""
        val d = TransitParse.parseStopTimes(body, "s")!!
        assertEquals(2, d.size)
        assertEquals(2, d[0].delay)
        assertTrue(d[0].train)
        assertEquals("3", d[0].platform)
        assertTrue(d[1].cancelled)
        assertFalse(d[1].train)
    }
}
