package nl.haltewekker

import nl.haltewekker.core.Geo
import nl.haltewekker.live.GPSFix
import nl.haltewekker.match.AskSooner
import nl.haltewekker.match.BusStops
import nl.haltewekker.match.ChoiceLook
import nl.haltewekker.match.ChoiceRun
import nl.haltewekker.match.ChooseGPS
import nl.haltewekker.match.Decision
import nl.haltewekker.match.DepartMatch
import nl.haltewekker.match.Departure
import nl.haltewekker.match.Evidence
import nl.haltewekker.match.GPSChoice
import nl.haltewekker.match.Judgement
import nl.haltewekker.match.LineRide
import nl.haltewekker.match.Ranked
import nl.haltewekker.match.Reject
import nl.haltewekker.match.TimedPiece
import nl.haltewekker.match.UsualLine
import nl.haltewekker.match.Verdict
import nl.haltewekker.match.VehicleGPS
import nl.haltewekker.match.VehicleMatch
import nl.haltewekker.match.VehicleTrack
import nl.haltewekker.match.choose
import nl.haltewekker.travel.HabitBook
import nl.haltewekker.travel.Habits
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.ZoneId

/** iOS `PickRulesTests` (0.38): the moment you left, your usual line, the bus stopping pattern, asking sooner. */
class PickRulesTest {
    private val t0 = Fx.t0
    private val utc = ZoneId.of("UTC")

    private val leaving get() = Fx.fixes(0.0, 0.0, 16) + Fx.fixes(16.0, 8.0, 11, start = t0 + 32)

    private fun bus(id: String, line: String, leaves: Double, live: Boolean = true, gps: VehicleGPS? = null): VehicleTrack {
        val piece = TimedPiece(t0 + leaves, t0 + leaves + 240, listOf(Fx.east(0.0), Fx.east(1000.0), Fx.east(2000.0)))
        return VehicleTrack(id, line, false, live, listOf(piece), gps)
    }

    private fun fix(m: Double, s: Double): GPSFix { val p = Fx.east(m); return GPSFix(p.lat, p.lon, 90.0, t0 + s) }

    @Test fun moment_standingThenMoving() {
        val d = DepartMatch.moment(leaving)
        assertNotNull(d)
        assertEquals(t0 + 32, d!!.t, 0.0)
        assertEquals(32.0, d.stood, 0.01)
        assertTrue(Geo.metres(d.p, Fx.east(0.0)) < 1)
    }

    @Test fun moment_noneWhileStandingOrWithoutAStand() {
        assertNull(DepartMatch.moment(Fx.fixes(0.0, 0.0, 20)))
        assertNull(DepartMatch.moment(Fx.fixes(0.0, 10.0, 20)))
        assertNull(DepartMatch.moment(Fx.fixes(0.0, 0.0, 5) + Fx.fixes(10.0, 8.0, 10, start = t0 + 10)))
        assertNull(DepartMatch.moment(Fx.fixes(0.0, 0.0, 16, accuracy = 120.0)))
    }

    @Test fun moment_freshness() {
        val d = Departure(t0, Fx.east(0.0), 30.0)
        assertNotNull(DepartMatch.usable(d, t0 + 200))
        assertNull(DepartMatch.usable(d, t0 + DepartMatch.FRESH + 1))
        assertNull(DepartMatch.usable(null, t0))
    }

    @Test fun clue_byLiveTimes() {
        val d = Departure(t0 + 32, Fx.east(0.0), 32.0)
        val a = DepartMatch.clue(bus("305-0001", "305", 40.0), d)
        val b = DepartMatch.clue(bus("306-0002", "306", 250.0), d)
        assertEquals(8.0, a.offBy!!, 0.01)
        assertEquals(218.0, b.offBy!!, 0.01)
        assertTrue(DepartMatch.leftThen(a))
        assertFalse(DepartMatch.leftThen(b))
        assertEquals("305-0001", DepartMatch.pick(listOf(a, b), listOf("306-0002", "305-0001")))
        assertEquals(mapOf("305-0001" to -DepartMatch.BONUS), DepartMatch.bonuses(listOf(a, b), listOf("305-0001", "306-0002")))
        assertEquals("depart · stood 32 s, left 08:00:32 · 305·0001 left then (live 8 s) · 306·0002 not then (live 218 s)",
            DepartMatch.logLine(d, listOf(a, b), mapOf("305-0001" to "305", "306-0002" to "306"), utc))
    }

