package nl.haltewekker

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.friends.FriendJson
import nl.haltewekker.logs.FieldFormat
import nl.haltewekker.logs.GPSShareQueue
import nl.haltewekker.logs.GPSShareRide
import nl.haltewekker.logs.GPSShareRules
import nl.haltewekker.logs.LogShareBatch
import nl.haltewekker.logs.LogSharePut
import nl.haltewekker.logs.LogShareRules
import nl.haltewekker.logs.LogShareState
import nl.haltewekker.logs.Maker
import nl.haltewekker.logs.ShareAsk
import nl.haltewekker.logs.SharedFix
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** iOS `GPSShareTests` (0.32): a point as it leaves the phone, the trimming, the queue, the budget, the put, the question. */
class GPSShareTest {
    private val t0 = Fx.t0

    private fun at(m: Double, north: Double = 0.0, s: Double, speed: Double = 12.0): SharedFix {
        val p = Fx.east(m, north)
        return GPSShareRules.fix(t0 + s, p.lat, p.lon, 8.0, speed, 90.0, "1/2", "bus 305·7821", "a1b2c3d4")!!
    }

    private fun trip(metres: Double, from: Double = 0.0): List<SharedFix> =
        generateSequence(0.0) { it + 30 }.takeWhile { it <= metres }.map { at(from + it, s = it / 10) }.toList()

    @Test fun aPointIsRoundedAndTagged() {
        val f = GPSShareRules.fix(1_795_070_038.24, 51.690123456, 5.298714999, 8.4, 12.36, 87.4, "1/3", "bus 305·7821", "3f9a1c2e")!!
        assertEquals(1_795_070_038.2, f.t, 0.0)
        assertEquals(51.69012, f.lat, 0.0); assertEquals(5.29871, f.lon, 0.0)
        assertEquals(8.0, f.acc, 0.0); assertEquals(12.4, f.spd, 0.0); assertEquals(87.0, f.crs, 0.0)
        assertEquals("1/3", f.leg); assertEquals("bus 305·7821", f.veh)
        val json = FriendJson.encodeString(SharedFix.serializer(), f)
        assertTrue(json, json.contains("51.69012") && !json.contains("51.690123"))
        assertEquals(f, FriendJson.decode(SharedFix.serializer(), ShareAsk.SAMPLE_FIX))
        // the same keys and numbers as the sample (sorted keys on Android)
        assertEquals(FriendJson.write(FriendJson.parse(ShareAsk.SAMPLE_FIX.toByteArray())!!), json)
    }

    @Test fun unknownSpeedAndCourseAreMinusOne() {
        val f = GPSShareRules.fix(t0, 51.5, 5.1, 20.0, -1.0, -1.0, null, null, null)!!
        assertEquals(-1.0, f.spd, 0.0); assertEquals(-1.0, f.crs, 0.0); assertNull(f.veh)
    }

    @Test fun aRoughOrBrokenFixIsntKept() {
        assertNull(GPSShareRules.fix(t0, 51.5, 5.1, 151.0, 3.0, 0.0, null, null, null))
        assertNull(GPSShareRules.fix(t0, 51.5, 5.1, -1.0, 3.0, 0.0, null, null, null))
        assertNull(GPSShareRules.fix(t0, Double.NaN, 5.1, 5.0, 3.0, 0.0, null, null, null))
        assertNull(GPSShareRules.fix(t0, 0.0, 0.0, 5.0, 3.0, 0.0, null, null, null))
        assertNull(GPSShareRules.fix(0.0, 51.5, 5.1, 5.0, 3.0, 0.0, null, null, null))
    }

