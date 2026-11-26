package nl.haltewekker

import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.travel.Nearby
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.ZoneId

/** iOS `NearbyRankTests` and `NearbySearchTests` (0.42, 0.42.2). */
class NearbyTest {
    // MARK: NearbyRankTests
    private val now0 = 1_800_000_000.0
    private val you0 = GeoPoint(51.69, 5.30)
    private fun stop(id: String, name: String, metres: Double, rail: Boolean = false) =
        Nearby.Stop(id, name, you0.lat + metres / 111_320, you0.lon, rail, metres)
    private fun at0(m: Double) = now0 + m * 60

    @Test fun twoSidesOfTheRoad() {
        val g = Nearby.groups(listOf(stop("a1", "Bolkenplein", 400.0), stop("a2", "Bolkenplein ", 420.0), stop("b", "Rembrandtlaan", 300.0)), 1000.0)
        assertEquals(listOf("Rembrandtlaan", "Bolkenplein"), g.map { it.name }); assertEquals(listOf("a1", "a2"), g[1].ids)
    }

    @Test fun beyondTheRange_sameNameFarOff() {
        val g = Nearby.groups(listOf(stop("a", "Centrum", 300.0), stop("c", "Centrum", 900.0), stop("x", "Far", 1500.0)), 1000.0)
        assertEquals(listOf("centrum"), g.map { it.id }); assertEquals(listOf("a"), g[0].ids)
    }

    @Test fun atMostEight_stations_twelvePlans() {
        val s = (0 until 12).map { stop("s$it", "Stop $it", 100.0 + it * 50) } + (0 until 12).map { stop("t$it", "Stop $it", 110.0 + it * 50) } +
            stop("ns", "Station", 950.0, rail = true)
        val g = Nearby.groups(s, 1000.0)
        assertEquals(Nearby.MAX_GROUPS, g.size); assertTrue(g.any { it.rail })
        assertEquals(Nearby.MAX_PLANS, g.sumOf { it.ids.size }); assertEquals(2, g[0].ids.size); assertEquals(1, g.last().ids.size)
    }

    @Test fun skip() { assertEquals(listOf("b"), Nearby.groups(listOf(stop("a", "A", 300.0), stop("b", "B", 1400.0)), 1600.0, setOf("a")).map { it.id }) }

    @Test fun walk() {
        assertEquals(8, Nearby.plannedWalk(400.0)); assertEquals(1, Nearby.plannedWalk(0.0)); assertEquals(6, Nearby.plannedWalk(400.0, 1.6))
    }

    @Test fun windowShifts() {
        val w = Nearby.window(Nearby.Leave.IN10, now0)
        assertEquals(at0(10.0), w.leave, 0.0); assertEquals(at0(45.0), w.until, 0.0)
        assertTrue(Nearby.catchable(at0(10.0), w)); assertFalse(Nearby.catchable(at0(9.0), w)); assertTrue(Nearby.catchable(at0(52.0), w))
        assertEquals(listOf("Leave now", "In 10 min", "In 20 min"), Nearby.Leave.entries.map { it.title })
    }

    @Test fun sure_yours() {
        val s = Nearby.sure(listOf(0.0, 1.0, 1.0, 2.0, 5.0, 0.5, 1.0, 1.0, 1.0, 1.0), 0.5, 1.0, false)
        assertEquals(90, s.percent); assertEquals(Nearby.Source.Yours(10), s.source); assertEquals(1, s.usual)
        assertEquals("on time 90% of your last 10 rides · usually +1 min", Nearby.sureWords(s))
    }

    @Test fun sure_model() {
        val s = Nearby.sure(listOf(1.0, 2.0), 0.2, 0.9, true)
        assertEquals(72, s.percent); assertEquals(Nearby.Source.Live, s.source); assertNull(s.usual)
        assertEquals("on time about 72% (by live times)", Nearby.sureWords(s))
        assertEquals(Nearby.Source.Estimate, Nearby.sure(emptyList(), 0.1, 1.0, false).source)
    }