    @Test fun clue_timetableOnlySaysNothing() {
        val d = Departure(t0 + 32, Fx.east(0.0), 32.0)
        val a = DepartMatch.clue(bus("305-0001", "305", 40.0), d)
        val b = DepartMatch.clue(bus("306-0002", "306", 300.0, live = false), d)
        assertNull(b.offBy)
        assertNull(DepartMatch.pick(listOf(a, b), listOf("305-0001", "306-0002")))
        assertEquals(1, DepartMatch.bonuses(listOf(a, b), listOf("305-0001", "306-0002")).size)
    }

    @Test fun clue_bothLeftTogether() {
        val d = Departure(t0 + 32, Fx.east(0.0), 32.0)
        val a = DepartMatch.clue(bus("305-0001", "305", 30.0), d)
        val b = DepartMatch.clue(bus("306-0002", "306", 60.0), d)
        assertNull(DepartMatch.pick(listOf(a, b), listOf("305-0001", "306-0002")))
        assertTrue(DepartMatch.bonuses(listOf(a, b), listOf("305-0001", "306-0002")).isEmpty())
    }

    @Test fun clue_byItsOwnGPS() {
        val d = Departure(t0 + 32, Fx.east(0.0), 32.0)
        val with = bus("305-0001", "305", 400.0, live = false, gps = VehicleGPS(fix(150.0, 50.0), fix(10.0, 20.0)))
        val stayed = bus("306-0002", "306", 40.0, gps = VehicleGPS(fix(10.0, 100.0)))
        val away = bus("306-0003", "306", 40.0, gps = VehicleGPS(fix(1200.0, 40.0)))
        val a = DepartMatch.clue(with, d); val b = DepartMatch.clue(stayed, d); val c = DepartMatch.clue(away, d)
        assertEquals(12.0, a.offBy!!, 0.01)
        assertTrue(a.byGPS)
        assertTrue(b.elsewhere)
        assertTrue(c.elsewhere)
        assertEquals("305-0001", DepartMatch.pick(listOf(a, b, c), listOf("305-0001", "306-0002", "306-0003")))
        val went = bus("306-0004", "306", 400.0, live = false, gps = VehicleGPS(fix(200.0, 120.0), fix(10.0, 100.0)))
        val w = DepartMatch.clue(went, d)
        assertFalse(w.elsewhere)
        assertNull(w.offBy)
    }

    private fun j(id: String, r: Verdict, gps: Boolean = false): Judgement {
        val e = Evidence(15, 28.0, 8.0, 15.0, true, 300.0, 0.0, 0.0, 11.0, 11.0, true, gps = gps)
        return Judgement(id, id.take(3), false, true, e, r)
    }

    private fun look(ids: List<String>, judged: List<Judgement>, shown: String, at: Double, cr: ChoiceRun,
                     nudge: Map<String, Double> = emptyMap(), departed: String? = null): ChoiceLook =
        VehicleMatch.choose(ids, judged, shown, false, at, cr, t0 + at, nudge = nudge, departed = departed)

