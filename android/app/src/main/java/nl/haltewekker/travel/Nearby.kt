package nl.haltewekker.travel

import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import java.time.Instant
import java.time.ZoneId
import java.time.temporal.ChronoUnit
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/**
 * (A9, iOS 0.42 / 0.42.2 `NearbyRank`) "Fastest trip, zoomed out": the stops you could walk to, each with its ways,
 * coloured by when you'd be there, ringed by how sure, tagged Fastest / Surest / Slower; the 0.42.2 fetch design (one
 * plan from where you are, a second only when needed), the window filtered locally, the overnight group, merged
 * circles and the honest status line. Pure, tested with the iOS vectors. Times are seconds since 1970.
 */
object Nearby {
    data class Stop(val id: String, val name: String, val lat: Double, val lon: Double, val rail: Boolean, val metres: Double)

    data class Group(val id: String, val name: String, val ids: List<String>, val lat: Double, val lon: Double, val rail: Boolean, val metres: Double) {
        val point: GeoPoint get() = GeoPoint(lat, lon)
    }

    const val DOTS_RADIUS = 1000.0
    const val USEFUL_WANTED = 3
    const val MAX_GROUPS = 8
    const val IDS_PER_GROUP = 2
    const val MAX_PLANS = 12
    const val SAME_STOP = 300.0
    const val STATIONS_FIRST = 2

    fun key(name: String): String = name.lowercase().split(' ', '\t').filter { it.isNotEmpty() }.joinToString(" ")

    fun groups(stops: List<Stop>, within: Double, skip: Set<String> = emptySet()): List<Group> {
        val near = stops.filter { it.metres <= within && it.metres.isFinite() }.sortedBy { it.metres }
        val all = ArrayList<Group>()
        val allIds = ArrayList<MutableList<String>>()
        for (s in near) {
            val k = if (s.rail) "rail:" + s.id else key(s.name)
            val here = GeoPoint(s.lat, s.lon)
            val i = all.indexOfFirst { it.id == k && Geo.metres(it.point, here) <= SAME_STOP }
            if (i >= 0) { if (s.id !in allIds[i]) allIds[i].add(s.id); continue }
            if (all.any { it.id == k }) continue
            all.add(Group(k, s.name, emptyList(), s.lat, s.lon, s.rail, s.metres))
            allIds.add(mutableListOf(s.id))
        }
        val picked = ArrayList<Int>()
        picked += all.indices.filter { all[it].rail && all[it].id !in skip }.take(STATIONS_FIRST)
        for (i in all.indices) {
            if (all[i].id in skip || i in picked) continue
            if (picked.size >= MAX_GROUPS) break
            picked.add(i)
        }
        val order = picked.take(MAX_GROUPS).sortedBy { all[it].metres }
        val out = ArrayList<Group>()
        var budget = MAX_PLANS
        for (i in order) { if (budget <= 0) break; out.add(all[i].copy(ids = listOf(allIds[i][0]))); budget-- }
        for (n in out.indices) {
            if (budget <= 0) break
            val i = all.indexOfFirst { it.id == out[n].id }
            if (i < 0) continue
            for (id in allIds[i].drop(1).take(IDS_PER_GROUP - 1)) { if (budget <= 0) break; out[n] = out[n].copy(ids = out[n].ids + id); budget-- }
        }
        return out
    }

    // MARK: asking the planner (0.42.2)

    val SEARCH_RADII = listOf(1600.0, 3000.0)
    const val MAX_SEARCH_PLANS = 2
    const val MAX_CONCURRENT = 2
    const val ITINERARIES = 8
    const val MAX_ITINERARIES = 12
    const val SEARCH_WINDOW = 3600
    const val MAX_PRE_TRANSIT = 2700

    fun preTransit(radius: Double): Int = min(MAX_PRE_TRANSIT, plannedWalk(radius) * 60)

