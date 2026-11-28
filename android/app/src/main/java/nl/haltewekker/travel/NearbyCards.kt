package nl.haltewekker.travel

import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * (0.10.11, iOS 0.42.15 `NearbyCards`) The stops on "Fastest trip, zoomed out" as mini cards (design M4b): a small dot
 * at the stop and a card by it with its line, "leave 10:41 · 9 min walk", "arrive 12:07", how sure, and FASTEST (gold)
 * and SUREST (green), both on one card when one way is both. Plain rules, tested in `NearbyCardsTest` against
 * docs/nearby-cards-vectors.json (iOS checks the same).
 */
object NearbyCards {
    // MARK: the tags

    data class Badge(val fastest: Boolean = false, val surest: Boolean = false) {
        val tagged get() = fastest || surest
        val tags: List<Nearby.Tag> get() = listOfNotNull(if (fastest) Nearby.Tag.FASTEST else null, if (surest) Nearby.Tag.SUREST else null)
    }

    /** The tags of the ranked ways (`Nearby.tags`); "Slower" isn't shown any more. */
    fun badges(options: List<Nearby.Option>): Map<String, Badge> {
        val out = linkedMapOf<String, Badge>()
        for ((id, tags) in Nearby.tags(options)) {
            val b = Badge(Nearby.Tag.FASTEST in tags, Nearby.Tag.SUREST in tags)
            if (b.tagged) out[id] = b
        }
        return out
    }

    enum class Edge { SUREST, FASTEST, PLAIN }

    fun edge(b: Badge?): Edge = when {
        b == null -> Edge.PLAIN
        b.surest -> Edge.SUREST
        b.fastest -> Edge.FASTEST
        else -> Edge.PLAIN
    }

    fun color(e: Edge): Int = when (e) { Edge.SUREST -> 0x3DD598; Edge.FASTEST -> 0xE8A33D; Edge.PLAIN -> 0x8A9099 }
    fun edgeWidth(e: Edge): Double = if (e == Edge.PLAIN) 1.5 else 2.5
    fun walkDashed(e: Edge): Boolean = e == Edge.PLAIN

    /** In a stop's sheet, the departure tagged Surest; the one there first itself when it's as sure (so both). */
    fun surestBoth(percents: List<Int>, fastest: Int): Int? {
        if (fastest !in percents.indices) return null
        val top = percents.indices.maxWithOrNull(compareBy<Int> { percents[it] }.thenByDescending { it }) ?: return null
        val p = percents[top]
        if (p < Nearby.SUREST_AT) return null
        return if (percents[fastest] >= p) fastest else top
    }

    // MARK: the words (never the walking emoji)

    fun leaveWords(time: String, walk: Int) = "leave $time · " + walkWords(walk)
    fun walkWords(walk: Int) = "${max(0, walk)} min walk"
    fun onTimeWords(s: Nearby.Sure) = "${s.percent}% on time"
    fun estimateWord(s: Nearby.Sure): String? = if (s.source is Nearby.Source.Yours) null else "estimate"

    // MARK: the cards on the map, never on top of anything

    data class Point(val x: Double, val y: Double)

    data class Rect(val x: Double, val y: Double, val w: Double, val h: Double) {
        val maxX get() = x + w
        val maxY get() = y + h
        fun touches(o: Rect, pad: Double) = x < o.maxX + pad && o.x < maxX + pad && y < o.maxY + pad && o.y < maxY + pad
        fun contains(p: Point) = p.x >= x && p.x <= maxX && p.y >= y && p.y <= maxY
        fun nearest(p: Point) = Point(min(max(p.x, x), maxX), min(max(p.y, y), maxY))

        /** Whether the line from `a` to `b` goes through the box (Liang–Barsky). */
        fun crossed(a: Point, b: Point): Boolean {
            val dx = b.x - a.x; val dy = b.y - a.y
            var t0 = 0.0; var t1 = 1.0
            val ps = doubleArrayOf(-dx, dx, -dy, dy)
            val qs = doubleArrayOf(a.x - x, maxX - a.x, a.y - y, maxY - a.y)
            for (k in 0 until 4) {
                if (ps[k] == 0.0) { if (qs[k] < 0) return false; continue }
                val t = qs[k] / ps[k]
                if (ps[k] < 0) t0 = max(t0, t) else t1 = min(t1, t)
                if (t0 > t1) return false
            }
            return true
        }
    }

