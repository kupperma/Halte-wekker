package nl.haltewekker.ui.screens

import android.Manifest
import android.os.Build
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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import nl.haltewekker.App
import nl.haltewekker.BuildConfig
import nl.haltewekker.motion.StepMotion
import nl.haltewekker.profile.Settings
import nl.haltewekker.profile.SettingsIndex
import nl.haltewekker.profile.SettingsTopic
import nl.haltewekker.profile.TestSetup
import nl.haltewekker.ui.Card
import nl.haltewekker.ui.Note
import nl.haltewekker.ui.QuietButton
import nl.haltewekker.ui.SettingsIcons
import nl.haltewekker.ui.theme.DS

/**
 * Settings (A6, iOS 0.32.1 `SettingsHub.swift`): a "you" card, the nine topics in two lists, each with a thin grey
 * outline icon (no coloured tiles), and a search over every setting (`SettingsIndex`) that opens the setting's page.
 */
@Composable
fun SettingsScreen(onBack: () -> Unit, onSetup: () -> Unit, onTestSetup: () -> Unit, onDay: () -> Unit, onCalendars: () -> Unit, onWeek: () -> Unit,
                   onFriends: () -> Unit = {}, onYear: () -> Unit = {}) {
    var topicName by rememberSaveable { mutableStateOf<String?>(null) }
    val topic = topicName?.let { n -> SettingsTopic.entries.firstOrNull { it.name == n } }
    if (topic != null) {
        TopicPage(topic, onBack = { topicName = null }, onSetup, onTestSetup, onDay, onCalendars, onWeek, onFriends, onYear)
        return
    }
    val testLive by TestSetup.live.collectAsState()
    val app = LocalContext.current.applicationContext as App
    val p by app.store.profile.collectAsState()
    var q by rememberSaveable { mutableStateOf("") }
    BackHandler(onBack = onBack)

    Column(Modifier.fillMaxSize().background(DS.t.page).safeDrawingPadding().verticalScroll(rememberScrollState()).padding(horizontal = 12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = DS.t.text) }
            Text("Settings", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, color = DS.t.text)
        }
        OutlinedTextField(q, { q = it }, Modifier.fillMaxWidth(), singleLine = true, placeholder = { Text("Search settings") },
            leadingIcon = { Icon(Icons.Filled.Search, null, tint = DS.t.secondary) })
        if (q.isNotBlank()) {
            val hits = SettingsIndex.search(q, SettingsIndex.entries(testLive))
            Card(padding = 4) {
                if (hits.isEmpty()) Text("No setting called that.", color = DS.t.secondary, modifier = Modifier.padding(12.dp))
                hits.forEachIndexed { i, e ->
                    if (i > 0) HorizontalDivider(color = DS.t.divider)
                    TopicRow(e.topic, e.title, e.topic.pageTitle) { q = ""; topicName = e.topic.name }
                }
            }
        } else {
            nl.haltewekker.ui.friends.ShareAskCard()
            // the "you" card: school, home, friends
            Card(Modifier.clickable { topicName = SettingsTopic.PLACES.name }) {
                Text(p.school?.name ?: "No school set", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold, color = DS.t.text)
                Text(listOfNotNull(if (p.home != null) "Home set · ${p.homeStops.size} stop${if (p.homeStops.size == 1) "" else "s"}" else "No home set",
                    if (nl.haltewekker.friends.FriendStore.hasAccount) "Friends on" else null).joinToString(" · "), color = DS.t.secondary)
                if (testLive) Note("You're using a test setup.", tint = DS.t.accent)
            }
            for (g in listOf(1, 2)) Card(padding = 4) {
                SettingsTopic.inGroup(g).forEachIndexed { i, t ->
                    if (i > 0) HorizontalDivider(color = DS.t.divider)
                    TopicRow(t, t.title, null) { topicName = t.name }
                }
            }
            Text("Haltewekker for Android ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})", color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
        }
        Spacer(Modifier.height(24.dp))
    }
}

