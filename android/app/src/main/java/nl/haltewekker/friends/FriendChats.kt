package nl.haltewekker.friends

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.flow.MutableStateFlow
import nl.haltewekker.R
import java.io.File

/**
 * Friends (0.27), the iOS `FriendChats.swift`: the chats on this phone (one per friend, one per group), in
 * `files/friends/chats.json` (not backed up, not in the vault). Lines come in with each check of the relay; no push.
 * A line fetched while the app is open: the in-app banner (none for the chat on screen); fetched in the background (a
 * trip's tick, the WorkManager refresh): one local notification per chat (`friends-chat-<chat>`).
 */
object FriendChats {
    const val CHANNEL = "friends"
    const val EXTRA_CHAT = "friendsChat"
    const val EXTRA_FRIENDS = "friends"

    private lateinit var ctx: Context
    val book = MutableStateFlow(ChatBook())
    /** The chat on screen now: what comes in there is read at once, without a banner. */
    val onScreen = MutableStateFlow<String?>(null)
    /** A chat to open (a notification tapped, a friend's "Message"). */
    val toOpen = MutableStateFlow<String?>(null)
    /** The app is in front (MainActivity's onStart/onStop). */
    @Volatile var foreground = false

    private val file: File get() = File(FriendStore.folder(ctx), "chats.json")

    fun init(c: Context) {
        ctx = c.applicationContext
        book.value = (try { file.takeIf { it.exists() }?.readBytes() } catch (_: Exception) { null })?.let { FriendJson.decode(ChatBook.serializer(), it) } ?: ChatBook()
        channel(ctx)
        publishUnread()
    }

