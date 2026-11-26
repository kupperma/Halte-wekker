package nl.haltewekker.friends

import kotlinx.serialization.Serializable

// Friends (0.25–0.28), the iOS `FriendInbox.swift`: the relay's answers, and reading a batch of boxes into the friend
// list, the groups, the chats and the timetables. Plain values, tested.

@Serializable data class RelayBox(val id: Long, val from: String, val slot: String? = null, val at: Long, val exp: Long, val data: String)
@Serializable data class RelayInbox(val boxes: List<RelayBox>, val cursor: Long, val more: Boolean)
@Serializable data class RelayRegistered(val account: String, val created: Boolean, val moved: Boolean)
@Serializable data class RelaySendResult(val to: String, val ok: Boolean, val id: Long? = null, val error: String? = null)
@Serializable data class RelaySent(val results: List<RelaySendResult>)
@Serializable data class RelayState(val from: String, val at: Long, val exp: Long, val data: String)
@Serializable data class RelayStates(val states: List<RelayState>)
@Serializable data class RelayCleared(val cleared: Int)
@Serializable data class RelayVault(val data: String? = null, val at: Long? = null)

/**
 * What the vault holds (locked with the vault key): the list, your picture, the groups (0.27), the timetable switches
 * (0.28), the extras' switches (0.29/0.30: campus, buddy, free, scores; an older app ignores them).
 */
@Serializable
data class FriendVaultContents(
    val v: Int = 1,
    val book: FriendBook,
    val picture: String? = null,
    val groups: List<FriendGroup>? = null,
    val timetable: TimetableSettings? = null,
    val extras: ExtrasSettings? = null,
)

/** Something to do on the relay, kept until it went through. */
@Serializable
data class FriendPending(
    val op: String,
    val to: String,
    val data: String? = null,
    val slot: String? = null,
    val ttl: Int? = null,
    /** (0.27) The chat line this box carries (its id), so it shows as sent once it went. */
    val line: String? = null,
) {
    companion object {
        const val BOX = "box"
        const val DROP = "drop"
        const val BLOCK = "block"
    }
}

object FriendInbox {
    data class ChatIn(val chat: String, val line: ChatMessage? = null, val seen: ChatSeen? = null, val seenFrom: String? = null)

    class Result(var book: FriendBook, var groups: GroupBook) {
        val effects = mutableListOf<FriendBook.Effect>()
        val news = mutableListOf<FriendBook.News>()
        val ack = mutableListOf<Long>()
        val kept = mutableListOf<Long>()
        val pictures = HashMap<String, ByteArray>()
        val groupNews = mutableListOf<GroupBook.News>()
        val groupPictures = HashMap<String, ByteArray>()
        val chat = mutableListOf<ChatIn>()
        val orphans = mutableListOf<RelayBox>()
        val groupsChanged = HashSet<String>()
        val timetables = HashMap<String, TimetableSeen>()
        val areas = HashMap<String, AreaSeen>()
        val timetablesOff = HashSet<String>()
        /** (0.29) Waits for you (the newest per sender), delays on shared rides, buddies' plans, friends on campus. */
        val waits = HashMap<String, WaitSeen>()
        val delays = mutableListOf<DelaySeen>()
        val buddies = HashMap<String, BuddySeen>()
        val campus = HashMap<String, CampusSeen>()
        /** (0.30) Friends' scores (the newest per friend; `on: false` takes them back). */
        val scores = HashMap<String, ScoresSeen>()
    }

    const val ORPHAN_DAYS = 7
    const val MAX_ORPHANS = 100

    private sealed class Later {
        class Opened(val o: OpenedBox, val box: RelayBox, val old: Boolean) : Later()
        class Raw(val box: RelayBox, val old: Boolean) : Later()
    }

