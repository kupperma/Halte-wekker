package nl.haltewekker

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.double
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.data.TripStop
import nl.haltewekker.data.TransitParse
import nl.haltewekker.ride.DoorSide
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * (0.10.6) Which side you get out: the relay's answer, the line the app shows and how it asks, against
 * docs/door-side-vectors.json (the vectors iOS and the relay check too).
 */
class DoorSideTest {
    private val v: JsonObject by lazy {
        val f = listOf("../../docs/door-side-vectors.json", "../docs/door-side-vectors.json", "docs/door-side-vectors.json").map(::File).first { it.exists() }
        Json.parseToJsonElement(f.readText()).jsonObject
    }
    private fun JsonObject.s(k: String) = (this[k] as? JsonPrimitive)?.takeIf { it.isString }?.content

    @Test fun answersAndLines() {
        val list = v["answers"]!!.jsonArray
        assertTrue(list.size >= 10)
        for (e in list) {
            val c = e.jsonObject
            assertEquals(c.s("body"), c.s("line"), DoorSide.line(DoorSide.parse(c.s("body")), c.s("track")))
        }
    }

    @Test fun query() {
        for (e in v["query"]!!.jsonArray) {
            val c = e.jsonObject
            val f = c["from"]!!.jsonArray.map { it.jsonPrimitive.double }
            val a = c["at"]!!.jsonArray.map { it.jsonPrimitive.double }
            val ask = DoorSide.Ask(c.s("station")!!, DoorSide.cleanTrack(c.s("track")), GeoPoint(f[0], f[1]), GeoPoint(a[0], a[1]))
            assertEquals(c.s("query"), ask.query())
        }
    }

    private fun stop(name: String, lat: Double, lon: Double, track: String? = null) = TripStop(name, GeoPoint(lat, lon), null, null, track = track)

    @Test fun whatItAsks() {
        val stops = listOf(stop("Tilburg", 51.5605, 5.0838, "2"), stop("Gilze-Rijen", 51.5458, 4.9339, "1"), stop("Breda", 51.5955, 4.7799, " 4 "),
            stop("Etten-Leur", 51.5753, 4.6385, "2"))
        val breda = GeoPoint(51.5957, 4.7795)
        val a = DoorSide.ask(true, stops, breda, "bd")!!
        assertEquals("BD", a.station)
        assertEquals("4", a.track)
        assertEquals("station=BD&track=4&from=51.5458,4.9339&at=51.5955,4.7799", a.query())
        // a bus, no code, no platform, your stop far from the trip, or first: nothing to ask
        assertNull(DoorSide.ask(false, stops, breda, "BD"))
        assertNull(DoorSide.ask(true, stops, breda, null))
        assertNull(DoorSide.ask(true, stops.map { it.copy(track = null) }, breda, "BD"))
        assertNull(DoorSide.ask(true, stops, GeoPoint(51.70, 4.90), "BD"))
        assertNull(DoorSide.ask(true, stops, GeoPoint(51.5605, 5.0838), "TB"))
        // another platform: another question (asked again)
        val moved = DoorSide.ask(true, stops.mapIndexed { i, s -> if (i == 2) s.copy(track = "5") else s }, breda, "BD")!!
        assertTrue(moved.key != a.key)
        assertEquals("Get off at Breda · 2 min", DoorSide.withLine("Get off at Breda · 2 min", null))
        assertEquals("Get off at Breda · 2 min\nExit on the left", DoorSide.withLine("Get off at Breda · 2 min", "Exit on the left"))
    }

    @Test fun tripStopsKeepTheirPlatform() {
        val body = """{"legs":[{"mode":"RAIL","routeShortName":"IC","tripShortName":"1144","from":{"name":"Tilburg","lat":51.5605,"lon":5.0838,"track":"2"},
            "intermediateStops":[{"name":"Gilze-Rijen","lat":51.5458,"lon":4.9339,"scheduledTrack":"1"}],
            "to":{"name":"Breda","lat":51.5955,"lon":4.7799,"track":"4","scheduledTrack":"3"}}]}"""
        val t = TransitParse.parseTrip(body)!!
        assertEquals(listOf("2", "1", "4"), t.stops.map { it.track })
    }
}
