package nl.haltewekker.ui.screens

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import nl.haltewekker.App
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.data.NearStop
import nl.haltewekker.data.PlaceHit
import nl.haltewekker.data.Transit
import nl.haltewekker.profile.Profile
import nl.haltewekker.profile.SavedPlace
import nl.haltewekker.profile.School
import nl.haltewekker.profile.SchoolCatalog
import nl.haltewekker.profile.SetupLogic
import nl.haltewekker.profile.TestSetup
import nl.haltewekker.auto.Regions
import nl.haltewekker.school.ManualWeek
import nl.haltewekker.school.ScheduleSource
import nl.haltewekker.school.SchoolAlarm
import nl.haltewekker.school.SchoolConfig
import nl.haltewekker.ui.BigButton
import nl.haltewekker.ui.Card
import nl.haltewekker.ui.Fmt
import nl.haltewekker.ui.Locator
import nl.haltewekker.ui.Note
import nl.haltewekker.ui.QuietButton
import nl.haltewekker.ui.theme.DS

/** Where the setup's timetable comes from (iOS `TimetableChoice`). */
enum class TimetableChoice { CALENDARS, LINK, MANUAL, LATER }

/**
 * The first-run setup (iOS `SetupFlow`): your school from the bundled list, your home (your location or a search),
 * the stops near home, your timetable (a calendar, a roster link, the same times every week, or later), your mornings
 * (how early, when to wake, the school alarm on or off), what the alarms need from Android, and a summary. Nothing is
 * saved until Done. `test`: "Test the setup as a new user" (it starts empty; your own setup is kept to go back to).
 */
