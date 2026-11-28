package nl.haltewekker.travel

import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.core.Iso
import nl.haltewekker.data.BoardDeparture
import nl.haltewekker.data.DoorTrip
import nl.haltewekker.data.Polite
import nl.haltewekker.data.Transit
import nl.haltewekker.data.TransitParse
import nl.haltewekker.logs.FieldEntry
import nl.haltewekker.logs.FieldLog
import kotlin.math.max

/**
 * (0.10.0, iOS 0.42.0/0.42.2 `NearbyStore`) Fastest trip, zoomed out: the stops around you, each with its ways to the
 * destination. One `/v5/plan` from your coordinate (the planner walks to every stop around by itself), a second page
 * only when fewer than 3 stops have a way (`Nearby.nextPlan`), never while Transitous asks to slow down; the stops
 * around (`/v1/map/stops`, kept 10 min) only drawn. At most 2 requests at once from here, all in the background lane.
 * A stop tapped: its own plan when it had no way, and its next departures ("Also from here").
 */
class NearbyStore(val destId: String, private val seed: List<DoorTrip>) {
    class Way(val group: Nearby.Group, val trips: List<DoorTrip>)

    data class Result(val here: GeoPoint, val groups: List<Nearby.Group>, val ways: Map<String, List<DoorTrip>>, val radius: Double,
                      val answered: Boolean, val planFailed: Boolean, val stopsFailed: Boolean, val busy: Boolean, val cursor: String?,
                      val plans: Int, val pages: Int, val failed: Int, val bytes: Int, val askedAt: Double)

    private val gate = Semaphore(Nearby.MAX_CONCURRENT)
    // (iOS 0.42.8) newer live times of the trips (the stops' boards), and when each departure's own answer came
    @Volatile private var updates: Map<String, NearbyLive.Update> = emptyMap()
    private val answeredAt = java.util.concurrent.ConcurrentHashMap<String, Double>()

    private fun leg(r: nl.haltewekker.data.Ride) = NearbyLive.Leg(r.tripId, r.departure, r.scheduledDeparture, r.arrival, r.scheduledArrival, r.live, r.toStop)

    /** A way with the live times known now (its first and last leg move the door and the arrival). */
    fun fresh(t: DoorTrip): DoorTrip {
        val u = updates
        if (t.rides.isEmpty() || t.rides.none { it.tripId in u }) return t
        val r = NearbyLive.trip(t.start, t.end, t.rides.map(::leg), u, answeredAt[t.first.tripId])
        val rides = t.rides.zip(r.legs) { a, b -> if (a.departure == b.departure && a.arrival == b.arrival && a.live == b.live) a else a.copy(departure = b.departure, arrival = b.arrival, live = b.live) }
        return t.copy(rides = rides, start = r.start, end = r.end)
    }

    /** Newer live times: the ways kept are freshened (the list, the colours, Fastest and Surest follow). */
    fun freshen(more: List<NearbyLive.Update>) {
        val m = NearbyLive.merge(updates, more)
        if (m == updates) return
        updates = m
        result = result?.let { r -> r.copy(ways = r.ways.mapValues { e -> e.value.map(::fresh) }) }
    }
    @Volatile var result: Result? = null; private set
    private var stopsKept: Pair<Double, List<Nearby.Stop>>? = null

    private suspend fun <T> bg(block: suspend () -> T): T = gate.withPermit { withContext(Polite.Background) { block() } }

    private fun stopsOf(list: List<nl.haltewekker.data.NearStop>) = list.map { Nearby.Stop(it.id, it.name, it.lat, it.lon, it.rail, it.meters) }

    private fun boarding(t: DoorTrip): Nearby.Boarding {
        val f = t.first
        return Nearby.Boarding(f.fromId, f.fromStop, f.fromLat, f.fromLon, f.isTrain)
    }

