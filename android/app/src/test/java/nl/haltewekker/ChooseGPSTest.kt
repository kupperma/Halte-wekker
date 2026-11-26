package nl.haltewekker

import nl.haltewekker.match.ChoiceLook
import nl.haltewekker.match.ChoiceRun
import nl.haltewekker.match.ChooseGPS
import nl.haltewekker.match.Decision
import nl.haltewekker.match.Evidence
import nl.haltewekker.match.GPSChoice
import nl.haltewekker.match.Judgement
import nl.haltewekker.match.Reject
import nl.haltewekker.match.ShownVerdict
import nl.haltewekker.match.Verdict
import nl.haltewekker.match.VehicleMatch
import nl.haltewekker.match.choose
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** iOS `ChooseGPSTests` (0.26.1): choosing between two buses on a shared road, their own GPS decides. */
class ChooseGPSTest {
    private val t0 = Fx.t0

    enum class Kind { GPS, LIVE, TIMETABLE }

    private fun ok(c: Double) = Verdict.Pass(c)
    private fun no(w: Reject) = Verdict.Fail(w)

    private fun j(id: String, kind: Kind, r: Verdict, cross: Double = 8.0): Judgement {
        var e: Evidence? = Evidence(fixes = 15, span = 28.0, crossTrack = cross, accuracy = 15.0, shaped = true, progress = 300.0, offset = 0.0,
            drift = 0.0, yourSpeed = 11.0, itsSpeed = 11.0, steady = true, gps = kind == Kind.GPS)
        if (r is Verdict.Fail && r.why == Reject.TOO_FEW_FIXES) e = null
        return Judgement(id, id, false, kind != Kind.TIMETABLE, e, r)
    }

    data class Look(val at: Double, val judged: List<Judgement>, val offRoad: Boolean = false)

    private fun run(ids: List<String>, shown: String, start: Double, seq: List<Look>, cr: ChoiceRun = ChoiceRun()): List<ChoiceLook> {
        val out = ArrayList<ChoiceLook>()
        cr.misses.clear(); cr.state = nl.haltewekker.match.SwitchState()
        for (l in seq) {
            val c = VehicleMatch.choose(ids, l.judged, shown, l.offRoad, l.at - start, cr, t0 + l.at)
            out.add(c)
            if (c.settle != null) break
        }
        return out
    }

    private fun at(mm: Int, ss: Int) = ((mm - 25) * 60 + ss - 44).toDouble()

    private val log19: List<Look> get() {
        val a = "306"; val b = "305"
        return listOf(
            Look(at(25, 58), listOf(j(a, Kind.GPS, ok(34.0)), j(b, Kind.LIVE, no(Reject.STANDING)))),
            Look(at(26, 11), listOf(j(b, Kind.LIVE, ok(38.0)), j(a, Kind.GPS, ok(56.0)))),
            Look(at(26, 23), listOf(j(b, Kind.LIVE, ok(28.0)), j(a, Kind.GPS, ok(49.0)))),
            Look(at(26, 37), listOf(j(a, Kind.GPS, ok(25.0)), j(b, Kind.LIVE, ok(35.0)))),
            Look(at(26, 53), listOf(j(b, Kind.GPS, ok(15.0)), j(a, Kind.GPS, ok(33.0)))),
            Look(at(27, 7), listOf(j(b, Kind.GPS, ok(8.0)), j(a, Kind.GPS, ok(8.0)))),
            Look(at(27, 44), listOf(j(a, Kind.GPS, no(Reject.TOO_FEW_FIXES)), j(b, Kind.LIVE, no(Reject.TOO_FEW_FIXES)))),
            Look(at(27, 58), listOf(j(a, Kind.GPS, no(Reject.TOO_FEW_FIXES)), j(b, Kind.GPS, no(Reject.TOO_FEW_FIXES)))),
            Look(at(28, 14), listOf(j(a, Kind.LIVE, ok(1.0)), j(b, Kind.GPS, ok(11.0)))),
            Look(at(28, 27), listOf(j(b, Kind.GPS, ok(0.0)), j(a, Kind.LIVE, no(Reject.DRIFTING)))),
            Look(at(28, 41), listOf(j(b, Kind.GPS, ok(13.0)), j(a, Kind.LIVE, no(Reject.DRIFTING)))),
            Look(at(28, 56), listOf(j(b, Kind.GPS, ok(48.0)), j(a, Kind.GPS, no(Reject.TOO_FAR_FROM_TIMES)))),
            Look(at(29, 9), listOf(j(a, Kind.GPS, ok(32.0)), j(b, Kind.GPS, ok(72.0)))),
            Look(at(29, 21), listOf(j(a, Kind.GPS, ok(18.0)), j(b, Kind.LIVE, no(Reject.DRIFTING)))),
            Look(at(29, 33), listOf(j(a, Kind.LIVE, ok(40.0)), j(b, Kind.LIVE, no(Reject.TOO_FAR_FROM_TIMES)))),
        )
    }

