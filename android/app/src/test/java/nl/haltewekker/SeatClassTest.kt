package nl.haltewekker

import kotlinx.serialization.json.JsonObject
import nl.haltewekker.friends.FriendJson
import nl.haltewekker.friends.NSTrains
import nl.haltewekker.friends.SeatClass
import nl.haltewekker.friends.SeatMap
import nl.haltewekker.friends.TrainDrawing
import nl.haltewekker.friends.TravelState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A5.1 (iOS 0.31.1): 1st class in the seat picker, from real NS compositions (the relay's `/ns/train`, 19 November
 * 2026, trimmed to what's read; the same 11 as the iOS app's SeatClassTests) and the table read off NS's drawings
 * (`SeatClass`; docs/superpowers/specs/2026-11-18-friends-design.md, "As built (0.31.1)").
 */
class SeatClassTest {
    companion object {
        const val IC3078 = """{"ritnummer":3078,"station":"UT","type":"VIRM","materieeldelen":[{"type":"VIRMm1 VI","afbeelding":"https://vt.ns-mlab.nl/v1/images/virmm1_6.png","breedte":3376,"zitplaatsen":{"zitplaatsEersteKlas":120,"zitplaatsTweedeKlas":425},"bakken":[{},{},{},{},{},{}]},{"type":"VIRMm1 IV","afbeelding":"https://vt.ns-mlab.nl/v1/images/virmm1_4.png","breedte":2259,"zitplaatsen":{"zitplaatsEersteKlas":80,"zitplaatsTweedeKlas":282},"bakken":[{},{},{},{}]}],"lengte":10,"lengteInPixels":5635,"rijrichting":"LINKS"}"""
        const val IC2280 = """{"ritnummer":2280,"station":"RTD","type":"VIRM","materieeldelen":[{"type":"VIRM IV","afbeelding":"https://vt.ns-mlab.nl/v1/images/virm_4.png","breedte":2259,"zitplaatsen":{"zitplaatsEersteKlas":64,"zitplaatsTweedeKlas":310},"bakken":[{},{},{},{}]},{"type":"VIRMm1 VI","afbeelding":"https://vt.ns-mlab.nl/v1/images/virmm1_6.png","breedte":3376,"zitplaatsen":{"zitplaatsEersteKlas":120,"zitplaatsTweedeKlas":425},"bakken":[{},{},{},{},{},{}]}],"lengte":10,"lengteInPixels":5635}"""
        const val SPR4982 = """{"ritnummer":4982,"station":"UT","type":"SLT","materieeldelen":[{"type":"SLT 4","afbeelding":"https://vt.ns-mlab.nl/v1/images/slt_4.png","breedte":1446,"zitplaatsen":{"zitplaatsEersteKlas":20,"zitplaatsTweedeKlas":160},"bakken":[{},{},{},{}]},{"type":"SLT 6","afbeelding":"https://vt.ns-mlab.nl/v1/images/slt_6.png","breedte":2094,"zitplaatsen":{"zitplaatsEersteKlas":40,"zitplaatsTweedeKlas":220},"bakken":[{},{},{},{},{},{}]}],"lengte":10,"lengteInPixels":3540,"rijrichting":"LINKS"}"""
        const val IC678 = """{"ritnummer":678,"station":"UT","type":"ICM","materieeldelen":[{"type":"ICM 3","afbeelding":"https://vt.ns-mlab.nl/v1/images/icm_3.png","breedte":1662,"zitplaatsen":{"zitplaatsEersteKlas":35,"zitplaatsTweedeKlas":163},"bakken":[{},{},{}]}],"lengte":3,"lengteInPixels":1662,"rijrichting":"RECHTS"}"""
        const val IC2685 = """{"ritnummer":2685,"station":"ASD","type":"ICM","materieeldelen":[{"type":"ICM 4","afbeelding":"https://vt.ns-mlab.nl/v1/images/icm_4.png","breedte":2218,"zitplaatsen":{"zitplaatsEersteKlas":56,"zitplaatsTweedeKlas":211},"bakken":[{},{},{},{}]},{"type":"ICM 4","afbeelding":"https://vt.ns-mlab.nl/v1/images/icm_4.png","breedte":2218,"zitplaatsen":{"zitplaatsEersteKlas":56,"zitplaatsTweedeKlas":211},"bakken":[{},{},{},{}]}],"lengte":8,"lengteInPixels":4436}"""
        const val IC1783 = """{"ritnummer":1783,"station":"UT","type":"DDZ","materieeldelen":[{"type":"DDZ 4","afbeelding":"https://vt.ns-mlab.nl/v1/images/ddz_4.png","breedte":2111,"zitplaatsen":{"zitplaatsEersteKlas":67,"zitplaatsTweedeKlas":269},"bakken":[{},{},{},{}]}],"lengte":4,"lengteInPixels":2111}"""
        const val SPR5683 = """{"ritnummer":5683,"station":"UT","type":"SNG","materieeldelen":[{"type":"SNG 3","afbeelding":"https://vt.ns-mlab.nl/v1/images/sng_3.png","breedte":1241,"zitplaatsen":{"zitplaatsEersteKlas":19,"zitplaatsTweedeKlas":125},"bakken":[{},{},{}]}],"lengte":3,"lengteInPixels":1241,"rijrichting":"RECHTS"}"""
        const val IC1184 = """{"ritnummer":1184,"station":"EHV","type":"ICNG","materieeldelen":[{"type":"ICNG 5","afbeelding":"https://vt.ns-mlab.nl/v1/images/icng_5.png","breedte":2286,"zitplaatsen":{"zitplaatsEersteKlas":58,"zitplaatsTweedeKlas":194},"bakken":[{},{},{},{},{}]}],"lengte":5,"lengteInPixels":2286,"rijrichting":"RECHTS"}"""
        const val IC9583 = """{"ritnummer":9583,"station":"RTD","type":"ICNG","materieeldelen":[{"type":"ICNG-B 8","afbeelding":"https://vt.ns-mlab.nl/v1/images/icng_B_8.png","breedte":3442,"zitplaatsen":{"zitplaatsEersteKlas":85,"zitplaatsTweedeKlas":322},"bakken":[{},{},{},{},{},{},{},{}]}],"lengte":8,"lengteInPixels":3442}"""
        const val ICE120 = """{"ritnummer":120,"station":"UT","type":"ICE","materieeldelen":[{"type":"ICE-3NEO","afbeelding":"https://vt.ns-mlab.nl/v1/images/ice.png","breedte":4109,"zitplaatsen":{"zitplaatsEersteKlas":99,"zitplaatsTweedeKlas":340},"bakken":[{},{},{},{},{},{},{},{}]}],"lengte":8,"lengteInPixels":4109,"rijrichting":"LINKS"}"""
        const val KEOLIS8581 = """{"ritnummer":8581,"station":"ZL","type":"Flirt","materieeldelen":[{"type":"Flirt 3 Keolis","afbeelding":"https://vt.ns-mlab.nl/v1/images/keolis_flirt3_blauwnet.png","breedte":1328,"zitplaatsen":{"zitplaatsEersteKlas":0,"zitplaatsTweedeKlas":171},"bakken":[{},{},{}]}],"lengte":3,"lengteInPixels":1328}"""
    }

