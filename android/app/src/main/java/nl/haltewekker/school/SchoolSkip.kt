package nl.haltewekker.school

import kotlin.math.floor

/** A day whose wake-up alarm you turned off on Your day: that day only (iOS `SchoolSkip`). Plain rules, tested. */
object SchoolSkip {
    sealed class Action {
        data object Keep : Action()
        data object Clear : Action()
        /** (Re)set it to `at`; `schedule`: still more than a minute ahead. */
        data class Set(val at: Double, val schedule: Boolean) : Action()
    }

    /** The day's alarm, planned for `at`: none on a skipped day; kept when it's set for that same minute; else set again. */
    fun decide(at: Double, day: String, skipped: kotlin.collections.Set<String>, current: Double?, hasAlarm: Boolean, now: Double): Action {
        if (day in skipped) return if (current != null || hasAlarm) Action.Clear else Action.Keep
        val same = current?.let { floor(it / 60) == floor(at / 60) } ?: false
        if (same && hasAlarm) return Action.Keep
        return Action.Set(at, schedule = at > now + 60)
    }

    /** A day turned back on: its alarm right away from the trip it has, when that's still more than a minute ahead. */
    fun restore(leave: Double?, wakeMinutes: Int, now: Double): Double? {
        val l = leave ?: return null
        val at = l - wakeMinutes * 60
        return if (at > now + 60) at else null
    }

    /** The skipped days still to come (`today` as yyyy-MM-dd; the strings sort as dates). */
    fun prune(s: kotlin.collections.Set<String>, today: String): kotlin.collections.Set<String> = s.filter { it >= today }.toSet()
}
