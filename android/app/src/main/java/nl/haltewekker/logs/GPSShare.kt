package nl.haltewekker.logs

import kotlinx.serialization.Serializable
import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.friends.FriendJson
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

// (A6, iOS 0.32 `GPSShare.swift`) Help improve Haltewekker › Share GPS points during rides (off unless turned on).
// While a trip runs, a GPS point every few seconds is kept on the phone; when the trip ends the first and last 500 m go,
// and every point near your places. What's left goes with the ride-log uploads. Pure, so every rule can be tested.

/** Who makes the app, and so who gets what's shared (one place for the name). */
object Maker { const val NAME = "Nana" }

/** One GPS point as it leaves the phone (docs/logs-export.md › GPS points). */
@Serializable
data class SharedFix(
    val t: Double, val lat: Double, val lon: Double, val acc: Double, val spd: Double, val crs: Double,
    val leg: String? = null, val veh: String? = null, val ride: String? = null,
) {
    val point: GeoPoint get() = GeoPoint(lat, lon)
}

@Serializable
data class GPSShareRide(val ride: String, val fixes: List<SharedFix> = emptyList())

/** What's kept on the phone between uploads: the trip that's running and the trimmed points waiting to go. */
@Serializable
data class GPSShareQueue(val current: GPSShareRide? = null, val ready: List<SharedFix> = emptyList()) {
    /** A fix heard while a trip runs: into the trip's points, every few seconds, up to `MAX_RIDE`. */
    fun heard(f: SharedFix, newRide: () -> String): GPSShareQueue {
        val r = current ?: GPSShareRide(newRide())
        if (r.fixes.size >= GPSShareRules.MAX_RIDE || !GPSShareRules.keep(f, r.fixes.lastOrNull())) return copy(current = r)
        return copy(current = r.copy(fixes = r.fixes + f.copy(ride = r.ride)))
    }

    /** The trip ended: its points trimmed join those waiting; the oldest go past `MAX_READY`. */
    fun finishRide(zones: List<GeoPoint>): GPSShareQueue {
        val r = current ?: return this
        val all = ready + GPSShareRules.finished(r, zones)
        return GPSShareQueue(null, if (all.size > GPSShareRules.MAX_READY) all.drop(all.size - GPSShareRules.MAX_READY) else all)
    }

    fun sent(n: Int) = copy(ready = ready.drop(min(max(0, n), ready.size)))

    companion object {
        fun decode(text: String?): GPSShareQueue = text?.let { FriendJson.decode(serializer(), it) } ?: GPSShareQueue()
        fun encode(q: GPSShareQueue): String = FriendJson.encodeString(serializer(), q)
    }
}

object GPSShareRules {
    const val EVERY = 3.0
    const val MAX_ACCURACY = 150.0
    const val TRIM_ENDS = 500.0
    const val ZONE_RADIUS = 500.0
    const val MAX_RIDE = 6000
    const val MAX_READY = 20000
    const val PER_UPLOAD = 600 * 1024
    const val PER_DAY = 4 * 1024 * 1024
    const val MAX_TAG = 40

    /** Swift's `rounded()`: half away from zero. */
    fun round(x: Double, digits: Int): Double {
        val k = 10.0.pow(digits)
        val r = floor(abs(x) * k + 0.5) / k
        return if (x < 0) -r else r
    }

    private const val ALLOWED = " ·.+/_'()?-"

    /** A vehicle tag the relay takes: letters, digits, spaces and `·.+/_'()?-`, at most 40 characters. */
    fun tag(s: String?): String? {
        s ?: return null
        val clean = buildString {
            var i = 0
            while (i < s.length) {
                val cp = s.codePointAt(i)
                if (Character.isLetter(cp) || Character.isDigit(cp) || (cp < 0x10000 && ALLOWED.indexOf(cp.toChar()) >= 0)) appendCodePoint(cp) else append('-')
                i += Character.charCount(cp)
            }
        }.take(MAX_TAG).trim(' ')
        return clean.ifEmpty { null }
    }

    fun fix(at: Double, lat: Double, lon: Double, accuracy: Double, speed: Double, course: Double,
            leg: String?, vehicle: String?, ride: String?): SharedFix? {
        if (!lat.isFinite() || !lon.isFinite() || abs(lat) > 90 || abs(lon) > 180 || (lat == 0.0 && lon == 0.0)) return null
        if (!accuracy.isFinite() || accuracy < 0 || accuracy > MAX_ACCURACY) return null
        if (!at.isFinite() || at <= 1.5e9) return null
        return SharedFix(round(at, 1), round(lat, 5), round(lon, 5), round(accuracy, 0),
            if (speed.isFinite() && speed >= 0) round(min(speed, 200.0), 1) else -1.0,
            if (course.isFinite() && course >= 0) round(min(course, 360.0), 0) else -1.0,
            leg, tag(vehicle), ride)
    }

