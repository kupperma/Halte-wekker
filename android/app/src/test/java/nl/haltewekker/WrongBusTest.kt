package nl.haltewekker

import nl.haltewekker.core.GeoPoint
import nl.haltewekker.live.GPSFix
import nl.haltewekker.match.ChoiceLook
import nl.haltewekker.match.ChoiceRun
import nl.haltewekker.match.ChooseGPS
import nl.haltewekker.match.Decision
import nl.haltewekker.match.DepartClue
import nl.haltewekker.match.DepartMatch
import nl.haltewekker.match.Departure
import nl.haltewekker.match.Evidence
import nl.haltewekker.match.Judgement
import nl.haltewekker.match.Reject
import nl.haltewekker.match.TimedPiece
import nl.haltewekker.match.UsualLine
import nl.haltewekker.match.Verdict
import nl.haltewekker.match.VehicleGPS
import nl.haltewekker.match.VehicleMatch
import nl.haltewekker.match.VehicleTrack
import nl.haltewekker.match.choose
import nl.haltewekker.ride.ChangeGuide
import nl.haltewekker.ride.MissRule
import nl.haltewekker.ride.NoticeExpiry
import nl.haltewekker.ride.OtherAtStop
import nl.haltewekker.ride.TimetableStart
import nl.haltewekker.ride.WrongBus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.ZoneId

/** iOS `WrongBusTests` (0.39.1): the evening of the field report, one test per thing that went wrong. */
class WrongBusTest {
    private val t0 = Fx.t0
    private fun at(s: Double) = t0 + s
    private val hhmm: (Double) -> String = { "+${((it - t0) / 60).toInt()}" }
    private fun bus(id: String, line: String, s: Double, walk: Int = 2) = ChangeGuide.Ride(id, line, false, at(s), "B", walk)
    private val utc = ZoneId.of("UTC")

    @Test fun a_atTheChange_notMissedBeforeItsLiveDeparture() {
        val next = ChangeGuide.Ride("ic-0103", "IC", true, at(31.0), "4", 3)
        val g = ChangeGuide.guide(at(-600.0), null, false, null, next, emptyList(), 4.0, at(0.0), hhmm, atChange = true)
        assertFalse(g.missed); assertNull(g.missText)
        assertTrue(ChangeGuide.guide(at(-600.0), null, false, null, next, emptyList(), 4.0, at(0.0), hhmm).missed)
    }

    @Test fun a_theLateBusAtItsLiveTime_isStillComing() {
        val g = ChangeGuide.guide(at(-480.0), null, true, null, bus("306-0600", "306", 180.0), listOf(bus("305-0553", "305", 14 * 60.0)),
            null, at(87.0), hhmm, atChange = true)
        assertFalse(g.missed)
        assertEquals("306-0600", g.target.tripId)
    }

    @Test fun a_goneWithoutYou_isMissed_unlessItsGPSHasItBeforeTheStop() {
        val next = bus("306-0600", "306", 0.0)
        val later = listOf(bus("305-0553", "305", 14 * 60.0))
        val gone = ChangeGuide.guide(at(-480.0), null, true, null, next, later, null, at(87.0), hhmm, atChange = true)
        assertTrue(gone.missed)
        assertEquals("You’ll miss the +0 — take bus 305 at +14", gone.missText)
        assertFalse(ChangeGuide.guide(at(-480.0), null, true, null, next, later, null, at(87.0), hhmm, atChange = true, notLeft = true).missed)
        assertFalse(MissRule.missed(at(-480.0), at(0.0), 2.0, at(50.0), true, false))
    }

    @Test fun a_onTheWay_theLiveArrivalAndTheRoomStillDecide() {
        assertTrue(MissRule.missed(at(600.0), at(660.0), 3.0, at(0.0), false, true))
        assertFalse(MissRule.missed(at(600.0), at(900.0), 3.0, at(0.0), false, false))
    }

    @Test fun a_notLeft_byItsOwnGPS() {
        assertTrue(MissRule.notLeft(1800.0, 2000.0, 30.0))
        assertTrue(MissRule.notLeft(2030.0, 2000.0, 30.0))
        assertFalse(MissRule.notLeft(2150.0, 2000.0, 30.0))
        assertFalse(MissRule.notLeft(1800.0, 2000.0, 400.0))
        assertFalse(MissRule.notLeft(null, 2000.0, 30.0))
    }

