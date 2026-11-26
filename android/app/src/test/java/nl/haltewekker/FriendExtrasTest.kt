package nl.haltewekker

import nl.haltewekker.auto.AutoRules
import nl.haltewekker.auto.RegionSpec
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.friends.B64u
import nl.haltewekker.friends.BuddyPlan
import nl.haltewekker.friends.BuddyRules
import nl.haltewekker.friends.BuddyWords
import nl.haltewekker.friends.CampusPosted
import nl.haltewekker.friends.CampusRules
import nl.haltewekker.friends.CampusSeen
import nl.haltewekker.friends.CampusState
import nl.haltewekker.friends.CampusWords
import nl.haltewekker.friends.ChatBook
import nl.haltewekker.friends.ChatText
import nl.haltewekker.friends.DelayAlarm
import nl.haltewekker.friends.DelayStop
import nl.haltewekker.friends.DelayTold
import nl.haltewekker.friends.DelayWords
import nl.haltewekker.friends.Friend
import nl.haltewekker.friends.FriendBook
import nl.haltewekker.friends.FriendBox
import nl.haltewekker.friends.FriendIdentity
import nl.haltewekker.friends.FriendInbox
import nl.haltewekker.friends.FriendMessage
import nl.haltewekker.friends.PersonWays
import nl.haltewekker.friends.RelayBox
import nl.haltewekker.friends.RideDelay
import nl.haltewekker.friends.TimetableDays
import nl.haltewekker.friends.TravelFreshness
import nl.haltewekker.friends.TravelState
import nl.haltewekker.friends.TripAnswer
import nl.haltewekker.friends.TripCard
import nl.haltewekker.friends.WaitAge
import nl.haltewekker.friends.WaitAnswer
import nl.haltewekker.friends.WaitFor
import nl.haltewekker.friends.WaitNext
import nl.haltewekker.friends.WaitRules
import nl.haltewekker.friends.WaitSeen
import nl.haltewekker.friends.WaitWords
import nl.haltewekker.friends.Way
import nl.haltewekker.friends.WayLeg
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Friends 0.29 (the extras) as plain rules: the iOS `FriendExtrasTests`, number for number. */
class FriendExtrasTest {
    private val t0 = 1_800_000_000.0          // Friday 15 January 2027, 09:00 in Amsterdam
    private val ehv = TripCard.Spot("Eindhoven Centraal", lat = 51.44306, lon = 5.47917)
    private val bd = TripCard.Spot("Breda", lat = 51.59556, lon = 4.78)
    private val tb = TripCard.Spot("Tilburg", lat = 51.56056, lon = 5.08333)

    private fun t(s: Double) = t0 + s
    private fun t(s: Int) = t0 + s

    private fun ride(trip: String, line: String = "IC", num: String? = "3512", from: TripCard.Spot? = null, to: TripCard.Spot? = null,
                     dep: Int, arr: Int, bus: Boolean = false) =
        TripCard.Ride(mode = if (bus) "bus" else "train", line = line, num = num, trip = trip, from = from ?: ehv, to = to ?: bd, dep = t(dep), arr = t(arr))

    private fun wait(state: String = "coming", dist: Int? = 300, eta: Int? = 120, at: Int = 0, ride: TripCard.Ride? = null) =
        WaitFor("w1", state, ehv, ride, dist, eta?.let { t(it) }, t(at))

    // MARK: wait for me

    @Test fun waitIds() {
        assertTrue(WaitRules.validId("vector-wait-1"))
        assertTrue(WaitRules.validId("Ab_9-"))
        assertFalse(WaitRules.validId(""))
        assertFalse(WaitRules.validId("a".repeat(33)))
        assertFalse(WaitRules.validId("no spaces"))
        assertFalse(WaitRules.validId("slash/"))
    }

