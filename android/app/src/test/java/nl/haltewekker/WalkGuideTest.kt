package nl.haltewekker

import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.travel.WalkGuide as W
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** iOS `WalkGuideTests` (0.41), and the OSRM maneuvers (Android). */
class WalkGuideTest {
    private fun raw(text: String, path: List<GeoPoint>, m: W.Turn? = null) = W.RawStep(text, Geo.length(path), path, m)

    private val lShape get() = W.route(listOf(
        raw("", listOf(Fx.east(0.0))),
        raw("Head east on Kerkstraat", listOf(Fx.east(0.0), Fx.east(100.0))),
        raw("Turn left onto Hoogstraat", listOf(Fx.east(100.0), Fx.east(100.0, north = 80.0))),
        raw("The destination is on your left.", listOf(Fx.east(100.0, north = 80.0))),
    ))

    @Test fun changeWrapsRound() {
        assertEquals(20.0, W.change(350.0, 10.0), 0.001); assertEquals(-20.0, W.change(10.0, 350.0), 0.001)
        assertEquals(-90.0, W.change(90.0, 0.0), 0.001); assertEquals(180.0, W.change(0.0, 180.0), 0.001)
    }

    @Test fun turnFromChange() {
        assertEquals(W.Turn.STRAIGHT, W.turn(5.0)); assertEquals(W.Turn.STRAIGHT, W.turn(-15.0))
        assertEquals(W.Turn.SLIGHT_RIGHT, W.turn(30.0)); assertEquals(W.Turn.SLIGHT_LEFT, W.turn(-30.0))
        assertEquals(W.Turn.RIGHT, W.turn(90.0)); assertEquals(W.Turn.LEFT, W.turn(-95.0))
        assertEquals(W.Turn.SHARP_RIGHT, W.turn(140.0)); assertEquals(W.Turn.SHARP_LEFT, W.turn(-150.0))
        assertEquals(W.Turn.U_TURN, W.turn(178.0)); assertEquals(W.Turn.U_TURN, W.turn(-170.0))
    }

    @Test fun routeFromSteps() {
        val r = lShape
        assertEquals(3, r.steps.size); assertEquals(180.0, r.length, 1.0)
        assertEquals(W.Turn.DEPART, r.steps[0].turn); assertEquals(0.0, r.steps[0].start, 0.0); assertEquals(100.0, r.steps[0].end, 1.0)
        assertEquals(W.Turn.LEFT, r.steps[1].turn); assertEquals("Turn left onto Hoogstraat", r.steps[1].text); assertEquals(180.0, r.steps[1].end, 1.0)
        assertEquals(W.Turn.ARRIVE, r.steps[2].turn); assertEquals("The destination is on your left", r.steps[2].text)
    }

    @Test fun rightSlightAndWords() {
        val right = W.route(listOf(raw("Head east", listOf(Fx.east(0.0), Fx.east(100.0))), raw("Turn right onto Markt", listOf(Fx.east(100.0), Fx.east(100.0, north = -100.0)))))
        assertEquals(W.Turn.RIGHT, right.steps[1].turn); assertEquals(W.Turn.ARRIVE, right.steps.last().turn)
        assertEquals(3, right.steps.size); assertEquals(200.0, right.steps[2].start, 1.0)
        val slight = W.route(listOf(raw("Head east", listOf(Fx.east(0.0), Fx.east(100.0))),
            raw("Keep left", listOf(Fx.east(100.0), Fx.east(143.3, north = 25.0))), raw("Arrive at the destination", listOf(Fx.east(143.3, north = 25.0)))))
        assertEquals(W.Turn.SLIGHT_LEFT, slight.steps[1].turn)
        val words = W.route(listOf(raw("Head east", listOf(Fx.east(0.0), Fx.east(100.0))),
            raw("Turn right onto Dorpsstraat", listOf(Fx.east(100.0), Fx.east(200.0))), raw("Arrive", listOf(Fx.east(200.0)))))
        assertEquals(W.Turn.SLIGHT_RIGHT, words.steps[1].turn)
    }

