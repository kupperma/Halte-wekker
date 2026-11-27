package nl.haltewekker.school

import kotlinx.serialization.Serializable
import nl.haltewekker.data.DoorTrip

/** One school day: its first class, the trip there and the alarm (iOS `SchoolAlarm.Planned`). */
@Serializable
data class Planned(
    val day: String,                    // yyyy-MM-dd
    val title: String,
    val room: String? = null,
    val classStart: Double,
    val beThere: Double,
    val leave: Double? = null,
    val arrive: Double? = null,
    val lines: String? = null,          // "306 · IC"
    val alarm: Double? = null,
    /** The alarm is set with Android (AlarmManager); false with an alarm time: too late, or not allowed. */
    val alarmSet: Boolean = false,
    val checked: Double = 0.0,          // when its trip was last planned
    val trip: DoorTrip? = null,
    /** (iOS 0.42.6) What the alarm was set with: "" as the timetable says, else the day's be-there time. */
    val label: String? = null,
) {
    /** The alarm has gone off (or its time has passed): never touched again, so it can't ring twice. */
    fun rang(now: Double): Boolean = (alarm ?: Double.POSITIVE_INFINITY) <= now
}

/** The school alarm's settings (iOS `school.on`, `school.cals`, `school.early`, `school.wake`). */
@Serializable
data class SchoolConfig(
    val on: Boolean = false,
    val calendarIds: List<Long> = emptyList(),
    val earlyMinutes: Int = 10,
    val wakeMinutes: Int = 60,
) {
    companion object {
        val earlyRange = 0..45
        val wakeRange = 15..150
    }
}

/** What planning asks Android to do with the alarms. */
sealed class AlarmOp {
    abstract val day: String
    data class Cancel(override val day: String) : AlarmOp()
    data class Set(override val day: String, val at: Double, val leave: Double, val classStart: Double, val title: String) : AlarmOp()
}

/**
 * Planning the school week (iOS `SchoolAlarm.plan`), as a plain function: the first classes in, the week and the alarm
 * changes out. The trips come from `planTrips` (Transitous, arriving by the time you want to be there). An alarm that
 * has gone off is never touched again; near days are planned again after 14 minutes (live times), far ones after 6 hours,
 * a moved class at once.
 */
object SchoolPlan {
    const val MIN_LEAD = 20 * 60.0          // a class this close is left as it is
    const val SOON = 36 * 3600.0
    const val NEAR_AGAIN = 14 * 60.0
    const val FAR_AGAIN = 6 * 3600.0
    const val KEEP_PAST = 2 * 86400.0

    fun beThere(classStart: Double, early: Int) = classStart - early * 60.0
    fun alarmAt(leave: Double, wake: Int) = leave - wake * 60.0

    /** Is a day due for planning again? */
    fun due(old: Planned?, classStart: Double, beThere: Double, now: Double, force: Boolean): Boolean {
        if (force || old == null) return true
        if (old.classStart != classStart || old.beThere != beThere) return true
        val soon = classStart - now < SOON
        return now - old.checked >= if (soon) NEAR_AGAIN else FAR_AGAIN
    }

    /** The trip that leaves the latest and still gets you there in time (a minute's slack), fewer changes first on a tie. */
    fun best(trips: List<DoorTrip>, beThere: Double, now: Double): DoorTrip? {
        val seen = HashSet<String>()
        return trips.filter { it.end <= beThere + 60 && it.first.departure > now && seen.add(it.id) }
            .maxWithOrNull(compareBy<DoorTrip> { it.start }.thenBy { -it.rides.size })
    }

    data class Result(val week: List<Planned>, val ops: List<AlarmOp>, val added: List<Planned>, val note: String?)

