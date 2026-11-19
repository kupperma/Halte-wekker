package nl.haltewekker

import kotlinx.coroutines.runBlocking
import nl.haltewekker.friends.B64u
import nl.haltewekker.friends.FriendJson
import nl.haltewekker.friends.LiveCrypto
import nl.haltewekker.friends.LiveKeys
import nl.haltewekker.friends.LiveRelay
import nl.haltewekker.friends.LiveRules
import nl.haltewekker.friends.LiveState
import nl.haltewekker.friends.LiveWords
import nl.haltewekker.friends.TravelState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * The live check of the live link against https://haltewekker-relay.tsfaw1.workers.dev (skipped unless HW_LIVE_RELAY=1):
 * a throwaway link made by the Android code path (`LiveKeys`, `LiveRules.state`, `LiveCrypto.lock`, `LiveRelay.put`),
 * fetched back as the relay's page fetches it (`GET /live/v1/get?t=<token>`), opened with only what the link holds (the
 * token from its path, the key from its fragment), then ended (`/live/v1/end`: the page then says "This link has ended").
 *
 *   HW_LIVE_RELAY=1 ./gradlew testReleaseUnitTest --tests nl.haltewekker.LiveLinkInteropTest
 */
class LiveLinkInteropTest {
    @Test fun androidLinkOpensFromTheRelayWithTheLinksKey() = runBlocking {
        assumeTrue("set HW_LIVE_RELAY=1 to run against the live relay", System.getenv("HW_LIVE_RELAY") == "1")
        val relay = LiveRelay(userAgent = "Haltewekker-interop-check")
        val keys = LiveKeys.make()
        val now = System.currentTimeMillis() / 1000.0
        val travel = TravelState("riding", "bus", "305", trip = "check-305", from = TravelState.Spot("Veghel"), to = TravelState.Spot("Den Bosch"),
            dest = TravelState.Spot("Breda"), eta = now + 1200, end = now + 4000)
        val state = LiveRules.state(travel, "Interop check", null, 2, now)
        try {
            val put = relay.put(keys, LiveCrypto.lock(state, keys), LiveRules.until(now, now))
            assertTrue("put: $put", put is LiveRelay.Answer.Ok)
            // only what the link gives a browser: the token (path) and the key (fragment)
            val (token, key) = LiveCrypto.parse(keys.link)!!
            val (status, got) = relay.get(token)
            assertEquals(200, status)
            val plain = LiveCrypto.open(B64u.decode(got!!.data)!!, key, token)
            val read = FriendJson.decode(LiveState.serializer(), plain)!!
            assertEquals(state, read)
            assertEquals("Interop check is on bus 305 to Den Bosch", LiveWords.headline(read).substringBefore(" · "))
            println("live link check: ${keys.link.substringBefore('#')} → ${LiveWords.headline(read)}")
        } finally {
            val end = relay.end(keys)
            assertTrue("end: $end", end is LiveRelay.Answer.Ok)
        }
        // ended: the page says so
        val (after, _) = relay.get(keys.token)
        assertTrue("after the end: $after", after == 410 || after == 404)
    }
}
