package nl.haltewekker

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import nl.haltewekker.core.Country
import nl.haltewekker.core.CountryStop
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.data.IRail
import nl.haltewekker.data.TransitParse
import nl.haltewekker.friends.NSCodes
import nl.haltewekker.ride.DoorSide
import nl.haltewekker.ride.PlatformWatch
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * (0.10.13, iOS 0.42.17 BelgiumTests) Haltewekker in Belgium: which country a stop is in, where a train's live data
 * comes from (NS or iRail), the relay's `/be/…` answers read and a Belgian train's iRail data laid over its Transitous
 * trip, against docs/belgium-vectors.json (the vectors iOS checks too).
 */
class BelgiumTest {
    private fun file(vararg names: String) = names.map(::File).first { it.exists() }
    private val v: JsonObject by lazy {
        Json.parseToJsonElement(file("../../docs/belgium-vectors.json", "../docs/belgium-vectors.json", "docs/belgium-vectors.json").readText()).jsonObject
    }
    private val codes: NSCodes by lazy {
        NSCodes(NSCodes.decode(file("../../ios/App/NSStations.json", "../ios/App/NSStations.json", "ios/App/NSStations.json").readText()))
    }

    private fun JsonObject.s(k: String): String? = (this[k] as? JsonPrimitive)?.takeIf { it !is JsonNull && it.isString }?.content
    private fun JsonObject.d(k: String): Double? = (this[k] as? JsonPrimitive)?.takeIf { it !is JsonNull && !it.isString }?.content?.toDoubleOrNull()
    private fun JsonObject.b(k: String): Boolean? = (this[k] as? JsonPrimitive)?.takeIf { it !is JsonNull && !it.isString }?.content?.toBooleanStrictOrNull()
    private fun cases(k: String) = v[k]!!.jsonArray.map { it.jsonObject }

    @Test fun country() {
        for (c in cases("country")) assertEquals(c.toString(), c.s("want"), Country.of(c.s("id")!!, c.d("lat"), c.d("lon")).code)
        for (c in cases("uic")) assertEquals(c.s("id"), c.s("want"), Country.uic(c.s("id")!!))
        for (c in cases("belgianTrip")) assertEquals(c.s("tripId"), c.b("want"), Country.belgianTrip(c.s("tripId")!!))
        for (c in cases("onlyBelgium")) {
            val stops = c["stops"]!!.jsonArray.map { it.jsonObject }.map { CountryStop(it.s("id") ?: "", it.d("lat"), it.d("lon")) }
            assertEquals(c.toString(), c.b("want"), Country.onlyBelgium(stops))
        }
    }

    /** No Dutch station is taken for a Belgian one by where it is: the Netherlands stays as it was. */
    @Test fun everyNSStationStaysDutch() {
        assertTrue(codes.stations.size > 350)
        for (st in codes.stations) {
            assertFalse("${st.code} ${st.name}", Country.inBelgium(st.lat, st.lon))
            assertEquals(st.code, Country.NL, Country.of("", st.lat, st.lon))
        }
    }

    @Test fun railSourceAndNSCodes() {
        for (c in cases("railSource")) assertEquals(c.toString(), c.s("want"), codes.railCode(c.s("id")!!, c.s("name")!!, c.d("lat"), c.d("lon")))
        for (c in cases("nsCode")) assertEquals(c.toString(), c.s("want"), codes.code(c.s("id")!!, c.s("name")))
        assertEquals(listOf("id" to "8821006"), Country.liveboardParams("be:8821006"))
        assertEquals(listOf("station" to "Brussel-Zuid"), Country.liveboardParams("be:Brussel-Zuid"))
        assertNull(Country.liveboardParams("BD"))
    }

    @Test fun liveboardAndComposition() {
        val lb = v["liveboard"]!!.jsonObject
        val got = IRail.departures(lb["body"].toString())!!
        val want = lb["want"]!!.jsonArray.map { it.jsonObject }
        assertEquals(want.size, got.size)
        for ((g, w) in got.zip(want)) {
            assertEquals(w.s("num"), g.num)
            assertEquals(g.num, w.s("planned"), g.planned?.let(IRail::iso))
            assertEquals(g.num, w.s("actual"), g.actual?.let(IRail::iso))
            assertEquals(g.num, w.s("track"), g.track)
            assertEquals(g.num, w.s("plannedTrack"), g.plannedTrack)
            assertEquals(g.num, w.b("changed"), g.changed)
            assertEquals(g.num, w.b("cancelled"), g.cancelled)
            assertEquals(g.num, w.d("crowd")?.toInt(), g.crowd)
        }
        assertNull(IRail.departures("nope"))
        assertNull(IRail.departures(null))
        // the platform watch reads it as NS's board
        val rows = PlatformWatch.parseBelgian(lb["body"].toString())!!
        assertEquals("", rows.first { it.num == "3334" }.plannedTrack)
        assertEquals("24", rows.first { it.num == "3334" }.actualTrack)
        assertTrue(rows.first { it.num == "2862" }.cancelled)
        val comp = v["composition"]!!.jsonObject
        assertEquals(comp.d("cars")!!.toInt() to comp.d("seats")!!.toInt(), IRail.composition(comp["body"].toString()))
        assertNull(IRail.composition("{\"cars\":0}"))
    }