    @Test fun tagsAreTheLogLinesOwn() {
        assertEquals("1/3", GPSShareRules.leg(0, 3)); assertEquals("3/3", GPSShareRules.leg(2, 3)); assertEquals("3/3", GPSShareRules.leg(5, 3))
        assertNull(GPSShareRules.leg(0, 0))
        assertEquals("bus 305·7821", GPSShareRules.tag(FieldFormat.vehicle("305", "trip-xyz-7821", false)))
        assertEquals("train ?·a1b2", GPSShareRules.tag(FieldFormat.vehicle("?", "a1b2", true)))
        assertEquals("bus N3-4·1234", GPSShareRules.tag("bus N3&4·1234"))
        assertEquals(40, GPSShareRules.tag("x".repeat(60))?.length)
        assertNull(GPSShareRules.tag("   "))
    }

    @Test fun everyFewSeconds() {
        val a = at(0.0, s = 0.0)
        assertTrue(GPSShareRules.keep(a, null))
        assertFalse(GPSShareRules.keep(at(10.0, s = 1.0), a))
        assertFalse(GPSShareRules.keep(at(20.0, s = 2.9), a))
        assertTrue(GPSShareRules.keep(at(30.0, s = 3.0), a))
        assertTrue(GPSShareRules.keep(at(30.0, s = -5.0), a))
    }

    @Test fun theFirstAndLast500mOfATripGo() {
        val fixes = trip(3000.0)
        val kept = GPSShareRules.trimmed(fixes)
        assertFalse(kept.isEmpty())
        for (f in kept) {
            assertTrue(Geo.metres(f.point, fixes.first().point) > 500)
            assertTrue(Geo.metres(f.point, fixes.last().point) > 500)
        }
        assertEquals(2000.0, Geo.metres(kept.first().point, kept.last().point), 70.0)
    }

    @Test fun aShortTripSendsNothing() {
        assertTrue(GPSShareRules.trimmed(trip(900.0)).isEmpty())
        assertTrue(GPSShareRules.trimmed(trip(1000.0)).isEmpty())
        assertTrue(GPSShareRules.trimmed(emptyList()).isEmpty())
        assertTrue(GPSShareRules.trimmed(listOf(at(0.0, s = 0.0))).isEmpty())
    }

    @Test fun aTripThatComesBackNearItsStartKeepsAway() {
        val back = generateSequence(2000.0) { it - 30 }.takeWhile { it >= 100 }.toList()
        val fixes = trip(2000.0) + back.mapIndexed { i, m -> at(m, 40.0, s = 200 + i * 3.0) }
        val kept = GPSShareRules.trimmed(fixes)
        assertFalse(kept.isEmpty())
        for (f in kept) {
            assertTrue(Geo.metres(f.point, fixes.first().point) > 500)
            assertTrue(Geo.metres(f.point, fixes.last().point) > 500)
        }
    }

    @Test fun jitterWhileStandingDoesntCountAsTravelled() {
        val fixes = (0 until 200).map { i -> at((i % 2) * 20.0, s = i * 3.0) } + trip(3000.0).map { it.copy(t = it.t + 600) }
        for (f in GPSShareRules.trimmed(fixes)) assertTrue(Geo.metres(f.point, fixes.first().point) > 500)
    }

    @Test fun nothingNearYourPlaces() {
        val fixes = trip(6000.0)
        val home = Fx.east(3000.0, 200.0)
        val kept = GPSShareRules.outsideZones(fixes, listOf(home))
        assertTrue(kept.size < fixes.size)
        for (f in kept) assertTrue(Geo.metres(f.point, home) > 500)
        assertEquals(fixes.size, GPSShareRules.outsideZones(fixes, listOf(GeoPoint(0.0, 0.0))).size)
    }

    @Test fun aFinishedTripIsTrimmedThenKeptAwayFromPlaces() {
        val ride = GPSShareRide("a1b2c3d4", trip(6000.0))
        val school = Fx.east(3000.0)
        val out = GPSShareRules.finished(ride, listOf(school))
        assertFalse(out.isEmpty())
        for (f in out) {
            assertTrue(Geo.metres(f.point, school) > 500)
            assertTrue(Geo.metres(f.point, ride.fixes.first().point) > 500)
            assertTrue(Geo.metres(f.point, ride.fixes.last().point) > 500)
        }
        assertEquals(out.map { it.t }.sorted(), out.map { it.t })
    }

