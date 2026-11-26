package nl.haltewekker.auto

import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint

/** A circle the phone watches (a proximity alert): leaving it may start a trip, entering School may switch to home. */
data class RegionSpec(val id: String, val lat: Double, val lon: Double, val radius: Double, val entry: Boolean, val exit: Boolean) {
    val point: GeoPoint get() = GeoPoint(lat, lon)
}

/**
 * The auto-start and auto-home rules (iOS `RoleRegions` off the corridor, `RegionLook`, `TripResume`). Plain values,
 * tested. Leaving a home stop's circle (or School's) looks for the bus or train you're on and starts a door-to-door
 * trip to the other place; reaching School switches the next trip to home, once a day.
 */
object AutoRules {
    const val SCHOOL_ID = "school"
    const val HOME_PREFIX = "home"
    const val HOME_RADIUS = 350.0
    const val SCHOOL_RADIUS = 350.0
    const val MERGE_METRES = 150.0
    const val MAX_STOPS = 3

    /** The regions wanted: School to leave (and to reach, for auto-home), then your home stops to leave (Home itself without stops). */
    fun wanted(home: GeoPoint?, school: GeoPoint?, homeStops: List<GeoPoint>, autoStart: Boolean, autoHome: Boolean): List<RegionSpec> {
        val out = ArrayList<RegionSpec>()
        if (school != null && (autoStart || autoHome)) out.add(RegionSpec(SCHOOL_ID, school.lat, school.lon, SCHOOL_RADIUS, entry = autoHome, exit = autoStart))
        if (autoStart) {
            val stops = merged(homeStops)
            if (stops.isEmpty() && home != null) out.add(RegionSpec(HOME_PREFIX, home.lat, home.lon, HOME_RADIUS, entry = false, exit = true))
            stops.forEachIndexed { i, p -> out.add(RegionSpec("$HOME_PREFIX.$i", p.lat, p.lon, HOME_RADIUS, entry = false, exit = true)) }
        }
        return out
    }

    /** (0.29) "Show friends when I'm at school": School's region also tells on entry and exit (added when it isn't there). */
    fun withCampus(base: List<RegionSpec>, school: GeoPoint, radius: Double = SCHOOL_RADIUS): List<RegionSpec> {
        val i = base.indexOfFirst { it.id == SCHOOL_ID }
        if (i < 0) return base + RegionSpec(SCHOOL_ID, school.lat, school.lon, radius, entry = true, exit = true)
        return base.toMutableList().also { it[i] = it[i].copy(entry = true, exit = true) }
    }

    /** (0.29) Leaving this region is one a trip starts from: not one only "at school" asked for. */
    fun exitStartsTrip(id: String, base: List<RegionSpec>): Boolean = base.any { it.id == id && it.exit }

    /** One stop per spot: a stop within 150 m of one already kept is the same place (at most three). */
    fun merged(stops: List<GeoPoint>): List<GeoPoint> {
        val out = ArrayList<GeoPoint>()
        for (s in stops) {
            if (!s.lat.isFinite() || !s.lon.isFinite() || out.any { Geo.metres(it, s) < MERGE_METRES }) continue
            out.add(s)
            if (out.size == MAX_STOPS) break
        }
        return out
    }

    enum class Role { HOME, SCHOOL }

    fun role(ofRegion: String): Role? = when {
        ofRegion == SCHOOL_ID -> Role.SCHOOL
        ofRegion == HOME_PREFIX || ofRegion.startsWith("$HOME_PREFIX.") -> Role.HOME
        else -> null
    }

    // MARK: right after a ride ended there (iOS RegionLook)

    const val AFTER_ARRIVAL = 20 * 60.0
    const val VEHICLE_SPEED = 5.0

    /** Leaving a place within 20 minutes of a ride ending there is walking away from the bus, unless at vehicle speed. */
    fun skip(place: String, lastEndPlace: String?, lastEndAt: Double?, speed: Double?, now: Double): Boolean {
        if (lastEndPlace == null || lastEndAt == null || lastEndPlace != place) return false
        val ago = now - lastEndAt
        if (ago < 0 || ago >= AFTER_ARRIVAL) return false
        if (speed != null && speed.isFinite() && speed >= VEHICLE_SPEED) return false
        return true
    }

    /** Which region a spot is in (the first whose circle, plus 150 m, holds it): where a ride ended. */
    fun regionAt(p: GeoPoint, regions: List<RegionSpec>): String? =
        regions.firstOrNull { Geo.metres(it.point, p) < it.radius + MERGE_METRES }?.id

    // MARK: the look after leaving (iOS TripManager.leftRegion: ten looks 35 s apart)

    const val LOOK_EVERY = 35.0
    const val LOOKS = 10

    /** The trip it may start: none while a trip runs, not the one running, and not one you ended by hand. */
    fun mayStart(tripId: String, idle: Boolean, running: String?, blocked: Set<String>): Boolean =
        idle && running != tripId && tripId !in blocked

    /** The trips you ended by hand stay blocked for two hours (so ending one doesn't start it again). */
    const val BLOCK_FOR = 2 * 3600.0
    fun prune(blocked: Map<String, Double>, now: Double): Map<String, Double> = blocked.filterValues { now - it in 0.0..BLOCK_FOR }
}

/** "Continue your trip" after ending one by hand before its last leg (iOS 0.26.2 `TripResume`). */
object TripResume {
    const val WITHIN = 30 * 60.0
    const val NEAR_ITS_STOP = 1000.0

    /** The leg it goes on with: at a change the next one; on a leg before the last, that leg. Null: none. */
    fun leg(atChange: Boolean, finished: Boolean, index: Int, count: Int): Int? {
        if (finished || index < 0) return null
        if (atChange) return if (index + 1 < count) index + 1 else null
        return if (index + 1 < count) index else null
    }

    /** Offered while no trip runs, within 30 minutes of the end, while you're on the way. */
    fun offer(endedAt: Double, now: Double, idle: Boolean, moving: Boolean, metresToItsStop: Double?): Boolean {
        if (!idle) return false
        val ago = now - endedAt
        if (ago < 0 || ago > WITHIN) return false
        if (moving) return true
        val m = metresToItsStop ?: return false
        return m.isFinite() && m >= 0 && m <= NEAR_ITS_STOP
    }
}
