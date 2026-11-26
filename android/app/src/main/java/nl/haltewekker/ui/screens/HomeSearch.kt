package nl.haltewekker.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import nl.haltewekker.App
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.core.Iso
import nl.haltewekker.data.DoorTrip
import nl.haltewekker.data.PlaceHit
import nl.haltewekker.data.Transit
import nl.haltewekker.data.TransitParse
import nl.haltewekker.data.VehicleKind
import nl.haltewekker.map.MapLine
import nl.haltewekker.map.MapPin
import nl.haltewekker.profile.SavedPlace
import nl.haltewekker.ui.BigButton
import nl.haltewekker.ui.Locator
import nl.haltewekker.ui.Note
import nl.haltewekker.ui.QuietButton
import nl.haltewekker.ui.TripRow
import nl.haltewekker.ui.theme.DS
import nl.haltewekker.ui.theme.Tokens

/**
 * (A8.1, iOS 0.40.0 `HomeSearch`) search as a half sheet over the home map: your places, recent ones, places and stops
 * found by name (the stops also as pins on the same map; tap one), then the ways there in the sheet with Go and the
 * route drawn on the map (it moves only when the route isn't in view, and goes back when the search closes).
 * "Another time or more options" opens the full Plan.
 */
class SearchState {
    var q by mutableStateOf("")
    var hits by mutableStateOf<List<PlaceHit>>(emptyList())
    var place by mutableStateOf<SavedPlace?>(null)
    var trips by mutableStateOf<List<DoorTrip>>(emptyList())
    var loading by mutableStateOf(false)
    var asked by mutableStateOf(false)
    var selected by mutableStateOf<String?>(null)
    var now by mutableDoubleStateOf(Iso.now())

    fun pick(p: SavedPlace) { place = p; trips = emptyList(); asked = false; selected = null }

    /** The stops found (pins), the chosen way's route and where you go. */
    fun pins(): List<MapPin> {
        val p = place
        if (p != null) return listOf(MapPin("dest", p.point, p.name.take(28), Tokens.light.accent.toArgb(), person = false))
        return hits.filter { it.kind == "stop" }.take(12).map { MapPin("hit:${it.id}", GeoPoint(it.lat, it.lon), it.name.take(28), 0xFF5B636B.toInt(), person = false) }
    }

    fun shown(): DoorTrip? = trips.firstOrNull { it.id == selected } ?: trips.firstOrNull()

    fun lines(): List<MapLine> {
        val t = shown() ?: return emptyList()
        val shapes = TransitParse.routes[t.id]
        if (shapes != null) return shapes.map { s ->
            MapLine(s.points, if (s.walk) 0xFF5B636B.toInt() else Tokens.light.kind(VehicleKind.of(s.mode, s.line, false)).toArgb(), s.walk)
        }
        // no shape kept: stop to stop
        return t.rides.mapNotNull { r -> val a = r.from; val b = r.to; if (a != null && b != null) MapLine(listOf(a, b), Tokens.light.kind(r.kind).toArgb()) else null }
    }

    fun frame(): List<GeoPoint> = lines().flatMap { it.points }.ifEmpty { pins().map { it.p } }
}

private val recentJson = Json { ignoreUnknownKeys = true }
private const val RECENT = "search.recent"

private fun recent(app: App): List<SavedPlace> = try {
    app.store.prefs.getString(RECENT, null)?.let { recentJson.decodeFromString(ListSerializer(SavedPlace.serializer()), it) } ?: emptyList()
} catch (_: Exception) { emptyList() }

private fun noteRecent(app: App, p: SavedPlace) {
    val list = (listOf(p) + recent(app).filter { it.name != p.name }).take(6)
    app.store.prefs.edit().putString(RECENT, recentJson.encodeToString(ListSerializer(SavedPlace.serializer()), list)).apply()
}

@Composable
fun SearchSheet(s: SearchState, canStart: Boolean, onStart: (DoorTrip, String) -> Unit, onMore: (SavedPlace?) -> Unit, onClose: () -> Unit) {
    val context = LocalContext.current
    val app = context.applicationContext as App
    val profile = app.store.profile.value
    LaunchedEffect(s.q) {
        if (s.q.trim().length < 3) { s.hits = emptyList(); return@LaunchedEffect }
        delay(400)
        s.hits = Transit.findPlaces(s.q.trim(), Locator.last(context))
    }
    LaunchedEffect(s.place) {
        val d = s.place ?: return@LaunchedEffect
        noteRecent(app, d)
        while (true) {
            val from = Locator.last(context) ?: profile.home?.point ?: break
            s.loading = true
            val n = Iso.now()
            val got = TransitParse.keepUseful(Transit.plan("${from.lat},${from.lon}", d.planId, n - 120, count = 6), n, 6)
            s.loading = false; s.asked = true; s.now = Iso.now()
            if (got.isNotEmpty() || s.trips.isEmpty()) s.trips = got
            delay(40_000)
        }
    }
    Row(verticalAlignment = Alignment.CenterVertically) {
        val d = s.place
        Text(if (d == null) "Where to?" else "To ${d.name}", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, color = DS.t.text,
            modifier = Modifier.weight(1f), maxLines = 1)
        if (s.loading) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
        IconButton(onClick = { if (s.place != null) { s.place = null; s.trips = emptyList() } else onClose() }) {
            Icon(Icons.Filled.Close, if (s.place != null) "Back to search" else "Close search", tint = DS.t.text)
        }
    }
    val d = s.place
    if (d == null) {
        OutlinedTextField(s.q, { s.q = it }, Modifier.fillMaxWidth(), label = { Text("A place, address or stop") }, singleLine = true)
        if (s.q.trim().length < 3) {
            Text("Your places", color = DS.t.secondary, fontWeight = FontWeight.SemiBold)
            profile.school?.let { p -> Choice("School", p.name) { s.pick(p) } }
            profile.home?.let { p -> Choice("Home", p.name) { s.pick(p) } }
            val rec = recent(app).filter { it.name != profile.school?.name && it.name != profile.home?.name }
            if (rec.isNotEmpty()) Text("Recent", color = DS.t.secondary, fontWeight = FontWeight.SemiBold)
            rec.forEach { p -> Choice(p.name, "") { s.pick(p) } }
        } else {
            s.hits.forEach { h ->
                Choice(h.name, listOf(h.town, h.kind).filter { it.isNotEmpty() }.joinToString(" · ")) { s.pick(SavedPlace(h.name, h.lat, h.lon)) }
            }
            if (s.hits.isEmpty()) Text("Searching…", color = DS.t.secondary)
        }
    } else {
        if (s.trips.isEmpty() && s.asked && !s.loading) Note(Transit.lastTrouble ?: "No trips found. Try again in a minute.")
        val shown = s.shown()
        s.trips.forEach { t ->
            TripRow(t, s.now, selected = shown?.id == t.id) { s.selected = t.id }
            if (shown?.id == t.id) {
                if (canStart) BigButton("Go") { onStart(t, d.name) }
                else Text("A ride is running: end it first.", color = DS.t.secondary)
            }
        }
        QuietButton("Another time or more options") { onMore(d) }
    }
}
