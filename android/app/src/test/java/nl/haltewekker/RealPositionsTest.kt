package nl.haltewekker

import nl.haltewekker.live.GPSFix
import nl.haltewekker.live.RealPositions
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

/** A tiny protobuf writer, to build feeds by hand (as iOS `RealPositionsTests`). */
private object PB {
    fun varint(v0: Long): List<Byte> {
        var v = v0
        val out = ArrayList<Byte>()
        do {
            var b = (v and 0x7f).toInt(); v = v ushr 7
            if (v != 0L) b = b or 0x80
            out.add(b.toByte())
        } while (v != 0L)
        return out
    }
    fun key(n: Long, wire: Long) = varint((n shl 3) or wire)
    fun uint(n: Long, v: Long) = key(n, 0) + varint(v)
    fun bytes(n: Long, b: List<Byte>) = key(n, 2) + varint(b.size.toLong()) + b
    fun string(n: Long, s: String) = bytes(n, s.toByteArray().toList())
    fun float(n: Long, f: Float): List<Byte> {
        val b = java.lang.Float.floatToIntBits(f)
        return key(n, 5) + (0 until 4).map { ((b ushr (8 * it)) and 0xff).toByte() }
    }
    fun double(n: Long, d: Double): List<Byte> {
        val b = java.lang.Double.doubleToLongBits(d)
        return key(n, 1) + (0 until 8).map { ((b ushr (8 * it)) and 0xff).toByte() }
    }
    fun entity(id: String, trip: String, date: String = "20261117", lat: Float, lon: Float, bearing: Float? = null,
               ts: Long?, extra: Boolean = false): List<Byte> {
        var td = string(1, trip) + string(3, date) + string(5, "151894")
        if (extra) td += uint(99, 7)
        var pos = float(1, lat) + float(2, lon)
        if (bearing != null) pos += float(3, bearing)
        if (extra) pos += double(4, 12345.5) + float(5, 8.2f)
        var vp = bytes(1, td) + bytes(2, pos) + uint(3, 14) + uint(4, 1)
        if (ts != null) vp += uint(5, ts)
        if (extra) vp += string(7, "4232722") + bytes(8, string(2, "6205")) + bytes(1003, uint(1, 322))
        var e = string(1, id) + bytes(4, vp)
        if (extra) e += uint(2, 0) + bytes(1500, listOf(1, 2, 3))
        return bytes(2, e)
    }
    fun header(ts: Long) = bytes(1, string(1, "1.0") + uint(2, 0) + uint(3, ts) + bytes(1000, uint(1, 42_000_000) + uint(2, 60)))
}

class RealPositionsTest {
    private val t0 = 1_794_918_086L          // 2026-11-17 13:21 in the Netherlands

    private fun parse(b: List<Byte>) = RealPositions.parse(b.toByteArray())

    @Test fun readsAHandBuiltFeed() {
        fun le(x: Int) = (0 until 4).map { ((x ushr (8 * it)) and 0xff).toByte() }
        val pos = listOf(0x0d.toByte()) + le(java.lang.Float.floatToIntBits(51.5f)) + listOf(0x15.toByte()) + le(java.lang.Float.floatToIntBits(5.25f))
        val vp = listOf(0x0a, 0x03, 0x0a, 0x01, 0x37, 0x12, 0x0a).map { it.toByte() } + pos + listOf(0x28, 0xde, 0x07).map { it.toByte() }
        val ent = listOf(0x0a, 0x01, 0x61, 0x22, vp.size).map { it.toByte() } + vp
        val bytes = listOf(0x0a, 0x03, 0x18, 0xe8, 0x07, 0x12, ent.size).map { it.toByte() } + ent
        val feed = parse(bytes)
        assertEquals(1000.0, feed.timestamp!!, 0.0)
        assertEquals(1, feed.entities)
        val f = feed.fixes["7"]!!
        assertEquals(51.5, f.lat, 0.0)
        assertEquals(5.25, f.lon, 0.0)
        assertNull(f.bearing)
        assertEquals(990.0, f.at, 0.0)
    }

