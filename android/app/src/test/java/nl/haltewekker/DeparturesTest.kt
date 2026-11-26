package nl.haltewekker

import nl.haltewekker.travel.FromStop
import nl.haltewekker.travel.GhostDepartures
import nl.haltewekker.travel.StickyTrips
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** iOS `GhostDeparturesTests`, `FromStopTests`, `StickyTripsTests` (0.40). */
class DeparturesTest {
    private val now = 5_000_000.0
    private fun at(m: Double) = now + m * 60
    private fun dep(id: String, trip: String? = null, line: String = "306", head: String = "Veghel", stop: String = "Schijndel, Centrum",
                    min: Double, sched: Double? = null, live: Boolean = false, cancelled: Boolean = false, vehicle: Boolean = false) =
        GhostDepartures.Dep(id, trip ?: id, line, head, stop, at(min), at(sched ?: min), live, cancelled, vehicle)

    @Test fun ghost_sameJourneyFromTwoSources() {
        val rows = GhostDepartures.clean(listOf(dep("a", "ovapi:1", min = 20.0), dep("b", "arriva:9", head = "Veghel Busstation", min = 22.0, sched = 20.0, live = true)), now)
        assertEquals(listOf("b"), rows.map { it.dep.id }); assertEquals(GhostDepartures.Status.LIVE, rows.first().status)
        assertEquals(2, GhostDepartures.clean(listOf(dep("a", head = "Veghel", min = 20.0, live = true), dep("b", head = "'s-Hertogenbosch Centraal", min = 20.0, live = true)), now).size)
        assertEquals(listOf("b"), GhostDepartures.clean(listOf(dep("a", min = 5.0, live = true, cancelled = true), dep("b", min = 12.0, live = true)), now).map { it.dep.id })
    }

    @Test fun ghost_unsure() {
        val rows = GhostDepartures.clean(listOf(dep("ghost", min = 8.0), dep("real", "t2", min = 12.0, live = true)), now)
        assertEquals(listOf("real", "ghost"), rows.map { it.dep.id }); assertEquals(GhostDepartures.Status.UNSURE, rows.last().status)
        assertEquals(GhostDepartures.Status.TIMETABLE, GhostDepartures.clean(listOf(dep("later", min = 30.0), dep("real", "t2", min = 5.0, live = true)), now).first { it.dep.id == "later" }.status)
        assertEquals(GhostDepartures.Status.TIMETABLE, GhostDepartures.clean(listOf(dep("a", line = "9", min = 5.0)), now).first().status)
        assertEquals(GhostDepartures.Status.UNSURE, GhostDepartures.clean(listOf(dep("a", min = 5.0)), now, setOf("306")).first().status)
        assertEquals(GhostDepartures.Status.TIMETABLE, GhostDepartures.clean(listOf(dep("a", min = 5.0, vehicle = true), dep("b", "t2", min = 9.0, live = true)), now).first { it.dep.id == "a" }.status)
    }

    @Test fun ghost_gone() {
        assertEquals(listOf("live"), GhostDepartures.clean(listOf(dep("ghost", min = -2.0), dep("live", "t2", min = -2.0, live = true)), now).map { it.dep.id })
        assertTrue(GhostDepartures.clean(listOf(dep("ghost", min = -0.5), dep("live", "t2", min = 4.0, live = true)), now).any { it.dep.id == "ghost" })
    }

    @Test fun ghost_options() {
        val o1 = GhostDepartures.Option("ghost", "306", at(6.0), at(6.0), false, false)
        val o2 = GhostDepartures.Option("real", "306", at(21.0), at(20.0), true, false)
        val o3 = GhostDepartures.Option("train", "IC", at(30.0), at(30.0), false, false)
        assertEquals(listOf("real", "train", "ghost"), GhostDepartures.order(listOf(o1, o2, o3), now))
        assertEquals(GhostDepartures.Status.UNSURE, GhostDepartures.statuses(listOf(o1, o2), now)["ghost"])
        assertEquals(listOf("ghost"), GhostDepartures.order(listOf(o1), now))
    }

    @Test fun ghost_normalized() {
        assertEquals("shertogenboschcentraal", GhostDepartures.normalized("'s-Hertogenbosch, Centraal"))
        assertTrue(GhostDepartures.sameHeadsign("Veghel", "Veghel Busstation"))
        assertTrue(GhostDepartures.sameHeadsign("", "Uden"))
        assertFalse(GhostDepartures.sameHeadsign("Uden", "Veghel"))
    }

    private val n2 = 9_000_000.0
    private fun at2(m: Double) = n2 + m * 60
    private fun fd(id: String, line: String = "306", min: Double, sched: Double? = null, live: Boolean = true, cancelled: Boolean = false,
                   platform: String? = null, head: String = "'s-Hertogenbosch") =
        FromStop.Dep(id, id, line, head, at2(min), at2(sched ?: min), live, cancelled, platform, false, "Veghel, Bolkenplein")

