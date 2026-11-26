package nl.haltewekker

import kotlinx.serialization.json.JsonObject
import nl.haltewekker.friends.FriendJson
import nl.haltewekker.logs.FieldEntry
import nl.haltewekker.logs.FieldFormat
import nl.haltewekker.logs.Gzip
import nl.haltewekker.logs.LogScrub
import nl.haltewekker.logs.LogScrubKnown
import nl.haltewekker.logs.LogShareBatch
import nl.haltewekker.logs.LogShareDelete
import nl.haltewekker.logs.LogSharePut
import nl.haltewekker.logs.LogShareRules
import nl.haltewekker.logs.LogShareState
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.time.ZoneId
import java.util.zip.GZIPInputStream

/** Shared ride logs (iOS `LogShareTests`): what a line may say once it leaves the phone, what goes in one upload, and when. */
class LogShareTest {
    private val t0 = 1_800_000_000.0
    private val utc = ZoneId.of("UTC")
    private val known = LogScrubKnown(homes = listOf("Kerkstraat 12", "Veghel"), schools = listOf("BUas", "Academy campus"),
        places = listOf("Oma Riet", "Sportpark"), people = listOf("Sanne", "Max"), ids = listOf("0123456789abcdef0123456789abcdef"))

    private fun scrub(s: String) = LogScrub.line(s, known)

    @Test fun realRideLinesKeepTheirMeaning() {
        val start = FieldFormat.rideStart("Home on board, by itself", "bus 305·7821", 16630.0, 1, 3)
        assertEquals("start · Home on board, by itself · bus 305·7821 · its stop 16630 m from you · leg 1/3", start)
        assertEquals(start, scrub(start))
        val lines = listOf(
            "detect · n=9 · IC·a1b2 live 30 s | 306·c3d4 timetable off its path 180 m → keep IC·a1b2",
            "same bus · kept by GPS · 305·4779 · 120 m from you, 40 s old (drifting 8 m/s)",
            "board · fast lane · 305·4779 · GPS 120 m from you, 40 s old · 2 fixes, 9 s · you 24 m/s",
            "arrive · by GPS · 230 m (±15) · leg 12 s old · started 180 m",
            "ring · approach · 1600 m · leg 25 s old · started 1940 m",
            "real position · bus 305·4779 · GPS 12 s old · 80 m from its times (behind)",
            "cost · 07:33–08:10 · 37 min · 4% · GPS 36 min · 1.2 MB · 40 checks · 12 LA updates · CPU 0.4 s",
            "hand pick · bus 306·4942 (was 305·4779) · 120 m · gps",
            FieldFormat.detect(9, "305·7821", true, true),
        )
        for (l in lines) assertEquals(l, l, scrub(l))
    }

    @Test fun publicStopNamesStay() {
        assertEquals("arrive · at Breda, Centraal Station · 230 m", scrub("arrive · at Breda, Centraal Station · 230 m"))
        assertEquals("look · Eindhoven Centraal → Tilburg", scrub("look · Eindhoven Centraal → Tilburg"))
    }

    @Test fun yourPlacesBecomeHomeSchoolAndAPlace() {
        assertEquals("start · from Home to School · bus 321·1280", scrub("start · from Kerkstraat 12 to BUas · bus 321·1280"))
        assertEquals("bus 305 to Home, Busstation", scrub("bus 305 to Veghel, Busstation"))
        assertEquals("arrive · at School · 40 m", scrub("arrive · at buas · 40 m"))
        assertEquals("ride to a place and a place", scrub("ride to Oma Riet and Sportpark"))
        assertEquals("near the School gate", scrub("near the Academy campus gate"))
        assertEquals("BUasX stays", scrub("BUasX stays"))
    }

    @Test fun peopleAndIdsGo() {
        assertEquals("shared with a friend and a friend", scrub("shared with Sanne and Max"))
        assertEquals("max speed", scrub("max speed"))
        assertEquals("account [id]", scrub("account 0123456789ABCDEF0123456789ABCDEF"))
        assertEquals("device [id]", scrub("device fedcba9876543210fedcba9876543210"))
        assertEquals("id [id]", scrub("id 3F2504E0-4F89-11D3-9A0C-0305E82C3301"))
        assertEquals("token [id]", scrub("token AbCdEfGhIjKlMnOpQrStUvWx12_-"))
        assertEquals("trip ·a1b2 · 305·7821", scrub("trip ·a1b2 · 305·7821"))
    }

    @Test fun coordinatesLinksAndAddressesGo() {
        assertEquals("fix [coord] · 12 m", scrub("fix 51.61612, 5.53125 · 12 m"))
        assertEquals("at [coord]", scrub("at 51.6161 5.5312"))
        assertEquals("lat [coord]", scrub("lat 51.616123"))
        assertEquals("lon [coord]", scrub("lon -0.12754"))
        assertEquals("near [coord]", scrub("near 51,61612"))
        assertEquals("pair [coord]", scrub("pair 51.62,5.53"))
        assertEquals("get [link] done", scrub("get https://example.org/plan?from=51.6&to=x done"))
        assertEquals("mail [email]", scrub("mail someone@example.org"))
        assertEquals("1.2 KB · 0.4 s · 16630 m", scrub("1.2 KB · 0.4 s · 16630 m"))
    }

