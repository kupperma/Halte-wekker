package nl.haltewekker.ui.screens

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.Canvas as ComposeCanvas
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import kotlinx.coroutines.delay
import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.core.Iso
import nl.haltewekker.data.DoorTrip
import nl.haltewekker.live.LiveFeeds
import nl.haltewekker.live.RealPositions
import nl.haltewekker.travel.Nearby
import nl.haltewekker.travel.NearbyCards
import nl.haltewekker.travel.NearbyLive
import nl.haltewekker.travel.NearbyStore
import nl.haltewekker.travel.TripTimeline
import nl.haltewekker.ui.BigButton
import nl.haltewekker.ui.Card
import nl.haltewekker.ui.Fmt
import nl.haltewekker.ui.Locator
import nl.haltewekker.ui.QuietButton
import nl.haltewekker.ui.RidePill
import nl.haltewekker.ui.theme.DS
import nl.haltewekker.ui.theme.Tokens
import org.maplibre.android.MapLibre
import org.maplibre.android.camera.CameraPosition
import org.maplibre.android.camera.CameraUpdateFactory
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.geometry.LatLngBounds
import org.maplibre.android.maps.MapLibreMap
import org.maplibre.android.maps.MapView
import org.maplibre.android.maps.Style
import org.maplibre.android.style.expressions.Expression
import org.maplibre.android.style.layers.CircleLayer
import org.maplibre.android.style.layers.PropertyFactory
import org.maplibre.android.style.sources.GeoJsonSource
import org.maplibre.geojson.Feature
import org.maplibre.geojson.FeatureCollection
import org.maplibre.geojson.Point
import java.time.ZoneId
import kotlin.math.max
import kotlin.math.roundToInt

private val ZONE: ZoneId = ZoneId.of("Europe/Amsterdam")

/** One stop as the screen shows it: its ways in this window, the best of them, its option for the tags. */
private class Shown(val group: Nearby.Group, val trips: List<DoorTrip>, val shown: List<Int>, val best: Nearby.Best?, val option: Nearby.Option?)

/** Whether Fastest trip opens on the stops around you (iOS `NearbyViews`): not on board, not a planned trip. */
fun nearbyFirst(canStart: Boolean, planned: Boolean): Boolean = canStart && !planned

/**
 * (0.10.0, iOS 0.42.0/0.42.2 `NearbyViews`, `NearbyDetail`) Fastest trip, zoomed out: a map of the stops you could walk
 * to, each circle coloured by when you'd arrive (green early … red late; "+N" where they'd overlap), its ring how sure
 * (solid ≥ 85 % on time, dashed under, thin grey by the time of day), a legend; Leave now / In 10 / In 20 filter
 * what's in (a second page a second after the last switch, only when needed); the list with Fastest, Surest, Slower.
 * A stop tapped: Times or Whole trip, "On the line now", "Also from here", "Go · leave in N min".
 */