    @Test fun sure_lastTwenty() {
        val s = Nearby.sure(List(30) { 10.0 } + List(20) { 0.0 }, 0.0, 1.0, false)
        assertEquals(Nearby.Source.Yours(20), s.source); assertEquals(99, s.percent); assertNull(s.usual)
        assertEquals(1, Nearby.sure(emptyList(), 1.0, 1.0, false).percent)
    }

    @Test fun ring() {
        assertEquals(Nearby.Ring.SOLID, Nearby.ring(Nearby.Sure(90, Nearby.Source.Live, null)))
        assertEquals(Nearby.Ring.DASHED, Nearby.ring(Nearby.Sure(70, Nearby.Source.Yours(8), 2)))
        assertEquals(Nearby.Ring.NEUTRAL, Nearby.ring(Nearby.Sure(95, Nearby.Source.Estimate, null)))
        assertEquals(Nearby.Ring.NEUTRAL, Nearby.ring(null))
    }

    private fun opt(id: String, arrive: Double, leave: Double = 0.0, walk: Int = 5, pct: Int?) =
        Nearby.Option(id, at0(arrive), at0(leave), walk, pct?.let { Nearby.Sure(it, Nearby.Source.Live, null) })

    @Test fun tags() {
        val o = listOf(opt("rembrandt", 17.0, pct = 82), opt("bolken", 19.0, pct = 98), opt("bunders", 22.0, pct = 74), opt("kempkens", 31.0, pct = 61))
        val t = Nearby.tags(o)
        assertEquals(listOf(Nearby.Tag.FASTEST), t["rembrandt"]); assertEquals(listOf(Nearby.Tag.SUREST), t["bolken"])
        assertEquals(listOf(Nearby.Tag.SLOWER), t["bunders"]); assertEquals(listOf(Nearby.Tag.SLOWER), t["kempkens"])
        assertEquals(listOf("rembrandt", "bolken", "bunders", "kempkens"), Nearby.ordered(o).map { it.id })
    }

    @Test fun fastestAlsoSurest() {
        val t = Nearby.tags(listOf(opt("a", 17.0, pct = 95), opt("b", 18.0, pct = 95), opt("c", 19.0, pct = 80)))
        assertEquals(listOf(Nearby.Tag.FASTEST, Nearby.Tag.SUREST), t["a"]); assertNull(t["b"])
    }

    @Test fun fastestTie() {
        val o = listOf(opt("far", 20.0, walk = 9, pct = null), opt("near", 20.0, walk = 3, pct = null))
        assertEquals("near", Nearby.fastest(o)?.id); assertEquals(listOf(Nearby.Tag.FASTEST), Nearby.tags(o)["near"])
        assertTrue(Nearby.tags(emptyList()).isEmpty())
    }

    @Test fun colours() {
        assertEquals(0x3DD598, Nearby.color(0.0)); assertEquals(0xE86F5A, Nearby.color(1.0)); assertEquals(0xC9D45A, Nearby.color(1.0 / 3))
        assertEquals(4.0 / 14, Nearby.fraction(at0(18.0), at0(14.0), at0(28.0)), 0.0001)
        assertEquals(0.25, Nearby.fraction(at0(16.0), at0(14.0), at0(16.0)), 0.0001)
    }

    @Test fun frame() {
        val f = Nearby.frame(you0, listOf(GeoPoint(you0.lat + 0.01, you0.lon + 0.02)))
        assertEquals(you0.lat + 0.005, f.lat, 1e-9); assertEquals(you0.lon + 0.01, f.lon, 1e-9)
        assertEquals(0.014, f.latDelta, 1e-9); assertEquals(0.028, f.lonDelta, 1e-9)
        assertEquals(600 / 111_320.0, Nearby.frame(you0, emptyList()).latDelta, 1e-9)
    }