    @Test fun waitValid() {
        assertNotNull(WaitFor.valid(wait()))
        assertNull(WaitFor.valid(wait().copy(id = "bad id")))
        assertNull("a stop without a place", WaitFor.valid(wait().copy(stop = TripCard.Spot("Somewhere"))))
        assertNull(WaitFor.valid(wait(dist = -5))?.dist)
        assertNull("a ride without a trip id goes", WaitFor.valid(wait(ride = ride("", dep = 600, arr = 3600)))?.ride)
        assertEquals("an unknown state reads as coming", WaitFor.Phase.COMING, wait("later").phase)
    }

    @Test fun waitPhase() {
        assertEquals(WaitFor.Phase.COMING, WaitRules.phase(300.0, t0, t(600), t(60)))
        assertEquals(WaitFor.Phase.THERE, WaitRules.phase(35.0, t0, t(600), t(60)))
        assertEquals(WaitFor.Phase.COMING, WaitRules.phase(null, t0, null, t(60)))
        assertNull("over after 30 minutes", WaitRules.phase(300.0, t0, null, t(31 * 60)))
        assertNull("over 2 minutes after the ride left", WaitRules.phase(300.0, t0, t(600), t(600 + 121)))
        assertEquals(WaitFor.Phase.COMING, WaitRules.phase(300.0, t0, t(600), t(600 + 119)))
    }

    @Test fun waitEta() {
        assertEquals(t(6 * 60), WaitRules.eta(300.0, t0), 0.0)
        assertEquals(t0, WaitRules.eta(30.0, t0), 0.0)
        assertEquals(t(60), WaitRules.eta(41.0, t0), 0.0)
    }

    @Test fun waitDue() {
        val a = wait(dist = 300)
        assertTrue(WaitRules.due(null, null, a, t0))
        assertTrue("a new phase goes at once", WaitRules.due(a, t0, wait("there", dist = 20), t(5)))
        assertFalse("not within 20 s", WaitRules.due(a, t0, wait(dist = 200), t(10)))
        assertTrue("moved 30 m", WaitRules.due(a, t0, wait(dist = 270), t(30)))
        assertFalse("moved 10 m", WaitRules.due(a, t0, wait(dist = 290), t(30)))
        assertTrue("there a minute later", WaitRules.due(a, t0, wait(dist = 300, eta = 200), t(30)))
        assertTrue("again after a minute", WaitRules.due(a, t0, a, t(60)))
    }

    @Test fun waitWords() {
        assertEquals("Sam is 2 min from the stop (300 m)", WaitWords.line("Sam", wait(dist = 300, eta = 120), t0))
        assertEquals("Sam is 1 min from the stop (80 m)", WaitWords.line("Sam", wait(dist = 80, eta = 30), t0))
        assertEquals("Sam is under a minute from the stop (80 m)", WaitWords.line("Sam", wait(dist = 80, eta = 0), t0))
        assertEquals("Sam is 300 m from the stop", WaitWords.line("Sam", wait(dist = 300, eta = null), t0))
        assertEquals("Sam is on the way to the stop", WaitWords.line("Sam", wait(dist = null, eta = null), t0))
        assertEquals("Sam is at the stop", WaitWords.line("Sam", wait("there", dist = 10), t0))
        assertEquals("300 m", WaitWords.metres(295))
        assertEquals("1.2 km", WaitWords.metres(1234))
        val r = ride("ic-3512", dep = 60, arr = 3000)
        assertEquals("At Eindhoven Centraal · for the IC 3512 at 09:01 · it leaves before Sam gets there", WaitWords.detail("Sam", wait(eta = 120, ride = r)))
        assertEquals("At Eindhoven Centraal · for the IC 3512 at 09:01", WaitWords.detail("Sam", wait(eta = 30, ride = r)))
        assertEquals("Asked Lisa to wait · you’re 300 m from the stop", WaitWords.mine("Lisa", wait(dist = 300)))
        assertEquals("Asked Lisa to wait · you’re at the stop", WaitWords.mine("Lisa", wait("there", dist = 5)))
        assertEquals("I’ll wait", WaitAnswer.WAIT.text)
        assertEquals(WaitAnswer.NEXT, WaitAnswer.of("next"))
    }

