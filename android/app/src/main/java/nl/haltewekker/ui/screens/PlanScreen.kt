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
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.delay
import nl.haltewekker.App
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.core.Iso
import nl.haltewekker.data.DoorTrip
import nl.haltewekker.data.PlaceHit
import nl.haltewekker.data.Transit
import nl.haltewekker.data.TransitParse
import nl.haltewekker.profile.SavedPlace
import nl.haltewekker.ui.BigButton
import nl.haltewekker.ui.Card
import nl.haltewekker.ui.Direction
import nl.haltewekker.ui.Fmt
import nl.haltewekker.ui.LegRow
import nl.haltewekker.ui.Locator
import nl.haltewekker.ui.Note
import nl.haltewekker.ui.TripRow
import nl.haltewekker.ui.theme.DS

/**
 * Fastest trip and Plan (iOS `GoNew`, the A1 part): from where you are (or home, without a location) to school, home or
 * any place you search, the trips worth taking, soonest first; pick one and start the ride. While open it plans again
 * every 40 s (20 s within 12 minutes of leaving, as iOS `GoPace`); nothing runs when it's closed.
 */
@Composable
fun PlanScreen(start: Direction?, canStart: Boolean, onBack: () -> Unit, onStart: (DoorTrip, String) -> Unit) {
    val context = LocalContext.current
    val app = context.applicationContext as App
    val profile by app.store.profile.collectAsState()
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    BackHandler(onBack = onBack)

    var dest by remember { mutableStateOf(start?.let { if (it == Direction.TO_SCHOOL) profile.school else profile.home } ?: profile.school ?: profile.home) }
    var searching by rememberSaveable { mutableStateOf(false) }
    var q by rememberSaveable { mutableStateOf("") }
    var hits by remember { mutableStateOf<List<PlaceHit>>(emptyList()) }
    var trips by remember { mutableStateOf<List<DoorTrip>>(emptyList()) }
    var loading by remember { mutableStateOf(false) }
    var asked by remember { mutableStateOf(false) }
    var selected by remember { mutableStateOf<String?>(null) }
    var now by remember { mutableDoubleStateOf(Iso.now()) }
    var again by remember { mutableIntStateOf(0) }
    var fromLabel by remember { mutableStateOf("") }

    LaunchedEffect(dest, again) {
        val d = dest ?: return@LaunchedEffect
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) {
                val here = Locator.last(context)
                val from = here ?: profile.home?.point
                if (from == null) { asked = true; break }
                fromLabel = if (here != null) "From where you are" else "From home"
                loading = true
                val n = Iso.now()
                val got = TransitParse.keepUseful(Transit.plan("${from.lat},${from.lon}", d.planId, n - 120, count = 6), n, 6)
                loading = false; asked = true; now = Iso.now()
                if (got.isNotEmpty() || trips.isEmpty()) trips = got
                val leaveIn = got.firstOrNull()?.let { it.first.departure - now }
                delay(if (leaveIn != null && leaveIn < 12 * 60) 20_000 else 40_000)
            }
        }
    }
    LaunchedEffect(q) {
        if (q.trim().length < 3) { hits = emptyList(); return@LaunchedEffect }
        delay(400)
        hits = Transit.findPlaces(q.trim(), Locator.last(context))
    }

    Column(Modifier.fillMaxSize().background(DS.t.page).safeDrawingPadding().verticalScroll(rememberScrollState()).padding(horizontal = 12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = DS.t.text) }
            Text("Fastest trip", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, color = DS.t.text, modifier = Modifier.weight(1f))
            if (loading) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
            else IconButton(onClick = { again++ }) { Icon(Icons.Filled.Refresh, "Plan again", tint = DS.t.text) }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            profile.school?.let { s -> FilterChip(dest == s && !searching, { dest = s; searching = false; trips = emptyList(); selected = null }, label = { Text("School") }) }
            profile.home?.let { h -> FilterChip(dest == h && !searching, { dest = h; searching = false; trips = emptyList(); selected = null }, label = { Text("Home") }) }
            FilterChip(searching, { searching = true }, label = { Text("Somewhere else") })
        }
        if (searching) {
            OutlinedTextField(q, { q = it }, Modifier.fillMaxWidth(), label = { Text("A place, address or stop") }, singleLine = true)
            hits.forEach { h ->
                Choice(h.name, listOf(h.town, h.kind).filter { it.isNotEmpty() }.joinToString(" · ")) {
                    dest = SavedPlace(h.name, h.lat, h.lon); searching = false; trips = emptyList(); selected = null
                }
            }
        }
        val d = dest
        if (d != null && !searching) {
            Text("$fromLabel to ${d.name}", color = DS.t.secondary)
            if (trips.isEmpty() && asked && !loading) Note(Transit.lastTrouble ?: "No trips found. Try again in a minute.")
            trips.forEach { t ->
                TripRow(t, now, selected = selected == t.id) { selected = if (selected == t.id) null else t.id }
                if (selected == t.id) Card {
                    t.rides.forEach { LegRow(it) }
                    if (t.walkAfter > 0) Text("Walk ${t.walkAfter} min to ${d.name}", color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
                    if (canStart) BigButton("I'm on it: start the ride") { onStart(t, d.name) }
                    else Text("A ride is running: end it first.", color = DS.t.secondary)
                }
            }
        }
        if (d == null && !searching) Text("Pick where to go.", color = DS.t.secondary)
        Spacer(Modifier.height(24.dp))
    }
}