    @Test fun skipsUnknownFieldsAndExtensions() {
        val data = PB.header(t0) +
            PB.entity("2026-11-17:QBUZZ:m090:1017", "395867263", lat = 51.929f, lon = 4.892f, bearing = 270f, ts = t0 - 12, extra = true) +
            PB.bytes(1200, listOf(9, 9, 9)) +
            PB.entity("x", "398181886", lat = 52.365f, lon = 4.885f, ts = t0 - 7)
        val feed = parse(data)
        assertEquals(t0.toDouble(), feed.timestamp!!, 0.0)
        assertEquals(2, feed.fixes.size)
        val a = feed.fixes["395867263"]!!
        assertEquals(51.929, a.lat, 1e-5)
        assertEquals(4.892, a.lon, 1e-5)
        assertEquals(270.0, a.bearing!!, 0.0)
        assertEquals((t0 - 12).toDouble(), a.at, 0.0)
        assertEquals("20261117", a.startDate)
        assertEquals(14, a.stopSequence)
        assertEquals(true, a.stopped)
        assertNotNull(feed.fixes["398181886"])
    }

    @Test fun truncatedFeedKeepsWhatWasWhole() {
        val whole = PB.header(t0) + PB.entity("a", "1", lat = 51.6f, lon = 5.3f, ts = t0) + PB.entity("b", "2", lat = 51.7f, lon = 5.4f, ts = t0)
        assertEquals(setOf("1", "2"), parse(whole).fixes.keys)
        val firstEnd = (PB.header(t0) + PB.entity("a", "1", lat = 51.6f, lon = 5.3f, ts = t0)).size
        for (cut in 0 until whole.size) {
            val f = parse(whole.take(cut))
            assertTrue(setOf("1", "2").containsAll(f.fixes.keys))
            if (cut >= firstEnd) assertNotNull("cut at $cut", f.fixes["1"])
            assertNull("the second is cut short at $cut", f.fixes["2"])
        }
    }

    @Test fun garbageNeverCrashes() {
        val rng = Random(7)
        repeat(300) { RealPositions.parse(rng.nextBytes(rng.nextInt(200))) }
        assertTrue(parse(listOf(0x08.toByte()) + List(20) { 0xff.toByte() }).fixes.isEmpty())
        assertTrue(parse(listOf(0x12, 0xff, 0xff, 0x03, 0x01).map { it.toByte() }).fixes.isEmpty())
        assertTrue(parse(listOf(0x13, 0x14).map { it.toByte() }).fixes.isEmpty())
        assertTrue(parse(listOf(0x00, 0x01).map { it.toByte() }).fixes.isEmpty())
        assertEquals(0, RealPositions.parse(ByteArray(0)).fixes.size)
    }

    @Test fun leavesOutVehiclesWithoutTripOrPosition_andKeepsTheNewest() {
        val noTrip = PB.bytes(2, PB.string(1, "n") + PB.bytes(4, PB.bytes(2, PB.float(1, 51.5f) + PB.float(2, 5.2f)) + PB.uint(5, t0)))
        val noPos = PB.bytes(2, PB.string(1, "p") + PB.bytes(4, PB.bytes(1, PB.string(1, "9")) + PB.uint(5, t0)))
        val zero = PB.entity("z", "8", lat = 0f, lon = 0f, ts = t0)
        val older = PB.entity("o", "5", lat = 51.1f, lon = 5.1f, ts = t0 - 60)
        val newer = PB.entity("q", "5", lat = 51.2f, lon = 5.2f, ts = t0 - 10)
        val noTime = PB.entity("t", "6", lat = 51.3f, lon = 5.3f, ts = null)
        val feed = parse(PB.header(t0) + noTrip + noPos + zero + newer + older + noTime)
        assertEquals(setOf("5", "6"), feed.fixes.keys)
        assertEquals(51.2, feed.fixes["5"]!!.lat, 1e-5)
        assertEquals(t0.toDouble(), feed.fixes["6"]!!.at, 0.0)
        assertEquals(6, feed.entities)
    }