    @Test fun osrmManeuverWins_shapeAsFallback() {
        // the shape goes straight on, OSRM says a right turn: its arrow
        val r = W.route(listOf(raw("Head east", listOf(Fx.east(0.0), Fx.east(100.0)), W.Turn.DEPART),
            raw("Turn right onto Dorpsstraat", listOf(Fx.east(100.0), Fx.east(200.0)), W.Turn.of("turn", "right")),
            raw("Arrive", listOf(Fx.east(200.0)), W.Turn.of("arrive", null))))
        assertEquals(W.Turn.RIGHT, r.steps[1].turn); assertEquals(W.Turn.ARRIVE, r.steps.last().turn)
        assertNull(W.Turn.of("turn", null)); assertEquals(W.Turn.U_TURN, W.Turn.of("continue", "uturn"))
        assertEquals(W.Turn.SLIGHT_LEFT, W.Turn.of("fork", "slight left"))
    }

    @Test fun noWordsAtAll() {
        val r = W.route(listOf(raw("", listOf(Fx.east(0.0), Fx.east(50.0)))))
        assertEquals(listOf(W.Turn.ARRIVE), r.steps.map { it.turn }); assertEquals(50.0, r.length, 1.0)
    }

    @Test fun sideFromWords() {
        assertEquals(true, W.side("Turn right onto Hoogstraat")); assertEquals(false, W.side("Sla linksaf naar Kerkstraat"))
        assertNull(W.side("Continue onto Markt"))
        assertTrue(W.saysArrive("The destination is on your right")); assertFalse(W.saysArrive("Turn left"))
    }

    @Test fun locate_thenAdvance() {
        val r = lShape
        val a = W.locate(Fx.east(50.0), r, 0, null)!!
        assertEquals(0, a.step); assertFalse(a.advanced); assertEquals(50.0, a.toTurn, 1.0); assertEquals(130.0, a.left, 1.0)
        assertEquals(W.Turn.LEFT, W.next(r, a.step)?.turn); assertEquals(W.Turn.ARRIVE, W.then(r, a.step)?.turn)
        val b = W.locate(Fx.east(88.0), r, 0, 50.0)!!
        assertEquals(1, b.step); assertTrue(b.advanced); assertEquals(92.0, b.toTurn, 1.0)
        assertEquals(W.Turn.ARRIVE, W.next(r, b.step)?.turn); assertNull(W.then(r, b.step))
        assertEquals(1, W.locate(Fx.east(100.0, north = 20.0), r, 0, 88.0)!!.step)
    }

    @Test fun locate_neverBack_notOffRoute() {
        val r = lShape
        val back = W.locate(Fx.east(30.0), r, 1, 100.0)!!
        assertEquals(1, back.step); assertFalse(back.advanced)
        val off = W.locate(Fx.east(95.0, north = -60.0), r, 0, 80.0)!!
        assertEquals(60.0, off.off, 1.0); assertEquals(0, off.step)
    }

    @Test fun warnAt30m() {
        val r = lShape
        val p = W.locate(Fx.east(75.0), r, 0, 60.0)!!
        assertTrue(W.warn(p, r, false)); assertFalse(W.warn(p, r, true))
        assertFalse(W.warn(W.locate(Fx.east(50.0), r, 0, 40.0)!!, r, false))
        val short = W.route(listOf(raw("Head east", listOf(Fx.east(0.0), Fx.east(30.0))), raw("Turn left", listOf(Fx.east(30.0), Fx.east(30.0, north = 100.0))),
            raw("Arrive", listOf(Fx.east(30.0, north = 100.0)))))
        assertFalse(W.warn(W.locate(Fx.east(10.0), short, 0, null)!!, short, false))
    }

    @Test fun offRoute_10sThenReroute() {
        val t0 = 1_800_000_000.0
        var s = W.OffRoute()
        var o = W.offRoute(s, 50.0, 10.0, t0); assertFalse(o.second); s = o.first; assertEquals(t0, s.since)
        o = W.offRoute(s, 55.0, 10.0, t0 + 5); assertFalse(o.second); s = o.first
        o = W.offRoute(s, 55.0, 10.0, t0 + 10); assertTrue(o.second); s = o.first; assertNull(s.since)
        o = W.offRoute(s, 60.0, 10.0, t0 + 15); s = o.first
        o = W.offRoute(s, 60.0, 10.0, t0 + 25); assertFalse(o.second); s = o.first
        o = W.offRoute(s, 60.0, 10.0, t0 + 30); assertTrue(o.second); s = o.first
        o = W.offRoute(s, 60.0, 10.0, t0 + 40); s = o.first; assertNotNull(s.since)
        o = W.offRoute(s, 10.0, 10.0, t0 + 41); s = o.first; assertNull(s.since)
        o = W.offRoute(s, 200.0, 150.0, t0 + 42); assertEquals(s, o.first); assertFalse(o.second)
    }

