package nl.haltewekker

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import nl.haltewekker.travel.Nearby
import nl.haltewekker.travel.NearbyCards
import nl.haltewekker.travel.NearbyCards.Point
import nl.haltewekker.travel.NearbyCards.Rect
import nl.haltewekker.travel.NearbySlot
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File

/**
 * (0.10.11) iOS `NearbyCardsTests` (0.42.15): the tags (Fastest and Surest, both on one card), the words (no walking
 * emoji), the layout (never on top of anything), how sure by the time of day; against docs/nearby-cards-vectors.json.
 */
class NearbyCardsTest {
    private val v: JsonObject by lazy {
        val f = listOf("../../docs/nearby-cards-vectors.json", "../docs/nearby-cards-vectors.json", "docs/nearby-cards-vectors.json").map(::File).first { it.exists() }
        Json.parseToJsonElement(f.readText()).jsonObject
    }
    private val now = 1_800_000_000.0
    private fun at(m: Double) = now + m * 60
    private fun opt(id: String, arrive: Double, pct: Int?, ranked: Boolean = true) =
        Nearby.Option(id, at(arrive), at(0.0), 5, pct?.let { Nearby.Sure(it, Nearby.Source.Live, null) }, ranked)

    @Test fun badges_apartOrBoth() {
        val apart = NearbyCards.badges(listOf(opt("veghel", 7.0, 92), opt("rembrandt", 14.0, 97), opt("bolken", 31.0, 4)))
        assertEquals(NearbyCards.Badge(fastest = true), apart["veghel"])
        assertEquals(NearbyCards.Badge(surest = true), apart["rembrandt"])
        assertNull(apart["bolken"])
        val both = NearbyCards.badges(listOf(opt("veghel", 7.0, 92), opt("bolken", 31.0, 4)))
        assertEquals(NearbyCards.Badge(true, true), both["veghel"])
        assertEquals(listOf(Nearby.Tag.FASTEST, Nearby.Tag.SUREST), both["veghel"]!!.tags)
    }

    @Test fun badges_noSurestUnder70_neverOvernight() {
        val low = NearbyCards.badges(listOf(opt("a", 7.0, 60), opt("b", 9.0, 69)))
        assertEquals(NearbyCards.Badge(fastest = true), low["a"]); assertNull(low["b"])
        val late = NearbyCards.badges(listOf(opt("night", 3.0, 99, ranked = false), opt("a", 7.0, 80)))
        assertNull(late["night"]); assertEquals(NearbyCards.Badge(true, true), late["a"])
        assertTrue(NearbyCards.badges(emptyList()).isEmpty())
    }

    @Test fun edge() {
        assertEquals(NearbyCards.Edge.SUREST, NearbyCards.edge(NearbyCards.Badge(true, true)))
        assertEquals(NearbyCards.Edge.FASTEST, NearbyCards.edge(NearbyCards.Badge(fastest = true)))
        assertEquals(NearbyCards.Edge.PLAIN, NearbyCards.edge(null))
        assertTrue(NearbyCards.edgeWidth(NearbyCards.Edge.FASTEST) > NearbyCards.edgeWidth(NearbyCards.Edge.PLAIN))
        assertTrue(NearbyCards.walkDashed(NearbyCards.Edge.PLAIN)); assertFalse(NearbyCards.walkDashed(NearbyCards.Edge.SUREST))
        assertEquals(0x3DD598, NearbyCards.color(NearbyCards.Edge.SUREST)); assertEquals(0xE8A33D, NearbyCards.color(NearbyCards.Edge.FASTEST))
    }

    @Test fun surestBoth() {
        assertEquals(1, NearbyCards.surestBoth(listOf(92, 97, 4), 0))
        assertEquals(0, NearbyCards.surestBoth(listOf(97, 92, 97), 0))
        assertNull(NearbyCards.surestBoth(listOf(60, 65), 0)); assertNull(NearbyCards.surestBoth(emptyList(), 0))
    }

    @Test fun words() {
        assertEquals("leave 10:41 · 9 min walk", NearbyCards.leaveWords("10:41", 9))
        assertEquals("9 min walk", NearbyCards.walkWords(9))
        val live = Nearby.Sure(92, Nearby.Source.Live, null)
        assertEquals("92% on time", NearbyCards.onTimeWords(live)); assertEquals("estimate", NearbyCards.estimateWord(live))
        assertNull(NearbyCards.estimateWord(Nearby.Sure(92, Nearby.Source.Yours(12), null)))
    }

    private fun pt(e: Any?): Point? = (e as? JsonArray)?.let { Point(it[0].jsonPrimitive.double, it[1].jsonPrimitive.double) }
    private val bounds: Rect get() = v["bounds"]!!.jsonArray.map { it.jsonPrimitive.double }.let { Rect(it[0], it[1], it[2], it[3]) }
    private fun items(c: JsonObject) = c["items"]!!.jsonArray.map { val i = it.jsonObject
        NearbyCards.Item(i["id"]!!.jsonPrimitive.content, Point(i["x"]!!.jsonPrimitive.double, i["y"]!!.jsonPrimitive.double), i["tagged"]!!.jsonPrimitive.boolean) }
    private fun dots(c: JsonObject) = c["dots"]!!.jsonArray.map { pt(it)!! }

