package nl.haltewekker.friends

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.net.URI
import java.time.Instant
import java.time.format.DateTimeFormatter
import kotlin.math.floor

// Listening now (relay 2026-11-27), the iOS `MusicShare.swift`: when the song you listen to goes to your friends (the
// travel state's `music`) and to a live link (payload v2's `music`), as plain values, tested without the player, the
// relay or the UI against docs/music-vectors.json. Opt-in (off by default), only while you travel, never history: the
// one song playing now, dropped when it's paused or the last look is 10 minutes old.

/** Who sees what you listen to. */
enum class MusicAudience(val raw: String, val title: String) {
    ALL("all", "Friends + live links"), FRIENDS("friends", "Only friends"), LINKS("links", "Only live links");
    companion object { fun of(raw: String?) = entries.firstOrNull { it.raw == raw } ?: ALL }
}

/** Where the song comes from on this phone. */
enum class MusicFrom(val raw: String, val title: String) {
    /** Any music app, read from its media session (Notification access). */
    PLAYER("player", "Music app on this phone"),
    /** Spotify, through your own Last.fm account, read by the relay. */
    SPOTIFY("spotify", "Spotify (via Last.fm)"),
    /** Any app that scrobbles to Last.fm. */
    LASTFM("lastfm", "Last.fm");
    val viaLastfm get() = this != PLAYER
    companion object { fun of(raw: String?) = entries.firstOrNull { it.raw == raw } ?: PLAYER }
}

/** The song playing now, as the phone last saw it (`seen`: unix s, when a look last saw it). */
data class MusicNow(
    val title: String, val artist: String = "", val app: String = "", val url: String? = null, val coverUrl: String? = null,
    val playing: Boolean = true, val seen: Double,
)

object MusicShare {
    /** Older than this (s) and it isn't shown or sent. */
    const val MAX_AGE = 600.0
    /** At most one look this often (s), on the ride's own network tick. */
    const val LOOK_EVERY = 30.0

    enum class Channel { FRIENDS, LINK }

    fun reaches(who: MusicAudience, c: Channel) = when (who) {
        MusicAudience.ALL -> true
        MusicAudience.FRIENDS -> c == Channel.FRIENDS
        MusicAudience.LINKS -> c == Channel.LINK
    }

    /** What `channel` gets now (null: nothing). `travelling`: a trip runs, or a live link is live. */
    fun share(song: MusicNow?, on: Boolean, who: MusicAudience, channel: Channel, travelling: Boolean, now: Double): LiveMusic? {
        if (!on || !travelling || !reaches(who, channel) || song == null || !song.playing) return null
        if (now - song.seen >= MAX_AGE) return null
        val title = LiveTripV2.clean(song.title, 80)
        if (title.isEmpty()) return null
        val artist = LiveTripV2.clean(song.artist, 60)
        val app = LiveTripV2.clean(song.app, 20)
        return LiveMusic(title, artist.ifEmpty { null }, app.ifEmpty { null }, link(song.url), cover(song.coverUrl), iso(song.seen))
    }

    fun lookDue(last: Double?, now: Double): Boolean = last == null || now < last || now - last >= LOOK_EVERY

    /** "2027-01-15T07:59:30Z" (whole seconds, UTC). */
    fun iso(t: Double): String = DateTimeFormatter.ISO_INSTANT.format(Instant.ofEpochSecond(floor(t).toLong()))

    fun parseIso(s: String): Double? = try { Instant.parse(s).epochSecond.toDouble() } catch (_: Exception) { null }

    private fun https(u: String?, ok: (String) -> Boolean): String? {
        if (u == null || u.length > 500) return null
        return try {
            val x = URI(u)
            val h = x.host?.lowercase() ?: return null
            if (x.scheme?.lowercase() == "https" && ok(h)) u else null
        } catch (_: Exception) { null }
    }

    /** A link to the song: only on Spotify, Apple Music or Last.fm. */
    fun link(u: String?) = https(u) { it == "open.spotify.com" || it == "music.apple.com" || it == "www.last.fm" }

    /** A cover: only from Spotify's, Apple's or Last.fm's image hosts. */
    fun cover(u: String?) = https(u) { it == "i.scdn.co" || it.endsWith(".mzstatic.com") || it == "lastfm.freetls.fastly.net" }

