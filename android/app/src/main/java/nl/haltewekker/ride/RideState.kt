package nl.haltewekker.ride

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import nl.haltewekker.data.DoorTrip
import nl.haltewekker.data.Ride

/** How the ride knows which bus or train you're on. */
@Serializable
enum class VehicleSource { NONE, BY_HAND, BY_GPS, BY_TIMES }

/** A running ride (iOS `TripManager`'s published state), saved so it survives the process being restarted. */
@Serializable
data class RideState(
    val trip: DoorTrip,
    val destination: String,
    val index: Int = 0,
    val phase: Phase = Phase.SLEEPING,
    val startedAt: Double,
    val legStart: Double,
    val wakeKm: List<Double>,
    val vehicleTripId: String? = null,
    val vehicleLine: String? = null,
    val vehicleSource: VehicleSource = VehicleSource.NONE,
    val distance: Double? = null,
    val accuracy: Double? = null,
    val speed: Double? = null,
    val eta: Double? = null,
    val lastFixAt: Double? = null,
    val quiet: Boolean = false,
    val roughGPS: Boolean = false,
    val note: String? = null,
) {
    val leg: Ride? get() = trip.rides.getOrNull(index)
    val wakeMetres: Double get() = (wakeKm.getOrNull(index) ?: WakeRules.BUS_KM) * 1000
    val finished: Boolean get() = phase == Phase.FINISHED
    /** When this leg gets you to your stop: live once it's known, else the plan's. */
    val legArrival: Double? get() = eta ?: leg?.arrival
}

/** The ride as state the screens and the notification follow (one per process). */
object RideStore {
    private const val KEY = "ride.v1"
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val _state = MutableStateFlow<RideState?>(null)
    val state: StateFlow<RideState?> = _state
    private var loaded = false

    fun load(context: Context) {
        if (loaded) return
        loaded = true
        val s = context.getSharedPreferences("haltewekker", Context.MODE_PRIVATE).getString(KEY, null) ?: return
        _state.value = try { json.decodeFromString<RideState>(s) } catch (_: Exception) { null }
    }

    fun set(context: Context, s: RideState?) {
        _state.value = s
        context.getSharedPreferences("haltewekker", Context.MODE_PRIVATE).edit().apply {
            if (s == null) remove(KEY) else putString(KEY, json.encodeToString(s))
        }.apply()
    }

    fun update(context: Context, f: (RideState) -> RideState) { _state.value?.let { set(context, f(it)) } }
}
