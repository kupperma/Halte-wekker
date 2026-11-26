package nl.haltewekker

import nl.haltewekker.core.GeoPoint
import nl.haltewekker.friends.DailyRank
import nl.haltewekker.friends.DayTrip
import nl.haltewekker.friends.DoorScore
import nl.haltewekker.friends.FriendJson
import nl.haltewekker.friends.ScoreRules
import nl.haltewekker.friends.ScoreTrip
import nl.haltewekker.friends.ScoresRules
import nl.haltewekker.friends.ScoresShare
import nl.haltewekker.friends.TimetableShareRules
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.ZoneId

/** iOS `DailyRankTests`, `ScoreRulesTests` (the board's rule) and FriendExtrasBTests' 0.35 vectors. */
class DailyRankTest {
    private val t0 = 1_800_000_000.0          // Friday 15 January 2027, 09:00 in Amsterdam
    private val zone = ZoneId.of("Europe/Amsterdam")
    private fun t(s: Double) = t0 + s

    private fun score(mins: Double, home: Boolean = false, at: Double, plan: Double? = null, line: String? = null, late: Double? = null) =
        ScoreTrip(if (home) "school→home" else "home→school", home, mins, at, plan, line, late)

    @Test fun duration() {
        assertEquals("41 min", DailyRank.duration(41.2)); assertEquals("1 h", DailyRank.duration(60.0))
        assertEquals("1 h 05", DailyRank.duration(65.0)); assertEquals("1 h 12", DailyRank.duration(72.0)); assertEquals("1 h", DailyRank.duration(59.6))
    }

    @Test fun withFriends() {
        val me = DailyRank.today(listOf(score(48.5, at = t(-1800.0))), t0, zone)
        val sam = listOf(DayTrip(false, 41.0, t(-2400.0), plan = 40.0))
        val tom = listOf(DayTrip(false, 72.0, t(-600.0), plan = 52.0, line = "305", late = 18.0))
        val rows = DailyRank.rows(listOf("me" to me, "sam" to sam, "tom" to tom), emptyList(), t0, zone)
        assertEquals(1, rows.size)
        assertEquals("sam", rows[0].fastest.who); assertEquals("tom", rows[0].slowest?.who); assertEquals(3, rows[0].count); assertFalse(rows[0].mine)
        val names = mapOf("sam" to "Sam", "tom" to "Tom")
        assertEquals(listOf("🏆 Fastest today: Sam, 41 min", "🐌 Slowest today: Tom, 1 h 12 — the 305 was 18 min late"), DailyRank.lines(rows[0]) { names[it] ?: "?" })
    }

    @Test fun youAreFastestAndNoReason() {
        val rows = DailyRank.rows(listOf("me" to listOf(DayTrip(true, 39.0, t(-60.0))), "kim" to listOf(DayTrip(true, 47.0, t(-120.0), plan = 45.0))), emptyList(), t0, zone)
        assertEquals(listOf("🏆 Fastest today: you, 39 min", "🐌 Slowest today: Kim, 47 min"), DailyRank.lines(rows[0]) { "Kim" })
        assertEquals(" — 20 min more than planned", DailyRank.why(DayTrip(true, 70.0, t0, 50.0, "IC", 2.0)))
        assertEquals("", DailyRank.why(DayTrip(true, 53.0, t0, 50.0)))
    }

    @Test fun onYourOwn() {
        val past = listOf(score(50.0, at = t(-86400.0)), score(46.0, at = t(-2 * 86400.0)), score(52.0, at = t(-3 * 86400.0)),
            score(30.0, at = t(-40 * 86400.0)), score(60.0, home = true, at = t(-86400.0)))
        assertEquals(50.0, DailyRank.usual(past, false, t0, zone)!!, 0.0)
        assertNull(DailyRank.usual(past, true, t0, zone))
        val all = listOf(score(41.0, at = t(-3600.0)), score(65.0, at = t(-1200.0), line = "Intercity", late = 9.0)) + past
        val rows = DailyRank.rows(listOf("me" to DailyRank.today(all, t0, zone)), all, t0, zone)
        assertEquals(1, rows.size); assertTrue(rows[0].mine)
        assertEquals(listOf("🏆 Fastest today: 41 min · 9 min quicker than usual", "🐌 Slowest today: 1 h 05 — the Intercity was 9 min late"), DailyRank.lines(rows[0]) { it })
        val one = DailyRank.rows(listOf("me" to DailyRank.today(listOf(score(51.0, at = t(-60.0))) + past, t0, zone)), past, t0, zone)
        assertEquals(listOf("Today: 51 min · about your usual"), DailyRank.lines(one[0]) { it })
        assertEquals(" · 6 min slower than usual", DailyRank.vsUsual(56.0, 50.0))
        assertEquals("", DailyRank.vsUsual(56.0, null))
    }

    @Test fun resetsAtMidnight() {
        val lastNight = 1_799_967_600.0 - 60
        val mine = listOf(score(45.0, at = lastNight))
        assertEquals(emptyList<DayTrip>(), DailyRank.today(mine, t0, zone))
        assertEquals(1, DailyRank.today(mine, lastNight + 30, zone).size)
        assertEquals(emptyList<DailyRank.Row>(), DailyRank.rows(listOf("sam" to listOf(DayTrip(false, 41.0, lastNight))), emptyList(), t0, zone))
    }