    /** Each trip with the stop its first ride leaves from (a new circle when it's none of the stops around). */
    fun place(here: GeoPoint, groups: List<Nearby.Group>, trips: List<DoorTrip>, ways: Map<String, List<DoorTrip>>): Pair<List<Nearby.Group>, Map<String, List<DoorTrip>>> {
        val gs = groups.toMutableList()
        val w = ways.mapValues { it.value.toMutableList() }.toMutableMap()
        val speed = HabitStore.pedestrianSpeed() ?: nl.haltewekker.data.WalkFirst.PLANNER_SPEED
        for (t0 in trips) {
            if (t0.rides.isEmpty()) continue
            // (iOS 0.42.8) the walk by its distance, a short first hop swapped for the walk to the next stop
            val t = nl.haltewekker.data.WalkFirst.fixed(t0, here, Iso.now(), speed).first
            val b = boarding(t)
            var i = Nearby.groupIndex(b, gs)
            if (i == null) {
                val g = Nearby.newGroup(b, here, gs.map { it.id }.toSet()) ?: continue
                gs.add(g); i = gs.size - 1
            }
            val list = w.getOrPut(gs[i].id) { mutableListOf() }
            if (list.none { it.id == t.id }) list.add(t)
        }
        return gs to w.mapValues { e -> e.value.sortedBy { it.first.departure } }
    }

    /** The departure as the window takes it (`Nearby.Dep`): when you leave your door, the longest wait anywhere. */
    fun dep(t: DoorTrip): Nearby.Dep {
        var wait = t.first.departure - (t.start + t.first.walkBefore * 60.0)
        for (i in 1 until t.rides.size) wait = max(wait, t.rides[i].departure - t.rides[i - 1].arrival - t.rides[i].walkBefore * 60.0)
        return Nearby.Dep(t.start, t.first.departure, t.end, t.rides.any { it.cancelled }, max(0.0, wait))
    }

    /** Stops with a ranked way in this window. */
    fun useful(r: Result, w: Nearby.Window): Int = r.ways.values.count { l -> Nearby.best(l.map(::dep), w)?.ranked == true }

    /** The search: the stops around and the first plan (two at once at most), then a second page only when needed. */
    suspend fun search(here: GeoPoint, leave: Nearby.Leave, note: String? = null): Result = coroutineScope {
        val began = Iso.now()
        val w = Nearby.window(leave, began)
        val prior = result?.takeIf { Geo.metres(it.here, here) < 250 }
        val stopsJob = async {
            stopsKept?.takeIf { began - it.first < 600 && prior != null }?.second
                ?: bg { Transit.nearStops(here) }?.let { stopsOf(it) }?.also { stopsKept = began to it }
        }
        var plans = 0; var pages = 0; var failed = 0; var bytes = 0
        var cursor: String? = null
        var trips = ArrayList<DoorTrip>()
        var radius = Nearby.SEARCH_RADII[0]
        var lastFailed = false
        var answered = false
        var done = 0
        while (true) {
            val r = Nearby.nextPlan(done, 0, cursor != null, lastFailed, Transit.cooling) ?: break
            if (done > 0) {
                // a second one only when fewer than 3 stops have a way
                val (gs, ws) = place(here, Nearby.groups(stopsJob.await() ?: emptyList(), Nearby.DOTS_RADIUS), trips, emptyMap())
                val tmp = Result(here, gs, ws, radius, answered, false, false, false, cursor, 0, 0, 0, 0, began)
                if (Nearby.nextPlan(done, useful(tmp, w), cursor != null, lastFailed, Transit.cooling) == null) break
            }
            radius = r
            val page = bg { Transit.planPage("${here.lat},${here.lon}", destId, Nearby.planAt(w, 0, began), Nearby.preTransit(r), if (lastFailed) null else cursor) }
            done++
            if (done > 1) pages++ else plans++
            bytes += page.bytes
            if (page.failed) { failed++; lastFailed = true; continue }
            answered = true; lastFailed = false
            cursor = page.cursor
            for (t in page.trips) if (trips.none { it.id == t.id }) { trips.add(t); answeredAt[t.first.tripId] = Iso.now() }
        }
        val stops = stopsJob.await()
        val (gs0, ws0) = place(here, Nearby.groups(stops ?: emptyList(), Nearby.DOTS_RADIUS), trips + seed, emptyMap())
        // what was in before stays when this one got nothing
        val keep = (if (!answered && prior != null) prior.ways else ws0).mapValues { e -> e.value.map(::fresh) }
        val res = Result(here, if (!answered && prior != null) prior.groups else gs0, keep, radius, answered || prior?.answered == true,
            !answered, stops == null, false, cursor, plans, pages, failed, bytes, Iso.now())
        result = res
        val notes = listOfNotNull(note, if (Transit.cooling) "cooling" else null, if (stops == null) "no stops" else null,
            if (seed.isNotEmpty()) "seed ${seed.size}" else null).joinToString(" · ").ifEmpty { null }
        FieldLog.add(FieldEntry.Kind.NET, Nearby.logLine(radius, res.groups.size, plans, pages, useful(res, w), failed, Iso.now() - began, bytes, notes))
        res
    }

