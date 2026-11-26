package nl.haltewekker

import nl.haltewekker.ride.ChangeGuide
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** iOS `ChangeGuideTests` (0.39): the change ahead, guided. */
class ChangeGuideTest {
    private val t0 = 1_800_000_000.0
    private fun at(m: Double) = t0 + m * 60
    private val hhmm: (Double) -> String = { "+${((it - t0) / 60).toInt()}" }
    private fun train(id: String, m: Double, p: String?, walk: Int = 0) = ChangeGuide.Ride(id, "IC", true, at(m), p, walk)

    @Test fun platformWords() {
        assertEquals("Platform 5 → 7", ChangeGuide.platforms("5", train("a", 0.0, "7")))
        assertEquals("Same platform (5)", ChangeGuide.platforms("5", train("a", 0.0, "5")))
        assertEquals("To platform 7", ChangeGuide.platforms(null, train("a", 0.0, "7")))
        assertEquals("Arrive at platform 5", ChangeGuide.platforms("5", train("a", 0.0, null)))
        assertNull(ChangeGuide.platforms(" ", train("a", 0.0, "")))
        val bus = ChangeGuide.Ride("b", "306", false, at(0.0), "B")
        assertEquals("Platform 3b → bus 306", ChangeGuide.platforms("3b", bus))
        assertNull(ChangeGuide.platforms(null, bus))
    }

    @Test fun needIsTheWalkOrYourOwnChangeTime() {
        assertEquals(3.0, ChangeGuide.need(3, null), 0.0)
        assertEquals(4.0, ChangeGuide.need(3, 4.0), 0.0)
        assertEquals(5.0, ChangeGuide.need(3, 9.0), 0.0)
        assertEquals(ChangeGuide.LEAST, ChangeGuide.need(0, null), 0.0)
        assertEquals(4.0, ChangeGuide.need(4, 2.0), 0.0)
    }

    @Test fun plentyOfRoom() {
        val g = ChangeGuide.guide(at(0.0), "5", true, null, train("p", 7.0, "7", 3), emptyList(), null, at(-10.0), hhmm)
        assertFalse(g.missed); assertFalse(g.tight)
        assertEquals(7, g.minutes)
        assertEquals("7 min to change", g.countdown)
        assertEquals("Platform 5 → 7 · 3 min walk", g.lockLine)
        assertNull(g.missText); assertNull(g.planned)
        assertEquals("p", g.target.tripId)
    }

    @Test fun aLateRideMissesItAndSaysWhatInstead() {
        val later = listOf(train("q", 12.0, "6", 3), train("r", 25.0, "4", 3), train("p", 9.0, "7", 3))
        val g = ChangeGuide.guide(at(10.0), "5", true, null, train("p", 9.0, "7", 3), later, 4.0, at(-5.0), hhmm)
        assertTrue(g.missed); assertTrue(g.tight)
        assertEquals("r", g.target.tripId)
        assertEquals("p", g.planned?.tripId)
        assertEquals(15, g.minutes)
        assertEquals("You’ll miss the +9 — take the +25 from platform 4", g.missText)
        assertEquals("Platform 5 → 4 · 3 min walk", g.lockLine)
    }

    @Test fun yourOwnChangeTimeDecidesAMiss() {
        val next = train("p", 3.0, "7", 2)
        assertFalse(ChangeGuide.guide(at(0.0), null, true, null, next, emptyList(), null, at(-3.0), hhmm).missed)
        assertTrue(ChangeGuide.guide(at(0.0), null, true, null, next, emptyList(), 4.0, at(-3.0), hhmm).missed)
    }

    @Test fun noLaterOneFound() {
        val g = ChangeGuide.guide(at(10.0), null, true, null, train("p", 8.0, "7"), emptyList(), null, at(0.0), hhmm)
        assertTrue(g.missed)
        assertEquals("p", g.target.tripId)
        assertEquals(-2, g.minutes)
        assertEquals("It leaves before you’re there", g.countdown)
        assertEquals("You’ll likely miss the +8", g.missText)
    }

    @Test fun atTheChangeItCountsFromNow() {
        val g = ChangeGuide.guide(at(0.0), "5", true, null, train("p", 7.0, "7", 2), emptyList(), null, at(3.0), hhmm)
        assertEquals("4 min to change", g.countdown)
        assertFalse(g.missed)
    }

    @Test fun aBusInsteadIsNamed() {
        val bus = ChangeGuide.Ride("b2", "306", false, at(20.0), "B", 4)
        val next = ChangeGuide.Ride("b1", "306", false, at(5.0), "B", 4)
        val g = ChangeGuide.guide(at(3.0), "3", true, null, next, listOf(bus), null, at(0.0), hhmm)
        assertEquals("You’ll miss the +5 — take bus 306 at +20", g.missText)
        assertEquals("Platform 3 → bus 306", g.platforms)
    }

    @Test fun aSlowBusWantsMoreRoomButStillMakesIt() {
        val g = ChangeGuide.guide(at(0.0), null, false, "C", train("p", 5.0, "3", 1), emptyList(), null, at(-8.0), hhmm)
        assertTrue(g.tight); assertFalse(g.missed)
    }

    @Test fun pickPlanByTripElseByTime() {
        val i = train("r", 25.0, "4")
        assertEquals(1, ChangeGuide.pickPlan(listOf("x" to at(20.0), "r" to at(25.0)), i))
        assertEquals(1, ChangeGuide.pickPlan(listOf("x" to at(20.0), "y" to at(25.5)), i))
        assertNull(ChangeGuide.pickPlan(listOf("x" to at(20.0), "y" to at(30.0)), i))
    }
}