    @Test fun fromStop_board() {
        val deps = listOf(fd("a", min = 3.0), fd("x", "158", 4.0, head = "Uden"), fd("b", "305", 9.0), fd("c", min = 18.0), fd("y", "158", 25.0, head = "Uden"))
        val b = FromStop.board(deps, setOf("306", "305"), "c", at2(5.0), n2)
        assertEquals(listOf("a", "b", "c"), b.useful.map { it.id }); assertEquals(listOf("x", "y"), b.other.map { it.id })
        assertTrue(b.useful[2].current)
        val g = FromStop.board(listOf(fd("a", min = 3.0), fd("b", min = 9.0), fd("c", min = 18.0)), setOf("306"), "b", at2(5.0), n2)
        assertTrue(g.useful[0].dimmed); assertFalse(g.useful[0].switchable); assertFalse(g.useful[1].switchable); assertTrue(g.useful[2].switchable)
        val many = FromStop.board((0 until 9).map { fd("d$it", min = 2.0 + 5 * it) }, setOf("306"), "d8", n2, n2)
        assertEquals(FromStop.MAX_USEFUL, many.useful.size); assertEquals("d8", many.useful.last().id)
        val gh = FromStop.board(listOf(fd("ghost", min = 6.0, live = false), fd("gone", min = 12.0, cancelled = true), fd("real", min = 10.0)), setOf("306"), null, n2, n2)
        assertEquals(listOf("real", "ghost"), gh.useful.map { it.id }); assertEquals(GhostDepartures.Status.UNSURE, gh.useful.last().status)
        val l = FromStop.board(listOf(fd("a", min = 7.0, sched = 4.0, platform = "B"), fd("t", min = 9.0, live = false)), setOf("306"), null, n2, n2)
        assertEquals("+3", l.useful.first().late); assertEquals("Stand B", FromStop.place(l.useful[0].dep))
        assertNull(l.useful.first { it.id == "t" }.late); assertEquals("in 7 min", FromStop.countdown(l.useful[0].dep, n2))
        assertEquals(listOf("a"), FromStop.board(listOf(fd("old", min = -3.0), fd("a", min = 5.0)), setOf("306"), null, n2, n2).useful.map { it.id })
    }

    private val n3 = 6_000_000.0
    private fun at3(m: Double) = n3 + m * 60
    private fun item(id: String, bus: String? = null, departs: Double, leave: Double? = null, cancelled: Boolean = false) =
        StickyTrips.Item(id, bus ?: "bus-$id", at3(departs), at3(leave ?: (departs - 8)), cancelled)

    @Test fun sticky_merge() {
        assertEquals(listOf("b", "c"), StickyTrips.merge(listOf(item("a", departs = -3.0), item("b", departs = 4.0), item("c", departs = 20.0)), emptyList(), StickyTrips.Answer.FAILED, null, now = n3))
        assertEquals(listOf("b"), StickyTrips.merge(listOf(item("b", departs = 4.0)), emptyList(), StickyTrips.Answer.WHOLE, null, now = n3))
        assertEquals(listOf("b2", "d", "c"), StickyTrips.merge(listOf(item("b", departs = 4.0), item("c", departs = 20.0)),
            listOf(item("b2", "bus-b", 5.0), item("d", departs = 12.0)), StickyTrips.Answer.PARTIAL, null, now = n3))
        val out = StickyTrips.merge(listOf(item("b", departs = 3.0, leave = -4.0), item("c", departs = 20.0)), listOf(item("d", departs = 18.0), item("e", departs = 33.0)),
            StickyTrips.Answer.WHOLE, "bus-b", now = n3)
        assertEquals(listOf("b", "d", "e"), out)
        assertEquals(listOf("d"), StickyTrips.merge(listOf(item("b", departs = -1.5)), listOf(item("d", departs = 18.0)), StickyTrips.Answer.WHOLE, "bus-b", now = n3))
        assertEquals(listOf("d"), StickyTrips.merge(listOf(item("b", departs = 2.0)), listOf(item("d", departs = 18.0)), StickyTrips.Answer.WHOLE, "bus-b", onIt = true, now = n3))
        assertEquals(listOf("d"), StickyTrips.merge(listOf(item("b", departs = 4.0, cancelled = true)), listOf(item("d", departs = 18.0)), StickyTrips.Answer.WHOLE, "bus-b", now = n3))
    }

    @Test fun sticky_pick() {
        val items = listOf(item("b", departs = 3.0, leave = -4.0), item("d", departs = 18.0, leave = 10.0))
        assertEquals(0, StickyTrips.pick(items, 0, true, n3)); assertEquals(1, StickyTrips.pick(items, 0, false, n3))
        assertEquals(1, StickyTrips.pick(items, 0, null, n3)); assertEquals(1, StickyTrips.pick(items, null, null, n3))
        assertEquals(0, StickyTrips.pick(listOf(item("x", departs = 9.0, leave = 2.0), item("b", departs = 40.0, leave = 30.0)), 1, true, n3))
        assertEquals("bus-b", StickyTrips.held(item("b", departs = 4.0), n3)); assertNull(StickyTrips.held(item("b", departs = -2.0), n3)); assertNull(StickyTrips.held(null, n3))
        assertEquals(true, StickyTrips.reachable(200.0, at3(3.0), n3)); assertEquals(false, StickyTrips.reachable(900.0, at3(3.0), n3))
        assertNull(StickyTrips.reachable(null, at3(3.0), n3))
    }
}