    /** Reads `boxes` (relay order) and `retry` (kept from before, off the relay already): the list first, then lines. */
    fun process(boxes: List<RelayBox>, book: FriendBook, groups: GroupBook = GroupBook(), retry: List<RelayBox> = emptyList(),
                me: FriendIdentity, now: Double): Result {
        val r = Result(book.snapshot(), groups.copy())
        val later = mutableListOf<Later>()
        val all = retry.map { it to true } + boxes.map { it to false }
        fun known(id: String) = r.book.card(id) ?: r.groups.card(id)
        for ((box, old) in all) {
            val data = B64u.decode(box.data)
            if (data == null) { if (!old) r.ack.add(box.id); continue }
            try {
                val opened = FriendBox.open(data, me, box.from, ::known)
                if (opened.message.isChat) { later.add(Later.Opened(opened, box, old)); continue }
                control(opened, box, old, r, me, now)
            } catch (e: FriendBoxException) {
                when (e.error) {
                    FriendBoxError.NEWER_VERSION -> if (!old) r.kept.add(box.id)
                    FriendBoxError.UNKNOWN_SENDER -> later.add(Later.Raw(box, old))
                    else -> if (!old) r.ack.add(box.id)
                }
            } catch (_: Exception) {
                if (!old) r.ack.add(box.id)
            }
        }
        val weekAgo = now.toLong() - ORPHAN_DAYS * 86400L
        for (item in later) {
            when (item) {
                is Later.Opened -> {
                    chat(item.o, r, me, now)
                    if (!item.old) r.ack.add(item.box.id)
                }
                is Later.Raw -> {
                    if (!item.old) r.ack.add(item.box.id)
                    val data = B64u.decode(item.box.data) ?: continue
                    try {
                        val o = FriendBox.open(data, me, item.box.from, ::known)
                        if (o.message.isChat) chat(o, r, me, now) else control(o, item.box, true, r, me, now)
                    } catch (e: FriendBoxException) {
                        if (e.error == FriendBoxError.UNKNOWN_SENDER && item.box.at >= weekAgo) r.orphans.add(item.box)
                    } catch (_: Exception) {}
                }
            }
        }
        if (r.orphans.size > MAX_ORPHANS) {
            val keep = r.orphans.takeLast(MAX_ORPHANS)
            r.orphans.clear(); r.orphans.addAll(keep)
        }
        return r
    }

    private fun control(opened: OpenedBox, box: RelayBox, old: Boolean, r: Result, me: FriendIdentity, now: Double) {
        val id = opened.sender.account
        val g = opened.header.g
        when (val m = opened.message) {
            is FriendMessage.Unknown -> { if (!old) r.kept.add(box.id); return }
            is FriendMessage.Picture -> {
                val jpeg = m.picture.bytes
                if ((r.book.card(id) != null || r.groups.shares(id)) && jpeg != null && jpeg.isNotEmpty() && jpeg.size <= FriendPicture.MAX_BYTES) r.pictures[id] = jpeg
            }
            is FriendMessage.Group -> if (g != null) {
                val b = r.book
                val name = b.friend(id)?.name ?: m.roster.member(id)?.name ?: "Someone"
                val got = r.groups.receive(m.roster, g, id, me.account, { b.isFriend(it) }, name, now)
                if (got.accepted) r.groupsChanged.add(g)
                got.news?.let { r.groupNews.add(it) }
                got.notes.forEachIndexed { k, line -> note(line, g, "${opened.header.n}.$k", r, now) }
            }
            is FriendMessage.GroupPicture -> {
                val jpeg = m.picture.bytes
                if (g != null && r.groups.acceptsPicture(g, id) && jpeg != null && jpeg.size <= FriendPicture.MAX_BYTES) r.groupPictures[g] = jpeg
            }
            FriendMessage.GroupLeave -> if (g != null) {
                r.groups.receiveLeave(g, id, me.account)?.let { line ->
                    r.groupsChanged.add(g)
                    note(line, g, opened.header.n, r, now)
                }
            }
            is FriendMessage.Timetable -> {
                val v = TimetableShare.valid(m.share)
                if ((r.book.isFriend(id) || r.groups.shares(id)) && v != null) {
                    val t = opened.header.t
                    if (v.isOff) {
                        r.timetablesOff.add(id); r.timetables.remove(id); r.areas.remove(id)
                    } else if ((r.timetables[id]?.t ?: Long.MIN_VALUE) <= t) {
                        r.timetables[id] = TimetableSeen(v, t, now)
                        r.timetablesOff.remove(id)
                    }
                }
            }
            is FriendMessage.Area -> {
                val v = TimetableArea.valid(m.area)
                if ((r.book.isFriend(id) || r.groups.shares(id)) && v != null) {
                    val t = opened.header.t
                    if ((r.areas[id]?.t ?: Long.MIN_VALUE) <= t) {
                        r.areas[id] = AreaSeen(v, t, now)
                        r.timetablesOff.remove(id)
                    }
                }
            }
            is FriendMessage.Wait -> {
                // (in a group from someone on its list while you're in it; else from a friend)
                val chat = if (g != null) { if (r.groups.accepts(g, id)) ChatKey.group(g) else null }
                    else if (r.book.isFriend(id)) ChatKey.friend(id) else null
                val v = WaitFor.valid(m.wait)
                if (chat != null && id != me.account && v != null && (r.waits[id]?.t ?: Long.MIN_VALUE) <= opened.header.t)
                    r.waits[id] = WaitSeen(id, chat, v, opened.header.t, now)
            }
            is FriendMessage.Delay -> {
                val v = RideDelay.valid(m.delay)
                if ((r.book.isFriend(id) || r.groups.shares(id)) && v != null) r.delays.add(DelaySeen(id, v, now))
            }
            is FriendMessage.Buddy -> if (r.book.isFriend(id) && (r.buddies[id]?.t ?: Long.MIN_VALUE) <= opened.header.t)
                r.buddies[id] = BuddySeen(m.plan, opened.header.t, now)
            is FriendMessage.Campus -> if (r.book.isFriend(id) && (r.campus[id]?.t ?: Long.MIN_VALUE) <= opened.header.t)
                r.campus[id] = CampusSeen(m.state, opened.header.t, now)
            is FriendMessage.Scores -> if (r.book.isFriend(id) && (r.scores[id]?.t ?: Long.MIN_VALUE) <= opened.header.t)
                r.scores[id] = ScoresSeen(ScoresShare.valid(m.share), opened.header.t, now)
            is FriendMessage.Travel, is FriendMessage.Message, is FriendMessage.Trip, is FriendMessage.Seen -> {}
            is FriendMessage.Request, is FriendMessage.Accept, FriendMessage.Unfriend, is FriendMessage.Profile -> {
                val (effects, news) = r.book.receive(m, opened.sender, me.card, now)
                r.effects += effects
                news?.let { r.news.add(it) }
            }
        }
        if (!old) r.ack.add(box.id)
    }

