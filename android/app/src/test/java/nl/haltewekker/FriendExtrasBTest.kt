package nl.haltewekker

import nl.haltewekker.friends.B64u
import nl.haltewekker.friends.Friend
import nl.haltewekker.friends.FriendBook
import nl.haltewekker.friends.FriendIdentity
import nl.haltewekker.friends.FriendInbox
import nl.haltewekker.friends.FreeToday
import nl.haltewekker.friends.FreeTodaySlot
import nl.haltewekker.friends.Hex
import nl.haltewekker.friends.RelayBox
import nl.haltewekker.friends.RideHistory
import nl.haltewekker.friends.RideHistoryWords
import nl.haltewekker.friends.RideTogether
import nl.haltewekker.friends.RidesRow
import nl.haltewekker.friends.ScoreBoard
import nl.haltewekker.friends.ScoreTrip
import nl.haltewekker.friends.ScoresPerson
import nl.haltewekker.friends.ScoresRules
import nl.haltewekker.friends.ScoresShare
import nl.haltewekker.friends.TimetableClass
import nl.haltewekker.friends.TimetableShare
import nl.haltewekker.friends.TimetableShareRules
import nl.haltewekker.friends.TravelState
import nl.haltewekker.friends.TripCard
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Friends 0.30 (extras, part B): free hours together, the leaderboard with friends, the ride history (iOS `FriendExtrasBTests`). */
class FriendExtrasBTest {
    private val t0 = 1_800_000_000.0          // Friday 15 January 2027, 09:00 in Amsterdam
    private val midnight = 1_799_967_600.0
    private fun t(s: Int) = t0 + s

    private fun share(classes: List<Pair<Int, Int>>, days: Int = 14) =
        TimetableShare(midnight, midnight + days * 86400.0, classes.map { TimetableClass(t(it.first), t(it.second)) })

    // you: 10:15–12:00, 13:30–15:45 · Sam: 09:00–11:30, 13:00–14:00 · Lisa and Kim: 10:00–12:00, 13:30–16:00
    private val mine = share(listOf(4500 to 10800, 16200 to 24300))
    private val sam = share(listOf(0 to 9000, 14400 to 18000))
    private val lisa = share(listOf(3600 to 10800, 16200 to 25200))

    @Test fun freeToday() {
        val s = FreeToday.slots(mine, listOf("sam" to sam, "lisa" to lisa), t0)
        assertEquals(listOf(FreeTodaySlot(t(10800), t(14400), listOf("sam")), FreeTodaySlot(t(10800), t(16200), listOf("lisa"))), s)
        assertEquals("Today: you and Sam are both free 12:00–13:00", FreeToday.line(s[0], listOf("Sam"), t0))
        assertEquals("Today: you and Lisa are both free 12:00–13:30", FreeToday.line(s[1], listOf("Lisa"), t0))
        assertEquals("You and Sam are both free 12:00–13:00\nYou and Lisa are both free 12:00–13:30",
            FreeToday.note(s, { if (it == "sam") "Sam" else "Lisa" }, t0))
    }

    @Test fun freeTodayTogetherAndLater() {
        val s = FreeToday.slots(mine, listOf("lisa" to lisa, "kim" to lisa), t0)
        assertEquals(listOf(FreeTodaySlot(t(10800), t(16200), listOf("kim", "lisa"))), s)
        assertEquals("Today: you, Kim and Lisa are all free 12:00–13:30", FreeToday.line(s[0], listOf("Kim", "Lisa"), t0))
        val mid = FreeToday.slots(mine, listOf("sam" to sam), t(12600))
        assertEquals("Now: you and Sam are both free until 13:00", FreeToday.line(mid[0], listOf("Sam"), t(12600)))
        assertEquals(listOf(listOf("lisa")), FreeToday.slots(mine, listOf("sam" to sam, "lisa" to lisa), t(15300)).map { it.with })
    }

