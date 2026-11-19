package nl.haltewekker.ui.screens

import android.Manifest
import android.app.TimePickerDialog
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Checkbox
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import nl.haltewekker.App
import nl.haltewekker.auto.Regions
import nl.haltewekker.core.Iso
import nl.haltewekker.data.DoorTrip
import nl.haltewekker.school.Calendars
import nl.haltewekker.school.ManualWeek
import nl.haltewekker.school.PhoneCalendar
import nl.haltewekker.school.Planned
import nl.haltewekker.school.ScheduleSource
import nl.haltewekker.school.SchoolAlarm
import nl.haltewekker.school.SchoolConfig
import nl.haltewekker.school.SchoolHints
import nl.haltewekker.school.WakeAlarm
import nl.haltewekker.ui.BigButton
import nl.haltewekker.ui.Card
import nl.haltewekker.ui.Fmt
import nl.haltewekker.ui.Header
import nl.haltewekker.ui.LegRow
import nl.haltewekker.ui.Note
import nl.haltewekker.ui.QuietButton
import nl.haltewekker.ui.theme.DS

// MARK: small parts

/** A value with − and + (iOS `Stepper`). */
@Composable
fun StepRow(title: String, sub: String?, value: Int, range: IntRange, step: Int, onChange: (Int) -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Column(Modifier.weight(1f)) {
            Text(title, color = DS.t.text, fontWeight = FontWeight.SemiBold)
            if (sub != null) Text(sub, color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
        }
        QuietButton("−") { if (value - step >= range.first) onChange(value - step) }
        QuietButton("+") { if (value + step <= range.last) onChange(value + step) }
    }
}

@Composable
fun SwitchRow(title: String, sub: String?, on: Boolean, set: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f).padding(end = 12.dp)) {
            Text(title, color = DS.t.text, fontWeight = FontWeight.SemiBold)
            if (sub != null) Text(sub, color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
        }
        Switch(on, set)
    }
}

@Composable
private fun TopBar(title: String, onBack: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = DS.t.text) }
        Text(title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, color = DS.t.text)
    }
}

@Composable
fun SubPage(title: String, onBack: () -> Unit, content: @Composable ColumnScope.() -> Unit) {
    BackHandler(onBack = onBack)
    Column(Modifier.fillMaxSize().background(DS.t.page).safeDrawingPadding().verticalScroll(rememberScrollState()).padding(horizontal = 12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        TopBar(title, onBack)
        content()
        Spacer(Modifier.height(24.dp))
    }
}

// MARK: the timetable

/** The phone's calendars to pick the timetable from; the ones that look like it are marked (and picked when none is). */
@Composable
fun CalendarPicker(picked: Set<Long>, schoolNames: List<String>, onChange: (Set<Long>) -> Unit) {
    val c = LocalContext.current
    var granted by remember { mutableStateOf(Calendars.granted(c)) }
    var all by remember { mutableStateOf<List<PhoneCalendar>?>(null) }
    var school by remember { mutableStateOf<Set<Long>>(emptySet()) }
    var tick by remember { mutableIntStateOf(0) }
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted = it; tick++ }
    LifecycleResumeEffect(Unit) { granted = Calendars.granted(c); tick++; onPauseOrDispose {} }
    LaunchedEffect(granted, tick) {
        if (!granted) return@LaunchedEffect
        val (l, s) = withContext(Dispatchers.IO) {
            val l = Calendars.list(c)
            l to Calendars.schoolLike(c, l, SchoolHints.make(schoolNames), Iso.now())
        }
        all = l; school = s
        if (picked.isEmpty() && s.isNotEmpty()) onChange(s)
    }
    if (!granted) {
        Text("Haltewekker reads only the calendars you pick, and only the first class of each day.", color = DS.t.secondary)
        BigButton("Allow calendar access") { ask.launch(Manifest.permission.READ_CALENDAR) }
        return
    }
    val l = all
    when {
        l == null -> Text("Looking at your calendars…", color = DS.t.secondary)
        l.isEmpty() -> Note("No calendars on this phone yet. Add your timetable to a calendar app (or subscribe to your roster link), then come back.")
        else -> Card {
            l.forEach { cal ->
                Row(Modifier.fillMaxWidth().clickable { onChange(if (cal.id in picked) picked - cal.id else picked + cal.id) },
                    verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(cal.id in picked, onCheckedChange = null)
                    Box(Modifier.padding(horizontal = 6.dp).size(12.dp).clip(CircleShape).background(Color(cal.color or 0xFF000000.toInt())))
                    Column(Modifier.weight(1f)) {
                        Text(cal.name, color = DS.t.text, fontWeight = FontWeight.SemiBold)
                        Text(if (cal.id in school) "${cal.account} · looks like your timetable" else cal.account,
                            color = if (cal.id in school) DS.t.accentText else DS.t.secondary, style = MaterialTheme.typography.bodySmall)
                    }
                }
            }
        }
    }
}

