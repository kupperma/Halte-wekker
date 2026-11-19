package nl.haltewekker.friends

import kotlinx.serialization.Serializable

// Friends (0.27), the iOS `FriendChat.swift`: chats as plain values. A chat is one friend's (keyed by their account)
// or a group's ("g." + the group id). Lines came as boxes (`message`, `trip`) or were written here; `seen` boxes say how
// far the others got and read. Nothing here sends: the store locks and sends what these values say is due.

object ChatKey {
    fun friend(account: String) = account
    fun group(id: String) = "g.$id"
    fun groupId(key: String): String? = if (key.startsWith("g.")) key.substring(2) else null
    fun isGroup(key: String) = key.startsWith("g.")
}

/** The body of a `message` box: a line, or an answer to a trip card (`re` its `n`, `answer` "in" | "cant"). */
@Serializable
data class ChatText(val text: String, val re: String? = null, val answer: String? = null) {
    companion object {
        const val MAX_LENGTH = 1000

        /** No control characters but line breaks, at most two line breaks in a row, trimmed, at most 1000 characters. */
        fun clean(s: String): String {
            val lines = s.split(Regex("\r\n|[\n\r\u000B\u000C\u0085  ]")).map { line ->
                line.filter { !Character.isISOControl(it) || it == '\t' }.replace('\t', ' ').trim()
            }
            val out = mutableListOf<String>()
            var blank = 0
            for (l in lines) {
                if (l.isEmpty()) { blank++; if (blank > 1) continue } else blank = 0
                out.add(l)
            }
            return FriendNames.takeChars(out.joinToString("\n").trim(), MAX_LENGTH)
        }
    }
}

enum class TripAnswer(val raw: String) {
    YES("in"), NO("cant");
    val text: String get() = if (this == YES) "I’m in" else "Can’t make it"
    companion object { fun of(raw: String?): TripAnswer? = entries.firstOrNull { it.raw == raw } }
}

/** The body of a `seen` box: the newest of the recipient's lines (by their `t`) the sender has got / has read. */
@Serializable
data class ChatSeen(val got: Long? = null, val read: Long? = null) {
    fun merged(o: ChatSeen) = ChatSeen(max(got, o.got), max(read, o.read))
    companion object {
        fun max(a: Long?, b: Long?): Long? = if (a == null) b else if (b == null) a else maxOf(a, b)
    }
}

/** One line in a chat (kept on this phone). Exactly one of text, trip, note. */
@Serializable
data class ChatMessage(
    val id: String,
    val from: String,
    val n: String,
    /** The writer's own time (the box's `t`). */
    val t: Long,
    /** When this phone got it (or wrote it): the chat's order. */
    val at: Double,
    val text: ChatText? = null,
    val trip: TripCard? = null,
    val note: String? = null,
    /** Yours: it went to the relay (false: still waiting). */
    val sent: Boolean? = null,
) {
    val isNote: Boolean get() = note != null
    companion object { fun id(from: String, n: String) = "$from|$n" }
}

sealed class ChatDelivery {
    data object Waiting : ChatDelivery()
    data object Sent : ChatDelivery()
    data class Delivered(val n: Int, val of: Int) : ChatDelivery()
    data class Read(val n: Int, val of: Int) : ChatDelivery()
}

@Serializable
data class Chat(
    val key: String,
    val messages: List<ChatMessage> = emptyList(),
    val readAt: Double? = null,
    val marks: Map<String, ChatSeen> = emptyMap(),
    val told: Map<String, ChatSeen> = emptyMap(),
) {
    val last: ChatMessage? get() = messages.lastOrNull()
}

/** Every chat on this phone (a file beside the friend list; not in the backup). */
@Serializable
data class ChatBook(val v: Int = 1, val chats: Map<String, Chat> = emptyMap()) {
    fun chat(key: String) = chats[key]

    /** Puts a line in a chat. Null: it was there already (the same box again). */
    fun add(m: ChatMessage, key: String): ChatBook? {
        val c = chats[key] ?: Chat(key)
        if (c.messages.any { it.id == m.id }) return null
        val list = (c.messages + m).takeLast(KEEP)
        return copy(chats = chats + (key to c.copy(messages = list)))
    }

    fun markSent(ids: Set<String>): ChatBook {
        if (ids.isEmpty()) return this
        return copy(chats = chats.mapValues { (_, c) ->
            if (c.messages.none { it.id in ids && it.sent != true }) c
            else c.copy(messages = c.messages.map { if (it.id in ids) it.copy(sent = true) else it })
        })
    }