    fun leg(index: Int, count: Int): String? = if (count <= 0 || index < 0) null else "${min(index, count - 1) + 1}/$count"

    fun keep(f: SharedFix, after: SharedFix?): Boolean {
        after ?: return true
        val gap = f.t - after.t
        return gap < 0 || gap >= EVERY - 0.05
    }

    fun trimmed(fixes: List<SharedFix>, ends: Double = TRIM_ENDS): List<SharedFix> {
        val sorted = fixes.sortedBy { it.t }
        val first = sorted.firstOrNull() ?: return emptyList()
        val last = sorted.last()
        val along = DoubleArray(sorted.size)
        for (i in 1 until sorted.size) along[i] = along[i - 1] + Geo.metres(sorted[i - 1].point, sorted[i].point)
        val total = along.lastOrNull() ?: 0.0
        return sorted.indices.filter { i ->
            along[i] >= ends && total - along[i] >= ends &&
                Geo.metres(sorted[i].point, first.point) > ends && Geo.metres(sorted[i].point, last.point) > ends
        }.map { sorted[it] }
    }

    fun outsideZones(fixes: List<SharedFix>, zones: List<GeoPoint>, radius: Double = ZONE_RADIUS): List<SharedFix> {
        val real = zones.filter { it.lat.isFinite() && it.lon.isFinite() && !(it.lat == 0.0 && it.lon == 0.0) }
        return fixes.filter { f -> real.none { Geo.metres(it, f.point) <= radius } }
    }

    fun finished(ride: GPSShareRide, zones: List<GeoPoint>) = outsideZones(trimmed(ride.fixes), zones)

    fun size(f: SharedFix): Int = FriendJson.encode(SharedFix.serializer(), f).size + 1

    data class Batch(val fixes: List<SharedFix>, val bytes: Int, val more: Boolean)

    fun batch(ready: List<SharedFix>, budget: Int): Batch {
        val out = ArrayList<SharedFix>()
        var bytes = 0
        val limit = max(0, budget)
        for (f in ready) {
            val s = size(f)
            if (bytes + s > limit) return Batch(out, bytes, true)
            out.add(f); bytes += s
        }
        return Batch(out, bytes, false)
    }

    fun budget(s: LogShareState, today: String): Int {
        val used = if (s.day == today) (s.fixBytesToday ?: 0) else 0
        return max(0, min(PER_UPLOAD, PER_DAY - used))
    }

    fun rideId(random: (Int) -> ByteArray = LogShareState::randomBytes): String = LogShareState.hex(random(4))
}

/** The question "Help improve Haltewekker" (iOS `ShareAsk`): the setup's step and a one-time card. */
object ShareAsk {
    const val ASKED_KEY = "share.asked.v1"

    fun showCard(setupDone: Boolean, asked: Boolean, testLive: Boolean) = setupDone && !asked && !testLive

    val intro = "Haltewekker is made by ${Maker.NAME}. If you like, this phone sends ${Maker.NAME} a little about your rides, so the app picks the right bus or train more often. It’s optional: both are off unless you turn them on, and you can change it any time in Settings › Help improve Haltewekker."
    const val LOGS_TITLE = "Share ride logs"
    const val LOGS_TEXT = "After each trip: how the app picked your bus or train and how the ride went (line numbers, distances in metres, what it decided). Never your places’ names, your friends or your account."
    const val FIXES_TITLE = "Share GPS points during rides"
    const val FIXES_TEXT = "Only while a trip runs: where the phone was every few seconds (time, place to about a metre, accuracy, speed and direction), with the leg and the bus or train it was on. The first and last 500 m of every trip are left out, and so is anything within 500 m of Home, School or another place you saved."
    const val SAMPLE_FIX = """{"t":1795070038.2,"lat":51.69012,"lon":5.29871,"acc":8,"spd":12.4,"crs":87,"leg":"1/3","veh":"bus 305·7821","ride":"3f9a1c2e"}"""
    val who = "It goes to ${Maker.NAME} only, under a random id made for this (not your Friends account), and is deleted after 60 days. Not during a trip, with Data Saver on a metered network or in battery saver. “Delete what I sent” in Settings › Help improve Haltewekker deletes it all at once."

    /** The setup's summary row. */
    fun words(logs: Boolean, fixes: Boolean) = when {
        logs && fixes -> "Ride logs and GPS points during rides"
        logs -> "Ride logs"
        fixes -> "GPS points during rides"
        else -> "Nothing shared"
    }
}