    @Test fun theQueueKeepsATripThenItsTrimmedPoints() {
        var q = GPSShareQueue()
        var made = 0
        for (f in trip(3000.0)) q = q.heard(f) { made += 1; "0000000$made" }
        assertEquals(1, made)
        assertEquals(trip(3000.0).size, q.current?.fixes?.size)
        assertTrue(q.current!!.fixes.all { it.ride == "00000001" })
        assertTrue(q.ready.isEmpty())
        q = q.finishRide(emptyList())
        assertNull(q.current)
        assertFalse(q.ready.isEmpty())
        val n = q.ready.size
        q = q.sent(2); assertEquals(n - 2, q.ready.size)
        q = q.sent(10_000); assertTrue(q.ready.isEmpty())
        q = q.heard(at(0.0, s = 1000.0)) { "bbbbbbbb" }
        assertEquals("bbbbbbbb", q.current?.ride)
        assertEquals(q, GPSShareQueue.decode(GPSShareQueue.encode(q)))
        assertEquals(GPSShareQueue(), GPSShareQueue.decode("nonsense"))
        assertEquals(GPSShareQueue(), GPSShareQueue.decode(null))
    }

    @Test fun theQueueKeepsEveryFewSecondsAndHasCaps() {
        var q = GPSShareQueue()
        for (i in 0 until 30) q = q.heard(at(i.toDouble(), s = i.toDouble())) { "a" }
        assertEquals(10, q.current?.fixes?.size)
        var long = GPSShareQueue()
        for (i in 0 until GPSShareRules.MAX_RIDE + 50) long = long.heard(at(i.toDouble(), s = i * 3.0)) { "a" }
        assertEquals(GPSShareRules.MAX_RIDE, long.current?.fixes?.size)
        var full = GPSShareQueue(GPSShareRide("bbbbbbbb", trip(3000.0).map { it.copy(ride = "bbbbbbbb") }), List(GPSShareRules.MAX_READY) { at(0.0, s = 0.0) })
        full = full.finishRide(emptyList())
        assertEquals(GPSShareRules.MAX_READY, full.ready.size)
        assertEquals("bbbbbbbb", full.ready.last().ride)
        assertEquals("a1b2c3d4", full.ready.first().ride)
    }

    @Test fun aBatchFitsItsBudget() {
        val fixes = trip(6000.0)
        val one = GPSShareRules.size(fixes[0])
        assertTrue(one in 61..199)
        val ten = fixes.take(10).sumOf { GPSShareRules.size(it) }
        val b = GPSShareRules.batch(fixes, ten + 5)
        assertEquals(10, b.fixes.size); assertTrue(b.more); assertEquals(ten, b.bytes)
        val all = GPSShareRules.batch(fixes, 10_000_000)
        assertEquals(fixes.size, all.fixes.size); assertFalse(all.more)
        assertTrue(GPSShareRules.batch(fixes, 0).fixes.isEmpty())
        val hour = (0 until 1200).map { at(it * 30.0, s = it * 3.0) }
        assertFalse(GPSShareRules.batch(hour, GPSShareRules.PER_UPLOAD).more)
    }

    private fun state(day: String = "2027-01-15", fixBytes: Int? = null) =
        LogShareState("a".repeat(32), "b".repeat(64), through = t0, day = day, fixBytesToday = fixBytes)

