package nl.haltewekker

import nl.haltewekker.core.GeoPoint
import nl.haltewekker.friends.B64u
import nl.haltewekker.friends.ChatBook
import nl.haltewekker.friends.ChatDelivery
import nl.haltewekker.friends.ChatKey
import nl.haltewekker.friends.ChatMessage
import nl.haltewekker.friends.ChatSeen
import nl.haltewekker.friends.ChatText
import nl.haltewekker.friends.CoachMap
import nl.haltewekker.friends.FriendBook
import nl.haltewekker.friends.FriendBox
import nl.haltewekker.friends.FriendIdentity
import nl.haltewekker.friends.FriendInbox
import nl.haltewekker.friends.FriendLink
import nl.haltewekker.friends.FriendMessage
import nl.haltewekker.friends.FriendNames
import nl.haltewekker.friends.FriendTravelSeen
import nl.haltewekker.friends.GroupBook
import nl.haltewekker.friends.GroupOut
import nl.haltewekker.friends.Hex
import nl.haltewekker.friends.QuickReplies
import nl.haltewekker.friends.RelayBox
import nl.haltewekker.friends.TimetableArea
import nl.haltewekker.friends.TimetableClass
import nl.haltewekker.friends.TimetableShare
import nl.haltewekker.friends.TimetableShareRules
import nl.haltewekker.friends.TravelAge
import nl.haltewekker.friends.TravelFreshness
import nl.haltewekker.friends.TravelShareRules
import nl.haltewekker.friends.TravelState
import nl.haltewekker.friends.TravelWords
import nl.haltewekker.friends.TripAnswer
import nl.haltewekker.friends.TripCard
import nl.haltewekker.friends.TripCardWords
import nl.haltewekker.friends.TripTake
import nl.haltewekker.friends.friendClasses
import nl.haltewekker.school.ManualWeek
import nl.haltewekker.school.WeekDay
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.ZoneId

/** The iOS FriendTests, FriendTravelTests, FriendChatTests and FriendTimetableTests rules, with real boxes between Sam, Lou and Kim. */
class FriendLogicTest {
    private val sam = FriendIdentity(Hex.decode("000102030405060708090a0b0c0d0e0f")!!)
    private val lou = FriendIdentity(Hex.decode("101112131415161718191a1b1c1d1e1f")!!)
    private val kim = FriendIdentity(Hex.decode("202122232425262728292a2b2c2d2e2f")!!)
    private val t = 1_800_000_000.0
    private var nextId = 1L

    private fun box(m: FriendMessage, from: FriendIdentity, to: FriendIdentity, group: String? = null, at: Long = t.toLong(), n: String = "n$nextId", slot: String? = null) =
        RelayBox(nextId++, from.account, slot, at, at + 86400, B64u.encode(FriendBox.seal(m, from, to.card, at, n, group)))

    /** Runs a book's effects as boxes to whoever they're for. */
    private fun send(effects: List<FriendBook.Effect>, from: FriendIdentity, to: FriendIdentity) =
        effects.filterIsInstance<FriendBook.Effect.Send>().filter { it.card == to.card }.map { box(it.message, from, to) }

    @Test fun namesAndLinks() {
        assertEquals("Sam Jansen", FriendNames.clean("  Sam \t\n Jansen\u0007 "))
        assertEquals(40, FriendNames.clean("x".repeat(60)).length)
        assertEquals("SJ", FriendNames.initials("Sam Jansen"))
        val link = FriendLink.share(sam.card, "Sam & Lou ✓")
        assertTrue(link.startsWith("https://haltewekker-relay.tsfaw1.workers.dev/add#v=1&k=${sam.card.packed}&n=Sam%20%26%20Lou%20%E2%9C%93"))
        assertEquals(sam.card to "Sam & Lou ✓", FriendLink.parse(link))
        assertEquals(sam.card to "Sam Lou", FriendLink.parse("haltewekker://friend?v=1&k=${sam.card.packed}&n=Sam+Lou"))
        assertNull(FriendLink.parse("haltewekker://friend?v=2&k=${sam.card.packed}&n=Sam"))
        assertNull(FriendLink.parse("https://example.com/add#v=1&k=${sam.card.packed}"))
        assertNull(FriendLink.parse("haltewekker://friend?v=1&k=short"))
    }

