package nl.haltewekker.ride

import kotlin.math.ceil
import kotlin.math.max

/**
 * (A7, iOS 0.37.1 `WristNotice`) the trip and wake-up notifications as a watch shows them (Wear OS mirrors the phone's
 * notifications with their actions): short, the stop first, one repeat after 30 s while it still rings, grouped per
 * trip, with a Stop alarm action that runs on the phone without opening the app. Plain values, tested.
 */
object WristNotice {
    const val STOP_ACTION = "STOP"
    const val STOP_TITLE = "Stop alarm"
    const val ALARM_CATEGORY = "ALARM"
    const val TRIP_CATEGORY = "TRIP"
    const val WAKE_CATEGORY = "WAKE"
    const val ALARM_ID = "alarm"
    const val AGAIN_ID = "alarm-again"
    const val AGAIN_AFTER = 30.0
    const val MAX_STOP = 22

    data class Lines(val title: String, val body: String)

    fun stop(name: String?): String {
        val s = (name ?: "").trim()
        if (s.isEmpty()) return "your stop"
        if (s.length <= MAX_STOP) return s
        return s.take(MAX_STOP - 1).trim() + "…"
    }

    fun minutes(secs: Double) = "${max(1, ceil(secs / 60).toInt())} min"

    fun ring(approach: Boolean, stop: String?, soon: String, inUse: Boolean = false, again: Boolean = false): Lines {
        val s = stop(stop)
        if (approach) {
            val title = "Get off at $s · $soon"
            if (inUse) return Lines(title, "Get ready to get off.")
            return Lines(title, if (again) "Still ringing: wake up and get ready to get off." else "Wake up: get ready to get off.")
        }
        val title = "Get off now at $s"
        if (inUse) return Lines(title, "This is your stop.")
        return Lines(title, if (again) "Still ringing: this is your stop." else "This is your stop.")
    }

    fun arrived(stop: String?, then: String?, finished: Boolean) =
        Lines("You’re at ${stop(stop)}", then ?: if (finished) "Get off here: your trip is done." else "Get off here.")

    fun backup(stop: String?) = Lines("Get off at ${stop(stop)} soon", "Your backup alarm: your stop should be close.")

    fun wakeTitle(title: String, repeat: Int) = if (repeat == 0) "⏰ $title" else "⏰ $title (again)"

    fun againDue(rangAt: Double, now: Double, stillRinging: Boolean, sent: Boolean) = stillRinging && !sent && now - rangAt >= AGAIN_AFTER

    fun secsAtAgain(secs: Double?): Double? = secs?.let { max(0.0, it - AGAIN_AFTER) }

    fun thread(tripStart: Double?) = tripStart?.let { "trip-${it.toLong()}" } ?: "trip"

    fun wakeThread(day: String) = "wake-$day"

    enum class Kind { ALARM, AGAIN, HEADS_UP, BACKUP, ARRIVED, SCHOOL_WAKE }

    fun relevance(k: Kind) = when (k) {
        Kind.ALARM, Kind.AGAIN, Kind.SCHOOL_WAKE -> 1.0
        Kind.HEADS_UP, Kind.BACKUP -> 0.9
        Kind.ARRIVED -> 0.7
    }
}

/** (A7, iOS 0.42.1 `AlarmStop`) what a notification's Stop alarm (or a tap or swipe on the ringing one) stops. */
object AlarmStop {
    enum class Action { STOP, OPEN, DISMISS, OTHER }

    fun action(identifier: String, open: String, dismiss: String) = when (identifier) {
        WristNotice.STOP_ACTION -> Action.STOP
        open -> Action.OPEN
        dismiss -> Action.DISMISS
        else -> Action.OTHER
    }

    data class Plan(val stopTrip: Boolean = false, val wakeRepeats: List<String> = emptyList(), val stopWake: Boolean = false) {
        val none: Boolean get() = !stopTrip && wakeRepeats.isEmpty() && !stopWake
    }

    fun plan(id: String, action: Action): Plan {
        if (id.startsWith("wake-")) return Plan(wakeRepeats = wakeRepeats(id), stopWake = action == Action.STOP)
        val isAlarm = id == WristNotice.ALARM_ID || id == WristNotice.AGAIN_ID
        return Plan(stopTrip = action == Action.STOP || (isAlarm && (action == Action.OPEN || action == Action.DISMISS)))
    }

    const val WAKE_COUNT = 3

    fun wakeRepeats(id: String): List<String> {
        if (!id.startsWith("wake-")) return emptyList()
        val cut = id.lastIndexOf('-')
        if (cut < 0) return emptyList()
        val base = id.substring(0, cut)
        if (base.length <= "wake".length) return emptyList()
        return (0 until WAKE_COUNT).map { "$base-$it" }
    }

    val tripDelivered = listOf(WristNotice.ALARM_ID, WristNotice.AGAIN_ID, "backup", "heads-up-true", "heads-up-false")
}