    @Test fun vehicleQuery() {
        for (c in cases("vehicleQuery")) assertEquals(c.toString(), c.s("want"), IRail.vehiclePath(c.s("tripId")!!, c.s("num")!!))
    }

    private fun stops(trip: JsonObject): List<JsonObject> = trip["legs"]!!.jsonArray.flatMap { e ->
        val l = e.jsonObject
        listOfNotNull(l["from"] as? JsonObject) + ((l["intermediateStops"] as? JsonArray)?.map { it.jsonObject } ?: emptyList()) +
            listOfNotNull(l["to"] as? JsonObject)
    }

    @Test fun overlay() {
        for (c in cases("overlay")) {
            val trip = c["trip"]!!.jsonObject
            assertEquals("9235", IRail.trainNumber(trip))
            val veh = JsonObject(c["vehicle"]!!.jsonObject.toMutableMap().also { it["num"] = JsonPrimitive(c.s("num")) })
            val out = IRail.overlay(trip, veh)
            val why = c.s("why")
            assertEquals(why, c.b("realTime"), (out["legs"]!!.jsonArray[0].jsonObject).b("realTime"))
            if (c.b("same") == true) { assertEquals(why, trip, out); continue }
            val want = c["want"]!!.jsonArray.map { it.jsonObject }
            val got = stops(out)
            assertEquals(want.size, got.size)
            for ((g, w) in got.zip(want)) {
                val n = w.s("name")
                assertEquals(n, g.s("name"))
                assertEquals(n, w.s("track"), g.s("track"))
                assertEquals(n, w.s("scheduledTrack"), g.s("scheduledTrack"))
                assertEquals(n, w.s("arrival"), g.s("arrival"))
                assertEquals(n, w.s("departure"), g.s("departure"))
                assertEquals(n, w.b("cancelled"), g.b("cancelled") ?: false)
            }
            // on the text, and read as the app reads a trip: the platform at Antwerpen, and its stop cancelled
            val text = IRail.overlay(trip.toString(), veh.toString())!!
            val live = TransitParse.parseTrip(text)!!
            assertEquals(want.map { it.s("track") }, live.stops.map { it.track })
            assertEquals(want.map { it.b("cancelled") }, live.stops.map { it.cancelled })
        }
        val nl = """{"legs":[{"mode":"REGIONAL_RAIL","tripShortName":"3561","from":{"stopId":"de-DELFI_000008400131","lat":51.5955,"lon":4.78},
            "to":{"stopId":"de-DELFI_000008400319","lat":51.6905,"lon":5.2936}}]}"""
        assertNull(IRail.trainNumber(nl))
        assertNull(IRail.trainNumber("""{"legs":[{"mode":"BUS","tripShortName":"12","from":{"stopId":"be-delijn_1","lat":51.2,"lon":4.4}}]}"""))
        assertNull(IRail.overlay("x", null))
    }

    @Test fun exitSideAsksBelgianNamesEscaped() {
        val a = DoorSide.Ask("NOORDERKEMPEN (BRECHT)", "1", GeoPoint(51.2172, 4.4211), GeoPoint(51.3568, 4.6322))
        assertEquals("station=NOORDERKEMPEN%20%28BRECHT%29&track=1&from=51.2172,4.4211&at=51.3568,4.6322", a.query())
        assertEquals("station=LI%C3%88GE-GUILLEMINS&track=3&from=1.0000,2.0000&at=1.0000,2.0000",
            DoorSide.Ask("LIÈGE-GUILLEMINS", "3", GeoPoint(1.0, 2.0), GeoPoint(1.0, 2.0)).query())
        assertTrue(DoorSide.Ask("BD", "4", GeoPoint(51.56, 4.98), GeoPoint(51.5955, 4.78)).query().startsWith("station=BD&track=4&"))
        assertNotNull(Country.of("", 51.2, 4.4))
    }
}
