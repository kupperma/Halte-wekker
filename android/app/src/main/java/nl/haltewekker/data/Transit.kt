package nl.haltewekker.data

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.withContext
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.core.Iso
import nl.haltewekker.core.obj
import nl.haltewekker.core.s
import java.util.concurrent.ConcurrentHashMap

/** Talks to Transitous (free, volunteer-run: keep requests light). The network half of iOS `Transit.swift`. */
object Transit {
    const val BASE = "https://api.transitous.org/api"

    @Volatile var lastTrouble: String? = null
        private set

    /** (0.10.0, iOS `Net.Polite.transitous`) a few at a time, a pause after a 429 (see `Polite`). */
    val polite = Polite()

    /** Transitous asked to slow down and the pause is on: background requests (the nearby stops) aren't sent. */
    val cooling: Boolean get() = polite.coolingLeft != null

    private suspend fun ask(path: String, params: List<Pair<String, String>>): String? {
        val lane = kotlin.coroutines.coroutineContext[Polite.LaneElement]?.lane ?: Polite.Lane.URGENT
        val placed = try { polite.enter(lane, 30.0) } catch (_: Polite.Refused) {
            lastTrouble = "Transitous asked to slow down (cooling down)"
            nl.haltewekker.logs.FieldLog.add(nl.haltewekker.logs.FieldEntry.Kind.NET, "$path · ${Polite.COOLING_NOTE}")
            return null
        }
        if (!placed) { lastTrouble = "Transitous is busy (no answer in time)"; return null }
        val sent = polite.sending()
        val a = try { Net.get(BASE + path, params) } finally { polite.exit(lane) }
        if (a.status == 429) {
            polite.slowDown(a.retryAfter, sent)
            nl.haltewekker.logs.FieldLog.add(nl.haltewekker.logs.FieldEntry.Kind.NET, "$path · 429 · paused ${Math.round(polite.coolingLeft ?: 0.0)} s")
        } else if (a.status in 200..399) polite.answered()
        lastTrouble = when {
            a.status == -1 -> "No connection to Transitous"
            a.status == 429 -> "Transitous asked to slow down (HTTP 429)"
            a.status >= 500 -> "Transitous had a problem (HTTP ${a.status})"
            a.status >= 400 -> "Transitous said no (HTTP ${a.status})"
            else -> null
        }
        return if (a.ok) a.text else null
    }

    /** The same question asked to the minute within 45 s gets the same answer (iOS `PlanMemo`). */
    private class Kept(val at: Double, val trips: List<DoorTrip>)
    private val plans = ConcurrentHashMap<String, Kept>()

    /** `detailed` false (0.10.5, iOS 0.42.8): without the legs' shapes (`detailedLegs=false`, half the bytes), for a ride's
     *  own plans that never draw them. */
    suspend fun plan(from: String, to: String, at: Double, count: Int = 5, maxTransfers: Int = 4, arriveBy: Boolean = false, detailed: Boolean = true): List<DoorTrip> =
        withContext(Dispatchers.Default) { planHere(from, to, at, count, maxTransfers, arriveBy, detailed) }

    private suspend fun planHere(from: String, to: String, at: Double, count: Int, maxTransfers: Int, arriveBy: Boolean, detailed: Boolean): List<DoorTrip> {
        val minute = Math.floor(at / 60) * 60
        // (A6, iOS 0.34) your walking speed, when it's learned and clearly not the planner's own
        val walk = nl.haltewekker.travel.HabitStore.pedestrianSpeed()
        val key = "$from>$to@$minute|$count|$maxTransfers|$arriveBy|$walk|$detailed"
        val now = Iso.now()
        plans[key]?.let { if (now - it.at < 45) return it.trips }
        val q = mutableListOf("fromPlace" to from, "toPlace" to to, "numItineraries" to "$count", "maxTransfers" to "$maxTransfers",
            "time" to Iso.format(minute), "detailedTransfers" to "false")
        if (arriveBy) q.add("arriveBy" to "true")
        if (!detailed) q.add("detailedLegs" to "false")
        walk?.let { q.add("pedestrianSpeed" to String.format(java.util.Locale.ROOT, "%.1f", it)) }
        val trips = ask("/v5/plan", q)?.let(TransitParse::parsePlan) ?: return emptyList()
        if (trips.isNotEmpty()) {
            if (plans.size > 80) plans.clear()
            plans[key] = Kept(now, trips)
        }
        return trips
    }

    /** (0.10.0, iOS `Transit.planPage`) one page of a plan, its next page's cursor and its size; `failed`: no answer. */
    class Page(val trips: List<DoorTrip>, val cursor: String?, val bytes: Int, val failed: Boolean)

