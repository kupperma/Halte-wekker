package nl.haltewekker.data

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.core.Polyline
import nl.haltewekker.core.a
import nl.haltewekker.core.b
import nl.haltewekker.core.d
import nl.haltewekker.core.o
import nl.haltewekker.core.obj
import nl.haltewekker.core.s
import nl.haltewekker.core.t
import nl.haltewekker.core.text
import java.util.UUID

/**
 * Transitous's (MOTIS) answers read into the app's models: a port of the parsing in iOS `Transit.swift`. Pure: no
 * network, so every rule is unit-tested on saved answers.
 */
object TransitParse {
    fun json(body: String): JsonElement? = try { Json.parseToJsonElement(body) } catch (_: Exception) { null }

    fun isTrainMode(mode: String) = !(mode.contains("BUS") || mode.contains("COACH"))

    fun isRailStop(modes: List<String>) = modes.any { it.contains("RAIL") || it == "LONG_DISTANCE" || it == "HIGHSPEED" }

    /** "IC", "ICD", "SPR", else the first four letters (iOS `Transit.trainLabel`). */
    fun trainLabel(n: String): String {
        val l = n.lowercase()
        if ("intercity direct" in l) return "ICD"
        if ("intercity" in l) return "IC"
        if ("sprinter" in l) return "SPR"
        return n.take(4)
    }

    // MARK: plan (/v5/plan)

    fun parseItinerary(it: JsonObject): DoorTrip? {
        val legs = it.a("legs").mapNotNull { it.obj }
        val rides = ArrayList<Ride>()
        for ((i, l) in legs.withIndex()) {
            val mode = l.s("mode") ?: ""
            if (mode == "WALK") continue
            val train = isTrainMode(mode)
            val from = l.o("from") ?: JsonObject(emptyMap())
            val to = l.o("to") ?: JsonObject(emptyMap())
            val dep = l.t("startTime") ?: continue
            val arr = l.t("endTime") ?: continue
            val short = l.s("routeShortName") ?: l.s("displayName") ?: "?"
            var walk = 0
            if (i > 0 && legs[i - 1].s("mode") == "WALK") {
                val a = legs[i - 1].t("startTime")
                val b = legs[i - 1].t("endTime")
                if (a != null && b != null) walk = mins(b - a)
            }
            rides.add(
                Ride(
                    tripId = l.s("tripId") ?: UUID.randomUUID().toString(),
                    line = if (train) trainLabel(short) else short, name = short, isTrain = train,
                    departure = dep, scheduledDeparture = l.t("scheduledStartTime") ?: dep,
                    arrival = arr, scheduledArrival = l.t("scheduledEndTime") ?: arr,
                    fromStop = from.s("name") ?: "", fromId = from.s("stopId") ?: (from.s("name") ?: ""),
                    toStop = to.s("name") ?: "",
                    platform = from.s("track") ?: from.s("scheduledTrack"),
                    live = l.b("realTime") ?: false, cancelled = l.b("cancelled") ?: false, walkBefore = walk,
                    num = l["tripShortName"].text, headsign = l.s("headsign") ?: "",
                    plannedPlatform = from.s("scheduledTrack") ?: from.s("track"),
                    fromLat = from.d("lat"), fromLon = from.d("lon"), toLat = to.d("lat"), toLon = to.d("lon"),
                    mode = mode, agency = l.s("agencyName"),
                ),
            )
        }
        if (rides.isEmpty()) return null
        val s = it.t("startTime") ?: return null
        val e = it.t("endTime") ?: return null
        return DoorTrip(rides, s, e)
    }

    fun parsePlan(body: String): List<DoorTrip> =
        json(body).obj?.a("itineraries")?.mapNotNull { it.obj?.let(::parseItinerary) } ?: emptyList()

    /**
     * The trips worth showing, soonest first: nothing that has left, none a later trip beats (leaves no earlier and
     * arrives sooner), at most `keep` (iOS `keepUseful` / `nextTrips`).
     */
    fun keepUseful(all: List<DoorTrip>, now: Double, keep: Int): List<DoorTrip> {
        val seen = HashSet<String>()
        val sorted = all.filter { it.first.departure >= now - 60 && it.start >= now - 90 && seen.add(it.id) }
            .sortedBy { it.first.departure }
        val kept = sorted.filter { t -> sorted.none { it.id != t.id && it.first.departure >= t.first.departure && it.end < t.end } }
        return kept.take(keep)
    }

