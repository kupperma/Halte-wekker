package nl.haltewekker.ui

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import nl.haltewekker.App
import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.core.Iso
import nl.haltewekker.data.BoardDeparture
import nl.haltewekker.data.DoorTrip
import nl.haltewekker.data.NearStop
import nl.haltewekker.data.Transit
import nl.haltewekker.data.TransitParse
import nl.haltewekker.data.VehicleKind
import nl.haltewekker.data.VehicleSegment
import nl.haltewekker.live.LiveFeeds
import nl.haltewekker.live.RealPositions
import nl.haltewekker.map.MapDot
import nl.haltewekker.profile.SavedPlace
import nl.haltewekker.ui.theme.Tokens
import java.util.Calendar
import androidx.compose.ui.graphics.toArgb

/** Which way the next trip goes: before noon to school, after it home (iOS `savedDirection`); a pick sticks 3 hours. */
enum class Direction { TO_SCHOOL, HOME }

/**
 * The home screen's data. Everything is fetched only while the screen is in front (the screen's own loops, tied to
 * its lifecycle): no polling in the background, as iOS Thrift.
 */
class HomeModel(app: Application) : AndroidViewModel(app) {
    private val store = (app as App).store

    val here = MutableStateFlow<GeoPoint?>(null)
    private val _departures = MutableStateFlow<List<BoardDeparture>>(emptyList())
    val departures: StateFlow<List<BoardDeparture>> = _departures
    private val _stops = MutableStateFlow<List<NearStop>>(emptyList())
    val stops: StateFlow<List<NearStop>> = _stops
    private val _next = MutableStateFlow<List<DoorTrip>>(emptyList())
    val next: StateFlow<List<DoorTrip>> = _next
    private val _nextLoading = MutableStateFlow(false)
    val nextLoading: StateFlow<Boolean> = _nextLoading
    private val _dots = MutableStateFlow<List<MapDot>>(emptyList())
    val dots: StateFlow<List<MapDot>> = _dots
    val direction = MutableStateFlow(autoDirection())
    /** (A8) the departures that may not run (no live data close to leaving on a line that has it), by `ghost` id. */
    private val _unsure = MutableStateFlow<Set<String>>(emptySet())
    val unsure: StateFlow<Set<String>> = _unsure
    /** Lines seen live today (normalized), for the ghost rule. */
    val liveToday = HashSet<String>()

    fun ghostId(d: BoardDeparture) = d.tripId + "|" + d.stopId + "|" + d.time

    fun ghost(d: BoardDeparture) = nl.haltewekker.travel.GhostDepartures.Dep(ghostId(d), d.tripId, d.line, d.headsign, d.stopName.ifEmpty { d.stopId },
        d.time, d.scheduled, d.live, d.cancelled)
    private var pickedAt = 0.0

    private var boardAt: GeoPoint? = null
    private var boardTime = 0.0
    private var nextFrom: GeoPoint? = null
    private var nextTime = 0.0
    private var nextDir: Direction? = null
    private var box: Pair<GeoPoint, GeoPoint>? = null
    private var zoom = 14.0
    private var segments: List<VehicleSegment> = emptyList()
    private var segmentsAt = 0.0
    private var segmentsBox: Pair<GeoPoint, GeoPoint>? = null

    /** Your recent fixes on the home (for "Continue your trip": moving like a bus or train). */
    private val fixes = ArrayDeque<nl.haltewekker.match.Fix>()
    fun noteFix(l: android.location.Location) {
        fixes.addLast(nl.haltewekker.match.Fix(l.time / 1000.0, GeoPoint(l.latitude, l.longitude), if (l.hasAccuracy()) l.accuracy.toDouble() else -1.0,
            if (l.hasSpeed()) l.speed.toDouble() else -1.0, if (l.hasBearing()) l.bearing.toDouble() else -1.0))
        while (fixes.size > 30) fixes.removeFirst()
    }
    fun moving(now: Double): Boolean = nl.haltewekker.match.OnBoardRules.movingByTrack(fixes.toList(), now)

    private fun autoDirection(): Direction = if (Calendar.getInstance().get(Calendar.HOUR_OF_DAY) < 12) Direction.TO_SCHOOL else Direction.HOME

    fun pick(d: Direction) { direction.value = d; pickedAt = Iso.now(); nextTime = 0.0 }

    fun target(d: Direction): SavedPlace? = store.profile.value.let { if (d == Direction.TO_SCHOOL) it.school else it.home }
    fun origin(d: Direction): SavedPlace? = store.profile.value.let { if (d == Direction.TO_SCHOOL) it.home else it.school }

