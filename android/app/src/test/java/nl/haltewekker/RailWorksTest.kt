package nl.haltewekker

import nl.haltewekker.core.GeoPoint
import nl.haltewekker.travel.RailWorks
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.ZoneId
import java.time.ZonedDateTime

/** iOS `RailWorksTests` (0.36). */
class RailWorksTest {
    private val ams = ZoneId.of("Europe/Amsterdam")
    private fun at(y: Int, m: Int, d: Int, h: Int, min: Int = 0) = ZonedDateTime.of(y, m, d, h, min, 0, 0, ams).toEpochSecond().toDouble()
    private val points = mapOf(
        "TB" to GeoPoint(51.56055, 5.08361), "TBR" to GeoPoint(51.57361, 4.99444), "GZ" to GeoPoint(51.58361, 4.92611),
        "BD" to GeoPoint(51.59555, 4.78), "ETN" to GeoPoint(51.575, 4.63583), "RSD" to GeoPoint(51.54028, 4.45833),
        "HT" to GeoPoint(51.69048, 5.29362), "BTL" to GeoPoint(51.58433, 5.31912),
        "EHV" to GeoPoint(51.44333, 5.48139), "EHS" to GeoPoint(51.45111, 5.45583), "TBU" to GeoPoint(51.56499, 5.05178))
    private val point: (String) -> GeoPoint? = { points[it] }
    private val names = mapOf("TB" to "Tilburg", "BD" to "Breda", "GZ" to "Gilze-Rijen", "TBR" to "Tilburg Reeshof")

    private fun sample(start: String = "2026-11-26T04:00:00+0100", end: String = "2026-11-27T02:00:00+0100",
                       stations: List<String> = listOf("TB", "TBR", "GZ", "BD"), cons: List<String>? = listOf("GZ", "BD"),
                       alt: String? = "er rijden stopbussen", type: String = "MAINTENANCE", words: Boolean = true): String {
        fun sec(l: List<String>) = """{"stations":[${l.joinToString(",") { """{"stationCode":"$it","name":"${names[it] ?: it}"}""" }}],"direction":"BOTH"}"""
        val sit = if (words) "Door werkzaamheden: tussen Gilze-Rijen en Breda rijden er bussen." else "Door werkzaamheden: tussen Gilze-Rijen en Breda rijden minder treinen."
        val altPart = alt?.let { ""","alternativeTransport":{"label":"$it","shortLabel":"$it"}""" } ?: ""
        val span = """{"start":"$start","end":"$end","situation":{"label":"$sit"}$altPart}"""
        val consPart = cons?.let { ""","consequence":{"section":${sec(it)},"description":"${if (words) "er rijden bussen" else "minder treinen"}","level":"LESS_TRAINS"}""" } ?: ""
        val ps = """{"section":${sec(stations)},"sectionType":"NL"$consPart}"""
        return """[{"id":"7001","type":"$type","title":"Tilburg - Breda.","isActive":false,"start":"$start","end":"$end","timespans":[$span],"publicationSections":[$ps]},{"id":"c1","type":"CALAMITY","title":"Elsewhere"}]"""
    }

    @Test fun parse() {
        val items = RailWorks.parse(sample())
        assertEquals(1, items.size)
        val i = items[0]
        assertEquals("7001", i.id); assertTrue(i.works)
        assertEquals(listOf(listOf("GZ", "BD")), i.stretches)
        assertEquals("Breda", i.names["BD"])
        assertEquals(1, i.spans.size); assertTrue(i.spans[0].buses); assertTrue(i.spans[0].noTrains)
        assertEquals(at(2026, 11, 26, 4), i.spans[0].start, 0.0)
        assertTrue(RailWorks.parse("nope").isEmpty())
        assertEquals(1, RailWorks.parse("""{"payload":${sample()}}""").size)
        assertEquals(listOf(listOf("TB", "TBR", "GZ", "BD")), RailWorks.parse(sample(cons = null))[0].stretches)
        assertFalse(RailWorks.parse(sample(type = "DISRUPTION"))[0].works)
    }