    /**
     * The nearby stops' plan (iOS 0.42.2): 8 itineraries (12 at most) in the next hour, 3 transfers at most, the walk
     * to the first stop up to `preTransit` seconds (0: the planner's own), without transfer details; your walking speed
     * once learned. `cursor`: the next page of an earlier one.
     */
    suspend fun planPage(from: String, to: String, at: Double, preTransit: Int, cursor: String?, count: Int = nl.haltewekker.travel.Nearby.ITINERARIES): Page =
        withContext(Dispatchers.Default) {
            val walk = nl.haltewekker.travel.HabitStore.pedestrianSpeed()
            val q = mutableListOf("fromPlace" to from, "toPlace" to to, "numItineraries" to "$count",
                "maxItineraries" to "${nl.haltewekker.travel.Nearby.MAX_ITINERARIES}", "searchWindow" to "${nl.haltewekker.travel.Nearby.SEARCH_WINDOW}",
                "maxTransfers" to "3", "time" to Iso.format(Math.floor(at / 60) * 60), "detailedTransfers" to "false")
            if (preTransit > 0) q.add("maxPreTransitTime" to "$preTransit")
            if (cursor != null) q.add("pageCursor" to cursor)
            walk?.let { q.add("pedestrianSpeed" to String.format(java.util.Locale.ROOT, "%.1f", it)) }
            val body = ask("/v5/plan", q) ?: return@withContext Page(emptyList(), null, 0, true)
            val next = TransitParse.json(body).obj?.s("nextPageCursor")
            Page(TransitParse.parsePlan(body), next, body.length, false)
        }

    /** Trips from a spot to a place, soonest first, without the ones a later trip beats. */
    suspend fun tripsFrom(here: GeoPoint, to: String, keep: Int = 5): List<DoorTrip> {
        val now = Iso.now()
        val all = plan("${here.lat},${here.lon}", to, now - 120, count = 5)
        return TransitParse.keepUseful(all, now, keep)
    }

    suspend fun findPlaces(text: String, near: GeoPoint?): List<PlaceHit> {
        val q = mutableListOf("text" to text, "numResults" to "12")
        near?.let { q.add("place" to "${it.lat},${it.lon}") }
        return ask("/v1/geocode", q)?.let { TransitParse.parseGeocode(it) } ?: emptyList()
    }

    private fun box(c: GeoPoint, dLat: Double, dLon: Double) =
        listOf("min" to "${c.lat - dLat},${c.lon - dLon}", "max" to "${c.lat + dLat},${c.lon + dLon}")

    /** The stops within about 1.3 km, nearest first (null: no answer). */
    suspend fun nearStops(c: GeoPoint): List<NearStop>? = ask("/v1/map/stops", box(c, 0.012, 0.019))?.let { TransitParse.parseNearStops(it, c) }

    /** The setup's home stops: one per stop area or name, nearest first. */
    suspend fun stopChoices(c: GeoPoint): List<NearStop>? = ask("/v1/map/stops", box(c, 0.008, 0.012))?.let { TransitParse.stopChoices(it, c) }

    /** The departure boards of stops, soonest first. */
    suspend fun board(stopIds: List<String>, n: Int = 20): List<BoardDeparture> = withContext(Dispatchers.Default) {
        stopIds.distinct().map { id ->
            async { ask("/v6/stoptimes", listOf("stopId" to id, "n" to "$n"))?.let { TransitParse.parseStopTimes(it, id) } ?: emptyList() }
        }.awaitAll().flatten().sortedBy { it.time }
    }

    /** Vehicles running in a box now and in the next minutes (the live map; matching). */
    suspend fun vehicles(min: GeoPoint, max: GeoPoint, back: Double = 60.0, ahead: Double = 240.0, allTrips: Boolean = false): List<VehicleSegment> =
        withContext(Dispatchers.Default) {
        val now = Iso.now()
        val q = listOf("min" to "${min.lat},${min.lon}", "max" to "${max.lat},${max.lon}",
            "startTime" to Iso.format(now - back), "endTime" to Iso.format(now + ahead), "zoom" to "15")
        ask("/v1/map/trips", q)?.let { TransitParse.parseMapTrips(it, allTrips) } ?: emptyList()
    }

    private class KeptTrip(val at: Double, val trip: TransitParse.LiveTrip)
    private val trips = ConcurrentHashMap<String, KeptTrip>()

    /** One trip with its live times, remembered for `maxAge` seconds. */
    suspend fun trip(tripId: String, maxAge: Double = 20.0): TransitParse.LiveTrip? = withContext(Dispatchers.Default) { tripHere(tripId, maxAge) }

    private suspend fun tripHere(tripId: String, maxAge: Double): TransitParse.LiveTrip? {
        val now = Iso.now()
        trips[tripId]?.let { if (now - it.at < maxAge) return it.trip }
        val t = ask("/v5/trip", listOf("tripId" to tripId))?.let(TransitParse::parseTrip) ?: return trips[tripId]?.trip
        if (trips.size > 50) trips.clear()
        trips[tripId] = KeptTrip(now, t)
        return t
    }
}
