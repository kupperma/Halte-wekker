package nl.haltewekker

import nl.haltewekker.core.GeoPoint
import nl.haltewekker.friends.B64u
import nl.haltewekker.friends.BuddyPlan
import nl.haltewekker.friends.BuddyRules
import nl.haltewekker.friends.ChatText
import nl.haltewekker.friends.ExtrasSettings
import nl.haltewekker.friends.Friend
import nl.haltewekker.friends.FriendBook
import nl.haltewekker.friends.FriendGroup
import nl.haltewekker.friends.FriendIdentity
import nl.haltewekker.friends.FriendJson
import nl.haltewekker.friends.FriendRequest
import nl.haltewekker.friends.FriendVaultContents
import nl.haltewekker.friends.GroupMember
import nl.haltewekker.friends.GroupRoster
import nl.haltewekker.friends.NSStation
import nl.haltewekker.friends.ScoreTrip
import nl.haltewekker.friends.TestFriendBrain
import nl.haltewekker.friends.TestTripSim
import nl.haltewekker.friends.TestWait
import nl.haltewekker.friends.TestWaitSim
import nl.haltewekker.friends.TimetableClass
import nl.haltewekker.friends.TimetableDays
import nl.haltewekker.friends.TimetableSettings
import nl.haltewekker.friends.TimetableShare
import nl.haltewekker.friends.TravelState
import nl.haltewekker.friends.TripCard
import nl.haltewekker.friends.WaitFor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.DayOfWeek

/**
 * Test friend (A5, iOS 0.30.1): the bot's brain as plain rules: what it says back, its timetable and scores near yours,
 * its pretend trip and wait, and that your vault never holds it (docs/superpowers/specs/2026-11-18-friends-design.md,
 * "As built (0.30.1)"). The same cases as the iOS app's TestFriendTests.
 */
class TestFriendTest {
    private val t0 = 1_800_000_000.0          // Friday 15 January 2027, 09:00 in Amsterdam
    private val midnight = 1_799_967_600.0    // that day's 00:00
    private fun t(s: Double) = t0 + s
    private fun seed(first: Int) = ByteArray(16) { (first + it).toByte() }

    // MARK: what it says back

    @Test fun replies() {
        assertEquals("No problem, I’ll wait. See you in a bit!", TestFriendBrain.reply("Running 5 min late"))
        assertEquals("Saved you one by the window.", TestFriendBrain.reply("Save me a seat"))
        assertEquals("Sure, I’ll wait for you!", TestFriendBrain.reply("Wait for me"))
        assertEquals("Great, I’m almost there!", TestFriendBrain.reply("I’m at the stop"))
        assertEquals("Great, I’m almost there!", TestFriendBrain.reply("i'm at the stop "))
        assertEquals("Nice, I’ll look out for you on the 305.", TestFriendBrain.reply("On the 305"))
        assertEquals("Hi! Test friend here. Your message came through, locked end to end.", TestFriendBrain.reply("Hello"))
        assertEquals("Good question! I’m only a test friend, so I can’t really answer, but your message came through fine.",
            TestFriendBrain.reply("Where are you?"))
        assertEquals("You said: “See you at the station”. Got it, locked end to end.", TestFriendBrain.reply("See you at the station"))
        assertNull(TestFriendBrain.reply("  \n "))
        assertEquals("You said: “${"a".repeat(80)}…”. Got it, locked end to end.", TestFriendBrain.reply("a".repeat(120)))
        assertEquals("Thanks for waiting! Nearly there.", TestFriendBrain.replyToAnswer("wait"))
        assertEquals("OK, let’s take the next one together.", TestFriendBrain.replyToAnswer("next"))
        assertNull(TestFriendBrain.replyToAnswer("something-new"))
        assertEquals(ChatText("I’ll wait", "w1", "wait"), TestFriendBrain.replyToWait("w1"))
        assertEquals("Hi everyone! I’m the test friend. Thanks for adding me to “Uni crew”. I answer here too.", TestFriendBrain.groupHello("Uni crew"))
    }

    @Test fun tripCard() {
        val ride = TripCard.Ride(mode = "train", line = "IC", num = "3512", trip = "vector-trip-3512", from = TripCard.Spot("Eindhoven Centraal"),
            to = TripCard.Spot("Breda"), dep = t0, arr = t(3000.0))
        val out = TestFriendBrain.repliesToTrip(TripCard(listOf(ride), TripCard.Spot("BUas")), "n1")
        assertEquals(2, out.size)
        assertEquals(ChatText("I’m in", "n1", "in"), out[0])
        assertEquals("See you on the IC 3512 at 09:00!", out[1].text)
        assertNull(out[1].answer)
    }

    // MARK: its timetable and scores