    fun setBounds(sw: GeoPoint, ne: GeoPoint, z: Double) { box = sw to ne; zoom = z }

    /** The departures near you (your home stops when you're home), each minute or after 300 m. */
    suspend fun refreshBoard(force: Boolean = false) {
        val p = here.value ?: store.profile.value.home?.point ?: return
        val now = Iso.now()
        if (!force && boardAt?.let { Geo.metres(it, p) < 300 } == true && now - boardTime < 60) return
        boardAt = p; boardTime = now
        val prof = store.profile.value
        val atHome = prof.home?.let { Geo.metres(it.point, p) < 600 } == true && prof.homeStops.isNotEmpty()
        val stops = if (atHome) prof.homeStops else (Transit.nearStops(p) ?: return).take(3)
        _stops.value = stops
        val list = Transit.board(stops.map { it.id }, n = 10)
        // (A8, iOS 0.40 `GhostDepartures`) each journey once, no cancelled ones, "may not run" ranked lower, gone ones gone
        list.filter { it.live && !it.cancelled }.forEach { liveToday.add(nl.haltewekker.travel.GhostDepartures.normalized(it.line)) }
        val rows = nl.haltewekker.travel.GhostDepartures.clean(list.map { ghost(it) }, now, liveToday)
        val byId = list.associateBy { it.tripId + "|" + it.stopId + "|" + it.time }
        _unsure.value = rows.filter { it.status == nl.haltewekker.travel.GhostDepartures.Status.UNSURE }.map { it.dep.id }.toSet()
        _departures.value = rows.mapNotNull { byId[it.dep.id] }.filter { it.time >= now - 60 }.take(12)
    }

    /** The next trip to school or home, from where you are (or the other place), every 2 minutes or after 400 m. */
    suspend fun refreshNext(force: Boolean = false, flipped: Boolean = false) {
        if (Iso.now() - pickedAt > 3 * 3600) direction.value = autoDirection()
        val d = direction.value
        val to = target(d) ?: return
        val from = here.value ?: origin(d)?.point ?: return
        val now = Iso.now()
        if (Geo.metres(from, to.point) < 400) {
            // you're there already: the other way
            if (!flipped && (pickedAt == 0.0 || now - pickedAt > 3 * 3600)) { direction.value = if (d == Direction.HOME) Direction.TO_SCHOOL else Direction.HOME; pickedAt = now; return refreshNext(true, flipped = true) }
            _next.value = emptyList(); return
        }
        if (!force && nextDir == d && nextFrom?.let { Geo.metres(it, from) < 400 } == true && now - nextTime < 120) return
        val sameWay = nextDir == d
        nextFrom = from; nextTime = now; nextDir = d
        _nextLoading.value = true
        val trips = Transit.tripsFrom(from, to.planId, keep = 4)
        _nextLoading.value = false
        _next.value = sticky(if (sameWay) _next.value else emptyList(), trips, now)
    }

    /**
     * (A8, iOS 0.40 `StickyTrips`) a failed or empty answer keeps what's still to come; a whole one replaces the list but
     * keeps the trip you're heading for (the one shown first) until it has left.
     */
    private fun sticky(kept: List<DoorTrip>, answer: List<DoorTrip>, now: Double): List<DoorTrip> {
        fun item(t: DoorTrip) = nl.haltewekker.travel.StickyTrips.Item(t.id, t.first.tripId, t.first.departure, t.start, t.first.cancelled)
        val held = nl.haltewekker.travel.StickyTrips.held(kept.firstOrNull()?.let(::item), now)
        val kind = if (answer.isEmpty()) nl.haltewekker.travel.StickyTrips.Answer.FAILED else nl.haltewekker.travel.StickyTrips.Answer.WHOLE
        val onIt = held != null && nl.haltewekker.ride.RideStore.state.value?.vehicleTripId == held
        val ids = nl.haltewekker.travel.StickyTrips.merge(kept.map(::item), answer.map(::item), kind, held, onIt, now)
        val all = (answer + kept).associateBy { it.id }
        val list = ids.mapNotNull { all[it] }
        // the card holds the one you're heading for while you can still reach its stop
        val here = here.value
        val hi = held?.let { h -> list.indexOfFirst { it.first.tripId == h } }?.takeIf { it >= 0 }
        val reach = if (hi != null) nl.haltewekker.travel.StickyTrips.reachable(here?.let { p -> list[hi].first.from?.let { Geo.metres(p, it) } }, list[hi].first.departure, now) else null
        val pick = nl.haltewekker.travel.StickyTrips.pick(list.map(::item), hi, reach, now) ?: return list
        return if (pick == 0) list else listOf(list[pick]) + list.filterIndexed { i, _ -> i != pick }
    }

