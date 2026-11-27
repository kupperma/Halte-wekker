package nl.haltewekker

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.core.Polyline
import nl.haltewekker.data.DoorTrip
import nl.haltewekker.data.Ride
import nl.haltewekker.friends.B64u
import nl.haltewekker.friends.FriendJson
import nl.haltewekker.friends.Hex
import nl.haltewekker.friends.LiveCrypto
import nl.haltewekker.friends.LiveKeys
import nl.haltewekker.friends.LiveMessage
import nl.haltewekker.friends.LiveMessages
import nl.haltewekker.friends.LiveMusic
import nl.haltewekker.friends.LiveNames
import nl.haltewekker.friends.LiveReply
import nl.haltewekker.friends.LiveState
import nl.haltewekker.friends.LiveTripV2
import nl.haltewekker.friends.TravelState
import nl.haltewekker.ride.SavedRide
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Live link payload v2 and messages (relay 2026-11-27): byte for byte against docs/live-link-vectors.json, the vector the
 * live page's own script (relay/test-live.mjs) and iOS (LiveTripV2Tests.swift) check too.
 */
class LiveTripV2Test {
    private val vec: JsonObject by lazy {
        val f = listOf("../../docs/live-link-vectors.json", "../docs/live-link-vectors.json", "docs/live-link-vectors.json").map(::File).first { it.exists() }
        Json.parseToJsonElement(f.readText()).jsonObject
    }
    private fun JsonObject.s(k: String) = (this[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
    private fun JsonObject.d(k: String) = (this[k] as? JsonPrimitive)?.content?.toDoubleOrNull()
    private fun JsonObject.i(k: String) = (this[k] as? JsonPrimitive)?.content?.toIntOrNull()
    private val keyBytes get() = B64u.decode(vec.s("key")!!)!!
    private val token get() = vec.s("token")!!

    private fun input(): Triple<LiveState, LiveTripV2.Trip, Double> {
        val inp = vec["input"]!!.jsonObject
        val now = inp.d("now")!!
        val base = FriendJson.decode(LiveState.serializer(), inp["base"]!!)!!
        val t = inp["trip"]!!.jsonObject
        val legs = t["legs"]!!.jsonArray.map { e ->
            val l = e.jsonObject
            LiveTripV2.LegIn(l.s("mode")!!, l.s("line"), l.s("num"), l.s("from")!!, l.s("to")!!, l.d("dep"), l.d("arr"), l.s("depPlatform"), l.s("arrPlatform"),
                l.i("coach"), l.s("deck"), l.i("late"), l.i("mins"))
        }
        val stops = t["stops"]!!.jsonArray.map { e -> val x = e.jsonObject; LiveTripV2.StopIn(x.s("name")!!, x.d("lat")!!, x.d("lon")!!, x.d("t")) }
        val shape = t["shape"]!!.jsonArray.map { e -> val a = e.jsonArray; GeoPoint(a[0].jsonPrimitive.content.toDouble(), a[1].jsonPrimitive.content.toDouble()) }
        val v = t["vehicle"]!!.jsonObject
        val music = FriendJson.decode(LiveMusic.serializer(), t["music"]!!)
        return Triple(base, LiveTripV2.Trip(legs, t.i("leg")!!, stops, shape, LiveTripV2.Vehicle(v.d("lat")!!, v.d("lon")!!, v.d("at")!!), t.s("face"),
            (t["inbox"] as JsonPrimitive).content == "true", music), now)
    }

    @Test fun payloadV2ByteForByte() {
        val (base, trip, now) = input()
        val s = LiveTripV2.build(base, trip, now)
        val plain = vec["state"]!!.jsonObject
        assertEquals(plain.s("plain"), String(FriendJson.encode(LiveState.serializer(), s), Charsets.UTF_8))
        val keys = LiveKeys(vec.s("secret")!!, vec.s("key")!!)
        assertEquals(token, keys.token)
        val sealed = LiveCrypto.seal(FriendJson.encode(LiveState.serializer(), s), keyBytes, token, Hex.decode(plain.s("nonce")!!)!!)
        assertEquals(plain.s("data"), B64u.encode(sealed))
        // and back: what the page reads
        val back = FriendJson.decode(LiveState.serializer(), LiveCrypto.open(sealed, keyBytes, token))!!
        assertEquals(2, back.v)
        assertEquals(5, back.legs!!.size)
        assertEquals("gps", back.pos!!.src)
        assertEquals(3, back.next)
        assertEquals("Eindhoven Centraal", back.stops!!.last().name)
        // the v1 fields stay for a page before v2
        assertEquals("Sam is on bus 305 to Eindhoven Centraal", nl.haltewekker.friends.LiveWords.headline(back).substringBefore(" · "))
        assertEquals(vec["page"]!!.jsonObject.i("shapePoints"), Polyline.decode(back.shape!!).size)
    }

    @Test fun messagesOpenAndSealByteForByte() {
        for ((name, kind) in listOf("message" to LiveMessages.MSG, "appMessage" to LiveMessages.MSG, "reply" to LiveMessages.REPLY)) {
            val x = vec[name]!!.jsonObject
            val data = B64u.decode(x.s("data")!!)!!
            assertEquals(name, x.s("plain"), String(LiveCrypto.openAs(kind, data, keyBytes, token), Charsets.UTF_8))
            assertEquals(name, x.s("data"), B64u.encode(LiveCrypto.sealAs(kind, x.s("plain")!!.toByteArray(), keyBytes, token, Hex.decode(x.s("nonce")!!)!!)))
        }
        val web = LiveMessages.open(B64u.decode(vec["message"]!!.jsonObject.s("data")!!)!!, keyBytes, token)!!
        assertEquals(LiveMessage("Kim", "web", null, "👋 On my way", 1800000030.0), web)
        val app = LiveMessages.open(B64u.decode(vec["appMessage"]!!.jsonObject.s("data")!!)!!, keyBytes, token)!!
        assertEquals("app", app.fromKind)
        assertEquals("3c157621a97cf055f5804a9826c6d1e1", app.friendId)
        assertEquals("💬 Lou (friend): I’m at the station", LiveMessages.notice(app) { id -> if (id == app.friendId) "Lou (friend)" else null })
        assertEquals("💬 Kim: 👋 On my way", LiveMessages.notice(web) { null })
        assertEquals("💬 Someone with your link: Hi", LiveMessages.notice(LiveMessage(text = "Hi", at = 1.0)) { null })
        // a message isn't a trip state (another AAD), nor an answer
        val msgData = B64u.decode(vec["message"]!!.jsonObject.s("data")!!)!!
        assertTrue(runCatching { LiveCrypto.open(msgData, keyBytes, token) }.isFailure)
        assertNull(LiveMessages.openReply(msgData, keyBytes, token))
        assertEquals(LiveReply("See you there", 1800000060.0, 1), LiveMessages.openReply(B64u.decode(vec["reply"]!!.jsonObject.s("data")!!)!!, keyBytes, token))
        // sent from this app: its name and account; read back the same
        val mine = LiveMessage("Lou", "app", "3c157621a97cf055f5804a9826c6d1e1", "I’m at the station", 1800000040.0)
        assertEquals(mine, LiveMessages.open(LiveMessages.seal(mine, keyBytes, token), keyBytes, token))
    }

    @Test fun messagesAreCleaned() {
        assertNull(LiveMessages.valid(LiveMessage(text = "  \n ", at = 1.0)))
        val long = LiveMessages.valid(LiveMessage(from = "K\u0007im", text = "x".repeat(400), at = 1.5))!!
        assertEquals(280, long.text.length)
        assertEquals("Kim", long.from)
        assertEquals(1.0, long.at, 0.0)
        // a web message can't claim a friend; an id must be an account id
        assertNull(LiveMessages.valid(LiveMessage("Kim", "web", "3c157621a97cf055f5804a9826c6d1e1", "hi", 1.0))!!.friendId)
        assertNull(LiveMessages.valid(LiveMessage("Kim", "app", "not-an-id", "hi", 1.0))!!.friendId)
        assertEquals("web", LiveMessages.valid(LiveMessage("Kim", "robot", null, "hi", 1.0))!!.fromKind)
        assertEquals(4, LiveMessages.chips.size)
    }

    @Test fun links() {
        val key = B64u.decode(vec.s("key")!!)!!
        assertEquals(token, LiveCrypto.parse(vec.s("link")!!)!!.first)
        assertEquals(token, LiveCrypto.parse(vec.s("appLink")!!)!!.first)
        assertTrue(LiveCrypto.parse(vec.s("appLink")!!)!!.second.contentEquals(key))
        assertTrue(LiveCrypto.parse("  " + vec.s("appLink") + "\n")!!.second.contentEquals(key))
        assertNull(LiveCrypto.parse("haltewekker://live/$token"))
        assertNull(LiveCrypto.parse("haltewekker://friend?v=1&k=x"))
        assertNull(LiveCrypto.parse("haltewekker://live/short#k=${B64u.encode(key)}"))
        assertNull(LiveCrypto.parse("https://example.com/live/$token#k=${B64u.encode(key)}"))
    }

    @Test fun theNameIsYours() {
        assertEquals("Sam", LiveNames.sender("Sam", "Kim"))
        assertEquals("Kim", LiveNames.sender("", " Kim "))
        assertEquals("Kim", LiveNames.sender(null, "Kim"))
        assertEquals("", LiveNames.sender(null, null))       // the page says "Your friend"
        // nothing in the builder brings a name of its own
        val (base, trip, now) = input()
        val s = LiveTripV2.build(base.copy(name = "Robin"), trip, now)
        assertEquals("Robin", s.name)
        assertTrue(!String(FriendJson.encode(LiveState.serializer(), s)).contains(nl.haltewekker.logs.Maker.NAME))
    }

    @Test fun roadAndBudget() {
        // a long straight road thins to its two ends; a winding one to at most 200 points
        val straight = (0..500).map { GeoPoint(51.0 + it * 0.0001, 5.0) }
        val stops = listOf(LiveTripV2.StopIn("A", 51.0, 5.0), LiveTripV2.StopIn("B", 51.05, 5.0))
        assertEquals(2, Polyline.decode(LiveTripV2.road(straight, stops)!!).size)
        val wiggly = (0..3000).map { GeoPoint(51.0 + it * 0.00002, 5.0 + (if (it % 2 == 0) 0.001 else -0.001) * (it % 7)) }
        val w = Polyline.decode(LiveTripV2.road(wiggly, listOf(LiveTripV2.StopIn("A", 51.0, 5.0), LiveTripV2.StopIn("B", 51.06, 5.0)))!!)
        assertTrue(w.size in 2..200)
        // no road: straight between the stops
        assertEquals(2, Polyline.decode(LiveTripV2.road(emptyList(), stops)!!).size)
        assertNull(LiveTripV2.road(emptyList(), stops.take(1)))
        // over the budget: the road goes first, then the stops
        val (base, trip, now) = input()
        val many = (0..59).map { LiveTripV2.StopIn("A stop with a rather long name number $it", 51.0 + it * 0.001, 5.0, now + it * 60) }
        val s = LiveTripV2.build(base, trip.copy(stops = many, shape = wiggly), now)
        assertTrue(LiveTripV2.bytes(s) <= LiveTripV2.BUDGET)
        assertEquals(60, s.stops!!.size)
        // a 0.30 reader: v1's fields only
        assertEquals("riding", s.state)
        assertEquals(1800000960.0, s.eta!!, 0.0)
        assertEquals("E0632E", LiveTripV2.color("bus", "305"))
        assertEquals("0A93B5", LiveTripV2.color("train", "SPR"))
        assertEquals("3B44B0", LiveTripV2.color("train", "IC"))
        assertNull(LiveTripV2.color("walk", null))
    }

    @Test fun fromTheRide() {
        val now = 1_800_000_000.0
        fun ride(id: String, line: String, train: Boolean, from: String, to: String, dep: Double, arr: Double, walk: Int = 0, plat: String? = null) =
            Ride(id, line, line, train, dep, dep, arr, arr, from, "s:$from", to, platform = plat, walkBefore = walk,
                fromLat = 51.6, fromLon = 5.5, toLat = 51.45, toLon = 5.48)
        val trip = DoorTrip(listOf(
            ride("b305", "305", false, "Veghel, Busstation", "Eindhoven Centraal", now - 300, now + 900),
            ride("ic", "IC", true, "Eindhoven Centraal", "Breda", now + 1500, now + 3800, walk = 4, plat = "4"),
        ), now - 600, now + 4100)
        val saved = SavedRide("b305", "305", "Eindhoven", false, true, "BUS", now, listOf(
            SavedRide.Stop("Uden", 51.66, 5.62, now - 900, now - 900),
            SavedRide.Stop("Veghel, Busstation", 51.6, 5.5, now - 300, now - 300),
            SavedRide.Stop("Son", 51.52, 5.49, now + 400, now + 400),
            SavedRide.Stop("Eindhoven Centraal", 51.45, 5.48, now + 900, now + 900),
        ), listOf(GeoPoint(51.66, 5.62), GeoPoint(51.6, 5.5), GeoPoint(51.52, 5.49), GeoPoint(51.45, 5.48)))
        val coach = "ic" to TravelState.Coach(3, 6, true, seat = TravelState.Seat("upper", 4, 11))
        val t = LiveTripV2.fromRide(trip, 0, "Campus", now + 960, saved, null, coach, "3DD598", now)
        assertEquals(listOf("bus", "walk", "train", "walk"), t.legs.map { it.mode })
        assertEquals(0, t.leg)
        assertEquals(now + 960, t.legs[0].arr!!, 0.0)
        assertEquals(4, t.legs[1].mins)
        assertEquals("4", t.legs[2].depPlatform)
        assertEquals(3, t.legs[2].coach)
        assertEquals("upper", t.legs[2].deck)
        assertEquals("Campus", t.legs[3].to)
        assertEquals(listOf("Veghel, Busstation", "Son", "Eindhoven Centraal"), t.stops.map { it.name })
        assertEquals(2, LiveTripV2.fromRide(trip, 1, "Campus", null, null, null, null, null, now).leg)
        assertEquals("0E7A55", LiveTripV2.face(null))
        assertNotNull(LiveTripV2.face("3c157621a97cf055f5804a9826c6d1e1"))
    }

    // MARK: (0.10.6) each leg's own road, the picture

    private fun input2(): Triple<LiveState, LiveTripV2.Trip, Double> {
        val inp = vec["input2"]!!.jsonObject
        val base = FriendJson.decode(LiveState.serializer(), inp["base"]!!)!!
        val t = inp["trip"]!!.jsonObject
        fun pt(e: kotlinx.serialization.json.JsonElement?) = (e as? JsonArray)?.let { GeoPoint(it[0].jsonPrimitive.content.toDouble(), it[1].jsonPrimitive.content.toDouble()) }
        val legs = t["legs"]!!.jsonArray.map { e ->
            val l = e.jsonObject
            LiveTripV2.LegIn(l.s("mode")!!, l.s("line"), l.s("num"), l.s("from")!!, l.s("to")!!, l.d("dep"), l.d("arr"), l.s("depPlatform"), l.s("arrPlatform"),
                l.i("coach"), l.s("deck"), l.i("late"), l.i("mins"), pt(l["fromPt"]), pt(l["toPt"]), (l["road"] as? JsonArray)?.mapNotNull { pt(it) } ?: emptyList())
        }
        return Triple(base, LiveTripV2.Trip(legs, t.i("leg")!!, face = t.s("face"), inbox = true, pic = t.i("pic")), inp.d("now")!!)
    }

    @Test fun legRoadsByteForByte() {
        val (base, trip, now) = input2()
        val s = LiveTripV2.build(base, trip, now)
        val json = String(FriendJson.encode(LiveState.serializer(), s), Charsets.UTF_8)
        val x = vec["state2"]!!.jsonObject
        val sealed = LiveCrypto.seal(FriendJson.encode(LiveState.serializer(), s), keyBytes, token, Hex.decode(x.s("nonce")!!)!!)
        assertEquals(x.s("plain"), json)
        assertEquals(x.s("data"), B64u.encode(sealed))
        val legs = s.legs!!
        assertNull("before the walk: none", legs[0].shape)
        assertEquals(2, Polyline.decode(legs[1].shape!!).size)
        val ic = Polyline.decode(legs[2].shape!!)
        assertTrue(ic.size in 3..LiveTripV2.MAX_LEG_SHAPE)
        assertEquals(51.44306, ic.first().lat, 1e-9)
        assertEquals(4.78, ic.last().lon, 1e-9)
        assertTrue(Polyline.decode(legs[3].shape!!).size > 2)
        assertEquals(2, Polyline.decode(legs[4].shape!!).size)
        assertEquals(2, s.pic)
        assertEquals("phone", s.pos!!.src)
        assertNull(s.shape)
        assertNull(s.stops)
        // with a road of its own the current ride sends none; a third ride ahead only its two ends
        val own = LiveTripV2.build(base, trip.copy(stops = listOf(LiveTripV2.StopIn("A", 51.44, 5.47), LiveTripV2.StopIn("B", 51.59, 4.78))), now)
        assertNull(own.legs!![2].shape)
        assertTrue(Polyline.decode(own.legs!![3].shape!!).size > 2)
        // the key changes with the picture
        assertTrue(nl.haltewekker.friends.LiveRules.key(s) != nl.haltewekker.friends.LiveRules.key(s.copy(pic = 3)))
    }

    @Test fun faceByteForByte() {
        val f = vec["face"]!!.jsonObject
        val jpeg = B64u.decode(f.s("plain")!!)!!
        val sealed = nl.haltewekker.friends.LiveFace.seal(jpeg, keyBytes, token, Hex.decode(f.s("nonce")!!)!!)
        assertEquals(f.s("data"), B64u.encode(sealed))
        assertTrue(jpeg.contentEquals(nl.haltewekker.friends.LiveFace.open(sealed, keyBytes, token)))
        // its own AAD: not a trip state, not a message
        assertTrue(runCatching { LiveCrypto.open(sealed, keyBytes, token) }.isFailure)
        assertTrue(runCatching { LiveCrypto.openAs(LiveMessages.MSG, sealed, keyBytes, token) }.isFailure)
        assertTrue(runCatching { nl.haltewekker.friends.LiveFace.open(B64u.decode(vec["state"]!!.jsonObject.s("data")!!)!!, keyBytes, token) }.isFailure)
        // put when there's a picture the relay doesn't have; a failed try waits a minute
        val st = nl.haltewekker.friends.LiveFace.stamp(jpeg)
        assertEquals(32, st.length)
        assertEquals("", nl.haltewekker.friends.LiveFace.stamp(null))
        assertTrue(nl.haltewekker.friends.LiveFace.due(st, "", null, 100.0))
        assertTrue(!nl.haltewekker.friends.LiveFace.due(st, st, null, 100.0))
        assertTrue(!nl.haltewekker.friends.LiveFace.due("", "", null, 100.0))
        assertTrue(!nl.haltewekker.friends.LiveFace.due(st, "", 70.0, 100.0))
        assertTrue(nl.haltewekker.friends.LiveFace.due(st, "", 40.0, 100.0))
    }
}