    @Test fun waitAge() {
        val s = WaitSeen("sam", "sam", wait(at = 0), 1_800_000_000, t0)
        assertEquals(TravelFreshness.FRESH, WaitAge.freshness(s, t(60)))
        assertEquals(TravelFreshness.STALE, WaitAge.freshness(s, t(120)))
        assertEquals(TravelFreshness.GONE, WaitAge.freshness(s, t(16 * 60)))
        assertEquals(TravelFreshness.GONE, WaitAge.freshness(s.copy(wait = s.wait.copy(state = "off")), t(10)))
        val left = s.copy(wait = s.wait.copy(ride = ride("ic", dep = 0, arr = 3000)))
        assertEquals(TravelFreshness.STALE, WaitAge.freshness(left, t(4 * 60)))
        assertEquals("its ride left 5 minutes ago", TravelFreshness.GONE, WaitAge.freshness(left, t(6 * 60)))
    }

    @Test fun waitNext() {
        val far = TripCard.Spot("Elsewhere", lat = 51.50, lon = 5.40)
        fun way(trip: String, line: String, from: TripCard.Spot, dep: Int): Way {
            val l = WayLeg(trip, "train", line, from = from, to = bd, dep = t(dep), arr = t(dep + 3000))
            return Way(listOf(l), t(dep - 120), t(dep + 3000))
        }
        val ways = listOf(way("missed", "IC", ehv, 300), way("spr", "SPR", ehv, 600), way("ic-next", "IC", ehv, 1200), way("far", "IC", far, 400))
        val stop = GeoPoint(51.44306, 5.47917)
        assertEquals("ic-next", WaitNext.pick(ways, stop, t(200), "missed", "IC")?.legs?.first()?.trip)
        assertEquals("spr", WaitNext.pick(ways, stop, t(200), "missed", null)?.legs?.first()?.trip)
        assertEquals("missed", WaitNext.pick(ways, stop, t(200), null, "IC")?.legs?.first()?.trip)
        assertNull(WaitNext.pick(ways, stop, t(1300), null, null))
    }

    // MARK: the delay alarm

    @Test fun shouldTell() {
        assertFalse(DelayAlarm.shouldTell(2, false, null))
        assertTrue(DelayAlarm.shouldTell(3, false, null))
        val told = DelayTold(4, false, t0)
        assertFalse(DelayAlarm.shouldTell(5, false, told))
        assertTrue(DelayAlarm.shouldTell(6, false, told))
        assertTrue(DelayAlarm.shouldTell(0, true, told))
        assertFalse(DelayAlarm.shouldTell(0, true, DelayTold(0, true, t0)))
        assertFalse("back on time isn't an alarm", DelayAlarm.shouldTell(1, false, told))
    }

    @Test fun watchedAndLookDue() {
        assertTrue(DelayAlarm.watched(ride("a", dep = 3600, arr = 7200), t0))
        assertFalse("more than 90 minutes ahead", DelayAlarm.watched(ride("a", dep = 100 * 60, arr = 9000), t0))
        assertTrue("on it", DelayAlarm.watched(ride("a", dep = -600, arr = 600), t0))
        assertFalse("in already", DelayAlarm.watched(ride("a", dep = -1200, arr = -60), t0))
        assertTrue(DelayAlarm.lookDue(null, t0))
        assertFalse(DelayAlarm.lookDue(t0, t(100)))
        assertTrue(DelayAlarm.lookDue(t0, t(120)))
    }

    private fun stop(s: TripCard.Spot, dep: Int?, sched: Int?, cancelled: Boolean = false) =
        DelayStop(s.name, s.point!!, dep?.let { t(it) }, sched?.let { t(it) }, cancelled)

