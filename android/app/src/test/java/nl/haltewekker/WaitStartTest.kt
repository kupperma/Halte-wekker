package nl.haltewekker

import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.match.Fix
import nl.haltewekker.ride.WaitStart
import nl.haltewekker.ride.WaitStart.Call
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * (0.10.3) iOS 0.42.4 `WaitStartTests`, every vector: the trip starts while Fastest trip watches, wherever you got on.
 * Synthetic rides in Veghel: the 305 from the bus station past Biezendijk (the stop it planned) towards Eindhoven.
 */
class WaitStartTest {
    private val t0 = 7_000_000.0
    private val rules = WaitStart.Rules(oneLook = 20.0, close = 60.0)

    private val busStation = GeoPoint(51.6170, 5.5440)
    private val middle = GeoPoint(51.6140, 5.5390)
    private val biezendijk = GeoPoint(51.6100, 5.5330)
    private val further = GeoPoint(51.6000, 5.5200)
    private val eindhoven = GeoPoint(51.4430, 5.4800)

    private val stops = listOf(
        WaitStart.Stop("Bus station", busStation, t0),
        WaitStart.Stop("Middle", middle, t0 + 90),
        WaitStart.Stop("Biezendijk", biezendijk, t0 + 180),
        WaitStart.Stop("Further", further, t0 + 330),
        WaitStart.Stop("Eindhoven", eindhoven, t0 + 1800))

    /** Fixes every `every` s at `speed` along the stops' road from stop `k` on, starting at `start` s. */
    private fun ride(fromStop: Int, start: Double, seconds: Double, speed: Double = 9.0, every: Double = 2.0): List<Fix> {
        val road = stops.map { it.point }.drop(fromStop)
        val out = ArrayList<Fix>()
        var t = 0.0
        while (t <= seconds) {
            out.add(Fix(t0 + start + t, along(road, speed * t), 8.0, speed, 225.0))
            t += every
        }
        return out
    }

    private fun along(road: List<GeoPoint>, metres: Double): GeoPoint {
        var left = metres
        for (i in 1 until road.size) {
            val d = Geo.metres(road[i - 1], road[i])
            if (left <= d) {
                val f = if (d > 0) left / d else 0.0
                return GeoPoint(road[i - 1].lat + (road[i].lat - road[i - 1].lat) * f, road[i - 1].lon + (road[i].lon - road[i - 1].lon) * f)
            }
            left -= d
        }
        return road.last()
    }

    /** Standing at `p` from `start` s for `seconds`. */
    private fun stand(p: GeoPoint, start: Double, seconds: Double, every: Double = 5.0): List<Fix> {
        val out = ArrayList<Fix>()
        var t = 0.0
        while (t <= seconds) { out.add(Fix(t0 + start + t, p, 10.0, 0.0, -1.0)); t += every }
        return out
    }

    private data class Run(val id: String?, val at: Double?, val calls: List<Call>)

    /** Looks every 6 s up to `until` s; the matcher has `cands` from `from` s on. The first start and every call. */
    private fun looks(fixes: List<Fix>, until: Double, from: Double, motion: WaitStart.Hint = WaitStart.Hint.NONE,
                      cands: (Double) -> List<WaitStart.Candidate>): Run {
        var state = WaitStart.State()
        val calls = ArrayList<Call>()
        var t = 6.0
        while (t <= until) {
            val now = t0 + t
            val seen = fixes.filter { it.t <= now }
            val m = WaitStart.moving(seen, now)
            val c = if (t >= from) cands(t) else emptyList()
            val out = WaitStart.step(state, m, motion, c, rules)
            state = out.state
            calls.add(out.call)
            (out.call as? Call.Start)?.let { return Run(it.id, t, calls) }
            t += 6
        }
        return Run(null, null, calls)
    }

    private fun cand(id: String, line: String = "305", cost: Double, gps: Double? = 12.0, gpsFor: Double? = 30.0,
                     reaches: Boolean? = true, planned: Boolean = false, plannedLine: Boolean = true) =
        WaitStart.Candidate(id, "$line·${id.takeLast(4)}", line, cost, gps, gpsFor, reaches, planned, plannedLine)

    // the field report: on at an earlier stop, an earlier 305

    @Test fun boardingTheSameLineAtAnEarlierStop_startsWithin90s_andBoardsWhereYouGotOn() {
        val fixes = stand(busStation, -60.0, 60.0) + ride(0, 0.0, 120.0)
        val r = looks(fixes, 120.0, 20.0) { listOf(cand("trip-2718", cost = 25.0)) }
        assertEquals("trip-2718", r.id)
        assertNotNull(r.at)
        assertTrue("started within 90 s of boarding", (r.at ?: 999.0) <= 90)
        val now = t0 + (r.at ?: 0.0)
        val seen = fixes.filter { it.t <= now }
        val start = WaitStart.startedMoving(seen, now)
        assertNotNull(start)
        assertEquals("the leg starts at the bus station", 0, WaitStart.repoint(stops, start, seen.last().p, biezendijk))
    }