    fun read(key: String, now: Double): ChatBook {
        val c = chats[key] ?: return this
        val newest = c.messages.maxOfOrNull { it.at } ?: now
        return copy(chats = chats + (key to c.copy(readAt = maxOf(c.readAt ?: Double.NEGATIVE_INFINITY, maxOf(now, newest)))))
    }

    fun unread(key: String, me: String): Int = chats[key]?.let { unread(it, me) } ?: 0

    fun unreadTotal(me: String, among: Set<String>? = null): Int =
        chats.values.filter { among?.contains(it.key) ?: true }.sumOf { unread(it, me) }

    fun seen(s: ChatSeen, from: String, key: String): ChatBook {
        val c = chats[key] ?: return this
        return copy(chats = chats + (key to c.copy(marks = c.marks + (from to (c.marks[from] ?: ChatSeen()).merged(s)))))
    }

    /** What to tell each writer (one `seen` box each), because you got or read more of theirs than you told them. */
    fun marksDue(key: String, me: String): List<Pair<String, ChatSeen>> {
        val c = chats[key] ?: return emptyList()
        val readAt = c.readAt ?: Double.NEGATIVE_INFINITY
        val byWriter = HashMap<String, ChatSeen>()
        for (m in c.messages) {
            if (m.isNote || m.from == me || m.from.isEmpty()) continue
            var s = byWriter[m.from] ?: ChatSeen()
            s = s.copy(got = ChatSeen.max(s.got, m.t))
            if (m.at <= readAt) s = s.copy(read = ChatSeen.max(s.read, m.t))
            byWriter[m.from] = s
        }
        val out = mutableListOf<Pair<String, ChatSeen>>()
        for ((w, s) in byWriter.toSortedMap()) {
            val had = c.told[w] ?: ChatSeen()
            val more = (s.got ?: Long.MIN_VALUE) > (had.got ?: Long.MIN_VALUE) || (s.read ?: Long.MIN_VALUE) > (had.read ?: Long.MIN_VALUE)
            if (more) out.add(w to s.merged(had))
        }
        return out
    }

    fun told(s: ChatSeen, writer: String, key: String): ChatBook {
        val c = chats[key] ?: return this
        return copy(chats = chats + (key to c.copy(told = c.told + (writer to (c.told[writer] ?: ChatSeen()).merged(s)))))
    }

    /** How far one of your lines got, `others` the chat's other people. */
    fun delivery(m: ChatMessage, key: String, others: List<String>): ChatDelivery {
        if (m.sent != true) return ChatDelivery.Waiting
        val marks = chats[key]?.marks ?: emptyMap()
        val count = maxOf(1, others.size)
        val read = others.count { (marks[it]?.read ?: Long.MIN_VALUE) >= m.t }
        if (read > 0) return ChatDelivery.Read(read, count)
        val got = others.count { (marks[it]?.got ?: Long.MIN_VALUE) >= m.t || (marks[it]?.read ?: Long.MIN_VALUE) >= m.t }
        if (got > 0) return ChatDelivery.Delivered(got, count)
        return ChatDelivery.Sent
    }

    /** The answers to a trip card (its `n`), the newest per person. */
    fun answers(card: String, key: String): Map<String, TripAnswer> {
        val c = chats[key] ?: return emptyMap()
        val out = HashMap<String, TripAnswer>()
        for (m in c.messages) {
            val t = m.text ?: continue
            if (t.re != card) continue
            val a = TripAnswer.of(t.answer) ?: continue
            out[m.from] = a
        }
        return out
    }

    val recent: List<Chat> get() = chats.values.filter { it.messages.isNotEmpty() }.sortedByDescending { it.last?.at ?: 0.0 }

    fun remove(key: String) = copy(chats = chats - key)

    companion object {
        const val KEEP = 500
        fun unread(c: Chat, me: String): Int {
            val since = c.readAt ?: Double.NEGATIVE_INFINITY
            return c.messages.count { !it.isNote && it.from != me && it.at > since }
        }
    }
}

object QuickReplies {
    val always = listOf("Running 5 min late", "Save me a seat", "Wait for me", "I’m at the stop")
    fun list(line: String?): List<String> {
        val l = line?.trim()
        if (l.isNullOrEmpty()) return always
        return listOf("On the $l") + always
    }
}

object ChatWords {
    fun preview(m: ChatMessage, me: String, name: (String) -> String, group: Boolean): String {
        val who = if (m.from == me) "You: " else if (group && m.from.isNotEmpty()) "${name(m.from)}: " else ""
        m.text?.let { return who + it.text.replace("\n", " ").take(90) }
        m.trip?.let { return who + "Trip: " + TripCardWords.short(it) }
        return m.note ?: ""
    }
}