    @Test fun stopsAwayWords() {
        assertEquals(4, Nearby.stopsAway(3, false, 6)); assertEquals(0, Nearby.stopsAway(6, true, 6)); assertNull(Nearby.stopsAway(7, false, 6))
        assertEquals("in 9 min · 4 stops", Nearby.comingWords(9, 4)); assertEquals("in 2 min · next stop", Nearby.comingWords(2, 1))
        assertEquals("in 14 min", Nearby.comingWords(14, null)); assertEquals("GPS 20 s", Nearby.gpsAge(20.0)); assertEquals("GPS 1 min", Nearby.gpsAge(75.0))
    }

    // MARK: NearbySearchTests
    private val utc = ZoneId.of("UTC")
    private val now = 1_800_000_000.0 + 15 * 3600 + 10 * 60
    private val you = GeoPoint(51.6167, 5.5440)
    private fun at(m: Double) = now + m * 60
    private fun dep(door: Double, walk: Double = 6.0, ride: Double = 75.0, wait: Double = 0.0) =
        Nearby.Dep(at(door), at(door + walk), at(door + walk + ride), false, wait * 60)

    @Test fun lateEvening_halfHourBuses() {
        val deps = listOf(dep(-5.0), dep(25.0), dep(55.0))
        for (l in Nearby.Leave.entries) {
            val w = Nearby.window(l, now)
            val s = Nearby.shown(deps, w)
            assertTrue(s.size >= 2); assertFalse(0 in s); assertNotNull(Nearby.best(deps, w))
        }
        val w10 = Nearby.window(Nearby.Leave.IN10, now)
        assertEquals(listOf(1, 2), Nearby.shown(deps, w10)); assertEquals(Nearby.Best(1, true), Nearby.best(deps, w10))
    }

    @Test fun nextOnes_shownNotRanked() {
        val w = Nearby.window(Nearby.Leave.IN10, now)
        val deps = listOf(dep(55.0), dep(85.0))
        assertEquals(listOf(0, 1), Nearby.shown(deps, w)); assertEquals(Nearby.Best(0, false), Nearby.best(deps, w))
    }

    @Test fun windowFilteredLocally() {
        val deps = listOf(dep(2.0), dep(12.0), dep(22.0), dep(32.0), dep(70.0))
        assertEquals(listOf(0, 1, 2, 3), Nearby.shown(deps, Nearby.window(Nearby.Leave.NOW, now)))
        assertEquals(listOf(1, 2, 3), Nearby.shown(deps, Nearby.window(Nearby.Leave.IN10, now)))
        assertEquals(listOf(2, 3), Nearby.shown(deps, Nearby.window(Nearby.Leave.IN20, now)))
        assertEquals(2, Nearby.best(deps, Nearby.window(Nearby.Leave.IN20, now))?.index)
    }

    @Test fun walkCountedOnce() {
        val w = Nearby.window(Nearby.Leave.IN10, now)
        val d = Nearby.Dep(at(10.0), at(18.0), at(90.0))
        assertTrue(Nearby.catchable(d.door, w)); assertEquals(listOf(0), Nearby.shown(listOf(d), w))
        assertEquals(at(17.0), Nearby.planAt(w, 8, now), 0.0); assertEquals(at(-1.0), Nearby.planAt(Nearby.window(Nearby.Leave.NOW, now), 0, now), 0.0)
    }

    @Test fun cancelledNotShown() { assertTrue(Nearby.shown(listOf(dep(5.0).copy(cancelled = true)), Nearby.window(Nearby.Leave.NOW, now)).isEmpty()) }