    @Test fun layout_vectors() {
        val list = v["layout"]!!.jsonArray
        assertTrue(list.size >= 8)
        for (e in list) {
            val c = e.jsonObject
            val name = c["name"]!!.jsonPrimitive.content
            val got = NearbyCards.layout(items(c), bounds, pt(c["you"]), dots(c))
            val want = c["placed"]!!.jsonArray
            assertEquals(name, want.size, got.size)
            for ((g, we) in got.zip(want)) {
                val w = we.jsonObject
                assertEquals(name, w["id"]!!.jsonPrimitive.content, g.id)
                assertEquals("$name ${g.id}", w["kind"]!!.jsonPrimitive.content, g.kind.raw)
                (w["rect"] as? JsonArray)?.map { it.jsonPrimitive.double }?.let { r ->
                    assertEquals("$name ${g.id}", r[0], g.rect.x, 0.01); assertEquals("$name ${g.id}", r[1], g.rect.y, 0.01)
                    assertEquals(r[2], g.rect.w, 0.01); assertEquals(r[3], g.rect.h, 0.01)
                }
                val l = pt(w["leader"])
                assertEquals("$name ${g.id} leader", l == null, g.leader == null)
                if (l != null) { assertEquals(l.x, g.leader!!.x, 0.01); assertEquals(l.y, g.leader!!.y, 0.01) }
            }
        }
    }

    private fun assertClear(placed: List<NearbyCards.Placed>, items: List<NearbyCards.Item>, b: Rect, you: Point?, dots: List<Point>, name: String) {
        val shown = placed.filter { it.kind != NearbyCards.Kind.HIDDEN }
        val blocks = dots.map { Rect(it.x - 7, it.y - 7, 14.0, 14.0) } + items.map { Rect(it.at.x - 7, it.at.y - 7, 14.0, 14.0) } +
            listOfNotNull(you?.let { Rect(it.x - 20, it.y - 20, 40.0, 40.0) })
        for ((k, p) in shown.withIndex()) {
            val r = p.rect
            assertTrue("$name ${p.id} inside", r.x >= b.x - 1e-9 && r.y >= b.y - 1e-9 && r.maxX <= b.maxX + 1e-9 && r.maxY <= b.maxY + 1e-9)
            for (q in shown.drop(k + 1)) if (r.touches(q.rect, 0.0)) fail("$name: ${p.id} on ${q.id}")
            for (bl in blocks) if (r.touches(bl, 0.0)) fail("$name: ${p.id} on a dot")
            for (q in shown) if (q.id != p.id) {
                val l = q.leader ?: continue
                val i = items.first { it.id == q.id }
                if (r.crossed(l, i.at)) fail("$name: ${p.id} on ${q.id}'s leader")
            }
        }
    }

    @Test fun layout_neverOverlaps_vectors() {
        for (e in v["layout"]!!.jsonArray) {
            val c = e.jsonObject
            val it0 = items(c)
            assertClear(NearbyCards.layout(it0, bounds, pt(c["you"]), dots(c)), it0, bounds, pt(c["you"]), dots(c), c["name"]!!.jsonPrimitive.content)
        }
    }

    @Test fun layout_neverOverlaps_synthetic() {
        val b = Rect(8.0, 56.0, 374.0, 360.0)
        var seed = 42UL
        fun rnd(): Double { seed = seed * 6364136223846793005UL + 1442695040888963407UL; return (seed shr 33).toDouble() / (1L shl 31).toDouble() }
        for (n in listOf(2, 3, 5, 8)) for (k in 0 until 60) {
            val cx = 20 + rnd() * 350; val cy = 62 + rnd() * 348
            val spread = if (n == 8) 300.0 else 100.0
            val its = (0 until n).map { i ->
                val x = minOf(b.maxX - 2, maxOf(b.x + 2, cx + (rnd() - 0.5) * spread))
                val y = minOf(b.maxY - 2, maxOf(b.y + 2, cy + (rnd() - 0.5) * spread))
                NearbyCards.Item("s$i", Point(x, y), i < 2)
            }
            val you = Point(its[0].at.x, maxOf(b.y, its[0].at.y - 50))
            val got = NearbyCards.layout(its, b, you)
            assertClear(got, its, b, you, emptyList(), "n$n #$k")
            if (n <= 3) assertNotEquals("n$n #$k", NearbyCards.Kind.HIDDEN, got[0].kind)
        }
    }

    @Test fun layout_pillsFromTheFifth_offTheMapHidden() {
        val its = (0 until 6).map { NearbyCards.Item("s$it", Point(100.0 + it * 150, 500.0), false) } + NearbyCards.Item("out", Point(1200.0, 10.0), false)
        val got = NearbyCards.layout(its, Rect(0.0, 0.0, 1000.0, 1000.0), null)
        assertEquals(listOf("card", "card", "card", "card", "pill", "pill", "hidden"), got.map { it.kind.raw })
        assertNull(got[0].leader); assertEquals(500 - NearbyCards.GAP, got[0].rect.maxY, 1e-9)
    }