    @Test fun delayRead() {
        val stops = listOf(stop(ehv, 360, 0), stop(tb, 1800, 1320), stop(bd, null, null))
        val a = DelayAlarm.read(stops, ehv, t0)!!
        assertEquals(6, a.late); assertFalse(a.cancelled); assertEquals(t(360), a.dep!!, 0.0)
        assertEquals("past your stop: at its next stop", 8, DelayAlarm.read(stops, ehv, t(600))!!.late)
        assertEquals("by name", 8, DelayAlarm.read(stops, TripCard.Spot("Tilburg"), t0)!!.late)
        val d = listOf(stop(ehv, 0, 0, true), stop(bd, 3000, 3000))
        assertEquals(true, DelayAlarm.read(d, ehv, t0)?.cancelled)
        val e = listOf(stop(ehv, 0, 0, true), stop(bd, 3000, 3000, true))
        assertEquals(true, DelayAlarm.read(e, TripCard.Spot("Nowhere"), t0)?.cancelled)
        assertNull(DelayAlarm.read(stops, TripCard.Spot("Nowhere"), t0))
        assertNull(DelayAlarm.read(emptyList(), ehv, t0))
    }

    @Test fun nextTogether() {
        fun way(vararg legs: Triple<String, TripCard.Spot, Int>): Way {
            val l = legs.map { WayLeg(it.first, "train", "IC", from = it.second, to = bd, dep = t(it.third), arr = t(it.third + 2400)) }
            return Way(l, t(legs[0].third - 60), t(legs[0].third + 2400))
        }
        val me = PersonWays("me", listOf(way(Triple("bad", ehv, 360)), way(Triple("ic-3516", ehv, 1800)), way(Triple("ic-3520", ehv, 3600))), t(60))
        val lisa = PersonWays("lisa", listOf(way(Triple("bad", ehv, 360)), way(Triple("ic-3516", ehv, 1800)), way(Triple("ic-3520", ehv, 3600))), t(60))
        val sam = PersonWays("sam", listOf(way(Triple("bad", tb, 1500)), way(Triple("ic-3520", tb, 4900))), t(60))
        assertEquals("ic-3520", DelayAlarm.next(listOf(me, lisa, sam), "bad", t(120))?.trip)
        assertEquals("ic-3516", DelayAlarm.next(listOf(me, lisa), "bad", t(120))?.trip)
        assertEquals(2, DelayAlarm.next(listOf(me, lisa), "bad", t(120))?.riders?.size)
        assertNull(DelayAlarm.next(listOf(me), "bad", t(120)))
    }

    @Test fun sharedRides() {
        val mine = listOf(ride("ic-3512", dep = 600, arr = 3600))
        val lisa = TravelState("waiting", "train", trip = "ic-3512", from = TravelState.Spot("Eindhoven Centraal", 51.44306, 5.47917), to = TravelState.Spot("Breda"))
        val other = lisa.copy(trip = "elsewhere")
        val card = TripCard(listOf(ride("b305", "305", null, dep = 300, arr = 500, bus = true), ride("ic-3512", from = tb, dep = 1500, arr = 3600)), bd)
        val refs = DelayAlarm.shared(mine, listOf("lisa" to lisa, "tom" to other), listOf(card to listOf("sam", "lisa")), "me", t0)
        assertEquals(1, refs.size)
        assertEquals("ic-3512", refs.first().ride.trip)
        assertEquals("your own ride when your trip has it", "Eindhoven Centraal", refs.first().ride.from.name)
        assertEquals(listOf("lisa", "sam"), refs.first().riders)
        assertEquals("Tilburg", refs.first().spots["sam"]?.first()?.name)
        val only = DelayAlarm.shared(emptyList(), emptyList(), listOf(card to listOf("sam")), "me", t0)
        assertEquals("Tilburg", only.first().ride.from.name)
        assertTrue(DelayAlarm.shared(mine, emptyList(), emptyList(), "me", t0).isEmpty())
    }