    @Test fun onYourRide() {
        val tbBd = RailWorks.Ride("TB", "BD")
        assertEquals(listOf("TB", "TBR", "GZ", "BD"), RailWorks.passed(tbBd, listOf("TB", "TBR", "GZ", "BD"), point))
        assertEquals(listOf("GZ", "BD"), RailWorks.passed(tbBd, listOf("GZ", "BD"), point))
        assertEquals(listOf("BD"), RailWorks.passed(tbBd, listOf("BD", "ETN", "RSD"), point))
        val item = RailWorks.parse(sample())[0]
        assertEquals(listOf("GZ", "BD"), RailWorks.hit(item, tbBd, point))
        assertEquals(listOf("GZ", "BD"), RailWorks.hit(item, RailWorks.Ride("BD", "TB"), point))
        assertNull(RailWorks.hit(item, RailWorks.Ride("HT", "BTL"), point))
        assertNull(RailWorks.hit(item, RailWorks.Ride("BD", "RSD"), point))
        assertEquals(listOf("EHV"), RailWorks.passed(RailWorks.Ride("EHV", "HT"), listOf("EHS", "EHV"), point))
        assertEquals(listOf("TB", "TBU"), RailWorks.passed(tbBd, listOf("TB", "TBU"), point))
        assertEquals(listOf("TB"), RailWorks.passed(RailWorks.Ride("TB", "XX"), listOf("TB", "GZ"), point))
    }

    @Test fun impactsDaysAndWindows() {
        val items = RailWorks.parse(sample())
        val rides = listOf(RailWorks.Ride("TB", "BD"), RailWorks.Ride("HT", "BTL"))
        val now = at(2026, 11, 23, 9)
        val list = RailWorks.impacts(items, rides, now, point = point)
        assertEquals(1, list.size)
        assertEquals("2026-11-26", list[0].day); assertEquals("Gilze-Rijen", list[0].fromName); assertEquals("Breda", list[0].toName)
        assertTrue(list[0].buses && list[0].noTrains && list[0].works)
        assertTrue(RailWorks.impacts(items, rides, at(2026, 11, 17, 9), point = point).isEmpty())
        val night = RailWorks.parse(sample(start = "2026-11-26T00:30:00+0100", end = "2026-11-26T06:00:00+0100"))
        val schoolOnly: (Double) -> Pair<Double, Double>? = { d -> (d + 7 * 3600) to (d + 9 * 3600) }
        assertTrue(RailWorks.impacts(night, rides, now, window = schoolOnly, point = point).isEmpty())
        assertEquals(1, RailWorks.impacts(night, rides, now, point = point).size)
        assertTrue(RailWorks.impacts(items, rides, now, window = { null }, point = point).isEmpty())
        assertTrue(RailWorks.impacts(night, rides, at(2026, 11, 26, 6), point = point).isEmpty())
    }

    @Test fun words() {
        val now = at(2026, 11, 23, 21)
        val i = RailWorks.impacts(RailWorks.parse(sample(cons = listOf("TB", "TBR", "GZ", "BD"))), listOf(RailWorks.Ride("TB", "BD")), now, point = point)[0]
        assertEquals("Thursday: no trains Tilburg–Breda (works). Leave 10 min earlier — buses replace trains", RailWorks.headline(i, now, 10))
        assertEquals("Thursday: no trains Tilburg–Breda (works). Buses replace trains — allow extra time", RailWorks.headline(i, now, null))
        assertEquals("Today", RailWorks.dayWord(at(2026, 11, 23, 0), now))
        assertEquals("Tomorrow", RailWorks.dayWord(at(2026, 11, 24, 0), now))
        val fewer = RailWorks.impacts(RailWorks.parse(sample(alt = null, type = "DISRUPTION", words = false)), listOf(RailWorks.Ride("TB", "BD")), now, point = point)[0]
        assertEquals("Thursday: fewer trains Gilze-Rijen–Breda (disruption). Allow extra time", RailWorks.headline(fewer, now, null))
    }

    @Test fun leaveEarlier() {
        val be = at(2026, 11, 26, 8, 45)
        assertEquals(10, RailWorks.leaveEarlier(40.0, at(2026, 11, 26, 7, 55), be))
        assertNull(RailWorks.leaveEarlier(40.0, at(2026, 11, 26, 8, 4), be))
        assertNull(RailWorks.leaveEarlier(null, at(2026, 11, 26, 7, 55), be))
    }

    @Test fun eveningBefore() {
        assertEquals(at(2026, 11, 25, 19, 30), RailWorks.eveningBefore(at(2026, 11, 26, 0)), 0.0)
        val i = RailWorks.impacts(RailWorks.parse(sample()), listOf(RailWorks.Ride("TB", "BD")), at(2026, 11, 25, 10), point = point)[0]
        assertFalse(RailWorks.tellNow(i, at(2026, 11, 25, 19, 0)))
        assertTrue(RailWorks.tellNow(i, at(2026, 11, 25, 19, 30)))
        assertTrue(RailWorks.tellNow(i, at(2026, 11, 25, 22, 59)))
        assertFalse(RailWorks.tellNow(i, at(2026, 11, 25, 23, 0)))
    }
}