    /** (A8) A trip put first ("From <stop>": switched to that departure). */
    fun putFirst(t: DoorTrip) { _next.value = listOf(t) + _next.value.filter { it.id != t.id } }

    /** The live map: buses and trains in view (Transitous's map; OVapi and NS positions where fresh). */
    suspend fun refreshVehicles(realPositions: Boolean) {
        val b = box ?: return
        val now = Iso.now()
        val (sw, ne) = b
        val tooBig = ne.lat - sw.lat > 0.12 || ne.lon - sw.lon > 0.2 || zoom < 11.5
        if (tooBig) { _dots.value = stopDots(); return }
        val moved = segmentsBox?.let { (a, c) -> sw.lat < a.lat || sw.lon < a.lon || ne.lat > c.lat || ne.lon > c.lon } ?: true
        if (moved || now - segmentsAt > 60) {
            val pad = 0.3
            val dLat = (ne.lat - sw.lat) * pad; val dLon = (ne.lon - sw.lon) * pad
            val a = GeoPoint(sw.lat - dLat, sw.lon - dLon); val c = GeoPoint(ne.lat + dLat, ne.lon + dLon)
            val got = Transit.vehicles(a, c, back = 60.0, ahead = 240.0)
            if (got.isNotEmpty() || segments.isEmpty()) { segments = got; segmentsAt = now; segmentsBox = a to c }
        }
        val buses = if (realPositions) LiveFeeds.busFixes() else emptyMap()
        val trains = if (realPositions) LiveFeeds.trainFixes() else emptyMap()
        place(buses, trains, sw, ne)
    }

    /** Between fetches, the vehicles move on along their roads by their times (cheap: no network). */
    fun moveOn() {
        val b = box ?: return
        place(LiveFeeds.buses.fixes, LiveFeeds.trains, b.first, b.second)
    }

    private fun place(buses: Map<String, nl.haltewekker.live.GPSFix>, trains: Map<Int, nl.haltewekker.live.GPSFix>, sw: GeoPoint, ne: GeoPoint) {
        val now = Iso.now()
        val out = ArrayList<MapDot>()
        for ((_, segs) in segments.groupBy { it.tripId }) {
            val s = segs.firstOrNull { it.position(now) != null } ?: segs.first()
            if (s.isTrain && RealPositions.isRail(s.mode)) continue      // trains: NS's own positions below
            val fix = RealPositions.usable(buses, s.tripId, now)
            val p = fix?.point ?: s.position(now) ?: continue
            if (p.lat < sw.lat || p.lat > ne.lat || p.lon < sw.lon || p.lon > ne.lon) continue
            out.add(MapDot(s.tripId, p, Tokens.light.kind(s.kind).toArgb(), s.line))
        }
        val distinct = out.distinctBy { it.id }.toMutableList()
        if (trains.isNotEmpty()) {
            for ((n, f) in trains) {
                if (now - f.at > RealPositions.FRESH) continue
                if (f.lat < sw.lat || f.lat > ne.lat || f.lon < sw.lon || f.lon > ne.lon) continue
                val kind = VehicleKind.of("RAIL", f.type ?: "", true)
                distinct.add(MapDot("ns$n", f.point, Tokens.light.kind(kind).toArgb(), f.type?.take(3) ?: "NS"))
            }
        } else {
            // no NS positions: trains by their times
            for (s in segments) if (s.isTrain && RealPositions.isRail(s.mode)) {
                val p = s.position(now) ?: continue
                if (p.lat < sw.lat || p.lat > ne.lat || p.lon < sw.lon || p.lon > ne.lon) continue
                if (distinct.none { it.id == s.tripId }) distinct.add(MapDot(s.tripId, p, Tokens.light.kind(s.kind).toArgb(), TransitParse.trainLabel(s.line)))
            }
        }
        _dots.value = stopDots() + distinct.take(300)
    }

    private fun stopDots(): List<MapDot> = _stops.value.map { MapDot("stop:${it.id}", GeoPoint(it.lat, it.lon), 0xFF5B636B.toInt(), "", "stop") }
}