    @Test fun choose_settlesOnTheOneThatLeftWithYou_inTwoLooks() {
        val cr = ChoiceRun()
        val ids = listOf("306-0002", "305-0001")
        val judged = listOf(j("306-0002", Verdict.Pass(12.0)), j("305-0001", Verdict.Pass(20.0)))
        assertNull(look(ids, judged, "306-0002", 0.0, cr, departed = "305-0001").settle)
        val second = look(ids, judged, "306-0002", 12.0, cr, departed = "305-0001")
        assertEquals("305-0001", second.settle)
        assertEquals(ChoiceLook.Why.DEPARTED, second.why)
        assertEquals(Decision.SwitchTo("305-0001"), second.decision)
    }

    @Test fun choose_departedShownIsSure() {
        val cr = ChoiceRun()
        val ids = listOf("305-0001", "306-0002")
        val judged = listOf(j("306-0002", Verdict.Pass(12.0)), j("305-0001", Verdict.Pass(14.0)))
        look(ids, judged, "305-0001", 0.0, cr, departed = "305-0001")
        val c = look(ids, judged, "305-0001", 12.0, cr, departed = "305-0001")
        assertEquals("305-0001", c.settle)
        assertEquals(Decision.Keep("305-0001"), c.decision)
    }

    @Test fun choose_departedRunBreaksWhenItFails() {
        var run = GPSChoice()
        val ok = listOf(j("305-0001", Verdict.Pass(10.0)), j("306-0002", Verdict.Pass(10.0)))
        val bad = listOf(j("305-0001", Verdict.Fail(Reject.DRIFTING)), j("306-0002", Verdict.Pass(10.0)))
        val alive = listOf("305-0001", "306-0002")
        fun step(js: List<Judgement>): String? { val (n, r) = ChooseGPS.departLook("305-0001", js, alive, run); run = n; return r }
        assertNull(step(ok)); assertNull(step(bad)); assertNull(step(ok))
        assertEquals("305-0001", step(ok))
    }

    @Test fun choose_itsOwnGPSStaysTheClearerEvidence() {
        var run = GPSChoice()
        val judged = listOf(j("306-0002", Verdict.Pass(5.0), gps = true), j("305-0001", Verdict.Pass(40.0)))
        repeat(3) {
            val (n, r) = ChooseGPS.departLook("305-0001", judged, listOf("306-0002", "305-0001"), run); run = n
            assertNull(r)
        }
        val cr = ChoiceRun()
        for (k in 0 until 4) assertNotEquals("305-0001", look(listOf("306-0002", "305-0001"), judged, "306-0002", k * 12.0, cr, departed = "305-0001").settle)
    }

    @Test fun choose_nudgeMovesTheRanking() {
        val ranked = listOf(Ranked("a", 10.0), Ranked("b", 20.0))
        assertEquals(listOf("b", "a"), ChooseGPS.nudged(ranked, mapOf("a" to 15.0)).map { it.id })
        assertEquals(ranked, ChooseGPS.nudged(ranked, emptyMap()))
        val ids = listOf("a-0001", "b-0002")
        val judged = listOf(j("a-0001", Verdict.Pass(20.0)), j("b-0002", Verdict.Pass(10.0)))
        var cr = ChoiceRun()
        val out = (0 until 4).map { k -> look(ids, judged, "a-0001", k * 15.0, cr, nudge = mapOf("a-0001" to 40.0)) }
        assertEquals("b-0002", out.last().settle)
        assertTrue(out.dropLast(1).all { it.settle == null })
        cr = ChoiceRun()
        for (k in 0 until 4) assertNull(look(ids, judged, "a-0001", k * 15.0, cr).settle)
    }

    private fun rides(line: String, n: Int, minute: Int = 7 * 60 + 40, weekend: Boolean = false, weight: Int = 1) =
        (0 until n).map { LineRide(line, false, minute, weekend, weight) }

    private fun o(id: String, line: String, train: Boolean = false) = UsualLine.Option(id, line, train)