    fun channel(c: Context) {
        val nm = c.getSystemService(NotificationManager::class.java) ?: return
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Friends", NotificationManager.IMPORTANCE_DEFAULT).apply {
            description = "Messages and friend requests, when they come in on a trip or at a background check"
        })
    }

    private fun save() {
        try {
            val tmp = File(file.parentFile, "chats.json.tmp")
            tmp.writeBytes(FriendJson.encode(ChatBook.serializer(), book.value))
            tmp.renameTo(file)
        } catch (_: Exception) {}
    }

    private fun now() = System.currentTimeMillis() / 1000.0

    /** Friends' chats and the groups you're in (or were taken off). */
    private val liveKeys: Set<String>
        get() = ((FriendStore.book.value?.friends?.map { it.id } ?: emptyList()) + FriendStore.groups.value.shown.map { ChatKey.group(it.id) }).toSet()

    private fun publishUnread() {
        val me = FriendStore.myAccount
        FriendStore.unread.value = if (me == null) 0 else book.value.unreadTotal(me, liveKeys)
    }

    fun refresh() = publishUnread()

    fun unread(key: String): Int = FriendStore.myAccount?.let { book.value.unread(key, it) } ?: 0

    val recent: List<Chat> get() { val live = liveKeys; return book.value.recent.filter { it.key in live } }

    // MARK: what comes in

    fun take(c: Context, items: List<FriendInbox.ChatIn>) {
        val me = FriendStore.myAccount ?: return
        if (items.isEmpty()) return
        var b = book.value
        val fresh = mutableListOf<Pair<String, ChatMessage>>()
        for (i in items) {
            if (i.line != null) {
                val nb = b.add(i.line, i.chat)
                if (nb != null) { b = nb; if (!i.line.isNote && i.line.from != me) fresh.add(i.chat to i.line) }
            } else if (i.seen != null && i.seenFrom != null) b = b.seen(i.seen, i.seenFrom, i.chat)
        }
        val k = onScreen.value
        if (foreground && k != null) b = b.read(k, now())
        book.value = b
        tell(c, fresh)
        marks(items.map { it.chat }.toSet())
        save()
        publishUnread()
    }

    private fun title(chat: String, from: String): String {
        val who = FriendStore.name(from)
        ChatKey.groupId(chat)?.let { gid -> FriendStore.group(gid)?.let { return "$who · ${it.name}" } }
        return who
    }

    private fun tell(c: Context, fresh: List<Pair<String, ChatMessage>>) {
        val me = FriendStore.myAccount ?: return
        for ((chat, lines) in fresh.groupBy { it.first }) {
            if (foreground && chat == onScreen.value) continue
            val last = lines.last().second
            val t = title(chat, last.from)
            val body = ChatWords.preview(last, me, { FriendStore.name(it) }, false) + if (lines.size > 1) " (+${lines.size - 1} more)" else ""
            if (foreground) FriendStore.banners.tryEmit(FriendBanner(t, body, chat))
            else notify(c, "friends-chat-$chat", t, body, chat)
        }
    }

    /** A request or "you're friends now" fetched in the background. */
    fun notifyNews(c: Context, title: String, body: String) { if (!foreground) notify(c, "friends-news", title, body, null) }

    /** (A4) The extras' news (a wait, a delay, the buddy, free time): a banner in front, else a notification. */
    fun tell(c: Context, tag: String, title: String, body: String, chat: String?) {
        if (foreground) FriendStore.banners.tryEmit(FriendBanner(title, body, chat)) else notify(c, tag, title, body, chat)
    }

    private fun notify(c: Context, tag: String, title: String, body: String, chat: String?) {
        val i = Intent().setClassName(c, "nl.haltewekker.ui.MainActivity").addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            .putExtra(EXTRA_FRIENDS, true).apply { if (chat != null) putExtra(EXTRA_CHAT, chat) }
        val pi = PendingIntent.getActivity(c, tag.hashCode(), i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val n = NotificationCompat.Builder(c, CHANNEL).setSmallIcon(R.drawable.ic_stat_ride).setContentTitle(title).setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body)).setAutoCancel(true).setContentIntent(pi)
            .setGroup("friends").setTimeoutAfter(2 * 86400_000L).build()
        try { c.getSystemService(NotificationManager::class.java)?.notify(tag, 7, n) } catch (_: SecurityException) {}
    }

    fun clearNotification(c: Context, chat: String) {
        try { c.getSystemService(NotificationManager::class.java)?.cancel("friends-chat-$chat", 7) } catch (_: Exception) {}
    }

    private fun marks(chats: Set<String>) {
        val me = FriendStore.myAccount ?: return
        var b = book.value
        for (chat in chats) for ((to, s) in b.marksDue(chat, me)) {
            FriendStore.queueSeen(s, to, chat)
            b = b.told(s, to, chat)
        }
        book.value = b
    }

    // MARK: what you do (on FriendStore's lane)

    fun read(chat: String) = FriendStore.launch {
        book.value = book.value.read(chat, now())
        marks(setOf(chat))
        save()
        publishUnread()
        clearNotification(ctx, chat)
    }

    fun send(text: String, chat: String) = FriendStore.launch {
        val t = ChatText.clean(text)
        if (t.isEmpty()) return@launch
        val body = ChatText(t)
        post(FriendMessage.Message(body), chat) { m -> m.copy(text = body) }
    }

    /** (0.29) "I'll wait" / "Let's take the next one together" to a wait (its id). */
    fun answerWait(a: WaitAnswer, wait: String, chat: String) = FriendStore.launch { answerWaitNow(a, wait, chat) }

    fun answerWaitNow(a: WaitAnswer, wait: String, chat: String) {
        val body = ChatText(a.text, wait, a.raw)
        post(FriendMessage.Message(body), chat) { it.copy(text = body) }
    }

    fun answer(a: TripAnswer, card: String, chat: String) = FriendStore.launch {
        val body = ChatText(a.text, card, a.raw)
        post(FriendMessage.Message(body), chat) { it.copy(text = body) }
    }

    /** A trip card to each of these chats; gives how many it went to. */
    suspend fun sendTrip(c: TripCard, chats: List<String>): Int = kotlinx.coroutines.withContext(FriendStore.lane) {
        val card = TripCard.valid(c) ?: return@withContext 0
        chats.count { post(FriendMessage.Trip(card), it) { m -> m.copy(trip = card) } }
    }

    private fun post(m: FriendMessage, chat: String, content: (ChatMessage) -> ChatMessage): Boolean {
        val me = FriendStore.myAccount ?: return false
        val n = RelaySign.nonce()
        val at = now()
        val t = at.toLong()
        val line = content(ChatMessage(ChatMessage.id(me, n), me, n, t, at, sent = false))
        if (!FriendStore.queueLine(m, chat, n, t, line.id)) return false
        book.value = (book.value.add(line, chat) ?: book.value).read(chat, at)
        save()
        publishUnread()
        FriendStore.sync(FriendStore.Why.NOW)
        return true
    }

    /** A line about the group written here ("You added Lou"). */
    fun note(text: String, chat: String) {
        val n = RelaySign.nonce()
        val at = now()
        book.value = (book.value.add(ChatMessage(ChatMessage.id("", n), "", n, at.toLong(), at, note = text), chat) ?: book.value).read(chat, at)
        save()
    }

    fun markSent(lines: Set<String>) { book.value = book.value.markSent(lines); save() }

    fun remove(chat: String) { book.value = book.value.remove(chat); save(); publishUnread() }

    fun clearAll() {
        book.value = ChatBook()
        onScreen.value = null
        toOpen.value = null
        file.delete()
    }

    fun delivery(m: ChatMessage, chat: String): ChatDelivery = book.value.delivery(m, chat, FriendStore.recipients(chat).map { it.account })
}