/** "Same times every week": a day on or off, its first class, when the last one ends, and its name (iOS `ManualWeekScreen`). */
@Composable
fun WeekEditor(week: ManualWeek, onChange: (ManualWeek) -> Unit) {
    val c = LocalContext.current
    fun pick(m: Int, set: (Int) -> Unit) { TimePickerDialog(c, { _, h, mi -> set(h * 60 + mi) }, m / 60, m % 60, true).show() }
    Card {
        for (wd in listOf(2, 3, 4, 5, 6, 7, 1)) {
            val start = week.minutes(wd)
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Checkbox(start != null, { on -> onChange(week.set(wd, if (on) 8 * 60 + 30 else null)) })
                Text(ManualWeek.dayName(wd), color = DS.t.text, fontWeight = FontWeight.SemiBold, modifier = Modifier.width(40.dp))
                if (start != null) {
                    QuietButton(ManualWeek.clock(start)) { pick(start) { onChange(week.set(wd, it)) } }
                    Text("to", color = DS.t.secondary)
                    val end = week.end(wd)
                    QuietButton(end?.let(ManualWeek::clock) ?: "end?") { pick(end ?: (start + 7 * 60).coerceAtMost(23 * 60)) { onChange(week.setEnd(wd, it)) } }
                    if (end != null) Text("×", color = DS.t.secondary, modifier = Modifier.clickable { onChange(week.setEnd(wd, null)) }.padding(6.dp))
                } else Text("no school", color = DS.t.secondary)
            }
            if (start != null) OutlinedTextField(week.title(wd) ?: "", { onChange(week.setTitle(wd, it)) }, Modifier.fillMaxWidth().padding(start = 48.dp),
                placeholder = { Text("What it is (optional)") }, singleLine = true)
        }
    }
    Text("The first class sets the alarm; the end is for later (friends' timetables). ${ManualWeek.words(week)}.", color = DS.t.secondary,
        style = MaterialTheme.typography.bodySmall)
}

// MARK: Settings