    suspend fun plan(
        week: List<Planned>,
        classes: Map<String, Lesson>,
        config: SchoolConfig,
        skipped: Set<String>,
        now: Double,
        force: Boolean,
        arrive: Map<String, Double> = emptyMap(),
        planTrips: suspend (beThere: Double) -> List<DoorTrip>,
    ): Result {
        val out = week.toMutableList()
        val ops = ArrayList<AlarmOp>()
        val added = ArrayList<Planned>()
        // days whose first class is gone from the timetable: their alarm goes (if it hasn't rung)
        for (p in week) if (classes[p.day] == null && !p.rang(now) && p.classStart > now) {
            if (p.alarmSet) ops.add(AlarmOp.Cancel(p.day))
            out.removeAll { it.day == p.day }
        }
        for (k in classes.keys.sorted()) {
            val e = classes.getValue(k)
            val old = out.firstOrNull { it.day == k }
            if (old?.rang(now) == true) continue                    // it rang: leave it alone
            if (e.start <= now + MIN_LEAD) continue
            // (iOS 0.42.6) the day's own "Be there at …" when you changed it, else the timetable's
            val changed = arrive[k] != null
            val be = SchoolArrive.beThere(e.start, config.earlyMinutes, arrive[k])
            if (!due(old, e.start, be, now, force)) continue
            val label = if (changed) be.toLong().toString() else ""
            val best = best(planTrips(be), be, now)
            var p: Planned
            if (best == null) {
                // no answer just now: keep what it had; right after you changed the day's time, its trip moved by the
                // change, so the alarm follows at once (planned again at the next chance)
                val ol = old?.leave
                if (old == null || old.beThere == be || old.classStart != e.start || ol == null) continue
                val leave = SchoolArrive.shiftedLeave(ol, old.beThere, be)
                if (leave <= now) continue
                p = old.copy(beThere = be, leave = leave, arrive = old.arrive?.let { SchoolArrive.shiftedLeave(it, old.beThere, be) },
                    checked = 0.0, trip = null)
            } else {
                p = (old ?: Planned(day = k, title = e.title ?: "Class", classStart = e.start, beThere = be)).copy(
                    title = e.title ?: "Class", room = e.room, classStart = e.start, beThere = be,
                    leave = best.start, arrive = best.end, checked = now, trip = best,
                    lines = best.rides.joinToString(" · ") { it.line },
                )
            }
            val leave = p.leave ?: continue
            val at = alarmAt(leave, config.wakeMinutes)
            var action = SchoolSkip.decide(at, k, skipped, p.alarm, p.alarmSet, now)
            // the same minute with new words (a changed be-there time): set again while it's more than 5 min ahead
            if (action == SchoolSkip.Action.Keep && p.alarmSet && k !in skipped && (p.label ?: "") != label && at > now + 5 * 60) {
                action = SchoolSkip.Action.Set(at, schedule = true)
            }
            when (val a = action) {
                SchoolSkip.Action.Keep -> {}
                SchoolSkip.Action.Clear -> {
                    if (p.alarmSet) ops.add(AlarmOp.Cancel(k))
                    p = p.copy(alarm = null, alarmSet = false)
                }
                is SchoolSkip.Action.Set -> {
                    if (p.alarmSet && !a.schedule) ops.add(AlarmOp.Cancel(k))
                    if (a.schedule) ops.add(AlarmOp.Set(k, a.at, leave, e.start, p.title))
                    val wasSet = old?.alarmSet == true
                    p = p.copy(alarm = a.at, alarmSet = a.schedule, label = if (a.schedule) label else p.label)
                    if (a.schedule && !wasSet) added.add(p)
                }
            }
            val i = out.indexOfFirst { it.day == k }
            if (i >= 0) out[i] = p else out.add(p)
        }
        out.removeAll { it.classStart < now - KEEP_PAST }
        out.sortBy { it.classStart }
        return Result(out, ops, added, null)
    }

    /** The next school day whose class is still ahead. */
    fun next(week: List<Planned>, now: Double): Planned? = week.filter { it.classStart > now }.minByOrNull { it.classStart }

    /** What to say under the school alarm when planning found nothing to do. */
    fun note(source: ScheduleSource, classesEmpty: Boolean, calendarsPicked: Boolean, calendarAllowed: Boolean): String? = when (source) {
        ScheduleSource.CALENDARS -> when {
            !calendarAllowed -> "Allow calendar access to read your timetable."
            !calendarsPicked -> "Pick your school calendar."
            classesEmpty -> "No classes found in the next week."
            else -> null
        }
        ScheduleSource.MANUAL -> if (classesEmpty) "No school days in your week." else null
        ScheduleSource.NONE -> "Your timetable isn't set up yet."
    }
}