@Composable
fun NearbyView(destId: String, destName: String, seed: List<DoorTrip>, onTrip: () -> Unit, onGo: (DoorTrip) -> Unit) {
    val context = LocalContext.current
    val store = remember(destId) { NearbyStore(destId, seed) }
    var leave by remember { mutableStateOf(Nearby.Leave.NOW) }
    var result by remember { mutableStateOf(store.result) }
    var busy by remember { mutableStateOf(false) }
    var located by remember { mutableStateOf(true) }
    var picked by remember { mutableStateOf<String?>(null) }
    var zoom by remember { mutableDoubleStateOf(14.0) }
    var now by remember { mutableDoubleStateOf(Iso.now()) }
    var switched by remember { mutableIntStateOf(0) }
    val rides by nl.haltewekker.travel.TravelLogStore.rides.collectAsState()

    // the search: at once, again after 5 minutes on screen or when you moved 250 m (what's shown stays meanwhile); never
    // at bus speed
    LaunchedEffect(destId) {
        nl.haltewekker.travel.TravelLogStore.load(context)
        var at: GeoPoint? = null
        var askedAt = 0.0
        while (true) {
            val here = Locator.last(context)
            located = here != null
            // (0.10.3, iOS 0.42.4) not on the bus: at bus speed it doesn't search (Fastest trip shows the cards then)
            if (here != null && nl.haltewekker.ride.WaitWatch.nearbySearches(nl.haltewekker.ride.WaitStore.atVehicleSpeed.value) && (at == null || Geo.metres(at, here) >= 250 || Iso.now() - askedAt >= 300)) {
                busy = result == null
                result = try { store.search(here, leave) } catch (_: Exception) { result }
                busy = false
                at = here; askedAt = Iso.now()
            }
            now = Iso.now()
            // (iOS 0.42.8) what a stop's board freshened (live times by trip id)
            store.result?.let { if (it !== result) result = it }
            delay(15_000)
        }
    }
    // a switch of the time to leave filters what's in; a second after the last one, the next page only when needed
    LaunchedEffect(switched) {
        if (switched == 0) return@LaunchedEffect
        delay(1000)
        store.more(leave)?.let { result = it }
    }
    LaunchedEffect(Unit) { while (true) { delay(20_000); now = Iso.now() } }

    val r = result
    val w = Nearby.window(leave, now)
    val shown: List<Shown> = r?.let { res ->
        res.groups.map { g ->
            val trips = res.ways[g.id] ?: emptyList()
            val deps = trips.map(store::dep)
            val idx = Nearby.shown(deps, w)
            val best = Nearby.best(deps, w)
            val opt = best?.let { b -> val t = trips[b.index]; Nearby.Option(g.id, t.end, t.first.departure, t.first.walkBefore, NearbyStore.sure(t, rides, now), b.ranked) }
            Shown(g, trips, idx, best, opt)
        }
    } ?: emptyList()
    val options = shown.mapNotNull { it.option }
    // (0.10.11, iOS 0.42.15) Fastest and Surest, both on one when one way is both ("Slower" isn't shown any more)
    val badges = NearbyCards.badges(options)
    val ranked = options.filter { it.ranked }

    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Stops around you", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold, color = DS.t.text, modifier = Modifier.weight(1f))
            TextButton(onClick = onTrip) { Text("Your trip and other times") }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Nearby.Leave.entries.forEach { l -> FilterChip(leave == l, { if (leave != l) { leave = l; switched++ } }, label = { Text(l.title) }) }
        }
        val me = r?.here ?: Locator.last(context)
        val greys = shown.filter { it.option == null }
        val vehicles = remember { mutableStateOf<List<Pair<GeoPoint, Int>>>(emptyList()) }
        // (0.10.11, iOS 0.42.15) each stop with a way a small dot (gold, green, grey) and a mini card by it, most
        // important first (`NearbyCards.layout` places them, never on top of anything)
        val tk = DS.t  // (0.10.12) the line colours of the current theme, not always the light one
        val cards = Nearby.ordered(options).map { o ->
            val s = shown.first { it.group.id == o.id }
            val t = s.trips[s.best!!.index]
            val b = badges[o.id] ?: NearbyCards.Badge()
            val day = Nearby.dayWord(o.arrival, now, ZONE)
            MiniCard(o.id, s.group.point, b, NearbyCards.edge(b), t.rides.distinctBy { it.line }.take(2).map { it.line to tk.kind(it.kind).toArgb() },
                NearbyCards.leaveWords(Fmt.time(o.departure), o.walk), (day?.let { "$it " } ?: "") + Fmt.time(o.arrival), Fmt.time(o.arrival),
                o.sure?.let(NearbyCards::onTimeWords), o.sure?.let(NearbyCards::estimateWord), o.ranked)
        }
        val frame = me?.let { y -> Nearby.frame(y, shown.filter { it.option?.ranked == true }.map { it.group.point }) }
        NearbyMap(Modifier.fillMaxWidth().height(320.dp), me, cards, greys.map { it.group.id to it.group.point }, vehicles.value, frame,
            showCards = picked == null, onTap = { picked = it }, onZoom = { zoom = it })
        Nearby.statusLine(Nearby.Situation(located = me != null, stopsFailed = r?.stopsFailed == true, busy = busy || (r == null && me != null),
            options = ranked.size, planFailed = r?.planFailed == true, seed = seed.isNotEmpty(), cooling = nl.haltewekker.data.Transit.cooling), "1.6 km")
            ?.let { (text, _) -> Text(text, color = DS.t.secondary, style = MaterialTheme.typography.bodySmall) }
        val p = picked?.let { id -> shown.firstOrNull { it.group.id == id } }
        if (p != null) StopSheet(p, store, w, now, badges[p.group.id]?.tags ?: emptyList(), rides, vehicles, onClose = { picked = null; vehicles.value = emptyList() }, onGo = onGo)
        else Nearby.ordered(options).forEach { o ->
            val s = shown.first { it.group.id == o.id }
            OptionRow(s, o, badges[o.id]?.tags ?: emptyList(), now) { picked = o.id }
        }
        Text("To $destName. Walks are the planner's from where you are; how sure: ${if (rides.isEmpty()) "by live times and the time of day" else "your own rides when there are enough, else by live times and the time of day"}.",
            color = DS.t.secondary, style = MaterialTheme.typography.labelSmall)
    }
}

/** (iOS 0.42.15) A stop's mini card: where it is, its tags and edge, its lines, the words, its pill ("12:31"). */
private data class MiniCard(val id: String, val p: GeoPoint, val badge: NearbyCards.Badge, val edge: NearbyCards.Edge,
                            val lines: List<Pair<String, Int>>, val leave: String, val arrive: String, val pill: String,
                            val onTime: String?, val estimate: String?, val ranked: Boolean)

private fun rgb(c: Int) = Color(0xFF000000 or (c.toLong() and 0xFFFFFF))

private fun tagColor(t: Nearby.Tag) = when (t) {
    Nearby.Tag.FASTEST -> rgb(NearbyCards.color(NearbyCards.Edge.FASTEST)); Nearby.Tag.SUREST -> rgb(NearbyCards.color(NearbyCards.Edge.SUREST)); Nearby.Tag.SLOWER -> Color(0xFF9AA1A8)
}

