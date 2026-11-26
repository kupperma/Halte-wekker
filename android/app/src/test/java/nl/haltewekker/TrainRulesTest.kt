package nl.haltewekker

import nl.haltewekker.live.GPSFix
import nl.haltewekker.match.ChooseGPS
import nl.haltewekker.match.Evidence
import nl.haltewekker.match.Fix
import nl.haltewekker.match.Judgement
import nl.haltewekker.match.Reject
import nl.haltewekker.match.TrainRules
import nl.haltewekker.match.TrainRules.Seen
import nl.haltewekker.match.VehicleGPS
import nl.haltewekker.match.VehicleMatch
import nl.haltewekker.match.Verdict
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** iOS `TrainRulesTests` (0.34): two trains on the same track. */
class TrainRulesTest {
    private val t0 = Fx.t0

    @Test fun reproducedTimetableOnlyWrongTrainPassesAlone() {
        val you = Fx.fixes(2000.0, 30.0, 15)
        val wrong = Fx.track("IC1131", live = false, path = Fx.railway, at = 6000.0, speed = 30.0)
        val judged = VehicleMatch.judgeAll(you, listOf(wrong), strictTimes = false)
        assertNotNull(Fx.ok(judged, "IC1131"))
        val mine = Fx.track("IC3624", path = Fx.railway, at = 2400.0, speed = 30.0)
            .copy(gps = VehicleGPS(GPSFix(Fx.east(2400.0).lat, Fx.east(2400.0).lon, 90.0, t0 + 26, speed = 30.0)))
        val both = VehicleMatch.judgeAll(you, listOf(wrong, mine), strictTimes = false)
        assertTrue(ChooseGPS.passedByGPS(both.first { it.id == "IC3624" }))
        assertEquals(listOf("IC3624"), TrainRules.rivals(both.first { it.id == "IC1131" }, both.filter { it.id != "IC1131" }))
    }

    private fun train(id: String, gps: Boolean, r: Verdict, live: Boolean = true) =
        Judgement(id, "IC", true, live, Evidence(15, 28.0, 20.0, 30.0, true, 840.0, 0.0, 0.0, 30.0, 30.0, true, gps = gps), r)

    @Test fun rivalsOnlyWhenTheShownOneIsNotWithYouByItsGPS() {
        val rival = train("b", true, Verdict.Pass(5.0))
        assertEquals(emptyList<String>(), TrainRules.rivals(train("a", true, Verdict.Pass(10.0)), listOf(rival)))
        assertEquals(listOf("b"), TrainRules.rivals(train("a", false, Verdict.Pass(10.0)), listOf(rival)))
        assertEquals(listOf("b"), TrainRules.rivals(train("a", true, Verdict.Fail(Reject.TOO_FAR_FROM_TIMES)), listOf(rival)))
        assertEquals(emptyList<String>(), TrainRules.rivals(train("a", false, Verdict.Pass(10.0)), listOf(train("c", false, Verdict.Pass(1.0)))))
        val bus = Judgement("bus", "305", false, true, rival.evidence, Verdict.Pass(1.0))
        assertEquals(emptyList<String>(), TrainRules.rivals(train("a", false, Verdict.Pass(10.0)), listOf(bus)))
        val many = listOf(train("x", true, Verdict.Pass(30.0)), train("y", true, Verdict.Pass(3.0)), train("z", true, Verdict.Pass(9.0)))
        assertEquals(listOf("y", "z"), TrainRules.rivals(null, many))
    }

    private fun ride(m0: Double, plan: List<Pair<Double, Double>>, accuracy: Double = 15.0): List<Fix> {
        val out = ArrayList<Fix>()
        var m = m0; var t = 0.0
        for ((span, v) in plan) {
            var s = 0.0
            while (s < span) { out.add(Fix(t0 + t, Fx.east(m), accuracy, v, 90.0)); m += v * 2; t += 2; s += 2 }
        }
        out.add(Fix(t0 + t, Fx.east(m), accuracy, plan.lastOrNull()?.second ?: 0.0, 90.0))
        return out
    }

    @Test fun passedThroughAStationAtSpeed() {
        val f = ride(0.0, listOf(120.0 to 30.0))
        assertEquals(Seen.PASSED_THROUGH, TrainRules.seen(f, Fx.east(1800.0)))
        assertNull(TrainRules.seen(f, Fx.east(3500.0)))
        assertNull(TrainRules.seen(f, Fx.east(1800.0, 1500.0)))
    }