    @Test fun usual_learnedSlot() {
        val r = rides("305", 3)
        val cands = listOf(o("a", "306"), o("b", "305"))
        assertEquals("b", UsualLine.usual(cands, 7 * 60 + 45, false, r))
        assertNull(UsualLine.usual(cands, 7 * 60 + 45, true, r))
        assertNull(UsualLine.usual(cands, 9 * 60, false, r))
        assertNull(UsualLine.usual(cands, 7 * 60 + 45, false, rides("305", 2)))
        assertNull(UsualLine.usual(listOf(o("a", "306"), o("b", "305", true)), 7 * 60 + 45, false, r))
    }

    @Test fun usual_correctionsCount() {
        val cands = listOf(o("a", "306"), o("b", "305"))
        assertNull(UsualLine.usual(cands, 460, false, rides("305", 3) + rides("306", 2, weight = UsualLine.SAID)))
        val more = rides("305", 3) + rides("306", 4, weight = UsualLine.SAID) + rides("305", 2, weight = UsualLine.NOT_THIS)
        assertEquals("a", UsualLine.usual(cands, 460, false, more))
        assertNull(UsualLine.usual(listOf(o("a", "305"), o("b", "305")), 460, false, rides("305", 5)))
    }

    @Test fun usual_tieBreakWithHysteresis() {
        fun c(u: Double, o: Double, gps: Boolean = false) = listOf(UsualLine.Cand("u", u, false), UsualLine.Cand("o", o, gps))
        assertEquals("u", UsualLine.tieBreak(c(20.0, 10.0), "u", null))
        assertNull(UsualLine.tieBreak(c(35.0, 10.0), "u", null))
        assertEquals("u", UsualLine.tieBreak(c(35.0, 10.0), "u", "u"))
        assertNull(UsualLine.tieBreak(c(55.0, 10.0), "u", "u"))
        assertNull(UsualLine.tieBreak(c(10.0, 10.0, gps = true), "u", "u"))
        assertNull(UsualLine.tieBreak(listOf(UsualLine.Cand("o", 10.0, false)), "u", null))
        assertNull(UsualLine.tieBreak(c(10.0, 20.0), null, null))
    }

    @Test fun usual_wordsMinuteAndKeep() {
        assertEquals(listOf("305 at 07:40 on weekdays"), UsualLine.words(rides("305", 4) + rides("306", 1)))
        assertEquals(emptyList<String>(), UsualLine.words(emptyList()))
        assertEquals(8 * 60 + 41, UsualLine.minute(t0 + 41 * 60, utc))
        assertFalse(UsualLine.weekend(t0, utc))
        assertTrue(UsualLine.weekend(t0 + 86_400, utc))
        var kept = emptyList<LineRide>()
        repeat(UsualLine.KEEP + 10) { kept = UsualLine.add(LineRide("305", false, 460, false, 1), kept) }
        assertEquals(UsualLine.KEEP, kept.size)
        assertEquals(emptyList<LineRide>(), UsualLine.add(LineRide(" ", false, 460, false, 1), emptyList()))
    }

    @Test fun usual_inTheHabitBook_andOldBooksStillRead() {
        var b = HabitBook()
        repeat(3) { b = b.rode("305", false, 460, false, UsualLine.CONFIRMED) }
        assertFalse(b.isEmpty)
        assertEquals(Habits.Row("Your usual lines", "305 at 07:40 on weekdays"), Habits.rows(b).last())
        val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
        assertEquals(b, json.decodeFromString(HabitBook.serializer(), json.encodeToString(HabitBook.serializer(), b)))
        val read = json.decodeFromString(HabitBook.serializer(), """{"walks":[1.4],"changes":[3],"boardedAt":{"x":1},"plannedAt":{},"names":{"x":"X"}}""")
        assertEquals(listOf(1.4), read.walks)
        assertEquals(mapOf("x" to 1), read.boardedAt)
        assertTrue(read.lines.isEmpty())
    }

