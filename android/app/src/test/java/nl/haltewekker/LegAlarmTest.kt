package nl.haltewekker

import nl.haltewekker.core.GeoPoint
import nl.haltewekker.live.GPSFix
import nl.haltewekker.live.RealPositions
import nl.haltewekker.ride.LegAlarm
import nl.haltewekker.ride.LegAlarm.Do
import nl.haltewekker.ride.MissCall
import nl.haltewekker.ride.Phase
import nl.haltewekker.ride.ShortLeg
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * (0.9.1) The ride's ring decision on whole synthetic legs (`LegAlarm`, as `RideService` applies it): a normal leg's
 * alarm waits out the first minute and then always rings; a short leg never rings but gets the quiet "Get off at the
 * next stop"; the next leg's planned ride starts the next leg.
 */
class LegAlarmTest {
    /** One fix of a synthetic leg: seconds into the leg, metres to its stop, accuracy, whether the wake rule fires. */
    private data class F(val t: Double, val metres: Double, val accuracy: Double = 10.0, val fired: Boolean)

    /** Runs fixes through `LegAlarm` as the ride does (the notice after each fix): every act with its time. */
    private fun run(fixes: List<F>, short: Boolean, secondsLeft: (Double) -> Double? = { null }, beforeAt: Double? = null): List<Pair<Double, Do>> {
        var leg = LegAlarm.Leg()
        val out = ArrayList<Pair<Double, Do>>()
        for (f in fixes) {
            val st = LegAlarm.fix(leg, f.t, f.metres, f.accuracy, f.fired && leg.phase == Phase.SLEEPING, short)
            leg = st.leg
            if (st.act != Do.NOTHING) out.add(f.t to st.act)
            if (st.act == Do.ARRIVE) break
            val n = LegAlarm.notice(leg, f.t, LegAlarm.beforeReached(beforeAt, f.t), secondsLeft(f.t), f.metres)
            leg = n.leg
            if (n.act == Do.NOTICE) out.add(f.t to Do.NOTICE)
        }
        return out
    }

    private fun approach(from: Double, speed: Double, wake: Double, until: Double, every: Double = 5.0): List<F> {
        val l = ArrayList<F>()
        var t = 0.0
        while (t <= until) {
            val d = maxOf(0.0, from - speed * t)
            l.add(F(t, d, fired = d <= wake))
            t += every
        }
        return l
    }

    @Test fun normalLegRingsAfterTheFirstMinute() {
        // 2.3 km out at 10 m/s: inside the 2 km wake at 30 s; held until 60 s, then it rings (once: the alarm phase)
        val acts = run(approach(2300.0, 10.0, 2000.0, 120.0), short = false)
        assertEquals(Do.HOLD, acts.first().second); assertEquals(30.0, acts.first().first, 0.0)
        assertTrue(acts.filter { it.first < 60 }.all { it.second == Do.HOLD })
        assertEquals(listOf(60.0 to Do.RING), acts.filter { it.second == Do.RING })
        assertTrue(acts.none { it.second == Do.WAKE_SHORT || it.second == Do.WAKE_EARLY || it.second == Do.NOTICE })
    }

    @Test fun normalLegLaterAlwaysRings() {
        // a 12 km bus leg: the wake rule fires at 1000 s, it rings at once
        val acts = run(approach(12_000.0, 10.0, 2000.0, 1100.0, every = 10.0), short = false)
        assertEquals(listOf(1000.0 to Do.RING), acts)
    }

    @Test fun noRingInTheFirstMinuteEvenOnABadFixRun() {
        // rough fixes (300 m) never fire or set where it started; the first good one after 60 s rings
        val fixes = listOf(F(5.0, 1500.0, 300.0, true), F(25.0, 1400.0, 300.0, true), F(45.0, 1300.0, 20.0, true), F(70.0, 1100.0, 20.0, true))
        assertEquals(listOf(45.0 to Do.HOLD, 70.0 to Do.RING), run(fixes, short = false))
        assertEquals(1300.0, LegAlarm.fix(LegAlarm.Leg(), 45.0, 1300.0, 20.0, false, false).leg.startedMetres!!, 0.0)
        assertNull(LegAlarm.fix(LegAlarm.Leg(), 5.0, 1500.0, 300.0, false, false).leg.startedMetres)
    }

    @Test fun startedInsideItsWakeWakesSilently() {
        // a 3 km leg started 1.9 km from its stop (inside 2 km): awake at the first fix, never a ring
        val acts = run(approach(1900.0, 10.0, 2000.0, 200.0), short = false)
        assertEquals(0.0 to Do.WAKE_EARLY, acts.first())
        assertTrue(acts.none { it.second == Do.RING })
        // there only within half the way it started from (≤ 450 m) and after its first minute
        assertEquals(Do.ARRIVE, acts.last().second); assertTrue(acts.last().first >= 60)
    }