@Composable
private fun TagChip(t: Nearby.Tag) {
    // (iOS 0.42.8) never "Fastes / t": one line, the row's other text gives way
    Text(t.title, color = Color(0xFF10140F), fontSize = 11.sp, fontWeight = FontWeight.Bold, maxLines = 1, softWrap = false,
        modifier = Modifier.background(tagColor(t), RoundedCornerShape(6.dp)).padding(horizontal = 6.dp, vertical = 2.dp))
}

@Composable
private fun OptionRow(s: Shown, o: Nearby.Option, tags: List<Nearby.Tag>, now: Double, onClick: () -> Unit) {
    val t = s.trips[s.best!!.index]
    // (iOS 0.42.15, design M4b) name and tags; "9 min walk · 305 · leaves 10:41"; the arrival big, "92% on time"
    Card(Modifier.clickable(onClick = onClick), padding = 12) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(s.group.name, fontWeight = FontWeight.SemiBold, color = DS.t.text, maxLines = 1,
                        overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                    tags.forEach { TagChip(it) }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(NearbyCards.walkWords(o.walk) + " ·", color = DS.t.secondary, style = MaterialTheme.typography.bodySmall, maxLines = 1, softWrap = false)
                    t.rides.take(3).forEach { RidePill(it) }
                    val sh = NearbyLive.shown(t.first.departure, t.first.scheduledDeparture, t.first.live, t.first.cancelled)
                    Text("· leaves ${Fmt.time(sh.time)}" + if (sh.late) " ${sh.word}" else "", color = if (sh.late) DS.t.warning else DS.t.secondary,
                        style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
                }
                if (!o.ranked) Text("later" + (Nearby.dayWord(t.first.departure, now, ZONE)?.let { " · $it" } ?: ""), color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
            }
            Column(horizontalAlignment = Alignment.End) {
                Text(Fmt.time(t.end), fontWeight = FontWeight.Bold, fontSize = 22.sp, color = if (o.ranked) DS.t.text else DS.t.secondary, maxLines = 1, softWrap = false)
                o.sure?.let { sure ->
                    Text(NearbyCards.onTimeWords(sure), color = DS.t.secondary, style = MaterialTheme.typography.bodySmall, maxLines = 1, softWrap = false)
                    NearbyCards.estimateWord(sure)?.let { Text(it, color = DS.t.secondary, style = MaterialTheme.typography.labelSmall, maxLines = 1, softWrap = false) }
                }
            }
        }
    }
}