/** Settings › School alarm (iOS `SchoolAlarmSection`). */
@Composable
fun SchoolSettingsCard(onDay: () -> Unit, onCalendars: () -> Unit, onWeek: () -> Unit) {
    val c = LocalContext.current
    val app = c.applicationContext as App
    val cfg by SchoolAlarm.config.collectAsState()
    val week by SchoolAlarm.week.collectAsState()
    val note by SchoolAlarm.note.collectAsState()
    val p by app.store.profile.collectAsState()
    var testAt by remember { mutableStateOf<Double?>(null) }
    var tick by remember { mutableIntStateOf(0) }
    LifecycleResumeEffect(Unit) { tick++; onPauseOrDispose {} }
    fun set(f: (SchoolConfig) -> SchoolConfig) = SchoolAlarm.setConfig(c, f(cfg))
    Card {
        Text("School alarm", fontWeight = FontWeight.Bold, color = DS.t.text)
        SwitchRow("Wake me for school", "From your timetable: the first class of the next school day, the trip there, and an alarm before you have to leave.", cfg.on) { v -> set { it.copy(on = v) } }
        when (p.schedule) {
            ScheduleSource.CALENDARS -> Row(Modifier.fillMaxWidth().clickable(onClick = onCalendars), verticalAlignment = Alignment.CenterVertically) {
                Text("School calendar", color = DS.t.text, modifier = Modifier.weight(1f))
                Text(if (cfg.calendarIds.isEmpty()) "Pick one" else "${cfg.calendarIds.size} picked", color = DS.t.accentText)
            }
            ScheduleSource.MANUAL -> Row(Modifier.fillMaxWidth().clickable(onClick = onWeek), verticalAlignment = Alignment.CenterVertically) {
                Text("Your week", color = DS.t.text, modifier = Modifier.weight(1f))
                Text(ManualWeek.words(p.week ?: ManualWeek()), color = DS.t.accentText)
            }
            ScheduleSource.NONE -> Text("Your timetable isn't set up yet.", color = DS.t.secondary)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (p.schedule != ScheduleSource.CALENDARS) QuietButton("From a calendar") { app.store.updateProfile { it.copy(schedule = ScheduleSource.CALENDARS) }; onCalendars() }
            if (p.schedule != ScheduleSource.MANUAL) QuietButton("Same times every week") {
                app.store.updateProfile { it.copy(schedule = ScheduleSource.MANUAL, week = it.week ?: ManualWeek.workdays) }; onWeek()
            }
        }
        StepRow("At school ${cfg.earlyMinutes} min before class", "Time to walk in and sit down.", cfg.earlyMinutes, SchoolConfig.earlyRange, 5) { v -> set { it.copy(earlyMinutes = v) } }
        StepRow("Wake me ${cfg.wakeMinutes} min before I leave", "Time to get up and ready.", cfg.wakeMinutes, SchoolConfig.wakeRange, 5) { v -> set { it.copy(wakeMinutes = v) } }
        if (cfg.on) {
            SchoolAlarm.next()?.let { n ->
                Text("${SchoolAlarm.dayWord(n.classStart).replaceFirstChar { it.uppercase() }}: ${n.title} at ${Fmt.time(n.classStart)}", color = DS.t.text, fontWeight = FontWeight.SemiBold)
                if (n.alarm != null && n.leave != null) Text("Alarm ${Fmt.time(n.alarm)} · leave ${Fmt.time(n.leave)} · at school ${Fmt.time(n.arrive ?: n.beThere)}", color = DS.t.secondary)
            }
            note?.let { Text(it, color = DS.t.warning) }
            @Suppress("UNUSED_EXPRESSION") tick
            if (!WakeAlarm.exactAllowed(c)) Note("Alarms on the minute aren't allowed: the alarm may ring a few minutes late. Allow them in the permissions below.")
            val onPhone = WakeAlarm.nextOnPhone(c)
            Text(if (onPhone != null) "Next alarm set on this phone: ${SchoolAlarm.shortDay(onPhone)} ${Fmt.time(onPhone)}" else
                if (week.any { it.alarmSet }) "Alarms set: ${week.filter { it.alarmSet }.joinToString(" · ") { "${SchoolAlarm.shortDay(it.classStart)} ${Fmt.time(it.alarm!!)}" }}" else "No alarm set on this phone yet.",
                color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
            QuietButton("Your day", onClick = onDay)
        }
        QuietButton("Test the alarm: it rings in 1 minute") { testAt = WakeAlarm.test(c) }
        testAt?.let { Text("Test alarm set for ${Fmt.time(it)}. Lock your phone and wait: it should ring like an alarm clock.", color = DS.t.accentText, style = MaterialTheme.typography.bodySmall) }
        Text("Only the calendars you pick are read, and only the first class of each day counts.", color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
    }
}

/** Settings › Trips by themselves (iOS autoStart, autoHome), with what it needs from Android. */
@Composable
fun AutoStartCard() {
    val c = LocalContext.current
    val app = c.applicationContext as App
    val s by app.store.settings.collectAsState()
    var tick by remember { mutableIntStateOf(0) }
    LifecycleResumeEffect(Unit) { tick++; Regions.update(c); onPauseOrDispose {} }
    val askOne = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { tick++; Regions.update(c) }
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { tick++ }
    @Suppress("UNUSED_EXPRESSION") tick
    Card {
        Text("Trips by themselves", fontWeight = FontWeight.Bold, color = DS.t.text)
        SwitchRow("Start my trip by itself", "Leave a home stop or school on a bus or train and the trip starts: it finds the one you're on and wakes you before your stop.", s.autoStart) { v ->
            app.store.updateSettings { it.copy(autoStart = v) }; Regions.update(c)
        }
        SwitchRow("Home after school", "Reaching school switches the next trip to home, once a day.", s.autoHome) { v ->
            app.store.updateSettings { it.copy(autoHome = v) }; Regions.update(c)
        }
        if ((s.autoStart || s.autoHome) && !(Perms.location(c) && Perms.background(c))) {
            Note("This needs location \"all the time\": Android then watches a circle around your home stops and school with its own low-power location, and only switches GPS on for a few minutes once you leave one. Nothing is sent anywhere.")
            QuietButton(if (Perms.location(c)) "Allow all the time" else "Allow location") {
                if (!Perms.location(c)) ask.launch(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION))
                else if (android.os.Build.VERSION.SDK_INT >= 29) askOne.launch(Manifest.permission.ACCESS_BACKGROUND_LOCATION)
            }
        } else if (s.autoStart || s.autoHome) {
            val n = Regions.current(c).size
            Text(if (n == 0) "Set your home stops and school to watch them." else "Watching $n place${if (n == 1) "" else "s"}.", color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
            if (!Perms.battery(c)) Text("Tip: allow \"No battery limits\" below, or Android may not let it start the trip from the background.", color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
        }
    }
}

// MARK: Your day

/** The next school day on the home: the alarm, when to leave; tap for Your day. Off: "Wake me for school". */
@Composable
fun SchoolHomeCard(onDay: () -> Unit, onSettings: () -> Unit) {
    val cfg by SchoolAlarm.config.collectAsState()
    val week by SchoolAlarm.week.collectAsState()
    val note by SchoolAlarm.note.collectAsState()
    val n = remember(week) { SchoolAlarm.next() }
    if (!cfg.on) {
        Card(Modifier.clickable(onClick = onSettings)) {
            Header("Wake me for school")
            Text("From your timetable: the trip to your first class, and an alarm an hour before you have to leave.", color = DS.t.secondary)
        }
        return
    }
    Card(Modifier.clickable(onClick = onDay)) {
        if (n == null) { Header("School alarm"); Text(note ?: "Looking at your timetable…", color = DS.t.secondary); return@Card }
        Header("School alarm · ${SchoolAlarm.dayWord(n.classStart)}", "${Fmt.time(n.classStart)} ${n.title}")
        if (n.alarm != null && n.leave != null) Row {
            Stat("ALARM", if (SchoolAlarm.isSkipped(n.day)) "off" else Fmt.time(n.alarm), big = true)
            Spacer(Modifier.weight(1f)); Stat("LEAVE", Fmt.time(n.leave)); Spacer(Modifier.weight(1f)); Stat("AT SCHOOL", Fmt.time(n.arrive ?: n.beThere))
        } else Text("Planning the trip…", color = DS.t.secondary)
    }
}

@Composable
private fun Stat(k: String, v: String, big: Boolean = false) {
    Column {
        Text(k, color = DS.t.secondary, style = MaterialTheme.typography.labelSmall)
        Text(v, color = if (big) DS.t.accentText else DS.t.text, style = if (big) MaterialTheme.typography.headlineMedium else MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
    }
}

/**
 * Your day (iOS Your day and the morning screen): the next school day's class, alarm, when to leave and the trip;
 * that day's alarm off or on; the week. It opens on the alarm's Open.
 */
@Composable
fun DayScreen(onBack: () -> Unit, onSettings: () -> Unit, canStart: Boolean, onStart: (DoorTrip, String) -> Unit) {
    val c = LocalContext.current
    val app = c.applicationContext as App
    val cfg by SchoolAlarm.config.collectAsState()
    val week by SchoolAlarm.week.collectAsState()
    val skipped by SchoolAlarm.skipped.collectAsState()
    val note by SchoolAlarm.note.collectAsState()
    val planning by SchoolAlarm.planning.collectAsState()
    val scope = rememberCoroutineScope()
    var now by remember { mutableDoubleStateOf(Iso.now()) }
    LaunchedEffect(Unit) { app.launch { SchoolAlarm.refresh(c) }; while (true) { now = Iso.now(); delay(20_000) } }
    val n = week.filter { it.classStart > now }.minByOrNull { it.classStart }
    val schoolName = app.store.profile.value.school?.name ?: "School"
    SubPage("Your day", onBack) {
        if (!cfg.on) {
            Card {
                Header("Wake me for school")
                Text("The school alarm is off. Turn it on in Settings: it plans the trip to your first class and wakes you before you have to leave.", color = DS.t.secondary)
                QuietButton("School alarm settings", onClick = onSettings)
            }
            return@SubPage
        }
        if (n == null) { Card { Text(note ?: "No school days planned yet.", color = DS.t.secondary) }; QuietButton("School alarm settings", onClick = onSettings); return@SubPage }
        val morning = n.alarm != null && n.alarm <= now && n.classStart - now < 4 * 3600
        Card {
            if (morning) Text("Good morning", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold, color = DS.t.accentText)
            Text("${SchoolAlarm.dayWord(n.classStart).uppercase()} · FIRST CLASS", color = DS.t.secondary, style = MaterialTheme.typography.labelMedium)
            Text("${Fmt.time(n.classStart)} ${n.title}", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold, color = DS.t.text)
            n.room?.let { Text(it, color = DS.t.secondary) }
            if (n.leave != null) Row {
                Stat("ALARM", if (n.day in skipped) "off" else n.alarm?.let(Fmt::time) ?: "–", big = true)
                Spacer(Modifier.weight(1f)); Stat("LEAVE", Fmt.time(n.leave)); Spacer(Modifier.weight(1f)); Stat("AT SCHOOL", Fmt.time(n.arrive ?: n.beThere))
            }
            when {
                n.leave == null -> Text(if (planning) "Planning the trip…" else note ?: "No trip found yet.", color = DS.t.secondary)
                n.leave < now -> Text("You should be on your way: you had to leave at ${Fmt.time(n.leave)}.", color = DS.t.warning)
                n.alarm != null && n.alarm < now -> Text("Leave ${Fmt.inMinutes(n.leave, now)} (at ${Fmt.time(n.leave)}).", color = DS.t.warning, fontWeight = FontWeight.SemiBold)
                n.day in skipped -> Text("No alarm this day: you turned it off.", color = DS.t.secondary)
                n.alarmSet -> Text("The alarm is set: it rings like an alarm clock, also on silent.", color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
            }
            if (n.alarm == null || n.alarm > now) SwitchRow("Wake me this day", "Off: only this day's alarm goes; the trip stays planned.", n.day !in skipped) { on ->
                SchoolAlarm.setSkipped(c, n.day, !on)
            }
        }
        n.trip?.let { t ->
            Card {
                Header("The trip", "${Fmt.time(t.start)} → ${Fmt.time(t.end)}")
                t.rides.forEach { LegRow(it) }
                if (t.walkAfter > 0) Text("Walk ${t.walkAfter} min to school", color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
                if (canStart && t.first.departure - now < 90 * 60 && t.first.departure > now - 10 * 60) BigButton("I'm on it: start the ride") { onStart(t, schoolName) }
            }
        }
        val days = week.filter { it.classStart > now - 12 * 3600 }
        if (days.size > 1) Card {
            Header("This week")
            days.forEach { p -> WeekRow(p, p.day in skipped, now) { on -> SchoolAlarm.setSkipped(c, p.day, !on) } }
            Text("Each day's alarm moves with the buses until it has rung; then it's left alone.", color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            QuietButton(if (planning) "Planning…" else "Plan again") { scope.launch { SchoolAlarm.refresh(c, force = true) } }
            QuietButton("School alarm settings", onClick = onSettings)
        }
    }
}

@Composable
private fun WeekRow(p: Planned, off: Boolean, now: Double, set: (Boolean) -> Unit) {
    val rang = p.rang(now)
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(SchoolAlarm.shortDay(p.classStart), color = DS.t.text, fontWeight = FontWeight.SemiBold, modifier = Modifier.width(40.dp))
        Column(Modifier.weight(1f)) {
            Text("${Fmt.time(p.classStart)} ${p.title}", color = DS.t.text, maxLines = 1)
            Text(listOfNotNull(p.leave?.let { "leave ${Fmt.time(it)}" }, p.lines).joinToString(" · "), color = DS.t.secondary, style = MaterialTheme.typography.bodySmall, maxLines = 1)
        }
        Text(when { off -> "off"; rang -> "rang"; else -> p.alarm?.let(Fmt::time) ?: "–" },
            color = when { off -> DS.t.secondary; rang -> DS.t.secondary; p.alarmSet -> DS.t.accentText; else -> DS.t.warning }, fontWeight = FontWeight.SemiBold)
        if (!rang) Switch(!off, set)
    }
}

/** Settings › School calendar. */
@Composable
fun CalendarsScreen(onBack: () -> Unit) {
    val c = LocalContext.current
    val app = c.applicationContext as App
    val cfg by SchoolAlarm.config.collectAsState()
    val names = remember { app.store.profile.value.schoolId?.let { id -> app.schools.firstOrNull { it.id == id } }?.let { listOf(it.short, it.name) } ?: emptyList() }
    SubPage("School calendar", onBack) {
        CalendarPicker(cfg.calendarIds.toSet(), names) { SchoolAlarm.setConfig(c, cfg.copy(calendarIds = it.toList())) }
        Text("Pick your school timetable. The first class of each day in it sets the alarm; nothing else is read.", color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
    }
}

/** Settings › Your week. */
@Composable
fun WeekScreen(onBack: () -> Unit) {
    val c = LocalContext.current
    val app = c.applicationContext as App
    val p by app.store.profile.collectAsState()
    SubPage("Your week", { app.launch { SchoolAlarm.refresh(c, force = true) }; onBack() }) {
        WeekEditor(p.week ?: ManualWeek.workdays) { w -> app.store.updateProfile { it.copy(week = w, schedule = ScheduleSource.MANUAL) } }
    }
}
