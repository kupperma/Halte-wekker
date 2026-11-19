package nl.haltewekker

import kotlinx.serialization.Serializable
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.friends.CoachMap
import nl.haltewekker.friends.FriendBox
import nl.haltewekker.friends.FriendIdentity
import nl.haltewekker.friends.FriendJson
import nl.haltewekker.friends.FriendMessage
import nl.haltewekker.friends.Hex
import nl.haltewekker.friends.MapFrame
import nl.haltewekker.friends.NSTrains
import nl.haltewekker.friends.SeatMap
import nl.haltewekker.friends.TravelState
import nl.haltewekker.friends.TravelWords
import nl.haltewekker.friends.TripCard
import nl.haltewekker.friends.TripTake
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.ZoneId
import kotlin.math.cos

/**
 * A5 (iOS 0.31): the seat (deck and window) in the travel state, the train's decks from NS's types, the window numbers,
 * the words, and what the friend's map frames (docs/superpowers/specs/2026-11-18-friends-design.md, "As built (0.31)").
 * The same cases as the iOS app's SeatMapTests.
 */
class SeatMapTest {
    private val sam = FriendIdentity(Hex.decode("000102030405060708090a0b0c0d0e0f")!!)
    private val utc: ZoneId = ZoneId.of("UTC")

    /** 0.26's vector state, with a seat in the coach. */
    private fun vectorState() = TravelState(
        state = "riding", mode = "train", line = "IC", num = "3512", trip = "vector-trip-3512",
        from = TravelState.Spot("Eindhoven Centraal", 51.44306, 5.47917), to = TravelState.Spot("Breda", 51.59556, 4.78),
        eta = 1_800_003_780.0, end = 1_800_004_200.0, pos = TravelState.Position(51.5112, 5.2874, 12.0, 1_799_999_990.0),
        leg = 2, legs = 2, coach = TravelState.Coach(3, 6, true, "EHV", TravelState.Seat("upper", 8, 11)),
    )

    companion object {
        const val PAYLOAD = """{"b":{"coach":{"at":"EHV","front":true,"n":3,"of":6,"seat":{"deck":"upper","of":11,"w":8}},"end":1800004200,"eta":1800003780,"from":{"lat":51.44306,"lon":5.47917,"name":"Eindhoven Centraal"},"leg":2,"legs":2,"line":"IC","mode":"train","num":"3512","pos":{"acc":12,"at":1799999990,"lat":51.5112,"lon":5.2874},"state":"riding","to":{"lat":51.59556,"lon":4.78,"name":"Breda"},"trip":"vector-trip-3512"},"f":"3c157621a97cf055f5804a9826c6d1e1","k":"travel","n":"vector-31","t":1800000000,"v":1}"""
    }

    // MARK: the box

    @Test fun seatVectorByteForByte() {
        val p = FriendBox.payload(FriendMessage.Travel(vectorState()), sam.account, 1_800_000_000, "vector-31")
        assertEquals(PAYLOAD, p.toString(Charsets.UTF_8))
        val (h, m) = FriendBox.parse(PAYLOAD.toByteArray())
        assertEquals("travel", h.k)
        val s = (m as FriendMessage.Travel).state
        assertEquals(TravelState.Seat("upper", 8, 11), s.coach?.seat)
        assertEquals("Coach 3 of 6 · upper deck · 8th window from the back", SeatMap.label(s.coach!!))
        // and back out of the parsed box, byte for byte
        assertEquals(PAYLOAD, FriendBox.payload(m, h.f, h.t, h.n).toString(Charsets.UTF_8))
    }

    /** 0.26–0.30's coach (and A3/A4's), as an older app reads it: the seat is skipped. */
    @Serializable private data class OldCoach(val n: Int, val of: Int, val front: Boolean, val at: String? = null)
    @Serializable private data class OldState(val coach: OldCoach? = null)