    private fun note(text: String, g: String, n: String, r: Result, now: Double) {
        val m = ChatMessage(ChatMessage.id("", n), "", n, now.toLong(), now, note = text)
        r.chat.add(ChatIn(ChatKey.group(g), line = m))
    }

    private fun chat(o: OpenedBox, r: Result, me: FriendIdentity, now: Double) {
        val from = o.sender.account
        if (from == me.account) return
        val g = o.header.g
        val key = if (g != null) {
            if (!r.groups.accepts(g, from)) return
            ChatKey.group(g)
        } else {
            if (!r.book.isFriend(from)) return
            ChatKey.friend(from)
        }
        var text: ChatText? = null
        var trip: TripCard? = null
        when (val m = o.message) {
            is FriendMessage.Message -> {
                val t = ChatText.clean(m.text.text)
                val answer = TripAnswer.of(m.text.answer)
                // (0.29) an answer to a "wait for me" ("I'll wait", "Let's take the next one together")
                val waitAnswer = WaitAnswer.of(m.text.answer)
                if (t.isEmpty() && answer == null && waitAnswer == null) return
                val kept = answer?.raw ?: waitAnswer?.raw
                text = ChatText(t.ifEmpty { answer?.text ?: waitAnswer?.text ?: "" }, if (kept == null) null else m.text.re, kept)
            }
            is FriendMessage.Trip -> trip = TripCard.valid(m.card) ?: return
            is FriendMessage.Seen -> { r.chat.add(ChatIn(key, seen = m.seen, seenFrom = from)); return }
            else -> return
        }
        val line = ChatMessage(ChatMessage.id(from, o.header.n), from, o.header.n, o.header.t, now, text = text, trip = trip)
        r.chat.add(ChatIn(key, line = line))
    }

    /** (0.26) Friends' latest states: only from friends, only `travel`, only while not too old; the newest per friend. */
    fun readStates(states: List<RelayState>, book: FriendBook, me: FriendIdentity, now: Double): Map<String, FriendTravelSeen> {
        val out = HashMap<String, FriendTravelSeen>()
        for (st in states) {
            if (!book.isFriend(st.from)) continue
            val data = B64u.decode(st.data) ?: continue
            val o = try { FriendBox.open(data, me, st.from) { book.friend(it)?.card } } catch (_: Exception) { continue }
            val t = (o.message as? FriendMessage.Travel)?.state ?: continue
            val sent = minOf(o.header.t, st.at).toDouble()
            val seen = FriendTravelSeen(st.from, t, sent, st.exp.toDouble())
            if (TravelAge.freshness(seen, now) == TravelFreshness.GONE) continue
            val had = out[st.from]
            if (had != null && had.sent >= sent) continue
            out[st.from] = seen
        }
        return out
    }

    fun banner(n: FriendBook.News): Pair<String, String> = when (n) {
        is FriendBook.News.Request -> "${n.name} wants to be friends" to "Open Friends to say yes or no."
        is FriendBook.News.Accepted -> "You and ${n.name} are friends" to "${n.name} said yes to your friend request."
    }
}
