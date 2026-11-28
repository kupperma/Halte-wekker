package nl.haltewekker

import nl.haltewekker.travel.TripTimeline as T
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** iOS `TripTimelineTests` (0.42, 0.42.2). */
class TripTimelineTest {
    private val t0 = 1_800_000_000.0
    private fun at(m: Double) = t0 + m * 60
    private fun leg(line: String, dep: Double, arr: Double, from: String, walk: Int, live: Boolean = true, train: Boolean = false) =
        T.Leg(line, train, live, at(dep), at(arr), from, walk)

    @Test fun parts() {
        val p = T.parts(at(1.0), listOf(leg("305", 9.0, 20.0, "Bolkenplein", 7), leg("IC", 27.0, 47.0, "Den Bosch", 4, train = true)), at(52.0))
        assertEquals(listOf(T.Kind.WALK, T.Kind.WAIT, T.Kind.RIDE, T.Kind.WALK, T.Kind.WAIT, T.Kind.RIDE, T.Kind.WALK), p.map { it.kind })
        assertEquals(at(8.0), p[0].end, 0.0); assertEquals(at(9.0), p[1].end, 0.0); assertEquals("305", p[2].line)
        assertEquals(at(20.0), p[3].start, 0.0); assertEquals(at(24.0), p[3].end, 0.0); assertEquals(at(27.0), p[4].end, 0.0)
        assertTrue(p[5].train); assertEquals(at(52.0), p.last().end, 0.0)
    }

    @Test fun parts_noEmpty() {
        val p = T.parts(at(0.0), listOf(leg("306", 5.0, 15.0, "A", 8)), at(15.0))
        assertEquals(listOf(T.Kind.WALK, T.Kind.RIDE), p.map { it.kind }); assertEquals(at(5.0), p[0].end, 0.0)
    }

    @Test fun axis() {
        val axis = T.axis(listOf(listOf(T.Part(T.Kind.WALK, at(2.0), at(30.0))), listOf(T.Part(T.Kind.RIDE, at(12.0), at(41.0)))))!!
        assertEquals(at(0.0), axis.start, 0.0); assertEquals(at(45.0), axis.end, 0.0); assertEquals(1.0 / 3, axis.at(at(15.0)), 1e-9)
        assertEquals(listOf(at(0.0), at(10.0), at(20.0), at(30.0), at(45.0)), axis.ticks(320.0))
        val short = T.axis(listOf(listOf(T.Part(T.Kind.RIDE, at(1.0), at(6.0)))))!!
        assertEquals(at(20.0), short.end, 0.0); assertEquals(listOf(at(0.0), at(10.0), at(20.0)), short.ticks(320.0))
        assertNull(T.axis(emptyList()))
    }

    @Test fun place() {
        val p = T.place(listOf(T.Part(T.Kind.WALK, at(10.0), at(20.0)), T.Part(T.Kind.WAIT, at(20.0), at(20.1))), T.Axis(at(0.0), at(40.0)))
        assertEquals(0.25, p[0].x, 1e-9); assertEquals(0.25, p[0].width, 1e-9); assertEquals(T.MIN_WIDTH, p[1].width, 1e-9)
    }

    @Test fun changeLabels_crowded() {
        val legs = listOf(leg("305", 2.0, 10.0, "Bolkenplein", 2), leg("306", 11.0, 12.0, "Busstation", 1), leg("IC", 13.0, 38.0, "Den Bosch", 1, train = true))
        val placed = T.place(T.parts(at(0.0), legs, at(40.0)), T.Axis(at(0.0), at(40.0)))
        val l = T.changeLabels(legs, placed, 0.0 to 1.0)
        assertEquals(listOf("Busstation"), l.map { it.text }); assertEquals(0.25, l[0].x, 1e-9)
        assertEquals(listOf("Den Bosch"), T.changeLabels(legs, placed, 0.1 to 1.0).map { it.text })
    }

    @Test fun changeLabels_apart() {
        val legs = listOf(leg("305", 1.0, 4.0, "A", 1), leg("IC", 5.0, 20.0, "Den Bosch", 1, train = true), leg("SPR", 21.0, 30.0, "Tilburg", 1, train = true))
        val placed = T.place(T.parts(at(0.0), legs, at(40.0)), T.Axis(at(0.0), at(40.0)))
        val l = T.changeLabels(legs, placed, null)
        assertEquals(listOf("Den Bosch", "Tilburg"), l.map { it.text })
        assertEquals(0.1, l[0].x, 1e-9); assertEquals(T.Anchor.LEADING, l[0].anchor); assertEquals(0.5, l[1].x, 1e-9); assertEquals(T.Anchor.CENTER, l[1].anchor)
        assertEquals(T.Anchor.TRAILING, T.anchor(0.95))
    }

