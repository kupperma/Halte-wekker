package nl.haltewekker

import nl.haltewekker.friends.B64u
import nl.haltewekker.friends.FriendJson
import nl.haltewekker.friends.LiveCrypto
import nl.haltewekker.friends.LiveCryptoException
import nl.haltewekker.friends.LiveKeys
import nl.haltewekker.friends.LiveRules
import nl.haltewekker.friends.LiveState
import nl.haltewekker.friends.LiveWords
import nl.haltewekker.friends.TravelState
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.time.ZoneId

/**
 * Friends 0.30: the live link for people without the app (iOS `FriendLiveTests`): its token, the lock (AES-256-GCM)
 * byte for byte against the spec's vector (Node's crypto; relay/test-live.mjs runs the page's own script on it), the
 * page's words and when the phone posts. The vector passing means the relay's page decrypts links made on Android.
 */
class FriendLiveTest {
    private val t0 = 1_800_000_000.0
    private fun t(s: Int) = t0 + s
    private val ams = ZoneId.of("Europe/Amsterdam")
    private fun bytes(from: Int, count: Int) = ByteArray(count) { (from + it).toByte() }
    private val keys = LiveKeys.of(bytes(0x00, 32), bytes(0x20, 32))

    private val riding = LiveState(name = "Sam", state = "riding", mode = "bus", line = "305", from = "Veghel", to = "Den Bosch", dest = "Breda",
        eta = 1_800_001_260.0, end = 1_800_004_500.0, late = 3, pos = LiveState.Position(51.61672, 5.54861, 1_799_999_990.0), t = t0)

    @Test fun tokenAndLink() {
        assertEquals(TOKEN, keys.token)
        assertEquals(LINK, keys.link)
        val p = LiveCrypto.parse(LINK)!!
        assertEquals(TOKEN, p.first)
        assertArrayEquals(bytes(0x20, 32), p.second)
        assertNull(LiveCrypto.parse("https://haltewekker-relay.tsfaw1.workers.dev/live/2x1Ot-EFfLIivv_lmStBuw"))
        assertNull(LiveCrypto.parse("https://example.com/live/2x1Ot-EFfLIivv_lmStBuw#ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8"))
        val fresh = LiveKeys.make()
        assertEquals(32, fresh.secretBytes.size)
        assertEquals(32, fresh.keyBytes.size)
        assertFalse(fresh.secretBytes.contentEquals(fresh.keyBytes))
        assertEquals(22, fresh.token.length)
    }

    @Test fun lockVector() {
        val json = FriendJson.encode(LiveState.serializer(), riding)
        assertEquals(PLAIN, String(json, Charsets.UTF_8))
        val sealed = LiveCrypto.seal(json, keys.keyBytes, keys.token, bytes(0x40, 12))
        assertEquals(DATA, B64u.encode(sealed))
        val opened = LiveCrypto.open(B64u.decode(DATA)!!, keys.keyBytes, keys.token)
        assertEquals(riding, FriendJson.decode(LiveState.serializer(), opened))
        try { LiveCrypto.open(sealed, keys.keyBytes, "AAAAAAAAAAAAAAAAAAAAAA"); fail("another token opened it") } catch (_: LiveCryptoException) {}
        try { LiveCrypto.open(sealed, bytes(0x60, 32), keys.token); fail("another key opened it") } catch (_: LiveCryptoException) {}
        assertNotEquals(B64u.encode(LiveCrypto.lock(riding, keys)), B64u.encode(LiveCrypto.lock(riding, keys)))
    }

    @Test fun words() {
        assertEquals("Sam is on bus 305 to Den Bosch · arrives 09:21 · 3 min late", LiveWords.headline(riding, ams))
        assertEquals("Then on to Breda · there around 10:15", LiveWords.detail(riding, ams))
        assertEquals("Sam is on bus 305 to Den Bosch · arrives 09:21 · on time", LiveWords.headline(riding.copy(late = 0), ams))
        var s = LiveState(name = "Sam", state = "waiting", mode = "train", line = "IC", num = "3512", from = "Eindhoven Centraal", to = "Breda", dep = 1_800_001_260.0, t = t0)
        assertEquals("Sam is waiting for the IC 3512 to Breda at Eindhoven Centraal · leaves 09:21", LiveWords.headline(s, ams))
        assertNull(LiveWords.detail(s, ams))
        s = s.copy(state = "change")
        assertEquals("Sam is changing at Eindhoven Centraal · then the IC 3512 to Breda at 09:21", LiveWords.headline(s, ams))
        assertEquals("Sam is changing at Eindhoven Centraal", LiveWords.headline(s.copy(line = null), ams))
        s = LiveState(name = "Sam", state = "arrived", mode = "bus", line = "305", to = "Den Bosch", dest = "Breda", eta = t(120), t = t(120))
        assertEquals("Sam has arrived at Den Bosch · 09:02", LiveWords.headline(s, ams))
        assertNull(LiveWords.detail(s, ams))
        assertEquals("Your friend is on the train", LiveWords.headline(LiveState(name = " ", state = "flying", mode = "train", t = t0), ams))
        assertEquals("the bus", LiveWords.vehicle(LiveState(name = "", state = "riding", mode = "bus", t = t0)))
        assertEquals("tram 1", LiveWords.vehicle(LiveState(name = "", state = "riding", mode = "tram", line = "1", t = t0)))
        assertEquals("the SPR", LiveWords.vehicle(LiveState(name = "", state = "riding", mode = "train", line = "SPR", t = t0)))
    }