    @Test fun freeTodayNothing() {
        assertEquals(emptyList<FreeTodaySlot>(), FreeToday.slots(null, listOf("sam" to sam), t0))
        val old = TimetableShare(midnight - 20 * 86400, midnight - 6 * 86400, emptyList())
        assertEquals(emptyList<FreeTodaySlot>(), FreeToday.slots(mine, listOf("x" to old), t0))
        assertEquals(emptyList<FreeTodaySlot>(), FreeToday.slots(mine, listOf("x" to share(emptyList())), t0))
        assertEquals(1, FreeToday.slots(mine, listOf("x" to share(listOf(0 to 11400, 13200 to 18000))), t0).size)
        assertEquals(emptyList<FreeTodaySlot>(), FreeToday.slots(mine, listOf("x" to share(listOf(0 to 11700, 13200 to 18000))), t0))
    }

    @Test fun freeTodayNote() {
        val s = FreeToday.slots(mine, listOf("sam" to sam), t0)
        assertTrue(FreeToday.noteDue(true, null, s, t0))
        assertTrue(FreeToday.noteDue(true, "2027-01-14", s, t(-3 * 3600)))
        assertFalse(FreeToday.noteDue(true, null, s, t(-3 * 3600 - 60)))
        assertFalse(FreeToday.noteDue(true, null, s, t(2 * 3600)))
        assertFalse(FreeToday.noteDue(true, "2027-01-15", s, t0))
        assertFalse(FreeToday.noteDue(false, null, s, t0))
        assertFalse(FreeToday.noteDue(true, null, emptyList(), t0))
    }

    // MARK: the leaderboard with friends

    companion object {
        val myTrips = listOf(
            ScoreTrip("home→school", false, 52.34, 1_799_391_600.0),     // last week
            ScoreTrip("home→school", false, 48.5, 1_799_996_400.0),      // this morning
            ScoreTrip("school→home", true, 52.0, 1_799_910_000.0),
            ScoreTrip("school→home", true, 55.0, 1_798_000_000.0),       // December
            ScoreTrip("home→school", false, 3.0, 1_799_996_000.0),       // too short to count
        )
    }

    @Test fun scoresBuild() {
        val s = ScoresRules.build(myTrips, 14, t0)
        assertEquals("2027-01", s.month)
        val two = listOf(ScoresShare.Best("home→school", false, 48.5, 1_799_996_400.0), ScoresShare.Best("school→home", true, 52.0, 1_799_910_000.0))
        assertEquals(two, s.best)
        assertEquals(two, s.mbest)
        assertEquals(14, s.rides)
        assertEquals("2026-12", ScoresRules.month(1_798_000_000.0))
        assertTrue(ScoresRules.isMonth("2027-01"))
        assertFalse(ScoresRules.isMonth("2027-13"))
        assertFalse(ScoresRules.isMonth("27-01"))
    }

    @Test fun scoresValid() {
        var s = ScoresShare(true, "2027-1", listOf(ScoresShare.Best("  Via\tDen  Bosch ", false, 40.0, t0), ScoresShare.Best("", false, 40.0, t0),
            ScoresShare.Best("x", true, 601.0, t0)), listOf(ScoresShare.Best("x", true, 30.0, t0)), 3)
        var v = ScoresShare.valid(s)
        assertEquals(listOf(ScoresShare.Best("Via Den Bosch", false, 40.0, t0)), v.best)
        assertNull(v.month); assertNull(v.mbest); assertNull(v.rides)
        s = s.copy(month = "2027-01", rides = 5000, best = List(12) { ScoresShare.Best("r", false, 20.0, t0) })
        v = ScoresShare.valid(s)
        assertEquals(8, v.best?.size)
        assertEquals(1, v.mbest?.size)
        assertNull(v.rides)
        assertEquals(ScoresShare(false), ScoresShare.valid(ScoresShare(false, "2027-01", rides = 2)))
    }