    @Test fun arrivedWithin25m() {
        assertTrue(W.arrived(20.0, 10.0)); assertFalse(W.arrived(30.0, 10.0)); assertFalse(W.arrived(10.0, 120.0)); assertFalse(W.arrived(10.0, -1.0))
    }

    @Test fun splitWalkedAndAhead() {
        val path = listOf(Fx.east(0.0), Fx.east(100.0), Fx.east(200.0))
        val s = W.split(path, 150.0)
        assertEquals(3, s.first.size); assertEquals(150.0, Geo.length(s.first), 1.0)
        assertEquals(2, s.second.size); assertEquals(50.0, Geo.length(s.second), 1.0)
        val start = W.split(path, 0.0); assertTrue(start.first.isEmpty()); assertEquals(path, start.second)
    }

    @Test fun hurryHint() {
        val now = 1_800_000_000.0
        val fine = W.hurry(600.0, null, now + 720, now, "your bus")
        assertEquals(9, fine.walkMinutes); assertEquals(W.Pace.FINE, fine.pace); assertEquals("Your bus leaves in 12 min · you’ll make it", fine.text)
        val faster = W.hurry(600.0, null, now + 530, now, "your train")
        assertEquals(W.Pace.FASTER, faster.pace); assertEquals("Your train leaves in 8 min · walk a bit faster", faster.text)
        assertEquals(W.Pace.HURRY, W.hurry(600.0, null, now + 300, now, "your bus").pace)
        val gone = W.hurry(600.0, null, now + 10, now, "your bus")
        assertEquals(W.Pace.GONE, gone.pace); assertEquals("Your bus leaves now", gone.text)
        val mine = W.hurry(600.0, 1.5, null, now, "your bus")
        assertEquals(7, mine.walkMinutes); assertNull(mine.text); assertNull(mine.pace)
        assertEquals(9, W.hurry(600.0, 9.0, null, now, "x").walkMinutes)
        assertEquals("4 min · 320 m to go", W.left(320.0, 4))
    }

    @Test fun words() {
        assertEquals("Turn right onto Hoogstraat", W.short("  Turn right onto   Hoogstraat. "))
        assertEquals("turn right onto Hoogstraat", W.lowerFirst("Turn right onto Hoogstraat"))
        assertEquals("NS station is ahead", W.lowerFirst("NS station is ahead"))
        assertEquals("5 m", W.metres(3.0)); assertEquals("40 m", W.metres(42.0)); assertEquals("440 m", W.metres(437.0)); assertEquals("1.2 km", W.metres(1234.0))
        val step = W.Step("Turn right onto Hoogstraat", W.Turn.RIGHT, 0.0, 10.0)
        assertEquals("In 40 m · turn right onto Hoogstraat", W.phrase(41.0, step))
        assertEquals("In 40 metres, turn right onto Hoogstraat", W.spoken(41.0, step))
        assertEquals("→ 40 m · Hoogstraat", W.lockLine(41.0, step, "Platform 4"))
        assertEquals("◉ 20 m · Platform 4", W.lockLine(20.0, W.Step("The destination is on your right", W.Turn.ARRIVE, 10.0, 10.0), "Platform 4"))
        assertEquals("In 60 m · turn left", W.phrase(60.0, W.Step("", W.Turn.LEFT, 0.0, 10.0)))
        assertEquals("Hoogstraat", W.street("Turn right onto Hoogstraat")); assertEquals("Kerkstraat", W.street("Sla rechtsaf naar de Kerkstraat"))
        assertNull(W.street("Turn right"))
        for (t in W.Turn.entries) assertTrue(t.glyph.isNotEmpty())
    }
}
