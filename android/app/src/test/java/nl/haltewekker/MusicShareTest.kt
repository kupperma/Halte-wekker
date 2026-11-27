package nl.haltewekker

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import nl.haltewekker.friends.FriendJson
import nl.haltewekker.friends.LiveMusic
import nl.haltewekker.friends.LiveRules
import nl.haltewekker.friends.LiveState
import nl.haltewekker.friends.LiveTripV2
import nl.haltewekker.friends.MusicAudience
import nl.haltewekker.friends.MusicNow
import nl.haltewekker.friends.MusicShare
import nl.haltewekker.friends.TravelState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Listening now (relay 2026-11-27): when the song goes out, to whom, and how it's written, against
 * docs/music-vectors.json (the vectors iOS and the relay check too).
 */
class MusicShareTest {
    private val v: JsonObject by lazy {
        val f = listOf("../../docs/music-vectors.json", "../docs/music-vectors.json", "docs/music-vectors.json").map(::File).first { it.exists() }
        Json.parseToJsonElement(f.readText()).jsonObject
    }
    private fun JsonObject.s(k: String) = (this[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
    private fun JsonObject.d(k: String) = (this[k] as? JsonPrimitive)?.takeIf { !it.isString }?.content?.toDoubleOrNull()
    private fun JsonObject.b(k: String) = (this[k] as? JsonPrimitive)?.takeIf { !it.isString }?.content?.toBooleanStrictOrNull()
    private fun music(e: Any?): LiveMusic? = (e as? JsonObject)?.let { FriendJson.decode(LiveMusic.serializer(), it) }

    @Test fun theCases() {
        val base = v["base"]!!.jsonObject
        val baseSong = base["song"]!!.jsonObject
        val want = music(v["music"])!!
        val now = v.d("now")!!
        val cases = v["cases"]!!.jsonArray
        assertTrue(cases.size > 10)
        for (e in cases) {
            val c = e.jsonObject
            val name = c.s("case")
            val on = c.b("on") ?: base.b("on")!!
            val who = MusicAudience.of(c.s("who") ?: base.s("who"))
            val travelling = c.b("travelling") ?: base.b("travelling")!!
            val song: MusicNow? = if (c.b("noSong") == true) null else {
                val o = HashMap<String, kotlinx.serialization.json.JsonElement>(baseSong)
                (c["song"] as? JsonObject)?.forEach { (k, x) -> o[k] = x }
                val j = JsonObject(o)
                MusicNow(j.s("title") ?: "", j.s("artist") ?: "", j.s("app") ?: "", j.s("url"), j.s("coverUrl"), j.b("playing") ?: true, j.d("seen") ?: 0.0)
            }
            for ((key, ch) in listOf("friends" to MusicShare.Channel.FRIENDS, "link" to MusicShare.Channel.LINK)) {
                val got = MusicShare.share(song, on, who, ch, travelling, now)
                val x = c[key]
                val expect = if (x is JsonPrimitive && x !is JsonNull && x.content == "true") want else music(x)
                assertEquals("$name: $key", expect, got)
            }
        }
    }

    @Test fun theMusicJSON() {
        val m = music(v["music"])!!
        assertEquals(v.s("musicJSON"), FriendJson.encodeString(LiveMusic.serializer(), m))
        assertEquals(m.at, MusicShare.iso(1_799_999_970.6))
        assertEquals(1_799_999_970.0, MusicShare.parseIso(m.at))
    }

    @Test fun theTravelStateCarriesItAndOldAppsStillRead() {
        val plain = v["travel"]!!.jsonObject.s("plain")!!
        val m = music(v["music"])!!
        val s = TravelState("riding", "bus", "305", from = TravelState.Spot("Veghel, Busstation"), to = TravelState.Spot("Eindhoven Centraal"),
            eta = 1_800_000_960.0, music = m)
        assertEquals(plain, FriendJson.encodeString(TravelState.serializer(), s))
        assertEquals(s, FriendJson.decode(TravelState.serializer(), plain))
        // a state without it reads as before
        assertNull(FriendJson.decode(TravelState.serializer(), """{"from":{"name":"A"},"mode":"bus","state":"riding","to":{"name":"B"}}""")!!.music)
    }

    @Test fun theLiveLinkKeepsItAndAPutFollowsANewSong() {
        val m = music(v["music"])!!
        val a = LiveState(name = "Sam", state = "riding", mode = "bus", t = 1_800_000_000.0)
        val b = a.copy(music = m)
        assertNotEquals(LiveRules.key(a), LiveRules.key(b))
        assertEquals(LiveRules.key(b), LiveRules.key(a.copy(music = m)))
        val built = LiveTripV2.build(b, LiveTripV2.Trip(emptyList(), 0, music = m), 1_800_000_000.0)
        assertEquals(m, built.music)
    }

    @Test fun iTunes() {
        val itn = v["itunes"]!!.jsonObject
        for (e in itn["queries"]!!.jsonArray) {
            val q = e.jsonObject
            assertEquals(q.s("url"), MusicShare.searchUrl(q.s("title")!!, q.s("artist")!!))
        }
        val answer = itn["answer"].toString()
        for (e in itn["picks"]!!.jsonArray) {
            val p = e.jsonObject
            val got = MusicShare.itunesPick(answer, p.s("title")!!, p.s("artist")!!)
            if (p.b("none") == true) assertNull(p.toString(), got)
            else {
                assertEquals(p.s("coverUrl"), got?.first)
                assertEquals(p.s("url"), got?.second)
            }
        }
        assertNull(MusicShare.itunesPick("{\"results\":[]}", "a", "b"))
        assertNull(MusicShare.itunesPick("nope", "a", "b"))
    }

    @Test fun theRelaysAnswer() {
        val r = v["relay"]!!.jsonObject
        val s = MusicShare.relaySong(r["spotify"].toString(), 1_800_000_000.0)!!
        assertEquals("Midnight City", s.title)
        assertEquals("M83", s.artist)
        assertEquals("Spotify", s.app)
        assertEquals("https://open.spotify.com/search/M83%20Midnight%20City", s.url)
        assertEquals(1_800_000_000.0, s.seen, 0.0)
        assertTrue(s.playing)
        assertNull(MusicShare.relaySong(r["idle"].toString(), 1_800_000_000.0))
        assertNull(MusicShare.relaySong("{\"error\":\"not_configured\"}", 1_800_000_000.0))
        // the app's own Spotify search link is the relay's
        assertEquals(s.url, MusicShare.spotifySearch("Midnight City", "M83"))
    }

    @Test fun lookingUsernamesAndApps() {
        val t = 1_800_000_000.0
        assertTrue(MusicShare.lookDue(null, t))
        assertFalse(MusicShare.lookDue(t - 29, t))
        assertTrue(MusicShare.lookDue(t - 30, t))
        assertTrue(MusicShare.lookDue(t + 60, t))
        assertEquals(v.d("lookEvery"), MusicShare.LOOK_EVERY)
        assertEquals(v.d("maxAge"), MusicShare.MAX_AGE)
        assertTrue(MusicShare.validUser("Test_1"))
        assertTrue(MusicShare.validUser(" rj "))
        assertFalse(MusicShare.validUser("a"))
        assertFalse(MusicShare.validUser("1abc"))
        assertFalse(MusicShare.validUser("abc&x=1"))
        assertFalse(MusicShare.validUser("abcdefghijklmnop"))
        assertFalse(MusicShare.reaches(MusicAudience.FRIENDS, MusicShare.Channel.LINK))
        assertFalse(MusicShare.reaches(MusicAudience.LINKS, MusicShare.Channel.FRIENDS))
        assertEquals("Spotify", MusicShare.appName("com.spotify.music"))
        assertEquals("", MusicShare.appName("com.example.notes"))
    }

}
