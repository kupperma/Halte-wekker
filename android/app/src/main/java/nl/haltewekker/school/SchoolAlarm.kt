package nl.haltewekker.school

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.SetSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import nl.haltewekker.App
import nl.haltewekker.core.Iso
import nl.haltewekker.data.Transit
import nl.haltewekker.ride.Notifications
import nl.haltewekker.ui.Fmt
import nl.haltewekker.work.Works
import java.time.Instant
import java.time.LocalDate
import java.time.format.TextStyle
import java.util.Locale
import kotlin.math.abs

/**
 * The school alarm (iOS `SchoolAlarm`): it reads your timetable (the calendars you picked, or your week), takes the
 * first class of each school day of the next week, plans the trip there from home with live times (the one that leaves
 * the latest and still gets you there a little before class), and sets an alarm before you have to leave. Planned
 * again by WorkManager (hourly, and when the calendar changes) and whenever the app or a setting asks.
 */
object SchoolAlarm {
    const val KEY_CONFIG = "school.v1"
    const val KEY_WEEK = "school.week.v1"
    const val KEY_SKIP = "school.skip"

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val _config = MutableStateFlow(SchoolConfig())
    val config: StateFlow<SchoolConfig> = _config
    private val _week = MutableStateFlow<List<Planned>>(emptyList())
    val week: StateFlow<List<Planned>> = _week
    private val _skipped = MutableStateFlow<Set<String>>(emptySet())
    val skipped: StateFlow<Set<String>> = _skipped
    private val _note = MutableStateFlow<String?>(null)
    val note: StateFlow<String?> = _note
    private val _planning = MutableStateFlow(false)
    val planning: StateFlow<Boolean> = _planning
    private var loaded = false
    private val lock = Mutex()
    private var lastPlan = 0.0

    private fun store(c: Context) = (c.applicationContext as App).store

    fun load(c: Context) { if (!loaded) reload(c) }

    /** Read it all again (at the start, and after the setup backup was put back). */
    fun reload(c: Context) {
        loaded = true
        val s = store(c)
        _config.value = s.getString(KEY_CONFIG)?.let { try { json.decodeFromString<SchoolConfig>(it) } catch (_: Exception) { null } } ?: SchoolConfig()
        val now = Iso.now()
        _week.value = (s.getString(KEY_WEEK)?.let { try { json.decodeFromString(ListSerializer(Planned.serializer()), it) } catch (_: Exception) { null } } ?: emptyList())
            .filter { it.classStart > now - SchoolPlan.KEEP_PAST }
        val sk = s.getString(KEY_SKIP)?.let { try { json.decodeFromString(SetSerializer(String.serializer()), it) } catch (_: Exception) { null } } ?: emptySet()
        _skipped.value = SchoolSkip.prune(sk, ManualWeek.dayKey(now, Timetable.amsterdam))
    }

    private fun saveWeek(c: Context) = store(c).putString(KEY_WEEK, json.encodeToString(ListSerializer(Planned.serializer()), _week.value))
    private fun saveSkip(c: Context) = store(c).putString(KEY_SKIP, json.encodeToString(SetSerializer(String.serializer()), _skipped.value))

    /** The settings changed (Settings, the setup): saved, the background work follows, and the week is planned again. */
    fun setConfig(c: Context, new: SchoolConfig) {
        load(c)
        val old = _config.value
        _config.value = new
        store(c).putString(KEY_CONFIG, json.encodeToString(SchoolConfig.serializer(), new))
        if (old.on && !new.on) stop(c)
        Works.update(c)
        if (new.on) (c.applicationContext as App).launch { refresh(c, force = true) }
    }

    /** Turned off: every alarm that hasn't rung goes. */
    private fun stop(c: Context) {
        val now = Iso.now()
        for (p in _week.value) if (!p.rang(now)) WakeAlarm.cancel(c, p.day)
        _week.value = emptyList(); saveWeek(c)
        _note.value = null
    }

    /** The week starts again: its alarms go, no day is off (a test setup's Done). */
    fun clearWeek(c: Context) {
        load(c)
        cancelAll(c)
        _week.value = emptyList(); saveWeek(c)
        _skipped.value = emptySet(); saveSkip(c)
    }

    /** Every alarm of the week goes (before the setup backup is put back: the other setup's alarms are not yours). */
    fun cancelAll(c: Context) { for (p in _week.value) WakeAlarm.cancel(c, p.day) }

    /** After a restart (Android forgets alarms then) or a restore: the week's alarms set again from what was planned. */
    fun rearm(c: Context) {
        load(c)
        val now = Iso.now()
        if (!_config.value.on) return
        for (p in _week.value) {
            val at = p.alarm ?: continue
            if (p.alarmSet && at > now + 60 && p.day !in _skipped.value) WakeAlarm.set(c, p.day, at, "Time to get up", body(p), p.leave)
        }
    }

    private fun body(p: Planned) = "Leave ${p.leave?.let(Fmt::time) ?: "soon"} for your ${Fmt.time(p.classStart)} ${p.title}"

    fun next(now: Double = Iso.now()): Planned? = SchoolPlan.next(_week.value, now)

    /** The first classes, from the calendars you picked or your week (empty: none, or no calendar access). */
    fun classes(c: Context, now: Double): Map<String, Lesson> {
        val p = store(c).profile.value
        return when (p.schedule) {
            ScheduleSource.CALENDARS -> {
                val start = LocalDate.now(Timetable.amsterdam).atStartOfDay(Timetable.amsterdam).toEpochSecond().toDouble()
                Timetable.firstClasses(Calendars.events(c, _config.value.calendarIds, start, start + 8 * 86400))
            }
            ScheduleSource.MANUAL -> Timetable.fromWeek(p.week ?: ManualWeek(), now)
            ScheduleSource.NONE -> emptyMap()
        }
    }