    @Test fun overnight() {
        val soon = Nearby.Dep(at(5.0), at(7.0), at(99.0))
        val night = Nearby.Dep(at(6.0), at(8.0), at(416.0), longestWait = 6 * 3600.0)
        val w = Nearby.window(Nearby.Leave.NOW, now)
        assertFalse(Nearby.late(soon, w)); assertTrue(Nearby.late(night, w)); assertFalse(Nearby.ranked(night, w))
        val s = Nearby.split(listOf(soon, night), w)
        assertEquals(listOf(0), s.first); assertEquals(listOf(1), s.second)
        assertEquals("Tomorrow morning", Nearby.laterTitle(night.arrival, now, utc))
        val o = listOf(Nearby.Option("bolken", soon.arrival, soon.departure, 2, Nearby.Sure(80, Nearby.Source.Live, null)),
            Nearby.Option("night", night.arrival, night.departure, 3, Nearby.Sure(99, Nearby.Source.Live, null), ranked = false))
        val t = Nearby.tags(o)
        assertEquals(listOf(Nearby.Tag.FASTEST, Nearby.Tag.SUREST), t["bolken"]); assertNull(t["night"])
        assertEquals(listOf("bolken", "night"), Nearby.ordered(o).map { it.id })
    }

    @Test fun dayWord() {
        assertNull(Nearby.dayWord(at(20.0), now, utc)); assertNull(Nearby.dayWord(at(100.0), now, utc))
        assertEquals("tomorrow", Nearby.dayWord(at(416.0), now, utc)); assertEquals("Sun", Nearby.dayWord(at(48 * 60.0), now, utc))
        assertEquals("Later · Sun", Nearby.laterTitle(at(48 * 60.0), now, utc))
    }

    @Test fun surestAt70() {
        val o = listOf(Nearby.Option("a", at(60.0), at(5.0), 3, Nearby.Sure(55, Nearby.Source.Estimate, null)),
            Nearby.Option("b", at(64.0), at(7.0), 3, Nearby.Sure(60, Nearby.Source.Estimate, null)))
        val t = Nearby.tags(o)
        assertEquals(listOf(Nearby.Tag.FASTEST), t["a"]); assertNull(t["b"])
        assertNull(Nearby.surestOf(listOf(55, 60), 0)); assertEquals(1, Nearby.surestOf(listOf(55, 80, 80), 0)); assertNull(Nearby.surestOf(listOf(90, 80), 0))
    }

    @Test fun requestBudget() {
        assertEquals(1600.0, Nearby.nextPlan(0, 0, false, false, true)); assertEquals(3000.0, Nearby.nextPlan(1, 2, true, false, false))
        assertNull(Nearby.nextPlan(1, 3, true, false, false)); assertNull(Nearby.nextPlan(1, 0, false, false, false))
        assertNull(Nearby.nextPlan(1, 0, true, false, true)); assertNull(Nearby.nextPlan(2, 0, true, true, false))
        assertEquals(2, Nearby.MAX_SEARCH_PLANS); assertTrue(Nearby.MAX_CONCURRENT <= 2)
        assertEquals(29 * 60, Nearby.preTransit(1600.0)); assertEquals(Nearby.MAX_PRE_TRANSIT, Nearby.preTransit(3000.0))
    }

    @Test fun failedPlan_neverNoBusOrTrain() {
        assertEquals(3000.0, Nearby.nextPlan(1, 0, false, true, false))
        var s = Nearby.Situation(planFailed = true)
        val failed = Nearby.statusLine(s, "3 km")?.first ?: ""
        assertTrue(failed.startsWith("Couldn’t check")); assertFalse(failed.contains("No bus or train"))
        s = s.copy(cooling = true); assertTrue((Nearby.statusLine(s, "3 km")?.first ?: "").contains("the planner is busy"))
        val some = Nearby.Situation(options = 2, unchecked = 3)
        assertEquals("Couldn’t check 3 stops just now (no answer in time). Tap one to try again.", Nearby.statusLine(some, "1.6 km")?.first)
        assertNull(Nearby.statusLine(some.copy(unchecked = 0), "1.6 km"))
    }

    @Test fun noBusOrTrain_only() {
        val s = Nearby.Situation()
        assertEquals("No bus or train from the stops within 1.6 km in this time. Try later, or see your trip.", Nearby.statusLine(s, "1.6 km")?.first)
        assertFalse((Nearby.statusLine(s.copy(seed = true), "1.6 km")?.first ?: "").contains("No bus or train"))
        assertFalse((Nearby.statusLine(s.copy(seed = true, fallback = true), "1.6 km")?.first ?: "").contains("No bus or train"))
        assertEquals(true, Nearby.statusLine(Nearby.Situation(busy = true), "1.6 km")?.second)
    }

