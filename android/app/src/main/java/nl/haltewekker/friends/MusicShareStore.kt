package nl.haltewekker.friends

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.media.MediaMetadata
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.provider.Settings
import android.service.notification.NotificationListenerService
import androidx.core.app.NotificationManagerCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import nl.haltewekker.data.Net
import nl.haltewekker.logs.FieldLog

/**
 * Listening now (relay 2026-11-27), the iOS `MusicShareStore.swift`: the song you listen to, for your friends and your
 * live link, only while you travel and only when you turned it on (Settings › Friends). The rules are in `MusicShare`
 * (tested). It looks on the ride's own network tick (`FriendTravelShare.tick`), at most every 30 s: no loop and no
 * wake-up of its own. Any music app through its media session (Android's Notification access lets the app see the
 * sessions; no notification is read), with a public cover and link from the iTunes Search API (the phone's own cover
 * picture is never sent); or Spotify and other apps through your own Last.fm account, read by the relay. Never
 * history: only the song playing now, in memory, gone when the trip ends. The log only says "music · sharing on/off"
 * and how many songs went out.
 */
object MusicShareStore {
    private const val PREFS = "music"
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    val on = MutableStateFlow(false)
    val from = MutableStateFlow(MusicFrom.PLAYER)
    val who = MutableStateFlow(MusicAudience.ALL)
    val lastfmUser = MutableStateFlow("")
    /** The song now (only while you travel with sharing on, or right after "Check now"). */
    val current = MutableStateFlow<MusicNow?>(null)
    /** What's wrong with the source, in words. */
    val problem = MutableStateFlow<String?>(null)
    /** The relay has no Last.fm key yet. */
    val lastfmMissing = MutableStateFlow(false)
    val checking = MutableStateFlow(false)

    @Volatile private var lastLook: Double? = null
    @Volatile private var looking = false
    private val covers = HashMap<String, Pair<String?, String?>>()
    private val sent = HashSet<String>()
    private var loaded = false
    private lateinit var app: Context

    private fun now() = System.currentTimeMillis() / 1000.0

    fun load(c: Context) {
        if (loaded) return
        loaded = true
        app = c.applicationContext
        val p = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        on.value = p.getBoolean("share", false)
        from.value = MusicFrom.of(p.getString("from", null))
        who.value = MusicAudience.of(p.getString("who", null))
        lastfmUser.value = p.getString("lastfm", "") ?: ""
    }

    private fun prefs() = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    // MARK: the settings

    fun setOn(c: Context, v: Boolean) {
        load(c)
        if (v == on.value) return
        on.value = v
        prefs().edit().putBoolean("share", v).apply()
        FieldLog.ride(if (v) "music · sharing on" else "music · sharing off")
        if (!v) { current.value = null; synchronized(sent) { sent.clear() } }
        FriendTravelShare.settingsChanged(c)
        LiveLinkStore.tick()
    }

    fun setFrom(c: Context, f: MusicFrom) {
        load(c)
        if (f == from.value) return
        from.value = f
        prefs().edit().putString("from", f.raw).apply()
        current.value = null
        problem.value = null
        FriendTravelShare.settingsChanged(c)
    }

    fun setWho(c: Context, w: MusicAudience) {
        load(c)
        if (w == who.value) return
        who.value = w
        prefs().edit().putString("who", w.raw).apply()
        FriendTravelShare.settingsChanged(c)
        LiveLinkStore.tick()
    }

    fun setUser(c: Context, u: String) {
        load(c)
        lastfmUser.value = u
        prefs().edit().putString("lastfm", u.trim()).apply()
        if (from.value.viaLastfm) { current.value = null; problem.value = null }
    }

    /** Android lets the app see what's playing once Notification access is on for it. */
    fun hasAccess(c: Context) = NotificationManagerCompat.getEnabledListenerPackages(c).contains(c.packageName)

    fun accessIntent() = Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    // MARK: what goes out

    private fun note(m: LiveMusic?) = m?.also { synchronized(sent) { sent.add(it.title + "|" + (it.artist ?: "")) } }

    /** What friends get with your travel state now. */
    fun forFriends(travelling: Boolean): LiveMusic? {
        if (!loaded) return null
        return note(MusicShare.share(current.value, on.value, who.value, MusicShare.Channel.FRIENDS, travelling, now()))
    }

    /** What your live link's page gets now. */
    fun forLink(travelling: Boolean): LiveMusic? {
        if (!loaded) return null
        return note(MusicShare.share(current.value, on.value, who.value, MusicShare.Channel.LINK, travelling, now()))
    }

    // MARK: when to look