    // MARK: geocode (/v1/geocode)

    fun parseGeocode(body: String, stopsOnly: Boolean = false): List<PlaceHit> {
        val list = json(body) as? kotlinx.serialization.json.JsonArray ?: return emptyList()
        return list.mapNotNull { e ->
            val m = e.obj ?: return@mapNotNull null
            val name = m.s("name") ?: return@mapNotNull null
            val la = m.d("lat") ?: return@mapNotNull null
            val lo = m.d("lon") ?: return@mapNotNull null
            val country = m.s("country")
            if (country != null && country !in setOf("NL", "BE", "DE")) return@mapNotNull null
            val type = m.s("type")
            if (stopsOnly && type != "STOP") return@mapNotNull null
            val areas = m.a("areas").mapNotNull { it.obj }
            val area = areas.firstOrNull { it.b("default") == true } ?: areas.firstOrNull { it.b("matched") == true } ?: areas.firstOrNull()
            val kind = when (type) { "STOP" -> "stop"; "ADDRESS" -> "address"; else -> "place" }
            PlaceHit(m.s("id") ?: "$la,$lo", name, area?.s("name") ?: "", la, lo, kind)
        }
    }

    // MARK: stops near a spot (/v1/map/stops)

    /** One entry per station (by its parent) or stop, nearest first (iOS `nearStopsAnswer`). */
    fun parseNearStops(body: String, here: GeoPoint): List<NearStop>? {
        val list = json(body) as? kotlinx.serialization.json.JsonArray ?: return null
        val seen = HashSet<String>()
        return list.mapNotNull { e ->
            val m = e.obj ?: return@mapNotNull null
            val id = m.s("stopId") ?: return@mapNotNull null
            val name = m.s("name") ?: return@mapNotNull null
            val la = m.d("lat") ?: return@mapNotNull null
            val lo = m.d("lon") ?: return@mapNotNull null
            val rail = isRailStop(m.a("modes").mapNotNull { it.text.takeIf { s -> s.isNotEmpty() } })
            val key = if (rail) (m.s("parentId") ?: id) else id
            if (!seen.add(key)) return@mapNotNull null
            NearStop(key, name, la, lo, rail, Geo.metres(here, GeoPoint(la, lo)))
        }.sortedBy { it.meters }
    }

    /**
     * The setup's home stops: one per stop area (parent) or name, nearest first, at most `limit` (iOS
     * `SetupLogic.stopChoices`). Uses the parent's id for a station, so the board covers every platform.
     */
    fun stopChoices(body: String, here: GeoPoint, limit: Int = 8): List<NearStop>? {
        val list = json(body) as? kotlinx.serialization.json.JsonArray ?: return null
        data class Raw(val id: String, val name: String, val parent: String?, val m: Double, val rail: Boolean, val lat: Double, val lon: Double)
        val raw = list.mapNotNull { e ->
            val m = e.obj ?: return@mapNotNull null
            val id = m.s("stopId") ?: return@mapNotNull null
            val name = m.s("name") ?: return@mapNotNull null
            val la = m.d("lat") ?: return@mapNotNull null
            val lo = m.d("lon") ?: return@mapNotNull null
            Raw(id, name, m.s("parentId"), Geo.metres(here, GeoPoint(la, lo)),
                isRailStop(m.a("modes").map { it.text }), la, lo)
        }
        val out = ArrayList<NearStop>()
        val seen = HashSet<String>()
        for (r in raw.sortedBy { it.m }) {
            val key = r.parent?.let { "p:$it" } ?: "n:${r.name.lowercase()}"
            if (!seen.add(key)) continue
            out.add(NearStop(r.parent ?: r.id, r.name, r.lat, r.lon, r.rail, r.m))
            if (out.size == limit) break
        }
        return out
    }

    // MARK: departures (/v6/stoptimes)

    fun parseStopTimes(body: String, stopId: String): List<BoardDeparture>? {
        val list = json(body).obj?.a("stopTimes") ?: return null
        return list.mapNotNull { e ->
            val st = e.obj ?: return@mapNotNull null
            val p = st.o("place") ?: JsonObject(emptyMap())
            val t = p.t("departure") ?: p.t("arrival") ?: return@mapNotNull null
            val mode = st.s("mode") ?: "BUS"
            BoardDeparture(
                tripId = st.s("tripId") ?: "", stopId = stopId, stopName = p.s("name") ?: "",
                line = st.s("routeShortName") ?: "?", headsign = st.s("headsign") ?: "",
                time = t, scheduled = p.t("scheduledDeparture") ?: t, live = st.b("realTime") ?: false,
                cancelled = (st.b("cancelled") ?: false) || (st.b("tripCancelled") ?: false) || (p.b("cancelled") ?: false),
                platform = p.s("track") ?: p.s("scheduledTrack"), train = isTrainMode(mode), mode = mode,
            )
        }
    }

