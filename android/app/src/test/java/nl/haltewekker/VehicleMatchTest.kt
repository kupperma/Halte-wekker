package nl.haltewekker

import nl.haltewekker.core.Geo
import nl.haltewekker.match.Decision
import nl.haltewekker.match.Fix
import nl.haltewekker.match.Ranked
import nl.haltewekker.match.Reject
import nl.haltewekker.match.SwitchState
import nl.haltewekker.match.TimedPiece
import nl.haltewekker.match.VehicleMatch
import nl.haltewekker.match.VehicleTrack
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.cos
import kotlin.math.sin

/** The iOS `VehicleMatchTests` scenarios, on the same world and with the same expectations. */
class VehicleMatchTest {
    private val t0 = Fx.t0

    @Test fun tolerancePinsToday() {
        assertEquals(1800.0, VehicleMatch.tolerance(true, 30.0), 0.0)
        assertEquals(1000.0, VehicleMatch.tolerance(false, 30.0), 0.0)
        assertEquals(600.0, VehicleMatch.tolerance(true, 5.0), 0.0)
        assertEquals(400.0, VehicleMatch.tolerance(false, 5.0), 0.0)
    }

    @Test fun timePosition() {
        val a = TimedPiece(t0, t0 + 60, listOf(Fx.east(0.0), Fx.east(1000.0)))
        val b = TimedPiece(t0 + 90, t0 + 150, listOf(Fx.east(1000.0), Fx.east(2000.0)))
        val v = VehicleTrack("v", "IC", true, true, listOf(a, b))
        assertEquals(500.0, VehicleMatch.timePosition(v, t0 + 30)!!, 0.5)
        assertEquals(1000.0, VehicleMatch.timePosition(v, t0 + 75)!!, 0.5)
        assertEquals(1500.0, VehicleMatch.timePosition(v, t0 + 120)!!, 0.5)
        assertEquals(2000.0, VehicleMatch.timePosition(v, t0 + 170)!!, 0.5)
        assertNull(VehicleMatch.timePosition(v, t0 + 200))
        assertNull(VehicleMatch.timePosition(v, t0 - 40))
    }

    @Test fun zeroDurationPiece() {
        val a = TimedPiece(t0, t0 + 60, listOf(Fx.east(0.0), Fx.east(1000.0)))
        val b = TimedPiece(t0 + 60, t0 + 60, listOf(Fx.east(1000.0), Fx.east(1500.0)))
        val c = TimedPiece(t0 + 60, t0 + 120, listOf(Fx.east(1500.0), Fx.east(2500.0)))
        val v = VehicleTrack("z", "IC", true, true, listOf(a, b, c))
        val at60 = VehicleMatch.timePosition(v, t0 + 60)!!
        assertTrue(at60.isFinite() && at60 >= 999.99 && at60 <= 1500.01)
        assertEquals(2000.0, VehicleMatch.timePosition(v, t0 + 90)!!, 1.0)
        val e = VehicleMatch.evidence(Fx.fixes(1000.0, 25.0, 15, start = t0 + 40), v)!!
        listOf(e.span, e.crossTrack, e.accuracy, e.progress, e.offset, e.drift, e.yourSpeed, e.itsSpeed).forEach { assertTrue(it.isFinite()) }
        val ends = VehicleTrack("e", "IC", true, true, listOf(a, b))
        assertEquals(1500.0, VehicleMatch.timePosition(ends, t0 + 60)!!, 1.0)
        assertEquals(1500.0, VehicleMatch.timePosition(ends, t0 + 80)!!, 1.0)
        assertEquals(Reject.OFF_ITS_PATH, Fx.why(VehicleMatch.judgeAll(Fx.fixes(1000.0, 25.0, 15, start = t0 + 40), listOf(ends)), "e"))
    }

    /** S1: on the train; a bus on the road 200 m beside the railway, nearer by its times. */
    @Test fun s1_busOnRoadBesideRailway() {
        val you = Fx.fixes(2000.0, 30.0, 15)
        val train = Fx.track("T", path = Fx.railway, at = 1100.0, speed = 30.0)
        val bus = Fx.track("B", "306", false, path = Fx.road(200.0), at = 2300.0, speed = 12.0)
        val j = VehicleMatch.judgeAll(you, listOf(train, bus))
        assertEquals(Reject.OFF_ITS_PATH, Fx.why(j, "B"))
        assertEquals(30.0, Fx.ok(j, "T")!!, 1.0)
        assertEquals(listOf("T"), VehicleMatch.rank(j, null).map { it.id })
    }

    /** S1b: the bus on a road only 50 m away doesn't keep up with you. */
    @Test fun s1b_busOnCloseRoad() {
        val you = Fx.fixes(2000.0, 30.0, 15)
        val train = Fx.track("T", path = Fx.railway, at = 1100.0, speed = 30.0)
        val bus = Fx.track("B", "306", false, path = Fx.road(50.0), at = 2300.0, speed = 12.0)
        val j = VehicleMatch.judgeAll(you, listOf(train, bus))
        assertEquals(Reject.DRIFTING, Fx.why(j, "B"))
        assertNotNull(Fx.ok(j, "T"))
    }