@Composable
private fun TopicRow(t: SettingsTopic, title: String, sub: String?, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 52.dp).clickable(onClick = onClick).padding(horizontal = 12.dp, vertical = 8.dp)
        .semantics { contentDescription = if (sub != null) "$title, in $sub" else title },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        Icon(SettingsIcons.of(t), null, tint = DS.t.secondary, modifier = Modifier.size(24.dp))
        Column(Modifier.weight(1f)) {
            Text(title, color = DS.t.text)
            if (sub != null) Text(sub, color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
        }
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = DS.t.secondary)
    }
}

@Composable
private fun TopicPage(t: SettingsTopic, onBack: () -> Unit, onSetup: () -> Unit, onTestSetup: () -> Unit, onDay: () -> Unit, onCalendars: () -> Unit,
                      onWeek: () -> Unit, onFriends: () -> Unit, onYear: () -> Unit) {
    BackHandler(onBack = onBack)
    val context = LocalContext.current
    val app = context.applicationContext as App
    val s by app.store.settings.collectAsState()
    val p by app.store.profile.collectAsState()
    val testLive by TestSetup.live.collectAsState()
    val ride by nl.haltewekker.ride.RideStore.state.collectAsState()
    fun set(f: (Settings) -> Settings) = app.store.updateSettings(f)
    val askMotion = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok -> set { it.copy(motion = ok) } }

    Column(Modifier.fillMaxSize().background(DS.t.page).safeDrawingPadding().verticalScroll(rememberScrollState()).padding(horizontal = 12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Settings", tint = DS.t.text) }
            Text(t.pageTitle, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, color = DS.t.text)
        }
        when (t) {
            SettingsTopic.TRIPS -> {
                WakeCard()
                Card {
                    Text("Alarm", fontWeight = FontWeight.Bold, color = DS.t.text)
                    Toggle("Sound only with headphones", "Without Bluetooth, wired or USB headphones the alarm only vibrates, so the rest of the train doesn't hear it. Not stopped after a minute? Then it rings out loud anyway.", s.headphonesOnly) { v -> set { it.copy(headphonesOnly = v) } }
                    Toggle("Station announcement", "\"Attention please. We are now approaching …\" before the alarm.", s.announce) { v -> set { it.copy(announce = v) } }
                    Toggle("Chime at the stop", "After the alarm, a chime and a notification at the stop itself.", s.ringAtStop) { v -> set { it.copy(ringAtStop = v) } }
                    Toggle("Backup alarm", "Also rings shortly before the planned arrival when GPS never got you close (a tunnel, a dead GPS).", s.backupAlarm) { v -> set { it.copy(backupAlarm = v) } }
                    // (A7, iOS 0.37.1) Wear OS mirrors the phone's notifications with their actions
                    Text("On a Wear OS watch: the wake-up taps your wrist; tap Stop alarm there. On the lock screen, Stop alarm works without unlocking.",
                        color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
                }
                AutoStartCard()
                Card {
                    val has = StepMotion.available(context)
                    Toggle("Use motion to notice rides faster", if (has) "The phone's step detector: walking or cycling isn't taken for a bus. Only while a trip runs; the alarm never depends on it."
                        else "This phone has no step detector.", s.motion && has) { v ->
                        if (v && Build.VERSION.SDK_INT >= 29 && !StepMotion.permitted(context)) askMotion.launch(Manifest.permission.ACTIVITY_RECOGNITION)
                        else set { it.copy(motion = v && has) }
                    }
                }
                TravelHelpCard()
                HabitsCard()
                PermissionsCard(showExtras = true)
            }
            SettingsTopic.PLACES -> Card {
                Text("Your school and home", fontWeight = FontWeight.Bold, color = DS.t.text)
                Text("School: ${p.school?.name ?: "not set"}", color = DS.t.text)
                Text("Home: ${if (p.home != null) "set (${p.homeStops.size} stops)" else "not set"}", color = DS.t.text)
                p.homeStops.forEach { Text("· ${it.name}", color = DS.t.secondary, style = MaterialTheme.typography.bodySmall) }
                QuietButton("Set up again", onClick = onSetup)
            }
            SettingsTopic.SCHOOL -> SchoolSettingsCard(onDay, onCalendars, onWeek)
            SettingsTopic.FRIENDS -> Card {
                Text("Friends", fontWeight = FontWeight.Bold, color = DS.t.text)
                Text(if (nl.haltewekker.friends.FriendStore.hasAccount) "Your friends, chats, what they see, your backup code, the leaderboard." else "Travel with friends: share trips, chat, compare timetables.",
                    color = DS.t.secondary)
                QuietButton("Open Friends", onClick = onFriends)
                nl.haltewekker.ui.friends.TestFriendSettingsRow()
            }
            SettingsTopic.MAP -> {
                Card {
                    Toggle("Real bus and train positions", "From OVapi and NS, while the map is open or a ride looks for your vehicle. Off: by their timetables (less data).", s.realPositions) { v -> set { it.copy(realPositions = v) } }
                    Toggle("Rain advice for the walk", "From 3 hours before a trip: rain on the walk to the first stop or from the last one (Open-Meteo), with a bus instead of a long walk to the train when there is one.", s.rainAdvice) { v -> set { it.copy(rainAdvice = v) } }
                    Toggle("OV-fiets at the station", "How many NS rental bikes are left where your last train gets in, when a bus or a walk follows it.", s.ovFiets) { v -> set { it.copy(ovFiets = v) } }
                }
                Card {
                    Text("Widget and shortcuts", fontWeight = FontWeight.Bold, color = DS.t.text)
                    Text("Next departures: long-press your home screen › Widgets › Haltewekker, and pick a stop. Tap it for the stop's departures.", color = DS.t.secondary)
                    Text("Shortcuts: long-press the app's icon for When's my bus, Plan to school, Plan home and Start my trip.", color = DS.t.secondary)
                }
            }
            SettingsTopic.NOTIFICATIONS -> Card {
                Toggle("Works and disruptions on my routes", "NS's works and disruptions on your trains between home and school, today and the next 7 days: a card on the home, and a notification at 19:30 the evening before.", s.railWorks) { v -> set { it.copy(railWorks = v) } }
                Toggle("Last way home", "After 20:00 and more than 3 km from home: the latest way home on the home's card, and a notification 30 minutes before it leaves.", s.lastHome) { v -> set { it.copy(lastHome = v) } }
            }
            SettingsTopic.BATTERY -> {
                Card {
                    Toggle("Save battery on long rides", "Far from your stop on a known bus or train: a fix every 25 s instead of every 2 s.", s.roughGPSOnLongRides) { v -> set { it.copy(roughGPSOnLongRides = v) } }
                }
                PermissionsCard(showExtras = true)
            }
            SettingsTopic.SHARE -> nl.haltewekker.ui.friends.LogShareCard()
            SettingsTopic.ADVANCED -> {
                Card {
                    Text("Your year in travel", fontWeight = FontWeight.Bold, color = DS.t.text)
                    Text("Hours on board, kilometres, CO₂ saved, your favourite line: from the rides kept on this phone.", color = DS.t.secondary)
                    QuietButton("Open", onClick = onYear)
                }
                Card {
                    if (testLive) {
                        Note("You're using a test setup.", tint = DS.t.accent)
                        QuietButton("Back to my own setup") { TestSetup.backToOwn(app) }
                    } else if (ride == null) {
                        QuietButton("Test the setup as a new user", onClick = onTestSetup)
                        Text("Try the first-run setup as someone new. Your own setup is kept and comes back with one tap.", color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
                    }
                }
                Card {
                    Text("About and open data", fontWeight = FontWeight.Bold, color = DS.t.text)
                    Text("Haltewekker for Android ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE}), made by ${nl.haltewekker.logs.Maker.NAME}.", color = DS.t.text)
                    Text("Trips and times: Transitous (MOTIS). Live positions: OVapi and NS. Map: OpenFreeMap and MapLibre, © OpenStreetMap contributors. Weather: Open-Meteo. Icons: Material Symbols (Apache 2.0).",
                        color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
                }
            }
        }
        Spacer(Modifier.height(24.dp))
    }
}

@Composable
private fun Toggle(title: String, sub: String, on: Boolean, set: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f).padding(end = 12.dp)) {
            Text(title, color = DS.t.text, fontWeight = FontWeight.SemiBold)
            Text(sub, color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
        }
        Switch(on, set)
    }
}
