package nl.haltewekker.ui.screens

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
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import nl.haltewekker.App
import nl.haltewekker.BuildConfig
import nl.haltewekker.profile.Settings
import nl.haltewekker.ui.Card
import nl.haltewekker.ui.QuietButton
import nl.haltewekker.ui.theme.DS
import kotlin.math.roundToInt

@Composable
fun SettingsScreen(onBack: () -> Unit, onSetup: () -> Unit) {
    val app = LocalContext.current.applicationContext as App
    val s by app.store.settings.collectAsState()
    val p by app.store.profile.collectAsState()
    BackHandler(onBack = onBack)
    fun set(f: (Settings) -> Settings) = app.store.updateSettings(f)

    Column(Modifier.fillMaxSize().background(DS.t.page).safeDrawingPadding().verticalScroll(rememberScrollState()).padding(horizontal = 12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = DS.t.text) }
            Text("Settings", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, color = DS.t.text)
        }
        Card {
            Text("Wake-up distance", fontWeight = FontWeight.Bold, color = DS.t.text)
            Text("Bus: %.1f km before your stop".format(s.busKm), color = DS.t.text)
            Slider(s.busKm.toFloat(), { v -> set { it.copy(busKm = (v * 2).roundToInt() / 2.0) } }, valueRange = 0.5f..10f, steps = 18)
            Text("Train: %.1f km before your stop".format(s.trainKm), color = DS.t.text)
            Slider(s.trainKm.toFloat(), { v -> set { it.copy(trainKm = (v * 2).roundToInt() / 2.0) } }, valueRange = 0.5f..15f, steps = 28)
        }
        Card {
            Text("Alarm", fontWeight = FontWeight.Bold, color = DS.t.text)
            Toggle("Sound only with headphones", "Without Bluetooth, wired or USB headphones the alarm only vibrates, so the rest of the train doesn't hear it. Not stopped after a minute? Then it rings out loud anyway.", s.headphonesOnly) { v -> set { it.copy(headphonesOnly = v) } }
            Toggle("Announce the stop", "\"Attention please. We are now approaching …\" before the alarm.", s.announce) { v -> set { it.copy(announce = v) } }
            Toggle("Tell me when I'm there", "After the alarm, a chime and a notification at the stop itself.", s.ringAtStop) { v -> set { it.copy(ringAtStop = v) } }
            Toggle("Backup alarm by time", "Also rings shortly before the planned arrival when GPS never got you close (a tunnel, a dead GPS).", s.backupAlarm) { v -> set { it.copy(backupAlarm = v) } }
        }
        Card {
            Text("Map and battery", fontWeight = FontWeight.Bold, color = DS.t.text)
            Toggle("Real bus and train positions", "From OVapi and NS, while the map is open or a ride looks for your vehicle. Off: by their timetables (less data).", s.realPositions) { v -> set { it.copy(realPositions = v) } }
            Toggle("Rough GPS on long rides", "Far from your stop on a known bus or train: a fix every 25 s instead of every 2 s.", s.roughGPSOnLongRides) { v -> set { it.copy(roughGPSOnLongRides = v) } }
        }
        PermissionsCard(showExtras = true)
        Card {
            Text("Your places", fontWeight = FontWeight.Bold, color = DS.t.text)
            Text("School: ${p.school?.name ?: "not set"}", color = DS.t.text)
            Text("Home: ${if (p.home != null) "set (${p.homeStops.size} stops)" else "not set"}", color = DS.t.text)
            QuietButton("Set up again", onClick = onSetup)
        }
        Text("Haltewekker for Android ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})", color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
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