    @Test fun tickStep() {
        assertEquals(10.0, T.tickStep(40 * 60.0, 320.0), 0.0); assertEquals(30.0, T.tickStep(90 * 60.0, 320.0), 0.0)
        assertEquals(15.0, T.tickStep(90 * 60.0, 400.0), 0.0); assertEquals(120.0, T.tickStep(390 * 60.0, 320.0), 0.0)
        assertEquals(360.0, T.tickStep(48 * 3600.0, 320.0), 0.0)
    }

    @Test fun ticks_overnight() {
        val axis = T.Axis(at(0.0), at(390.0))
        val t = axis.ticks(320.0)
        assertEquals(at(0.0), t.first(), 0.0); assertEquals(at(390.0), t.last(), 0.0)
        for (i in 1 until t.size) assertTrue((axis.at(t[i]) - axis.at(t[i - 1])) * 320 >= T.TICK_SPACING - 1e-9)
        assertTrue(t.size <= 6)
    }

    @Test fun ends() {
        val w = 320.0; val lw = T.TIME_WIDTH / w
        val wide = T.ends(0.1, 0.8, w)
        assertEquals(0.1, wide.leave, 1e-9); assertEquals(0.8 - lw, wide.arrive, 1e-9)
        for ((a, b) in listOf(0.5 to 0.55, 0.0 to 0.04, 0.97 to 1.0, 0.3 to 0.3)) {
            val e = T.ends(a, b, w)
            assertTrue(e.arrive - e.leave >= lw - 1e-12); assertTrue(e.leave >= 0); assertTrue(e.arrive + lw <= 1 + 1e-9)
        }
    }

    @Test fun gapLabels() {
        val legs = listOf(leg("158", 3.0, 23.0, "Bolkenplein", 2), leg("SPR", 31.0, 60.0, "Den Bosch", 3, train = true), leg("1", 62.0, 75.0, "Breda", 0))
        val axis = T.Axis(at(0.0), at(80.0))
        val g = T.gapLabels(T.place(T.parts(at(0.0), legs, at(79.0)), axis), 320.0, 6.0)
        assertEquals(listOf("2 walk + 1 wait", "3 walk + 5 wait", "2 min", "4 min walk"), g.map { it.text })
        assertEquals(listOf(T.Tone.PLAIN, T.Tone.PLAIN, T.Tone.RISKY, T.Tone.PLAIN), g.map { it.tone })
        assertEquals((23.0 + 31) / 2 / 80, g[1].x, 1e-9); assertTrue(g[1].below); assertTrue(g[3].below); assertEquals(listOf(0, 1, 0, 1), g.map { it.lane })
        val lg = T.gapLabels(T.place(T.parts(at(0.0), listOf(leg("158", 0.0, 20.0, "A", 0), leg("SPR", 50.0, 70.0, "B", 0, train = true)), at(70.0)), axis), 320.0)
        assertEquals(listOf("30 min"), lg.map { it.text }); assertFalse(lg[0].below); assertEquals(35.0 / 80, lg[0].x, 1e-9)
        val tp = T.place(T.parts(at(0.0), listOf(leg("158", 0.0, 20.0, "A", 0), leg("SPR", 24.0, 50.0, "B", 0, train = true)), at(50.0)), axis)
        assertEquals(listOf(T.Tone.TIGHT), T.gapLabels(tp, 320.0, 6.0).map { it.tone }); assertEquals(listOf(T.Tone.PLAIN), T.gapLabels(tp, 320.0, null).map { it.tone })
    }

    @Test fun gapLabels_neverOnTop() {
        val legs = listOf(leg("1", 0.0, 20.0, "A", 0), leg("2", 21.0, 22.0, "B", 0), leg("3", 23.0, 24.0, "C", 0), leg("4", 25.0, 60.0, "D", 0))
        val g = T.gapLabels(T.place(T.parts(at(0.0), legs, at(60.0)), T.Axis(at(0.0), at(60.0))), 320.0)
        assertTrue(g.all { it.below })
        for (a in g) for (b in g) if (a != b && a.lane == b.lane) assertTrue(kotlin.math.abs(a.x - b.x) >= (T.textWidth(a.text) + T.textWidth(b.text)) / 2 / 320)
        assertEquals(setOf(0, 1), g.map { it.lane }.toSet())
    }

    @Test fun rideLabels() {
        val placed = T.place(T.parts(at(0.0), listOf(leg("158", 0.0, 41.0, "A", 0), leg("1", 43.0, 45.0, "B", 0)), at(45.0)), T.Axis(at(0.0), at(45.0)))
        val r = T.rideLabels(placed, 320.0)
        assertEquals(listOf("41 min"), r.map { it.text }); assertEquals("158", placed[r[0].index].part.line)
    }
}
