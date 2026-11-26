package nl.haltewekker

import kotlinx.coroutines.runBlocking
import nl.haltewekker.friends.B64u
import nl.haltewekker.friends.ChatText
import nl.haltewekker.friends.FriendBook
import nl.haltewekker.friends.FriendBox
import nl.haltewekker.friends.FriendCard
import nl.haltewekker.friends.FriendIdentity
import nl.haltewekker.friends.FriendInbox
import nl.haltewekker.friends.FriendMessage
import nl.haltewekker.friends.FriendPending
import nl.haltewekker.friends.FriendRelay
import nl.haltewekker.friends.GroupBook
import nl.haltewekker.friends.RelaySign
import nl.haltewekker.friends.TestFriendBrain
import nl.haltewekker.friends.TestFriendEngine
import nl.haltewekker.friends.TestFriendEnv
import nl.haltewekker.friends.TestTripSim
import nl.haltewekker.friends.TravelState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * The test friend against the live relay (skipped unless HW_LIVE_RELAY=1): the bot's own account (the app's
 * `TestFriendEngine`, as `TestFriendBot` runs it inside your checks) registers, sends a throwaway account a friend
 * request with its note, is accepted, says hello and shares a timetable, answers a line and marks it read, puts a
 * pretend train's state (with a coach and a seat) on the relay, then both leave.
 *
 *   HW_LIVE_RELAY=1 ./gradlew testReleaseUnitTest --tests nl.haltewekker.TestFriendLiveTest
 */
class TestFriendLiveTest {
    private val base = System.getenv("HW_RELAY_URL") ?: FriendRelay.BASE
    private fun now() = System.currentTimeMillis() / 1000.0

    @Test fun botRegistersBefriendsAnswersAndLeaves() = runBlocking {
        assumeTrue("set HW_LIVE_RELAY=1 to run against the live relay", System.getenv("HW_LIVE_RELAY") == "1")
        // the throwaway "you"
        val you = FriendIdentity.random()
        val youRelay = FriendRelay(you, RelaySign.newDevice(), base)
        youRelay.register()
        val env = object : TestFriendEnv {
            override val you: FriendCard get() = you.card
            override val yourName: String get() = "Throwaway"
            override fun relay(me: FriendIdentity, device: String) = FriendRelay(me, device, base)
        }
        var book = FriendBook(myName = "Throwaway")
        var groups = GroupBook()
        var cursor = 0L
        suspend fun read(): FriendInbox.Result {
            val inbox = youRelay.inbox(cursor)
            val r = FriendInbox.process(inbox.boxes, book, groups, emptyList(), you, now())
            book = r.book.snapshot(); groups = r.groups
            cursor = inbox.cursor
            youRelay.ack(r.ack)
            return r
        }
        suspend fun send(m: FriendMessage, to: FriendCard) {
            val d = FriendBox.seal(m, you, to)
            youRelay.send(listOf(FriendPending(FriendPending.BOX, to.account, B64u.encode(d))))
        }
        var bot: TestFriendEngine? = null
        try {
            // 1. it registers and asks you
            val made = TestFriendEngine.create(env, now())
            assertNotNull("the bot registers on the relay", made)
            bot = TestFriendEngine(made!!, env)
            bot.check(now())
            val r1 = read()
            val req = book.incoming.firstOrNull { it.id == made.account }
            assertNotNull("its request arrives", req)
            assertEquals(TestFriendBrain.NAME, req!!.name)
            // 2. you say yes; it says hello and shares a timetable
            val effects = book.accept(req.id, you.card, now())
            for (e in effects) if (e is FriendBook.Effect.Send) send(e.message, e.card)
            bot.check(now())
            assertTrue("it's friends with you", bot.isFriend)
            val r2 = read()
            assertTrue("its hello", r2.chat.any { it.line?.text?.text == TestFriendBrain.HELLO })
            assertNotNull("its timetable", r2.timetables[req.id])
            // 3. you write; it answers and marks it read
            val line = FriendBox.payload(FriendMessage.Message(ChatText("Hello")), you.account, now().toLong(), RelaySign.nonce())
            youRelay.send(listOf(FriendPending(FriendPending.BOX, req.id, B64u.encode(FriendBox.seal(line, you, req.card)))))
            bot.check(now())
            val r3 = read()
            assertTrue("its answer", r3.chat.any { it.line?.text?.text == "Hi! Test friend here. Your message came through, locked end to end." })
            assertTrue("read at once", r3.chat.any { it.seen?.read != null && it.seenFrom == req.id })
            // 4. a pretend train, on board: its state with a coach and a seat, through the relay's state routes
            val trip = TestTripSim.make("train", "SPR", null, "test-friend-live", listOf(
                TestTripSim.RealStop("Best", 51.50972, 5.39, null), TestTripSim.RealStop("'s-Hertogenbosch", 51.69048, 5.29362, null)), null, now() - 120)!!
            bot.s = bot.s.copy(trip = trip, tripSent = null)
            bot.check(now())
            val states = FriendInbox.readStates(youRelay.stateGet(), book, you, now())
            val st: TravelState? = states[req.id]?.state
            assertNotNull("its travel state", st)
            assertEquals(TravelState.Seat("none", 6, 11), st!!.coach?.seat)
            assertTrue(r1.news.isNotEmpty())
        } finally {
            // 5. both leave
            val gone = bot?.leave() ?: true
            assertTrue("the bot leaves the relay", gone)
            try { youRelay.leave() } catch (_: Exception) {}
        }
    }
}