    /** NS's answer as the app reads it. */
    private fun drawing(json: String): TrainDrawing = NSTrains.parse(FriendJson.parse(json.toByteArray()) as JsonObject)!!

    /** The picker's train from a composition, as the app builds it. */
    private fun train(json: String, line: String = "IC"): SeatMap.Train = TrainDrawing.seatTrain(drawing(json), line)

    private fun kinds(t: SeatMap.Train): String = t.coaches.joinToString("") { c ->
        when (c.kind) { SeatClass.Kind.FIRST -> "1"; SeatClass.Kind.PART -> "p"; SeatClass.Kind.SECOND -> "2"; null -> "?" }
    }

    @Test fun parse_readsNSsAnswer() {
        val d = drawing(IC3078)
        assertEquals(listOf("virmm1_6", "virmm1_4"), d.drawings)
        assertEquals(listOf<Int?>(120, 80), d.firstSeats)
        assertEquals(listOf("VIRMm1 VI", "VIRMm1 IV"), d.kinds)
        assertEquals(listOf(6, 4), d.units.map { it.cars })
        assertEquals(2, d.units.size)
        assertEquals(3376.0 / 5635.0, d.units[1].x, 1e-9)
        assertEquals("left", d.dir)
        assertEquals(10, d.cars)
        // the Belgian ICNG's drawing name, lower case; Keolis says 0
        assertEquals(listOf("icng_b_8"), drawing(IC9583).drawings)
        assertEquals(listOf<Int?>(0), drawing(KEOLIS8581).firstSeats)
        // without zitplaatsen: not said
        val bare = """{"lengte":4,"lengteInPixels":400,"materieeldelen":[{"type":"VIRM IV","breedte":400,"bakken":[{},{},{},{}]}]}"""
        assertEquals(listOf<Int?>(null), drawing(bare).firstSeats)
        // no drawing: from its type ("VIRM IV" → virm_4), its 1st class below only in the second coach
        assertEquals("2pp2", kinds(train(bare)))
    }