    @Test fun busTooFast() {
        val you = Fx.fixes(2000.0, 35.0, 15, north = 50.0)
        val bus = Fx.track("B", "306", false, path = Fx.road(50.0), at = 2000.0, speed = 35.0)
        assertEquals(Reject.IMPLAUSIBLE_SPEED, Fx.why(VehicleMatch.judgeAll(you, listOf(bus)), "B"))
    }

    /** S2: on the bus; a train passes beside it. */
    @Test fun s2_trainPassingYourBus() {
        val you = Fx.fixes(2000.0, 12.0, 15, north = 50.0)
        val bus = Fx.track("B", "306", false, path = Fx.road(50.0), at = 1900.0, speed = 12.0)
        val train = Fx.track("T", path = Fx.railway, at = 1500.0, speed = 30.0)
        val j = VehicleMatch.judgeAll(you, listOf(bus, train))
        assertEquals(Reject.DRIFTING, Fx.why(j, "T"))
        assertEquals(listOf("B"), VehicleMatch.rank(j, null).map { it.id })
    }

    /** S3: two trains on the double track, opposite ways, no GPS course. */
    @Test fun s3_oppositeTrainsWithoutCourse() {
        val you = Fx.fixes(2000.0, 30.0, 15, course = -1.0)
        val east = Fx.track("A", path = Fx.railway, at = 1400.0, speed = 30.0)
        val west = Fx.track("B", path = Fx.railway.reversed(), at = Geo.length(Fx.railway) - 2200, speed = 30.0)
        val j = VehicleMatch.judgeAll(you, listOf(east, west))
        assertEquals(Reject.WRONG_WAY, Fx.why(j, "B"))
        assertEquals(20.0, Fx.ok(j, "A")!!, 1.0)
    }

    /** S4: a bus and a train leave the same station; the bus's road turns away. */
    @Test fun s4_leavingAStation() {
        fun x(t: Double) = if (t <= 30) 2000 + t * t / 6 else 2150 + 10 * (t - 30)
        fun you(end: Double): List<Fix> = generateSequence(0.0) { it + 2 }.takeWhile { it <= end }
            .map { t -> Fix(t0 + t, Fx.east(x(t)), 20.0, if (t <= 30) t / 3 else 10.0, 90.0) }.toList()
        val train = Fx.track("T", path = Fx.railway, at = 2000.0, speed = 10.0)
        val turn = 50 * Math.PI / 180
        val d = 3000.0
        val road = listOf(Fx.east(0.0), Fx.east(2050.0), Fx.east(2050 + d * sin(turn), north = d * cos(turn)))
        val bus = Fx.track("B", "306", false, path = road, at = 2000.0, speed = 10.0)
        val early = VehicleMatch.judgeAll(you(4.0), listOf(train, bus))
        assertEquals(Reject.TOO_FEW_FIXES, Fx.why(early, "T"))
        assertEquals(Reject.TOO_FEW_FIXES, Fx.why(early, "B"))
        val later = VehicleMatch.judgeAll(you(40.0), listOf(train, bus))
        assertEquals(Reject.OFF_ITS_PATH, Fx.why(later, "B"))
        assertNotNull(Fx.ok(later, "T"))
        assertEquals(false, later.first { it.id == "T" }.evidence?.steady)
    }

    /** S6: a bus standing at your stop while you set off on another. */
    @Test fun s6_busStandingAtYourStop() {
        val you = Fx.fixes(2000.0, 8.0, 17, every = 1.25, north = 50.0)
        val before = TimedPiece(t0 - 205, t0 - 5, listOf(Fx.east(0.0, 50.0), Fx.east(2000.0, 50.0)))
        val after = TimedPiece(t0 + 20, t0 + 510, listOf(Fx.east(2000.0, 50.0), Fx.east(3000.0, 50.0), Fx.east(6900.0, 50.0)))
        val standing = VehicleTrack("S", "306", false, true, listOf(before, after))
        assertEquals(Reject.STANDING, Fx.why(VehicleMatch.judgeAll(you, listOf(standing)), "S"))
    }

    @Test fun rankAndDecide() {
        val ranked = listOf(Ranked("a", 10.0), Ranked("b", 80.0))
        val (d1, _) = VehicleMatch.decide(null, ranked, setOf("a", "b"), state = SwitchState(), now = t0)
        assertEquals(Decision.SwitchTo("a"), d1)
        val (d2, _) = VehicleMatch.decide(null, listOf(Ranked("a", 10.0), Ranked("b", 30.0)), setOf("a", "b"), state = SwitchState(), now = t0)
        assertEquals(Decision.Undecided(listOf("a", "b")), d2)
        // shown "b", "a" much better three looks in a row over 45 s: switch
        var s = SwitchState()
        var last: Decision = Decision.None
        for (k in 0..3) {
            val (d, ns) = VehicleMatch.decide("b", ranked, setOf("a", "b"), state = s, now = t0 + k * 20.0)
            s = ns; last = d
        }
        assertEquals(Decision.SwitchTo("a"), last)
        assertEquals(Decision.Keep("b"), VehicleMatch.decide("b", emptyList(), emptySet(), state = SwitchState(), now = t0).first)
    }
}
