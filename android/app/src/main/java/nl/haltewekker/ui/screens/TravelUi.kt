package nl.haltewekker.ui.screens

import android.content.Intent
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
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
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import nl.haltewekker.App
import nl.haltewekker.core.Iso
import nl.haltewekker.data.DoorTrip
import nl.haltewekker.friends.NSCodes
import nl.haltewekker.ride.Notifications
import nl.haltewekker.ride.WakeBy
import nl.haltewekker.ride.WakeRule
import nl.haltewekker.ride.WakeSettings
import nl.haltewekker.travel.HabitStore
import nl.haltewekker.travel.Habits
import nl.haltewekker.travel.OVFiets
import nl.haltewekker.travel.RailWorks
import nl.haltewekker.travel.StudentOV
import nl.haltewekker.travel.TravelLogStore
import nl.haltewekker.travel.TravelNotes
import nl.haltewekker.travel.TravelYear
import nl.haltewekker.ui.Card
import nl.haltewekker.ui.Header
import nl.haltewekker.ui.Note
import nl.haltewekker.ui.QuietButton
import nl.haltewekker.ui.friends.SwitchRow
import nl.haltewekker.ui.theme.DS
import java.time.ZoneId
import kotlin.math.roundToInt

// (A6) the screens' parts for iOS 0.33–0.37: the wake setting, the trip's notes (student OV, a change's record, rain,
// OV-fiets), the home's cards (works, the last way home, your year in travel), learned from your rides, your year.

private fun hhmm(t: Double) = Notifications.time(t)

/** Settings › Trips & alarm › "Wake me … before my stop" and the usual wake distances (the safety net). */
@Composable
fun WakeCard() {
    val app = LocalContext.current.applicationContext as App
    val s by app.store.settings.collectAsState()
    fun setWake(f: (WakeSettings) -> WakeSettings) = app.store.updateSettings { it.copy(wake = f(it.wake)) }
    Card {
        Header("Wake me … before my stop")
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            FilterChip(s.wake.by == WakeBy.TIME, { setWake { it.copy(by = WakeBy.TIME) } }, label = { Text("By time") })
            FilterChip(s.wake.by == WakeBy.DISTANCE, { setWake { it.copy(by = WakeBy.DISTANCE) } }, label = { Text("By distance") })
        }
        if (s.wake.by == WakeBy.TIME) {
            Text("By train: ${s.wake.trainMinutes} min before your stop", color = DS.t.text)
            Slider(s.wake.trainMinutes.toFloat(), { v -> setWake { it.copy(trainMinutes = WakeSettings.clamp(v.roundToInt())) } }, valueRange = 1f..10f, steps = 8)
            Text("By bus: ${s.wake.busMinutes} min before your stop", color = DS.t.text)
            Slider(s.wake.busMinutes.toFloat(), { v -> setWake { it.copy(busMinutes = WakeSettings.clamp(v.roundToInt())) } }, valueRange = 1f..10f, steps = 8)
            Text("By the stop's live arrival while it's fresh, else your speed along the route. The distance below still rings if it comes first.",
                color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
        }
        Text("Bus: ${WakeRule.distanceWords(s.busKm * 1000)} before your stop", color = DS.t.text)
        Slider(s.busKm.toFloat(), { v -> app.store.updateSettings { it.copy(busKm = (v * 2).roundToInt() / 2.0) } }, valueRange = 0.5f..10f, steps = 18)
        Text("Train: ${WakeRule.distanceWords(s.trainKm * 1000)} before your stop", color = DS.t.text)
        Slider(s.trainKm.toFloat(), { v -> app.store.updateSettings { it.copy(trainKm = (v * 2).roundToInt() / 2.0) } }, valueRange = 0.5f..15f, steps = 28)
    }
}