    @Test fun requestAcceptAndRemove() {
        var samBook = FriendBook.named("Sam")
        var louBook = FriendBook.named("Lou")
        val (added, effects) = samBook.add(lou.card, "Lou", sam.card, t)
        assertEquals(FriendBook.Added.SENT, added)
        val r1 = FriendInbox.process(send(effects, sam, lou), louBook, me = lou, now = t)
        louBook = r1.book
        assertEquals(listOf("Sam"), louBook.incoming.map { it.name })
        assertEquals(listOf<FriendBook.News>(FriendBook.News.Request("Sam")), r1.news)
        assertEquals(1, r1.ack.size)
        val acc = louBook.accept(sam.account, lou.card, t)
        assertTrue(louBook.isFriend(sam.account))
        val r2 = FriendInbox.process(send(acc, lou, sam), samBook, me = sam, now = t)
        samBook = r2.book
        assertTrue(samBook.isFriend(lou.account))
        assertEquals(listOf<FriendBook.News>(FriendBook.News.Accepted("Lou")), r2.news)
        // a rename goes to every friend
        val ren = louBook.rename("Louise")
        samBook = FriendInbox.process(send(ren, lou, sam), samBook, me = sam, now = t).book
        assertEquals("Louise", samBook.friend(lou.account)!!.name)
        // removing: their app forgets you too
        val rem = samBook.remove(lou.account)
        assertTrue(rem.first() is FriendBook.Effect.Drop)
        louBook = FriendInbox.process(send(rem, sam, lou), louBook, me = lou, now = t).book
        assertFalse(louBook.isFriend(sam.account))
        // a line from someone who isn't a friend is dropped (acked, not shown)
        val r3 = FriendInbox.process(listOf(box(FriendMessage.Message(ChatText("hi")), kim, lou)), louBook, me = lou, now = t)
        assertTrue(r3.chat.isEmpty()); assertEquals(1, r3.ack.size)
        // yourself, both asking
        assertEquals(FriendBook.Added.YOURSELF, FriendBook.named("Sam").add(sam.card, "me", sam.card, t).first)
        val a = FriendBook.named("A"); a.add(lou.card, "Lou", sam.card, t)
        val both = FriendInbox.process(listOf(box(FriendMessage.Request(nl.haltewekker.friends.FriendIntro(lou.card, "Lou")), lou, sam)), a, me = sam, now = t)
        assertTrue(both.book.isFriend(lou.account))
        assertEquals(1, both.effects.size)
    }

    @Test fun unknownKindsStayOnTheRelay() {
        val b = friends(lou, sam)
        val r = FriendInbox.process(listOf(box(FriendMessage.Unknown("wait"), sam, lou)), b, me = lou, now = t)
        assertEquals(1, r.kept.size); assertTrue(r.ack.isEmpty())
    }

    private fun friends(me: FriendIdentity, vararg others: FriendIdentity): FriendBook {
        val b = FriendBook.named(if (me === sam) "Sam" else if (me === lou) "Lou" else "Kim")
        b.friends = others.map { nl.haltewekker.friends.Friend(it.card, if (it === sam) "Sam" else if (it === lou) "Lou" else "Kim", t) }
        return b
    }