    @Test fun b_neverByItsTimetableLongBeforeItLeaves() {
        val dep = at(35 * 60.0)
        assertFalse(TimetableStart.allowed(at(24 * 60 + 39.0), dep))
        assertTrue(TimetableStart.allowed(at(33 * 60 + 30.0), dep))
        assertTrue(TimetableStart.allowed(at(40 * 60.0), dep))
        assertFalse(TimetableStart.allowed(at(56 * 60.0), dep))
        assertEquals("wait · not by its timetable: bus 305·0551 leaves 17:35 (in 11 min) · finding the one you're on",
            TimetableStart.waitLine("bus 305·0551", "17:35", 11))
    }

    private fun j(id: String, line: String, gps: Boolean, r: Verdict, offset: Double = 0.0, cross: Double = 8.0, train: Boolean = false): Judgement {
        val e = Evidence(15, 28.0, cross, 15.0, true, 300.0, offset, 0.0, 11.0, 11.0, true, gps = gps)
        return Judgement(id, line, train, true, e, r)
    }
    private val far = Verdict.Fail(Reject.TOO_FAR_FROM_TIMES)

    @Test fun c_farByGPS() {
        assertTrue(ChooseGPS.farByGPS(j("305-0551", "305", true, far, 1683.0)))
        assertFalse(ChooseGPS.farByGPS(j("305-0551", "305", true, far, 958.0)))
        assertFalse(ChooseGPS.farByGPS(j("305-0551", "305", false, far, 1683.0)))
        assertFalse(ChooseGPS.farByGPS(j("305-0551", "305", true, Verdict.Fail(Reject.OFF_ITS_PATH), 1683.0)))
        assertFalse(ChooseGPS.farByGPS(j("305-0551", "305", true, Verdict.Pass(30.0), 1683.0)))
        assertFalse(ChooseGPS.farByGPS(j("ic-1", "IC", true, far, 1683.0, train = true)))
    }

    @Test fun c_theOtherOneFittedByGPSAMomentAgo_winsOverThePlannedFarOne() {
        val cr = ChoiceRun()
        cr.gps = cr.gps.copy(fitAt = ChooseGPS.noteGPSFits(listOf(j("154-0855", "154", true, Verdict.Pass(150.0), 900.0)), cr.gps.fitAt, at(0.0)))
        cr.gps = cr.gps.restart()
        val ids = listOf("305-0551", "154-0855")
        val look = listOf(j("305-0551", "305", true, far, 1683.0), j("154-0855", "154", true, far, 889.0))
        val c = VehicleMatch.choose(ids, look, "305-0551", false, 10.0, cr, at(10.0))
        assertEquals("154-0855", c.settle)
        assertEquals(ChoiceLook.Why.FAR_BY_GPS, c.why)
        assertEquals(Decision.SwitchTo("154-0855"), c.decision)
    }

    @Test fun c_withoutTheFindsFit_itIsNotTheOnlyOneLeftWhileTheOtherFittedByGPS() {
        val cr = ChoiceRun()
        val ids = listOf("305-0551", "154-0855")
        val a = VehicleMatch.choose(ids, listOf(j("305-0551", "305", true, far, 958.0), j("154-0855", "154", true, Verdict.Pass(40.0), 400.0)),
            "305-0551", false, 0.0, cr, at(0.0))
        assertNotEquals("305-0551", a.settle)
        val b = VehicleMatch.choose(ids, listOf(j("305-0551", "305", true, far, 1878.0), j("154-0855", "154", true, far, 1089.0)),
            "305-0551", false, 12.0, cr, at(12.0))
        assertEquals("154-0855", b.settle)
        assertNotEquals(ChoiceLook.Why.ONLY_ONE_LEFT, b.why)
    }

    @Test fun c_morning0909_bothOffTheirPathKeepsThePlanned() {
        val cr = ChoiceRun()
        val ids = listOf("372-0101", "4-0177")
        assertNull(VehicleMatch.choose(ids, listOf(j("372-0101", "372", false, Verdict.Pass(7.0)), j("4-0177", "4", false, Verdict.Pass(34.0))),
            "372-0101", false, 0.0, cr, at(0.0)).settle)
        val off = Verdict.Fail(Reject.OFF_ITS_PATH)
        assertNull(VehicleMatch.choose(ids, listOf(j("4-0177", "4", false, off, cross = 155.0), j("372-0101", "372", true, off, 1500.0, 161.0)),
            "372-0101", false, 20.0, cr, at(20.0)).settle)
        val l2 = VehicleMatch.choose(ids, listOf(j("372-0101", "372", true, off, 1500.0, 191.0), j("4-0177", "4", false, off, cross = 211.0)),
            "372-0101", false, 33.0, cr, at(33.0))
        assertEquals("372-0101", l2.settle)
        assertEquals(ChoiceLook.Why.ONLY_ONE_LEFT, l2.why)
    }