    @Test fun log19_305WinsByItsGPS() {
        val out = run(listOf("306", "305"), "306", 0.0, log19)
        assertEquals("305", out.last().settle)
        assertEquals(ChoiceLook.Why.BY_GPS, out.last().why)
        assertEquals(12, out.size)
        assertTrue(out.dropLast(1).all { it.settle == null })
        assertTrue(out.all { it.alive == listOf("306", "305") })
        assertEquals(Decision.SwitchTo("305"), out.last().decision)
    }

    @Test fun log19_oneQuietRoundDoesNotHandItOver() {
        val out = run(listOf("306", "305"), "306", 0.0, log19.takeLast(3))
        assertEquals(3, out.size)
        assertTrue(out.all { it.settle == null && it.alive == listOf("306", "305") })
        assertNotEquals(ChoiceLook.Why.ONLY_ONE_LEFT, out.last().why)
    }

    @Test fun oneBadRoundOfTheBetterOne() {
        val a = "306"; val b = "305"
        val seq = listOf(
            Look(0.0, listOf(j(b, Kind.GPS, ok(5.0)), j(a, Kind.GPS, no(Reject.TOO_FAR_FROM_TIMES)))),
            Look(12.0, listOf(j(b, Kind.GPS, no(Reject.TOO_FAR_FROM_TIMES)), j(a, Kind.GPS, ok(20.0)))),
            Look(24.0, listOf(j(b, Kind.GPS, ok(6.0)), j(a, Kind.GPS, no(Reject.TOO_FAR_FROM_TIMES)))),
            Look(36.0, listOf(j(b, Kind.GPS, ok(4.0)), j(a, Kind.GPS, no(Reject.TOO_FAR_FROM_TIMES)))),
        )
        val out = run(listOf(a, b), a, -20.0, seq)
        assertEquals(4, out.size)
        assertEquals(listOf(null, null, null, b), out.map { it.settle })
        assertEquals(listOf(a, b), out[1].alive)
        assertEquals(ChoiceLook.Why.BY_GPS, out.last().why)
    }

    @Test fun log18_157WinsOverPlanned305() {
        val a = "4806"; val b = "4262"
        val seq = listOf(
            Look(0.0, listOf(j(b, Kind.GPS, ok(13.0)), j(a, Kind.GPS, no(Reject.TOO_FAR_FROM_TIMES)))),
            Look(12.0, listOf(j(b, Kind.GPS, ok(18.0)), j(a, Kind.LIVE, no(Reject.TOO_FAR_FROM_TIMES)))),
            Look(24.0, listOf(j(b, Kind.GPS, ok(73.0)), j(a, Kind.GPS, no(Reject.TOO_FAR_FROM_TIMES)))),
        )
        val out = run(listOf(a, b), a, -8.0, seq)
        assertEquals(2, out.size)
        assertEquals(b, out.last().settle)
        assertEquals(ChoiceLook.Why.BY_GPS, out.last().why)
    }