@Composable
private fun StopSheet(s: Shown, store: NearbyStore, w: Nearby.Window, now: Double, tags: List<Nearby.Tag>, rides: List<nl.haltewekker.travel.RideRecord>,
                      vehicles: androidx.compose.runtime.MutableState<List<Pair<GeoPoint, Int>>>, onClose: () -> Unit, onGo: (DoorTrip) -> Unit) {
    var tab by remember(s.group.id) { mutableIntStateOf(0) }
    var info by remember(s.group.id) { mutableStateOf<NearbyStore.StopInfo?>(null) }
    var again by remember(s.group.id) { mutableIntStateOf(0) }
    var selected by remember(s.group.id) { mutableStateOf<String?>(null) }
    var why by remember(s.group.id) { mutableStateOf(false) }
    val walk = s.trips.firstOrNull()?.first?.walkBefore ?: Nearby.plannedWalk(s.group.metres)
    LaunchedEffect(s.group.id, again) {
        info = null
        info = try { store.stop(s.group, s.trips, w.leave + walk * 60.0) } catch (_: Exception) { NearbyStore.StopInfo(s.trips, emptyList(), true) }
    }
    // (iOS 0.42.8) the stop's board freshened its departures: those, in the same order
    val trips = info?.trips?.takeIf { it.isNotEmpty() && (s.trips.isEmpty() || it.size == s.trips.size) } ?: s.trips
    val deps = trips.map(store::dep)
    val idx = Nearby.shown(deps, w)
    val (normal, late) = Nearby.split(deps, w).let { (a, b) -> idx.filter { it in a } to idx.filter { it in b } }
    // on the line now: the next 3 of those departures with their own GPS, drawn on the map
    val tk = DS.t
    LaunchedEffect(s.group.id, trips.size, tk) {
        while (true) {
            val buses = try { LiveFeeds.busFixes() } catch (_: Exception) { emptyMap() }
            val trains = if (trips.any { it.first.isTrain }) try { LiveFeeds.trainFixes() } catch (_: Exception) { emptyMap() } else emptyMap()
            vehicles.value = idx.take(3).mapNotNull { i ->
                val f = trips[i].first
                val g = if (f.isTrain) RealPositions.trainNumber(f.num)?.let { trains[it] }?.let { RealPositions.usable(it, f.tripId, Iso.now()) }
                    else RealPositions.usable(buses, f.tripId, Iso.now())
                g?.let { it.point to tk.kind(f.kind).toArgb() }
            }
            delay(30_000)
        }
    }
    DisposableEffect(s.group.id) { onDispose { vehicles.value = emptyList() } }
    Card(padding = 14) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(s.group.name, fontWeight = FontWeight.Bold, color = DS.t.text, style = MaterialTheme.typography.titleMedium)
                    tags.forEach { TagChip(it) }
                }
                Text(NearbyCards.walkWords(walk), color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
            }
            TextButton(onClick = onClose) { Text("All stops") }
        }
        s.best?.let { b -> trips.getOrNull(b.index) }?.let { t ->
            // (0.10.12) worked out once per trip, not on every recomposition; the line and the explanation share it
            val sure = remember(t, rides, now) { NearbyStore.sure(t, rides, now) }
            // (iOS 0.42.15) tap it (or the i) for where the % comes from: your own rides around this time, or the estimate
            Row(Modifier.fillMaxWidth().heightIn(min = 44.dp).clickable { why = !why }, verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Arrive ${Fmt.time(t.end)}: " + Nearby.sureWords(sure), color = DS.t.text,
                    style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
                Icon(Icons.Outlined.Info, contentDescription = if (why) "Hide where this comes from" else "Where this comes from", tint = DS.t.accent)
            }
            if (why) Text(NearbyStore.explain(t, sure), color = DS.t.text, style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.fillMaxWidth().background(DS.t.secondary.copy(alpha = 0.12f), RoundedCornerShape(12.dp)).padding(12.dp))
        }
        val i0 = info
        if (i0 == null && trips.isEmpty()) Text("Checking this stop…", color = DS.t.secondary)
        if (i0?.failed == true && trips.isEmpty()) {
            Text("Couldn’t check this stop just now (the planner is busy or didn’t answer).", color = DS.t.secondary)
            QuietButton("Try again") { again++ }
        }
        if (trips.isNotEmpty()) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilterChip(tab == 0, { tab = 0 }, label = { Text("Times") })
                FilterChip(tab == 1, { tab = 1 }, label = { Text("Whole trip") })
            }
            if (idx.isEmpty()) Text("Nothing from here for that time.", color = DS.t.secondary)
            if (tab == 0) normal.take(6).forEach { i -> TimeRow(trips[i], now) }
            else {
                val surest = NearbyCards.surestBoth(normal.map { NearbyStore.sure(trips[it], rides, now).percent },
                    normal.indexOf(s.best?.index ?: -1).takeIf { it >= 0 } ?: 0)?.let { normal[it] }
                Timelines(normal.map { trips[it] }, s.best?.index?.let { trips.getOrNull(it)?.id }, surest?.let { trips[it].id }, selected) { selected = it }
                if (late.isNotEmpty()) {
                    Text(Nearby.laterTitle(trips[late.first()].end, now, ZONE), fontWeight = FontWeight.SemiBold, color = DS.t.text)
                    Timelines(late.map { trips[it] }, null, null, selected) { selected = it }
                }
            }
            if (tab == 0 && late.isNotEmpty()) {
                Text(Nearby.laterTitle(trips[late.first()].end, now, ZONE), fontWeight = FontWeight.SemiBold, color = DS.t.text)
                late.take(3).forEach { i -> TimeRow(trips[i], now) }
            }
            if (vehicles.value.isNotEmpty() || idx.isNotEmpty()) {
                Text("On the line now", fontWeight = FontWeight.SemiBold, color = DS.t.text)
                OnTheLine(idx.take(3).map { trips[it] }, now)
            }
            info?.also?.takeIf { it.isNotEmpty() }?.let { also ->
                Text("Also from here", fontWeight = FontWeight.SemiBold, color = DS.t.text)
                also.take(6).forEach { d ->
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                        nl.haltewekker.ui.LinePill(d.line, d.kind)
                        Text("${Fmt.time(d.time)} · ${d.headsign}" + (d.platform?.let { " · platform $it" } ?: ""), color = DS.t.text, style = MaterialTheme.typography.bodySmall)
                    }
                }
            }
            val go = (selected?.let { id -> trips.firstOrNull { it.id == id } }) ?: s.best?.let { trips.getOrNull(it.index) }
            if (go != null) {
                val inMin = max(0, ((go.start - now) / 60).roundToInt())
                BigButton("Go · leave in $inMin min") { onGo(go) }
                go.first.from?.let { at -> WalkThere(WalkTarget(at, go.first.fromStop, go.first.platform, go.first.departure, walkWhat(go.first))) }
            }
        }
    }
}

@Composable
private fun TimeRow(t: DoorTrip, now: Double) {
    val f = t.first
    // (iOS 0.42.8) the live time ("14:41 +3", the planned one struck through); "live" only with live times
    val sh = NearbyLive.shown(f.departure, f.scheduledDeparture, f.live, f.cancelled)
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        t.rides.take(3).forEach { RidePill(it) }
        Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
            sh.planned?.let { Text(Fmt.time(it), color = DS.t.secondary, style = MaterialTheme.typography.bodySmall,
                textDecoration = androidx.compose.ui.text.style.TextDecoration.LineThrough, maxLines = 1) }
            Text("${Fmt.time(sh.time)} · ${sh.word}", color = if (sh.late) Color(0xFFE86F5A) else DS.t.text, style = MaterialTheme.typography.bodyMedium, maxLines = 1)
        }
        Text("arrive ${Fmt.time(t.end)}", color = DS.t.secondary, style = MaterialTheme.typography.bodySmall, maxLines = 1)
    }
}

