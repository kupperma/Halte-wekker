package nl.haltewekker.ride

import kotlinx.serialization.Serializable
import kotlin.math.max
import kotlin.math.roundToInt

/** A ride's phase, as iOS `TripManager.Phase`. */
@Serializable
enum class Phase { SLEEPING, ALARM, AWAKE, FINISHED }

/**
 * When the ride rings and when it says you're there: distance-based, as the iOS app (`TripManager.handle`): it rings
 * `busKm` (2 km) or `trainKm` (5 km) before the last stop of each leg; once awake, at 450 m it chimes "you're there"
 * and goes on to the next leg. Pure, so every rule is unit-tested.
 */
object WakeRules {
    const val BUS_KM = 2.0
    const val TRAIN_KM = 5.0
    const val ARRIVE_M = 450.0
    const val GOOD_ACCURACY = 250.0       // m: a fix this good or better counts for the wake-up
    const val ARRIVE_ACCURACY = 600.0     // …and this for "you're there"
    const val EARLY_LEG = 20.0            // s: inside the wake distance this soon after the leg started: awake, silently
    const val LOUD_AFTER = 60.0           // s: with "Out loud if I don't stop it" on (iOS 0.42.9: off by default), out loud after this

    fun wakeKm(isTrain: Boolean, busKm: Double = BUS_KM, trainKm: Double = TRAIN_KM): Double = if (isTrain) trainKm else busKm

    enum class Action { NONE, RING, AWAKE_SILENTLY, ARRIVE }

    /**
     * What one GPS fix does: `metres` to the leg's stop, the fix's `accuracy`, `legAge` seconds since the leg started.
     * - asleep and within the wake distance: ring (or, within 20 s of the leg's start, only stay awake: you started
     *   the ride that close to the stop, as iOS `RideGuards.wakeAtStart`);
     * - awake and within 450 m: arrive.
     */
    fun onFix(phase: Phase, metres: Double, accuracy: Double, legAge: Double, wakeMetres: Double): Action {
        if (!metres.isFinite() || metres < 0 || !accuracy.isFinite() || accuracy < 0) return Action.NONE
        return when (phase) {
            Phase.SLEEPING ->
                if (accuracy < GOOD_ACCURACY && metres <= wakeMetres) (if (legAge < EARLY_LEG) Action.AWAKE_SILENTLY else Action.RING)
                else Action.NONE
            Phase.AWAKE -> if (metres <= ARRIVE_M && accuracy <= ARRIVE_ACCURACY) Action.ARRIVE else Action.NONE
            else -> Action.NONE
        }
    }

    /** No headphones in and the setting on: it only vibrates (iOS `AlarmSound.quietNow`, 0.24.3). */
    fun quiet(headphonesOnly: Boolean, privateOutput: Boolean): Boolean = headphonesOnly && !privateOutput

    /** (iOS 0.42.9 `RingShow`) every kind of ring. */
    enum class RingKind { ALARM, HEADPHONES_QUIET, PHONE_IN_USE, BY_TIME, RECKONED, BACKUP, AGAIN, SHORT_NOTICE, GET_READY, ARRIVED }

    /** The alarm's own notification (full screen, Stop alarm) and the ringing ride: every ring, not the quiet words. */
    fun lockRinging(k: RingKind): Boolean = k != RingKind.SHORT_NOTICE && k != RingKind.GET_READY && k != RingKind.ARRIVED

    /** Without headphones it stays vibration only, out loud after `LOUD_AFTER` only with that switch on. */
    fun loudLater(quiet: Boolean, outLoudLater: Boolean): Boolean = quiet && outLoudLater

    /**
     * The backup alarm by time (Android: AlarmManager), for when GPS drops out: at the leg's arrival less the time the
     * wake distance takes at a typical speed (a bus 10 m/s, a train 25 m/s), at least 2 minutes before it; never in
     * the past. Null: off, or the leg has no arrival.
     */
    fun backupAt(arrival: Double?, isTrain: Boolean, wakeMetres: Double, now: Double, enabled: Boolean = true): Double? {
        if (!enabled || arrival == null || !arrival.isFinite()) return null
        val speed = if (isTrain) 25.0 else 10.0
        val lead = max(120.0, wakeMetres / speed)
        val at = arrival - lead
        return if (at > now + 30) at else null
    }

    /** "Breda in about 1.8 km", for the alarm and the notification. */
    fun distanceText(metres: Double): String =
        if (metres >= 1000) String.format(java.util.Locale.ROOT, "%.1f km", metres / 1000) else "${(metres / 10).roundToInt() * 10} m"

    fun announcement(place: String, isTrain: Boolean, approach: Boolean): String {
        val spoken = if (isTrain && !place.contains("station", true) && !place.contains("Centraal")) "$place station" else place
        val veh = if (isTrain) "train" else "bus"
        return if (approach) "Attention please. We are now approaching $spoken. Please get ready to leave the $veh."
        else "Arriving at $spoken. This is your stop. Please leave the $veh here."
    }
}

/**
 * Rough GPS on long rides (iOS `RideGPS`, 0.20.7): far from the stop (the wake distance plus 8 minutes at full speed,
 * and a kilometre more to switch it on) with the vehicle confirmed and the stop not due within 10 minutes, the ride
 * asks for a fix every 25 s instead of every 2 s. Anything else: the best, at once.
 */
object RideGPS {
    const val BUS_CRUISE = 25.0
    const val TRAIN_CRUISE = 39.0
    const val TRAVEL = 8 * 60.0
    const val HYSTERESIS = 1000.0
    const val DUE_SOON = 10 * 60.0
    const val FRESH_FIX = 300.0
    const val GOOD_ACCURACY = 100.0

    data class Input(
        val enabled: Boolean = true,
        val asleep: Boolean = true,
        val confirmed: Boolean = false,
        val metresToStop: Double? = null,
        val accuracy: Double? = null,
        val fixAge: Double? = null,
        val wakeMetres: Double,
        val isTrain: Boolean,
        val speed: Double? = null,
        val secondsToStop: Double? = null,
        val wasFar: Boolean = false,
    )

    fun farFrom(wakeMetres: Double, isTrain: Boolean, speed: Double?): Double {
        val cruise = if (isTrain) TRAIN_CRUISE else BUS_CRUISE
        val v = max(cruise, speed?.takeIf { it.isFinite() } ?: 0.0)
        return max(0.0, wakeMetres) + v * TRAVEL
    }

    fun far(i: Input): Boolean {
        if (!i.enabled || !i.asleep || !i.confirmed) return false
        val d = i.metresToStop ?: return false
        if (!d.isFinite() || d < 0) return false
        val a = i.accuracy ?: return false
        if (!a.isFinite() || a < 0 || a >= GOOD_ACCURACY) return false
        val age = i.fixAge ?: return false
        if (!age.isFinite() || age < 0 || age > FRESH_FIX) return false
        if (!i.wakeMetres.isFinite() || i.wakeMetres < 0) return false
        i.secondsToStop?.let { if (!(it.isFinite() && it > DUE_SOON)) return false }
        return d > farFrom(i.wakeMetres, i.isTrain, i.speed) + (if (i.wasFar) 0.0 else HYSTERESIS)
    }

    /** Milliseconds between fixes asked for: far, 25 s (and 75 m); else 2 s. */
    fun intervalMs(far: Boolean): Long = if (far) 25_000 else 2_000
}
