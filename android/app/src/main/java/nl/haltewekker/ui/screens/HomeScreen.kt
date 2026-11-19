package nl.haltewekker.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.repeatOnLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import nl.haltewekker.App
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.core.Iso
import nl.haltewekker.data.DoorTrip
import nl.haltewekker.map.LiveMap
import nl.haltewekker.ride.RideState
import nl.haltewekker.ui.BigButton
import nl.haltewekker.ui.Card
import nl.haltewekker.ui.Direction
import nl.haltewekker.ui.Fmt
import nl.haltewekker.ui.Header
import nl.haltewekker.ui.HomeModel
import nl.haltewekker.ui.LinePill
import nl.haltewekker.ui.Locator
import nl.haltewekker.ui.Note
import nl.haltewekker.ui.QuietButton
import nl.haltewekker.ui.TripRow
import nl.haltewekker.ui.theme.DS

/** The home: the live map, the next trip to school or home, Fastest trip, and the departures around you. */
@Composable
fun HomeScreen(ride: RideState?, onPlan: (Direction?) -> Unit, onRide: () -> Unit, onStart: (DoorTrip, String) -> Unit, onSettings: () -> Unit) {
    val context = LocalContext.current
    val app = context.applicationContext as App
    val model: HomeModel = viewModel()
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val settings by app.store.settings.collectAsState()
    val profile by app.store.profile.collectAsState()
    val here by model.here.collectAsState()
    val dots by model.dots.collectAsState()
    val deps by model.departures.collectAsState()
    val next by model.next.collectAsState()
    val loading by model.nextLoading.collectAsState()
    val dir by model.direction.collectAsState()
    val scope = rememberCoroutineScope()
    var now by remember { mutableDoubleStateOf(Iso.now()) }

    // Everything below runs only while the home is in front.
    LaunchedEffect(Unit) {
        if (model.here.value == null) model.here.value = Locator.last(context)
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            launch { Locator.updates(context, 5000, 25f).collect { model.here.value = GeoPoint(it.latitude, it.longitude) } }
            launch { while (true) { now = Iso.now(); model.refreshBoard(); model.refreshNext(); delay(20_000) } }
            launch {
                var k = 0
                while (true) {
                    if (k % 10 == 0) model.refreshVehicles(settings.realPositions) else model.moveOn()
                    k++; delay(3_000)
                }
            }
        }
    }

    Column(Modifier.fillMaxSize().background(DS.t.page)) {
        Box(Modifier.fillMaxWidth().weight(0.42f)) {
            LiveMap(Modifier.fillMaxSize(), centre = here ?: profile.home?.point, me = here, dots = dots) { sw, ne, z -> model.setBounds(sw, ne, z) }
            IconButton(onClick = onSettings, modifier = Modifier.statusBarsPadding().padding(8.dp).align(Alignment.TopEnd)
                .clip(CircleShape).background(DS.t.surface)) {
                Icon(Icons.Filled.Settings, "Settings", tint = DS.t.text)
            }
        }
        Column(Modifier.fillMaxWidth().weight(0.58f).verticalScroll(rememberScrollState()).padding(horizontal = 12.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (ride != null) Card(Modifier.clickable(onClick = onRide)) {
                val leg = ride.leg
                Header("Ride in progress", ride.legArrival?.let { "there ${Fmt.time(it)}" })
                if (leg != null) Row(verticalAlignment = Alignment.CenterVertically) {
                    LinePill(leg.line, leg.kind); Spacer(Modifier.width(8.dp))
                    Text("to ${leg.toStop}", color = DS.t.text, modifier = Modifier.weight(1f))
                    ride.distance?.let { Text(Fmt.metres(it), color = DS.t.secondary) }
                }
                QuietButton("Open the ride", onClick = onRide)
            }
            Card {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    FilterChip(dir == Direction.TO_SCHOOL, { model.pick(Direction.TO_SCHOOL); scope.launch { model.refreshNext(true) } },
                        label = { Text("To school") }, enabled = profile.school != null)
                    FilterChip(dir == Direction.HOME, { model.pick(Direction.HOME); scope.launch { model.refreshNext(true) } },
                        label = { Text("Home") }, enabled = profile.home != null)
                    Spacer(Modifier.weight(1f))
                    if (loading) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                }
                val first = next.firstOrNull()
                val target = model.target(dir)
                when {
                    target == null -> Text(if (dir == Direction.TO_SCHOOL) "Set your school in Settings." else "Set your home in Settings.", color = DS.t.secondary)
                    first == null && !loading -> Text("No trip found right now.", color = DS.t.secondary)
                    first != null -> {
                        Text("Leave ${Fmt.inMinutes(first.start, now)}", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold, color = DS.t.text)
                        TripRow(first, now) { onPlan(dir) }
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            QuietButton("More trips") { onPlan(dir) }
                            if (ride == null) QuietButton("I'm on it: start the ride") { onStart(first, target.name) }
                        }
                    }
                }
            }
            BigButton("Fastest trip") { onPlan(null) }
            if (!Locator.granted(context)) Note("Allow location (Settings) for the map around you, the stops near you and trips from where you are.")
            Card {
                Header("Departures near you", if (deps.isEmpty()) null else "live where shown")
                if (deps.isEmpty()) Text("Nothing yet.", color = DS.t.secondary)
                deps.forEach { d ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        LinePill(d.line, d.kind); Spacer(Modifier.width(8.dp))
                        Column(Modifier.weight(1f)) {
                            Text(d.headsign.ifEmpty { d.line }, color = DS.t.text, maxLines = 1)
                            Text(d.stopName + (d.platform?.let { " · platform $it" } ?: ""), color = DS.t.secondary, style = MaterialTheme.typography.bodySmall, maxLines = 1)
                        }
                        Column(horizontalAlignment = Alignment.End) {
                            Text(if (d.cancelled) "cancelled" else Fmt.time(d.time), color = if (d.cancelled || d.delay > 2) DS.t.warning else DS.t.text, fontWeight = FontWeight.SemiBold)
                            if (d.delay != 0 && !d.cancelled) Text("${if (d.delay > 0) "+" else ""}${d.delay} min", color = DS.t.warning, style = MaterialTheme.typography.bodySmall)
                        }
                    }
                }
            }
            Text("Trips and times: Transitous (MOTIS). Live positions: OVapi and NS. Map: OpenFreeMap, © OpenStreetMap contributors.",
                color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
            Spacer(Modifier.height(24.dp))
        }
    }
}