    @Test fun shortLegNeverRingsButGetsTheQuietWord() {
        // a 600 m hop (wake 2 km): the first fix fires, quiet; "Get off at the next stop" once, after the first minute,
        // 90 s before it's in (in at 150 s); at the stop only within 300 m (half of 600) and after the minute
        assertTrue(ShortLeg.isShort(LegAlarm.span(GeoPoint(52.0, 5.0), GeoPoint(52.0, 5.0087)), 2000.0))
        val fixes = (0..40).map { k -> val t = k * 5.0; F(t, maxOf(0.0, 600.0 - 4.0 * t), fired = true) }
        val acts = run(fixes, short = true, secondsLeft = { 150.0 - it })
        assertEquals(0.0 to Do.WAKE_SHORT, acts.first())
        assertTrue(acts.none { it.second == Do.RING || it.second == Do.HOLD })
        assertEquals(listOf(60.0 to Do.NOTICE), acts.filter { it.second == Do.NOTICE })
        val arrive = acts.first { it.second == Do.ARRIVE }
        assertTrue(arrive.first >= 60); assertTrue(600.0 - 4.0 * arrive.first <= 300.0)
        assertTrue(acts.filter { it.second == Do.NOT_YET }.all { it.first < arrive.first })
    }

    @Test fun shortLegFiringLateStaysQuiet() {
        // a 790 m leg with a 400 m wake (short: under 800 m) that only fires after the first minute: still no alarm
        assertTrue(ShortLeg.isShort(790.0, 400.0))
        val fixes = (0..30).map { k -> val t = k * 5.0; val d = maxOf(0.0, 790.0 - 4.0 * t); F(t, d, fired = d <= 400) }
        val acts = run(fixes, short = true)
        assertEquals(Do.WAKE_SHORT, acts.first().second); assertTrue(acts.first().first > 60)
        assertTrue(acts.none { it.second == Do.RING })
        // no times: the word at half the way it started from (790 m → 395 m)
        assertEquals(1, acts.count { it.second == Do.NOTICE })
    }

    @Test fun shortNoticeByTheStopBefore() {
        val leg = LegAlarm.Leg(Phase.AWAKE, quiet = true, startedMetres = 700.0)
        assertEquals(Do.NOTHING, LegAlarm.notice(leg, 40.0, true, 300.0, 600.0).act)          // first minute
        assertEquals(Do.NOTICE, LegAlarm.notice(leg, 70.0, LegAlarm.beforeReached(100.0, 75.0), 300.0, 600.0).act)
        assertEquals(Do.NOTHING, LegAlarm.notice(leg.copy(told = true), 70.0, true, 30.0, 100.0).act)
        assertEquals(Do.NOTHING, LegAlarm.notice(leg.copy(quiet = false), 70.0, true, 30.0, 100.0).act)  // a normal awake leg
        assertFalse(LegAlarm.beforeReached(100.0, 60.0)); assertFalse(LegAlarm.beforeReached(null, 1e9))
    }

    @Test fun deadReckoningFollowsTheSameRules() {
        val asleep = LegAlarm.Leg()
        assertEquals(Do.NOTHING, LegAlarm.reckoned(asleep, 30.0, true, false).act)
        assertEquals(Do.RING, LegAlarm.reckoned(asleep, 61.0, true, false).act)
        assertEquals(Phase.ALARM, LegAlarm.reckoned(asleep, 61.0, true, false).leg.phase)
        assertEquals(Do.WAKE_SHORT, LegAlarm.reckoned(asleep, 61.0, true, true).act)
        assertTrue(LegAlarm.reckoned(asleep, 61.0, true, true).leg.quiet)
        assertEquals(Do.NOTHING, LegAlarm.reckoned(asleep, 61.0, false, false).act)
        assertEquals(Do.NOTHING, LegAlarm.reckoned(asleep.copy(phase = Phase.AWAKE), 61.0, true, false).act)
    }

    @Test fun ringingOrAwakeAfterAStopDoesNothingMore() {
        val ringing = LegAlarm.Leg(Phase.ALARM)
        assertEquals(Do.NOTHING, LegAlarm.fix(ringing, 300.0, 200.0, 10.0, true, false).act)
        // awake after Stop alarm with "Ring at the stop": there at 450 m, whatever the minute
        assertEquals(Do.ARRIVE, LegAlarm.fix(LegAlarm.Leg(Phase.AWAKE), 30.0, 440.0, 10.0, false, false).act)
        assertEquals(Do.NOTHING, LegAlarm.fix(LegAlarm.Leg(Phase.AWAKE), 30.0, 440.0, 700.0, false, false).act)
    }