    @Test fun cardRiders() {
        assertEquals(listOf("lisa"), DelayAlarm.riders("me", mapOf("lisa" to TripAnswer.YES, "tom" to TripAnswer.NO), "me"))
        assertEquals(listOf("sam", "lisa"), DelayAlarm.riders("sam", mapOf("me" to TripAnswer.YES, "lisa" to TripAnswer.YES), "me"))
        assertNull("you're not in", DelayAlarm.riders("sam", mapOf("me" to TripAnswer.NO), "me"))
        assertNull(DelayAlarm.riders("sam", emptyMap(), "me"))
    }

    @Test fun delayWords() {
        val d = RideDelay(ride("ic-3512", dep = 360, arr = 3600), 6, next = ride("ic-3516", num = "3516", dep = 1800, arr = 4800))
        assertEquals("IC 3512 is 6 min late", DelayWords.title(d))
        assertEquals("You, Lisa and Sam are on it. It now leaves Eindhoven Centraal at 09:06. Next you can all take: IC 3516 at 09:30 from Eindhoven Centraal.",
            DelayWords.body(d, listOf("you", "Lisa", "Sam")))
        val c = RideDelay(ride("b305", "305", null, dep = 0, arr = 600, bus = true), 0, cancelled = true)
        assertEquals("Bus 305 is cancelled", DelayWords.title(c))
        assertEquals("Lisa is on it. Look for another way in Fastest trip.", DelayWords.body(c, listOf("Lisa")))
        assertEquals(20, RideDelay.valid(c.copy(who = List(30) { "x" }))?.who?.size)
        assertNull(RideDelay.valid(RideDelay(ride("", dep = 0, arr = 60), 4)))
    }

    // MARK: the wake-up buddy

    @Test fun buddyPlan() {
        val today = TimetableDays.key(t0)
        assertEquals("2027-01-15", today)
        val r = ride("ic-3512", dep = -4740, arr = -1680)
        val b = BuddyPlan(true, today, t(-6000), r)
        val p = BuddyRules.plan(b, emptyList(), today)!!
        assertEquals(t(-6000), p.leave, 0.0)
        assertEquals("ic-3512", p.ride?.trip)
        assertNull(BuddyRules.plan(BuddyPlan(true, "2027-01-14", t(-90000)), emptyList(), today))
        assertNull(BuddyRules.plan(BuddyPlan(false, today, t(-6000)), emptyList(), today))
        val card = TripCard(listOf(ride("ic-3512", dep = 1200, arr = 4000)), bd, start = t(600))
        assertEquals(t(600), BuddyRules.plan(null, listOf(card to true), today)!!.leave, 0.0)
        assertEquals(t(300), BuddyRules.plan(null, listOf(card to false), today)!!.leave, 0.0)
        assertEquals(t(-6000), BuddyRules.plan(b, listOf(card to true), today)!!.leave, 0.0)
    }

    @Test fun buddyAlert() {
        val today = TimetableDays.key(t0)
        val leave = t(0)
        val r = ride("ic", dep = 1260, arr = 4000)
        assertFalse("within 5 minutes", BuddyRules.alert(leave, r, false, null, today, t(4 * 60)))
        assertTrue(BuddyRules.alert(leave, r, false, null, today, t(5 * 60)))
        assertTrue(BuddyRules.alert(leave, r, false, null, today, t(1260 + 600)))
        assertFalse("too late to matter", BuddyRules.alert(leave, r, false, null, today, t(1260 + 601)))
        assertFalse(BuddyRules.alert(leave, r, true, null, today, t(600)))
        assertFalse("once a morning", BuddyRules.alert(leave, r, false, today, today, t(600)))
        assertTrue(BuddyRules.alert(leave, r, false, "2027-01-14", today, t(600)))
        assertFalse("another day's plan", BuddyRules.alert(t(-86400), null, false, null, today, t(600)))
        assertTrue(BuddyRules.alert(leave, null, false, null, today, t(900)))
        assertFalse(BuddyRules.alert(leave, null, false, null, today, t(901)))
    }