    @Test fun timetable() {
        val tt = TestFriendBrain.timetable(null, t0)
        assertEquals(midnight, tt.from, 0.0)
        assertEquals(midnight + 14 * 86400, tt.to, 0.0)
        assertNotNull(TimetableShare.valid(tt))
        assertEquals("week", tt.src)
        // 10 weekdays in the two weeks from Friday, two of them Wednesdays (no afternoon)
        assertEquals(28, tt.classes.size)
        assertEquals(midnight + 10.5 * 3600, tt.classes.first().start, 0.0)     // Friday 10:30
        assertEquals(midnight + 12 * 3600, tt.classes.first().end!!, 0.0)
        val monday = midnight + 3 * 86400
        val mon = tt.classes.filter { TimetableDays.key(it.start) == TimetableDays.key(monday) }
        assertEquals(listOf(monday + 8.75 * 3600, monday + 10.75 * 3600, monday + 13.25 * 3600), mon.map { it.start })
        val wed = midnight + 5 * 86400
        assertEquals(2, tt.classes.count { TimetableDays.key(it.start) == TimetableDays.key(wed) })
        assertTrue(tt.classes.all { TimetableDays.localDate(it.start).dayOfWeek != DayOfWeek.SUNDAY })
        // near yours: your Monday starts at 09:30, so does its
        val mine = TimetableShare(midnight, midnight + 14 * 86400, listOf(TimetableClass(monday + 9.5 * 3600, monday + 11 * 3600)))
        val near = TestFriendBrain.timetable(mine, t0)
        assertEquals(monday + 9.5 * 3600, near.classes.first { TimetableDays.key(it.start) == TimetableDays.key(monday) }.start, 0.0)
    }

    @Test fun scores() {
        val none = TestFriendBrain.scores(emptyList(), 2, t0)
        assertTrue(none.on)
        assertEquals("2027-01", none.month)
        assertEquals(listOf("home→school", "school→home"), none.best?.map { it.route })
        assertEquals(listOf(46.5, 51.2), none.best?.map { it.mins })
        assertEquals(none.best, none.mbest)
        assertEquals(2, none.rides)
        val mine = listOf(ScoreTrip("home→school", false, 40.0, t(-86400.0)), ScoreTrip("school→home", true, 50.0, t(-86400.0)))
        assertEquals(listOf(42.0, 48.0), TestFriendBrain.scores(mine, 0, t0).best?.map { it.mins })
    }

    @Test fun buddy() {
        val from = TripCard.Spot("Eindhoven Centraal", lat = 51.44306, lon = 5.47917)
        val to = TripCard.Spot("Eindhoven Strijp-S", lat = 51.4497, lon = 5.4580)
        val ride = TestFriendBrain.ride(from, to, true, t0, 4.0, "test-1")
        assertEquals(t(240.0), ride.dep, 0.0)
        assertEquals("SPR", ride.line)
        val plan = TestFriendBrain.buddy(t0, ride)
        assertEquals(BuddyPlan(on = true, day = "2027-01-15", leave = t(-360.0), ride = ride, left = null), plan)
        // your phone tells you now: 5 minutes after it should have left, not moving
        assertTrue(BuddyRules.alert(plan.leave!!, plan.ride, false, null, "2027-01-15", t0))
    }

    // MARK: its pretend trip and wait

    @Test fun tripSim() {
        val stops = listOf(
            TestTripSim.RealStop("A", 51.0, 5.0, t(120.0)),
            TestTripSim.RealStop("B", 51.01, 5.02, t(420.0)),
            TestTripSim.RealStop("C", 51.02, 5.04, t(720.0)),
            TestTripSim.RealStop("D", 51.03, 5.06, t(120.0 + 30 * 60)),          // past 25 minutes: not taken
        )
        val trip = TestTripSim.make("train", "SPR", null, "x", stops, "Zwolle", t0)!!
        assertEquals(listOf("A", "B", "C"), trip.stops.map { it.name })
        assertEquals(listOf(0.0, 300.0, 600.0), trip.stops.map { it.at })
        assertEquals("Zwolle", trip.dest)
        // a minute waiting at the first stop
        val w = TestTripSim.state(trip, t(30.0))!!
        assertEquals("waiting", w.state)
        assertEquals("A", w.from.name)
        assertEquals("C", w.to.name)
        assertEquals(51.0, w.pos!!.lat, 0.0)
        assertNull(w.coach)
        assertEquals(t(660.0), w.eta!!, 0.0)
        // then on board, half way from A to B, with a coach
        val r = TestTripSim.state(trip, t(60.0 + 150))!!
        assertEquals("riding", r.state)
        assertEquals(51.005, r.pos!!.lat, 0.00001)
        assertEquals(5.01, r.pos!!.lon, 0.00001)
        // and a window: a Sprinter has one deck
        assertEquals(TravelState.Coach(3, 6, true, null, TravelState.Seat("none", 6, 11)), r.coach)
        assertEquals(TravelState.Seat("upper", 8, 11), TestTripSim.coach("IC").seat)
        assertEquals("x", r.trip)
        assertEquals("Zwolle", r.dest?.name)
        // over at the last stop
        assertNull(TestTripSim.state(trip, t(660.0)))
        assertTrue(TestTripSim.over(trip, t(660.0)))
        assertNull(TestTripSim.state(trip, t(-1.0)))
        // without times: by distance; one stop isn't a trip; a headsign that is the last stop isn't a "then on to"
        val untimed = stops.take(3).map { TestTripSim.RealStop(it.name, it.lat, it.lon, null) }
        val d = TestTripSim.make("bus", "300", null, "y", untimed, "C", t0)!!
        assertEquals(0.0, d.stops.first().at, 0.0)
        assertEquals(600.0, d.stops.last().at, 0.0)
        assertEquals(300.0, d.stops[1].at, 5.0)
        assertNull(d.dest)
        assertNull(TestTripSim.state(d, t(300.0))?.coach)
        assertNull(TestTripSim.make("bus", "300", null, "z", listOf(stops[0]), null, t0))
    }

