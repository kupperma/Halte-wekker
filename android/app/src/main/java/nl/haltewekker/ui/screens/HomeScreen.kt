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
import androidx.compose.material.icons.filled.Search
import androidx.compose.ui.graphics.toArgb
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
import androidx.compose.ui.draw.shadow
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
import nl.haltewekker.auto.AutoStart
import nl.haltewekker.auto.ResumeOffer
import nl.haltewekker.auto.ResumeStore
import nl.haltewekker.auto.TripResume
import nl.haltewekker.profile.TestSetup
import nl.haltewekker.ride.RideBar
import nl.haltewekker.ride.Phase
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.compose.foundation.shape.RoundedCornerShape

/** The home: the live map, the next trip to school or home, Fastest trip, and the departures around you. */
@Composable
fun HomeScreen(ride: RideState?, onPlan: (Direction?) -> Unit, onRide: () -> Unit, onStart: (DoorTrip, String) -> Unit, onSettings: () -> Unit,
               onDay: () -> Unit, onResume: (ResumeOffer) -> Unit, onFriends: () -> Unit = {}, onYear: () -> Unit = {},
               friendsOpen: Boolean = false, friendsFull: Boolean = false, onFriendsClose: () -> Unit = {},
               onPlanTo: (nl.haltewekker.profile.SavedPlace?) -> Unit = { onPlan(null) }) {
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
    val unsure by model.unsure.collectAsState()
    val loading by model.nextLoading.collectAsState()
    val dir by model.direction.collectAsState()
    val scope = rememberCoroutineScope()
    var now by remember { mutableDoubleStateOf(Iso.now()) }
    val resume by ResumeStore.offer.collectAsState()
    val testLive by TestSetup.live.collectAsState()
    LaunchedEffect(Unit) { ResumeStore.load(context) }
    // (A8.1, iOS 0.40.0 / 0.40.2) search and Friends are sheets over this map, one at a time
    var searchOpen by androidx.compose.runtime.saveable.rememberSaveable { androidx.compose.runtime.mutableStateOf(false) }
    var searchUp by remember { androidx.compose.runtime.mutableStateOf(false) }
    val search = remember { SearchState() }
    val sheet = searchOpen || friendsOpen
    val focus by model.focus.collectAsState()
    val friendsLayer by nl.haltewekker.ui.friends.FriendsOverMap.layer.collectAsState()
    val friendPictures by nl.haltewekker.friends.FriendStore.pictures.collectAsState()
    androidx.activity.compose.BackHandler(enabled = searchOpen && !friendsOpen) {
        if (search.place != null) { search.place = null; search.trips = emptyList() } else { searchOpen = false; search.q = "" }
    }
    LifecycleResumeEffect(Unit) {
        // auto-home reached school: the next trip goes home
        if (AutoStart.takeDirection(context) != null) { model.pick(Direction.HOME); scope.launch { model.refreshNext(true) } }
        onPauseOrDispose {}
    }

    // Everything below runs only while the home is in front.
    LaunchedEffect(Unit) {
        if (model.here.value == null) model.here.value = Locator.last(context)
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            launch { Locator.updates(context, 5000, 25f).collect {
                model.here.value = GeoPoint(it.latitude, it.longitude); model.noteFix(it)
                model.meFix = nl.haltewekker.live.WaitVehicle.Me(GeoPoint(it.latitude, it.longitude), it.time / 1000.0,
                    if (it.hasAccuracy()) it.accuracy.toDouble() else -1.0, if (it.hasSpeed()) it.speed.toDouble() else null)
            } }
            // (A8.1, iOS 0.40.3) the vehicle you wait for or ride: its whole trip every 30 s, placed (gliding) every second
            launch { while (true) { model.refreshFocus(); delay(10_000) } }
            launch { while (true) { model.stepFocus(settings.realPositions, settings.busPosition == "estimated"); delay(1_000) } }
            launch { while (true) { now = Iso.now(); model.refreshBoard(); model.refreshNext(); nl.haltewekker.travel.TimeToGo.check(context, model.next.value.firstOrNull(), Iso.now()); delay(20_000) } }
            launch {
                var k = 0
                while (true) {
                    if (k % 10 == 0) model.refreshVehicles(settings.realPositions) else model.moveOn()
                    k++; delay(3_000)
                }
            }
        }
    }

    val dark = androidx.compose.foundation.isSystemInDarkTheme()
    val f = focus
    val focusDots = if (sheet || f == null) emptyList() else listOfNotNull(
        f.placed.ghost?.let { nl.haltewekker.map.MapDot("ghost", it, f.color, kind = "ghost") },
        f.placed.point?.let { nl.haltewekker.map.MapDot("focus:${f.ride.tripId}", it, f.color, f.label, "focus", f.placed.tag, if (f.placed.dim) 0.6 else 1.0) })
    val pins = when {
        searchOpen -> search.pins()
        sheet || f == null || f.stop == null -> emptyList()
        else -> listOf(nl.haltewekker.map.MapPin("mystop", f.stop, "${f.label} · ${Fmt.time(f.ride.departure)}", f.color,
            sub = if (f.placed.shown.source == nl.haltewekker.live.RealFirst.Source.NONE) "No live position" else ""))
    }
    val fl = friendsLayer.takeIf { friendsOpen }
    Box(Modifier.fillMaxSize().background(DS.t.page)) {
    Column(Modifier.fillMaxSize()) {
        Box(Modifier.fillMaxWidth().weight(if (sheet) 1f else 0.42f)) {
            LiveMap(Modifier.fillMaxSize(), centre = here ?: profile.home?.point, me = here, dots = if (friendsOpen) emptyList() else dots,
                focus = focusDots, pins = pins, lines = if (searchOpen) search.lines() else emptyList(),
                faces = fl?.pins ?: emptyList(), pictures = friendPictures, stops = fl?.stops ?: emptyList(),
                frame = when { fl != null -> fl.frame; searchOpen -> search.frame(); else -> emptyList() },
                frameMode = if (searchOpen) nl.haltewekker.map.FrameMode.IF_OUTSIDE else nl.haltewekker.map.FrameMode.FIT,
                cover = fl?.cover ?: if (searchOpen) (if (searchUp) 0.92 else 0.5) else 0.0, dark = dark, accent = DS.t.accent.toArgb(),
                onTap = { id ->
                    when {
                        id.startsWith("face:") -> nl.haltewekker.ui.friends.FriendsOverMap.tapped.value = id.removePrefix("face:")
                        id.startsWith("hit:") -> search.hits.firstOrNull { "hit:${it.id}" == id }?.let { h -> search.pick(nl.haltewekker.profile.SavedPlace(h.name, h.lat, h.lon)) }
                    }
                }) { sw, ne, z -> model.setBounds(sw, ne, z) }
            if (!sheet) {
            IconButton(onClick = onSettings, modifier = Modifier.statusBarsPadding().padding(8.dp).align(Alignment.TopEnd)
                .clip(CircleShape).background(DS.t.surface)) {
                Icon(Icons.Filled.Settings, "Settings", tint = DS.t.text)
            }
            // A3: Friends, with requests and new lines as a badge
            nl.haltewekker.ui.friends.FriendsHomeButton(Modifier.statusBarsPadding().padding(top = 8.dp, end = 60.dp).align(Alignment.TopEnd), onFriends)
            // (A8.1, iOS 0.40.0) search over this map
            IconButton(onClick = { searchOpen = true; searchUp = false }, modifier = Modifier.statusBarsPadding().padding(top = 8.dp, end = 112.dp).align(Alignment.TopEnd)
                .clip(CircleShape).background(DS.t.surface)) {
                Icon(Icons.Filled.Search, "Search a place", tint = DS.t.text)
            }
            // the ride made smaller (iOS 0.26.1): the bar over the map while a trip runs
            if (ride != null) RideBarView(ride, settings.ringAtStop, now, Modifier.statusBarsPadding().padding(start = 8.dp, end = 164.dp, top = 8.dp)
                .align(Alignment.TopStart), onRide)
            }
        }
        if (!sheet)         Column(Modifier.fillMaxWidth().weight(0.58f).verticalScroll(rememberScrollState()).padding(horizontal = 12.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (testLive) Card {
                Text("Test setup", fontWeight = FontWeight.Bold, color = DS.t.text)
                Text("You're trying the setup as a new user.", color = DS.t.secondary)
                QuietButton("Back to my own") { TestSetup.backToOwn(context) }
            }
            // "Continue your trip" after ending one by hand before its last leg (iOS 0.26.2)
            val r = resume
            if (r != null && ride == null) {
                val leg = r.trip.rides.getOrNull(r.leg)
                val from = leg?.from
                val offered = leg != null && TripResume.offer(r.endedAt, now, idle = true, moving = model.moving(now),
                    metresToItsStop = from?.let { f -> here?.let { nl.haltewekker.core.Geo.metres(it, f) } })
                if (offered && leg != null) Card {
                    Header("Continue your trip?", "to ${r.destination}")
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        LinePill(leg.line, leg.kind); Spacer(Modifier.width(8.dp))
                        Text("${Fmt.time(leg.departure)} from ${leg.fromStop}", color = DS.t.text, modifier = Modifier.weight(1f))
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        QuietButton("Continue") { onResume(r) }
                        QuietButton("No") { ResumeStore.set(context, null) }
                    }
                }
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
                        val habits by nl.haltewekker.travel.HabitStore.book.collectAsState()
                        Text("Leave ${Fmt.inMinutes(nl.haltewekker.travel.WalkWords.leave(first, habits), now)}", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold, color = DS.t.text)
                        WalkLine(first, now)
                        FocusLine(focus, first)
                        TripRow(first, now) { onPlan(dir) }
                        // (A8, iOS 0.40) "Buses from <stop> ▾": the next departures from where you get on
                        FromStopFold(first, next.drop(1), target.planId) { t -> model.putFirst(t) }
                        // (A6, iOS 0.36–0.37) student OV, a change's record, rain on the walk, OV-fiets
                        TripNotes(first, next, now)
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            QuietButton("More trips") { onPlan(dir) }
                            if (ride == null) QuietButton("I'm on it: start the ride") { onStart(first, target.name) }
                        }
                    }
                }
            }
            SchoolHomeCard(onDay = onDay, onSettings = onSettings)
            // (A6) works on your route, the last way home, your year in travel; "Help improve Haltewekker?" once
            HomeTravelCards(here, onYear)
            nl.haltewekker.ui.friends.ShareAskCard()
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
                            if (model.ghostId(d) in unsure) Text(nl.haltewekker.travel.GhostDepartures.UNSURE_SHORT, color = DS.t.warning, style = MaterialTheme.typography.bodySmall)
                            if (d.delay != 0 && !d.cancelled) Text("${if (d.delay > 0) "+" else ""}${d.delay} min", color = DS.t.warning, style = MaterialTheme.typography.bodySmall)
                        }
                    }
                }
            }
            Text("Trips and times: Transitous (MOTIS). Live positions: OVapi and NS. Trains in Belgium: iRail (NMBS/SNCB open data). Map: OpenFreeMap, © OpenStreetMap contributors.",
                color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
            Spacer(Modifier.height(24.dp))
        }
    }
    if (searchOpen) nl.haltewekker.ui.friends.MapSheet(searchUp, { searchUp = it }, 380.dp, onClose = { searchOpen = false; search.q = "" }) {
        SearchSheet(search, canStart = ride == null, onStart = { t, to -> searchOpen = false; onStart(t, to) },
            onMore = { p -> searchOpen = false; onPlanTo(p) }, onClose = { searchOpen = false; search.q = "" })
    }
    if (friendsOpen) nl.haltewekker.ui.friends.FriendsScreen(onBack = onFriendsClose, canStart = ride == null, onStart = onStart, full = friendsFull)
    }
}