@Composable
private fun OnTheLine(trips: List<DoorTrip>, now: Double) {
    val buses = LiveFeeds.buses.fixes
    val trains = LiveFeeds.trains
    trips.forEach { t ->
        val f = t.first
        val g = if (f.isTrain) RealPositions.trainNumber(f.num)?.let { trains[it] }?.let { RealPositions.usable(it, f.tripId, now) } else RealPositions.usable(buses, f.tripId, now)
        val mins = ((f.departure - now) / 60).roundToInt()
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            RidePill(f)
            Text(Nearby.comingWords(mins, null) + " · " + (g?.let { Nearby.gpsAge(now - it.at) } ?: "no live position, by its times"),
                color = DS.t.text, style = MaterialTheme.typography.bodySmall)
        }
    }
}

/** Whole trip: each departure a timeline on one shared axis (`TripTimeline`), gap minutes labelled, tap selects. */
@Composable
private fun Timelines(trips: List<DoorTrip>, fastest: String?, surest: String?, selected: String?, onPick: (String) -> Unit) {
    if (trips.isEmpty()) return
    val rows = trips.map { t -> TripTimeline.parts(t.start, t.rides.map { TripTimeline.Leg(it.line, it.isTrain, it.live, it.departure, it.arrival, it.fromStop, it.walkBefore) }, t.end) }
    val axis = TripTimeline.axis(rows) ?: return
    val changeNeeds = nl.haltewekker.travel.Habits.changeMinutes(nl.haltewekker.travel.HabitStore.book.value)
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val wDp = maxWidth.value.toDouble()
        val density = LocalDensity.current.density
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            // the time axis
            Box(Modifier.fillMaxWidth().height(16.dp)) {
                axis.ticks(wDp).forEach { tk ->
                    val x = axis.at(tk)
                    Text(Fmt.time(tk), fontSize = 10.sp, color = DS.t.secondary,
                        modifier = Modifier.padding(start = (max(0.0, x * wDp - if (x > 0.9) 30.0 else if (x > 0.05) 15.0 else 0.0)).dp))
                }
            }
            trips.forEachIndexed { k, t ->
                val placed = TripTimeline.place(rows[k], axis)
                val gaps = TripTimeline.gapLabels(placed, wDp, changeNeeds)
                val rideText = TripTimeline.rideLabels(placed, wDp).associate { it.index to it.text }
                val ends = TripTimeline.ends(axis.at(t.start), axis.at(t.end), wDp)
                // (iOS 0.42.15) green when it's the surest (also when it's the fastest too), gold when only the fastest
                val border = when (t.id) { surest -> tagColor(Nearby.Tag.SUREST); fastest -> tagColor(Nearby.Tag.FASTEST); else -> if (t.id == selected) DS.t.accent else Color.Transparent }
                Column(Modifier.fillMaxWidth().border(BorderStroke(2.dp, border), RoundedCornerShape(8.dp)).clickable { onPick(t.id) }.padding(4.dp)) {
                    Box(Modifier.fillMaxWidth().height(14.dp)) {
                        Text(Fmt.time(t.start), fontSize = 10.sp, color = DS.t.secondary, modifier = Modifier.padding(start = (ends.leave * wDp).dp))
                        Text(Fmt.time(t.end), fontSize = 10.sp, color = DS.t.secondary, modifier = Modifier.padding(start = (ends.arrive * wDp).dp))
                    }
                    val textColor = DS.t.secondary
                    Box(Modifier.fillMaxWidth().height(22.dp)) {
                        ComposeCanvas(Modifier.fillMaxWidth().height(22.dp)) {
                            val cy = size.height / 2
                            placed.forEach { p ->
                                val x0 = (p.x * size.width).toFloat(); val x1 = ((p.x + p.width) * size.width).toFloat()
                                when (p.part.kind) {
                                    TripTimeline.Kind.WALK -> drawLine(textColor, Offset(x0, cy), Offset(x1, cy), strokeWidth = 2 * density,
                                        pathEffect = PathEffect.dashPathEffect(floatArrayOf(3 * density, 3 * density)))
                                    TripTimeline.Kind.WAIT -> drawLine(textColor.copy(alpha = 0.5f), Offset(x0, cy), Offset(x1, cy), strokeWidth = 1 * density)
                                    TripTimeline.Kind.RIDE -> {
                                        val kind = nl.haltewekker.data.VehicleKind.of("", p.part.line, p.part.train)
                                        val c = Tokens.light.kind(kind).copy(alpha = if (p.part.live) 1f else 0.5f)
                                        drawRoundRect(c, Offset(x0, cy - 9 * density), Size(max(2f, x1 - x0), 18 * density),
                                            androidx.compose.ui.geometry.CornerRadius(4 * density))
                                    }
                                }
                            }
                        }
                        rideText.forEach { (i, txt) ->
                            val p = placed[i]
                            Text(txt, fontSize = 10.sp, color = Color.White, fontWeight = FontWeight.Bold,
                                modifier = Modifier.padding(start = ((p.x + p.width / 2) * wDp - TripTimeline.textWidth(txt) / 2).coerceAtLeast(0.0).dp, top = 3.dp))
                        }
                    }
                    val inline = gaps.filter { !it.below }
                    val below = gaps.filter { it.below }
                    if (inline.isNotEmpty() || below.isNotEmpty()) Box(Modifier.fillMaxWidth().height(if (below.any { it.lane == 1 }) 28.dp else 14.dp)) {
                        (inline + below).forEach { g ->
                            val c = when (g.tone) { TripTimeline.Tone.RISKY -> Color(0xFFE86F5A); TripTimeline.Tone.TIGHT -> DS.t.warning; else -> DS.t.secondary }
                            Text(g.text, fontSize = 10.sp, color = c, modifier = Modifier.padding(start = (g.x * wDp - TripTimeline.textWidth(g.text) / 2).coerceAtLeast(0.0).dp,
                                top = (if (g.below && g.lane == 1) 14 else 0).dp))
                        }
                    }
                }
            }
        }
    }
}

