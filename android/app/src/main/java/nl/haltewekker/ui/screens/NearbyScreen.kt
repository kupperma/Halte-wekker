package nl.haltewekker.ui.screens

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.DashPathEffect
import android.graphics.Paint
import android.graphics.Typeface
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
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.Canvas as ComposeCanvas
import androidx.compose.material3.FilterChip
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
import androidx.compose.ui.graphics.Brush
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
import org.maplibre.android.style.layers.SymbolLayer
import org.maplibre.android.style.sources.GeoJsonSource
import org.maplibre.geojson.Feature
import org.maplibre.geojson.FeatureCollection
import org.maplibre.geojson.Point
import java.time.ZoneId
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.pow
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
    val tags = Nearby.tags(options)
    val ranked = options.filter { it.ranked }
    val earliest = ranked.minOfOrNull { it.arrival }
    val latest = ranked.maxOfOrNull { it.arrival }?.let { l -> earliest?.let { max(l, it + Nearby.MIN_SPREAD) } }
    fun colour(o: Nearby.Option?): Int =
        if (o == null || !o.ranked || earliest == null || latest == null) 0x9AA1A8 else Nearby.color(Nearby.fraction(o.arrival, earliest, latest))

    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Stops around you", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold, color = DS.t.text, modifier = Modifier.weight(1f))
            TextButton(onClick = onTrip) { Text("Your trip and other times") }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Nearby.Leave.entries.forEach { l -> FilterChip(leave == l, { if (leave != l) { leave = l; switched++ } }, label = { Text(l.title) }) }
        }
        val me = r?.here ?: Locator.last(context)
        val metresPerDp = 78271.5 * cos((me?.lat ?: 52.0) * Math.PI / 180) / 2.0.pow(zoom)
        val pins = shown.filter { it.option != null }.map { Nearby.Pin(it.group.id, it.group.lat, it.group.lon, it.option?.arrival) }
        val clusters = Nearby.merge(pins, Nearby.PIN_POINTS * metresPerDp)
        val greys = shown.filter { it.option == null && clusters.none { c -> Geo.metres(GeoPoint(c.lat, c.lon), it.group.point) < Nearby.PIN_POINTS * metresPerDp } }
        val vehicles = remember { mutableStateOf<List<Pair<GeoPoint, Int>>>(emptyList()) }
        val circles = clusters.map { c ->
            val s = shown.first { it.group.id == c.id }
            val o = s.option!!
            Circle(c.id, GeoPoint(c.lat, c.lon), colour(o), max(1, ((o.arrival - now) / 60).roundToInt()), Nearby.ring(o.sure), c.members.size - 1, o.ranked)
        }
        val frame = me?.let { y -> Nearby.frame(y, shown.filter { it.option?.ranked == true }.map { it.group.point }) }
        NearbyMap(Modifier.fillMaxWidth().height(320.dp), me, circles, greys.map { it.group.id to it.group.point }, vehicles.value, frame,
            onTap = { picked = it }, onZoom = { zoom = it })
        if (earliest != null && latest != null) Legend(earliest, ranked.maxOf { it.arrival })
        Nearby.statusLine(Nearby.Situation(located = me != null, stopsFailed = r?.stopsFailed == true, busy = busy || (r == null && me != null),
            options = ranked.size, planFailed = r?.planFailed == true, seed = seed.isNotEmpty(), cooling = nl.haltewekker.data.Transit.cooling), "1.6 km")
            ?.let { (text, _) -> Text(text, color = DS.t.secondary, style = MaterialTheme.typography.bodySmall) }
        val p = picked?.let { id -> shown.firstOrNull { it.group.id == id } }
        if (p != null) StopSheet(p, store, w, now, tags[p.group.id] ?: emptyList(), rides, vehicles, onClose = { picked = null; vehicles.value = emptyList() }, onGo = onGo)
        else Nearby.ordered(options).forEach { o ->
            val s = shown.first { it.group.id == o.id }
            OptionRow(s, o, tags[o.id] ?: emptyList(), colour(o), now) { picked = o.id }
        }
        Text("To $destName. Walks are the planner's from where you are; how sure: ${if (rides.isEmpty()) "by live times and the time of day" else "your own rides when there are enough, else by live times and the time of day"}.",
            color = DS.t.secondary, style = MaterialTheme.typography.labelSmall)
    }
}

private data class Circle(val id: String, val p: GeoPoint, val color: Int, val minutes: Int, val ring: Nearby.Ring, val more: Int, val ranked: Boolean)

@Composable
private fun Legend(earliest: Double, latest: Double) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("arrive ${Fmt.time(earliest)}", color = DS.t.secondary, style = MaterialTheme.typography.labelMedium)
        Box(Modifier.width(120.dp).height(8.dp).background(Brush.horizontalGradient(Nearby.SCALE.map { Color(0xFF000000 or it.toLong()) }), RoundedCornerShape(4.dp)))
        Text(Fmt.time(latest), color = DS.t.secondary, style = MaterialTheme.typography.labelMedium)
    }
}