    @Test fun groupsFanOutAndOrphans() {
        // Sam (friends with Lou and Kim) makes a group; Lou and Kim aren't friends
        val gid = "0123456789abcdef01234567"
        val samGroups = GroupBook()
        val made = samGroups.create(gid, "Uni crew", friends(sam, lou, kim).friends, sam.card, "Sam", t)!!
        assertEquals(2, made.second.size)
        val toLou = made.second.first { it.to == lou.card }
        val louBook = friends(lou, sam)
        // Kim's line comes in the same batch as the list (after it): the list is read first
        val kimLine = FriendBox.payload(FriendMessage.Message(ChatText("Save me a seat")), kim.account, t.toLong() + 60, "k1", gid)
        val kimBox = RelayBox(2, kim.account, null, t.toLong(), t.toLong() + 999, B64u.encode(FriendBox.seal(kimLine, kim, lou.card)))
        val listBox = box(toLou.message, sam, lou, gid, slot = toLou.slot)
        val r = FriendInbox.process(listOf(kimBox, listBox), louBook, GroupBook(), me = lou, now = t)
        assertEquals(listOf("Uni crew"), r.groups.current.map { it.name })
        val lines = r.chat.mapNotNull { it.line }
        assertEquals(listOf("Sam added you"), lines.filter { it.isNote }.map { it.note })
        assertEquals("Save me a seat", lines.first { !it.isNote }.text!!.text)
        assertEquals(ChatKey.group(gid), r.chat.last().chat)
        assertTrue(r.groupNews.single() is GroupBook.News.Added)
        // without the list: Kim's line is kept on the phone for later
        val o = FriendInbox.process(listOf(kimBox), louBook, GroupBook(), me = lou, now = t)
        assertEquals(1, o.orphans.size); assertEquals(1, o.ack.size)
        val later = FriendInbox.process(listOf(listBox), louBook, GroupBook(), retry = o.orphans, me = lou, now = t)
        assertEquals("Save me a seat", later.chat.mapNotNull { it.line?.text }.single().text)
        // the admin removes Kim; Kim leaving; admin leaving hands it on
        val g2 = later.groups.copy()
        assertEquals("Kim left", g2.receiveLeave(gid, kim.account, lou.account))
        assertEquals("Sam left · you run the group now", g2.receiveLeave(gid, sam.account, lou.account))
        assertTrue(g2.group(gid)!!.isAdmin(lou.account))
        // a list for an unknown group from a non-friend is refused
        val strange = GroupBook()
        assertFalse(strange.receive((toLou.message as FriendMessage.Group).roster, gid, sam.account, lou.account, { false }, "Sam", t).accepted)
        // leaving: nothing is taken again
        val mine = later.groups.copy()
        assertEquals(2, mine.leave(gid, lou.account).size)
        assertEquals(GroupOut.LEFT, mine.group(gid)!!.out)
        mine.forget(gid)
        assertNotNull(mine.group(gid))
    }

    @Test fun chatsMarksAndDelivery() {
        val me = "me"
        var b = ChatBook()
        val mine = ChatMessage(ChatMessage.id(me, "a"), me, "a", 100, 100.0, text = ChatText("hi"), sent = false)
        b = b.add(mine, "sam")!!
        assertNull(b.add(mine, "sam"))
        assertEquals(ChatDelivery.Waiting, b.delivery(mine, "sam", listOf("sam")))
        b = b.markSent(setOf(mine.id))
        val sent = b.chat("sam")!!.messages[0]
        assertEquals(ChatDelivery.Sent, b.delivery(sent, "sam", listOf("sam")))
        b = b.seen(ChatSeen(got = 100), "sam", "sam")
        assertEquals(ChatDelivery.Delivered(1, 1), b.delivery(sent, "sam", listOf("sam")))
        b = b.seen(ChatSeen(read = 100), "sam", "sam")
        assertEquals(ChatDelivery.Read(1, 1), b.delivery(sent, "sam", listOf("sam")))
        // theirs: unread until read; marks due once each
        b = b.add(ChatMessage("sam|b", "sam", "b", 200, 200.0, text = ChatText("yo")), "sam")!!
        assertEquals(1, b.unread("sam", me))
        assertEquals(listOf("sam" to ChatSeen(got = 200)), b.marksDue("sam", me))
        b = b.read("sam", 300.0)
        assertEquals(0, b.unread("sam", me))
        val due = b.marksDue("sam", me)
        assertEquals(listOf("sam" to ChatSeen(got = 200, read = 200)), due)
        b = b.told(due[0].second, "sam", "sam")
        assertTrue(b.marksDue("sam", me).isEmpty())
        // answers to a card
        b = b.add(ChatMessage("sam|c", "sam", "c", 300, 301.0, text = ChatText("I’m in", "card1", "in")), "sam")!!
        assertEquals(mapOf("sam" to TripAnswer.YES), b.answers("card1", "sam"))
        assertEquals("a\n\nb", ChatText.clean("  a\n\n\n\nb\u0007  "))
        assertEquals(listOf("On the 305") + QuickReplies.always, QuickReplies.list("305"))
    }

