package nl.haltewekker.friends

import kotlinx.serialization.Serializable

// Test friend (A5, iOS 0.30.1 `TestFriendBot.swift`, its relay half): the bot's own account and what it does in one
// check, on plain JVM (no Android: the live JVM check drives this same code against the real relay). It talks to you
// only through the relay with the very boxes a friend's phone sends, sealed with its keys, read with
// `FriendInbox.process` on its own book and groups. `TestFriendBot` keeps it in its own file and runs it inside your
// app's own checks.

/** What the test friend keeps (its own file, never in a backup or the vault). */
@Serializable
data class TestFriendSaved(
    /** Its seed, base64url. */
    val seed: String,
    val device: String,
    val book: FriendBook,
    val groups: List<FriendGroup> = emptyList(),
    val cursor: Long = 0,
    val pending: List<FriendPending> = emptyList(),
    /** Its hello (and its timetable and area) went, once you were friends. */
    val greeted: Boolean = false,
    val timetableAt: Double? = null,
    val trip: TestTrip? = null,
    val tripSent: Double? = null,
    /** A `travel` state of its is on the relay (taken back when the trip is over). */
    val tripPut: Boolean = false,
    val wait: TestWait? = null,
    val waitSent: Double? = null,
    val campus: Boolean = false,
    /** Groups it said hello in, and your waits it answered. */
    val hello: List<String> = emptyList(),
    val waitsAnswered: List<String> = emptyList(),
    /** Being removed: it leaves the relay (tried again at the next check if the network was away). */
    val leaving: Boolean = false,
) {
    val identity: FriendIdentity? get() = B64u.decode(seed)?.takeIf { it.size == FriendIdentity.SEED_BYTES }?.let { FriendIdentity(it) }
    val account: String? get() = identity?.account
}

/** What the bot needs from your side of the app: who you are, and what it pretends near you. */
interface TestFriendEnv {
    /** Your friends card (null: no account). */
    val you: FriendCard?
    val yourName: String
    /** Your own timetable as you share it (for one near it). */
    fun yourTimetable(): TimetableShare? = null
    /** Its area: the stops near your Home, the station, your school (never the address). */
    fun area(): TimetableArea? = null
    /** Its picture (a 256 px JPEG). */
    fun picture(): ByteArray? = null
    fun relay(me: FriendIdentity, device: String): FriendRelay = FriendRelay(me, device)
}

/** One run of the bot, on a copy of what it keeps. */
class TestFriendEngine(var s: TestFriendSaved, private val env: TestFriendEnv) {
    companion object {
        /** Its `travel` states and its wait move on at most this often (each check of yours). */
        const val EVERY = 20.0

        /** Makes it (its account on the relay), and it sends you a friend request with its picture. Null: no relay. */
        suspend fun create(env: TestFriendEnv, now: Double): TestFriendSaved? {
            val you = env.you ?: return null
            val me = FriendIdentity.random()
            val dev = RelaySign.newDevice()
            try { env.relay(me, dev).register() } catch (_: Exception) { return null }
            val book = FriendBook(myName = TestFriendBrain.NAME)
            val (_, effects) = book.add(you, env.yourName, me.card, now)
            val e = TestFriendEngine(TestFriendSaved(B64u.encode(me.seed), dev, book), env)
            for (x in effects) {
                val send = x as? FriendBook.Effect.Send ?: continue
                val req = send.message as? FriendMessage.Request ?: continue
                e.enqueue(FriendMessage.Request(req.intro.copy(note = TestFriendBrain.NOTE)), send.card, me)
                env.picture()?.let { e.enqueue(FriendMessage.Picture(FriendPicture.of(it)), send.card, me, "picture", 30 * 86400) }
            }
            return e.s
        }
    }

    private val me: FriendIdentity get() = s.identity!!
    private fun relay() = env.relay(me, s.device)
    val isFriend: Boolean get() = env.you?.let { s.book.isFriend(it.account) } == true

    // MARK: one look

