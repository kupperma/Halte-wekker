package nl.haltewekker.ride

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

/** (A8, iOS 0.39 `RideCache`) one ride as saved on the phone: its stops and the road it takes. */
@Serializable
data class SavedRide(
    val tripId: String, val line: String, val headsign: String = "", val isTrain: Boolean, val live: Boolean, val mode: String = "",
    val savedAt: Double, val stops: List<Stop>, val shape: List<GeoPoint>,
) {
    @Serializable
    data class Stop(val name: String, val lat: Double, val lon: Double, val arrival: Double? = null, val departure: Double? = null,
                    val scheduled: Double? = null, val platform: String? = null) {
        val point: GeoPoint get() = GeoPoint(lat, lon)
    }
}

@Serializable
data class SavedTrip(val trip: Double, val rides: List<SavedRide> = emptyList())

/** Without signal: the trip's rides saved when it starts, bounded, for that trip only. Plain values, tested. */
object RideCache {
    const val MAX_RIDES = 4
    const val MAX_STOPS = 120
    const val MAX_SHAPE = 400
    const val MAX_BYTES = 160_000
    const val MAX_AGE = 6 * 3600.0
    const val EVERY = 120.0
    const val NEAR = 1500.0
    private val json = Json { ignoreUnknownKeys = true }

    fun thin(path: List<GeoPoint>, limit: Int = MAX_SHAPE): List<GeoPoint> {
        if (limit < 2 || path.size <= limit) return path
        val last = path.size - 1
        return (0 until limit).map { i -> path[Math.round(i.toDouble() * last / (limit - 1)).toInt()] }
    }

    fun bounded(r: SavedRide) = r.copy(stops = r.stops.take(MAX_STOPS), shape = thin(r.shape))

    fun put(ride: SavedRide, saved: SavedTrip?, trip: Double): SavedTrip {
        val s = saved?.takeIf { it.trip == trip } ?: SavedTrip(trip)
        val rides = (s.rides.filter { it.tripId != ride.tripId } + bounded(ride)).takeLast(MAX_RIDES)
        return s.copy(rides = rides)
    }

    fun ride(tripId: String, saved: SavedTrip?, trip: Double?, now: Double): SavedRide? {
        if (saved == null || trip == null || saved.trip != trip) return null
        return saved.rides.lastOrNull { it.tripId == tripId && now - it.savedAt <= MAX_AGE }
    }

    fun keep(saved: SavedTrip?, trip: Double?, now: Double): Boolean {
        if (saved == null || trip == null || saved.trip != trip) return false
        return now - trip <= MAX_AGE
    }

    fun due(lastSaved: Double?, now: Double): Boolean = lastSaved == null || now - lastSaved >= EVERY

    fun encode(s: SavedTrip): String? {
        var t = s
        while (true) {
            val d = try { json.encodeToString(SavedTrip.serializer(), t) } catch (_: Exception) { return null }
            if (d.toByteArray().size <= MAX_BYTES) return d
            if (t.rides.size <= 1) return null
            t = t.copy(rides = t.rides.drop(1))
        }
    }

    fun decode(text: String): SavedTrip? = try { json.decodeFromString(SavedTrip.serializer(), text) } catch (_: Exception) { null }

    fun times(r: SavedRide): List<Double?> = r.stops.mapIndexed { i, s -> if (i == 0) s.departure ?: s.arrival else s.arrival ?: s.departure }

    fun stop(near: GeoPoint, r: SavedRide, after: Int? = null): Int? {
        val i = r.stops.indices.filter { after == null || it > after }.minByOrNull { Geo.metres(r.stops[it].point, near) } ?: return null
        return if (Geo.metres(r.stops[i].point, near) <= NEAR) i else null
    }

    fun delay(r: SavedRide, i: Int): Int? {
        if (!r.live || i !in r.stops.indices) return null
        val s = r.stops[i].scheduled ?: return null
        val t = (if (i == 0) r.stops[i].departure ?: r.stops[i].arrival else r.stops[i].arrival ?: r.stops[i].departure) ?: return null
        return Math.round((t - s) / 60).toInt()
    }

    fun backOnline(wasOffline: Boolean, online: Boolean) = wasOffline && online
}