    @Test fun pointsHaveTheirOwnDailyBudget() {
        val today = "2027-01-15"
        assertEquals(600 * 1024, GPSShareRules.budget(state(), today))
        assertEquals(100, GPSShareRules.budget(state(fixBytes = GPSShareRules.PER_DAY - 100), today))
        assertEquals(0, GPSShareRules.budget(state(fixBytes = GPSShareRules.PER_DAY), today))
        assertEquals(600 * 1024, GPSShareRules.budget(state(day = "2027-01-14", fixBytes = GPSShareRules.PER_DAY), today))
        var s = LogShareRules.sent(state(fixBytes = 1000), LogShareBatch(), t0, today, fixBytes = 500)
        assertEquals(1500, s.fixBytesToday); assertEquals(0, s.sentToday); assertTrue(s.sentEver)
        s = LogShareRules.sent(s, LogShareBatch(), t0 + 90_000, "2027-01-16", fixBytes = 200)
        assertEquals(200, s.fixBytesToday)
    }

    @Test fun dueWithPointsWaiting() {
        val today = "2027-01-15"
        var used = state().copy(sentToday = LogShareRules.PER_DAY)
        assertFalse(LogShareRules.due(used, true, LogShareRules.Trigger.TRIP_ENDED, false, false, t0, today))
        assertTrue(LogShareRules.due(used, true, LogShareRules.Trigger.TRIP_ENDED, false, false, t0, today, fixes = true))
        used = used.copy(fixBytesToday = GPSShareRules.PER_DAY)
        assertFalse(LogShareRules.due(used, true, LogShareRules.Trigger.TRIP_ENDED, false, false, t0, today, fixes = true))
        assertFalse(LogShareRules.due(state(), true, LogShareRules.Trigger.TRIP_ENDED, true, false, t0, today, fixes = true))
        assertFalse(LogShareRules.due(state(), true, LogShareRules.Trigger.TRIP_ENDED, false, true, t0, today, fixes = true))
    }

    @Test fun aStateSavedBeforePointsStillReads() {
        val old = """{"install":"${"a".repeat(32)}","secret":"${"b".repeat(64)}","day":"2027-01-15","sentToday":10,"sentEver":true}"""
        val s = LogShareState.decode(old)
        assertNotNull(s); assertNull(s?.fixBytesToday); assertEquals(10, s?.sentToday)
    }

    @Test fun thePutsShape() {
        val s = state()
        var put = LogSharePut(s.install, s.secret, "0.6.0 (7) Android", listOf("a line"))
        var o = FriendJson.parse(FriendJson.encode(LogSharePut.serializer(), put)) as JsonObject
        assertEquals(setOf("install", "secret", "app", "lines"), o.keys)
        put = put.copy(fixes = listOf(at(0.0, s = 0.0)), tz = 3600)
        o = FriendJson.parse(FriendJson.encode(LogSharePut.serializer(), put)) as JsonObject
        assertEquals(setOf("install", "secret", "app", "lines", "fixes", "tz"), o.keys)
        assertEquals(setOf("t", "lat", "lon", "acc", "spd", "crs", "leg", "veh", "ride"), ((o["fixes"] as JsonArray)[0] as JsonObject).keys)
        assertEquals("3600", (o["tz"] as JsonPrimitive).content)
    }

    @Test fun aRideIdIs8Hex() {
        assertEquals("abababab", GPSShareRules.rideId { ByteArray(it) { 0xAB.toByte() } })
        assertEquals(8, GPSShareRules.rideId().length)
    }

    @Test fun theCardShowsOnceAfterASetupThatDidntAsk() {
        assertTrue(ShareAsk.showCard(true, false, false))
        assertFalse(ShareAsk.showCard(true, true, false))
        assertFalse(ShareAsk.showCard(false, false, false))
        assertFalse(ShareAsk.showCard(true, false, true))
    }

    @Test fun theWordsNameWhoGetsIt() {
        assertEquals("Nana", Maker.NAME)
        for (t in listOf(ShareAsk.intro, ShareAsk.who)) assertTrue(t, t.contains(Maker.NAME))
        assertTrue(ShareAsk.FIXES_TEXT.contains("500 m"))
        assertTrue(ShareAsk.who.contains("Delete what I sent"))
        assertEquals("Nothing shared", ShareAsk.words(false, false))
        assertEquals("Ride logs and GPS points during rides", ShareAsk.words(true, true))
    }
}
