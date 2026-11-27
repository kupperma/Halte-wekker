package nl.haltewekker.ride

import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.data.DoorTrip

/**
 * (0.10.3, iOS 0.42.4 "the look belongs to the watching, not to a screen") Fastest trip's watching, as plain state:
 * it starts when Fastest trip has a way to watch, and from then on the look at what you get on runs in `RideService`
 * (a foreground service with location, started while the app is in front) whatever is on screen: the cards, the stops
 * around you, the walk, another screen, the home screen of the phone, the phone locked. It stops when you go back from
 * Fastest trip, a trip starts (by itself or "I'm on it"), you're there, the way it watched first left 20 minutes ago
 * and you didn't move, or after 3 hours. Tested in `WaitWatchTest`.
 */
object WaitWatch {
    const val MAX_HOURS = 3.0
    /** s between looks: every 6 s… */
    const val EVERY = 6.0
    /** …for the first 3 minutes at bus speed (and while one is on its way to starting); after that `BACKOFF`. */
    const val QUICK_FOR = 180.0
    /** s: iOS `LookBackoff.steps` (the looks in a row that saw the same best). */
    val BACKOFF = listOf(4.0, 8.0, 15.0, 30.0)
    /** iOS `GoPace.missedAfter` / `movedEnough`. */
    const val MISSED_AFTER = 20 * 60.0
    const val MOVED_ENOUGH = 300.0
    /** m: you're there (iOS: within 400 m of the destination, a fix better than 200 m). */
    const val THERE = 400.0

    /** What Fastest trip watches: where to, and the ways on screen (the one it watches first). */
    data class Request(val destName: String, val destId: String, val dest: GeoPoint, val ways: List<DoorTrip>) {
        val watched: DoorTrip? get() = ways.firstOrNull()
    }

    data class State(
        val watching: Boolean = false,
        val since: Double = 0.0,
        val watchedFirst: Double? = null,        // the departure it watched first
        val openedFrom: GeoPoint? = null,
        val movedMax: Double = 0.0,
        val fastSince: Double? = null,           // at bus speed since (the pace of the looks)
        val sameLooks: Int = 0,                  // looks in a row with the same best (the back-off)
        val sameKey: String? = null,
        val logged: Pair<String, Double>? = null, // the last look's call in the field log, and when
        val wait: WaitStart.State = WaitStart.State(),
    )

    /** It begins (or begins again, for another destination): the state and the log line. */
    fun begin(s: State, now: Double, inFront: Boolean, watchedFirst: Double?): Pair<State, String> =
        State(watching = true, since = now, watchedFirst = watchedFirst) to WaitStart.onLine(again = s.watching, inFront = inFront)

    /** It stops, and why: the log line only when it was watching. */
    fun end(s: State, why: String): Pair<State, String?> = State() to (if (s.watching) WaitStart.offLine(why) else null)

    /** A fix (≤ 200 m): how far you've been from where it began. */
    fun moved(s: State, p: GeoPoint, accuracy: Double): State {
        if (accuracy < 0 || accuracy >= 200) return s
        val o = s.openedFrom ?: return s.copy(openedFrom = p)
        return s.copy(movedMax = maxOf(s.movedMax, Geo.metres(o, p)))
    }

    /** It stops by itself (the reason), else null. Nothing about the screen. */
    fun autoStop(s: State, here: GeoPoint?, accuracy: Double, dest: GeoPoint?, now: Double): String? {
        if (!s.watching) return null
        if (now - s.since > MAX_HOURS * 3600) return "after ${MAX_HOURS.toInt()} hours"
        val w = s.watchedFirst
        if (w != null && now - w >= MISSED_AFTER && s.movedMax < MOVED_ENOUGH) return "the trip you waited for has gone"
        if (here != null && dest != null && accuracy >= 0 && accuracy < 200 && Geo.metres(here, dest) < THERE) return "you're there"
        return null
    }

    /** One look's pace: at bus speed since (kept while any step was at speed), and the back-off's count by what it saw. */
    fun paced(s: State, fast: Boolean, moving: WaitStart.Moving, key: String?, now: Double): State {
        val since = if (fast) (s.fastSince ?: now) else if (moving.seconds <= 0) null else s.fastSince
        val same = if (key != null && key == s.sameKey) s.sameLooks + 1 else 1
        return s.copy(fastSince = since, sameLooks = same, sameKey = key)
    }