    @Test fun readsARealFeed() {
        // OVapi's feed of 2026-11-19 15:10, its header and first 25 vehicles
        val feed = RealPositions.parse(Fx.resource("vehiclePositions-sample.pb"))
        assertEquals(25, feed.entities)
        assertTrue(feed.fixes.size in 15..25)
        assertNotNull(feed.timestamp)
        for (f in feed.fixes.values) {
            assertTrue(f.lat in 50.0..54.0)
            assertTrue(f.lon in 3.0..8.0)
        }
    }

    @Test fun keyAndServiceDate() {
        assertEquals("374105578", RealPositions.key("20261117_11:57_nl-OpenOV_374105578"))
        assertNull(RealPositions.key("20261117_11:57_nl-NS_12345"))
        assertNull(RealPositions.key("20261117_11:57_nl-OpenOV_"))
        assertEquals("20261117", RealPositions.serviceDate("20261117_11:57_nl-OpenOV_374105578"))
        assertNull(RealPositions.serviceDate("abc_nl-OpenOV_1"))
    }

    @Test fun usableOnlyWhenFreshAndToday() {
        val now = t0.toDouble()
        val id = "20261117_11:57_nl-OpenOV_374105578"
        fun fix(age: Double, date: String? = "20261117") = mapOf("374105578" to GPSFix(51.6, 5.3, null, now - age, date))
        assertNotNull(RealPositions.usable(fix(40.0), id, now))
        assertNotNull(RealPositions.usable(fix(180.0), id, now))
        assertNull(RealPositions.usable(fix(181.0), id, now))
        assertNull(RealPositions.usable(fix(-120.0), id, now))
        assertNull(RealPositions.usable(fix(40.0, "20261116"), id, now))
        assertNotNull(RealPositions.usable(fix(40.0, null), id, now))
        assertNull(RealPositions.usable(fix(40.0), "20261117_11:57_nl-OpenOV_999", now))
        assertNull(RealPositions.usable(fix(40.0), "20261117_11:57_de-DELFI_374105578", now))
        assertNull(RealPositions.usable(fix(40.0, "20261110"), "20261110_11:57_nl-OpenOV_374105578", now))
        val night = 1_794_960_000.0          // 2026-11-18 01:00 Dutch time
        assertEquals("20261118", RealPositions.day(night))
        val nf = mapOf("1" to GPSFix(51.6, 5.3, null, night - 30, "20261117"))
        assertNotNull(RealPositions.usable(nf, "20261117_25:20_nl-OpenOV_1", night))
    }

    @Test fun trainNumbersAndNS() {
        assertEquals(3561, RealPositions.trainNumber("3561"))
        assertEquals(3561, RealPositions.trainNumber("IC 3561"))
        assertNull(RealPositions.trainNumber("Intercity"))
        assertNull(RealPositions.trainNumber("0"))
        assertNull(RealPositions.trainNumber("1234567"))
        val at = 1_800_000_000.0
        val trains = RealPositions.parseTrains(String(Fx.resource("ns-vehicles-sample.json")), at)!!
        assertEquals(6, trains.size)
        val t = trains[8649]!!
        assertEquals(52.124134, t.lat, 1e-6)
        assertEquals(4.707 / 3.6, t.speed!!, 1e-6)
        assertEquals("SPR", t.type)
        assertEquals(at, t.at, 0.0)
        val odd = """{"treinen":[{"ritId":"123","lat":"51,5","lng":5.2},{"treinNummer":0,"lat":51,"lng":5},{"treinNummer":9,"lat":0,"lng":0}]}"""
        assertEquals(setOf(123), RealPositions.parseTrains(odd, at)!!.keys)
        assertNull(RealPositions.parseTrains("[]", at))
    }

    @Test fun backoff() {
        assertEquals(30.0, RealPositions.backoff(0), 0.0)
        assertEquals(60.0, RealPositions.backoff(1), 0.0)
        assertEquals(240.0, RealPositions.backoff(3), 0.0)
        assertEquals(300.0, RealPositions.backoff(9), 0.0)
    }
}
