package nl.haltewekker.ui.screens

import nl.haltewekker.travel.GhostDepartures

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
fun PlanScreen(start: Direction?, canStart: Boolean, onBack: () -> Unit, onStart: (DoorTrip, String) -> Unit, place: SavedPlace? = null) {
    val context = LocalContext.current
    val app = context.applicationContext as App
    val profile by app.store.profile.collectAsState()
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    BackHandler(onBack = onBack)

    var dest by remember { mutableStateOf(place ?: start?.let { if (it == Direction.TO_SCHOOL) profile.school else profile.home } ?: profile.school ?: profile.home) }
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
    var goTrip by remember { mutableStateOf<DoorTrip?>(null) }
    var showNearby by rememberSaveable { mutableStateOf(nearbyFirst(canStart, planned = false)) }

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
                // (0.10.0) a way taken from the stops around ("Go") stays first until it has left
                val kept = goTrip?.takeIf { g -> g.first.departure > n - 60 && got.none { it.id == g.id } }
                if (got.isNotEmpty() || trips.isEmpty()) trips = listOfNotNull(kept) + got
                // (A8.1, iOS 0.40) "Time to go", later by your own walking speed once learned (2 min spare)
                nl.haltewekker.travel.TimeToGo.check(context, trips.firstOrNull(), now)
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
            // (0.10.0, iOS 0.42.0/0.42.2) Fastest trip opens on the stops around you (not on board); "Your trip and other
            // times" shows the trip cards as before, "All stops around you" goes back
            if (showNearby && canStart) NearbyView(d.planId, d.name, trips, onTrip = { showNearby = false },
                onGo = { t -> goTrip = t; trips = listOf(t) + trips.filter { it.id != t.id }; selected = t.id; showNearby = false })
            else {
                if (canStart) androidx.compose.material3.TextButton(onClick = { showNearby = true }) { Text("All stops around you") }
                Text("$fromLabel to ${d.name}", color = DS.t.secondary)
                if (trips.isEmpty() && asked && !loading) Note(Transit.lastTrouble ?: "No trips found. Try again in a minute.")
                // (A8, iOS 0.40 `GhostDepartures.order`) a first ride with no live data close to leaving on a live line: after the others
                val ordered = GhostDepartures.order(trips.map { GhostDepartures.Option(it.id, it.first.line, it.first.departure, it.first.scheduledDeparture, it.first.live, it.first.cancelled) }, now)
                    .mapNotNull { id -> trips.firstOrNull { it.id == id } }
                val big = ordered.firstOrNull { it.id == selected } ?: ordered.firstOrNull()
                ordered.forEach { t ->
                    TripRow(t, now, selected = selected == t.id) { selected = if (selected == t.id) null else t.id }
                    // (A8.1, iOS 0.40) "From <stop>" under the big card: the next departures where you get on
                    if (big?.id == t.id) FromStopFold(t, trips.filter { it.id != t.id }, d.planId) { sw ->
                        trips = listOf(sw) + trips.filter { it.id != sw.id }; selected = sw.id
                    }
                    if (selected == t.id) Card {
                        t.rides.forEach { LegRow(it) }
                        // (0.10.0, iOS 0.41) "Walk there": to the first stop with arrows, or in the maps app
                        t.first.from?.let { at -> WalkThere(WalkTarget(at, t.first.fromStop, t.first.platform, t.first.departure, walkWhat(t.first))) }
                        TripNotes(t, trips, now)
                        if (t.walkAfter > 0) Text("Walk ${t.walkAfter} min to ${d.name}", color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
                        if (canStart) BigButton("I'm on it: start the ride") { onStart(t, d.name) }
                        else Text("A ride is running: end it first.", color = DS.t.secondary)
                        // A3: as a card a friend can take
                        nl.haltewekker.ui.friends.SendTripButton { nl.haltewekker.ui.friends.TripCards.card(t, d.name, d.point, d == profile.home) }
                    }
                }
            }
        }
        if (d == null && !searching) Text("Pick where to go.", color = DS.t.secondary)
        Spacer(Modifier.height(24.dp))
    }
}