    @Test fun realTrains_coachByCoach() {
        // drawn from the left: 2 = no 1st class, p = part of it, 1 = all 1st class, ? = not known
        assertEquals("2p2pp22pp2", kinds(train(IC3078)))
        assertEquals("2pp22p2pp2", kinds(train(IC2280)))
        assertEquals("p22pp2222p", kinds(train(SPR4982, "SPR")))
        assertEquals("2p2", kinds(train(IC678)))
        assertEquals("22122212", kinds(train(IC2685)))
        assertEquals("p2p2", kinds(train(IC1783)))
        assertEquals("the SNG 3 has 1st class at one end only", "p22", kinds(train(SPR5683, "SPR")))
        assertEquals("22pp2", kinds(train(IC1184)))
        assertEquals("22pppp22", kinds(train(IC9583)))
        assertEquals("????????", kinds(train(ICE120)))
        assertEquals("NS counts no 1st-class seats", "222", kinds(train(KEOLIS8581, "SPR")))
    }

    @Test fun trainFlags() {
        val ice = train(ICE120)
        assertFalse(ice.anyFirst)
        assertTrue(ice.firstUnknown)
        val ic = train(IC3078)
        assertTrue(ic.anyFirst)
        assertFalse(ic.firstUnknown)
        val k = train(KEOLIS8581)
        assertFalse(k.anyFirst)
        assertFalse(k.firstUnknown)
        // the guess (no NS) knows no 1st class
        val guess = SeatMap.train(emptyList(), emptyList(), 6, null, "IC")
        assertFalse(guess.anyFirst)
        assertTrue(guess.firstUnknown)
        assertFalse(TrainDrawing.seatTrain(null, "IC", 4).anyFirst)
        assertEquals(4, TrainDrawing.seatTrain(null, "IC", 4).count)
    }

    @Test fun windows_perDeck() {
        val t = train(IC3078)
        // the VIRMm1 IV's second coach (drawn 7): the upper deck's 1st class is shorter than the lower's
        val s = t.coaches[7].first!!
        assertEquals(listOf(6..7), SeatClass.runs(0, true, s))
        assertEquals(listOf(5..7), SeatClass.runs(1, true, s))
        // the Koploper's middle coach: one deck
        val icm = train(IC678).coaches[1]
        assertFalse(icm.double)
        assertEquals(listOf(5..9), SeatClass.runs(0, false, icm.first!!))
        // the DDZ behind its cab
        val ddz = train(IC1783).coaches[0]
        assertEquals(listOf(2..5), SeatClass.runs(0, true, ddz.first!!))
        assertEquals(listOf(2..3), SeatClass.runs(1, true, ddz.first!!))
        // the old VIRM IV's second coach: below only
        val virm = train(IC2280).coaches[1]
        assertEquals(emptyList<IntRange>(), SeatClass.runs(0, true, virm.first!!))
        assertEquals(listOf(5..7), SeatClass.runs(1, true, virm.first!!))
    }

    @Test fun yourSeat_isFirst_andItsWords() {
        val t = train(IC3078)
        // coach 2 from the front (the front on the left: drawn 1), upper deck, window 5 from the back (drawn 6)
        val c = TravelState.Coach(2, 10, true, "UT", TravelState.Seat("upper", 5, 11))
        assertTrue(SeatMap.isFirst(c, t, "UT"))
        assertEquals("Coach 2 of 10 · upper deck · 5th window from the back · 1st class", SeatMap.label(c, firstClass = true))
        assertEquals("Coach 2 of 10 · upper deck · 5th window from the back", SeatMap.label(c))
        // the same coach, window 1 from the back (drawn 10): 2nd class
        assertFalse(SeatMap.isFirst(TravelState.Coach(2, 10, true, "UT", TravelState.Seat("upper", 1, 11)), t, "UT"))
        // only a coach that's part 1st class: not 1st class without a window
        assertFalse(SeatMap.isFirst(TravelState.Coach(2, 10, true, "UT"), t, "UT"))
        // a coach that's 1st class all through is, window or not
        val icm = train(IC2685)
        assertTrue(SeatMap.isFirst(TravelState.Coach(3, 8, false, "ASD"), icm, "ASD"))
        assertEquals("Coach 3 of 8 · 1st class", SeatMap.label(TravelState.Coach(3, 8, false, "ASD"), firstClass = true))
        // the seat box is unchanged: nothing about class is sent
        assertEquals("""{"at":"UT","front":true,"n":2,"of":10,"seat":{"deck":"upper","of":11,"w":5}}""",
            FriendJson.encodeString(TravelState.Coach.serializer(), c))
    }