    fun nextPlan(done: Int, useful: Int, hasCursor: Boolean, lastFailed: Boolean, cooling: Boolean): Double? {
        if (done >= MAX_SEARCH_PLANS || done >= SEARCH_RADII.size) return null
        if (done == 0) return SEARCH_RADII[0]
        if (cooling || useful >= USEFUL_WANTED || !(hasCursor || lastFailed)) return null
        return SEARCH_RADII[done]
    }

    data class Boarding(val id: String, val name: String, val lat: Double?, val lon: Double?, val rail: Boolean) {
        val point: GeoPoint? get() = if (lat != null && lon != null) GeoPoint(lat, lon) else null
    }

    fun groupIndex(b: Boarding, groups: List<Group>): Int? {
        groups.indexOfFirst { b.id in it.ids || it.id == "rail:" + b.id }.takeIf { it >= 0 }?.let { return it }
        val k = key(b.name)
        val p = b.point ?: return if (b.rail) null else groups.indexOfFirst { !it.rail && it.id == k }.takeIf { it >= 0 }
        if (!b.rail) groups.indexOfFirst { !it.rail && it.id == k && Geo.metres(it.point, p) <= SAME_STOP }.takeIf { it >= 0 }?.let { return it }
        var best: Int? = null; var bm = Double.POSITIVE_INFINITY
        groups.forEachIndexed { i, g ->
            val m = Geo.metres(g.point, p)
            val near = if (g.rail || b.rail) 400.0 else 120.0
            if (m <= near && m < bm) { best = i; bm = m }
        }
        return best
    }

    fun newGroup(b: Boarding, here: GeoPoint, taken: Set<String>): Group? {
        val p = b.point ?: return null
        var id = if (b.rail) "rail:" + b.id else key(b.name)
        if (id in taken) id += "@" + b.id
        return Group(id, b.name, listOf(b.id), p.lat, p.lon, b.rail, Geo.metres(here, p))
    }

    // MARK: the walk

    const val DETOUR = 1.3
    const val PLANNER_SPEED = 1.2

    fun walkMetres(straight: Double) = max(0.0, straight) * DETOUR

    fun plannedWalk(straight: Double, speed: Double = PLANNER_SPEED): Int {
        val v = if (speed.isFinite() && speed > 0) speed else PLANNER_SPEED
        return max(1, ceil(walkMetres(straight) / v / 60).toInt())
    }

    // MARK: when you'd leave

    enum class Leave(val minutes: Int, val title: String) { NOW(0, "Leave now"), IN10(10, "In 10 min"), IN20(20, "In 20 min") }

    const val WINDOW_MINUTES = 35.0
    const val MAX_WAIT = 90 * 60.0
    const val MAX_TRIP = 3 * 3600.0
    const val MIN_PER_STOP = 2
    const val DOOR_GRACE = 30.0

    data class Window(val leave: Double, val until: Double)

    fun window(l: Leave, now: Double): Window { val leave = now + l.minutes * 60.0; return Window(leave, leave + WINDOW_MINUTES * 60) }

    fun catchable(door: Double, w: Window) = door >= w.leave - DOOR_GRACE

    fun planAt(w: Window, walk: Int, now: Double) = max(now - 60, w.leave + max(0, walk) * 60.0 - 60)

    data class Dep(val door: Double, val departure: Double, val arrival: Double, val cancelled: Boolean = false, val longestWait: Double = 0.0)

    fun late(d: Dep, w: Window) = d.door - w.leave > MAX_WAIT || d.longestWait > MAX_WAIT || d.arrival - w.leave > MAX_TRIP

    fun ranked(d: Dep, w: Window) = catchable(d.door, w) && d.door <= w.until && !late(d, w)

    fun shown(deps: List<Dep>, w: Window): List<Int> {
        val ok = deps.indices.filter { !deps[it].cancelled && catchable(deps[it].door, w) }.sortedBy { deps[it].departure }
        val out = ArrayList<Int>()
        for (i in ok) if (deps[i].door <= w.until || out.size < MIN_PER_STOP) out.add(i)
        return out
    }

    data class Best(val index: Int, val ranked: Boolean)