/** (A8.1, iOS 0.40.3) where the bus or train you wait for is: "Bus 306 · GPS 40 s · Arriving", "No live position". */
@Composable
private fun FocusLine(f: HomeModel.Focus?, trip: DoorTrip) {
    if (f == null || f.onBoard || f.ride.tripId != trip.first.tripId) return
    val s = f.placed.shown
    val what = if (f.ride.isTrain) f.label else "Bus ${f.label}"
    val where = when (val h = s.here) {
        nl.haltewekker.live.RealFirst.Here.Arriving -> "Arriving"
        is nl.haltewekker.live.RealFirst.Here.Waiting -> nl.haltewekker.live.BusFusion.waitingText(h.leaves) { Fmt.time(it) }
        nl.haltewekker.live.RealFirst.Here.AtStop -> "It’s at your stop"
        null -> null
    }
    val tag = if (s.source == nl.haltewekker.live.RealFirst.Source.NONE) "No live position" else f.placed.tag.replaceFirstChar { it.uppercase() }
    Text(listOfNotNull(what, tag, where).joinToString(" · "), color = if (where != null) DS.t.accentText else DS.t.secondary,
        style = MaterialTheme.typography.bodySmall)
}

/** The ride made smaller: what you're on, the countdown, how the wake-up stands; tap to open it full. */
@Composable
fun RideBarView(r: RideState, ringAtStop: Boolean, now: Double, modifier: Modifier = Modifier, onOpen: () -> Unit) {
    val leg = r.leg
    val vehicle = r.vehicleLine?.let { if (leg?.isTrain == true) it else "Bus $it" }
    val wake = RideBar.wake(r.phase, r.vehicleSource != nl.haltewekker.ride.VehicleSource.NONE)
    Row(modifier.fillMaxWidth().shadow(4.dp, RoundedCornerShape(20.dp)).clip(RoundedCornerShape(20.dp))
        .background(if (r.phase == Phase.ALARM) DS.t.warning else DS.t.surface).clickable(onClick = onOpen).padding(12.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        if (leg != null) LinePill(r.vehicleLine ?: leg.line, leg.kind)
        Column(Modifier.weight(1f)) {
            Text(RideBar.title(vehicle, leg?.toStop ?: r.destination), color = DS.t.text, fontWeight = FontWeight.Bold, maxLines = 1)
            val d = RideBar.detail(RideBar.countdown(r.legArrival, r.distance, now), r.index, r.trip.rides.size)
            Text(listOf(d, RideBar.wakeText(wake, ringAtStop)).filter { it.isNotEmpty() }.joinToString(" · "), color = DS.t.secondary,
                style = MaterialTheme.typography.bodySmall, maxLines = 1)
        }
    }
}