    data class Item(val id: String, val at: Point, val tagged: Boolean)

    enum class Kind(val raw: String) { CARD("card"), PILL("pill"), HIDDEN("hidden") }

    data class Placed(val id: String, val kind: Kind, val rect: Rect, val leader: Point?)

    const val CARD_WIDTH = 196.0
    const val CARD_HEIGHT = 58.0
    const val TAGGED_HEIGHT = 76.0
    const val PILL_WIDTH = 56.0
    const val PILL_HEIGHT = 26.0
    const val GAP = 12.0
    const val PAD = 4.0
    const val DOT_RADIUS = 7.0
    const val YOU_RADIUS = 20.0
    const val MAX_CARDS = 4
    const val MAX_LEADER = 120.0

    /** The spots tried, as the box's top-left corner from the dot: above, below, the diagonals, the sides, then further. */
    fun offsets(w: Double, h: Double): List<Point> {
        val g = GAP
        val out = mutableListOf(Point(-w / 2, -g - h), Point(-w / 2, g), Point(g, -g - h), Point(-w - g, -g - h),
            Point(g, g), Point(-w - g, g), Point(g, -h / 2), Point(-w - g, -h / 2))
        for (k in 1..3) {
            val s = k * (h + g)
            out += listOf(Point(-w / 2, -g - h - s), Point(-w / 2, g + s), Point(g, -g - h - s), Point(-w - g, -g - h - s),
                Point(g, g + s), Point(-w - g, g + s))
        }
        return out
    }

    fun clamp(r: Rect, b: Rect): Rect {
        val x = if (r.w >= b.w) b.x else min(max(r.x, b.x), b.maxX - r.w)
        val y = if (r.h >= b.h) b.y else min(max(r.y, b.y), b.maxY - r.h)
        return Rect(x, y, r.w, r.h)
    }

    private fun box(p: Point, r: Double) = Rect(p.x - r, p.y - r, 2 * r, 2 * r)

    /** iOS `NearbyCards.layout`: each in order at the first spot clear of everything, else a pill, else none. */
    fun layout(items: List<Item>, bounds: Rect, you: Point?, dots: List<Point> = emptyList()): List<Placed> {
        val blocks = mutableListOf<Rect>()
        if (you != null) blocks += box(you, YOU_RADIUS)
        for (p in dots) blocks += box(p, DOT_RADIUS)
        for (i in items) blocks += box(i.at, DOT_RADIUS)
        val placed = mutableListOf<Rect>()
        val leaders = mutableListOf<Pair<Point, Point>>()
        val out = mutableListOf<Placed>()
        for ((n, item) in items.withIndex()) {
            if (!bounds.contains(item.at)) { out += Placed(item.id, Kind.HIDDEN, Rect(item.at.x, item.at.y, 0.0, 0.0), null); continue }
            val tries = mutableListOf<Triple<Kind, Double, Double>>()
            if (n < MAX_CARDS) tries += Triple(Kind.CARD, CARD_WIDTH, if (item.tagged) TAGGED_HEIGHT else CARD_HEIGHT)
            tries += Triple(Kind.PILL, PILL_WIDTH, PILL_HEIGHT)
            var done = false
            loop@ for ((kind, w, h) in tries) {
                for (o in offsets(w, h)) {
                    val r = clamp(Rect(item.at.x + o.x, item.at.y + o.y, w, h), bounds)
                    if (blocks.any { r.touches(it, PAD) }) continue
                    if (placed.any { r.touches(it, PAD) }) continue
                    if (leaders.any { r.crossed(it.first, it.second) }) continue
                    val near = r.nearest(item.at)
                    val dx = near.x - item.at.x; val dy = near.y - item.at.y
                    val length = sqrt(dx * dx + dy * dy)
                    val far = length > GAP + 0.5
                    if (far && length > MAX_LEADER) continue
                    if (far && placed.any { it.crossed(near, item.at) }) continue
                    if (far) leaders += near to item.at
                    placed += r
                    out += Placed(item.id, kind, r, if (far) near else null)
                    done = true
                    break@loop
                }
            }
            if (!done) out += Placed(item.id, Kind.HIDDEN, Rect(item.at.x, item.at.y, 0.0, 0.0), null)
        }
        return out
    }
}