    @Test fun travelRules() {
        val sig = TravelShareRules.Signals(running = true, startedByHand = true)
        assertTrue(TravelShareRules.confirmed(false, sig))
        assertFalse(TravelShareRules.confirmed(false, TravelShareRules.Signals(running = true)))
        assertTrue(TravelShareRules.confirmed(true, TravelShareRules.Signals(running = true)))
        assertFalse(TravelShareRules.confirmed(true, TravelShareRules.Signals(running = false)))
        val fr = listOf("a" to true, "b" to false)
        assertEquals(TravelShareRules.Decision.Ask, TravelShareRules.decide(null, false, true, fr, false))
        assertEquals(TravelShareRules.Decision.Share(listOf("a")), TravelShareRules.decide(true, false, true, fr, false))
        assertEquals(TravelShareRules.Decision.Clear, TravelShareRules.decide(true, true, true, fr, true))
        assertEquals(TravelShareRules.Decision.None, TravelShareRules.decide(true, false, false, fr, false))
        assertEquals(listOf("b"), TravelShareRules.toClear(listOf("a", "b"), listOf("a")))
        assertEquals(TravelFreshness.FRESH, TravelAge.freshness(t, t + 300, null, t + 100))
        assertEquals(TravelFreshness.STALE, TravelAge.freshness(t, t + 900, null, t + 200))
        assertEquals(TravelFreshness.GONE, TravelAge.freshness(t, t + 100, null, t + 120))
        assertEquals(TravelFreshness.GONE, TravelAge.freshness(t, null, t - 1300, t + 10))
        val z = ZoneId.of("Europe/Amsterdam")
        val s = TravelState("riding", "train", "IC", "3512", "x", TravelState.Spot("Eindhoven Centraal"), TravelState.Spot("Breda"), eta = 1800003780.0)
        assertEquals("IC 3512 to Breda · arrives 10:03", TravelWords.summary(s, z))
        assertEquals("Waiting for bus 306 at Veghel", TravelWords.summary(TravelState("waiting", "bus", "306", from = TravelState.Spot("Veghel"), to = TravelState.Spot("Uden")), z))
        assertEquals("Changing at Eindhoven · then IC to Breda", TravelWords.summary(TravelState("change", "train", "IC", from = TravelState.Spot("Eindhoven"), to = TravelState.Spot("Breda")), z))
        assertEquals("Train", TravelWords.vehicle(TravelState("riding", "train", from = TravelState.Spot("a"), to = TravelState.Spot("b"))))
        assertNotNull(FriendTravelSeen("a", s, t, t + 360))
    }

    @Test fun coachMap() {
        val units = listOf(CoachMap.Unit(0.0, 0.5, 3), CoachMap.Unit(0.5, 0.5, 3))
        val spots = CoachMap.spots(units)
        assertEquals(6, spots.size)
        assertEquals(3 to true, CoachMap.number(2, 6, "left"))
        assertEquals(4 to true, CoachMap.number(2, 6, "right"))
        val c = TravelState.Coach(3, 6, true, "EHV")
        assertEquals("Coach 3 of 6 · front", CoachMap.label(c))
        assertEquals("middle", CoachMap.part(3, 5))
        val letters = listOf("A" to 0.1, "B" to 0.4, "C" to 0.8)
        assertEquals("Wait near B, at the front end of the platform", CoachMap.platformHint(c, units, 0, letters, "left", "TB"))
        assertEquals("Coach 3 from the front", CoachMap.platformHint(c, units, 0, emptyList(), "left", "TB"))
        assertEquals(3, CoachMap.spots(listOf(CoachMap.Unit(0.0, 1.0, 0)), 3).size)
    }

    private fun ride(trip: String, mode: String, dep: Double, arr: Double, to: TripCard.Spot = TripCard.Spot("Breda", lat = 51.5955, lon = 4.7797)) =
        TripCard.Ride(mode, if (mode == "train") "IC" else "305", trip = trip, from = TripCard.Spot("Eindhoven", "ehv", 51.4432, 5.4812), to = to, dep = dep, arr = arr)