    // MARK: vehicles running (/v1/map/trips)

    /** Each piece's first trip (`allTrips`: every trip on it), as iOS `vehicleSegments` / `liveVehicles`. */
    fun parseMapTrips(body: String, allTrips: Boolean = false): List<VehicleSegment> {
        val list = json(body) as? kotlinx.serialization.json.JsonArray ?: return emptyList()
        return list.flatMap { e ->
            val s = e.obj ?: return@flatMap emptyList()
            val mode = s.s("mode") ?: ""
            if (mode == "AIRPLANE") return@flatMap emptyList()
            val trips = s.a("trips").mapNotNull { it.obj }
            val dep = s.t("departure") ?: return@flatMap emptyList()
            val arr = s.t("arrival") ?: return@flatMap emptyList()
            val poly = s.s("polyline") ?: return@flatMap emptyList()
            val path = Polyline.decode(poly)
            val train = isTrainMode(mode)
            (if (allTrips) trips else trips.take(1)).mapNotNull { t ->
                val id = t.s("tripId") ?: return@mapNotNull null
                val line = t.s("routeShortName") ?: "?"
                VehicleSegment(
                    tripId = id, line = if (train) trainLabel(line) else line, isTrain = train,
                    fromName = s.o("from")?.s("name") ?: "", toName = s.o("to")?.s("name") ?: "",
                    departure = dep, arrival = arr, path = path, realTime = s.b("realTime") ?: false,
                    scheduledDeparture = s.t("scheduledDeparture"), scheduledArrival = s.t("scheduledArrival"), mode = mode,
                )
            }
        }
    }

    // MARK: one trip (/v5/trip)

    data class LiveTrip(val line: String, val headsign: String, val mode: String, val num: String, val live: Boolean,
                        val stops: List<TripStop>, val path: List<GeoPoint>)

    fun parseTrip(body: String): LiveTrip? {
        val legs = json(body).obj?.a("legs")?.mapNotNull { it.obj } ?: return null
        if (legs.isEmpty()) return null
        val stops = ArrayList<TripStop>()
        val path = ArrayList<GeoPoint>()
        var line = ""; var head = ""; var mode = ""; var num = ""; var live = false
        fun stop(o: JsonObject?): TripStop? {
            o ?: return null
            val la = o.d("lat") ?: return null
            val lo = o.d("lon") ?: return null
            return TripStop(o.s("name") ?: "", GeoPoint(la, lo), o.t("arrival"), o.t("departure"), o.t("scheduledDeparture"), o.b("cancelled") ?: false)
        }
        var tripCancelled = false
        for (l in legs) {
            line = l.s("routeShortName") ?: line
            head = l.s("headsign") ?: head
            mode = l.s("mode") ?: mode
            if (num.isEmpty()) num = l["tripShortName"].text
            live = live || (l.b("realTime") ?: false)
            if ((l.b("cancelled") ?: false) || (l.b("tripCancelled") ?: false)) tripCancelled = true
            if (stops.isEmpty()) stop(l.o("from"))?.let(stops::add)
            for (o in l.a("intermediateStops")) stop(o.obj)?.let(stops::add)
            stop(l.o("to"))?.let(stops::add)
            l.o("legGeometry")?.let { g -> g.s("points")?.let { path += Polyline.decode(it, g.d("precision")?.toInt() ?: 5) } }
        }
        if (stops.size < 2) return null
        // (A4) a trip cancelled as a whole: every stop is (only the delay alarm reads it)
        val all = if (tripCancelled) stops.map { it.copy(cancelled = true) } else stops
        return LiveTrip(line, head, mode, num, live, all, path)
    }

    /** The trip's stop nearest `p` (within `maxMetres`), for the live arrival at your stop. */
    fun stopNear(stops: List<TripStop>, p: GeoPoint, maxMetres: Double = 400.0): TripStop? =
        stops.minByOrNull { Geo.metres(it.point, p) }?.takeIf { Geo.metres(it.point, p) <= maxMetres }
}