    @Test fun bothWaysAndTies() {
        val rows = DailyRank.rows(listOf("me" to listOf(DayTrip(true, 50.0, t(-60.0)), DayTrip(false, 44.0, t(-7200.0))),
            "ann" to listOf(DayTrip(false, 44.0, t(-7200.0)))), emptyList(), t0, zone)
        assertEquals(listOf(false, true), rows.map { it.home })
        assertEquals("me", rows[0].fastest.who); assertEquals("me", rows[0].slowest?.who); assertNull(rows[1].slowest)
    }

    @Test fun valid() {
        val list = listOf(DayTrip(false, 4.0, t0), DayTrip(false, 41.0, t0, 700.0, " \u0007305  ", 18.0),
            DayTrip(true, 50.0, t0, 45.0, "IC", 0.5), DayTrip(true, 50.0, t0, null, "", 5.0))
        assertEquals(listOf(DayTrip(false, 41.0, t0, line = "305", late = 18.0), DayTrip(true, 50.0, t0, plan = 45.0), DayTrip(true, 50.0, t0)), DayTrip.valid(list))
        assertNull(DayTrip.valid(null))
        assertEquals(12, DayTrip.valid(List(20) { DayTrip(true, 50.0, t0) })?.size)
    }

    // the 0.35 vector: the scores body with today's trips, byte for byte

    @Test fun scoresToday() {
        val today = listOf(DayTrip(false, 72.0, 1_799_998_200.0, 52.0, "305", 18.0))
        val body = ScoresShare(on = true, month = "2027-01", today = today)
        val bytes = FriendJson.encodeString(ScoresShare.serializer(), body)
        assertEquals("""{"month":"2027-01","on":true,"today":[{"at":1799998200,"home":false,"late":18,"line":"305","mins":72,"plan":52}]}""", bytes)
        assertEquals(today, ScoresShare.valid(FriendJson.decode(ScoresShare.serializer(), bytes)!!).today)
        val old = FriendJson.decode(ScoresShare.serializer(), """{"on":true,"month":"2027-01","rides":3}""")!!
        assertNull(old.today)
        val mine = listOf(ScoreTrip("home→school", false, 44.0, t0 - 86400))
        assertNull(ScoresRules.build(mine, 14, t0).today)
        assertEquals(today, ScoresRules.build(mine, 14, t0, today).today)
        assertNull(ScoresShare.valid(ScoresShare(on = false, today = today)).today)
    }

    @Test fun scoresDueSoon() {
        val sent = TimetableShareRules.Sent("h1", t0, listOf("a"))
        assertEquals(emptyList<String>(), ScoresRules.due(sent, "h2", listOf("a"), t(240.0), soon = true))
        assertEquals(listOf("a"), ScoresRules.due(sent, "h2", listOf("a"), t(300.0), soon = true))
        assertEquals(emptyList<String>(), ScoresRules.due(sent, "h2", listOf("a"), t(300.0)))
    }

    // the board's rule (iOS ScoreRulesTests, the custom trip)

    private val home = Fx.east(0.0)
    private val school = Fx.east(20_000.0)

    @Test fun aPlannedTripBetweenHomeAndSchoolIsScored() {
        val f = ScoreRules.Finished(startedAtLeg = 0, starts = listOf(Fx.east(800.0)), end = Fx.east(19_500.0), home = home, school = school)
        assertEquals(DoorScore.TO_SCHOOL to false, ScoreRules.board(f))
        assertEquals(DoorScore.TO_HOME to true, ScoreRules.board(f.copy(starts = listOf(Fx.east(19_000.0)), end = Fx.east(300.0))))
        assertNull(ScoreRules.board(f.copy(demo = true)))
        assertNull("started at a change: not a whole trip", ScoreRules.board(f.copy(startedAtLeg = 1)))
        assertNull(ScoreRules.board(f.copy(end = Fx.east(10_000.0))))
    }

    @Test fun aStaleStartFixFallsBackToTheFirstStop() {
        val farFix = Fx.east(9000.0)
        val firstStop = Fx.east(600.0)
        // a fresh fix far from home: the first stop is tried next
        val f = ScoreRules.Finished(startedAtLeg = 0, starts = ScoreRules.starts(farFix, t0 - 30, t0, firstStop), end = Fx.east(19_800.0), home = home, school = school)
        assertEquals(DoorScore.TO_SCHOOL, ScoreRules.board(f)?.first)
        // a stale fix isn't used at all
        assertEquals(listOf(firstStop), ScoreRules.starts(farFix, t0 - 3600, t0, firstStop))
        assertEquals(listOf(farFix, firstStop), ScoreRules.starts(farFix, t0 - 300, t0, firstStop))
        assertEquals(listOf<GeoPoint>(), ScoreRules.starts(null, null, t0, null))
    }

    @Test fun theSavedBoardReadsEntryByEntry() {
        val good = """{"route":"home→school","home":false,"mins":44.5,"at":1800000000}"""
        assertEquals(1, ScoreRules.decode("[$good]").size)
        assertEquals(2, ScoreRules.decode("""[$good,{"route":5},$good]""").size)
        assertEquals(emptyList<ScoreTrip>(), ScoreRules.decode("nonsense"))
        assertEquals(emptyList<ScoreTrip>(), ScoreRules.decode(null))
        // an entry from before A6 (no plan, late) still reads
        assertNull(ScoreRules.decode("[$good]")[0].plan)
    }

    @Test fun theWorstLateRideStays() {
        assertEquals("305" to 18.0, ScoreRules.worse(null, "305" to 18.0))
        assertEquals("305" to 18.0, ScoreRules.worse("305" to 18.0, "IC" to 4.0))
        assertEquals("IC" to 20.0, ScoreRules.worse("305" to 18.0, "IC" to 20.0))
    }
}
