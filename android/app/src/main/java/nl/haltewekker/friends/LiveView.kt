package nl.haltewekker.friends

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * (relay 2026-11-27) Someone's live link opened in this app (`haltewekker://live/<token>#k=<key>` from the page's "Open in
 * Haltewekker", or the https link shared or pasted): the trip as the page shows it, read the same way (`/live/v1/get`,
 * opened with the key from the link), and messages to the sharer with your own name, and your friends account so they
 * see you as that friend. Kept only while it's open; nothing is saved.
 */
object LiveView {
    data class Sent(val seq: Int, val at: Double, val text: String)
    data class View(
        val token: String, val key: ByteArray, val state: LiveState? = null, val status: String? = null, val ended: Boolean = false,
        val seen: Int = 0, val replies: List<LiveReply> = emptyList(), val sent: List<Sent> = emptyList(), val note: String? = null,
    )

    val view = MutableStateFlow<View?>(null)
    private val relay = LiveRelay()

    /** A live link of this relay (either form): opened (true), else not one (false). */
    fun open(link: String): Boolean {
        val (token, key) = LiveCrypto.parse(link) ?: return false
        if (view.value?.token != token) view.value = View(token, key, status = "Opening the trip…")
        return true
    }

    /** The first live link in a shared or pasted text. */
    fun find(text: String?): String? =
        Regex("(https://haltewekker-relay\\.tsfaw1\\.workers\\.dev/live/|haltewekker://live/)[A-Za-z0-9_-]{22}/?#\\S+").find(text ?: "")?.value

    fun close() { view.value = null }

    /** One look (the screen asks every 15 s while it's showing). */
    suspend fun poll() {
        val v = view.value ?: return
        if (v.ended) return
        val (st, got) = relay.get(v.token)
        val cur = view.value?.takeIf { it.token == v.token } ?: return
        view.value = when {
            st == 404 || st == 410 -> cur.copy(ended = true, status = "This live trip has ended.")
            st != 200 || got == null -> cur.copy(status = "Can’t reach the trip right now. Trying again…")
            else -> {
                val s = try { FriendJson.decode(LiveState.serializer(), LiveCrypto.open(B64u.decode(got.data) ?: ByteArray(0), v.key, v.token)) } catch (_: Exception) { null }
                if (s == null) cur.copy(status = "This link’s key doesn’t fit. Ask for the link again.")
                else cur.copy(state = s, status = null, seen = got.seen,
                    replies = got.replies.mapNotNull { (_, _, d) -> B64u.decode(d)?.let { LiveMessages.openReply(it, v.key, v.token) } })
            }
        }
    }

    /** A message to the sharer: your name, and your friends account when you have one. */
    suspend fun send(c: Context, text: String): Boolean {
        val v = view.value ?: return false
        val t = LiveTripV2.clean(text, LiveMessages.MAX_TEXT)
        if (t.isEmpty()) return false
        val name = LiveNames.sender(FriendStore.book.value?.myName, c.getSharedPreferences("friends", Context.MODE_PRIVATE).getString("live.name", ""))
        val now = Math.floor(System.currentTimeMillis() / 1000.0)
        val m = LiveMessage(name, "app", FriendStore.myAccount, t, now)
        val a = relay.msg(v.token, LiveMessages.seal(m, v.key, v.token))
        val cur = view.value?.takeIf { it.token == v.token } ?: return false
        view.value = when (a) {
            is LiveRelay.Answer.Ok -> cur.copy(sent = (cur.sent + Sent(a.seq, now, t)).takeLast(20), note = null)
            LiveRelay.Answer.Slow -> cur.copy(note = "Wait a few seconds before sending another.")
            LiveRelay.Answer.Ended -> cur.copy(note = "The live trip has ended.")
            else -> cur.copy(note = "Couldn’t send it. Check your connection.")
        }
        return a is LiveRelay.Answer.Ok
    }
}