    @Test fun oneLineStaysOneLineAndShort() {
        assertEquals("a b c d", scrub("a\nb\tc\rd"))
        assertEquals(LogScrub.MAX_LINE, scrub("x".repeat(5000)).length)
    }

    @Test fun namesLikeTheLogsOwnWordsAndShortOnesAreLeft() {
        val k = LogScrubKnown(homes = listOf("Home", "  "), schools = listOf("School", "AB"), places = listOf("Bus"), people = listOf("Ring"))
        assertTrue(LogScrub.names(k).isEmpty())
        val line = "ring · approach · bus 305·7821 · Home on board"
        assertEquals(line, LogScrub.line(line, k))
    }

    private fun entry(s: Int, k: FieldEntry.Kind, t: String) = FieldEntry(t0 + s, k, t)

    @Test fun batchTakesNewMatchAndRideLinesOldestFirst() {
        val log = listOf(
            entry(40, FieldEntry.Kind.RIDE, "end · by hand"),
            entry(30, FieldEntry.Kind.NET, "/ns/departures · 200 · 1.2 KB · 0.3 s · 1 try · background"),
            entry(20, FieldEntry.Kind.MATCH, "detect · n=2 · 305·7821 live 20 s → choose 305·7821"),
            entry(10, FieldEntry.Kind.RIDE, "start · hand · bus 305·7821 · its stop 180 m from you · leg 1/1"),
            entry(0, FieldEntry.Kind.RIDE, "old · sent already"),
        )
        val b = LogShareRules.batch(log, t0, 10_000, known, utc)
        assertEquals(3, b.lines.size)
        assertTrue(b.lines[0].endsWith(" ride start · hand · bus 305·7821 · its stop 180 m from you · leg 1/1"))
        assertTrue(b.lines[1].contains(" match detect · "))
        assertTrue(b.lines[2].endsWith(" ride end · by hand"))
        assertFalse(b.lines.any { it.contains("/ns/") })
        assertEquals(t0 + 40, b.through!!, 0.0)
        assertFalse(b.more)
        assertEquals(b.lines.joinToString("\n").toByteArray().size, b.bytes)
        assertEquals(emptyList<String>(), LogShareRules.batch(log, t0 + 40, 10_000, known).lines)
    }

    @Test fun lineFormat() {
        val e = FieldEntry(t0, FieldEntry.Kind.RIDE, "start · Home on board, by itself · bus 305·7821 · its stop 16630 m from you · leg 1/3")
        assertEquals("2027-01-15 08:00:00 ride start · Home on board, by itself · bus 305·7821 · its stop 16630 m from you · leg 1/3", LogShareRules.text(e, known, utc))
        assertEquals("2027-01-15", LogShareRules.day(t0, utc))
        assertEquals("2027-01-16", LogShareRules.day(t0 + 16 * 3600, utc))
    }

    @Test fun batchStopsAtTheBudgetAndGoesOnFromThere() {
        val log = (0 until 10).reversed().map { entry(it, FieldEntry.Kind.MATCH, "m".repeat(80)) }
        val one = LogShareRules.text(log.last(), known, utc).toByteArray().size
        val b = LogShareRules.batch(log, null, one * 3 + 2, known, utc)
        assertEquals(3, b.lines.size)
        assertTrue(b.more)
        assertEquals(t0 + 2, b.through!!, 0.0)
        assertEquals(7, LogShareRules.batch(log, b.through, 1_000_000, known, utc).lines.size)
        assertTrue(LogShareRules.batch(log, null, 0, known).lines.isEmpty())
    }

    @Test fun exampleIsYourNewestRideLineScrubbed() {
        val log = listOf(entry(20, FieldEntry.Kind.MATCH, "detect · near BUas"), entry(10, FieldEntry.Kind.RIDE, "start · from Kerkstraat 12 · bus 305·7821"))
        assertEquals("2027-01-15 08:00:10 ride start · from Home · bus 305·7821", LogShareRules.example(log, known, utc))
        assertNull(LogShareRules.example(listOf(entry(0, FieldEntry.Kind.NET, "/x")), known))
        assertTrue(LogShareRules.SAMPLE.contains("ride start · Home on board, by itself · bus 305·7821"))
    }

    private fun state(lastTry: Double? = null, day: String = "2027-01-15", sent: Int = 0) =
        LogShareState.fresh(t0) { ByteArray(it) { 7 } }.copy(lastTry = lastTry, day = day, sentToday = sent)

