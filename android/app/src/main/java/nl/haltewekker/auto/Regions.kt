package nl.haltewekker.auto

import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.location.LocationManager
import android.net.Uri
import android.app.PendingIntent
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import nl.haltewekker.App
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.core.Iso
import nl.haltewekker.ride.RideService
import nl.haltewekker.ride.RideStore
import nl.haltewekker.ui.screens.Perms
import java.time.LocalDate

/**
 * The circles the phone watches for auto-start and auto-home (iOS region monitoring), with the platform's own
 * proximity alerts (`LocationManager.addProximityAlert`: no Google Play services). Android checks them with its own
 * low-power location; only on leaving one does the app switch GPS on (`RideService`'s look). They need location "all
 * the time"; without it nothing is watched. Set again after a restart and whenever your places or the switches change.
 */
object Regions {
    private const val KEY = "auto.regions"
    private const val MAX = 6
    private val json = Json { ignoreUnknownKeys = true }

    @Serializable private data class Stored(val id: String, val lat: Double, val lon: Double, val radius: Double, val entry: Boolean, val exit: Boolean)

    private fun pi(c: Context, i: Int, id: String, flags: Int): PendingIntent? = PendingIntent.getBroadcast(c, 300 + i,
        Intent(c, RegionReceiver::class.java).setAction(ACTION).setData(Uri.parse("hw-region:$id")),
        flags or PendingIntent.FLAG_MUTABLE)                // mutable: Android adds whether you entered or left

    const val ACTION = "nl.haltewekker.auto.REGION"

    /** The regions watched now (as last set). */
    fun current(c: Context): List<RegionSpec> = ((c.applicationContext as App).store.getString(KEY)?.let {
        try { json.decodeFromString(ListSerializer(Stored.serializer()), it) } catch (_: Exception) { null }
    } ?: emptyList()).map { RegionSpec(it.id, it.lat, it.lon, it.radius, it.entry, it.exit) }

    /** The regions your places and switches want (whether or not Android lets them be watched). */
    fun wanted(c: Context): List<RegionSpec> {
        val app = c.applicationContext as App
        val p = app.store.profile.value
        val s = app.store.settings.value
        if (!p.setupDone) return emptyList()
        val base = base(c)
        val school = p.school?.point
        // (A4) "Show friends when I'm at school": School's region tells on leaving too (it never starts a trip by itself)
        return if (school != null && app.store.prefs.getBoolean(nl.haltewekker.friends.FriendExtrasStore.CAMPUS_REGION_KEY, false))
            AutoRules.withCampus(base, school) else base
    }

    /** The regions the trips by themselves want (without "at school"). */
    fun base(c: Context): List<RegionSpec> {
        val app = c.applicationContext as App
        val p = app.store.profile.value
        val s = app.store.settings.value
        if (!p.setupDone) return emptyList()
        return AutoRules.wanted(p.home?.point, p.school?.point, p.homeStops.map { GeoPoint(it.lat, it.lon) }, s.autoStart, s.autoHome)
    }

    @SuppressLint("MissingPermission")
    fun update(c: Context) {
        val app = c.applicationContext as App
        val lm = c.getSystemService(LocationManager::class.java) ?: return
        val old = current(c)
        old.forEachIndexed { i, r -> pi(c, i, r.id, PendingIntent.FLAG_NO_CREATE)?.let { try { lm.removeProximityAlert(it) } catch (_: Exception) {}; it.cancel() } }
        val want = if (Perms.location(c) && Perms.background(c)) wanted(c).take(MAX) else emptyList()
        val set = ArrayList<RegionSpec>()
        want.forEachIndexed { i, r ->
            val p = pi(c, i, r.id, PendingIntent.FLAG_UPDATE_CURRENT) ?: return@forEachIndexed
            try { lm.addProximityAlert(r.lat, r.lon, r.radius.toFloat(), -1, p); set.add(r) } catch (_: Exception) {}
        }
        app.store.putString(KEY, json.encodeToString(ListSerializer(Stored.serializer()), set.map { Stored(it.id, it.lat, it.lon, it.radius, it.entry, it.exit) }))
    }
}