    @Test fun roadsPartSwitchAtOnce() {
        val out = run(listOf("306", "305"), "306", -60.0, listOf(
            Look(0.0, listOf(j("305", Kind.LIVE, ok(20.0)), j("306", Kind.GPS, no(Reject.OFF_ITS_PATH), cross = 1309.0)))))
        assertEquals(1, out.size)
        assertEquals("305", out.last().settle)
        assertEquals(ChoiceLook.Why.SPLIT, out.last().why)
        val other = run(listOf("305", "306"), "305", -60.0, listOf(
            Look(0.0, listOf(j("305", Kind.GPS, ok(20.0)), j("306", Kind.GPS, no(Reject.OFF_ITS_PATH), cross = 1309.0)))))
        assertEquals(listOf("305"), other.last().alive)
        assertEquals("305", other.last().settle)
        assertEquals(ChoiceLook.Why.ONLY_ONE_LEFT, other.last().why)
        val near = run(listOf("306", "305"), "306", -60.0, listOf(
            Look(0.0, listOf(j("305", Kind.LIVE, ok(20.0)), j("306", Kind.GPS, no(Reject.OFF_ITS_PATH), cross = 120.0)))))
        assertNull(near.last().settle)
        assertFalse(ChooseGPS.roadsParted(j("x", Kind.GPS, no(Reject.OFF_ITS_PATH), cross = 299.0)))
        assertTrue(ChooseGPS.roadsParted(j("x", Kind.GPS, no(Reject.OFF_ITS_PATH), cross = 300.0)))
        assertFalse(ChooseGPS.roadsParted(j("x", Kind.GPS, no(Reject.DRIFTING), cross = 900.0)))
    }

    @Test fun alternatingLeadNeverSwitches() {
        val seq = (0 until 70).map { k ->
            val b = k % 2 == 0
            Look(12.0 * k, listOf(
                j("305", Kind.GPS, if (b) ok(5.0) else no(Reject.TOO_FAR_FROM_TIMES)),
                j("306", Kind.GPS, if (b) no(Reject.TOO_FAR_FROM_TIMES) else ok(5.0))))
        }
        val out = run(listOf("306", "305"), "306", -8.0, seq)
        assertTrue(out.dropLast(1).all { it.settle == null && it.decision == Decision.Keep("306") })
        assertEquals("306", out.last().settle)
        assertEquals(ChoiceLook.Why.TIMED_OUT, out.last().why)
    }

    @Test fun tieKeepsShown() {
        val seq = (0 until 20).map { k -> Look(12.0 * k, listOf(j("305", Kind.GPS, ok(if (k % 2 == 0) 2.0 else 20.0)), j("306", Kind.GPS, ok(22.0)))) }
        val out = run(listOf("306", "305"), "306", 0.0, seq)
        assertEquals(20, out.size)
        assertTrue(out.all { it.settle == null && it.decision == Decision.Keep("306") })
    }

    @Test fun noFlipBackAfterSwitch() {
        val cr = ChoiceRun()
        val first = run(listOf("306", "305"), "306", 0.0, log19, cr)
        assertEquals("305", first.last().settle)
        assertNull(cr.gps.leader)
        val s = at(28, 56)
        val back = listOf(
            Look(s + 30, listOf(j("305", Kind.LIVE, no(Reject.DRIFTING)), j("306", Kind.GPS, ok(18.0)))),
            Look(s + 42, listOf(j("305", Kind.LIVE, no(Reject.TOO_FAR_FROM_TIMES)), j("306", Kind.GPS, ok(20.0)))),
            Look(s + 54, listOf(j("305", Kind.LIVE, no(Reject.DRIFTING)), j("306", Kind.GPS, ok(15.0)))),
        )
        val out = run(listOf("305", "306"), "305", s + 20, back, cr)
        assertEquals(3, out.size)
        assertTrue(out.all { it.settle == null && it.decision == Decision.Keep("305") && it.shown == ShownVerdict.NOT_SURE })
    }