    @Test fun spoken() {
        val icm = train(IC2685)
        assertEquals("Coach 3 of 8, 1st class", SeatMap.spokenCoach(icm.coaches[2], 8))
        assertEquals("Coach 1 of 8", SeatMap.spokenCoach(icm.coaches[0], 8))
        val ic = train(IC3078)
        assertEquals("Coach 2 of 10, from the front, two decks, part 1st class", SeatMap.spokenCoach(ic.coaches[1], 10))
        assertEquals("1st class (about here)", SeatClass.words(SeatClass.Kind.PART))
        assertEquals("1st class", SeatClass.words(SeatClass.Kind.FIRST))
        assertNull(SeatClass.words(SeatClass.Kind.SECOND))
        assertEquals("= 1st class (about here)", SeatClass.legend(part = true, whole = false))
        assertEquals("= 1st class · gold coach: all 1st class", SeatClass.legend(part = false, whole = true))
        assertEquals("= 1st class (about here) · gold coach: all 1st class", SeatClass.legend(part = true, whole = true))
        assertEquals("Gold coaches are all 1st class", SeatClass.spokenLegend(part = false, whole = true))
    }

    @Test fun drawingNames() {
        assertEquals("virmm1_6", SeatClass.drawing("https://vt.ns-mlab.nl/v1/images/virmm1_6.png"))
        assertEquals("icng_b_8", SeatClass.drawing("icng_B_8.png"))
        assertEquals("virmm1_6", SeatClass.drawing("", "VIRMm1 VI"))
        assertEquals("virm_4", SeatClass.drawing("", "VIRM IV"))
        assertEquals("ddz_4", SeatClass.drawing("", "DDZ 4"))
        assertEquals("nsr_flirt_3", SeatClass.drawing("", "Flirt 3"))
        assertEquals("icng_b_8", SeatClass.drawing("", "ICNG-B 8"))
        assertNull(SeatClass.drawing("ice.png", "ICE-3NEO"))
        assertNull(SeatClass.drawing("", ""))
        // another number of coaches than drawn: not known
        assertNull(SeatClass.sections("virm_4", 0, 6, null))
        assertEquals(emptyList<SeatClass.Section>(), SeatClass.sections("virm_4", 0, 6, 0))
    }

    @Test fun table_isWellFormed() {
        assertEquals(19, SeatClass.drawings.size)
        for ((k, d) in SeatClass.drawings) {
            assertEquals(k, d.edges.size + 1, d.coaches.size)
            assertEquals(k, d.edges.sorted(), d.edges)
            assertTrue(k, d.edges.all { it > 0 && it < 1 })
            for (secs in d.coaches) for (s in secs) assertTrue(k, s.a >= 0 && s.b <= 1 && s.a < s.b)
            assertFalse("$k has some 1st class", d.coaches.all { it.isEmpty() })
        }
    }

    @Test fun unitZones() {
        val sng3 = SeatClass.unitZones("sng_3")!!
        assertEquals("one end only", 1, sng3.size)
        assertEquals(0.2 * 0.3634, sng3[0].first, 1e-9)
        val icm4 = SeatClass.unitZones("icm_4")!!
        assertEquals(1, icm4.size)
        assertEquals(0.4993, icm4[0].first, 1e-9)
        assertEquals(0.75, icm4[0].second, 1e-9)
        // ICNG 5: over the gangway, merged
        assertEquals(1, SeatClass.unitZones("icng_5")!!.size)
        assertNull(SeatClass.unitZones("ice"))
    }

    @Test fun strip_markAndKind() {
        // a part-1st coach's bar: where any deck has it
        val s = train(IC3078).coaches[7].first!!
        val span = SeatClass.span(s)
        assertNotNull(span)
        assertEquals(0.46, span!!.start, 1e-9)
        assertEquals(0.76, span.endInclusive, 1e-9)
        assertNull(SeatClass.span(emptyList()))
        assertEquals(SeatClass.Kind.FIRST, SeatClass.kind(listOf(SeatClass.WHOLE)))
        // all through on one deck only isn't the whole coach
        assertEquals(SeatClass.Kind.PART, SeatClass.kind(listOf(SeatClass.Section(0.0, 1.0, SeatMap.Deck.UPPER))))
        // an all-1st coach: every window, any seat
        val icm = train(IC2685).coaches[2]
        assertTrue(SeatMap.isFirst(TravelState.Seat("none", 1, 11), icm, null))
        assertTrue(SeatMap.isFirst(null, icm, null))
        // a coach not known: never 1st class
        assertFalse(SeatMap.isFirst(TravelState.Seat("none", 6, 11), train(ICE120).coaches[2], "left"))
    }
}