    @Test fun buddyMovingAndDue() {
        assertTrue(BuddyRules.moving(t(-600), emptyList(), t0))
        assertFalse("yesterday's leaving doesn't count", BuddyRules.moving(t(-4000), emptyList(), t0))
        assertTrue("a trip of theirs came", BuddyRules.moving(null, listOf(t(-60)), t0))
        assertFalse(BuddyRules.moving(null, emptyList(), t0))
        val p = BuddyPlan(true, "2027-01-15", t0)
        assertTrue(BuddyRules.due(null, null, p, t0))
        assertFalse(BuddyRules.due(p, t0, p, t(3600)))
        assertTrue(BuddyRules.due(p, t0, p, t(12 * 3600)))
        assertTrue("leaving goes at once", BuddyRules.due(p, t0, p.copy(left = t(60)), t(120)))
    }

    @Test fun buddyWords() {
        val r = ride("ic", dep = -4740, arr = -1680)
        assertEquals("Lisa isn’t moving yet — their train is at 07:41", BuddyWords.title("Lisa", t(-6000), r))
        assertEquals("Lisa isn’t moving yet — they planned to leave at 07:20", BuddyWords.title("Lisa", t(-6000), null))
        assertEquals("Lisa planned to leave at 07:20 for the IC 3512 from Eindhoven Centraal. Maybe send a message?", BuddyWords.body("Lisa", t(-6000), r))
    }

    // MARK: who's on campus

    @Test fun campusInside() {
        assertEquals(true, CampusRules.inside(300.0, 350.0, false))
        assertEquals("at the edge: as it was", true, CampusRules.inside(450.0, 350.0, true))
        assertEquals(false, CampusRules.inside(450.0, 350.0, false))
        assertEquals(false, CampusRules.inside(501.0, 350.0, true))
        assertNull(CampusRules.inside(null, 350.0, true))
    }

    @Test fun campusDecide() {
        val friends = listOf("lisa", "tom")
        assertEquals(CampusRules.Action.Post(t0, friends), CampusRules.decide(true, true, t0, null, friends, t(60)))
        assertEquals("off by default", CampusRules.Action.None, CampusRules.decide(false, true, t0, null, friends, t(60)))
        assertEquals(CampusRules.Action.None, CampusRules.decide(true, false, null, null, friends, t(60)))
        assertEquals(CampusRules.Action.None, CampusRules.decide(true, null, null, null, friends, t(60)))
        val p = CampusPosted(t0, CampusRules.until(t0), listOf("lisa"))
        assertEquals("a new friend gets it too", CampusRules.Action.Post(t0, listOf("tom")), CampusRules.decide(true, true, t0, p, friends, t(60)))
        assertEquals("not known: as it was", CampusRules.Action.None, CampusRules.decide(true, null, t0, p, listOf("lisa"), t(60)))
        assertEquals(CampusRules.Action.Clear(listOf("lisa")), CampusRules.decide(true, false, null, p, friends, t(60)))
        assertEquals(CampusRules.Action.Clear(listOf("lisa")), CampusRules.decide(false, true, t0, p, friends, t(60)))
        assertEquals("after 10 hours", CampusRules.Action.Clear(listOf("lisa")), CampusRules.decide(true, true, t0, p, friends, t(10 * 3600)))
        assertEquals("not again until you've left", CampusRules.Action.None, CampusRules.decide(true, true, t0, null, friends, t(10 * 3600 + 60)))
    }

