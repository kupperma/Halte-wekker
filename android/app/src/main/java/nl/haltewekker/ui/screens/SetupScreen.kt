package nl.haltewekker.ui.screens

import android.Manifest
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
import nl.haltewekker.ui.BigButton
import nl.haltewekker.ui.Card
import nl.haltewekker.ui.Fmt
import nl.haltewekker.ui.Locator
import nl.haltewekker.ui.Note
import nl.haltewekker.ui.QuietButton
import nl.haltewekker.ui.theme.DS

/**
 * The first-run setup (iOS `SetupFlow`, the A1 part): your school from the bundled list, your home (your location or
 * a search), the stops near home for its board, and what the ride needs from Android.
 */
@Composable
fun SetupScreen(onDone: () -> Unit) {
    val app = LocalContext.current.applicationContext as App
    var step by rememberSaveable { mutableStateOf(0) }
    var school by remember { mutableStateOf<School?>(null) }
    var campus by remember { mutableStateOf<School.Campus?>(null) }
    var home by remember { mutableStateOf<SavedPlace?>(null) }
    val stops = remember { mutableStateListOf<NearStop>() }
    val picked = remember { mutableStateListOf<String>() }

    Column(Modifier.fillMaxSize().background(DS.t.page).safeDrawingPadding().verticalScroll(rememberScrollState()).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Text(listOf("Welcome", "Your school", "Your home", "Stops near home", "Allow the alarm")[step],
            style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold, color = DS.t.text)
        when (step) {
            0 -> {
                Text("Haltewekker plans your trip door to door, shows the buses and trains around you live, and wakes you up before your stop, so you can sleep on the way.",
                    color = DS.t.text)
                Text("Three questions, then you're set. Everything stays on your phone.", color = DS.t.secondary)
                BigButton("Start") { step = 1 }
            }
            1 -> SchoolStep(app.schools, school, campus) { s, c -> school = s; campus = c; step = 2 }
            2 -> HomeStep { h -> home = h; stops.clear(); picked.clear(); step = 3 }
            3 -> {
                val h = home
                LaunchedEffect(h) {
                    if (h != null && stops.isEmpty()) {
                        val got = Transit.stopChoices(h.point) ?: emptyList()
                        stops.addAll(got)
                        got.firstOrNull()?.let { picked.add(it.id) }
                    }
                }
                Text("Pick up to three stops for the departures at home.", color = DS.t.secondary)
                if (stops.isEmpty()) Row(verticalAlignment = Alignment.CenterVertically) {
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
                PermissionsCard(showExtras = true)
                BigButton("Done") {
                    val c = campus; val s = school
                    app.store.setProfile(Profile(
                        setupDone = true, schoolId = s?.id, campus = c?.label,
                        school = if (s != null && c != null) SavedPlace("${s.short} ${c.label}".trim(), c.lat, c.lon) else null,
                        home = home?.copy(stopIds = picked.toList()),
                        homeStops = stops.filter { it.id in picked },
                    ))
                    onDone()
                }
            }
        }
        if (step in 1..4) QuietButton("Back") { step -= 1 }
        Spacer(Modifier.height(24.dp))
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