    @Test fun olderAppsIgnoreTheSeat_andNoSeatIsLeftOut() {
        val j = """{"coach":{"at":"EHV","front":true,"n":3,"of":6,"seat":{"deck":"upper","of":11,"w":8}}}"""
        assertEquals(OldCoach(3, 6, true, "EHV"), FriendJson.decode(OldState.serializer(), j)?.coach)
        // the whole vector read as 0.26's: coach 3 of 6 from the front, the seat skipped
        val old = FriendJson.decode(OldState.serializer(), (FriendJson.parse(PAYLOAD.toByteArray()) as JsonObject)["b"]!!)
        assertEquals(OldCoach(3, 6, true, "EHV"), old?.coach)
        // without a seat the coach is 0.26's, byte for byte
        val c = TravelState.Coach(3, 6, true, "EHV")
        assertEquals("""{"at":"EHV","front":true,"n":3,"of":6}""", FriendJson.encodeString(TravelState.Coach.serializer(), c))
        // an old coach reads with no seat
        val back = FriendJson.decode(TravelState.Coach.serializer(), """{"front":false,"n":2,"of":4}""")
        assertNotNull(back)
        assertNull(back!!.seat)
        // a newer deck reads as one deck; a window outside the coach is dropped
        assertEquals(SeatMap.Deck.NONE, SeatMap.deck(TravelState.Seat("middle", 3, 11)))
        assertNull(SeatMap.valid(TravelState.Seat("upper", 12, 11)))
        assertNull(SeatMap.valid(TravelState.Seat("upper", 0, 11)))
        assertNull(SeatMap.valid(TravelState.Seat("upper", 3, 41)))
        assertEquals("Coach 3 of 6 · front", SeatMap.label(TravelState.Coach(3, 6, true, null, TravelState.Seat("upper", 0, 11))))
        // a seat missing one of its three fields: the box doesn't read (as on iOS, all three are required)
        assertNull(FriendJson.decode(TravelState.Coach.serializer(), """{"front":true,"n":3,"of":6,"seat":{"deck":"upper","w":8}}"""))
    }

    // MARK: the train

    @Test fun decksFromNSTypes() {
        assertEquals(true, SeatMap.doubleDeck("VIRM-6"))
        assertEquals(true, SeatMap.doubleDeck("virmm1_4"))
        assertEquals(true, SeatMap.doubleDeck("DDZ-4"))
        assertEquals(false, SeatMap.doubleDeck("SNG-3"))
        assertEquals(false, SeatMap.doubleDeck("SLT_6"))
        assertEquals(false, SeatMap.doubleDeck("nsr_flirt_4"))
        assertEquals("the Koploper has one deck", false, SeatMap.doubleDeck("ICM-4"))
        assertEquals(false, SeatMap.doubleDeck("ICNG-8"))
        assertNull(SeatMap.doubleDeck(""))
        assertNull(SeatMap.doubleDeck("XYZ-9"))
        assertTrue(SeatMap.defaultDouble("IC"))
        assertTrue(SeatMap.defaultDouble("ICD"))
        assertFalse(SeatMap.defaultDouble("SPR"))
        assertFalse(SeatMap.defaultDouble(null))
    }

    @Test fun trainFromNSDrawing() {
        // a VIRM of 4 and an SLT of 4 (coaches listed), the front drawn on the left
        val units = listOf(CoachMap.Unit(0.0, 0.5, 4), CoachMap.Unit(0.5, 0.5, 4))
        val t = SeatMap.train(units, listOf("VIRM-4", "SLT-4"), 8, "left", "IC")
        assertTrue(t.fromNS)
        assertEquals(8, t.count)
        assertEquals(listOf(true, true, true, true, false, false, false, false), t.coaches.map { it.double })
        assertEquals(listOf(1, 2, 3, 4, 5, 6, 7, 8), t.coaches.map { it.n })
        assertTrue(t.coaches.all { it.front })
        // the front on the right: numbered from the right
        val r = SeatMap.train(units, listOf("VIRM-4", "SLT-4"), 8, "right", "IC")
        assertEquals(listOf(8, 7, 6, 5, 4, 3, 2, 1), r.coaches.map { it.n })
        // no direction: from the left, not "from the front"
        val u = SeatMap.train(units, emptyList(), 8, null, "SPR")
        assertEquals(listOf(1, 2, 3, 4, 5, 6, 7, 8), u.coaches.map { it.n })
        assertFalse(u.coaches.any { it.front })
        assertFalse("no types: a Sprinter's single deck", u.anyDouble)
    }

    @Test fun trainWithoutNS() {
        // NS's length only (or nothing): its count (or 6), the front on the right; decks by the line
        val ic = SeatMap.train(emptyList(), emptyList(), 0, null, "IC")
        assertFalse(ic.fromNS)
        assertEquals(6, ic.count)
        assertEquals("right", ic.dir)
        assertEquals(listOf(6, 5, 4, 3, 2, 1), ic.coaches.map { it.n })
        assertTrue(ic.coaches.all { it.double && it.front })
        val spr = SeatMap.train(emptyList(), emptyList(), 4, null, "SPR")
        assertEquals(4, spr.count)
        assertFalse(spr.anyDouble)
        // at most 16 drawn
        assertEquals(16, SeatMap.train(emptyList(), emptyList(), 30, null, "IC").count)
    }

