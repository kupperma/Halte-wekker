package nl.haltewekker.school

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.SetSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import nl.haltewekker.App
import nl.haltewekker.core.Geo
import nl.haltewekker.core.Iso
import nl.haltewekker.logs.FieldLog
import nl.haltewekker.ride.RideState
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
    /** (iOS 0.42.6) "Be there at …" per day, the days skipped because you were already going, the days turned
     *  back on after that, and what was seen this morning. */
    const val KEY_ARRIVE = "school.arrive"
    const val KEY_GOING = "school.going"
    const val KEY_KEEP = "school.keepRinging"
    const val KEY_SEEN = "school.morning"

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val _config = MutableStateFlow(SchoolConfig())
    val config: StateFlow<SchoolConfig> = _config
    private val _week = MutableStateFlow<List<Planned>>(emptyList())
    val week: StateFlow<List<Planned>> = _week
    private val _skipped = MutableStateFlow<Set<String>>(emptySet())
    val skipped: StateFlow<Set<String>> = _skipped
    private val _arrive = MutableStateFlow<Map<String, Double>>(emptyMap())
    val arrive: StateFlow<Map<String, Double>> = _arrive
    private val _going = MutableStateFlow<Map<String, String>>(emptyMap())
    val going: StateFlow<Map<String, String>> = _going
    private var keepRinging: Set<String> = emptySet()
    private var seen = OnTheWay.Seen("")
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
        val today = ManualWeek.dayKey(now, Timetable.amsterdam)
        _arrive.value = SchoolArrive.prune(s.getString(KEY_ARRIVE)?.let { try { json.decodeFromString(MapSerializer(String.serializer(), Double.serializer()), it) } catch (_: Exception) { null } } ?: emptyMap(), today)
        _going.value = OnTheWay.prune(s.getString(KEY_GOING)?.let { try { json.decodeFromString(MapSerializer(String.serializer(), String.serializer()), it) } catch (_: Exception) { null } } ?: emptyMap(), today)
        keepRinging = (s.getString(KEY_KEEP)?.let { try { json.decodeFromString(SetSerializer(String.serializer()), it) } catch (_: Exception) { null } } ?: emptySet()).filter { it >= today }.toSet()
        seen = OnTheWay.fresh(s.getString(KEY_SEEN)?.let { try { json.decodeFromString(OnTheWay.Seen.serializer(), it) } catch (_: Exception) { null } }, today)
    }

    private fun saveArrive(c: Context) = store(c).putString(KEY_ARRIVE, json.encodeToString(MapSerializer(String.serializer(), Double.serializer()), _arrive.value))
    private fun saveGoing(c: Context) {
        store(c).putString(KEY_GOING, json.encodeToString(MapSerializer(String.serializer(), String.serializer()), _going.value))
        store(c).putString(KEY_KEEP, json.encodeToString(SetSerializer(String.serializer()), keepRinging))
    }
    private fun saveSeen(c: Context) = store(c).putString(KEY_SEEN, json.encodeToString(OnTheWay.Seen.serializer(), seen))

    /** The days without an alarm: turned off on Your day, or skipped because you were already on the way. */
    val offDays: Set<String> get() = _skipped.value + _going.value.keys

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
        _arrive.value = emptyMap(); saveArrive(c)
        _going.value = emptyMap(); keepRinging = emptySet(); saveGoing(c)
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
            if (p.alarmSet && at > now + 60 && p.day !in offDays) { val (t, b) = text(p); WakeAlarm.set(c, p.day, at, t, b, p.leave) }
        }
    }

    /** The alarm's title and text: as before, or (iOS 0.42.6) with the time you picked for the day. */
    private fun text(p: Planned): Pair<String, String> = text(p.day, p.leave ?: p.classStart, p.classStart, p.beThere, p.title)

    private fun text(day: String, leave: Double, classStart: Double, beThere: Double, title: String): Pair<String, String> =
        if (_arrive.value[day] == null) "Time to get up" to "Leave ${Fmt.time(leave)} for your ${Fmt.time(classStart)} $title"
        else SchoolArrive.alarmText(leave, classStart, beThere, true, Fmt::time)

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
    suspend fun refresh(c: Context, force: Boolean = false, immediate: Boolean = false) {
        load(c)
        if (!_config.value.on) return
        lock.withLock {
            val now = Iso.now()
            if (!force && !immediate && now - lastPlan < 5 * 60) return
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
        pruneDays(c, now)
        checkOnTheWay(c, now)
        val r = SchoolPlan.plan(_week.value, classes, cfg, offDays, now, force, _arrive.value) { be ->
            Transit.plan(home.planId, school.planId, be, count = 6, maxTransfers = 4, arriveBy = true)
        }
        if (!_config.value.on) return
        for (op in r.ops) when (op) {
            is AlarmOp.Cancel -> WakeAlarm.cancel(c, op.day)
            is AlarmOp.Set -> { val (t, b) = text(op.day, op.leave, op.classStart, _arrive.value[op.day] ?: op.classStart, op.title); WakeAlarm.set(c, op.day, op.at, t, b, op.leave) }
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
            var text = if (set.size == 1) "Leave ${Fmt.time(one.leave!!)} · first class ${Fmt.time(one.classStart)} ${one.title}" else list
            if (set.size == 1) changedLine(one.day)?.let { text += " · $it" }
            Notifications.school(c, "school-set", title, text)
        } else if (oldNext != null && n != null && oldNext.classStart == n.classStart) {
            val a = oldNext.alarm; val b = n.alarm
            if (a != null && b != null && abs(b - a) >= 5 * 60 && b > now) {
                Notifications.school(c, "school-move", "School alarm moved to ${Fmt.time(b)}",
                    "Was ${Fmt.time(a)} · ${_arrive.value[n.day]?.let { "be there ${Fmt.time(it)} (class ${Fmt.time(n.classStart)})" } ?: "the buses changed"} · leave ${Fmt.time(n.leave ?: b)} for ${Fmt.time(n.classStart)} ${n.title}")
            }
        }
    }

    // MARK: Your day: a day's alarm off, or on again

    fun isSkipped(day: String) = day in _skipped.value || day in _going.value

    /** One day's wake-up alarm off (that day only), or on again: then set at once from the trip it has, and planned again. */
    fun setSkipped(c: Context, day: String, skip: Boolean) {
        load(c)
        _skipped.value = if (skip) _skipped.value + day else _skipped.value - day
        saveSkip(c)
        if (!skip && day in _going.value) {
            // (iOS 0.42.6) turned back on after a skip for being on the way: it rings, and isn't skipped again that day
            _going.value = _going.value - day; keepRinging = keepRinging + day; saveGoing(c)
            FieldLog.ride("school alarm · $day: turned back on after the skip")
        }
        val now = Iso.now()
        val i = _week.value.indexOfFirst { it.day == day }
        if (i < 0) return
        val p = _week.value[i]
        if (skip && !p.rang(now)) {
            WakeAlarm.cancel(c, day)
            _week.value = _week.value.toMutableList().also { it[i] = p.copy(alarm = null, alarmSet = false) }
        } else if (!skip) {
            val at = SchoolSkip.restore(p.leave, _config.value.wakeMinutes, now)
            if (at != null) { val (t, b) = text(p); WakeAlarm.set(c, day, at, t, b, p.leave) }
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

    // MARK: (iOS 0.42.6) Be there at … per day

    /** The day's own "Be there at …", if you changed it. */
    fun arrival(day: String): Double? = _arrive.value[day]

    fun timetableBeThere(p: Planned): Double = SchoolArrive.timetable(p.classStart, _config.value.earlyMinutes)

    /** "Changed: be there 09:00 (class 11:00)", when the day's time is yours. */
    fun changedLine(day: String): String? {
        val a = _arrive.value[day] ?: return null
        val p = _week.value.firstOrNull { it.day == day } ?: return null
        return SchoolArrive.changedLine(a, p.classStart, Fmt::time)
    }

    /** "Be there at …" for one day (null: the timetable's again): the day's trip and alarm are planned again at once. */
    fun setArrival(c: Context, day: String, t: Double?) {
        load(c)
        val p = _week.value.firstOrNull { it.day == day }
        val v = if (t != null && p != null) SchoolArrive.normalized(t, timetableBeThere(p), p.classStart) else t
        if (_arrive.value[day] == v) return
        _arrive.value = if (v != null) _arrive.value + (day to v) else _arrive.value - day
        saveArrive(c)
        _week.value = _week.value.map { if (it.day == day) it.copy(checked = 0.0) else it }
        saveWeek(c)
        FieldLog.ride(if (v != null) "school alarm · $day: be there ${Fmt.time(v)}" else "school alarm · $day: be there as the timetable says")
        (c.applicationContext as App).launch { refresh(c, force = false, immediate = true) }
    }

    fun setArrival(c: Context, day: String, q: SchoolArrive.Quick) {
        val p = _week.value.firstOrNull { it.day == day } ?: return
        setArrival(c, day, SchoolArrive.quick(q, timetableBeThere(p)))
    }

    /** Yesterday's changes and skips go. */
    private fun pruneDays(c: Context, now: Double) {
        val today = ManualWeek.dayKey(now, Timetable.amsterdam)
        val a = SchoolArrive.prune(_arrive.value, today)
        if (a.size != _arrive.value.size) { _arrive.value = a; saveArrive(c) }
        val g = OnTheWay.prune(_going.value, today)
        val k = keepRinging.filter { it >= today }.toSet()
        if (g.size != _going.value.size || k.size != keepRinging.size) { _going.value = g; keepRinging = k; saveGoing(c) }
    }

    // MARK: (iOS 0.42.6) already on the way

    /** 03:00 today: "this morning" starts. */
    private fun morning(now: Double): Double {
        val d = Instant.ofEpochMilli((now * 1000).toLong()).atZone(Timetable.amsterdam).toLocalDate()
        return d.atTime(OnTheWay.MORNING_HOUR, 0).atZone(Timetable.amsterdam).toEpochSecond().toDouble()
    }

    private fun today(now: Double) = ManualWeek.dayKey(now, Timetable.amsterdam)

    private fun towardSchool(c: Context, r: RideState): Boolean {
        val school = store(c).profile.value.school ?: return false
        val last = r.trip.rides.lastOrNull()?.to?.let { Geo.metres(it, school.point) }
        return OnTheWay.towardSchool(last, fixedToSchool = r.destination == school.name)
    }

    /** The ride (read only, from `RideStore.set`): a start, or its end at your last stop. */
    fun rideChanged(c: Context, old: RideState?, new: RideState?) {
        try {
            load(c)
            val now = Iso.now()
            if (now < morning(now)) return
            var s = OnTheWay.fresh(seen, today(now))
            if (new != null && old == null && !new.finished) {
                if (s.tripAt == null) s = s.copy(tripAt = now)
                if (s.schoolTripAt == null && towardSchool(c, new)) s = s.copy(schoolTripAt = now)
            }
            if (new != null && new.finished && old?.finished != true && s.atSchool == null && towardSchool(c, new)) s = s.copy(atSchool = now)
            if (s != seen) { seen = s; saveSeen(c) }
            if (new != null && old == null || new?.finished == true) checkOnTheWay(c, now)
        } catch (_: Exception) {}
    }

    /** A region (`AutoStart.onRegion`): left home, or got to school. */
    fun region(c: Context, home: Boolean, entering: Boolean) {
        load(c)
        val now = Iso.now()
        if (now < morning(now)) return
        var s = OnTheWay.fresh(seen, today(now))
        if (home && !entering && s.leftHome == null) s = s.copy(leftHome = now)
        if (!home && entering && s.atSchool == null) s = s.copy(atSchool = now)
        if (s != seen) { seen = s; saveSeen(c) }
        checkOnTheWay(c, now)
    }

    /** Why a day's alarm was skipped ("already on the way (trip 07:12)"), if it was. */
    fun goingWords(day: String): String? = _going.value[day]

    /**
     * This morning's alarm goes when you're already on the way (`OnTheWay.decide`), said once in the field log and as a
     * notification. `ringing`: the alarm is going off now (`WakeReceiver`): decided as if it were still to come.
     * True when today's alarm is skipped.
     */
    fun checkOnTheWay(c: Context, now: Double = Iso.now(), ringing: Boolean = false): Boolean {
        load(c)
        if (!_config.value.on) return false
        val day = today(now)
        if (day in _going.value) return true
        if (day in keepRinging || day in _skipped.value) return false
        val i = _week.value.indexOfFirst { it.day == day }
        if (i < 0) return false
        val p = _week.value[i]
        val alarm = if (ringing) now + 1 else p.alarm
        val prof = store(c).profile.value
        val ride = nl.haltewekker.ride.RideStore.state.value
        val running = ride != null && !ride.finished
        val fix = nl.haltewekker.ui.Locator.lastFix(c)?.takeIf { it.accuracy < 300 }
        val homeM = fix?.let { f -> prof.home?.let { Geo.metres(nl.haltewekker.core.GeoPoint(f.latitude, f.longitude), it.point) } }
        val live = OnTheWay.Live(running = running, runningToSchool = running && ride != null && towardSchool(c, ride),
            homeMetres = homeM, fixAt = fix?.let { it.time / 1000.0 })
        val d = OnTheWay.decide(day, day, alarm, now, morning(now), OnTheWay.fresh(seen, day), live)
        if (d !is OnTheWay.Decision.Skip) return false
        val words = OnTheWay.words(d.reason, Fmt::time)
        _going.value = _going.value + (day to words); saveGoing(c)
        WakeAlarm.cancel(c, day)
        _week.value = _week.value.toMutableList().also { it[i] = p.copy(alarm = null, alarmSet = false) }
        saveWeek(c)
        FieldLog.init(c)
        FieldLog.ride(OnTheWay.logLine(d.reason, Fmt::time))
        Notifications.school(c, "school-going", "No school alarm today", "You're $words. Turn it back on in Your day.")
        return true
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