    /** s to the next look: 6, after 3 minutes at bus speed with nothing on its way to starting 4/8/15/30 (never under 6). */
    fun nextLook(s: State, fast: Boolean, progress: Int, now: Double): Double {
        val early = s.fastSince?.let { now - it < QUICK_FOR } ?: true
        if (!fast || early || progress > 0) return EVERY
        return maxOf(EVERY, BACKOFF[(s.sameLooks - 1).coerceIn(0, BACKOFF.size - 1)])
    }

    /** Where a ride may take you on to: the destination, and of each way the stop its first ride gets you to and where each later ride leaves. */
    fun targets(r: Request): List<GeoPoint> {
        val out = mutableListOf(r.dest)
        for (t in r.ways) {
            t.first.to?.let { out.add(it) }
            for (ride in t.rides.drop(1)) ride.from?.let { out.add(it) }
        }
        return out
    }

    /** m: a leg whose stop is this near you (450 m and the fix's accuracy, at least 150) would end at once (iOS `RideGuards.startsAtItsStop`). */
    fun atItsStop(metres: Double?, accuracy: Double): Boolean {
        val d = metres ?: return false
        if (!d.isFinite() || d < 0) return false
        val acc = if (accuracy.isFinite() && accuracy > 0) accuracy else 0.0
        return d <= 450 + maxOf(150.0, acc)
    }

    /** The stops around you search only while you're not at bus speed (iOS: the overview closes on the bus). */
    fun nearbySearches(atVehicleSpeed: Boolean): Boolean = !atVehicleSpeed

    /** The way on screen that rides `tripId` (the watched one first). */
    fun wayOn(r: Request?, tripId: String): DoorTrip? = r?.ways?.firstOrNull { it.first.tripId == tripId }

    /** Another line a long way round (more than 30 min later than the watched way) is probably not one you're on. */
    fun longWayRound(watched: DoorTrip?, line: String, end: Double): Boolean {
        val w = watched ?: return false
        return !WaitStart.sameLine(w.first.line, line) && end > w.end + 30 * 60
    }
}

/**
 * (0.10.3) Between Fastest trip and `RideService`: what to watch (the screen puts its ways here and asks the service
 * once), whether it watches, and whether you move at bus speed (the stops around you stop searching then).
 */
object WaitStore {
    private val _request = MutableStateFlow<WaitWatch.Request?>(null)
    val request: StateFlow<WaitWatch.Request?> = _request
    internal val _watching = MutableStateFlow(false)
    val watching: StateFlow<Boolean> = _watching
    internal val _atVehicleSpeed = MutableStateFlow(false)
    val atVehicleSpeed: StateFlow<Boolean> = _atVehicleSpeed
    /** It stopped by itself (you're there, the trip has gone, 3 hours, a trip started): not again until Fastest trip opens again. */
    @Volatile private var stoppedFor: String? = null

    /** Fastest trip opened: it may watch again. */
    fun opened() { stoppedFor = null }

    /** Fastest trip has `r` on screen: watch it (the service starts once; later calls only change what it watches). */
    fun watch(context: Context, r: WaitWatch.Request) {
        if (ContextCompat.checkSelfPermission(context, android.Manifest.permission.ACCESS_FINE_LOCATION) != android.content.pm.PackageManager.PERMISSION_GRANTED &&
            ContextCompat.checkSelfPermission(context, android.Manifest.permission.ACCESS_COARSE_LOCATION) != android.content.pm.PackageManager.PERMISSION_GRANTED) return
        if (r.destId == stoppedFor) return
        val was = _request.value
        _request.value = r
        if (was != null && was.destId == r.destId && _watching.value) return
        try {
            ContextCompat.startForegroundService(context, Intent(context, RideService::class.java).setAction(RideService.ACTION_WATCH))
        } catch (_: Exception) {}
    }

    /** Back from Fastest trip ("closed"), or the notification's Stop watching. */
    fun stop(context: Context, why: String) {
        val was = _request.value != null || _watching.value
        _request.value = null
        if (!was) return
        try { context.startService(Intent(context, RideService::class.java).setAction(RideService.ACTION_UNWATCH).putExtra(RideService.EXTRA_WHAT, why)) } catch (_: Exception) {}
    }

    /** The service let go of it (a trip started, you're there, …). */
    internal fun ended(stopped: String? = null) {
        if (stopped != null) stoppedFor = stopped
        _request.value = null; _watching.value = false; _atVehicleSpeed.value = false
    }
}