/**
 * The nearby map (iOS 0.42.15): you, each stop a small dot (gold or green when tagged, grey else; grey dots for the stops
 * not planned from), the vehicles on the line now; over it the walk lines from you (solid in the tag's colour, dashed
 * grey else), each stop's mini card or pill where `NearbyCards.layout` puts it (never on top of another, of you or of
 * a dot), with a leader line when it isn't right by its dot. Taps on a card, a pill or a dot open the stop.
 */
@Composable
private fun NearbyMap(modifier: Modifier, me: GeoPoint?, cards: List<MiniCard>, greys: List<Pair<String, GeoPoint>>, vehicles: List<Pair<GeoPoint, Int>>,
                      frame: Nearby.Frame?, showCards: Boolean, onTap: (String) -> Unit, onZoom: (Double) -> Unit) {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val tap by rememberUpdatedState(onTap)
    val zoomed by rememberUpdatedState(onZoom)
    var map by remember { mutableStateOf<MapLibreMap?>(null) }
    var style by remember { mutableStateOf<Style?>(null) }
    var moved by remember { mutableIntStateOf(0) }
    val density = context.resources.displayMetrics.density
    val view = remember {
        MapLibre.getInstance(context)
        MapView(context).apply {
            onCreate(null)
            getMapAsync { m ->
                m.uiSettings.isRotateGesturesEnabled = false
                m.uiSettings.isTiltGesturesEnabled = false
                m.uiSettings.isLogoEnabled = false
                // (0.10.12) the © OpenStreetMap / OpenFreeMap credit stays (required): its "i" bottom right, kept
                // clear of the cards (`ATTRIBUTION` is left out of their room)
                m.uiSettings.isAttributionEnabled = true
                m.uiSettings.attributionGravity = android.view.Gravity.BOTTOM or android.view.Gravity.END
                m.uiSettings.setAttributionMargins(0, 0, (ATTRIBUTION_MARGIN * density).toInt(), (ATTRIBUTION_MARGIN * density).toInt())
                m.cameraPosition = CameraPosition.Builder().target(LatLng(me?.lat ?: 52.09, me?.lon ?: 5.12)).zoom(14.0).build()
                m.setStyle(Style.Builder().fromUri(nl.haltewekker.map.MapStyle.STYLE_URL)) { s ->
                    for (id in listOf("greys", "dots", "me", "vehicles")) s.addSource(GeoJsonSource(id))
                    s.addLayer(CircleLayer("greys-dots", "greys").withProperties(PropertyFactory.circleColor("#9AA1A8"), PropertyFactory.circleRadius(5f),
                        PropertyFactory.circleStrokeColor("#FFFFFF"), PropertyFactory.circleStrokeWidth(1.5f)))
                    s.addLayer(CircleLayer("stop-dots", "dots").withProperties(PropertyFactory.circleColor(Expression.get("color")),
                        PropertyFactory.circleRadius(5f), PropertyFactory.circleStrokeColor("#0B0C0E"), PropertyFactory.circleStrokeWidth(2f)))
                    s.addLayer(CircleLayer("vehicles-dots", "vehicles").withProperties(PropertyFactory.circleColor(Expression.get("color")),
                        PropertyFactory.circleRadius(7f), PropertyFactory.circleStrokeColor("#FFFFFF"), PropertyFactory.circleStrokeWidth(2f)))
                    s.addLayer(CircleLayer("me-halo", "me").withProperties(PropertyFactory.circleColor("#2F8CFF"), PropertyFactory.circleOpacity(0.18f),
                        PropertyFactory.circleRadius(20f)))
                    s.addLayer(CircleLayer("me-dot", "me").withProperties(PropertyFactory.circleColor("#2F7CF6"), PropertyFactory.circleRadius(7f),
                        PropertyFactory.circleStrokeColor("#FFFFFF"), PropertyFactory.circleStrokeWidth(3f)))
                    style = s
                }
                m.addOnCameraIdleListener { zoomed(m.cameraPosition.zoom); moved++ }
                m.addOnCameraMoveListener { moved++ }
                m.addOnMapClickListener { ll ->
                    val pt = m.projection.toScreenLocation(ll)
                    val r = 10 * density
                    val hit = m.queryRenderedFeatures(android.graphics.RectF(pt.x - r, pt.y - r, pt.x + r, pt.y + r), "stop-dots", "greys-dots").firstOrNull()
                    val id = hit?.getStringProperty("id") ?: return@addOnMapClickListener false
                    tap(id); true
                }
                map = m
            }
        }
    }
    DisposableEffect(lifecycle) {
        val obs = LifecycleEventObserver { _, e ->
            when (e) {
                Lifecycle.Event.ON_START -> view.onStart(); Lifecycle.Event.ON_RESUME -> view.onResume()
                Lifecycle.Event.ON_PAUSE -> view.onPause(); Lifecycle.Event.ON_STOP -> view.onStop()
                else -> {}
            }
        }
        lifecycle.addObserver(obs)
        if (lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) { view.onStart(); if (lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) view.onResume() }
        onDispose { lifecycle.removeObserver(obs); view.onPause(); view.onStop(); view.onDestroy() }
    }
    val fkey = frame?.let { "%.4f,%.4f,%.4f,%.4f".format(java.util.Locale.ROOT, it.lat, it.lon, it.latDelta, it.lonDelta) }
    LaunchedEffect(map, fkey) {
        val m = map ?: return@LaunchedEffect
        val f = frame ?: return@LaunchedEffect
        val b = LatLngBounds.from(f.lat + f.latDelta / 2, f.lon + f.lonDelta / 2, f.lat - f.latDelta / 2, f.lon - f.lonDelta / 2)
        try { m.easeCamera(CameraUpdateFactory.newLatLngBounds(b, (24 * density).toInt()), 400) } catch (_: Exception) {}
    }
    LaunchedEffect(style, cards) {
        val s = style ?: return@LaunchedEffect
        (s.getSource("dots") as? GeoJsonSource)?.setGeoJson(FeatureCollection.fromFeatures(cards.map { c ->
            Feature.fromGeometry(Point.fromLngLat(c.p.lon, c.p.lat)).apply {
                addStringProperty("id", c.id); addStringProperty("color", String.format("#%06X", 0xFFFFFF and NearbyCards.color(c.edge)))
            } }))
    }
    LaunchedEffect(style, greys) {
        val s = style ?: return@LaunchedEffect
        (s.getSource("greys") as? GeoJsonSource)?.setGeoJson(FeatureCollection.fromFeatures(greys.map { (id, p) ->
            Feature.fromGeometry(Point.fromLngLat(p.lon, p.lat)).apply { addStringProperty("id", id) } }))
    }
    LaunchedEffect(style, me) {
        val s = style ?: return@LaunchedEffect
        (s.getSource("me") as? GeoJsonSource)?.setGeoJson(FeatureCollection.fromFeatures(listOfNotNull(me?.let { Feature.fromGeometry(Point.fromLngLat(it.lon, it.lat)) })))
    }
    LaunchedEffect(style, vehicles) {
        val s = style ?: return@LaunchedEffect
        (s.getSource("vehicles") as? GeoJsonSource)?.setGeoJson(FeatureCollection.fromFeatures(vehicles.map { (p, c) ->
            Feature.fromGeometry(Point.fromLngLat(p.lon, p.lat)).apply { addStringProperty("color", String.format("#%06X", 0xFFFFFF and c)) } }))
    }
    BoxWithConstraints(modifier) {
        AndroidView(factory = { view }, modifier = Modifier.fillMaxSize())
        val m = map
        if (m != null && style != null && showCards) {
            @Suppress("UNUSED_VARIABLE") val tick = moved          // (follows the map as it moves)
            fun screen(p: GeoPoint): NearbyCards.Point {
                val px = m.projection.toScreenLocation(LatLng(p.lat, p.lon))
                return NearbyCards.Point(px.x / density.toDouble(), px.y / density.toDouble())
            }
            val wDp = maxWidth.value.toDouble(); val hDp = maxHeight.value.toDouble()
            val bounds = NearbyCards.Rect(6.0, 6.0, max(0.0, wDp - 12), max(0.0, hDp - 12))
            val items = cards.map { NearbyCards.Item(it.id, screen(it.p), it.badge.tagged) }
            val you = me?.let(::screen)
            // the map's credit (bottom right) and the room around it stay clear of the cards
            val credit = NearbyCards.Rect(wDp - ATTRIBUTION_MARGIN - ATTRIBUTION_SIZE, hDp - ATTRIBUTION_MARGIN - ATTRIBUTION_SIZE,
                ATTRIBUTION_SIZE, ATTRIBUTION_SIZE)
            val placed = NearbyCards.layout(items, bounds, you, greys.map { screen(it.second) }, avoid = listOf(credit))
            val byId = cards.associateBy { it.id }
            ComposeCanvas(Modifier.fillMaxSize()) {
                val d = density
                if (you != null) for (i in items) {
                    val e = byId[i.id]?.edge ?: NearbyCards.Edge.PLAIN
                    val dx = i.at.x - you.x; val dy = i.at.y - you.y
                    val len = kotlin.math.sqrt(dx * dx + dy * dy)
                    val a = NearbyCards.YOU_RADIUS * 0.45; val b = NearbyCards.DOT_RADIUS
                    if (len <= a + b + 2) continue
                    val ux = dx / len; val uy = dy / len
                    val from = Offset(((you.x + ux * a) * d).toFloat(), ((you.y + uy * a) * d).toFloat())
                    val to = Offset(((i.at.x - ux * b) * d).toFloat(), ((i.at.y - uy * b) * d).toFloat())
                    if (NearbyCards.walkDashed(e)) drawLine(rgb(NearbyCards.color(e)).copy(alpha = 0.8f), from, to, strokeWidth = 2 * d,
                        pathEffect = PathEffect.dashPathEffect(floatArrayOf(4 * d, 4 * d)))
                    else drawLine(rgb(NearbyCards.color(e)), from, to, strokeWidth = 3 * d)
                }
                for (p in placed) {
                    val l = p.leader ?: continue
                    val i = items.firstOrNull { it.id == p.id } ?: continue
                    val e = byId[p.id]?.edge ?: NearbyCards.Edge.PLAIN
                    drawLine(rgb(NearbyCards.color(e)), Offset((l.x * d).toFloat(), (l.y * d).toFloat()), Offset((i.at.x * d).toFloat(), (i.at.y * d).toFloat()), strokeWidth = 1.5f * d)
                }
            }
            for (p in placed) {
                if (p.kind == NearbyCards.Kind.HIDDEN) continue
                val c = byId[p.id] ?: continue
                Box(Modifier.offset(p.rect.x.dp, p.rect.y.dp).size(p.rect.w.dp, p.rect.h.dp).clickable { tap(c.id) }) {
                    if (p.kind == NearbyCards.Kind.CARD) MiniCardView(c) else MiniPillView(c)
                }
            }
        }
    }
}

