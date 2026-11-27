package nl.haltewekker.ride

import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint

/**
 * (0.9.1, iOS 0.42.3 `TripManager.handle` with `ShortLeg`) what one fix, one dead-reckoned step or one look on your
 * road does to a leg's alarm. Pure, so the ring path is tested on whole leg sequences (`LegAlarmTest`); the ride
 * (`RideService`) applies what it says.
 *
 * - Asleep, the wake rule firing on a good fix: a short leg (`ShortLeg.isShort`) wakes quietly (no alarm, a quiet
 *   "Get off at the next stop" later); within 20 s of the leg's start any leg wakes quietly (it started inside its
 *   wake distance); from 20 to 60 s it holds; after that a normal leg always rings.
 * - Awake and within 450 m: you're there, but a quiet leg only after its first minute and within half the way it
 *   started from (200–450 m, `ShortLeg.mayArrive`).
 * - Dead reckoning: nothing in the first minute; a short leg wakes quietly; else it rings.
 */
object LegAlarm {
    /** The leg as the alarm sees it: its phase, awake without the alarm (`quiet`), the quiet word told, how far it started. */
    data class Leg(val phase: Phase = Phase.SLEEPING, val quiet: Boolean = false, val told: Boolean = false, val startedMetres: Double? = null)

    enum class Do { NOTHING, RING, WAKE_SHORT, WAKE_EARLY, HOLD, ARRIVE, NOT_YET, NOTICE }

    data class Step(val leg: Leg, val act: Do)

    /** The straight distance from where a leg starts to its stop (iOS `legSpan`). */
    fun span(from: GeoPoint?, to: GeoPoint?): Double? = if (from != null && to != null) Geo.metres(from, to) else null

    /**
     * One fix: `legAge` seconds into the leg, `metres` to its stop, its `accuracy`; `fired`: the wake rule fires on it
     * (asked only for a good fix while asleep); `short`: the leg is shorter than its wake distance (or 800 m).
     */
    fun fix(l: Leg, legAge: Double, metres: Double, accuracy: Double, fired: Boolean, short: Boolean): Step {
        if (!metres.isFinite() || metres < 0 || !accuracy.isFinite() || accuracy < 0) return Step(l, Do.NOTHING)
        val good = accuracy < WakeRules.GOOD_ACCURACY
        val leg = if (good && l.startedMetres == null) l.copy(startedMetres = metres) else l
        when (leg.phase) {
            Phase.SLEEPING -> if (good && fired) return when (ShortLeg.onFire(legAge, short)) {
                ShortLeg.OnFire.QUIET -> Step(leg.copy(phase = Phase.AWAKE, quiet = true), if (short) Do.WAKE_SHORT else Do.WAKE_EARLY)
                ShortLeg.OnFire.WAIT -> Step(leg, Do.HOLD)
                ShortLeg.OnFire.RING -> Step(leg.copy(phase = Phase.ALARM), Do.RING)
            }
            Phase.AWAKE -> if (metres <= WakeRules.ARRIVE_M && accuracy <= WakeRules.ARRIVE_ACCURACY) {
                return if (leg.quiet && !ShortLeg.mayArrive(legAge, metres, leg.startedMetres)) Step(leg, Do.NOT_YET) else Step(leg, Do.ARRIVE)
            }
            else -> {}
        }
        return Step(leg, Do.NOTHING)
    }

    /** One dead-reckoned step (no good GPS): `fired` = the time rule fires and may ring on a reckoned place (`DeadReckon.mayRing`). */
    fun reckoned(l: Leg, legAge: Double, fired: Boolean, short: Boolean): Step {
        if (l.phase != Phase.SLEEPING || legAge < ShortLeg.NO_RING_FOR || !fired) return Step(l, Do.NOTHING)
        return if (short) Step(l.copy(phase = Phase.AWAKE, quiet = true), Do.WAKE_SHORT) else Step(l.copy(phase = Phase.ALARM), Do.RING)
    }

    /**
     * A quiet leg's "Get off at the next stop" (iOS `checkShortNotice`): once a leg, not in its first minute, when the
     * stop before yours is reached by its times, 90 s before it's in, or (no times) halfway from where it started.
     */
    fun notice(l: Leg, legAge: Double, beforeReached: Boolean, secondsLeft: Double?, metres: Double?): Step {
        if (l.phase != Phase.AWAKE || !l.quiet) return Step(l, Do.NOTHING)
        if (!ShortLeg.noticeDue(legAge, l.told, beforeReached, secondsLeft, metres, l.startedMetres)) return Step(l, Do.NOTHING)
        return Step(l.copy(told = true), Do.NOTICE)
    }

    /** The stop before yours reached by its times (iOS: its arrival less `GetReady.EARLY`). */
    fun beforeReached(beforeAt: Double?, now: Double): Boolean = beforeAt != null && now >= beforeAt - GetReady.EARLY

    /** What a look at the vehicles on your road (going away from this leg's stop) finds (iOS `wrongWay`'s first checks). */
    sealed class Road {
        /** The one you're on is on this road after all: carry on (and look again after another stretch). */
        data object CarryOn : Road()
        /** On the ride the next leg was planned with: this leg is done, the next one starts on it. */
        data class NextLeg(val tripId: String) : Road()
        /** Neither: Android has no "wrong way" plan again, so it looks again after another stretch. */
        data object Nothing : Road()
    }

    fun onRoad(found: List<String>, current: String?, plannedNext: String?, thisLeg: String?): Road {
        if (current != null && current in found) return Road.CarryOn
        if (plannedNext != null && plannedNext == thisLeg) return Road.Nothing
        return NextLegGuard.plannedNextAmong(found, plannedNext)?.let { Road.NextLeg(it) } ?: Road.Nothing
    }

    /** Going away from this leg's stop (iOS `handle`): further than you've been, by 800 m near it (within 3 km), else 2 km. */
    fun goingAway(closest: Double?, metres: Double): Boolean {
        val c = closest ?: return false
        return metres > c + (if (c < 3000) 800.0 else 2000.0)
    }

    /** A fix that says you're moving like a vehicle (iOS `LiveStore.movingFix`): 5 m/s or more, 100 m or better. */
    fun moving(speed: Double, accuracy: Double): Boolean = speed.isFinite() && speed >= 5 && accuracy >= 0 && accuracy <= 100
}