    @Test fun dueAfterATripOrHourly() {
        val today = "2027-01-15"
        fun due(s: LogShareState, trig: LogShareRules.Trigger, running: Boolean = false, low: Boolean = false, on: Boolean = true, at: Int) =
            LogShareRules.due(s, on, trig, running, low, t0 + at, today)
        val tick = LogShareRules.Trigger.TICK
        val ended = LogShareRules.Trigger.TRIP_ENDED
        assertTrue(due(state(), tick, at = 0))
        assertFalse(due(state(), tick, on = false, at = 0))
        assertFalse(due(state(), ended, running = true, at = 0))
        assertFalse(due(state(), tick, low = true, at = 0))
        val tried = state(lastTry = t0)
        assertFalse(due(tried, tick, at = 3599))
        assertTrue(due(tried, tick, at = 3600))
        assertFalse(due(tried, ended, at = 59))
        assertTrue(due(tried, ended, at = 60))
        assertTrue(due(tried, tick, at = -10))
        assertFalse(due(state(sent = LogShareRules.PER_DAY), ended, at = 0))
        assertTrue(due(state(day = "2027-01-14", sent = LogShareRules.PER_DAY), ended, at = 0))
    }

    @Test fun budgetAndCounting() {
        val today = "2027-01-15"
        assertEquals(200 * 1024, LogShareRules.budget(state(), today))
        assertEquals(1000, LogShareRules.budget(state(sent = LogShareRules.PER_DAY - 1000), today))
        assertEquals(200 * 1024, LogShareRules.budget(state(day = "2027-01-14", sent = LogShareRules.PER_DAY), today))
        val b = LogShareBatch(listOf("a"), 500, t0 + 9)
        var s = LogShareRules.sent(state(sent = 100), b, t0 + 10, today)
        assertEquals(600, s.sentToday)
        assertEquals(t0 + 9, s.through!!, 0.0)
        assertTrue(s.sentEver)
        s = LogShareRules.sent(s, b, t0 + 90_000, "2027-01-16")
        assertEquals(500, s.sentToday)
        assertEquals("2027-01-16", s.day)
        assertEquals(t0 + 5, LogShareRules.tried(s, t0 + 5).lastTry!!, 0.0)
    }

    @Test fun installIdAndSecret() {
        val s = LogShareState.fresh(t0)
        assertEquals(32, s.install.length)
        assertEquals(64, s.secret.length)
        assertEquals(t0, s.through!!, 0.0)
        assertNotEquals(s.install, LogShareState.fresh(t0).install)
        val fixed = LogShareState.fresh(t0) { ByteArray(it) { 0xab.toByte() } }
        assertEquals("ab".repeat(16), fixed.install)
        val sent = fixed.copy(sentEver = true, through = t0 + 99)
        val r = sent.rotated()
        assertNotEquals(sent.install, r.install)
        assertNotEquals(sent.secret, r.secret)
        assertFalse(r.sentEver)
        assertEquals(t0 + 99, r.through!!, 0.0)
        assertEquals(r, LogShareState.decode(LogShareState.encode(r)))
        assertNull(LogShareState.decode(LogShareState.encode(r.copy(install = "not hex"))))
        assertNull(LogShareState.decode("{}"))
        assertNull(LogShareState.decode(null))
    }

    @Test fun putCarriesOnlyItsFourFields() {
        val put = LogSharePut("a".repeat(32), "b".repeat(64), "0.4.0 (4) Android", listOf("2027-01-15 08:00:00 ride end · by hand"))
        val o = FriendJson.parse(FriendJson.encode(LogSharePut.serializer(), put)) as JsonObject
        assertEquals(setOf("install", "secret", "app", "lines"), o.keys)
        val d = FriendJson.parse(FriendJson.encode(LogShareDelete.serializer(), LogShareDelete(put.install, put.secret))) as JsonObject
        assertEquals(setOf("install", "secret"), d.keys)
        // the relay's own check of the app field: /^[0-9A-Za-z .()_-]{1,40}$/
        assertTrue(Regex("^[0-9A-Za-z .()_-]{1,40}$").matches(put.app))
    }

    @Test fun crc32() {
        assertEquals(0xCBF43926L, Gzip.crc32("123456789".toByteArray()))
        assertEquals(0L, Gzip.crc32(ByteArray(0)))
    }

    @Test fun gzipWrapsRawDeflate() {
        val text = (0 until 200).joinToString("\n") { "2027-01-15 08:00:${it % 60} ride start · bus 305·7821" }.toByteArray()
        val z = Gzip.compress(text)!!
        assertArrayEquals(byteArrayOf(0x1f, 0x8b.toByte(), 0x08, 0x00), z.copyOfRange(0, 4))
        assertTrue(z.size < text.size)
        val back = ByteArrayOutputStream().also { GZIPInputStream(z.inputStream()).copyTo(it) }.toByteArray()
        assertArrayEquals(text, back)
        fun le32(i: Int) = (0 until 4).fold(0L) { v, k -> v or ((z[z.size - 8 + i + k].toLong() and 0xff) shl (8 * k)) }
        assertEquals(Gzip.crc32(text), le32(0))
        assertEquals(text.size.toLong(), le32(4))
    }
}