    /** Percent-encoding of everything but A–Z, a–z, 0–9 and "-._~" (UTF-8). */
    fun encode(s: String): String = buildString {
        for (b in s.toByteArray(Charsets.UTF_8)) {
            val c = b.toInt() and 0xff
            val ch = c.toChar()
            if (c < 128 && (ch.isLetterOrDigit() || ch == '-' || ch == '.' || ch == '_' || ch == '~')) append(ch)
            else append('%').append("%02X".format(c))
        }
    }

    // MARK: the iTunes Search API (no key): a public cover and Apple Music link for a song

    fun searchUrl(title: String, artist: String): String =
        "https://itunes.apple.com/search?term=${encode(LiveTripV2.clean("$artist $title", 140))}&entity=song&limit=1"

    private fun plain(s: String) = s.lowercase().filter { it.isLetterOrDigit() }

    private fun alike(a: String, b: String): Boolean {
        val x = plain(a)
        val y = plain(b)
        return x.isNotEmpty() && y.isNotEmpty() && (x.contains(y) || y.contains(x))
    }

    /** The first result's cover (300 px) and Apple Music link, when it's this song; null: no such result. */
    fun itunesPick(text: String, title: String, artist: String): Pair<String?, String?>? {
        val j = try { Json.parseToJsonElement(text) as? JsonObject } catch (_: Exception) { null } ?: return null
        val r = ((j["results"] as? JsonArray)?.firstOrNull() as? JsonObject) ?: return null
        fun s(k: String) = (r[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
        val same = if (plain(artist).isEmpty()) alike(title, s("trackName") ?: "") else alike(artist, s("artistName") ?: "")
        if (!same) return null
        val art = s("artworkUrl100")?.replace("100x100bb", "300x300bb")
        val page = s("trackViewUrl")?.let { p ->
            val q = p.indexOf('?')
            if (q < 0) p else {
                val kept = p.substring(q + 1).split('&').filter { it.isNotEmpty() && it.substringBefore('=') != "uo" }
                p.substring(0, q) + if (kept.isEmpty()) "" else "?" + kept.joinToString("&")
            }
        }
        return cover(art) to link(page)
    }

    /** A Spotify search for the song (what "Listen too" opens for a song playing in Spotify). */
    fun spotifySearch(title: String, artist: String) = "https://open.spotify.com/search/" + encode(LiveTripV2.clean("$artist $title", 140))

    /** The app's name from its package, for the apps people play music with (else none). */
    fun appName(pkg: String): String = when (pkg) {
        "com.spotify.music" -> "Spotify"
        "com.apple.android.music" -> "Apple Music"
        "com.google.android.apps.youtube.music" -> "YouTube Music"
        "com.google.android.youtube" -> "YouTube"
        "deezer.android.app" -> "Deezer"
        "com.soundcloud.android" -> "SoundCloud"
        "com.aspiro.tidal" -> "TIDAL"
        "com.amazon.mp3" -> "Amazon Music"
        "com.pandora.android" -> "Pandora"
        "com.bandcamp.android" -> "Bandcamp"
        "nl.nederlandseomroep.nporadio", "nl.npo.radio" -> "NPO Radio"
        else -> ""
    }

    // MARK: the relay's Last.fm answer (/music/v1/now)

    /** The song in the relay's answer (null: nothing playing, or not an answer). `now`: when it came. */
    fun relaySong(text: String, now: Double): MusicNow? {
        val j = try { Json.parseToJsonElement(text) as? JsonObject } catch (_: Exception) { null } ?: return null
        fun s(k: String) = (j[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
        if ((j["nowPlaying"] as? JsonPrimitive)?.content != "true") return null
        val t = s("title")?.takeIf { it.isNotEmpty() } ?: return null
        return MusicNow(t, s("artist") ?: "", s("app") ?: "", s("url"), s("coverUrl"), true, now)
    }

    /** A Last.fm username as typed: 2–15 letters, digits, "_" or "-", starting with a letter. */
    fun validUser(s: String) = Regex("^[A-Za-z][A-Za-z0-9_-]{1,14}$").matches(s.trim())
}