    /** After a switch of the time to leave: the next page only when fewer than 3 stops have a ranked way then. */
    suspend fun more(leave: Nearby.Leave): Result? {
        val r = result ?: return null
        val w = Nearby.window(leave, Iso.now())
        val done = r.plans + r.pages
        if (Nearby.nextPlan(done, useful(r, w), r.cursor != null, r.planFailed, Transit.cooling) == null) return null
        val began = Iso.now()
        val rad = Nearby.SEARCH_RADII.getOrElse(done) { Nearby.SEARCH_RADII.last() }
        val page = bg { Transit.planPage("${r.here.lat},${r.here.lon}", destId, Nearby.planAt(w, 0, began), Nearby.preTransit(rad), r.cursor) }
        if (!page.failed) for (t in page.trips) answeredAt[t.first.tripId] = Iso.now()
        val (gs, ws) = if (page.failed) r.groups to r.ways else place(r.here, r.groups, page.trips, r.ways)
        val res = r.copy(groups = gs, ways = ws, radius = rad, cursor = page.cursor ?: r.cursor, pages = r.pages + 1,
            failed = r.failed + if (page.failed) 1 else 0, bytes = r.bytes + page.bytes, answered = r.answered || !page.failed)
        result = res
        FieldLog.add(FieldEntry.Kind.NET, Nearby.logLine(rad, gs.size, r.plans, res.pages, useful(res, w), res.failed, Iso.now() - began, res.bytes,
            "after the switch to ${leave.title.lowercase()}"))
        return res
    }

    // MARK: a stop tapped

    data class StopInfo(val trips: List<DoorTrip>, val also: List<BoardDeparture>, val failed: Boolean)
    private val stopKept = HashMap<String, Pair<Double, StopInfo>>()

    /**
     * Its own plan (from its first id, at when you can be there, 5 itineraries) when the search had no way from it,
     * and its next departures of the same lines and headsigns as its ways (`/v6/stoptimes`, 16; kept a minute).
     */
    suspend fun stop(g: Nearby.Group, have: List<DoorTrip>, canBeThere: Double): StopInfo {
        val now = Iso.now()
        stopKept[g.id]?.let { if (now - it.first < 60) return it.second }
        val began = now
        var trips = have
        var failed = false
        var planned = false
        var bytes = 0
        if (have.isEmpty() && !Transit.cooling) {
            planned = true
            val page = bg { Transit.planPage(g.ids.first(), destId, canBeThere - 60, 0, null, count = 5) }
            bytes += page.bytes
            failed = page.failed
            trips = page.trips
            for (t in trips) answeredAt[t.first.tripId] = Iso.now()
        }
        val lines = trips.map { it.first.line to it.first.headsign }.toSet()
        val board = if (Transit.cooling) emptyList() else bg { Transit.board(listOf(g.ids.first()), n = 16) }
        // (iOS 0.42.8) the board's live times freshen the stop's own departures too (by trip id), not only the others
        val asOf = Iso.now()
        freshen(board.map { NearbyLive.update(board = it.tripId, time = it.time, scheduled = it.scheduled, live = it.live, asOf = asOf) })
        trips = trips.map(::fresh)
        val also = board.filter { (it.line to it.headsign) in lines || it.line in lines.map { l -> l.first } }.filter { it.time >= canBeThere - 30 && !it.cancelled }
        val info = StopInfo(trips, also, failed)
        if (!failed) stopKept[g.id] = now to info
        FieldLog.add(FieldEntry.Kind.NET, Nearby.stopLogLine(planned, failed, trips.size, board.size, Iso.now() - began, bytes))
        return info
    }