    @Test fun rules() {
        assertTrue(LiveRules.due(null, "", "a", t0))
        assertFalse(LiveRules.due(t0, "a", "a", t(30)))
        assertTrue(LiveRules.due(t0, "a", "a", t(55)))
        assertFalse(LiveRules.due(t0, "a", "b", t(3)))
        assertTrue(LiveRules.due(t0, "a", "b", t(6)))
        assertEquals(t(600 + 1800), LiveRules.until(t0, t(600)), 0.0)
        assertEquals(t(4 * 3600), LiveRules.until(t0, t(4 * 3600 - 60)), 0.0)
        assertEquals(t(600 + 900), LiveRules.until(t0, t(600), arrived = true), 0.0)
        assertFalse(LiveRules.expired(t0, t(4 * 3600 - 1)))
        assertTrue(LiveRules.expired(t0, t(4 * 3600)))
        assertEquals(3, LiveRules.late(t(300), t(120)))
        assertEquals(0, LiveRules.late(t(60), t(120)))
        assertNull(LiveRules.late(null, t(120)))
    }

    @Test fun fromTravel() {
        var tr = TravelState("riding", "bus", "305", trip = "bus-305", from = TravelState.Spot("Veghel", 51.6, 5.5), to = TravelState.Spot("Den Bosch", 51.69, 5.29),
            dest = TravelState.Spot("Breda"), eta = 1_800_001_260.0, end = 1_800_004_500.0, pos = TravelState.Position(51.61672, 5.54861, 12.0, 1_799_999_990.0),
            coach = TravelState.Coach(3, 6, true))
        assertEquals("names only, no accuracy, no coach, no dep while riding", riding, LiveRules.state(tr, " Sam ", t(-60), 3, t0))
        tr = tr.copy(state = "waiting")
        val w = LiveRules.state(tr, "Sam", t(300), null, t0)
        assertEquals(t(300), w.dep!!, 0.0)
        assertNull(w.late)
        assertNull(LiveRules.state(tr.copy(dest = TravelState.Spot("Den Bosch")), "Sam", null, null, t0).dest)
        val a = LiveRules.arrived(riding, "Sam", "Breda", t(4000))
        assertEquals(LiveState(name = "Sam", state = "arrived", mode = "bus", line = "305", from = "Veghel", to = "Breda", eta = t(4000), t = t(4000)), a)
        assertNotEquals(LiveRules.key(riding), LiveRules.key(w))
    }

    companion object {
        const val TOKEN = "2x1Ot-EFfLIivv_lmStBuw"
        const val LINK = "https://haltewekker-relay.tsfaw1.workers.dev/live/2x1Ot-EFfLIivv_lmStBuw#ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8"
        const val PLAIN = """{"dest":"Breda","end":1800004500,"eta":1800001260,"from":"Veghel","late":3,"line":"305","mode":"bus","name":"Sam","pos":{"at":1799999990,"lat":51.61672,"lon":5.54861},"state":"riding","t":1800000000,"to":"Den Bosch","v":1}"""
        const val DATA = "AUBBQkNERUZHSElKS7l22eQjAucxcHAiTeErc14x6_Pn13qW5l7OpDBU3_8y5jF6alf-mxd1pw20reGB2e60y1bPhb3fRMafBUHNMX0XzIrkdFdZINAvfQZc6wgCKn4B3YWG2r9jXEn0RXpeVbJnZrAQ2fH-jvvebSMWbiXub8wm-a4kw_nwp59f9VyUkXutBMfsSHUt3Agu3YlcN2wqOLT2L2x4rrqImgvKvsoulSwMAdncswKlNM9vKwSvq3RIztNMa-KL1guHyZLcJ5KPVhXxLPpZVMixIoV0J937rVtJ9dYWTJ1LJ0lsBKOwV_k08p4uVV-3ue-8vAw"
    }
}