    /**
     * Plan the week again (one at a time). Not forced: only when 5 minutes have passed, and then only the days that
     * are due (`SchoolPlan.due`).
     */
    suspend fun refresh(c: Context, force: Boolean = false) {
        load(c)
        if (!_config.value.on) return
        lock.withLock {
            val now = Iso.now()
            if (!force && now - lastPlan < 5 * 60) return
            lastPlan = now
            _planning.value = true
            try { plan(c, force, now) } finally { _planning.value = false }
        }
    }

    private suspend fun plan(c: Context, force: Boolean, now: Double) {
        val prof = store(c).profile.value
        val cfg = _config.value
        val home = prof.home; val school = prof.school
        if (home == null || school == null) { _note.value = "Set your home and school first."; return }
        val allowed = Calendars.granted(c)
        if (prof.schedule == ScheduleSource.CALENDARS && !allowed) { _note.value = SchoolPlan.note(prof.schedule, true, cfg.calendarIds.isNotEmpty(), false); return }
        val classes = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { classes(c, now) }
        val oldNext = next(now)
        val r = SchoolPlan.plan(_week.value, classes, cfg, _skipped.value, now, force) { be ->
            Transit.plan(home.planId, school.planId, be, count = 6, maxTransfers = 4, arriveBy = true)
        }
        if (!_config.value.on) return
        for (op in r.ops) when (op) {
            is AlarmOp.Cancel -> WakeAlarm.cancel(c, op.day)
            is AlarmOp.Set -> WakeAlarm.set(c, op.day, op.at, "Time to get up", "Leave ${Fmt.time(op.leave)} for your ${Fmt.time(op.classStart)} ${op.title}", op.leave)
        }
        _week.value = r.week
        saveWeek(c)
        _note.value = SchoolPlan.note(prof.schedule, classes.isEmpty(), cfg.calendarIds.isNotEmpty(), allowed)
        tell(c, r.added, oldNext, now)
        Works.early(c, next(now)?.takeIf { it.alarmSet }?.alarm)
    }

    /** Say what changed: the new alarms, or the next one moving by 5 minutes or more. */
    private fun tell(c: Context, added: List<Planned>, oldNext: Planned?, now: Double) {
        val set = added.filter { (it.alarm ?: 0.0) > now }
        val n = next(now)
        if (set.isNotEmpty()) {
            val list = set.take(5).joinToString(" · ") { "${shortDay(it.classStart)} ${Fmt.time(it.alarm!!)}" }
            val one = set[0]
            val title = if (set.size == 1) "School alarm ${dayWord(one.alarm!!)} ${Fmt.time(one.alarm)}" else "${set.size} school alarms set"
            val text = if (set.size == 1) "Leave ${Fmt.time(one.leave!!)} · first class ${Fmt.time(one.classStart)} ${one.title}" else list
            Notifications.school(c, "school-set", title, text)
        } else if (oldNext != null && n != null && oldNext.classStart == n.classStart) {
            val a = oldNext.alarm; val b = n.alarm
            if (a != null && b != null && abs(b - a) >= 5 * 60 && b > now) {
                Notifications.school(c, "school-move", "School alarm moved to ${Fmt.time(b)}",
                    "Was ${Fmt.time(a)} · the buses changed · leave ${Fmt.time(n.leave ?: b)} for ${Fmt.time(n.classStart)} ${n.title}")
            }
        }
    }

    // MARK: Your day: a day's alarm off, or on again

    fun isSkipped(day: String) = day in _skipped.value

    /** One day's wake-up alarm off (that day only), or on again: then set at once from the trip it has, and planned again. */
    fun setSkipped(c: Context, day: String, skip: Boolean) {
        load(c)
        _skipped.value = if (skip) _skipped.value + day else _skipped.value - day
        saveSkip(c)
        val now = Iso.now()
        val i = _week.value.indexOfFirst { it.day == day }
        if (i < 0) return
        val p = _week.value[i]
        if (skip && !p.rang(now)) {
            WakeAlarm.cancel(c, day)
            _week.value = _week.value.toMutableList().also { it[i] = p.copy(alarm = null, alarmSet = false) }
        } else if (!skip) {
            val at = SchoolSkip.restore(p.leave, _config.value.wakeMinutes, now)
            if (at != null) WakeAlarm.set(c, day, at, "Time to get up", body(p), p.leave)
            _week.value = _week.value.toMutableList().also { it[i] = p.copy(alarm = at ?: p.alarm, alarmSet = at != null, checked = 0.0) }
            (c.applicationContext as App).launch { refresh(c, force = false) }
        }
        saveWeek(c)
    }

    /** The alarm went off (or was stopped): the day is done. */
    fun rang(c: Context, day: String) {
        load(c)
        if (day == WakeAlarm.TEST_DAY) return
        val now = Iso.now()
        _week.value = _week.value.map { if (it.day == day && (it.alarm ?: 0.0) > now) it.copy(alarm = now) else it }
        saveWeek(c)
    }

    /** "today", "tomorrow", "Monday". */
    fun dayWord(t: Double): String {
        val d = Instant.ofEpochMilli((t * 1000).toLong()).atZone(Timetable.amsterdam).toLocalDate()
        val today = LocalDate.now(Timetable.amsterdam)
        return when (d) {
            today -> "today"
            today.plusDays(1) -> "tomorrow"
            else -> d.dayOfWeek.getDisplayName(TextStyle.FULL, Locale.UK)
        }
    }

    /** "Mon". */
    fun shortDay(t: Double): String =
        Instant.ofEpochMilli((t * 1000).toLong()).atZone(Timetable.amsterdam).dayOfWeek.getDisplayName(TextStyle.SHORT, Locale.UK)
}