    @Test fun tripFallback() {
        val stations = listOf(NSStation("A", "", "Alpha", lat = 51.0, lon = 5.0), NSStation("B", "", "Beta", lat = 51.02, lon = 5.0),
            NSStation("C", "", "Gamma", lat = 51.005, lon = 5.0), NSStation("D", "", "Delta", lat = 51.1, lon = 5.0))
        val trip = TestTripSim.fallback(GeoPoint(51.001, 5.0), stations, t0)!!
        assertEquals(listOf("Alpha", "Beta"), trip.stops.map { it.name })
        assertEquals("test-friend-A-B", trip.trip)
        assertTrue(trip.isTrain)
        assertNull(TestTripSim.fallback(GeoPoint(53.5, 7.5), stations, t0))
    }

    @Test fun waitSim() {
        val stop = TripCard.Spot("Eindhoven Centraal", lat = 51.44306, lon = 5.47917)
        val w = TestWait("w1", stop, t0)
        val a = TestWaitSim.body(w, t0)
        assertEquals(WaitFor.Phase.COMING, a.phase)
        assertEquals(650, a.dist)
        assertEquals(t(300.0), a.eta!!, 0.0)
        assertNotNull(WaitFor.valid(a))
        assertEquals(330, TestWaitSim.body(w, t(150.0)).dist)
        val b = TestWaitSim.body(w, t(300.0))
        assertEquals(WaitFor.Phase.THERE, b.phase)
        assertEquals(0, b.dist)
        assertFalse(TestWaitSim.over(w, t(599.0)))
        assertTrue(TestWaitSim.over(w, t(600.0)))
        assertEquals(WaitFor.Phase.OFF, TestWaitSim.body(w, t(600.0)).phase)
    }

    // MARK: never in your backup

    @Test fun vaultScrub() {
        val sam = FriendIdentity(seed(0x00))
        val lou = FriendIdentity(seed(0x10))
        val bot = FriendIdentity(seed(0x40))
        val book = FriendBook(myName = "Sam", friends = listOf(Friend(lou.card, "Lou", t0), Friend(bot.card, "Test friend", t0)),
            incoming = listOf(FriendRequest(bot.card, "Test friend", t0)))
        val roster = GroupRoster("Crew", sam.account, 1, listOf(GroupMember(sam.card, "Sam"), GroupMember(bot.card, "Test friend")))
        val c = FriendVaultContents(book = book, groups = listOf(FriendGroup("g1", roster, t0)),
            timetable = TimetableSettings(off = listOf(bot.account, lou.account)), extras = ExtrasSettings(buddy = listOf(bot.account)))
        val v = TestFriendBrain.scrub(c, bot.account)
        assertEquals(listOf(lou.account), v.book.friends.map { it.id })
        assertTrue(v.book.incoming.isEmpty())
        assertEquals(listOf(sam.account), v.groups?.first()?.roster?.members?.map { it.id })
        assertEquals(listOf(lou.account), v.timetable?.off)
        assertNull(v.extras?.buddy)
        val plain = FriendJson.encodeString(FriendVaultContents.serializer(), v)
        assertFalse(plain.contains(bot.account))
        assertFalse(plain.contains(B64u.encode(bot.card.signKey)))
        // nothing to take out: the same
        assertEquals(v, TestFriendBrain.scrub(v, bot.account))
    }
}