    /** NS's `/ns/train` answer: each unit's type (else its drawing's name) for the decks. */
    @Test fun unitKindsFromNS() {
        val j = """{"lengte":8,"lengteInPixels":800,"rijrichting":"RECHTS","materieeldelen":[
            {"type":"VIRM-4","breedte":400,"bakken":[{},{},{},{}],"afbeelding":"https://x/virm_4.png"},
            {"breedte":400,"bakken":[{},{},{},{}],"afbeelding":"https://x/slt_4.png"}]}"""
        val d = NSTrains.parse(FriendJson.parse(j.toByteArray()) as JsonObject)!!
        assertEquals(listOf("VIRM-4", "slt_4"), d.kinds)
        val t = SeatMap.train(d.units, d.kinds, d.cars, d.dir, "IC")
        assertEquals(listOf(true, true, true, true, false, false, false, false), t.coaches.map { it.double })
        assertEquals(listOf(8, 7, 6, 5, 4, 3, 2, 1), t.coaches.map { it.n })
    }

    // MARK: the windows

    @Test fun windowsCountFromTheBack() {
        // the front on the right: the back is on the left, so the left window is the 1st from the back
        assertEquals(1, SeatMap.window(0, dir = "right"))
        assertEquals(8, SeatMap.window(7, dir = "right"))
        // the front on the left: the right window is the 1st from the back
        assertEquals(1, SeatMap.window(10, dir = "left"))
        assertEquals(8, SeatMap.window(3, dir = "left"))
        // not known: from the left
        assertEquals(4, SeatMap.window(3, dir = null))
        for (dir in listOf("left", "right", null)) for (i in 0 until SeatMap.WINDOWS)
            assertEquals(i, SeatMap.drawnWindow(SeatMap.window(i, dir = dir), dir = dir))
        assertNull(SeatMap.drawnWindow(12, dir = "right"))
        // two rows: top the upper deck, bottom the lower; one row: no deck
        assertEquals(TravelState.Seat("upper", 8, 11), SeatMap.seat(7, 0, true, "right"))
        assertEquals(TravelState.Seat("lower", 8, 11), SeatMap.seat(7, 1, true, "right"))
        assertEquals(TravelState.Seat("none", 6, 11), SeatMap.seat(5, 0, false, "left"))
        assertEquals(1, SeatMap.row(TravelState.Seat("lower", 2, 11), true))
        assertEquals(0, SeatMap.row(TravelState.Seat("lower", 2, 11), false))
        // a friend's app that drew 22 windows: the 16th of 22 is the 8th of 11
        assertEquals(7, SeatMap.drawnWindow(TravelState.Seat("none", 16, 22), "right"))
    }

    @Test fun words() {
        assertEquals(listOf("1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd"),
            listOf(1, 2, 3, 4, 11, 12, 13, 21, 22).map { SeatMap.ordinal(it) })
        assertEquals("Coach 2 of 4 · 6th window from the back", SeatMap.label(TravelState.Coach(2, 4, true, null, TravelState.Seat("none", 6, 11))))
        assertEquals("Coach 2 of 4 · lower deck · 1st window from the left",
            SeatMap.label(TravelState.Coach(2, 4, false, "EHV", TravelState.Seat("lower", 1, 11))))
        assertEquals("Coach 2 of 4 · front", SeatMap.label(TravelState.Coach(2, 4, true, null)))
        assertEquals("Coach 3, upper deck, window 8 from the back", SeatMap.spoken(3, SeatMap.Deck.UPPER, 8, true))
        assertEquals("Coach 2, window 6 from the back", SeatMap.spoken(2, SeatMap.Deck.NONE, 6, true))
        assertEquals("Coach 3 of 6, from the front, two decks", SeatMap.spokenCoach(SeatMap.Coach(3, 3, true, true), 6))
    }

    @Test fun cardWords() {
        var s = TravelState(state = "riding", mode = "train", line = "IC", num = "3512", from = TravelState.Spot("Eindhoven Centraal"),
            to = TravelState.Spot("Breda"), eta = 1_800_003_780.0)
        assertEquals("IC 3512 to Breda", TravelWords.cardLine(s))
        assertEquals("arrives 09:03", TravelWords.cardTime(s, utc))
        assertEquals("3512 to Breda · 09:03", TravelWords.headline(s, utc))
        s = s.copy(num = null, line = "SPR")
        assertEquals("to Breda · 09:03", TravelWords.headline(s, utc))
        s = s.copy(state = "waiting")
        assertEquals("Waiting at Eindhoven Centraal", TravelWords.cardLine(s))
        assertNull(TravelWords.cardTime(s, utc))
        s = s.copy(state = "change")
        assertEquals("Changing at Eindhoven Centraal", TravelWords.cardLine(s))
        val bus = TravelState(state = "riding", mode = "bus", from = TravelState.Spot("Veghel"), to = TravelState.Spot("Uden"))
        assertEquals("Bus to Uden", TravelWords.headline(bus, utc))
    }