    @Test fun c_morning0909_bothLeftThenSaysNothing() {
        val d = Departure(at(0.0), Fx.east(0.0), 179.0)
        val a = DepartClue("372-0101", offBy = 38.0)
        val b = DepartClue("4-0177", offBy = 38.0)
        assertNull(DepartMatch.pick(listOf(a, b), listOf("372-0101", "4-0177")))
        assertEquals("depart · stood 179 s, left 08:00:00 · 372·0101 left then (live 38 s) · 4·0177 left then (live 38 s)",
            DepartMatch.logLine(d, listOf(a, b), mapOf("372-0101" to "372", "4-0177" to "4"), utc))
    }

    @Test fun d_sureAfter75sOfItsGPS_orWhenTheRoadsSplit() {
        var runs = WrongBus.note(emptyMap(), listOf("154-0855"), at(0.0))
        runs = WrongBus.note(runs, listOf("154-0855", "305-0551"), at(40.0))
        assertFalse(WrongBus.sure(runs["154-0855"], false, at(40.0)))
        runs = WrongBus.note(runs, listOf("154-0855"), at(80.0))
        assertTrue(WrongBus.sure(runs["154-0855"], false, at(80.0)))
        assertFalse(WrongBus.sure(runs["305-0551"], false, at(80.0)))
        assertTrue(WrongBus.sure(null, true, at(0.0)))
        assertFalse(WrongBus.sure(runs["154-0855"], false, at(280.0)))
        runs = WrongBus.note(runs, listOf("154-0855"), at(280.0))
        assertEquals(at(280.0), runs["154-0855"]!!.first, 0.0)
        assertNull(runs["305-0551"])
    }

    @Test fun d_differsByLineOrDestination() {
        assertTrue(WrongBus.differs("306", "", "154", "Schijndel"))
        assertFalse(WrongBus.differs("306", "Veghel", "306", "Veghel"))
        assertTrue(WrongBus.differs("306", "Veghel", "306", "Uden"))
        assertFalse(WrongBus.differs("306", "", "306", "Uden"))
        assertFalse(WrongBus.differs("", "", "154", "Schijndel"))
        assertTrue(WrongBus.due(true, true, false, false))
        assertFalse(WrongBus.due(true, true, true, false))
        assertFalse(WrongBus.due(true, true, false, true))
        assertFalse(WrongBus.due(true, false, false, false))
    }

    @Test fun d_words() {
        assertEquals("You’re on the 154 to Schijndel, not your 306", WrongBus.title("154", "Schijndel", "306"))
        assertEquals("You’re on the 154, not your 306", WrongBus.title("154", " ", "306"))
        assertEquals("Get off at Kloosterstraat — 306 back at 17:52", WrongBus.fix("Kloosterstraat", true, "306", "17:52"))
        assertEquals("Stay on to Schijndel — 306 from there at 18:11", WrongBus.fix("Schijndel", false, "306", "18:11"))
        assertEquals("Stay on to Veghel: it gets you there", WrongBus.fix("Veghel", false, null, null))
        assertEquals("wrong bus · on 154·0855 to Schijndel, planned 306 · Stay on to Schijndel — 306 from there at 18:11",
            WrongBus.logLine("154·0855", "Schijndel", "306", "Stay on to Schijndel — 306 from there at 18:11"))
    }

    @Test fun d_itsNotificationGoesAfter20Minutes() {
        val id = WrongBus.id(t0)
        assertTrue(id.startsWith(WrongBus.ID_PREFIX))
        assertEquals(20.0, NoticeExpiry.minutes(id)!!, 0.0)
        assertEquals(emptyList<String>(), NoticeExpiry.due(listOf(id to t0), at(19 * 60.0)))
        assertEquals(listOf(id), NoticeExpiry.due(listOf(id to t0), at(20 * 60.0)))
    }

    private val yours = OtherAtStop.Yours("306", Fx.t0 + 150, setOf("306"))
    private fun seen(id: String, line: String, metres: Double?, age: Double? = 40.0, leaves: Double = 60.0) =
        OtherAtStop.Seen(id, line, "Schijndel", at(leaves), metres, age)

    @Test fun e_the154AtYourStop_isNotYours() {
        val s = OtherAtStop.pick(listOf(seen("154-0855", "154", 30.0), seen("156-0978", "156", 900.0)), yours, 50.0, at(0.0))
        assertEquals("154-0855", s?.tripId)
        val w = OtherAtStop.words(s!!, yours, at(0.0))
        assertEquals("That’s the 154 to Schijndel — not yours", w.first)
        assertEquals("Your 306: 2 min", w.second)
        assertEquals("Your 306: due", OtherAtStop.words(seen("154-0855", "154", 30.0), yours, at(120.0)).second)
    }

