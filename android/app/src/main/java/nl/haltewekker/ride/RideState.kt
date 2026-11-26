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
    /** (A2) Started by itself, on leaving a home stop or School. */
    val auto: Boolean = false,
    /** (A3) The last fix (5 decimals), for friends you show your trips to. */
    val lastLat: Double? = null,
    val lastLon: Double? = null,
    /** (A4) The leg the ride started at (0: from the start, so a finished trip counts on the leaderboard). */
    val firstLeg: Int? = null,
    /** (A6, iOS 0.33) Rung by time: the minutes it rang at (the alarm says "in about 3 min"). */
    val ringMinutes: Int? = null,
    /** (A6, iOS 0.34) No good GPS for a while: the place goes on along the vehicle's route. */
    val reckoning: Boolean = false,
    /** (A6, iOS 0.35) where you were when it started (if known) and when that fix was, for the leaderboard's start. */
    val startLat: Double? = null,
    val startLon: Double? = null,
    val startFixAt: Double? = null,
    /** (A6, iOS 0.35) the ride that was latest at your stop so far, and by how many minutes. */
    val lateLine: String? = null,
    val lateMins: Double? = null,
    /** (A6, iOS 0.36) the trains' minutes late at their stops, and the train part's planned and actual end (money back). */
    val trainLates: List<Double> = emptyList(),
    val trainEndPlanned: Double? = null,
    val trainEndActual: Double? = null,
    /** (A6, iOS 0.34) when you got off at a change (for the change time you need), and the vehicle you got off. */
    val changeArrived: Double? = null,
    val changeFromVehicle: String? = null,
    /** (A7) choosing between these ("Bus 305", "IC to Breda"): the ride screen says it's checking. */
    val choosing: List<String> = emptyList(),
    /** (A7, iOS 0.34 / 0.38) the one-time "305 or 306?" card: its two ids and buttons. */
    val ask: AskCard? = null,
    /** (A7, iOS 0.39.1) "You’re on the 154 to Schijndel, not your 306", once a ride; and "That’s the 154 — not yours". */
    val wrongBus: RideAlert? = null,
    val wrongBusTold: Boolean = false,
    val otherAtStop: RideAlert? = null,
    /** (A7) when it rang (the one repeat 30 s later), and whether that went. */
    val rangAt: Double? = null,
    val againSent: Boolean = false,
    /** (A8) this leg's ring was noted for the adaptive wake-up. */
    val wakeNoted: Boolean = false,
    /** (A8, iOS 0.39) the quiet "Get ready" went for this leg; no network: going by the saved stops and times. */
    val readyTold: Boolean = false,
    val offline: Boolean = false,
    /** (A8, iOS 0.39) the next stop (not yours), the delay at your stop and the change line, for the lock screen. */
    val nextStop: String? = null,
    val delayMin: Int? = null,
    val changeLine: String? = null,
    val changeMiss: String? = null,
    val changeSwitch: String? = null,
) {
    val leg: Ride? get() = trip.rides.getOrNull(index)
    val wakeMetres: Double get() = (wakeKm.getOrNull(index) ?: WakeRules.BUS_KM) * 1000
    val finished: Boolean get() = phase == Phase.FINISHED
    /** When this leg gets you to your stop: live once it's known, else the plan's. */
    val legArrival: Double? get() = eta ?: leg?.arrival
}

@Serializable
data class AskCard(val title: String, val body: String, val ids: List<String>, val answers: List<String>, val lines: List<String>, val train: Boolean)

@Serializable
data class RideAlert(val title: String, val body: String, val tripId: String)

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