    @Test fun rideAlong() {
        val now = 1_800_000_000.0
        var s = TravelState(state = "riding", mode = "train", line = "SPR", trip = "trip-1", from = TravelState.Spot("Best", 51.50972, 5.39),
            to = TravelState.Spot("'s-Hertogenbosch", 51.69048, 5.29362), eta = now + 600, pos = TravelState.Position(51.6, 5.34, 12.0, now))
        val c = TripTake.rideAlong(s, now)!!
        assertEquals(1, c.rides.size)
        assertEquals("trip-1", c.rides[0].trip)
        assertEquals("on board: from where they are", GeoPoint(51.6, 5.34), c.rides[0].from.point)
        assertEquals("'s-Hertogenbosch", c.rides[0].to.name)
        assertEquals(TripTake.Way.Fastest, TripTake.way(c, now, null, null))
        assertNotNull(TripCard.valid(c))
        s = s.copy(state = "waiting")
        assertEquals("Best", TripTake.rideAlong(s, now)?.rides?.get(0)?.from?.name)
        // no vehicle, or Home without a place: nothing to ride along with
        assertNull(TripTake.rideAlong(s.copy(trip = null), now))
        assertNull(TripTake.rideAlong(s.copy(to = TravelState.Spot("Home")), now))
    }

    // MARK: the map (a friend's page frames their trip)

    @Test fun friendMapFramesTheTrip() {
        // the test friend's pretend Sprinter, Best to 's-Hertogenbosch, half way
        val s = TravelState(state = "riding", mode = "train", from = TravelState.Spot("Best", 51.50972, 5.39),
            to = TravelState.Spot("'s-Hertogenbosch", 51.69048, 5.29362), pos = TravelState.Position(51.6, 5.34, 12.0, 1_800_000_000.0))
        val pts = MapFrame.points(s)
        assertEquals(3, pts.size)
        // a map 1.2 times as high as wide, the sheet over its bottom 45 %
        val r = MapFrame.fit(pts, 1.2, 0.45)!!
        for (p in pts) assertTrue("$p in $r", r.contains(p))
        // the points sit in the free top part: all of them north of the line the sheet starts at
        val sheetTop = r.lat + r.latDelta / 2 - r.latDelta * 0.55
        for (p in pts) assertTrue(p.lat > sheetTop)
        // nowhere near Limburg (Maastricht 50.85, Sittard 51.0), and not zoomed out to the country
        assertTrue(r.lat - r.latDelta / 2 > 51.0)
        assertTrue(r.latDelta < 1.0)
        // the longitude span fits the map's width (equal scale)
        val k = cos((51.50972 + 51.69048) / 2 * Math.PI / 180)
        assertEquals(r.latDelta, r.lonDelta * k * 1.2, 1e-9)
    }

    @Test fun mapSkipsMissingPlaces_andZoomsOutOfAStreet() {
        // Home goes without a place; a 0,0 position is a missing one
        val s = TravelState(state = "waiting", mode = "bus", from = TravelState.Spot("Veghel, Busstation", 51.6167, 5.5486),
            to = TravelState.Spot("Home"), pos = TravelState.Position(0.0, 0.0, null, 1_800_000_000.0))
        val pts = MapFrame.points(s)
        assertEquals(listOf(GeoPoint(51.6167, 5.5486)), pts)
        val r = MapFrame.fit(pts, 1.0, 0.0)!!
        assertEquals(51.6167, r.lat, 1e-9)
        assertTrue(r.latDelta * 111_320 >= 1600 - 1)
        assertNull(MapFrame.fit(emptyList(), 1.0))
        assertNull(MapFrame.fit(listOf(GeoPoint(Double.NaN, 5.0)), 1.0))
    }

    @Test fun routeIsTheBitTheyRide() {
        val s = TravelState(state = "riding", mode = "train", from = TravelState.Spot("B", 51.1, 5.1), to = TravelState.Spot("D", 51.3, 5.3),
            pos = TravelState.Position(51.2, 5.2, null, 1_800_000_000.0))
        val path = (0..5).map { GeoPoint(51.0 + it * 0.1, 5.0 + it * 0.1) }
        assertEquals(path.subList(1, 4), MapFrame.route(s, path))
        // no shape: from, where they are, to
        assertEquals(listOf(GeoPoint(51.1, 5.1), GeoPoint(51.2, 5.2), GeoPoint(51.3, 5.3)), MapFrame.route(s, emptyList()))
        // nothing to draw with one point
        val lone = TravelState(state = "riding", mode = "bus", from = TravelState.Spot("Here"), to = TravelState.Spot("Home"))
        assertEquals(emptyList<GeoPoint>(), MapFrame.route(lone, emptyList()))
    }
}