    @Test fun boardingAnEarlierDepartureOfThePlannedLine_byItsTimes_startsOnIt() {
        val fixes = stand(biezendijk, -60.0, 60.0) + ride(2, 0.0, 120.0)
        val r = looks(fixes, 120.0, 20.0) { listOf(cand("trip-1111", cost = 30.0, gps = null, gpsFor = null)) }
        assertEquals("trip-1111", r.id)
        assertTrue((r.at ?: 999.0) <= 90)
        val now = t0 + (r.at ?: 0.0)
        val seen = fixes.filter { it.t <= now }
        assertNull(WaitStart.repoint(stops, WaitStart.startedMoving(seen, now), seen.last().p, biezendijk))
    }

    @Test fun boardingThePlannedDepartureAtThePlannedStop_unchanged() {
        val fixes = stand(biezendijk, -60.0, 60.0) + ride(2, 0.0, 90.0)
        val r = looks(fixes, 90.0, 20.0) { listOf(cand("trip-0952", cost = 6.0, planned = true)) }
        assertEquals("trip-0952", r.id)
        assertEquals("one look, as soon as you've been at bus speed for 30 s", 30.0, r.at)
        val now = t0 + 30
        val seen = fixes.filter { it.t <= now }
        assertNull("the planned stop stays the leg's start", WaitStart.repoint(stops, WaitStart.startedMoving(seen, now), seen.last().p, biezendijk))
    }

    @Test fun theOneOnTheRoadItSharesWithThe306_stillStarts() {
        val fixes = stand(busStation, -30.0, 30.0) + ride(0, 0.0, 120.0)
        val r = looks(fixes, 120.0, 20.0) { t ->
            val a = cand("trip-2718", cost = 25.0)
            val b = cand("trip-3306", line = "306", cost = 22.0, reaches = false, plannedLine = false)
            if (t.toInt() % 12 == 0) listOf(b, a) else listOf(a, b)
        }
        assertEquals("trip-2718", r.id)
        assertTrue((r.at ?: 999.0) <= 90)
    }

    @Test fun anotherLineThatGetsYouThere_needsTwoLooksByGPS() {
        val fixes = ride(0, 0.0, 120.0)
        val r = looks(fixes, 120.0, 20.0) { listOf(cand("trip-0150", line = "150", cost = 10.0, plannedLine = false)) }
        assertEquals("trip-0150", r.id)
        assertEquals(36.0, r.at)
    }

    @Test fun byItsTimesAlone_anotherLineNeedsThreeLooks() {
        assertEquals(3, WaitStart.needed(cand("x", line = "150", cost = 10.0, gps = null, gpsFor = null, plannedLine = false), rules))
        assertEquals(1, WaitStart.needed(cand("y", cost = 10.0, gps = null, gpsFor = null, planned = true), rules))
        assertEquals(1, WaitStart.needed(cand("z", cost = 10.0), rules))
        assertEquals(2, WaitStart.needed(cand("z", cost = 25.0), rules))
    }

    // no start

    @Test fun standingAtTheStopWhileABusPasses_noStart() {
        val fixes = stand(busStation, 0.0, 240.0)
        val r = looks(fixes, 240.0, 0.0) { listOf(cand("trip-2718", cost = 5.0, planned = true)) }
        assertNull(r.id)
        assertTrue(r.calls.all { it == Call.Hold("standing") })
    }

    @Test fun walking_noStart() {
        val fixes = ride(0, 0.0, 240.0, speed = 1.4)
        assertNull(looks(fixes, 240.0, 20.0) { listOf(cand("trip-2718", cost = 5.0, planned = true)) }.id)
    }

    @Test fun cycling_noStart() {
        val slow = ride(0, 0.0, 240.0, speed = 5.0)
        assertNull(looks(slow, 240.0, 20.0) { listOf(cand("trip-2718", cost = 5.0, planned = true)) }.id)
        // a fast bike, motion says cycling (Android: the step detector's "walking")
        val fast = ride(0, 0.0, 240.0, speed = 7.5)
        val r = looks(fast, 240.0, 20.0, motion = WaitStart.Hint.AFOOT) { listOf(cand("trip-2718", cost = 5.0, planned = true)) }
        assertNull(r.id)
        assertTrue(r.calls.all { it == Call.Hold("walking or cycling (motion)") })
    }

    @Test fun automotive_startsSooner() {
        assertNull(WaitStart.movingRule(WaitStart.Moving(12.0, 8.0), WaitStart.Hint.VEHICLE))
        assertNotNull(WaitStart.movingRule(WaitStart.Moving(12.0, 8.0), WaitStart.Hint.NONE))
    }