    @Test fun stoppedAtAStation() {
        assertEquals(Seen.STOPPED, TrainRules.seen(ride(0.0, listOf(40.0 to 25.0, 40.0 to 0.0, 40.0 to 20.0)), Fx.east(1050.0)))
        assertNull(TrainRules.seen(ride(0.0, listOf(40.0 to 25.0, 10.0 to 0.0, 40.0 to 20.0)), Fx.east(1050.0)))
    }

    @Test fun gapInTheFixesIsNoPassThrough() {
        val f = ride(0.0, listOf(120.0 to 30.0)).filterNot { it.t > t0 + 40 && it.t < t0 + 100 }
        assertNull(TrainRules.seen(f, Fx.east(1800.0)))
    }

    @Test fun outByStoppingPattern() {
        val calls = mapOf("SPR" to setOf("Breda", "Gilze-Rijen", "Tilburg"), "IC" to setOf("Breda", "Tilburg"))
        val through = mapOf("SPR" to setOf("Breda", "Gilze-Rijen", "Tilburg"), "IC" to setOf("Breda", "Gilze-Rijen", "Tilburg"))
        assertEquals(setOf("SPR"), TrainRules.outByStops(calls, through, mapOf("Gilze-Rijen" to Seen.PASSED_THROUGH)))
        assertEquals(setOf("IC"), TrainRules.outByStops(calls, through, mapOf("Gilze-Rijen" to Seen.STOPPED)))
        assertEquals(emptySet<String>(), TrainRules.outByStops(calls, mapOf("SPR" to setOf("Gilze-Rijen"), "IC" to emptySet()), mapOf("Gilze-Rijen" to Seen.STOPPED)))
        assertEquals(emptySet<String>(), TrainRules.outByStops(mapOf("A" to setOf("X"), "B" to setOf("X")), mapOf("A" to setOf("X"), "B" to setOf("X")), mapOf("X" to Seen.PASSED_THROUGH)))
    }

    @Test fun askAfterTwoMinutesOfATieWithDifferentDestinations() {
        val dest = mapOf("a" to "'s-Hertogenbosch", "b" to "Eindhoven Centraal")
        assertNull(TrainRules.ask(listOf("a", "b"), 100.0, true, dest, false))
        assertEquals("a", TrainRules.ask(listOf("a", "b"), 130.0, true, dest, false)?.first)
        assertNull(TrainRules.ask(listOf("a", "b"), 130.0, true, dest, true))
        assertNull(TrainRules.ask(listOf("a"), 130.0, true, dest, false))
        assertNull(TrainRules.ask(listOf("a", "b"), 130.0, false, dest, false))
        assertNull(TrainRules.ask(listOf("a", "b"), 130.0, true, mapOf("a" to "Zwolle", "b" to "zwolle"), false))
        assertNull(TrainRules.ask(listOf("a", "b"), 130.0, true, mapOf("a" to "Zwolle"), false))
    }

    @Test fun askWords() {
        assertEquals("IC to 's-Hertogenbosch or IC to Eindhoven Centraal?", TrainRules.askTitle("IC" to "'s-Hertogenbosch", "IC" to "Eindhoven Centraal"))
        assertEquals("SPR to Tilburg", TrainRules.answer("SPR", "Tilburg"))
    }

    private fun p(m: Double) = Fx.east(m)

    @Test fun stayOnToTheEndOfTheLastLeg() {
        val ends = listOf(p(3000.0), p(6000.0))
        val deps = listOf(t0, t0 + 900)
        val calls = listOf(TrainRules.Call(p(0.0), t0), TrainRules.Call(p(3000.0), t0 + 600), TrainRules.Call(p(6000.0), t0 + 1200))
        assertEquals(1 to 2, TrainRules.stayOn(0, ends, deps, calls, t0 + 60))
        assertNull(TrainRules.stayOn(0, ends, deps, calls.take(2), t0 + 60))
    }

    @Test fun stayOnInTimeForTheRideAfter() {
        val ends = listOf(p(3000.0), p(6000.0), p(9000.0))
        val calls = listOf(TrainRules.Call(p(3000.0), t0 + 600), TrainRules.Call(p(6000.0), t0 + 1200))
        assertEquals(1, TrainRules.stayOn(0, ends, listOf(t0, t0 + 700, t0 + 1500), calls, t0)?.first)
        assertNull(TrainRules.stayOn(0, ends, listOf(t0, t0 + 700, t0 + 1250), calls, t0))
    }
}