    @Test fun nextLegsPlannedRideStartsTheNextLeg() {
        // a bus to the station, then the train: going away from the bus's stop on the planned train
        assertEquals(LegAlarm.Road.NextLeg("ic-3540"), LegAlarm.onRoad(listOf("ic-3538", "ic-3540"), "bus-306", "ic-3540", "bus-306"))
        assertEquals(LegAlarm.Road.NextLeg("ic-3540"), LegAlarm.onRoad(listOf("ic-3540"), null, "ic-3540", "bus-306"))
        // the bus you're on is on this road after all: carry on
        assertEquals(LegAlarm.Road.CarryOn, LegAlarm.onRoad(listOf("bus-306", "ic-3540"), "bus-306", "ic-3540", "bus-306"))
        // another train on the same track: not the planned one, nothing to do (no plan again, no pick)
        assertEquals(LegAlarm.Road.Nothing, LegAlarm.onRoad(listOf("ic-3538"), "bus-306", "ic-3540", "bus-306"))
        assertEquals(LegAlarm.Road.Nothing, LegAlarm.onRoad(listOf("ic-3540"), null, null, "bus-306"))
        assertEquals(LegAlarm.Road.Nothing, LegAlarm.onRoad(listOf("x"), null, "x", "x"))        // the same trip both legs
        // going away: 800 m further than you've been near the stop, 2 km further out
        assertTrue(LegAlarm.goingAway(300.0, 1200.0)); assertFalse(LegAlarm.goingAway(300.0, 1000.0))
        assertFalse(LegAlarm.goingAway(5000.0, 6500.0)); assertTrue(LegAlarm.goingAway(5000.0, 7100.0)); assertFalse(LegAlarm.goingAway(null, 9e9))
        assertTrue(LegAlarm.moving(12.0, 15.0)); assertFalse(LegAlarm.moving(3.0, 15.0)); assertFalse(LegAlarm.moving(12.0, 150.0))
    }

    @Test fun nextLegSequence() {
        // leg 1 (a 700 m bus) never got within 450 m by GPS; you're on the train going away: closest 520 m, then 1400 m
        var closest: Double? = null
        var started: String? = null
        for ((d, v) in listOf(900.0 to 4.0, 700.0 to 5.0, 520.0 to 1.0, 800.0 to 9.0, 1400.0 to 20.0)) {
            val away = LegAlarm.goingAway(closest, d) && LegAlarm.moving(v, 10.0)
            closest = minOf(closest ?: d, d)
            if (away) started = (LegAlarm.onRoad(listOf("ic-3540", "ic-3542"), "bus-306", "ic-3540", "bus-306") as? LegAlarm.Road.NextLeg)?.tripId
        }
        assertEquals("ic-3540", started)
    }

    @Test fun nextRideSeenOnItsRoad() {
        // a straight road east, stops every ~690 m; you change at the third stop
        val stops = (0..4).map { GeoPoint(52.0, 5.0 + 0.01 * it) }
        val from = stops[2]
        assertEquals(MissCall.Seen.NOT_LEFT, MissCall.seenOnRoad(emptyList(), stops, from, GeoPoint(52.0, 5.015), 30.0))
        assertEquals(MissCall.Seen.GONE, MissCall.seenOnRoad(emptyList(), stops, from, GeoPoint(52.0, 5.025), 30.0))
        assertEquals(MissCall.Seen.NONE, MissCall.seenOnRoad(emptyList(), stops, from, GeoPoint(52.0, 5.025), 400.0))   // too old
        assertEquals(MissCall.Seen.NONE, MissCall.seenOnRoad(emptyList(), stops, from, GeoPoint(52.01, 5.025), 30.0))   // off its road
        assertEquals(MissCall.Seen.NONE, MissCall.seenOnRoad(emptyList(), stops, GeoPoint(52.2, 5.0), GeoPoint(52.0, 5.025), 30.0))
    }

    @Test fun noGPSReasonWords() {
        val id = "20261127_23:10_nl-OpenOV_400100123"
        val now = 1_795_000_000.0
        val other = mapOf("999" to GPSFix(52.0, 5.0, null, now))
        assertEquals("real positions off", RealPositions.noGPSReason(false, id, null, other, emptyMap(), now))
        assertEquals("ovapi positions not in", RealPositions.noGPSReason(true, id, null, emptyMap(), emptyMap(), now))
        assertTrue(RealPositions.noGPSReason(true, id, null, other, emptyMap(), now)!!.startsWith("no ovapi match for trip_id 400100123"))
        assertNull(RealPositions.noGPSReason(true, id, null, mapOf("400100123" to GPSFix(52.0, 5.0, null, now - 20)), emptyMap(), now))
        assertEquals("fix 240 s old", RealPositions.noGPSReason(true, id, null, mapOf("400100123" to GPSFix(52.0, 5.0, null, now - 240)), emptyMap(), now))
        assertEquals("train 3540 not in ns positions", RealPositions.noGPSReason(true, "x", 3540, other, mapOf(1 to GPSFix(52.0, 5.0, null, now)), now))
    }
}