    companion object {
        /** How sure (`Nearby.sure`): your own rides on its last line to its last stop around the same time (the travel
         *  log; iOS 0.42.15 `NearbySlot.pick`: within an hour either side, else 90 or 120 minutes, weekdays and weekends
         *  apart), else the model by the time of day (`NearbySlot.period`: rush hours worst) and its live delay. */
        fun sure(t: DoorTrip, rides: List<RideRecord>, now: Double): Nearby.Sure {
            val last = t.last
            val zone = java.time.ZoneId.of("Europe/Amsterdam")
            fun slotOf(at: Double): Pair<Int, Boolean> {
                val z = java.time.Instant.ofEpochSecond(at.toLong()).atZone(zone)
                return (z.hour * 60 + z.minute) to (z.dayOfWeek == java.time.DayOfWeek.SATURDAY || z.dayOfWeek == java.time.DayOfWeek.SUNDAY)
            }
            val entries = rides.filter { it.to == last.toStop && (it.label.endsWith(" " + last.line) || it.label == last.line || it.label == last.name) }
                .mapNotNull { r -> r.late?.let { l -> slotOf(r.arr).let { (m, we) -> NearbySlot.Entry(m, we, l) } } }
            val (mm, weekend) = slotOf(last.scheduledArrival)
            val (own, window) = NearbySlot.pick(entries, mm, weekend)
            // the model: a live delay at the end already says a lot; else by the time of day (rush hours later more often)
            val p = NearbySlot.period(mm / 60.0, weekend)
            val byTime = NearbySlot.lateChance(if (last.isTrain) p.train else p.bus, Nearby.LATE_BY)
            val late = when {
                last.live && last.arrival - last.scheduledArrival >= Nearby.LATE_BY * 60 -> 0.85
                last.live -> 0.5 * byTime + 0.5 * 0.15
                else -> byTime
            }
            var made = 1.0
            for (i in 1 until t.rides.size) {
                val room = (t.rides[i].departure - t.rides[i - 1].arrival) / 60 - t.rides[i].walkBefore
                made *= 1 - when { room < 1 -> 0.5; room < 3 -> 0.25; room < 5 -> 0.1; else -> 0.03 }
            }
            val s = Nearby.sure(own, late, made, t.rides.any { it.live })
            return if (s.source is Nearby.Source.Yours) s.copy(window = window) else s
        }

        /** (iOS 0.42.15) Where a trip's % comes from, for the sheet (`NearbySlot.explain`). */
        fun explain(t: DoorTrip, rides: List<RideRecord>, now: Double): String {
            val last = t.last
            val z = java.time.Instant.ofEpochSecond(last.scheduledArrival.toLong()).atZone(java.time.ZoneId.of("Europe/Amsterdam"))
            val m = z.hour * 60 + z.minute
            val we = z.dayOfWeek == java.time.DayOfWeek.SATURDAY || z.dayOfWeek == java.time.DayOfWeek.SUNDAY
            return NearbySlot.explain(sure(t, rides, now), last.line, last.toStop, NearbySlot.slotWords(m, we),
                NearbySlot.period(m / 60.0, we).name, t.rides.size - 1)
        }
    }
}
