package nl.haltewekker

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.ride.ActivityCadence
import nl.haltewekker.ride.CandidatePrefilter
import nl.haltewekker.ride.ChangeWait
import nl.haltewekker.ride.RideAccuracy
import nl.haltewekker.ride.RideNet
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * iOS 0.42.9's battery and data rules (`ride/RideSaver.kt`) against docs/battery-vectors.json (iOS checks the same
 * vectors), and synthetic legs of the usual shapes: rough for most of them, the best always back before the wake
 * point.
 */
class RideSaverTest {
    private val v: JsonObject by lazy {
        val f = listOf("../../docs/battery-vectors.json", "../docs/battery-vectors.json", "docs/battery-vectors.json").map(::File).first { it.exists() }
        Json.parseToJsonElement(f.readText()).jsonObject
    }
    private fun JsonObject.s(k: String) = (this[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
    private fun JsonObject.d(k: String) = (this[k] as? JsonPrimitive)?.takeIf { !it.isString }?.content?.toDoubleOrNull()
    private fun JsonObject.b(k: String) = (this[k] as? JsonPrimitive)?.takeIf { !it.isString }?.content?.toBooleanStrictOrNull()
    private fun list(k: String) = (v[k] as JsonArray).map { it.jsonObject }
    private fun point(e: JsonElement?): GeoPoint? = (e as? JsonArray)?.takeIf { it.size == 2 }?.let {
        GeoPoint((it[0] as JsonPrimitive).content.toDouble(), (it[1] as JsonPrimitive).content.toDouble())
    }

    @Test fun accuracyVectors() {
        val cases = list("accuracy")
        assertTrue(cases.size > 20)
        for (c in cases) {
            val i = c["input"]!!.jsonObject
            val input = RideAccuracy.Input(
                enabled = i.b("enabled") ?: true, asleep = i.b("asleep") ?: true, confirmed = i.b("confirmed") ?: false,
                confirmedAge = i.d("confirmedAge"), isTrain = i.b("isTrain") ?: false, metresToStop = i.d("metresToStop"),
                accuracy = i.d("accuracy"), fixAge = i.d("fixAge"), speed = i.d("speed"), wakeMetres = i.d("wakeMetres") ?: 0.0,
                secondsToStop = i.d("secondsToStop"), legAge = i.d("legAge") ?: 0.0, backstop = i.b("backstop") ?: false,
                needBest = i.b("needBest") ?: false, wasReduced = i.b("wasReduced") ?: false)
            assertEquals(c.s("name"), c.s("tier"), RideAccuracy.tier(input).name.lowercase())
        }
    }

    @Test fun changeWaitVectors() {
        for (c in list("changeWait")) {
            assertEquals(c.toString(), c.b("low"), ChangeWait.low(c.d("standingFor"), c.d("nextIn"), c.b("moving") ?: false, c.b("inVehicle") ?: false))
        }
    }

    private fun change(s: String?) = when (s) {
        "say" -> ActivityCadence.Change.SAY
        "meaningful" -> ActivityCadence.Change.MEANINGFUL
        "look" -> ActivityCadence.Change.LOOK
        else -> ActivityCadence.Change.NONE
    }

    @Test fun cadenceVectors() {
        for (c in list("cadence")) {
            val ch = change(c.s("change")); val near = c.b("near") ?: false; val since = c.d("sinceLast") ?: 0.0
            assertEquals(c.toString(), c.b("send"), ActivityCadence.send(ch, near, since))
            assertEquals(c.toString(), c.d("later"), ActivityCadence.later(ch, near, since))
        }
        for (c in list("cadenceNear")) assertEquals(c.toString(), c.b("near"), ActivityCadence.near(c.d("secondsToStop"), c.b("awake") ?: false))
        assertEquals(1L, ActivityCadence.minute(119.0))
        assertEquals(19, ActivityCadence.distanceStep(1950.0))
        assertEquals(24, ActivityCadence.distanceStep(2400.0))
        assertEquals(-1, ActivityCadence.distanceStep(null))
    }

    @Test fun rideNearVectors() {
        for (c in list("rideNear")) {
            assertEquals(c.toString(), c.b("near"), RideNet.near(c.d("secondsToStop"), c.d("metresToStop"), c.d("wakeMetres") ?: 0.0, c.b("awake") ?: false))
        }
        assertEquals(120.0, RideNet.tripEvery(false), 0.0)
        assertEquals(45.0, RideNet.tripEvery(true), 0.0)
        assertEquals(3, RideNet.ways(10, false))
        assertEquals(10, RideNet.ways(10, true))
    }

    @Test fun prefilterVectors() {
        val p = v["prefilter"]!!.jsonObject
        val you = p["you"]!!.jsonArray.mapNotNull(::point)
        val planned = p.s("planned")
        val built = p["candidates"]!!.jsonArray.map { e ->
            val c = e.jsonObject
            val k = CandidatePrefilter.Candidate(c.s("tripId")!!, c.s("line")!!, c.b("isTrain") ?: false,
                c["paths"]!!.jsonArray.map { path -> path.jsonArray.mapNotNull(::point) }, point(c["gps"]), c.d("gpsAge"))
            assertEquals(k.tripId, c.s("drop"), CandidatePrefilter.drop(k, you, planned)?.name?.lowercase())
            k
        }
        val (kept, counts) = CandidatePrefilter.filter(built, you, planned) { it }
        val want = p["counts"]!!.jsonObject
        assertEquals(want.d("coach")!!.toInt(), counts.coach)
        assertEquals(want.d("route")!!.toInt(), counts.route)
        assertEquals(want.d("far")!!.toInt(), counts.far)
        assertTrue(kept.any { it.tripId == planned })
        assertEquals("prefilter · board · 6 of 12 left out (2 coaches, 2 off their route, 2 far by their GPS)",
            CandidatePrefilter.line("board", counts, built.size))
    }

    /** iOS `RideSaverTests.ride`, number for number: one leg, second by second. */
    private fun ride(metres: Double, speed: Double, isTrain: Boolean, wake: Double, stopsAt: List<Double>, seed: Long, rough: Double): Triple<Double, Double?, Double> {
        var s = seed.toULong()
        fun next(): Double { s = s * 6364136223846793005UL + 1442695040888963407UL; return (s shr 11).toDouble() / (1L shl 53).toDouble() }
        val stops = ArrayDeque(stopsAt)
        var d = metres; var t = 0.0; var tier = RideAccuracy.Tier.BEST
        var lastFixAt = 0.0; var lastFixD = d; var lastAcc = 10.0; var lastPos = d
        var lastPass: Double? = null; var lastEval = 0.0; var standing = 0.0
        var reduced = 0.0; var total = 0.0; var bestAt: Double? = null; var nearest = Double.MAX_VALUE
        while (d > 0) {
            if (standing > 0) standing -= 1 else {
                d = maxOf(0.0, d - speed)
                if (stops.isNotEmpty() && d <= stops.first()) { stops.removeFirst(); standing = 60.0 }
            }
            t += 1
            val filter = if (tier == RideAccuracy.Tier.REDUCED) RideAccuracy.REDUCED_FILTER else 25.0
            var evaluate = t - lastEval >= RideAccuracy.LOOK_EVERY
            if (Math.abs(lastPos - d) >= filter) {
                val acc = if (tier == RideAccuracy.Tier.REDUCED) 30 + next() * rough else 5 + next() * 10
                val err = (next() * 2 - 1) * acc
                lastFixAt = t; lastPos = d; lastFixD = maxOf(0.0, d + err); lastAcc = acc
                evaluate = true
            }
            if (tier == RideAccuracy.Tier.BEST && t >= 90 && t.toInt() % 30 == 0) lastPass = t
            if (evaluate) {
                lastEval = t
                val nx = RideAccuracy.tier(RideAccuracy.Input(confirmed = lastPass != null, confirmedAge = lastPass?.let { t - it },
                    isTrain = isTrain, metresToStop = lastFixD, accuracy = lastAcc, fixAge = t - lastFixAt,
                    speed = if (tier == RideAccuracy.Tier.BEST) speed else null, wakeMetres = wake,
                    secondsToStop = d / speed + stops.size * 60 + standing.toInt(), legAge = t,
                    wasReduced = tier == RideAccuracy.Tier.REDUCED, asleep = d > wake))
                if (tier == RideAccuracy.Tier.REDUCED && nx == RideAccuracy.Tier.BEST) bestAt = d
                tier = nx
            }
            if (tier == RideAccuracy.Tier.REDUCED) { reduced += 1; nearest = minOf(nearest, d) }
            total += 1
        }
        return Triple(reduced / total, bestAt, nearest)
    }

    @Test fun trainLegReplay() {
        for ((k, speed) in listOf(30.0, 39.0, 45.0).withIndex()) for (seed in 1..20) {
            val (share, bestAt, nearest) = ride(51_000.0, speed, true, 5000.0, listOf(38_000.0, 24_000.0, 12_000.0), (seed * 31 + k).toLong(), 900.0)
            assertTrue("speed $speed seed $seed", share > 0.55)
            assertTrue("speed $speed seed $seed", nearest >= 5000 + RideAccuracy.EXIT_MARGIN)
            bestAt?.let { assertTrue(it >= 5000 + RideAccuracy.EXIT_MARGIN) }
        }
    }

    @Test fun busLegReplay() {
        for (seed in 1..20) {
            val (share, _, nearest) = ride(19_500.0, 13.0, false, 2000.0, listOf(16_000.0, 12_000.0, 8000.0, 5000.0), seed.toLong(), 400.0)
            assertTrue("seed $seed", share > 0.4)
            assertTrue("seed $seed", nearest >= maxOf(RideAccuracy.BUS_BEST, 2000 + RideAccuracy.EXIT_MARGIN))
        }
    }

    @Test fun changeWaitReplay() {
        val wait = 33 * 60.0
        var low = 0
        var t = 0.0
        while (t < wait) { if (ChangeWait.low(t, wait - t, false, false)) low++; t += 1 }
        assertEquals(1620, low)
        assertFalse(ChangeWait.low(600.0, 900.0, true, false))
    }
}