    private fun entries() = v["slotEntries"]!!.jsonArray.map { val e = it.jsonObject
        NearbySlot.Entry(e["minute"]!!.jsonPrimitive.int, e["weekend"]!!.jsonPrimitive.boolean, e["delay"]!!.jsonPrimitive.double) }

    @Test fun slot_vectors() {
        val e = entries()
        for (x in v["picks"]!!.jsonArray) {
            val c = x.jsonObject
            val m = c["minute"]!!.jsonPrimitive.int; val we = c["weekend"]!!.jsonPrimitive.boolean
            val (d, w) = NearbySlot.pick(e, m, we)
            assertEquals("$m $we", c["delays"]!!.jsonArray.map { it.jsonPrimitive.double }, d)
            assertEquals("$m $we", c["window"]!!.jsonPrimitive.int, w)
            assertEquals("$m $we", c["percent"]!!.jsonPrimitive.int, Nearby.sure(d, 0.4, 1.0, true).percent)
        }
        for (x in v["periods"]!!.jsonArray) {
            val c = x.jsonObject
            val p = NearbySlot.period(c["hour"]!!.jsonPrimitive.double, c["weekend"]!!.jsonPrimitive.boolean)
            assertEquals(c["name"]!!.jsonPrimitive.content, p.name)
            assertEquals(c["bus"]!!.jsonPrimitive.double, p.bus, 1e-9); assertEquals(c["train"]!!.jsonPrimitive.double, p.train, 1e-9)
            assertEquals(c["late3"]!!.jsonPrimitive.double, NearbySlot.lateChance(p.bus, 3.0), 1e-4)
        }
        for (x in v["slotWords"]!!.jsonArray) {
            val c = x.jsonObject
            assertEquals(c["text"]!!.jsonPrimitive.content, NearbySlot.slotWords(c["minute"]!!.jsonPrimitive.int, c["weekend"]!!.jsonPrimitive.boolean))
        }
    }

    @Test fun sameLine_1300_vs_1900_differ() {
        val e = entries()
        val a = Nearby.sure(NearbySlot.pick(e, 13 * 60, false).first, 0.3, 1.0, false)
        val b = Nearby.sure(NearbySlot.pick(e, 19 * 60, false).first, 0.3, 1.0, false)
        assertTrue(a.percent > b.percent); assertEquals(4, a.onTime); assertEquals(1, b.onTime)
        val day = NearbySlot.lateChance(NearbySlot.period(13.0, false).bus, 3.0)
        val evening = NearbySlot.lateChance(NearbySlot.period(19.0, false).bus, 3.0)
        val rush = NearbySlot.lateChance(NearbySlot.period(17.5, false).bus, 3.0)
        assertTrue(evening > day); assertTrue(rush > evening)
    }

    @Test fun slot_widens_weekendsApart() {
        val e = listOf(70, 80, 100, 150).map { NearbySlot.Entry(600 + it, false, 0.0) } + listOf(0, 5, 10, 15).map { NearbySlot.Entry(600 + it, true, 9.0) }
        val (d, w) = NearbySlot.pick(e, 600, false)
        assertEquals(120, w); assertEquals(3, d.size)
        val (dw, ww) = NearbySlot.pick(e, 600, true)
        assertEquals(60, ww); assertEquals(listOf(9.0, 9.0, 9.0, 9.0), dw)
        assertEquals(15, NearbySlot.apart(5, 1430))
    }

    @Test fun explain_namesTheSlot() {
        val s = Nearby.sure(listOf(0.0, 1.0, 2.0, 8.0, 1.0, 0.0, 0.0), 0.3, 1.0, false).copy(window = 60)
        assertEquals("Based on your last 7 rides on the 305 to Eindhoven around 19:00 on weekdays: 6 on time (less than 3 min late).",
            NearbySlot.explain(s, "305", "Eindhoven", "around 19:00 on weekdays", "evening", 0))
        assertTrue(NearbySlot.explain(s.copy(window = 120), "305", "Eindhoven", "around 19:00 on weekdays", "evening", 0)
            .endsWith("Counted up to 120 min either side: too few closer to that time."))
        val t = NearbySlot.explain(Nearby.sure(emptyList(), 0.3, 0.9, true), "305", "Eindhoven", "around 19:00 on weekdays", "evening", 1)
        assertTrue(t, t.startsWith("Estimated: fewer than 4 of your own rides around 19:00 on weekdays."))
        assertTrue(t, t.endsWith("Times the chance you make your change (about 90%)."))
        assertEquals("Estimated from the time of day only (around 13:00 on weekdays, daytime): no live times of the 305 yet.",
            NearbySlot.explain(Nearby.sure(emptyList(), 0.3, 1.0, false), "305", "Eindhoven", "around 13:00 on weekdays", "daytime", 0))
    }
}