    @Test fun aStopOnTheWay_stillCountsAsMoving() {
        val moving = ride(0, 0.0, 40.0)
        val stop = stand(moving.last().p, 42.0, 20.0, every = 2.0)
        val m = WaitStart.moving(moving + stop, t0 + 62)
        assertTrue(m.seconds >= 30)
        assertNull(WaitStart.movingRule(m, WaitStart.Hint.NONE))
    }

    // the wrong bus

    @Test fun sureOnALineThatDoesntGoThere_wrongBusOnce_notSilence() {
        val fixes = ride(0, 0.0, 120.0)
        var state = WaitStart.State()
        val calls = ArrayList<Call>()
        for (k in 0 until 4) {
            val now = t0 + 60 + k * 6.0
            val m = WaitStart.moving(fixes.filter { it.t <= now }, now)
            val c = listOf(cand("trip-0154", line = "154", cost = 8.0, gpsFor = 80.0, reaches = false, plannedLine = false))
            val out = WaitStart.step(state, m, WaitStart.Hint.NONE, c, rules)
            state = out.state
            calls.add(out.call)
        }
        assertEquals(Call.WrongBus("trip-0154"), calls.first())
        assertEquals("told once", 0, calls.drop(1).count { it == Call.WrongBus("trip-0154") })
        assertEquals(Call.Hold("not your way (told)"), calls.last())
    }

    @Test fun notYetSure_noWrongBus() {
        val m = WaitStart.Moving(40.0, 9.0)
        val c = listOf(cand("trip-0154", line = "154", cost = 8.0, gpsFor = 20.0, reaches = false, plannedLine = false))
        assertEquals(Call.Hold("not your way"), WaitStart.step(WaitStart.State(), m, WaitStart.Hint.NONE, c, rules).call)
    }

    @Test fun stopsNotKnown_holds() {
        val m = WaitStart.Moving(40.0, 9.0)
        val out = WaitStart.step(WaitStart.State(), m, WaitStart.Hint.NONE, listOf(cand("a", cost = 5.0, reaches = null)), rules)
        assertEquals(Call.Hold("its stops not known yet"), out.call)
    }

    // where it goes

    @Test fun reaches_aheadOnly() {
        val here = further
        assertTrue(WaitStart.reaches(stops, here, listOf(eindhoven), t0))
        assertFalse(WaitStart.reaches(stops, here, listOf(busStation), t0 + 400))
        assertFalse(WaitStart.reaches(stops, here, listOf(GeoPoint(51.69, 5.30)), t0))
    }

    @Test fun boardedAt_nearestStopToWhereYouStartedMoving() {
        val start = GeoPoint(51.6168, 5.5436)
        assertEquals(0, WaitStart.boardedAt(stops, start, further))
        assertNull(WaitStart.boardedAt(stops, GeoPoint(51.63, 5.58), further))
    }

    // the watching, not a screen

    @Test fun theLookRunsWhileItWatches_whateverIsOnScreen() {
        assertNull(WaitStart.lookRuns(watching = true, tripIdle = true, demo = false))
        assertEquals("not watching", WaitStart.lookRuns(watching = false, tripIdle = true, demo = false))
        assertEquals("a trip runs", WaitStart.lookRuns(watching = true, tripIdle = false, demo = false))
        assertEquals("the demo", WaitStart.lookRuns(watching = true, tripIdle = true, demo = true))
        assertEquals("wait · watching on · its look at what you get on runs (behind the screen)", WaitStart.onLine(again = false, inFront = false))
        assertEquals("wait · watching off · closed", WaitStart.offLine("closed"))
    }

    @Test fun logDue_everyLookWhileBusy_elseOnceAMinute() {
        val last = "standing" to t0
        assertTrue(WaitStart.logDue("standing", last, busy = true, now = t0 + 6))
        assertFalse(WaitStart.logDue("standing", last, busy = false, now = t0 + 6))
        assertTrue(WaitStart.logDue("standing", last, busy = false, now = t0 + 60))
        assertTrue(WaitStart.logDue("seen 1 of 2 looks", last, busy = false, now = t0 + 6))
        assertTrue(WaitStart.logDue("standing", null, busy = false, now = t0))
    }

    // the field log

    @Test fun logLine() {
        val m = WaitStart.Moving(40.0, 9.2)
        val c = listOf(cand("trip-2718", cost = 25.0), cand("trip-1234", line = "306", cost = 40.0, gps = null, gpsFor = null, reaches = false, plannedLine = false))
        assertEquals("wait · moving 9 m/s 40 s · candidates 305·2718 gps 12 s fits, 306·1234 times elsewhere · start 305·2718",
            WaitStart.logLine(m, c, Call.Start("trip-2718")))
        assertEquals("wait · moving 0 m/s 0 s · no candidates · held by standing", WaitStart.logLine(WaitStart.Moving(0.0, 0.0), emptyList(), Call.Hold("standing")))
    }
}