    /**
     * What's waiting goes, its mailbox is read and answered, its pretend trip and wait move on, and what it said goes.
     * Called inside your check right after your own boxes went, so its answers come back in that same check.
     */
    suspend fun check(now: Double) {
        if (s.leaving) { leave(); return }
        val you = env.you ?: return
        val me = s.identity ?: return
        val r = relay()
        try {
            flush(r)
            val inbox = r.inbox(s.cursor)
            val res = FriendInbox.process(inbox.boxes, s.book, GroupBook(s.groups), emptyList(), me, now)
            s = s.copy(book = res.book.snapshot(), groups = res.groups.groups)
            apply(res.effects)
            // it says yes to you at once
            if (s.book.incoming.any { it.id == you.account }) {
                val b = s.book.snapshot()
                val yes = b.accept(you.account, me.card, now)
                s = s.copy(book = b)
                apply(yes)
            }
            if (s.book.isFriend(you.account) && !s.greeted) {
                s = s.copy(greeted = true)
                line(ChatText(TestFriendBrain.HELLO), you.account)
                shareTimetable(now)
            } else if (s.greeted && s.book.isFriend(you.account) && now - (s.timetableAt ?: 0.0) >= 20 * 3600) {
                shareTimetable(now)
            }
            greetGroups()
            answer(res, you.account)
            s = s.copy(cursor = inbox.cursor)
            r.ack(res.ack)
            pretend(r, you, now)
            flush(r)
            // removed as a friend some other way (their page's "Remove"): it leaves too
            if (s.greeted && !s.book.isFriend(you.account) && s.book.incoming.none { it.id == you.account }) s = s.copy(leaving = true)
        } catch (_: FriendRelay.Failure.UnknownAccount) {
            try { r.register() } catch (_: Exception) {}
        } catch (_: Exception) {
            // (offline: next check)
        }
    }

    /** Sends what's waiting, 20 at a time; a box the relay refuses for good is let go. */
    private suspend fun flush(r: FriendRelay) {
        while (s.pending.isNotEmpty()) {
            val run = s.pending.take(20)
            try { r.send(run) } catch (_: FriendRelay.Failure.Refused) {}
            s = s.copy(pending = s.pending.filter { p -> run.none { it === p } })
        }
    }

    /** The list's effects: boxes to send (its picture along with a yes). */
    private fun apply(effects: List<FriendBook.Effect>) {
        for (e in effects) {
            val send = e as? FriendBook.Effect.Send ?: continue
            enqueue(send.message, send.card, me)
            if (send.message is FriendMessage.Accept) env.picture()?.let { enqueue(FriendMessage.Picture(FriendPicture.of(it)), send.card, me, "picture", 30 * 86400) }
        }
    }

    /** One box for one person (a box waiting in the same slot for them goes). */
    fun enqueue(m: FriendMessage, card: FriendCard, me: FriendIdentity = this.me, slot: String? = null, ttl: Int? = null, group: String? = null) {
        val d = try { FriendBox.seal(m, me, card, group = group) } catch (_: Exception) { return }
        var l = s.pending
        if (slot != null) l = l.filter { !(it.to == card.account && it.slot == slot) }
        s = s.copy(pending = l + FriendPending(FriendPending.BOX, card.account, B64u.encode(d), slot, ttl))
    }

    /** A line in a chat: to you (`chat` = your account), or to everyone else in a group ("g." + its id). */
    fun line(text: ChatText, chat: String) = post(FriendMessage.Message(text), chat)

    private fun post(m: FriendMessage, chat: String) {
        val gid = ChatKey.groupId(chat)
        val cards: List<FriendCard> = if (gid != null) {
            val g = s.groups.firstOrNull { it.id == gid }?.takeIf { it.isIn } ?: return
            g.others(me.account).map { it.card }
        } else listOfNotNull(s.book.friend(chat)?.card)
        if (cards.isEmpty()) return
        val p = FriendBox.payload(m, me.account, System.currentTimeMillis() / 1000, RelaySign.nonce(), gid)
        var l = s.pending
        for (c in cards) {
            val d = try { FriendBox.seal(p, me, c) } catch (_: Exception) { continue }
            l = l + FriendPending(FriendPending.BOX, c.account, B64u.encode(d))
        }
        s = s.copy(pending = l)
    }

    /** Hello in each group it's in and hasn't said it in yet. */
    private fun greetGroups() {
        for (g in GroupBook(s.groups).current) {
            if (g.id in s.hello) continue
            s = s.copy(hello = s.hello + g.id)
            line(ChatText(TestFriendBrain.groupHello(g.name)), ChatKey.group(g.id))
        }
    }