/** (A8, iOS 0.40 `WalkPlan`) the walk at your own speed, with 2 min spare; the time to leave only ever moves later by what it saves less the spare. */
object WalkPlan {
    const val SPARE = 2
    const val WALKS_NEEDED = 5

    data class Shown(val walk: Int, val spare: Int, val later: Int, val learned: Boolean)

    fun walk(planned: Int, metres: Double?, speed: Double?, walks: Int, plannerSpeed: Double): Int {
        if (planned <= 0) return planned
        if (walks < WALKS_NEEDED || speed == null || !speed.isFinite() || speed <= 0) return planned
        val base = if (plannerSpeed.isFinite() && plannerSpeed > 0) plannerSpeed else 1.2
        val m = metres?.takeIf { it.isFinite() && it > 0 } ?: (planned * 60 * base)
        val mine = ceil(m / speed / 60).toInt()
        return max(1, min(planned, mine))
    }

    fun shown(planned: Int, metres: Double?, speed: Double?, walks: Int, plannerSpeed: Double): Shown {
        val w = walk(planned, metres, speed, walks, plannerSpeed)
        val learned = walks >= WALKS_NEEDED && speed != null && planned > 0
        if (!learned) return Shown(planned, 0, 0, false)
        val saved = max(0, planned - w)
        val later = max(0, saved - SPARE)
        return Shown(w, saved - later, later, true)
    }

    fun leave(leave: Double, s: Shown) = leave + s.later * 60.0

    fun words(s: Shown, leaveIn: Int?, leaveBy: String?): String {
        var t = "${s.walk} min walk"
        if (leaveIn != null) t += if (leaveIn <= 0) " · leave now" else " · leave in $leaveIn min"
        else if (!leaveBy.isNullOrEmpty()) t += " · leave by $leaveBy"
        if (s.learned && s.spare > 0 && (leaveIn != null || leaveBy != null)) t += " (${s.spare} min spare)"
        return t
    }
}

/** (A8) The running trip's saved rides (`no_backup/ridecache.json`): written when it starts and every 2 minutes, gone when it ends. */
object RideCacheStore {
    private var saved: SavedTrip? = null
    private val lastSaved = HashMap<String, Double>()
    private fun file(c: android.content.Context) = java.io.File(c.noBackupFilesDir, "ridecache.json")

    fun load(c: android.content.Context, trip: Double?) {
        if (saved != null) return
        saved = try { file(c).takeIf { it.exists() }?.readText()?.let(RideCache::decode) } catch (_: Exception) { null }
        if (!RideCache.keep(saved, trip, nl.haltewekker.core.Iso.now())) clear(c)
    }

    fun due(tripId: String, now: Double) = RideCache.due(lastSaved[tripId], now)

    fun put(c: android.content.Context, tripId: String, t: nl.haltewekker.data.TransitParse.LiveTrip, trip: Double, now: Double) {
        val r = SavedRide(tripId, t.line, t.headsign, t.mode.uppercase().let { it.contains("RAIL") || it.contains("TRAIN") }, t.live, t.mode, now,
            t.stops.map { SavedRide.Stop(it.name, it.point.lat, it.point.lon, it.arrival, it.departure, it.scheduledDeparture, null) }, t.path)
        val s = RideCache.put(r, saved, trip)
        saved = s
        lastSaved[tripId] = now
        RideCache.encode(s)?.let { text -> try { file(c).writeText(text) } catch (_: Exception) {} }
    }

    /** (0.10.1) The saved copy of a ride as it is (the live link's stops and road). */
    fun saved(tripId: String, trip: Double?, now: Double): SavedRide? = RideCache.ride(tripId, saved, trip, now)

    /** The saved copy of a ride, as a trip answer. */
    fun live(tripId: String, trip: Double?, now: Double): nl.haltewekker.data.TransitParse.LiveTrip? {
        val r = RideCache.ride(tripId, saved, trip, now) ?: return null
        return nl.haltewekker.data.TransitParse.LiveTrip(r.line, r.headsign, r.mode, "", r.live,
            r.stops.map { nl.haltewekker.data.TripStop(it.name, it.point, it.arrival, it.departure, it.scheduled) }, r.shape)
    }

    fun clear(c: android.content.Context) { saved = null; lastSaved.clear(); try { file(c).delete() } catch (_: Exception) {} }
}