    fun best(deps: List<Dep>, w: Window): Best? {
        val s = shown(deps, w)
        s.filter { ranked(deps[it], w) }.minByOrNull { deps[it].arrival }?.let { return Best(it, true) }
        return s.minByOrNull { deps[it].arrival }?.let { Best(it, false) }
    }

    fun split(deps: List<Dep>, w: Window): Pair<List<Int>, List<Int>> = deps.indices.partition { !late(deps[it], w) }

    fun dayWord(d: Double, now: Double, zone: ZoneId): String? {
        val a = Instant.ofEpochSecond(now.toLong()).atZone(zone).toLocalDate()
        val bz = Instant.ofEpochSecond(d.toLong()).atZone(zone)
        val days = ChronoUnit.DAYS.between(a, bz.toLocalDate())
        if (days <= 0) return null
        if (days == 1L && bz.hour < 4) return null
        if (days == 1L) return "tomorrow"
        return listOf("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")[bz.dayOfWeek.value - 1]
    }

    fun laterTitle(firstArrival: Double, now: Double, zone: ZoneId): String {
        val day = dayWord(firstArrival, now, zone)
        val hour = Instant.ofEpochSecond(firstArrival.toLong()).atZone(zone).hour
        if (day == "tomorrow" && hour < 12) return "Tomorrow morning"
        return day?.let { "Later · $it" } ?: "Later"
    }

    // MARK: how sure

    const val LATE_BY = 3.0
    const val OWN_NEEDED = 4
    const val OWN_KEPT = 20

    sealed class Source {
        data class Yours(val rides: Int) : Source()
        object Live : Source() { override fun toString() = "Live" }
        object Estimate : Source() { override fun toString() = "Estimate" }
    }

    data class Sure(val percent: Int, val source: Source, val usual: Int?)

    private fun roundHalf(x: Double) = floor(x + 0.5).toInt()
    private fun clampPercent(p: Double) = min(99, max(1, roundHalf(p * 100)))
    private fun median(xs: List<Double>): Double {
        val s = xs.sorted(); if (s.isEmpty()) return 0.0
        return if (s.size % 2 == 1) s[s.size / 2] else (s[s.size / 2 - 1] + s[s.size / 2]) / 2
    }

    fun sure(own: List<Double>, modelLate: Double, made: Double, live: Boolean): Sure {
        val m = if (made.isFinite()) min(1.0, max(0.0, made)) else 1.0
        val mine = own.filter { it.isFinite() }.takeLast(OWN_KEPT)
        if (mine.size >= OWN_NEEDED) {
            val share = mine.count { it < LATE_BY }.toDouble() / mine.size
            val med = median(mine)
            return Sure(clampPercent(share * m), Source.Yours(mine.size), if (med >= 0.5) roundHalf(med) else null)
        }
        val late = if (modelLate.isFinite()) min(1.0, max(0.0, modelLate)) else 0.3
        return Sure(clampPercent((1 - late) * m), if (live) Source.Live else Source.Estimate, null)
    }

    fun sureWords(s: Sure): String = when (val src = s.source) {
        is Source.Yours -> "on time ${s.percent}% of your last ${src.rides} ride${if (src.rides == 1) "" else "s"}" + (s.usual?.let { " · usually +$it min" } ?: "")
        Source.Live -> "on time about ${s.percent}% (by live times)"
        Source.Estimate -> "on time about ${s.percent}% (by the time of day; no live times yet)"
    }

    enum class Ring { SOLID, DASHED, NEUTRAL }
    const val SOLID_AT = 85

    fun ring(s: Sure?): Ring = if (s == null || s.source == Source.Estimate) Ring.NEUTRAL else if (s.percent >= SOLID_AT) Ring.SOLID else Ring.DASHED

    // MARK: fastest, surest, slower

    data class Option(val id: String, val arrival: Double, val departure: Double, val walk: Int, val sure: Sure?, val ranked: Boolean = true)

    enum class Tag(val title: String) { FASTEST("Fastest"), SUREST("Surest"), SLOWER("Slower") }

    const val SLOWER_AFTER = 5 * 60.0
    const val SUREST_AT = 70