/** A proximity alert: you entered or left one of the circles. */
class RegionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Regions.ACTION) return
        val id = intent.data?.schemeSpecificPart ?: return
        val entering = intent.getBooleanExtra(LocationManager.KEY_PROXIMITY_ENTERING, false)
        AutoStart.onRegion(context, id, entering)
    }
}

/** What leaving or reaching a place does (iOS `TripManager.leftRegion`, `maybeAutoHome`). */
object AutoStart {
    const val KEY_LAST_END = "auto.lastEnd"
    const val KEY_BLOCKED = "auto.blocked"
    const val KEY_HOME_DAY = "auto.homeDay"
    const val KEY_DIRECTION = "auto.direction"          // "HOME|<time>": auto-home switched the next trip
    private val json = Json { ignoreUnknownKeys = true }

    private fun store(c: Context) = (c.applicationContext as App).store

    fun onRegion(c: Context, id: String, entering: Boolean) {
        val s = store(c).settings.value
        val role = AutoRules.role(id) ?: return
        val spec = Regions.current(c).firstOrNull { it.id == id } ?: return
        // (A4) the friends extras hear it first: at school (campus), leaving home (the wake-up buddy)
        try { nl.haltewekker.friends.FriendStore.init(c); nl.haltewekker.friends.FriendExtrasStore.region(id, entering) } catch (_: Exception) {}
        // (iOS 0.42.6) and the school alarm: left home, or at school (no wake-up when you're already going)
        try { nl.haltewekker.school.SchoolAlarm.region(c, home = role == AutoRules.Role.HOME, entering = entering) } catch (_: Exception) {}
        if (entering) {
            if (role == AutoRules.Role.SCHOOL && spec.entry && s.autoHome && RideStore.state.value == null) {
                val today = LocalDate.now().toString()
                if (store(c).getString(KEY_HOME_DAY) == today) return
                store(c).putString(KEY_HOME_DAY, today)
                store(c).putString(KEY_DIRECTION, "HOME|${Iso.now()}")
            }
            return
        }
        if (!spec.exit || !s.autoStart || !AutoRules.exitStartsTrip(id, Regions.base(c))) return
        RideStore.load(c)
        if (RideStore.state.value != null) return
        val (place, at) = lastEnd(c)
        val speed = nl.haltewekker.ui.Locator.lastFix(c)?.takeIf { Iso.now() - it.time / 1000.0 < 60 && it.hasSpeed() }?.speed?.toDouble()
        if (AutoRules.skip(id, place, at, speed, Iso.now())) return
        RideService.look(c, id)
    }

    /** Where and when the last ride ended (a region's id). */
    fun lastEnd(c: Context): Pair<String?, Double?> {
        val v = store(c).getString(KEY_LAST_END)?.split('|') ?: return null to null
        return v.getOrNull(0) to v.getOrNull(1)?.toDoubleOrNull()
    }

    fun noteEnd(c: Context, at: GeoPoint?) {
        val p = at ?: return
        val id = AutoRules.regionAt(p, Regions.current(c).ifEmpty { Regions.wanted(c) }) ?: return
        store(c).putString(KEY_LAST_END, "$id|${Iso.now()}")
    }

    /** The trips you ended by hand (not started again by themselves for two hours). */
    fun blocked(c: Context): Map<String, Double> {
        val m = store(c).getString(KEY_BLOCKED)?.let { try { json.decodeFromString<Map<String, Double>>(it) } catch (_: Exception) { null } } ?: emptyMap()
        return AutoRules.prune(m, Iso.now())
    }

    fun block(c: Context, ids: Collection<String>) {
        if (ids.isEmpty()) return
        val m = blocked(c).toMutableMap()
        for (i in ids) m[i] = Iso.now()
        store(c).putString(KEY_BLOCKED, json.encodeToString(MapSerializer(String.serializer(), Double.serializer()), m))
    }

    /** Auto-home switched the next trip to home (taken once by the home screen). */
    fun takeDirection(c: Context): Double? {
        val v = store(c).getString(KEY_DIRECTION) ?: return null
        store(c).putString(KEY_DIRECTION, null)
        return v.substringAfter('|').toDoubleOrNull()
    }
}
