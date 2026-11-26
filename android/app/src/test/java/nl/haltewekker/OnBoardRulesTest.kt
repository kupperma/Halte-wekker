package nl.haltewekker

import nl.haltewekker.core.GeoPoint
import nl.haltewekker.match.ChooseGPS
import nl.haltewekker.match.Evidence
import nl.haltewekker.match.Fix
import nl.haltewekker.match.GPSChoice
import nl.haltewekker.match.Judgement
import nl.haltewekker.match.OnBoardBackoff
import nl.haltewekker.match.OnBoardRules
import nl.haltewekker.match.Reject
import nl.haltewekker.match.Verdict
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** iOS `OnBoardRulesTests`, `OnBoardTrainTests` (the track) and the GPS run of `ChooseGPS`. */
class OnBoardRulesTest {
    private enum class Kind { GPS, LIVE, TIMETABLE }

    private fun j(id: String, kind: Kind, r: Verdict, you: Double = 5.0, fixes: Int = 15, train: Boolean = false): Judgement {
        val e = Evidence(fixes, 28.0, 8.0, 10.0, true, you * 28, 0.0, 0.0, you, 10.0, true, gps = kind == Kind.GPS)
        return Judgement(id, id, train, kind != Kind.TIMETABLE, e, r)
    }
    private fun ok(c: Double) = Verdict.Pass(c)
    private fun no(r: Reject) = Verdict.Fail(r)

    @Test fun timetableNeverBeatsGPS() {
        val look = listOf(j("9", Kind.TIMETABLE, ok(6.0)), j("305", Kind.GPS, ok(14.0)), j("305b", Kind.GPS, no(Reject.TOO_FAR_FROM_TIMES)),
            j("3", Kind.TIMETABLE, no(Reject.WRONG_WAY)))
        assertEquals("305", OnBoardRules.best(look, 5.0))
        val fast = listOf(j("9", Kind.TIMETABLE, ok(6.0), you = 12.0), j("305", Kind.GPS, ok(14.0), you = 12.0))
        assertEquals("305", OnBoardRules.best(fast, 12.0))
    }

    @Test fun timetableOnlyWhileWalkingIsNone() {
        val look = listOf(j("15", Kind.TIMETABLE, ok(15.0)), j("119", Kind.TIMETABLE, ok(21.0)), j("319", Kind.TIMETABLE, ok(21.0)))
        assertNull(OnBoardRules.best(look, 5.0))
        val riding = look.map { j(it.id, Kind.TIMETABLE, it.result, you = 11.0) }
        assertEquals("15", OnBoardRules.best(riding, 11.0))
        assertNull(OnBoardRules.best(listOf(j("15", Kind.TIMETABLE, ok(15.0), you = 0.0, fixes = 1)), 4.0))
        assertEquals("15", OnBoardRules.best(listOf(j("15", Kind.TIMETABLE, ok(15.0), you = 0.0, fixes = 1)), 9.0))
    }

    @Test fun liveKeepsItsPlace() {
        assertEquals("a", OnBoardRules.best(listOf(j("a", Kind.LIVE, ok(5.0)), j("b", Kind.GPS, ok(14.0))), 5.0))
        assertEquals("a", OnBoardRules.best(listOf(j("a", Kind.LIVE, ok(5.0))), 1.0))
        assertNull(OnBoardRules.best(listOf(j("a", Kind.LIVE, no(Reject.OFF_ITS_PATH))), 10.0))
        assertNull(OnBoardRules.best(emptyList(), 10.0))
    }

    @Test fun aTrainByItsGPSBeatsOneByItsTimes() {
        val look = listOf(j("SPR", Kind.LIVE, ok(20.0), train = true), j("IC", Kind.GPS, ok(22.0), train = true))
        assertEquals("IC", OnBoardRules.best(look, 30.0))
    }

    @Test fun mayAutoStart() {
        assertFalse(OnBoardRules.mayAutoStart("7821", false, "7821", emptySet()))
        assertFalse(OnBoardRules.mayAutoStart("7821", false, "7954", emptySet()))
        assertFalse(OnBoardRules.mayAutoStart("7821", true, null, setOf("7821")))
        assertTrue(OnBoardRules.mayAutoStart("7821", true, null, setOf("7954")))
    }

    private val t0 = Fx.t0
    private fun track(speed: Double, seconds: Int, every: Int = 2, accuracy: Double = 65.0, end: Double = t0): List<Fix> =
        (seconds downTo 0 step every).map { s ->
            Fix(end - s, GeoPoint(51.69 - s * speed / 110_540, 5.29), accuracy, -1.0, -1.0)
        }