    @Test fun scoresDue() {
        val friends = listOf("b", "a")
        assertEquals(listOf("a", "b"), ScoresRules.due(null, "h1", friends, t0))
        assertEquals(emptyList<String>(), ScoresRules.due(null, "h1", emptyList(), t0))
        val sent = TimetableShareRules.Sent("h1", t0, listOf("a", "b"))
        assertEquals(emptyList<String>(), ScoresRules.due(sent, "h1", friends, t(3600)))
        assertEquals("changed, too soon", emptyList<String>(), ScoresRules.due(sent, "h2", friends, t(3600)))
        assertEquals(listOf("a", "b"), ScoresRules.due(sent, "h2", friends, t(12 * 3600)))
        assertEquals("a new friend at once", listOf("c"), ScoresRules.due(sent, "h1", friends + "c", t(3600)))
        assertEquals(listOf("a", "b"), ScoresRules.due(sent, "h1", friends, t(7 * 86400)))
        assertNotEquals(ScoresRules.fingerprint(ScoresRules.build(myTrips, 14, t0)), ScoresRules.fingerprint(ScoresRules.build(myTrips, 15, t0)))
    }

    @Test fun scoreBoard() {
        val me = ScoresPerson("me", ScoresRules.build(myTrips, 14, t0))
        val sam = ScoresPerson("sam", ScoresShare(true, "2027-01",
            listOf(ScoresShare.Best("home→school", false, 39.5, 1_799_000_000.0), ScoresShare.Best("Via Den Bosch", false, 61.0, 1_799_000_000.0)),
            listOf(ScoresShare.Best("home→school", false, 44.0, 1_799_900_000.0)), 20))
        val lou = ScoresPerson("lou", ScoresShare(true, "2026-12", listOf(ScoresShare.Best("school→home", true, 50.0, 1_798_000_000.0)),
            listOf(ScoresShare.Best("school→home", true, 50.0, 1_798_000_000.0)), 30))
        val off = ScoresPerson("off", ScoresShare(false))
        val all = listOf(me, sam, lou, off)
        val ever = ScoreBoard.groups(all, null)
        assertEquals(listOf("false|home→school", "false|Via Den Bosch", "true|school→home"), ever.map { it.id })
        assertEquals(listOf("sam", "me"), ever[0].rows.map { it.who })
        assertEquals(listOf("lou", "me"), ever[2].rows.map { it.who })
        val month = ScoreBoard.groups(all, "2027-01")
        assertEquals(listOf("false|home→school", "true|school→home"), month.map { it.id })
        assertEquals(listOf(44.0, 48.5), month[0].rows.map { it.mins })
        assertEquals("Lou's are December's", listOf("me"), month[1].rows.map { it.who })
        assertEquals(listOf(RidesRow("sam", 20), RidesRow("me", 14)), ScoreBoard.rides(all, "2027-01"))
        assertEquals("Home → school", ScoreBoard.label(ever[0]))
        assertEquals("Via Den Bosch · to school", ScoreBoard.label(ever[1]))
    }

    @Test fun scoresFromAFriendOnly() {
        val sam = FriendIdentity(Hex.decode("000102030405060708090a0b0c0d0e0f")!!)
        val lou = FriendIdentity(Hex.decode("101112131415161718191a1b1c1d1e1f")!!)
        val book = FriendBook.named("Lou")
        val box = RelayBox(1, sam.account, "scores", 1_800_000_001, 1_801_000_000, FriendExtrasVectorTest.SCORES_BOX)
        assertTrue(FriendInbox.process(listOf(box), book, me = lou, now = t0).scores.isEmpty())
        book.friends = listOf(Friend(sam.card, "Sam", t0))
        val r = FriendInbox.process(listOf(box), book, me = lou, now = t0)
        assertEquals(14, r.scores[sam.account]?.share?.rides)
        assertEquals("2027-01", r.scores[sam.account]?.share?.month)
        assertEquals(listOf(1L), r.ack)
        assertTrue(B64u.decode(FriendExtrasVectorTest.SCORES_BOX) != null)
    }

