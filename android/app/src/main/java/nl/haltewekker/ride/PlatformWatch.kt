package nl.haltewekker.ride

import android.content.Context
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import nl.haltewekker.data.DoorTrip
import nl.haltewekker.data.Net
import nl.haltewekker.data.Ride
import java.time.OffsetDateTime
import java.time.format.DateTimeFormatter

/**
 * (0.10.1) Your trains' platforms and cancellations, for every train of the trip that runs (iOS `WatchStore`, with what
 * 0.42.4 fixed there): each train leg still ahead (and the one you wait for, also at a change) whose departure is within
 * 3 hours, seeded with the planner's planned platform so a change before NS's first answer still counts, looked at on
 * NS's board (relay `/ns/departures`) at most once a minute. A change is told at once, quietly while the ride sleeps
 * (with sound when you're awake), and the trip's ride gets the new platform (the change card, the ride's notification).
 */
object PlatformWatch {
    const val AHEAD = 3 * 3600.0
    const val EVERY = 55.0

    @Serializable
    data class Watch(val key: String, val code: String, val num: String, val planned: Double, val label: String, val from: String,
                     val track: String, val cancelled: Boolean = false, val leg: Int)

    data class Dep(val num: String, val planned: Double?, val plannedTrack: String, val actualTrack: String, val cancelled: Boolean)

    data class Alert(val key: String, val cancelled: Boolean, val title: String, val body: String, val leg: Int, val track: String?)

    fun key(code: String, r: Ride) = "$code|${r.num}|${r.scheduledDeparture.toLong()}"

    /**
     * Which legs to watch: every train ride from the one you're on or waiting for, not boarded yet (`boarded`: the
     * current leg's vehicle is found), leaving within 3 hours and not more than 20 minutes ago, from an NS station.
     */
    fun legs(trip: DoorTrip, index: Int, boarded: Boolean, now: Double, code: (Ride) -> String?): List<Pair<Int, String>> =
        trip.rides.withIndex().mapNotNull { (k, r) ->
            if (!r.isTrain || k < index || (k == index && boarded)) return@mapNotNull null
            if (r.departure - now > AHEAD || now - r.departure > 20 * 60) return@mapNotNull null
            code(r)?.let { k to it }
        }

    /** A new watch for a train leg: the planner's platform to start from. */
    fun seed(r: Ride, leg: Int, code: String, label: String): Watch =
        Watch(key(code, r), code, r.num, r.scheduledDeparture, label, r.fromStop, (r.platform ?: r.plannedPlatform ?: "").trim(), r.cancelled, leg)

    /** "08:02 Intercity to Breda" */
    fun label(r: Ride, hhmm: (Double) -> String): String {
        val what = r.name.ifEmpty { r.line }.ifEmpty { "train" }
        val to = r.headsign.ifEmpty { r.toStop }
        return "${hhmm(r.scheduledDeparture)} $what to $to"
    }

    /** NS's board: the train by its number, else by its planned time (within a minute). */
    fun match(list: List<Dep>, num: String, planned: Double): Dep? =
        if (num.isNotEmpty()) list.firstOrNull { it.num == num } else list.firstOrNull { d -> d.planned?.let { kotlin.math.abs(it - planned) < 60 } ?: false }

    /** Is this a change to tell: the watch as it is now, and what to say (null: nothing new). */
    fun look(w: Watch, d: Dep): Pair<Watch, Alert?> {
        if (d.cancelled && !w.cancelled) {
            return w.copy(cancelled = true) to Alert(w.key, true, "Train cancelled", "Your ${w.label} from ${w.from} has been cancelled.", w.leg, null)
        }
        val tr = d.actualTrack.ifEmpty { d.plannedTrack }.trim()
        if (tr.isEmpty() || d.cancelled) return w to null
        if (w.track.isEmpty()) return w.copy(track = tr) to null
        if (tr == w.track) return w to null
        return w.copy(track = tr) to Alert(w.key, false, "Platform $tr", "Your ${w.label} now leaves ${w.from} from platform $tr instead of ${w.track}.", w.leg, tr)
    }

    private val nsTime = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ssZ")
    private fun time(s: String?): Double? = s?.let {
        try { OffsetDateTime.parse(it, nsTime).toEpochSecond().toDouble() } catch (_: Exception) {
            try { OffsetDateTime.parse(it).toEpochSecond().toDouble() } catch (_: Exception) { null } }
    }

    /** NS's departures answer (`payload.departures`). */
    fun parse(text: String?): List<Dep>? {
        val o = try { Json.parseToJsonElement(text ?: return null) as? JsonObject } catch (_: Exception) { null } ?: return null
        val deps = (o["payload"] as? JsonObject)?.get("departures") as? JsonArray ?: return emptyList()
        fun JsonObject.s(k: String) = (this[k] as? JsonPrimitive)?.content ?: ""
        return deps.mapNotNull { e ->
            val x = e as? JsonObject ?: return@mapNotNull null
            Dep((x["product"] as? JsonObject)?.s("number") ?: "", time(x.s("plannedDateTime").ifEmpty { null }), x.s("plannedTrack"), x.s("actualTrack"),
                x.s("cancelled") == "true")
        }
    }

    // MARK: the watch that runs (kept with the ride; gone when it ends)

    private var watches: List<Watch> = emptyList()
    private var lastLook = 0.0
    private var forTrip = 0.0
    private var looking = false

    /**
     * The ride's tick: at most once a minute, NS's board for each station a watched train leaves from; what changed is
     * told (`tell`) and put on the trip (`apply`: the leg and its new platform, or null when it's cancelled).
     */
    suspend fun tick(s: RideState, now: Double, code: (Ride) -> String?, hhmm: (Double) -> String, tell: (Alert) -> Unit) {
        if (looking || now - lastLook < EVERY) return
        if (forTrip != s.startedAt) { watches = emptyList(); forTrip = s.startedAt }
        val want = legs(s.trip, s.index, s.vehicleTripId != null, now, code)
        watches = want.map { (k, c) ->
            val r = s.trip.rides[k]
            watches.firstOrNull { it.key == key(c, r) } ?: seed(r, k, c, label(r, hhmm))
        }
        if (watches.isEmpty()) return
        lastLook = now
        looking = true
        try {
            val boards = HashMap<String, List<Dep>>()
            for (c in watches.map { it.code }.distinct()) {
                val a = Net.get(nl.haltewekker.friends.FriendRelay.BASE + "/ns/departures", listOf("station" to c))
                if (a.status == 200) parse(a.text)?.let { boards[c] = it }
            }
            watches = watches.map { w ->
                val d = boards[w.code]?.let { match(it, w.num, w.planned) } ?: return@map w
                val (nw, alert) = look(w, d)
                alert?.let(tell)
                nw
            }
        } finally { looking = false }
    }

    fun clear() { watches = emptyList(); lastLook = 0.0; forTrip = 0.0 }

    /** The trip with the new platform on its leg (the change card and the ride's notification show it). */
    fun applied(trip: DoorTrip, a: Alert): DoorTrip {
        val r = trip.rides.getOrNull(a.leg) ?: return trip
        val nr = if (a.cancelled) r.copy(cancelled = true) else r.copy(platform = a.track)
        return trip.copy(rides = trip.rides.toMutableList().also { it[a.leg] = nr })
    }

    /** Posted at once: quiet while the ride sleeps, with sound when you're awake. */
    fun post(c: Context, a: Alert, quiet: Boolean) = Notifications.platform(c, "platform-${a.key}", a.title, a.body, quiet)
}