    @Test fun movingByTrack() {
        assertTrue(OnBoardRules.movingByTrack(track(30.0, 30), t0))
        assertTrue(OnBoardRules.movingByTrack(track(30.0, 30), t0, speed = 8.0))
        assertTrue(OnBoardRules.movingByTrack(track(9.0, 40, accuracy = 10.0), t0))
        assertFalse(OnBoardRules.movingByTrack(track(1.4, 50, accuracy = 10.0), t0))
        assertFalse(OnBoardRules.movingByTrack(track(6.0, 40, accuracy = 10.0), t0, speed = 8.0))
        assertFalse(OnBoardRules.movingByTrack(track(30.0, 10), t0))
        assertFalse(OnBoardRules.movingByTrack(track(30.0, 30, every = 15).take(2), t0))
        assertFalse(OnBoardRules.movingByTrack(track(30.0, 30, end = t0 - 120), t0))
        assertFalse(OnBoardRules.movingByTrack(track(30.0, 30, accuracy = 500.0), t0))
        val jump = (0..14).map { k -> Fix(t0 + k * 2 - 30, GeoPoint(51.69, 5.29), 40.0, -1.0, -1.0) } +
            Fix(t0, GeoPoint(51.69 + 300 / 110_540.0, 5.29), 40.0, -1.0, -1.0)
        assertFalse(OnBoardRules.movingByTrack(jump, t0))
    }

    @Test fun lookDue() {
        assertTrue(OnBoardRules.lookDue(true, true, 0.0, 1.0))
        assertFalse(OnBoardRules.lookDue(false, false, 320.0, 10.0))
        assertTrue(OnBoardRules.lookDue(false, false, 640.0, 21.0))
        assertTrue(OnBoardRules.lookDue(false, false, 320.0, null))
        assertTrue(OnBoardRules.lookDue(false, false, 310.0, 30.0))
        assertFalse(OnBoardRules.lookDue(false, false, 200.0, 50.0))
        assertFalse(OnBoardRules.lookDue(false, true, 2000.0, 30.0))
        assertFalse(OnBoardRules.lookDue(false, false, null, 30.0))
    }

    @Test fun backoffAfterSixEmptyLooks() {
        var s = OnBoardBackoff.State()
        repeat(5) { s = OnBoardBackoff.looked(s, false, t0 + it) }
        assertFalse(OnBoardBackoff.holding(s, t0 + 10))
        s = OnBoardBackoff.looked(s, false, t0 + 6)
        assertTrue(OnBoardBackoff.holding(s, t0 + 60))
        assertFalse(OnBoardBackoff.holding(s, t0 + 6 + 121))
        assertFalse(OnBoardBackoff.holding(OnBoardBackoff.looked(s, true, t0 + 7), t0 + 8))
    }

    /** The 157 fits by its GPS while the planned 305 is far from its times: the 157 after two looks (2026-11-18). */
    @Test fun gpsRunDecidesAfterTwoLooks() {
        val a = "4806"; val b = "4262"
        var run = GPSChoice()
        val looks = listOf(
            listOf(j(b, Kind.GPS, ok(13.0)), j(a, Kind.GPS, no(Reject.TOO_FAR_FROM_TIMES))),
            listOf(j(b, Kind.GPS, ok(18.0)), j(a, Kind.LIVE, no(Reject.TOO_FAR_FROM_TIMES))),
        )
        val out = looks.mapIndexed { k, l -> val (r, w) = ChooseGPS.gpsLook(listOf(a, b), l, run, t0 + k * 12); run = r; w }
        assertEquals(listOf(null, b), out)
        // a look where it fails for real starts the run again
        val (r2, w2) = ChooseGPS.gpsLook(listOf(a, b), listOf(j(b, Kind.GPS, no(Reject.OFF_ITS_PATH)), j(a, Kind.LIVE, ok(5.0))), run, t0 + 36)
        assertNull(w2); assertNull(r2.leader)
        // both about as good: nobody by GPS
        assertNull(ChooseGPS.gpsBest(listOf(a, b), listOf(j(b, Kind.GPS, ok(8.0)), j(a, Kind.GPS, ok(8.0)))))
        // "not sure" isn't beaten
        assertNull(ChooseGPS.gpsBest(listOf(a, b), listOf(j(b, Kind.GPS, ok(8.0)), j(a, Kind.GPS, no(Reject.TOO_FEW_FIXES)))))
    }
}
