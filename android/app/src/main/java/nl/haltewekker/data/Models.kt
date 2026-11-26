package nl.haltewekker.data

import kotlinx.serialization.Serializable
import nl.haltewekker.core.GeoPoint
import kotlin.math.max
import kotlin.math.roundToInt

/** Minutes, rounded (iOS `Fmt.mins`). */
fun mins(seconds: Double): Int = (seconds / 60).roundToInt()

/** One bus or train ride inside a trip (iOS `Ride`). Times are seconds since 1970. */
@Serializable
data class Ride(
    val tripId: String,
    val line: String,               // "306", "IC", "SPR"
    val name: String,               // "Intercity", "306"
    val isTrain: Boolean,
    val departure: Double,
    val scheduledDeparture: Double,
    val arrival: Double,
    val scheduledArrival: Double,
    val fromStop: String,
    val fromId: String,
    val toStop: String,
    val platform: String? = null,
    val live: Boolean = false,
    val cancelled: Boolean = false,
    val walkBefore: Int = 0,
    val num: String = "",
    val headsign: String = "",
    val plannedPlatform: String? = null,
    val fromLat: Double? = null,
    val fromLon: Double? = null,
    val toLat: Double? = null,
    val toLon: Double? = null,
    val mode: String = "",
    /** (A7) Transitous's `agencyName` (NS, Arriva, Qbuzz…): two trains of two companies are two check-outs. */
    val agency: String? = null,
) {
    val id: String get() = "$tripId|${departure.toLong()}"
    val delay: Int get() = if (live) mins(departure - scheduledDeparture) else 0
    val rideMinutes: Int get() = mins(arrival - departure)
    val to: GeoPoint? get() = if (toLat != null && toLon != null) GeoPoint(toLat, toLon) else null
    val from: GeoPoint? get() = if (fromLat != null && fromLon != null) GeoPoint(fromLat, fromLon) else null
    val kind: VehicleKind get() = VehicleKind.of(mode, if (isTrain) name else line, isTrain)
    fun walking(minutes: Int) = copy(walkBefore = minutes)
}

/** A door-to-door trip from the planner: the rides plus where it starts and ends (iOS `DoorTrip`). */
@Serializable
data class DoorTrip(val rides: List<Ride>, val start: Double, val end: Double) {
    val id: String get() = rides.joinToString("+") { it.id }
    val first: Ride get() = rides.first()
    val last: Ride get() = rides.last()
    val changes: List<String> get() = rides.drop(1).map { it.fromStop }
    val rideMinutes: Double get() = (last.arrival - first.departure) / 60
    val walkAfter: Int get() = max(0, mins(end - last.arrival))
    val totalMinutes: Int get() = mins(end - start)
}

/** A departure from a stop's board (iOS `BoardDeparture`). */
@Serializable
data class BoardDeparture(
    val tripId: String,
    val stopId: String,
    val stopName: String,
    val line: String,
    val headsign: String,
    val time: Double,
    val scheduled: Double,
    val live: Boolean,
    val cancelled: Boolean,
    val platform: String?,
    val train: Boolean = false,
    val mode: String = "",
) {
    val delay: Int get() = if (live) mins(time - scheduled) else 0
    val kind: VehicleKind get() = VehicleKind.of(mode, line, train)
}

/** A stop near you: a bus stop, or a train station by the station (iOS `Transit.NearStop`). */
@Serializable
data class NearStop(val id: String, val name: String, val lat: Double, val lon: Double, val rail: Boolean, val meters: Double)

/** A search hit: a stop, an address or a named place (iOS `Transit.PlaceHit`). */
@Serializable
data class PlaceHit(val id: String, val name: String, val town: String, val lat: Double, val lon: Double, val kind: String)

/** A stop-to-stop piece of a running vehicle from the live map (iOS `VehicleSegment`). */
data class VehicleSegment(
    val tripId: String,
    val line: String,
    val isTrain: Boolean,
    val fromName: String,
    val toName: String,
    val departure: Double,
    val arrival: Double,
    val path: List<GeoPoint>,
    val realTime: Boolean = false,
    val scheduledDeparture: Double? = null,
    val scheduledArrival: Double? = null,
    val mode: String = "",
) {
    /** Where its times put it at `t`, by time along its path (nil outside its piece, with 30 s slack). */
    fun position(t: Double): GeoPoint? {
        if (t < departure - 30 || t > arrival + 30 || path.size < 2) return null
        val span = max(1.0, arrival - departure)
        val f = ((t - departure) / span).coerceIn(0.0, 1.0)
        return nl.haltewekker.core.Geo.pointAtMetres(f * nl.haltewekker.core.Geo.length(path), path)
    }
    val kind: VehicleKind get() = VehicleKind.of(mode, line, isTrain)
}

/** One stop of a trip with its live times (iOS `TripStop` / `LiveTrip.Stop`). */
data class TripStop(val name: String, val point: GeoPoint, val arrival: Double?, val departure: Double?,
                    /** (A4) The planned departure and whether the live data says it's cancelled there (the delay alarm). */
                    val scheduledDeparture: Double? = null, val cancelled: Boolean = false)

/** The kind of vehicle, for its colour (iOS `VehicleKind`). */
enum class VehicleKind {
    BUS, IC, SPRINTER, TRAM, METRO, TRAIN;

    companion object {
        fun of(mode: String, line: String, isTrain: Boolean): VehicleKind {
            val m = mode.uppercase()
            if ("TRAM" in m) return TRAM
            if ("SUBWAY" in m || "METRO" in m) return METRO
            if ("BUS" in m || "COACH" in m) return BUS
            val l = line.trim().uppercase()
            railKind(l)?.let { return it }
            if ("HIGHSPEED" in m || "LONG_DISTANCE" in m) return IC
            if (m.isEmpty() && !isTrain) return BUS
            return TRAIN
        }

        private val icWords = setOf("IC", "ICE", "ICD", "ICNG", "ICM", "ICR", "EC", "ECE", "EN", "EST", "NJ", "TGV", "THA", "RJ", "RJX")

        private fun railKind(l: String): VehicleKind? {
            if (l.isEmpty()) return null
            val words = l.split(Regex("[^\\p{L}\\p{N}]+")).filter { it.isNotEmpty() }
            val first = words.firstOrNull() ?: l
            if (first == "SPR" || "SPRINTER" in l || l.startsWith("STOP") || first == "ST") return SPRINTER
            if (first in icWords) return IC
            if (first.startsWith("IC") && first.length <= 4 && first.none { it.isDigit() }) return IC
            if ("INTERCITY" in l || "EURO" in l || "NIGHTJET" in l || "THALYS" in l) return IC
            return null
        }
    }
}