private fun tagColor(t: Nearby.Tag) = when (t) { Nearby.Tag.FASTEST -> Color(0xFFC9A227); Nearby.Tag.SUREST -> Color(0xFF3DD598); Nearby.Tag.SLOWER -> Color(0xFF9AA1A8) }

@Composable
private fun TagChip(t: Nearby.Tag) {
    // (iOS 0.42.8) never "Fastes / t": one line, the row's other text gives way
    Text(t.title, color = Color.White, fontSize = 11.sp, fontWeight = FontWeight.Bold, maxLines = 1, softWrap = false,
        modifier = Modifier.background(tagColor(t), RoundedCornerShape(6.dp)).padding(horizontal = 6.dp, vertical = 2.dp))
}

@Composable
private fun OptionRow(s: Shown, o: Nearby.Option, tags: List<Nearby.Tag>, colour: Int, now: Double, onClick: () -> Unit) {
    val t = s.trips[s.best!!.index]
    Card(Modifier.clickable(onClick = onClick), padding = 12) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Box(Modifier.width(12.dp).height(12.dp).background(Color(0xFF000000 or colour.toLong()), RoundedCornerShape(6.dp)))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(s.group.name, fontWeight = FontWeight.SemiBold, color = DS.t.text, maxLines = 1,
                        overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                    tags.forEach { TagChip(it) }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("🚶 ${t.first.walkBefore} min", color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
                    t.rides.take(3).forEach { RidePill(it) }
                    val sh = NearbyLive.shown(t.first.departure, t.first.scheduledDeparture, t.first.live, t.first.cancelled)
                    Text("leaves ${Fmt.time(sh.time)}" + if (sh.late) " ${sh.word}" else "", color = if (sh.late) DS.t.warning else DS.t.secondary,
                        style = MaterialTheme.typography.bodySmall, maxLines = 1)
                }
                if (!o.ranked) Text("later" + (Nearby.dayWord(t.first.departure, now, ZONE)?.let { " · $it" } ?: ""), color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
                o.sure?.let { Text(Nearby.sureWords(it), color = DS.t.secondary, style = MaterialTheme.typography.bodySmall) }
            }
            Text(Fmt.time(t.end), fontWeight = FontWeight.Bold, fontSize = 22.sp, color = DS.t.text)
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
    LaunchedEffect(s.group.id, trips.size) {
        while (true) {
            val buses = try { LiveFeeds.busFixes() } catch (_: Exception) { emptyMap() }
            val trains = if (trips.any { it.first.isTrain }) try { LiveFeeds.trainFixes() } catch (_: Exception) { emptyMap() } else emptyMap()
            vehicles.value = idx.take(3).mapNotNull { i ->
                val f = trips[i].first
                val g = if (f.isTrain) RealPositions.trainNumber(f.num)?.let { trains[it] }?.let { RealPositions.usable(it, f.tripId, Iso.now()) }
                    else RealPositions.usable(buses, f.tripId, Iso.now())
                g?.let { it.point to Tokens.light.kind(f.kind).toArgb() }
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
                Text("🚶 $walk min walk", color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
            }
            TextButton(onClick = onClose) { Text("All stops") }
        }
        s.best?.let { b -> trips.getOrNull(b.index) }?.let { t ->
            Text("Arrive ${Fmt.time(t.end)}: " + Nearby.sureWords(NearbyStore.sure(t, rides, now)), color = DS.t.text, style = MaterialTheme.typography.bodyMedium)
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
                val surest = Nearby.surestOf(normal.map { NearbyStore.sure(trips[it], rides, now).percent },
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
                val border = when (t.id) { fastest -> Color(0xFFC9A227); surest -> Color(0xFF3DD598); else -> if (t.id == selected) DS.t.accent else Color.Transparent }
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

/** The nearby map: the circles (arrival colour, minutes, ring, "+N"), the grey dots, you, the vehicles on the line now. */
@Composable
private fun NearbyMap(modifier: Modifier, me: GeoPoint?, circles: List<Circle>, greys: List<Pair<String, GeoPoint>>, vehicles: List<Pair<GeoPoint, Int>>,
                      frame: Nearby.Frame?, onTap: (String) -> Unit, onZoom: (Double) -> Unit) {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val tap by rememberUpdatedState(onTap)
    val zoomed by rememberUpdatedState(onZoom)
    var map by remember { mutableStateOf<MapLibreMap?>(null) }
    var style by remember { mutableStateOf<Style?>(null) }
    val density = context.resources.displayMetrics.density
    val view = remember {
        MapLibre.getInstance(context)
        MapView(context).apply {
            onCreate(null)
            getMapAsync { m ->
                m.uiSettings.isRotateGesturesEnabled = false
                m.uiSettings.isTiltGesturesEnabled = false
                m.uiSettings.isLogoEnabled = false
                m.cameraPosition = CameraPosition.Builder().target(LatLng(me?.lat ?: 52.09, me?.lon ?: 5.12)).zoom(14.0).build()
                m.setStyle(Style.Builder().fromUri(nl.haltewekker.map.MapStyle.STYLE_URL)) { s ->
                    for (id in listOf("greys", "circles", "me", "vehicles")) s.addSource(GeoJsonSource(id))
                    s.addLayer(CircleLayer("greys-dots", "greys").withProperties(PropertyFactory.circleColor("#9AA1A8"), PropertyFactory.circleRadius(5f),
                        PropertyFactory.circleStrokeColor("#FFFFFF"), PropertyFactory.circleStrokeWidth(1.5f)))
                    s.addLayer(SymbolLayer("circles-icons", "circles").withProperties(PropertyFactory.iconImage(Expression.get("icon")),
                        PropertyFactory.iconAllowOverlap(true), PropertyFactory.iconIgnorePlacement(true)))
                    s.addLayer(CircleLayer("vehicles-dots", "vehicles").withProperties(PropertyFactory.circleColor(Expression.get("color")),
                        PropertyFactory.circleRadius(7f), PropertyFactory.circleStrokeColor("#FFFFFF"), PropertyFactory.circleStrokeWidth(2f)))
                    s.addLayer(CircleLayer("me-dot", "me").withProperties(PropertyFactory.circleColor("#2F7CF6"), PropertyFactory.circleRadius(7f),
                        PropertyFactory.circleStrokeColor("#FFFFFF"), PropertyFactory.circleStrokeWidth(3f)))
                    style = s
                }
                m.addOnCameraIdleListener { zoomed(m.cameraPosition.zoom) }
                m.addOnMapClickListener { ll ->
                    val hit = m.queryRenderedFeatures(m.projection.toScreenLocation(ll), "circles-icons", "greys-dots").firstOrNull()
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
    LaunchedEffect(style, circles) {
        val s = style ?: return@LaunchedEffect
        val f = circles.map { c ->
            val icon = "nb-${c.color}-${c.minutes}-${c.ring}-${c.more}-${c.ranked}"
            if (s.getImage(icon) == null) s.addImage(icon, circleBitmap(c, density))
            Feature.fromGeometry(Point.fromLngLat(c.p.lon, c.p.lat)).apply { addStringProperty("icon", icon); addStringProperty("id", c.id) }
        }
        (s.getSource("circles") as? GeoJsonSource)?.setGeoJson(FeatureCollection.fromFeatures(f))
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
    AndroidView(factory = { view }, modifier = modifier)
}

/** A stop's circle: filled in its arrival colour with the minutes inside, its ring how sure, "+N" for merged ones. */
private fun circleBitmap(c: Circle, density: Float): Bitmap {
    val d = (34 * density).toInt()
    val pad = (8 * density).toInt()
    val bmp = Bitmap.createBitmap(d + pad * 2, d + pad * 2, Bitmap.Config.ARGB_8888)
    val cv = Canvas(bmp)
    val cx = (d / 2 + pad).toFloat(); val cy = cx; val r = d / 2f
    val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = (0xFF000000.toInt() or c.color); alpha = if (c.ranked) 255 else 150 }
    cv.drawCircle(cx, cy, r, fill)
    val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }
    when (c.ring) {
        Nearby.Ring.SOLID -> { ring.color = 0xFF14171A.toInt(); ring.strokeWidth = 3 * density }
        Nearby.Ring.DASHED -> { ring.color = 0xFF14171A.toInt(); ring.strokeWidth = 2.5f * density; ring.pathEffect = DashPathEffect(floatArrayOf(4 * density, 3 * density), 0f) }
        Nearby.Ring.NEUTRAL -> { ring.color = 0xFF9AA1A8.toInt(); ring.strokeWidth = 1.2f * density }
    }
    cv.drawCircle(cx, cy, r + 2 * density, ring)
    val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xFF14171A.toInt(); textSize = 13 * density; typeface = Typeface.DEFAULT_BOLD; textAlign = Paint.Align.CENTER
    }
    cv.drawText("${c.minutes}", cx, cy + 4.5f * density, text)
    if (c.more > 0) {
        val bx = cx + r * 0.75f; val by = cy - r * 0.75f
        cv.drawCircle(bx, by, 8 * density, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xFF14171A.toInt() })
        cv.drawText("+${c.more}", bx, by + 3.5f * density, Paint(text).apply { color = 0xFFFFFFFF.toInt(); textSize = 9 * density })
    }
    return bmp
}