    @Test fun busStops_stoodAndThrough() {
        val stop = Fx.east(500.0)
        assertEquals(BusStops.Seen.STOOD, BusStops.seen(Fx.fixes(490.0, 0.0, 10), stop))
        assertNull(BusStops.seen(Fx.fixes(490.0, 0.0, 6), stop))
        assertEquals(BusStops.Seen.THROUGH, BusStops.seen(Fx.fixes(200.0, 10.0, 35), stop))
        assertNull(BusStops.seen(Fx.fixes(380.0, 3.0, 80), stop))
        assertNull(BusStops.seen(Fx.fixes(200.0, 10.0, 20), stop))
        assertNull(BusStops.seen(Fx.fixes(200.0, 10.0, 35, north = 200.0), stop))
    }

    @Test fun busStops_againstAndPenalties() {
        val stops = listOf(
            BusStops.Stop("kerk", Fx.east(500.0), mutableSetOf("306"), mutableSetOf(), mutableSetOf("305", "306")),
            BusStops.Stop("station", Fx.east(900.0), mutableSetOf("305", "306"), mutableSetOf("305"), mutableSetOf("305", "306")),
            BusStops.Stop("markt", Fx.east(1300.0), mutableSetOf("306"), mutableSetOf(), mutableSetOf("305", "306")))
        val ids = listOf("305", "306")
        val one = BusStops.against(stops, mapOf("kerk" to BusStops.Seen.STOOD), ids)
        assertEquals(mapOf("305" to 1), one)
        assertTrue(BusStops.penalties(one, ids).isEmpty())
        val two = BusStops.against(stops, mapOf("kerk" to BusStops.Seen.STOOD, "station" to BusStops.Seen.THROUGH, "markt" to BusStops.Seen.THROUGH), ids)
        assertEquals(mapOf("305" to 2), two)
        assertEquals(mapOf("305" to 2 * BusStops.PENALTY), BusStops.penalties(two, ids))
        assertTrue(BusStops.penalties(mapOf("305" to 2, "306" to 2), ids).isEmpty())
        assertEquals(mapOf("305" to BusStops.MAX_PENALTY), BusStops.penalties(mapOf("305" to 9), ids))
        assertTrue(BusStops.penalties(mapOf("305" to 3), listOf("305")).isEmpty())
    }

    @Test fun ask_dueAfterAMinute() {
        assertFalse(AskSooner.due(listOf("a", "b"), 59.0, false, false))
        assertTrue(AskSooner.due(listOf("a", "b"), 61.0, false, false))
        assertFalse(AskSooner.due(listOf("a", "b"), 61.0, true, false))
        assertFalse(AskSooner.due(listOf("a", "b", "c"), 61.0, false, false))
        assertFalse(AskSooner.due(listOf("a"), 61.0, false, false))
        assertFalse(AskSooner.due(listOf("a", "b"), 120.0, false, true))
        assertTrue(AskSooner.due(listOf("a", "b"), 181.0, false, true))
    }

    @Test fun ask_words() {
        assertTrue(AskSooner.worthAsking("305" to "306", "" to ""))
        assertFalse(AskSooner.worthAsking("306" to "306", "Den Bosch" to "den bosch"))
        assertTrue(AskSooner.worthAsking("306" to "306", "Uden" to "Den Bosch"))
        assertEquals("305 or 306?", AskSooner.title("305" to "Eindhoven", "306" to "Den Bosch", false))
        assertEquals("306 to Uden or 306 to Den Bosch?", AskSooner.title("306" to "Uden", "306" to "Den Bosch", false))
        assertEquals("IC to Breda or IC to Eindhoven?", AskSooner.title("IC" to "Breda", "IC" to "Eindhoven", true))
        assertEquals("Bus 305", AskSooner.answer("305", "Eindhoven", false, false))
        assertEquals("Bus 306 to Uden", AskSooner.answer("306", "Uden", false, true))
        assertEquals("IC to Breda", AskSooner.answer("IC", "Breda", true, true))
        assertTrue(AskSooner.body(false).startsWith("Two buses"))
        assertTrue(AskSooner.body(true).startsWith("Two trains"))
    }
}