    // MARK: ride history together

    private val ehv = TravelState.Spot("Eindhoven Centraal", 51.44306, 5.47917)
    private val bd = TravelState.Spot("Breda", 51.59556, 4.78)

    private fun travel(trip: String, stage: String = "riding") = TravelState(stage, "train", "IC", "3512", trip, ehv, bd)

    private fun card(trip: String): TripCard {
        val a = TripCard.Spot("Eindhoven Centraal"); val b = TripCard.Spot("Breda")
        return TripCard(listOf(TripCard.Ride(mode = "bus", line = "6", trip = "bus-6", from = a, to = a, dep = t0, arr = t(600)),
            TripCard.Ride(mode = "train", line = "IC", trip = trip, from = a, to = b, dep = t(660), arr = t(3720))), b)
    }

    @Test fun ridersTogether() {
        val tr = listOf("sam" to travel("ic-3512"), "lisa" to travel("ic-3512", "waiting"), "tom" to travel("ic-3516"))
        assertEquals(listOf("sam"), RideHistory.riders("ic-3512", tr, emptyList(), "me"))
        val cards = listOf(card("ic-3512") to listOf("kim", "sam"), card("ic-3520") to listOf("tom"))
        assertEquals(listOf("kim", "sam"), RideHistory.riders("ic-3512", tr, cards, "me"))
        assertEquals("a card's shared ride is its train", emptyList<String>(), RideHistory.riders("bus-6", tr, cards, "me"))
        assertEquals(emptyList<String>(), RideHistory.riders("", tr, cards, "me"))
    }

    private fun ride(trip: String, day: String, dep: Double, with: List<String>) = RideTogether(trip, day, "IC 3512", "Eindhoven Centraal", "Breda", dep, with)

    @Test fun rideHistory() {
        var h = emptyList<RideTogether>()
        h = RideHistory.add(h, ride("ic-3512", "2027-01-15", t0, listOf("sam")), t0)
        h = RideHistory.add(h, ride("ic-3512", "2027-01-15", t0, listOf("kim", "sam")), t(60))
        h = RideHistory.add(h, ride("ic-3520", "2027-01-14", t(-86400), listOf("sam")), t0)
        h = RideHistory.add(h, ride("ic-3500", "2026-12-20", 1_797_750_000.0, listOf("sam")), t0)
        h = RideHistory.add(h, ride("ic-1", "2027-01-15", t0, emptyList()), t0)
        assertEquals(3, h.size)
        assertEquals(listOf("kim", "sam"), h[0].with)
        assertEquals(2, RideHistory.count(h, "sam", t0))
        assertEquals(1, RideHistory.count(h, "kim", t0))
        assertEquals(2, RideHistory.count(h, t0))
        assertEquals(listOf("ic-3512", "ic-3520", "ic-3500"), RideHistory.last(h, "sam").map { it.trip })
        assertEquals(listOf("ic-3512"), RideHistory.last(h, "sam", 1).map { it.trip })
        assertEquals(listOf("x"), RideHistory.add(h, ride("x", "2028-03-01", t(410 * 86400), listOf("sam")), t(410 * 86400)).map { it.trip })
        assertEquals(listOf("ic-3512"), RideHistory.keep(h, setOf("kim")).map { it.trip })
        assertEquals("You rode together 14 times this month", RideHistoryWords.month(14))
        assertEquals("You rode together once this month", RideHistoryWords.month(1))
        assertEquals("No rides together this month yet", RideHistoryWords.month(0))
        assertEquals("Fri 15 Jan · 09:00 · IC 3512 · Eindhoven Centraal → Breda", RideHistoryWords.row(h[0]))
    }
}