    @Test fun e_quietWhenItDoesntMatter() {
        val here = listOf(seen("154-0855", "154", 30.0))
        assertNull(OtherAtStop.pick(here, yours, 400.0, at(0.0)))
        assertNull(OtherAtStop.pick(here, yours, 50.0, at(-15 * 60.0)))
        assertNull(OtherAtStop.pick(listOf(seen("306-0681", "306", 20.0)), yours, 50.0, at(0.0)))
        val both = OtherAtStop.Yours("305", at(150.0), setOf("305", "306"))
        assertNull(OtherAtStop.pick(listOf(seen("306-0681", "306", 20.0)), both, 50.0, at(0.0)))
        assertNull(OtherAtStop.pick(listOf(seen("154-0855", "154", null, null)), yours, 50.0, at(0.0)))
        assertNull(OtherAtStop.pick(listOf(seen("154-0855", "154", 30.0, 400.0)), yours, 50.0, at(0.0)))
        assertNull(OtherAtStop.pick(listOf(seen("154-0855", "154", 200.0)), yours, 50.0, at(0.0)))
        assertNull(OtherAtStop.pick(listOf(seen("154-0855", "154", 30.0, leaves = 20 * 60.0)), yours, 50.0, at(0.0)))
        assertNull(OtherAtStop.pick(here, null, 50.0, at(0.0)))
    }

    @Test fun e_itsNotificationGoesAfter10Minutes() {
        val id = OtherAtStop.id("20261125_17:24_nl-OpenOV_154")
        assertTrue(id.startsWith(OtherAtStop.ID_PREFIX))
        assertEquals(10.0, NoticeExpiry.minutes(id)!!, 0.0)
    }

    @Test fun f_onlyThePlannedLineIsLearnedFromAFoundRide() {
        assertFalse(UsualLine.learnsFound("154", false, "306", false))
        assertFalse(UsualLine.learnsFound("154", false, "305", false))
        assertTrue(UsualLine.learnsFound("305", false, "305", false))
        assertTrue(UsualLine.learnsFound("IC", true, "ic", true))
        assertFalse(UsualLine.learnsFound("IC", true, "IC", false))
        assertTrue(UsualLine.learnsFound("306", false, null, null))
    }

    @Test fun f_notThenByLiveTimesAloneNeeds180s() {
        val d = Departure(at(0.0), Fx.east(0.0), 179.0)
        val the306 = DepartClue("306-0681", offBy = 91.0)
        val the154 = DepartClue("154-0887", offBy = 37.0, byGPS = true)
        assertFalse(DepartMatch.notThen(the306, 37.0))
        assertNull(DepartMatch.pick(listOf(the306, the154), listOf("154-0887", "306-0681")))
        assertEquals("depart · stood 179 s, left 08:00:00 · 306·0681 not sure (live 91 s) · 154·0887 left then (gps 37 s)",
            DepartMatch.logLine(d, listOf(the306, the154), mapOf("306-0681" to "306", "154-0887" to "154"), utc))
        assertTrue(DepartMatch.notThen(DepartClue("306-0681", offBy = 91.0, byGPS = true), 37.0))
        assertEquals("154-0887", DepartMatch.pick(listOf(DepartClue("306-0681", offBy = 200.0), the154), listOf("154-0887", "306-0681")))
    }

    @Test fun f_twoStandingAtTheStop_sayNothing() {
        val d = Departure(at(0.0), Fx.east(0.0), 179.0)
        val a = DepartClue("154-0887", offBy = 20.0, byGPS = true, atStop = true)
        val b = DepartClue("306-0681", offBy = 300.0, byGPS = true, atStop = true)
        assertTrue(DepartMatch.severalAtStop(listOf(a, b), listOf("154-0887", "306-0681")))
        assertNull(DepartMatch.pick(listOf(a, b), listOf("154-0887", "306-0681")))
        assertTrue(DepartMatch.bonuses(listOf(a, b), listOf("154-0887", "306-0681")).isEmpty())
        assertTrue(DepartMatch.logLine(d, listOf(a, b), mapOf("154-0887" to "154", "306-0681" to "306"), utc).endsWith(" · 2 at the stop: says nothing"))
        val p = Fx.east(10.0)
        val g = GPSFix(p.lat, p.lon, 90.0, at(-120.0))
        val piece = TimedPiece(at(600.0), at(900.0), listOf(Fx.east(0.0), Fx.east(1000.0)))
        val v = VehicleTrack("306-0681", "306", false, false, listOf(piece), VehicleGPS(g))
        assertTrue(DepartMatch.clue(v, d).atStop)
    }
}