    private fun group(id: String, name: String, ids: List<String>, north: Double, rail: Boolean = false) =
        Nearby.Group(id, name, ids, you.lat + north / 111_320, you.lon, rail, kotlin.math.abs(north))
    private fun boarding(id: String, name: String, north: Double?, rail: Boolean = false) =
        Nearby.Boarding(id, name, north?.let { you.lat + it / 111_320 }, north?.let { you.lon }, rail)

    @Test fun groupedByBoarding() {
        val gs = listOf(group("bolkenplein", "Bolkenplein", listOf("b1", "b2"), 300.0), group("markt", "Markt", listOf("m1"), -500.0),
            group("rail:s", "Station", listOf("s"), 2000.0, true))
        assertEquals(0, Nearby.groupIndex(boarding("b2", "Bolkenplein", 310.0), gs)); assertEquals(0, Nearby.groupIndex(boarding("b9", "Bolkenplein", 420.0), gs))
        assertEquals(1, Nearby.groupIndex(boarding("x", "Markt, perron A", -560.0), gs))
        assertEquals(2, Nearby.groupIndex(boarding("p3", "Station perron 3", 2250.0, true), gs))
        assertNull(Nearby.groupIndex(boarding("c", "Busstation", 900.0), gs)); assertNull(Nearby.groupIndex(boarding("b7", "Bolkenplein", 1400.0), gs))
    }

    @Test fun seedsOwnStop() {
        val gs = listOf(group("bolkenplein", "Bolkenplein", listOf("b1"), 300.0))
        val b = boarding("c1", "Busstation", 900.0)
        assertNull(Nearby.groupIndex(b, gs))
        val g = Nearby.newGroup(b, you, gs.map { it.id }.toSet())
        assertEquals("busstation", g?.id); assertEquals(listOf("c1"), g?.ids); assertEquals(900.0, g!!.metres, 15.0)
        assertEquals("bolkenplein@b7", Nearby.newGroup(boarding("b7", "Bolkenplein", 1400.0), you, setOf("bolkenplein"))?.id)
        assertNull(Nearby.newGroup(boarding("z", "Nowhere", null), you, emptySet()))
    }

    @Test fun mergeCircles() {
        val pins = listOf(Nearby.Pin("late", you.lat, you.lon, at(66.0)), Nearby.Pin("early", you.lat + 20 / 111_320.0, you.lon, at(49.0)),
            Nearby.Pin("apart", you.lat + 400 / 111_320.0, you.lon, at(70.0)))
        val c = Nearby.merge(pins, 60.0)
        assertEquals(listOf("early", "apart"), c.map { it.id }); assertEquals(listOf("early", "late"), c[0].members)
        for (a in c) for (b in c) if (a.id != b.id) assertTrue(Geo.metres(GeoPoint(a.lat, a.lon), GeoPoint(b.lat, b.lon)) >= 60)
        assertEquals(3, Nearby.merge(pins, 5.0).size)
    }

    @Test fun logLines() {
        assertEquals("nearby · r 1.6 km · stops 9 · plans 1 (+1 page) · ways 6 · 0 failed · 0.8 s · 320 KB", Nearby.logLine(1600.0, 9, 1, 1, 6, 0, 0.84, 320 * 1024))
        assertEquals("nearby · r 3.0 km · stops 4 · plans 2 · ways 1 · 1 failed · 10.0 s · 0 KB · cooling", Nearby.logLine(3000.0, 4, 2, 0, 1, 1, 10.0, 0, "cooling"))
        assertEquals("nearby stop · plan · ways 3 · times 12 · 0.9 s · 150 KB", Nearby.stopLogLine(true, false, 3, 12, 0.9, 150 * 1024))
        assertEquals("nearby stop · ways 2 · 0.2 s · 4 KB", Nearby.stopLogLine(false, false, 2, null, 0.2, 4096))
    }
}