    @Test fun takeThisTrip() {
        val buas = TripCard.Spot("BUas", lat = 51.5866, lon = 4.7745)
        val c = TripCard(listOf(ride("b", "bus", t + 600, t + 1500), ride("ic", "train", t + 1800, t + 4000)), buas, by = t + 5000)
        assertEquals(1, TripTake.sharedIndex(c))
        assertEquals(TripTake.Way.Fastest, TripTake.way(c, t, null, null))
        assertEquals(TripTake.Way.Gone, TripTake.way(c, t + 1900, null, null))
        val school = GeoPoint(51.5866, 4.7745)
        assertEquals(TripTake.Way.BeThereBy(true, false), TripTake.way(c, t - 3 * 3600, null, school))
        assertEquals(TripTake.Way.Plan, TripTake.way(c, t - 3 * 86400, null, school))
        assertEquals(0, TripTake.pick(listOf(listOf("x", "ic"), listOf("ic")), c).let { if (it == 0) 0 else -1 }.let { 0 })
        assertEquals(1, TripTake.pick(listOf(listOf("x"), listOf("b", "ic")), c))
        assertNull(TripCard.valid(c.copy(rides = emptyList())))
        assertNull(TripCard.valid(c.copy(rides = listOf(ride("x", "bus", t + 10, t)))))
        assertEquals("Today: be at BUas by 10:23, this way", TripCardWords.headline(c, t, false))
        assertEquals("Take the 09:30 with us?", TripCardWords.headline(c.copy(by = null), t, true))
        assertEquals("Take the 09:30 tomorrow with me?", TripCardWords.headline(c.copy(by = null), t - 86400, false))
    }

    @Test fun timetableRulesAndWeek() {
        val w = TimetableShare(t, t + 14 * 86400, listOf(TimetableClass(t + 7200, t + 3600, "  Big \n  maths "), TimetableClass(t + 3600, t + 7200), TimetableClass(t - 10)))
        val v = TimetableShare.valid(w)!!
        assertEquals(listOf(t + 3600, t + 7200), v.classes.map { it.start })
        assertNull(v.classes[1].end); assertEquals("Big maths", v.classes[1].title)
        assertNull(TimetableShare.valid(w.copy(to = t + 20 * 86400)))
        assertTrue(TimetableShare.valid(TimetableShare.takenBack(t))!!.isOff)
        val area = TimetableArea(listOf(TripCard.Spot("A"), TripCard.Spot("B", lat = 1.0, lon = 2.0)), null, TripCard.Spot("  BUas ", lat = 51.0, lon = 4.0), 90)
        val va = TimetableArea.valid(area)!!
        assertEquals(listOf("B"), va.stops.map { it.name }); assertEquals("BUas", va.school.name); assertEquals(60, va.early)
        assertNull(TimetableArea.valid(area.copy(school = TripCard.Spot("x"))))
        // when it goes
        assertEquals(listOf("a", "b"), TimetableShareRules.due(null, "h", listOf("b", "a"), t))
        val sent = TimetableShareRules.Sent("h", t, listOf("a"))
        assertEquals(listOf("b"), TimetableShareRules.due(sent, "h", listOf("a", "b"), t + 60))
        assertEquals(listOf("b"), TimetableShareRules.due(sent, "h2", listOf("a", "b"), t + 60))
        assertEquals(listOf("a", "b"), TimetableShareRules.due(sent, "h2", listOf("a", "b"), t + 3 * 3600))
        assertEquals(listOf("a", "b"), TimetableShareRules.due(sent, "h", listOf("a", "b"), t + 20 * 3600))
        assertEquals(listOf("a"), TimetableShareRules.takeBack(sent, listOf("b")))
        assertEquals(listOf("a", "c"), TimetableShareRules.recipients(listOf("a", "b"), setOf("b"), listOf("c", "me"), "me", true))
        assertEquals("af63dc4c8601ec8c", TimetableShareRules.fingerprint("a".toByteArray()))
        // your week: one class per school day, first class to the day's end
        val week = ManualWeek(listOf(WeekDay(6, 8 * 60 + 45, 15 * 60 + 30, "Design")))
        val classes = week.friendClasses(t, 14, ZoneId.of("Europe/Amsterdam"))
        assertEquals(2, classes.size)
        assertEquals(1799999100.0, classes[0].start, 0.0)   // today counts, all of it (08:45)
        assertEquals("Design", classes[0].title)
        assertEquals(1799999100.0 + (6 * 60 + 45) * 60, classes[0].end!!, 0.0)
    }
}