    /** The ride's network tick: a look when one is due, while sharing is on and you travel. */
    fun tick(c: Context, travelling: Boolean) {
        load(c)
        if (!on.value || !travelling) {
            if (current.value != null && !travelling) stop()
            return
        }
        if (looking || !MusicShare.lookDue(lastLook, now())) return
        lastLook = now()
        scope.launch { look(c.applicationContext) }
    }

    /** The trip (and the live link) ended: the song is forgotten. */
    fun stop() {
        val n = synchronized(sent) { val k = sent.size; sent.clear(); k }
        if (n > 0) FieldLog.ride("music · $n song${if (n == 1) "" else "s"} shared")
        current.value = null
        lastLook = null
    }

    /** "Check now" in Settings: one look, shown there only (nothing is sent outside a trip). */
    fun checkNow(c: Context) {
        load(c)
        if (looking) return
        checking.value = true
        scope.launch {
            try { look(c.applicationContext) } finally { checking.value = false }
        }
    }

    private suspend fun look(c: Context) {
        if (looking) return
        looking = true
        try {
            val before = current.value?.title
            try {
                if (from.value == MusicFrom.PLAYER) lookPlayer(c) else lookLastfm()
            } catch (_: Exception) { /* keep what we had */ }
            if (current.value?.title != before) LiveLinkStore.tick()
        } finally { looking = false }
    }

    // MARK: a music app on this phone (its media session)

    private suspend fun lookPlayer(c: Context) {
        if (!hasAccess(c)) {
            problem.value = "Turn on Notification access for Haltewekker, so it can see what’s playing."
            current.value = null
            return
        }
        problem.value = null
        val msm = c.getSystemService(MediaSessionManager::class.java) ?: return
        val sessions = try { msm.getActiveSessions(ComponentName(c, MusicListener::class.java)) } catch (_: SecurityException) { null }
        if (sessions == null) {
            problem.value = "Turn on Notification access for Haltewekker, so it can see what’s playing."
            current.value = null
            return
        }
        val s = sessions.firstOrNull { it.playbackState?.state == PlaybackState.STATE_PLAYING } ?: sessions.firstOrNull()
        val meta: MediaMetadata? = s?.metadata
        if (s == null || meta == null) { current.value = null; return }
        val title = meta.getString(MediaMetadata.METADATA_KEY_TITLE) ?: meta.getString(MediaMetadata.METADATA_KEY_DISPLAY_TITLE)
        if (title.isNullOrBlank()) { current.value = null; return }
        val artist = meta.getString(MediaMetadata.METADATA_KEY_ARTIST) ?: meta.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST) ?: ""
        val name = MusicShare.appName(s.packageName)
        val playing = s.playbackState?.state == PlaybackState.STATE_PLAYING
        val k = "$artist|$title".lowercase()
        val found = synchronized(covers) { covers[k] } ?: itunes(title, artist)?.also { f ->
            synchronized(covers) { if (covers.size > 50) covers.clear(); covers[k] = f }
        }
        val url = if (s.packageName == "com.spotify.music") MusicShare.spotifySearch(title, artist) else found?.second
        current.value = MusicNow(title, artist, name, url, found?.first, playing, now())
    }

    /** A public cover and Apple Music link for the song (the iTunes Search API, no key). A miss is kept too. */
    private suspend fun itunes(title: String, artist: String): Pair<String?, String?>? {
        val a = Net.get(MusicShare.searchUrl(title, artist))
        if (!a.ok) return null
        return MusicShare.itunesPick(a.text, title, artist) ?: (null to null)
    }

    // MARK: Last.fm (through the relay)

    private suspend fun lookLastfm() {
        val user = lastfmUser.value.trim()
        if (!MusicShare.validUser(user)) {
            problem.value = if (user.isEmpty()) "Type your Last.fm username." else "That isn’t a Last.fm username."
            current.value = null
            return
        }
        val a = Net.get(LiveCrypto.RELAY + "/music/v1/now", listOf("user" to user, "app" to if (from.value == MusicFrom.SPOTIFY) "spotify" else "lastfm"))
        when (a.status) {
            200 -> { lastfmMissing.value = false; problem.value = null; current.value = MusicShare.relaySong(a.text, now()) }
            503 -> { lastfmMissing.value = true; problem.value = "Last.fm isn’t set up yet."; current.value = null }
            404 -> { problem.value = "Last.fm doesn’t know “$user”."; current.value = null }
            403 -> { problem.value = "Your Last.fm listening is private. Last.fm › Settings › Privacy: show recent listening."; current.value = null }
            else -> {}   // keep what we had
        }
    }
}

/**
 * Listening now: Android shows a music app's media session only to an app with Notification access, which is what
 * this service is for. It reads no notification (nothing is overridden); the system runs it while access is on.
 */
class MusicListener : NotificationListenerService()