    @Test fun gpsBest() {
        val ids = listOf("a", "b")
        assertEquals("a", ChooseGPS.gpsBest(ids, listOf(j("a", Kind.GPS, ok(5.0)), j("b", Kind.LIVE, no(Reject.DRIFTING)))))
        assertEquals("a", ChooseGPS.gpsBest(ids, listOf(j("a", Kind.GPS, ok(5.0)), j("b", Kind.GPS, ok(35.0)))))
        assertNull(ChooseGPS.gpsBest(ids, listOf(j("a", Kind.GPS, ok(5.0)), j("b", Kind.GPS, ok(34.0)))))
        assertNull(ChooseGPS.gpsBest(ids, listOf(j("a", Kind.GPS, ok(5.0)), j("b", Kind.LIVE, no(Reject.TOO_FEW_FIXES)))))
        assertNull(ChooseGPS.gpsBest(ids, listOf(j("a", Kind.GPS, ok(5.0)))))
        assertNull(ChooseGPS.gpsBest(ids, listOf(j("a", Kind.GPS, ok(5.0)), j("b", Kind.TIMETABLE, ok(90.0)))))
        assertNull(ChooseGPS.gpsBest(ids, listOf(j("a", Kind.LIVE, ok(5.0)), j("b", Kind.LIVE, no(Reject.DRIFTING)))))
    }

    @Test fun softenedOnlyTimesOnlySoonAfterAGPSFit() {
        val drifting = j("a", Kind.LIVE, no(Reject.DRIFTING))
        assertTrue(ChooseGPS.softened(drifting, t0, t0 + 90))
        assertFalse(ChooseGPS.softened(drifting, t0, t0 + 91))
        assertFalse(ChooseGPS.softened(drifting, null, t0))
        assertFalse(ChooseGPS.softened(j("a", Kind.GPS, no(Reject.TOO_FAR_FROM_TIMES)), t0, t0 + 10))
        assertFalse(ChooseGPS.softened(j("a", Kind.LIVE, no(Reject.OFF_ITS_PATH)), t0, t0 + 10))
        assertFalse(ChooseGPS.softened(j("a", Kind.LIVE, no(Reject.WRONG_WAY)), t0, t0 + 10))
        val fits = ChooseGPS.noteGPSFits(listOf(j("a", Kind.GPS, ok(3.0)), j("b", Kind.LIVE, ok(3.0))), mapOf("old" to t0 - 200), t0)
        assertEquals(mapOf("a" to t0), fits)
    }

    @Test fun runNeedsLooksCloseTogether() {
        val look = listOf(j("a", Kind.GPS, ok(5.0)), j("b", Kind.GPS, no(Reject.TOO_FAR_FROM_TIMES)))
        var g = GPSChoice()
        fun step(js: List<Judgement>, now: Double): String? { val (n, r) = ChooseGPS.gpsLook(listOf("a", "b"), js, g, now); g = n; return r }
        assertNull(step(look, t0))
        assertNull(step(look, t0 + 61))
        assertEquals("a", step(look, t0 + 73))
        g = GPSChoice()
        val tie = listOf(j("a", Kind.GPS, ok(5.0)), j("b", Kind.GPS, ok(10.0)))
        val fails = listOf(j("a", Kind.GPS, no(Reject.TOO_FAR_FROM_TIMES)), j("b", Kind.GPS, ok(10.0)))
        assertNull(step(look, t0))
        assertNull(step(tie, t0 + 12))
        assertEquals("a", g.leader)
        assertEquals("a", step(look, t0 + 24))
        g = GPSChoice()
        assertNull(step(look, t0))
        assertNull(step(fails, t0 + 12))
        assertEquals("b", g.leader)
    }
}