    fun tags(options: List<Option>): Map<String, List<Tag>> {
        val ranked = options.filter { it.ranked }
        val fast = fastest(ranked) ?: return emptyMap()
        val out = linkedMapOf(fast.id to mutableListOf(Tag.FASTEST))
        surest(ranked, fast)?.let { out.getOrPut(it.id) { mutableListOf() }.add(Tag.SUREST) }
        for (o in ranked) if (out[o.id] == null && o.arrival - fast.arrival >= SLOWER_AFTER) out[o.id] = mutableListOf(Tag.SLOWER)
        return out
    }

    fun fastest(options: List<Option>): Option? = options.filter { it.ranked }
        .minWithOrNull(compareBy<Option>({ it.arrival }, { it.walk }).thenByDescending { it.departure })

    private fun surest(options: List<Option>, fast: Option): Option? {
        val rated = options.filter { it.sure != null }
        val top = rated.maxWithOrNull(compareBy<Option> { it.sure?.percent ?: 0 }.thenByDescending { it.arrival }) ?: return null
        val p = top.sure?.percent ?: 0
        if (p < SUREST_AT) return null
        return if (p <= (fast.sure?.percent ?: -1)) fast else top
    }

    fun surestOf(percents: List<Int>, fastest: Int): Int? {
        if (fastest !in percents.indices) return null
        val top = percents.indices.maxWithOrNull(compareBy<Int> { percents[it] }.thenByDescending { it }) ?: return null
        return if (percents[top] >= SUREST_AT && percents[top] > percents[fastest]) top else null
    }

    fun ordered(options: List<Option>): List<Option> {
        val t = tags(options)
        fun rank(o: Option): Int { val tg = t[o.id] ?: emptyList(); return if (Tag.FASTEST in tg) 0 else if (Tag.SUREST in tg) 1 else if (o.ranked) 2 else 3 }
        return options.sortedWith(compareBy({ rank(it) }, { it.arrival }, { it.walk }))
    }

    // MARK: the colours

    val SCALE = listOf(0x3DD598, 0xC9D45A, 0xE8A33D, 0xE86F5A)
    const val MIN_SPREAD = 8 * 60.0

    fun fraction(arrival: Double, earliest: Double, latest: Double): Double {
        val f = (arrival - earliest) / max(MIN_SPREAD, latest - earliest)
        return if (f.isFinite()) min(1.0, max(0.0, f)) else 0.0
    }

    fun color(f: Double): Int {
        val x = if (f.isFinite()) min(1.0, max(0.0, f)) else 0.0
        val steps = (SCALE.size - 1).toDouble()
        val i = min(SCALE.size - 2, floor(x * steps).toInt())
        val t = x * steps - i
        fun one(s: Int): Int {
            val a = (SCALE[i] shr s) and 0xFF; val b = (SCALE[i + 1] shr s) and 0xFF
            return min(255, max(0, roundHalf(a + (b - a) * t))) shl s
        }
        return one(16) or one(8) or one(0)
    }

    // MARK: the map's frame

    data class Frame(val lat: Double, val lon: Double, val latDelta: Double, val lonDelta: Double)

    fun frame(you: GeoPoint, stops: List<GeoPoint>, minMetres: Double = 600.0, pad: Double = 1.4): Frame {
        val pts = listOf(you) + stops
        val minLat = pts.minOf { it.lat }; val maxLat = pts.maxOf { it.lat }
        val minLon = pts.minOf { it.lon }; val maxLon = pts.maxOf { it.lon }
        val midLat = (minLat + maxLat) / 2
        val perLon = max(1.0, 111_320 * cos(midLat * Math.PI / 180))
        return Frame(midLat, (minLon + maxLon) / 2, max((maxLat - minLat) * pad, minMetres / 111_320), max((maxLon - minLon) * pad, minMetres / perLon))
    }

    // MARK: on the line now

    fun stopsAway(next: Int, atStop: Boolean, mine: Int): Int? =
        if (atStop) (if (next <= mine) mine - next else null) else (if (next <= mine) mine - next + 1 else null)