/** (0.10.12) The map's attribution "i": its margin from the bottom right and its size (dp), with room to tap it. */
private const val ATTRIBUTION_MARGIN = 6.0
private const val ATTRIBUTION_SIZE = 28.0

/** Text sizes that don't grow with the font size setting: the layout's boxes (`NearbyCards` sizes) must hold. */
@Composable
private fun fixedSp(x: Float) = (x / LocalDensity.current.fontScale).sp

/** (iOS `NearbyMiniCard`) Its lines and "leave 10:41 · 9 min walk" (cut off first), "arrive 12:07" with "92% on time"
 *  (and "estimate") beside it, the tags row. */
@Composable
private fun MiniCardView(c: MiniCard) {
    val shape = RoundedCornerShape(10.dp)
    Column(Modifier.fillMaxSize().background(DS.t.surface, shape).border(NearbyCards.edgeWidth(c.edge).dp, rgb(NearbyCards.color(c.edge)), shape)
        .padding(horizontal = 8.dp, vertical = 6.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(5.dp), verticalAlignment = Alignment.CenterVertically) {
            c.lines.forEach { (line, colour) ->
                Text(line, color = Color.White, fontSize = fixedSp(10f), fontWeight = FontWeight.Bold, maxLines = 1, softWrap = false,
                    modifier = Modifier.background(rgb(colour), RoundedCornerShape(4.dp)).padding(horizontal = 5.dp, vertical = 1.dp))
            }
            Text(c.leave, color = DS.t.secondary, fontSize = fixedSp(10.5f), maxLines = 1, softWrap = false,
                overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("arrive " + c.arrive, color = if (c.ranked) DS.t.text else DS.t.secondary, fontSize = fixedSp(15f), fontWeight = FontWeight.Bold,
                maxLines = 1, softWrap = false, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            Spacer(Modifier.width(6.dp))
            if (c.onTime != null) Column(horizontalAlignment = Alignment.End) {
                Text(c.onTime, color = DS.t.secondary, fontSize = fixedSp(10f), fontWeight = FontWeight.Medium, maxLines = 1, softWrap = false)
                c.estimate?.let { Text(it, color = DS.t.secondary, fontSize = fixedSp(9f), maxLines = 1, softWrap = false) }
            }
        }
        if (c.badge.tagged) Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            if (c.badge.fastest) MiniTag("FASTEST", tagColor(Nearby.Tag.FASTEST))
            if (c.badge.surest) MiniTag("SUREST", tagColor(Nearby.Tag.SUREST))
        }
    }
}

@Composable
private fun MiniTag(text: String, fill: Color) {
    Text(text, color = Color(0xFF10140F), fontSize = fixedSp(9f), fontWeight = FontWeight.ExtraBold, maxLines = 1, softWrap = false,
        modifier = Modifier.background(fill, RoundedCornerShape(4.dp)).padding(horizontal = 5.dp, vertical = 2.dp))
}

/** A card folded to its arrival ("12:31") where there's no room for the card. */
@Composable
private fun MiniPillView(c: MiniCard) {
    val shape = RoundedCornerShape(50)
    Box(Modifier.fillMaxSize().background(DS.t.surface, shape).border(NearbyCards.edgeWidth(c.edge).dp, rgb(NearbyCards.color(c.edge)), shape),
        contentAlignment = Alignment.Center) {
        Text(c.pill, color = DS.t.text, fontSize = fixedSp(13f), fontWeight = FontWeight.Bold, maxLines = 1, softWrap = false)
    }
}