    @Test fun campusSeen() {
        val s = CampusState(true, "BUas", t(-3300), CampusRules.until(t(-3300)))
        val seen = CampusSeen(s, 1_800_000_000, t0)
        assertTrue(CampusRules.here(seen, t0))
        assertFalse(CampusRules.here(seen, t(10 * 3600)))
        assertFalse(CampusRules.here(CampusSeen(CampusState(false), 1_800_000_000, t0), t0))
        assertFalse("a stay over 10 hours isn't taken", CampusRules.here(CampusSeen(CampusState(true, since = t(-60), until = t(20 * 3600)), 1_800_000_000, t0), t0))
        assertEquals("At BUas since 08:05", CampusWords.since(s))
        assertEquals("At school", CampusWords.since(CampusState(true)))
        assertEquals("On campus now: Tom and Lisa", CampusWords.list(listOf("Tom", "Lisa")))
        assertEquals(3600, CampusRules.ttl(t(3600), t0))
        assertEquals(60, CampusRules.ttl(t(10), t0))
        assertEquals(36000, CampusRules.ttl(t(20 * 3600), t0))
    }

    @Test fun campusRegion() {
        val school = GeoPoint(51.5866, 4.7745)
        val base = listOf(RegionSpec("school", 51.5866, 4.7745, 350.0, entry = true, exit = false), RegionSpec("home.0", 51.6, 5.5, 350.0, entry = false, exit = true))
        val w = AutoRules.withCampus(base, school, 350.0)
        assertEquals(2, w.size)
        assertEquals(true, w.first { it.id == "school" }.exit)
        assertEquals(true, w.first { it.id == "school" }.entry)
        assertEquals(base.last(), w.last())
        assertFalse("only 'at school' asked for School's exit", AutoRules.exitStartsTrip("school", base))
        assertTrue(AutoRules.exitStartsTrip("home.0", base))
        assertEquals(listOf(RegionSpec("school", 51.5866, 4.7745, 350.0, entry = true, exit = true)), AutoRules.withCampus(emptyList(), school, 350.0))
    }

    // MARK: reading them

    @Test fun inboxReadsTheExtras() {
        val sam = FriendIdentity.random()
        val lou = FriendIdentity.random()
        val stranger = FriendIdentity.random()
        val book = FriendBook.named("Lou")
        book.friends = listOf(Friend(sam.card, "Sam", t0))
        fun box(id: Long, m: FriendMessage, from: FriendIdentity, at: Double) =
            RelayBox(id, from.account, null, at.toLong(), 0, B64u.encode(FriendBox.seal(m, from, lou.card, at.toLong())))
        val w = wait()
        val older = WaitFor("w1", "coming", ehv, dist = 500, at = t(-60))
        val answer = ChatText("I’ll wait", "w9", "wait")
        val r = FriendInbox.process(listOf(
            box(1, FriendMessage.Wait(w), sam, t0),
            box(2, FriendMessage.Wait(older), sam, t(-60)),
            box(3, FriendMessage.Campus(CampusState(true, "BUas", t0, t(3600))), sam, t0),
            box(4, FriendMessage.Buddy(BuddyPlan(true)), sam, t0),
            box(5, FriendMessage.Delay(RideDelay(ride("ic", dep = 0, arr = 600), 4)), sam, t0),
            box(6, FriendMessage.Wait(w), stranger, t0),
            box(7, FriendMessage.Message(answer), sam, t0),
        ), book, me = lou, now = t0)
        assertEquals("the newest by their time", 300, r.waits[sam.account]?.wait?.dist)
        assertEquals(sam.account, r.waits[sam.account]?.chat)
        assertNull("only from a friend", r.waits[stranger.account])
        assertEquals("BUas", r.campus[sam.account]?.state?.school)
        assertEquals(true, r.buddies[sam.account]?.plan?.on)
        assertEquals(4, r.delays.first().delay.late)
        assertEquals(setOf(1L, 2L, 3L, 4L, 5L, 6L, 7L), r.ack.toSet())
        val m = r.chat.first().line!!
        val text = m.text!!
        assertEquals("a wait's answer keeps what it answers", "wait", text.answer)
        assertEquals("w9", text.re)
        val chats = ChatBook().add(m, sam.account)!!
        assertEquals(mapOf(sam.account to WaitAnswer.WAIT), chats.waitAnswers("w9", sam.account))
        assertTrue("not a trip card's answer", chats.answers("w9", sam.account).isEmpty())
    }
}
