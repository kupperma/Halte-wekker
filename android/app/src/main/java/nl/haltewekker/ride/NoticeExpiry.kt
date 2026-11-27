package nl.haltewekker.ride

/**
 * How long each kind of notification stays before the app takes it off (iOS 0.24.2 `NoticeExpiry`). Android can time
 * a notification out by itself (`setTimeoutAfter`), so each is posted with its time; the sweep at each wake-up (the app,
 * a background plan) takes off the ones a reboot or an old version left. Kinds by their tag's start. The ride's own
 * notification and the alarms are never taken off here, and an unknown tag stays.
 */
object NoticeExpiry {
    private val rules: List<Pair<String, Double>> = listOf(
        "trip-ended" to 10.0,
        "autostart" to 10.0,       // "your trip started by itself", "looking for your bus"
        "arrived-" to 10.0,        // "You're at …"
        "resume-" to 30.0,         // "Continue your trip"
        "wake-missed" to 90.0,     // the school alarm wasn't stopped: leave by …
        "school-" to 12 * 60.0,    // "School alarm tomorrow 07:10", "moved to …"
        "ready-" to 10.0,          // (A8, iOS 0.39) the quiet "Get ready" one stop before yours
        "wrongbus-" to 20.0,       // (A7, iOS 0.39.1) "You're on the 154 to Schijndel, not your 306"
        "otherbus-" to 10.0,       // (A7, iOS 0.39.1) "That's the 154 to Schijndel — not yours"
        "heads-up-" to 10.0,       // (A7, iOS 0.37.1) the quiet wake-up while you used your phone
        "platform-" to 20.0,       // (0.10.1) a platform change or cancelled train: the train has left by then
        "livemsg-" to 60.0,        // (0.10.1) a message from someone with your live link
    ).sortedByDescending { it.first.length }

    /** Minutes a notification with this tag stays; null: until you clear it. */
    fun minutes(tag: String?): Double? {
        val t = tag ?: return null
        return rules.firstOrNull { t.startsWith(it.first) }?.second
    }

    /** The posted notifications to take off now: (tag, posted at, seconds since 1970). */
    fun due(posted: List<Pair<String?, Double>>, now: Double): List<String> =
        posted.mapNotNull { (tag, at) -> val m = minutes(tag) ?: return@mapNotNull null; if (now - at >= m * 60) tag else null }
}

/** The ride made smaller (iOS 0.26.1 `RideBar`): the bar over the home while a trip runs. Plain, tested. */
object RideBar {
    enum class Wake { FINDING, SLEEPING, AWAKE, ALARM }

    fun wake(phase: Phase, vehicleKnown: Boolean): Wake = when {
        phase == Phase.ALARM -> Wake.ALARM
        phase == Phase.AWAKE || phase == Phase.FINISHED -> Wake.AWAKE
        !vehicleKnown -> Wake.FINDING
        else -> Wake.SLEEPING
    }

    fun wakeText(w: Wake, ringAtStop: Boolean): String = when (w) {
        Wake.ALARM -> "Wake up"
        Wake.FINDING -> "Finding your bus or train"
        Wake.SLEEPING -> "Wakes you before your stop"
        Wake.AWAKE -> if (ringAtStop) "You're awake · a chime there" else "You're awake"
    }

    /** "Bus 305 to Uden", or "To Uden" before it knows which one. */
    fun title(vehicle: String?, to: String): String {
        if (vehicle.isNullOrEmpty()) return if (to.isEmpty()) "Your trip" else "To $to"
        return if (to.isEmpty()) vehicle else "$vehicle to $to"
    }

    data class Countdown(val value: String, val unit: String)

    /** The minutes to your stop while its time is known (and not more than two minutes past); else the distance. */
    fun countdown(eta: Double?, metres: Double?, now: Double): Countdown? {
        if (eta != null && eta > now - 120) return Countdown("${maxOf(0, Math.round((eta - now) / 60).toInt())}", "min")
        val d = metres ?: return null
        if (!d.isFinite()) return null
        if (d < 1000) return Countdown("${maxOf(0, Math.round(d / 10).toInt() * 10)}", "m")
        return Countdown(String.format(java.util.Locale.ROOT, "%.1f", d / 1000), "km")
    }

    /** "12 min · leg 1 of 2". */
    fun detail(countdown: Countdown?, index: Int, legs: Int): String =
        listOfNotNull(countdown?.let { "${it.value} ${it.unit}" }, if (legs > 1) "leg ${index + 1} of $legs" else null).joinToString(" · ")

    /** Made smaller holds for this trip only while it doesn't ring: the alarm opens it full again. */
    fun keepsSmall(small: Boolean, rideOn: Boolean, alarm: Boolean): Boolean = small && rideOn && !alarm
}