@Composable
fun SetupScreen(test: Boolean = false, onDone: () -> Unit, onCancel: (() -> Unit)? = null) {
    val context = LocalContext.current
    val app = context.applicationContext as App
    val own = remember { if (test) Profile() else app.store.profile.value }
    val ownCfg = remember { if (test) SchoolConfig() else SchoolAlarm.config.value }
    var step by rememberSaveable { mutableStateOf(0) }
    var school by remember { mutableStateOf(own.schoolId?.let { id -> app.schools.firstOrNull { it.id == id } }) }
    var campus by remember { mutableStateOf(school?.campuses?.firstOrNull { it.label == own.campus }) }
    var home by remember { mutableStateOf(own.home) }
    val stops = remember { mutableStateListOf<NearStop>().also { it.addAll(own.homeStops) } }
    val picked = remember { mutableStateListOf<String>().also { l -> l.addAll(own.homeStops.map { it.id }) } }
    var timetable by remember { mutableStateOf(when (own.schedule) { ScheduleSource.CALENDARS -> TimetableChoice.CALENDARS; ScheduleSource.MANUAL -> TimetableChoice.MANUAL; else -> if (own.setupDone) TimetableChoice.LATER else null } ) }
    var week by remember { mutableStateOf(own.week ?: ManualWeek.workdays) }
    var calendarIds by remember { mutableStateOf(ownCfg.calendarIds.toSet()) }
    var early by remember { mutableStateOf(ownCfg.earlyMinutes) }
    var wake by remember { mutableStateOf(ownCfg.wakeMinutes) }
    var wakeOn by remember { mutableStateOf(ownCfg.on) }
    val titles = listOf("Welcome", "Your school", "Your home", "Stops near home", "Your timetable", "Mornings", "Allow the alarms", "All set")
    BackHandler(enabled = step > 0) { step -= 1 }

    fun schedule(): ScheduleSource = when (timetable) {
        TimetableChoice.CALENDARS, TimetableChoice.LINK -> ScheduleSource.CALENDARS
        TimetableChoice.MANUAL -> if (week.isEmpty) ScheduleSource.NONE else ScheduleSource.MANUAL
        else -> ScheduleSource.NONE
    }
    fun timetableWords(): String {
        val n = calendarIds.size
        val cals = if (n == 0) "no calendar picked yet" else if (n == 1) "1 calendar" else "$n calendars"
        return when (timetable) {
            TimetableChoice.CALENDARS -> "On this phone · $cals"
            TimetableChoice.LINK -> "Roster link · $cals"
            TimetableChoice.MANUAL -> "Same times every week · ${ManualWeek.words(week)}"
            else -> "Later"
        }
    }
    fun finish() {
        val c = campus; val s = school
        if (test) TestSetup.beforeDone(context)
        val sch = schedule()
        app.store.setProfile(Profile(
            setupDone = true, schoolId = s?.id, campus = c?.label,
            school = if (s != null && c != null) SavedPlace("${s.short} ${c.label}".trim(), c.lat, c.lon) else own.school,
            home = home?.copy(stopIds = picked.toList()),
            homeStops = stops.filter { it.id in picked },
            schedule = sch, week = if (timetable == TimetableChoice.MANUAL) week else own.week,
        ))
        SchoolAlarm.setConfig(context, SchoolConfig(on = wakeOn && sch != ScheduleSource.NONE,
            calendarIds = if (sch == ScheduleSource.CALENDARS) calendarIds.toList() else emptyList(), earlyMinutes = early, wakeMinutes = wake))
        if (test) TestSetup.done(context)
        Regions.update(context)
        onDone()
    }

    Column(Modifier.fillMaxSize().background(DS.t.page).safeDrawingPadding().verticalScroll(rememberScrollState()).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)) {
        if (test) Note("Testing the setup as a new user: your own setup is kept, and comes back with \"Back to my own\" in Settings.", tint = DS.t.accent)
        if (step > 0) Text("Step $step of ${titles.size - 1}", color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
        Text(titles[step], style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold, color = DS.t.text)
        when (step) {
            0 -> {
                Text("Haltewekker plans your trip door to door, shows the buses and trains around you live, and wakes you up before your stop, so you can sleep on the way.",
                    color = DS.t.text)
                Text("It can also read your timetable and wake you in the morning, in time for the bus to your first class. Everything stays on your phone.", color = DS.t.secondary)
                BigButton("Start") { step = 1 }
            }
            1 -> {
                val s = school; val c = campus
                if (s != null && c != null) BigButton("Keep ${s.short} ${c.label}") { step = 2 }
                SchoolStep(app.schools, school, campus) { a, b -> school = a; campus = b; step = 2 }
            }
            2 -> {
                if (home != null) BigButton("Keep this home") { step = 3 }
                HomeStep { h -> home = h; stops.clear(); picked.clear(); step = 3 }
            }
            3 -> {
                val h = home
                LaunchedEffect(h) {
                    if (h != null && stops.isEmpty()) {
                        val got = Transit.stopChoices(h.point) ?: emptyList()
                        stops.addAll(got)
                        got.firstOrNull()?.let { picked.add(it.id) }
                    }
                }
                Text("Pick up to three stops for the departures at home. Leaving one on a bus can start your trip by itself.", color = DS.t.secondary)
                if (stops.isEmpty() && h != null) Row(verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.padding(8.dp)); Text("Looking for stops…", color = DS.t.secondary)
                }
                Card {
                    stops.forEach { s ->
                        Row(Modifier.fillMaxWidth().clickable {
                            if (s.id in picked) picked.remove(s.id) else if (picked.size < 3) picked.add(s.id)
                        }, verticalAlignment = Alignment.CenterVertically) {
                            Checkbox(s.id in picked, onCheckedChange = null)
                            Column(Modifier.weight(1f).padding(start = 8.dp)) {
                                Text(s.name, color = DS.t.text, fontWeight = FontWeight.SemiBold)
                                Text("${Fmt.metres(s.meters)}${if (s.rail) " · station" else ""}", color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
                            }
                        }
                    }
                }
                BigButton(if (picked.isEmpty()) "Skip" else "Next") { step = 4 }
            }
            4 -> {
                TimetableStep(timetable, { timetable = it }, week, { week = it }, calendarIds, { calendarIds = it },
                    listOfNotNull(school?.short, school?.name))
                BigButton(if (timetable == null) "Later" else "Next") { if (timetable == null) timetable = TimetableChoice.LATER; step = 5 }
            }
            5 -> {
                Text("How the school alarm plans your mornings. You can change these any time in Settings › School alarm.", color = DS.t.text)
                Card {
                    StepRow("Be there $early min before class", "Time to walk in and sit down.", early, SchoolConfig.earlyRange, 5) { early = it }
                    StepRow("Wake me $wake min before I leave", "Time to get up and ready.", wake, SchoolConfig.wakeRange, 5) { wake = it }
                }
                Card {
                    SwitchRow("Wake me for school", "An alarm before you have to leave for your first class, moved when the buses change.", wakeOn) { wakeOn = it }
                }
                if (wakeOn && schedule() == ScheduleSource.NONE) Note("It needs your timetable to know your first class: go back a step, or set it later in Settings › School alarm.")
                BigButton("Next") { step = 6 }
            }
            6 -> {
                PermissionsCard(showExtras = true)
                BigButton("Next") { step = 7 }
            }
            7 -> {
                Text(if (test) "This is what a new student has now. Try it for real: trips, the board and the school alarm use this test setup until you go back to your own."
                    else "That's all it needs. Change any of it later in Settings.", color = DS.t.text)
                Card {
                    Summary("Your school", school?.let { s -> "${s.short} ${campus?.label ?: ""}".trim() } ?: "Not set") { step = 1 }
                    Summary("Your home", if (home != null) "Set · ${picked.size} stop${if (picked.size == 1) "" else "s"}" else "Not set") { step = 2 }
                    Summary("Timetable", timetableWords()) { step = 4 }
                    Summary("Mornings", "At school $early min early · wake $wake min before you leave · school alarm ${if (wakeOn && schedule() != ScheduleSource.NONE) "on" else "off"}") { step = 5 }
                }
                BigButton("Done", enabled = school != null && home != null) { finish() }
                if (school == null || home == null) Text("Your school and home are needed.", color = DS.t.warning)
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (step in 1..7) QuietButton("Back") { step -= 1 }
            if (onCancel != null) QuietButton("Cancel") { onCancel() }
        }
        Spacer(Modifier.height(24.dp))
    }
}

@Composable
private fun Summary(title: String, value: String, onClick: () -> Unit) {
    Column(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 4.dp)) {
        Text(title, color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
        Text(value, color = DS.t.text, fontWeight = FontWeight.SemiBold)
    }
}

/** The timetable step: a calendar on the phone, a roster link (subscribed in a calendar app), your week, or later. */
@Composable
private fun TimetableStep(choice: TimetableChoice?, setChoice: (TimetableChoice) -> Unit, week: ManualWeek, setWeek: (ManualWeek) -> Unit,
                          calendarIds: Set<Long>, setCalendars: (Set<Long>) -> Unit, schoolNames: List<String>) {
    val context = LocalContext.current
    Text("The school alarm needs your first class of each day. Where is your timetable?", color = DS.t.text)
    Choice("A calendar on this phone", "Google, Outlook, your school's app: any calendar synced to Android", choice == TimetableChoice.CALENDARS) { setChoice(TimetableChoice.CALENDARS) }
    Choice("I have a roster link", "An iCal or webcal link from your school's timetable site", choice == TimetableChoice.LINK) { setChoice(TimetableChoice.LINK) }
    Choice("Same times every week", "Your first class each weekday", choice == TimetableChoice.MANUAL) { setChoice(TimetableChoice.MANUAL) }
    Choice("Later", "Skip it for now: trips and the stop alarm work without it", choice == TimetableChoice.LATER) { setChoice(TimetableChoice.LATER) }
    when (choice) {
        TimetableChoice.CALENDARS -> CalendarPicker(calendarIds, schoolNames, setCalendars)
        TimetableChoice.LINK -> {
            var link by rememberSaveable { mutableStateOf("") }
            var noApp by remember { mutableStateOf(false) }
            val url = SetupLogic.webcalUrl(link)
            OutlinedTextField(link, { link = it }, Modifier.fillMaxWidth(), label = { Text("https://… or webcal://…") }, singleLine = true)
            if (link.isNotBlank() && url == null) Text("That doesn't look like a web link.", color = DS.t.warning)
            if (url != null) BigButton("Subscribe in your calendar app") {
                try { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); noApp = false }
                catch (_: ActivityNotFoundException) { noApp = true }
            }
            if (noApp && url != null) {
                Note("No app on this phone subscribes to calendar links. Install ICSx⁵ (free, F-Droid or Play Store) and open the link again, or add it in Google Calendar on the web (Other calendars › From URL). Then pick the new calendar below.")
                QuietButton("Copy the link") {
                    context.getSystemService(ClipboardManager::class.java)?.setPrimaryClip(ClipData.newPlainText("Roster", SetupLogic.httpsUrl(url)))
                }
            }
            Text("Your calendar app refreshes a subscribed calendar on its own schedule, so a change to your roster can take a while to show here. Once it's there, pick it:",
                color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
            CalendarPicker(calendarIds, schoolNames, setCalendars)
        }
        TimetableChoice.MANUAL -> WeekEditor(week, setWeek)
        TimetableChoice.LATER -> Text("You can set it up later in Settings › School alarm.", color = DS.t.secondary)
        null -> {}
    }
}

@Composable
private fun SchoolStep(list: List<School>, school: School?, campus: School.Campus?, onPick: (School, School.Campus) -> Unit) {
    var q by rememberSaveable { mutableStateOf("") }
    var chosen by remember { mutableStateOf(school) }
    val hits = remember(q) { SchoolCatalog.search(q, list) }
    val c = chosen
    if (c != null && c.campuses.size > 1) {
        Text("Which campus of ${c.short}?", color = DS.t.text)
        c.campuses.forEach { cp ->
            Choice(cp.label, cp.city, campus == cp) { onPick(c, cp) }
        }
        QuietButton("Another school") { chosen = null }
        return
    }
    OutlinedTextField(q, { q = it }, Modifier.fillMaxWidth(), label = { Text("School, university or city") }, singleLine = true)
    if (q.isBlank()) Text("${list.size} schools and universities in the Netherlands. Type a name (\"BUas\", \"Fontys Venlo\", \"TU/e\").", color = DS.t.secondary)
    hits.forEach { h ->
        Choice(h.school.name, h.campuses.joinToString(", ") { it.label }) {
            if (h.campuses.size == 1) onPick(h.school, h.campuses[0]) else chosen = h.school.copy(campuses = h.campuses)
        }
    }
}

@Composable
private fun HomeStep(onPick: (SavedPlace) -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var q by rememberSaveable { mutableStateOf("") }
    var hits by remember { mutableStateOf<List<PlaceHit>>(emptyList()) }
    var busy by remember { mutableStateOf(false) }
    var trouble by remember { mutableStateOf<String?>(null) }
    fun useHere() {
        scope.launch {
            busy = true
            val p = Locator.last(context) ?: withTimeoutOrNull(20_000) { Locator.updates(context, 1000, 0f).first() }?.let { GeoPoint(it.latitude, it.longitude) }
            busy = false
            if (p == null) trouble = "No location yet. Try outside, or search for your address."
            else onPick(SavedPlace("Home", p.lat, p.lon))
        }
    }
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { r ->
        if (r.values.any { it }) useHere() else trouble = "Without location, search for your address instead."
    }
    Text("Where do you leave from? It's only saved on this phone.", color = DS.t.secondary)
    BigButton(if (busy) "Finding you…" else "Use my location", enabled = !busy) {
        if (Locator.granted(context)) useHere()
        else ask.launch(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION))
    }
    trouble?.let { Note(it) }
    OutlinedTextField(q, { q = it }, Modifier.fillMaxWidth(), label = { Text("Or search: street and number, or a stop") }, singleLine = true)
    LaunchedEffect(q) {
        if (q.trim().length < 3) { hits = emptyList(); return@LaunchedEffect }
        delay(400)
        hits = Transit.findPlaces(q.trim(), Locator.last(context))
    }
    hits.forEach { h -> Choice(h.name, listOf(h.town, h.kind).filter { it.isNotEmpty() }.joinToString(" · ")) { onPick(SavedPlace("Home", h.lat, h.lon)) } }
}

@Composable
fun Choice(title: String, sub: String, selected: Boolean = false, onClick: () -> Unit) {
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(if (selected) DS.t.accentSoft else DS.t.surface)
        .clickable(onClick = onClick).padding(14.dp)) {
        Text(title, color = DS.t.text, fontWeight = FontWeight.SemiBold)
        if (sub.isNotEmpty()) Text(sub, color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
    }
}