/** Settings › Trips & alarm: the student travel product, the check-out reminder, money back for a late train. */
@Composable
fun TravelHelpCard() {
    val app = LocalContext.current.applicationContext as App
    val s by app.store.settings.collectAsState()
    Card {
        Header("Student travel product")
        StudentOV.Product.entries.forEach { p ->
            FilterChip(s.studentOV == p.raw, { app.store.updateSettings { it.copy(studentOV = p.raw) } }, label = { Text(p.title) })
        }
        Text("DUO's windows: when a ride is free, at a discount or full fare, on plan options (40% off trains, 34% off buses).",
            color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
        SwitchRow("Check-out reminder", "“Did you check out?” a minute after you get off where the card wants it: at the end, off a bus, between bus and train. The app can't see your card.",
            s.checkOut) { v -> app.store.updateSettings { it.copy(checkOut = v) } }
        SwitchRow("Money back for a late train", "Once, after a trip whose trains got you there 30 min late or more, with a tap to NS's claim page.",
            s.delayClaim) { v -> app.store.updateSettings { it.copy(delayClaim = v) } }
    }
}

/** Settings › Trips & alarm › Learned from your rides (iOS 0.34): the three values and "Reset what it learned". */
@Composable
fun HabitsCard() {
    val c = LocalContext.current
    LaunchedEffect(Unit) { HabitStore.load(c) }
    val b by HabitStore.book.collectAsState()
    Card {
        Header("Learned from your rides")
        Habits.rows(b).forEach { r ->
            Row(Modifier.fillMaxWidth()) {
                Text(r.label, color = DS.t.text, modifier = Modifier.weight(1f))
                Text(r.value, color = DS.t.secondary)
            }
        }
        Text("On this phone only: your walking speed goes to the planner, your change time and the stops you prefer to the choice of trips.",
            color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
        if (!b.isEmpty) QuietButton("Reset what it learned") { HabitStore.reset() }
    }
}

/** Under a trip on the plan: student OV, how a change went before, rain on the walk, OV-fiets at the last train's station. */
@Composable
fun TripNotes(t: DoorTrip, others: List<DoorTrip>, now: Double) {
    val c = LocalContext.current
    val app = c.applicationContext as App
    val s by app.store.settings.collectAsState()
    var student by remember(t.id) { mutableStateOf<String?>(null) }
    var rain by remember(t.id) { mutableStateOf<String?>(null) }
    var bikes by remember(t.id) { mutableStateOf<OVFiets.Answer?>(null) }
    var bikeAt by remember(t.id) { mutableStateOf("") }
    LaunchedEffect(t.id, s.studentOV, s.rainAdvice, s.ovFiets) {
        HabitStore.load(c)
        val product = StudentOV.Product.of(s.studentOV)
        if (product != StudentOV.Product.NONE) {
            val codes = NSCodes.get(c)
            val trains = t.rides.filter { it.isTrain }
            val cents = if (trains.isNotEmpty()) {
                val a = codes.code(trains.first().fromId, trains.first().fromStop); val b = codes.code(trains.last().toStop)
                if (a != null && b != null) TravelNotes.price(a, b, trains.first().departure) else null
            } else null
            student = StudentOV.tripLine(product, t.rides.map { it.isTrain to it.departure }, cents)
        } else student = null
        rain = if (s.rainAdvice) TravelNotes.rainLine(t, others, Iso.now()) { hhmm(it) } else null
        if (s.ovFiets) {
            val codes = NSCodes.get(c)
            val code = OVFiets.station(t.rides.map { OVFiets.Ride(it.isTrain, if (it.isTrain) codes.code(it.toStop) else null) }, t.walkAfter)
            if (code != null) { bikes = TravelNotes.bikes(code); bikeAt = codes.station(code)?.name ?: code }
        }
    }
    student?.let { Text(it, color = if (it.startsWith("Free")) DS.t.accentText else DS.t.text, style = MaterialTheme.typography.bodySmall) }
    val changes = (1 until t.rides.size).mapNotNull { i -> HabitStore.changeWords(t, i)?.let { t.rides[i].fromStop to it } }
    changes.forEach { (at, w) -> Text(if (t.rides.size > 2) "At $at: $w" else w.replaceFirstChar { it.uppercase() }, color = DS.t.secondary, style = MaterialTheme.typography.bodySmall) }
    rain?.let { Note(it, tint = DS.t.accent) }
    bikes?.let { a -> OVFiets.text(a)?.let { Text("$bikeAt · $it", color = if (OVFiets.low(a)) DS.t.warning else DS.t.secondary, style = MaterialTheme.typography.bodySmall) } }
}

/** The home's cards (iOS 0.36–0.37): works on your routes today or tomorrow, the last way home, your year in travel. */
@Composable
fun HomeTravelCards(here: nl.haltewekker.core.GeoPoint?, onYear: () -> Unit) {
    val c = LocalContext.current
    val works by TravelNotes.works.collectAsState()
    val last by TravelNotes.lastHome.collectAsState()
    var year by remember { mutableStateOf<Int?>(null) }
    LaunchedEffect(here == null) { TravelNotes.refresh(c, here); year = TravelLogStore.seasonal(c) }
    val now = Iso.now()
    val soon = works.filter { RailWorks.dayWord(it.dayStart, now).let { w -> w == "Today" || w == "Tomorrow" } }
    if (soon.isNotEmpty()) Card {
        Header("Works on your route")
        soon.take(2).forEach { Text(RailWorks.headline(it, now, null), color = DS.t.text) }
    }
    last?.let { o -> Card { Header("Last way home"); Text(nl.haltewekker.travel.LastTrip.cardText(o) { hhmm(it) }, color = DS.t.text) } }
    year?.let { y ->
        Card {
            Header("Your year in travel", "$y")
            Text("Hours on board, kilometres, CO₂ saved and your favourite line.", color = DS.t.secondary)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                QuietButton("Open", onClick = onYear)
                QuietButton("Not now") { TravelLogStore.dismiss(c, y); year = null }
            }
        }
    }
}

/** Your year in travel (Settings › Advanced, and the home's card in December): on this phone only. */
@Composable
fun YearScreen(onBack: () -> Unit) {
    val c = LocalContext.current
    BackHandler(onBack = onBack)
    val zone = ZoneId.systemDefault()
    val cards = remember { TravelYear.cards(TravelLogStore.stats(c), zone) }
    Column(Modifier.fillMaxSize().background(DS.t.page).safeDrawingPadding().verticalScroll(rememberScrollState()).padding(horizontal = 12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = DS.t.text) }
            Text(cards.firstOrNull()?.title ?: "Your year in travel", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, color = DS.t.text)
        }
        if (cards.isEmpty()) Text("Nothing yet: your rides from now on count here (kept on this phone only).", color = DS.t.secondary)
        cards.forEach { y ->
            Card {
                Text(y.title, color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
                Text(y.value, style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold, color = DS.t.text)
                Text(y.sub, color = DS.t.text)
            }
        }
        if (cards.isNotEmpty()) QuietButton("Share") {
            // the shared words leave out every place (iOS shares a picture with the same words)
            val text = cards.joinToString("\n") { "${it.title}: ${it.value}" + if (it.id == "intro" || it.id == "early" || it.id == "delay") "" else " — ${it.shareSub ?: it.sub}" } + "\n— Haltewekker"
            c.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text), "Share your year"))
        }
        Text("CO₂ saved against driving alone: car 0.19 kg/km, bus 0.05, train 0.02 (co2emissiefactoren.nl, EEA). Kilometres are the straight line × 1.3 by bus, × 1.15 by train.",
            color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
        Spacer(Modifier.height(24.dp))
    }
}
