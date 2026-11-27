package nl.haltewekker.school

import kotlinx.serialization.Serializable
import kotlin.math.abs
import kotlin.math.floor

/**
 * "Be there at …" for one school day (iOS 0.42.6 `SchoolArrive`): a time you pick instead of the timetable's (first
 * class minus how early you want to be there). Per date, never per weekday, gone once its day is over. Plain rules,
 * tested with the iOS vectors (`SchoolArriveTest`). Times in seconds since 1970.
 */
object SchoolArrive {
    enum class Quick(val minutes: Int, val title: String) {
        HOUR_EARLIER(-60, "1 h earlier"),
        TWO_HOURS_EARLIER(-120, "2 h earlier"),
        HALF_HOUR_LATER(30, "30 min later"),
    }

    fun timetable(classStart: Double, early: Int): Double = classStart - early * 60.0

    fun beThere(classStart: Double, early: Int, override: Double?): Double = override ?: timetable(classStart, early)

    fun quick(q: Quick, timetable: Double): Double = timetable + q.minutes * 60.0

    /** Whole minutes; null when it's the timetable's own minute, or more than 12 hours from the first class. */
    fun normalized(t: Double, timetable: Double, classStart: Double): Double? {
        val picked = floor(t / 60) * 60
        if (floor(picked / 60) == floor(timetable / 60)) return null
        if (abs(picked - classStart) > 12 * 3600) return null
        return picked
    }

    /** The changes still to come (`today` as yyyy-MM-dd). */
    fun prune(o: Map<String, Double>, today: String): Map<String, Double> = o.filter { it.key >= today }

    fun changedLine(beThere: Double, classStart: Double, clock: (Double) -> String): String =
        "Changed: be there ${clock(beThere)} (class ${clock(classStart)})"

    /** The alarm's title and text: as before unless you changed the day's time. */
    fun alarmText(leave: Double, classStart: Double, beThere: Double, changed: Boolean, clock: (Double) -> String): Pair<String, String> =
        if (!changed) "Time to get up" to "Leave ${clock(leave)} for your ${clock(classStart)} class"
        else "Time to get up · be there ${clock(beThere)}" to "Leave ${clock(leave)} to be there ${clock(beThere)} (class ${clock(classStart)})"

    fun shiftedLeave(oldLeave: Double, oldBeThere: Double, newBeThere: Double): Double = oldLeave + (newBeThere - oldBeThere)
}

/**
 * Never ring when you're already going (iOS 0.42.6 `OnTheWay`): that morning's school wake-up is skipped when a trip to
 * school started that morning (or runs), when you got to school that day, or when you clearly left home that morning
 * (a ride started and you left home's region or are more than 1 km away). Moving around at home alone never skips it.
 */
object OnTheWay {
    const val MORNING_HOUR = 3
    const val SCHOOL_TRIP_METRES = 1500.0
    const val AT_SCHOOL_METRES = 400.0
    const val FAR_METRES = 1000.0
    const val HOME_METRES = 500.0
    const val FRESH_FIX = 15 * 60.0

    @Serializable
    data class Seen(
        val day: String,
        val tripAt: Double? = null,
        val schoolTripAt: Double? = null,
        val atSchool: Double? = null,
        val leftHome: Double? = null,
    )

    data class Live(
        val running: Boolean = false,
        val runningToSchool: Boolean = false,
        val homeMetres: Double? = null,
        val fixAt: Double? = null,
    )

    sealed class Reason {
        data class Going(val trip: Double) : Reason()
        data class AtSchool(val at: Double) : Reason()
    }

    sealed class Decision {
        data object Ring : Decision()
        data class Skip(val reason: Reason) : Decision()
    }

    fun fresh(s: Seen?, day: String): Seen = if (s != null && s.day == day) s else Seen(day)

    fun towardSchool(lastStopMetres: Double?, fixedToSchool: Boolean): Boolean =
        fixedToSchool || (lastStopMetres != null && lastStopMetres <= SCHOOL_TRIP_METRES)

    fun atSchool(metres: Double?, fixAt: Double?, now: Double): Boolean =
        metres != null && fixAt != null && metres <= AT_SCHOOL_METRES && now - fixAt <= FRESH_FIX

    fun decide(day: String, today: String, alarm: Double?, now: Double, morning: Double, seen: Seen, live: Live): Decision {
        if (day != today || seen.day != day || alarm == null || alarm <= now) return Decision.Ring
        fun thisMorning(d: Double?): Double? = d?.takeIf { it >= morning && it <= now }
        val fresh = live.fixAt?.let { now - it <= FRESH_FIX } ?: false
        val home = live.homeMetres ?: Double.POSITIVE_INFINITY
        val nearHome = fresh && home < HOME_METRES
        val far = fresh && home > FAR_METRES
        thisMorning(seen.schoolTripAt)?.let { t -> if (live.runningToSchool || !nearHome) return Decision.Skip(Reason.Going(t)) }
        if (nearHome) return Decision.Ring
        thisMorning(seen.atSchool)?.let { return Decision.Skip(Reason.AtSchool(it)) }
        thisMorning(seen.tripAt)?.let { t -> if (thisMorning(seen.leftHome) != null || far) return Decision.Skip(Reason.Going(t)) }
        return Decision.Ring
    }

    fun words(r: Reason, clock: (Double) -> String): String = when (r) {
        is Reason.Going -> "already on the way (trip ${clock(r.trip)})"
        is Reason.AtSchool -> "already at school (${clock(r.at)})"
    }

    fun logLine(r: Reason, clock: (Double) -> String): String = "school alarm · skipped: ${words(r, clock)}"

    fun <V> prune(m: Map<String, V>, today: String): Map<String, V> = m.filter { it.key >= today }
}