    fun gpsAge(seconds: Double): String { val s = max(0, roundHalf(seconds)); return if (s < 60) "GPS $s s" else "GPS ${s / 60} min" }

    fun comingWords(minutes: Int, stops: Int?): String {
        val w = if (minutes <= 0) "now" else "in $minutes min"
        val n = stops ?: return w
        return if (n == 0) "$w · at the stop" else w + if (n == 1) " · next stop" else " · $n stops"
    }

    // MARK: stops close together on the map (0.42.2)

    data class Pin(val id: String, val lat: Double, val lon: Double, val arrival: Double?) { val point: GeoPoint get() = GeoPoint(lat, lon) }

    data class Cluster(val id: String, val lat: Double, val lon: Double, val members: MutableList<String>)

    fun merge(pins: List<Pin>, within: Double): List<Cluster> {
        val order = pins.sortedWith(Comparator { a, b ->
            val x = a.arrival; val y = b.arrival
            when {
                x != null && y != null && x != y -> x.compareTo(y)
                x != null && y == null -> -1
                x == null && y != null -> 1
                else -> a.id.compareTo(b.id)
            }
        })
        val out = ArrayList<Cluster>()
        for (p in order) {
            val c = out.firstOrNull { Geo.metres(GeoPoint(it.lat, it.lon), p.point) < within }
            if (c != null) c.members.add(p.id) else out.add(Cluster(p.id, p.lat, p.lon, mutableListOf(p.id)))
        }
        return out
    }

    const val PIN_POINTS = 40.0

    // MARK: what the screen says

    data class Situation(val located: Boolean = true, val stopsFailed: Boolean = false, val busy: Boolean = false, val options: Int = 0,
                         val planFailed: Boolean = false, val unchecked: Int = 0, val seed: Boolean = false, val fallback: Boolean = false,
                         val cooling: Boolean = false)

    fun statusLine(s: Situation, range: String): Pair<String, Boolean>? {
        if (!s.located) return "Finding where you are…" to true
        if (s.busy) return "Asking the planner for the ways from the stops within $range…" to true
        val busyWord = if (s.cooling) "the planner is busy" else "no answer in time"
        if (s.options == 0) {
            if (s.fallback) return "Nothing found yet for that time: this is your trip’s way. See your trip for its other times." to false
            if (s.planFailed || s.stopsFailed) return "Couldn’t check the stops around you just now ($busyWord). Your trip has the fastest way." to false
            if (s.seed) return "Your trip has the way: see your trip." to false
            return "No bus or train from the stops within $range in this time. Try later, or see your trip." to false
        }
        if (s.planFailed) return "Couldn’t check every stop just now ($busyWord): these are the ones in." to false
        if (s.unchecked > 0) return "Couldn’t check ${s.unchecked} stop${if (s.unchecked == 1) "" else "s"} just now ($busyWord). Tap one to try again." to false
        return null
    }

    private fun one(x: Double) = String.format(java.util.Locale.ROOT, "%.1f", x)

    fun logLine(radius: Double, stops: Int, plans: Int, pages: Int, ways: Int, failed: Int, seconds: Double, bytes: Int, note: String? = null): String {
        val km = floor(radius / 100 + 0.5) / 10
        val page = if (pages > 0) " (+$pages page${if (pages == 1) "" else "s"})" else ""
        var out = "nearby · r ${one(km)} km · stops $stops · plans $plans$page · ways $ways · $failed failed · ${one(max(0.0, seconds))} s · ${roundHalf(max(0, bytes) / 1024.0)} KB"
        if (!note.isNullOrEmpty()) out += " · $note"
        return out
    }

    fun stopLogLine(planned: Boolean, failed: Boolean, ways: Int, board: Int?, seconds: Double, bytes: Int): String {
        var out = "nearby stop"
        if (planned) out += if (failed) " · plan failed" else " · plan"
        out += " · ways $ways"
        if (board != null) out += " · times $board"
        return out + " · ${one(max(0.0, seconds))} s · ${roundHalf(max(0, bytes) / 1024.0)} KB"
    }
}