    /** Your lines (one-to-one and in groups) answered, marked as read; your waits answered "I’ll wait". */
    private fun answer(res: FriendInbox.Result, you: String) {
        val newest = LinkedHashMap<String, Long>()
        for (item in res.chat) {
            val m = item.line ?: continue
            if (m.from != you) continue
            newest[item.chat] = maxOf(newest[item.chat] ?: Long.MIN_VALUE, m.t)
            val t = m.text
            val c = m.trip
            if (t != null) {
                val a = t.answer
                if (a != null) TestFriendBrain.replyToAnswer(a)?.let { line(ChatText(it), item.chat) }
                else TestFriendBrain.reply(t.text)?.let { line(ChatText(it), item.chat) }
            } else if (c != null) {
                for (r in TestFriendBrain.repliesToTrip(c, m.n)) line(r, item.chat)
            }
        }
        // (read at once: "Read" under your line)
        for ((chat, t) in newest) {
            val gid = ChatKey.groupId(chat)
            val card = gid?.let { g -> s.groups.firstOrNull { it.id == g }?.roster?.member(you)?.card } ?: s.book.friend(you)?.card ?: continue
            enqueue(FriendMessage.Seen(ChatSeen(t, t)), card, me, gid?.let { GroupBook.seenSlot(it) } ?: "seen", group = gid)
        }
        val w = res.waits[you]
        if (w != null && w.wait.phase != WaitFor.Phase.OFF && w.wait.id !in s.waitsAnswered) {
            s = s.copy(waitsAnswered = (s.waitsAnswered + w.wait.id).takeLast(20))
            line(TestFriendBrain.replyToWait(w.wait.id), w.chat)
        }
    }

    // MARK: its timetable and area

    private fun shareTimetable(now: Double) {
        val you = s.book.friends.firstOrNull()?.card ?: return
        s = s.copy(timetableAt = now)
        val tt = TestFriendBrain.timetable(env.yourTimetable(), now)
        enqueue(FriendMessage.Timetable(tt), you, me, TimetableShareRules.TIMETABLE_SLOT, TimetableShareRules.TIMETABLE_TTL)
        env.area()?.let { enqueue(FriendMessage.Area(it), you, me, TimetableShareRules.AREA_SLOT, TimetableShareRules.AREA_TTL) }
    }

    // MARK: pretending

    /** Its trip's state at you (every `EVERY` seconds), its wait moving closer; taken back when they're over. */
    private suspend fun pretend(r: FriendRelay, you: FriendCard, now: Double) {
        if (!s.book.isFriend(you.account)) return
        val t = s.trip
        if (t != null) {
            if (TestTripSim.over(t, now)) {
                s = s.copy(trip = null)
                if (s.tripPut && (try { r.stateClear(null); true } catch (_: Exception) { false })) s = s.copy(tripPut = false)
                line(ChatText("Made it to ${t.stops.lastOrNull()?.name ?: "there"}! (That was a pretend trip.)"), you.account)
            } else if (now - (s.tripSent ?: 0.0) >= EVERY) {
                val st = TestTripSim.state(t, now)
                if (st != null) {
                    val d = try { FriendBox.seal(FriendMessage.Travel(st), me, you) } catch (_: Exception) { null }
                    if (d != null) {
                        val ok = try { r.statePut(listOf(you.account to d), TravelAge.TTL).any { it.ok } } catch (_: Exception) { false }
                        if (ok) s = s.copy(tripSent = now, tripPut = true)
                    }
                }
            }
        } else if (s.tripPut && (try { r.stateClear(null); true } catch (_: Exception) { false })) {
            s = s.copy(tripPut = false)
        }
        val w = s.wait
        if (w != null && (now - (s.waitSent ?: 0.0) >= EVERY || TestWaitSim.over(w, now))) {
            enqueue(FriendMessage.Wait(TestWaitSim.body(w, now)), you, me, WaitRules.SLOT, WaitRules.TTL)
            s = s.copy(waitSent = now, wait = if (TestWaitSim.over(w, now)) null else w)
        }
    }

    // MARK: leaving

    /** It leaves: every group it's in hears it, its state is taken back, the relay forgets it. True: it's gone. */
    suspend fun leave(): Boolean {
        val me = s.identity ?: return true
        val r = relay()
        val g = GroupBook(s.groups)
        val boxes = mutableListOf<FriendPending>()
        for (grp in g.current) for (x in g.leave(grp.id, me.account)) {
            val d = try { FriendBox.seal(x.message, me, x.to, group = x.group) } catch (_: Exception) { continue }
            boxes.add(FriendPending(FriendPending.BOX, x.to.account, B64u.encode(d), x.slot))
        }
        s = s.copy(groups = g.groups, leaving = true)
        for (chunk in boxes.chunked(20)) try { r.send(chunk) } catch (_: Exception) {}
        if (s.tripPut) try { r.stateClear(null) } catch (_: Exception) {}
        return try { r.leave(); true } catch (_: FriendRelay.Failure.UnknownAccount) { true } catch (_: Exception) { false }
    }
}
