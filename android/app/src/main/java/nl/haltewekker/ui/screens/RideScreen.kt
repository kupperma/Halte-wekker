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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import nl.haltewekker.core.Iso
import nl.haltewekker.ride.Phase
import nl.haltewekker.ride.RideService
import nl.haltewekker.ride.RideState
import nl.haltewekker.ride.VehicleSource
import nl.haltewekker.ui.BigButton
import nl.haltewekker.ui.Card
import nl.haltewekker.ui.Fmt
import nl.haltewekker.ui.Header
import nl.haltewekker.ui.HoldButton
import nl.haltewekker.ui.LegRow
import nl.haltewekker.ui.LinePill
import nl.haltewekker.ui.Note
import nl.haltewekker.ui.QuietButton
import nl.haltewekker.ui.theme.DS

/** The ride: what you're on, how far your stop is, when it rings and when you're there; stop the alarm, end it. */
@Composable
fun RideScreen(s: RideState, onBack: () -> Unit) {
    val context = LocalContext.current
    BackHandler(onBack = onBack)
    var now by remember { mutableDoubleStateOf(Iso.now()) }
    LaunchedEffect(Unit) { while (true) { now = Iso.now(); delay(5_000) } }
    val leg = s.leg

    Column(Modifier.fillMaxSize().background(DS.t.page).safeDrawingPadding().verticalScroll(rememberScrollState()).padding(horizontal = 12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            // made smaller (iOS 0.26.1): the ride goes on in the bar over the home
            IconButton(onClick = onBack) { Icon(Icons.Filled.KeyboardArrowDown, "Make smaller", tint = DS.t.text) }
            Text("To ${s.destination}", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, color = DS.t.text, modifier = Modifier.weight(1f))
        }
        if (s.auto) Text("Started by itself when you left the stop.", color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
        when (s.phase) {
            Phase.ALARM -> {
                Card {
                    Text("Wake up", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold, color = DS.t.warning)
                    Text("${leg?.toStop ?: "Your stop"} in about ${Fmt.metres(s.distance ?: s.wakeMetres)}.", color = DS.t.text)
                    if (s.quiet) Text("No headphones: it only vibrates, and rings out loud after a minute.", color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
                    BigButton("Stop alarm") { RideService.send(context, RideService.ACTION_STOP_ALARM) }
                }
            }
            Phase.FINISHED -> Card {
                Text("You're there", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold, color = DS.t.accentText)
                Text("Your trip to ${s.destination} is done.", color = DS.t.text)
                BigButton("Close") { RideService.send(context, RideService.ACTION_END); onBack() }
            }
            else -> {}
        }
        // (A7, iOS 0.34/0.38) "305 or 306?": once, when two are still tied a minute after you left the stop
        s.ask?.let { q -> Card {
            Text(q.title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold, color = DS.t.text)
            Text(q.body, color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                q.ids.forEachIndexed { k, id -> QuietButton(q.answers.getOrElse(k) { "This one" }) { RideService.send(context, RideService.ACTION_ANSWER, trip = id) } }
            }
        } }
        // (A7, iOS 0.39.1) the wrong bus, and another line's bus at your stop
        s.wrongBus?.let { w -> Card {
            Text(w.title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold, color = DS.t.warning)
            Text(w.body, color = DS.t.text)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                QuietButton("Pick again") { RideService.send(context, RideService.ACTION_PICK_AGAIN) }
                QuietButton("Got it") { RideService.send(context, RideService.ACTION_DISMISS, what = "wrong") }
            }
        } }
        s.otherAtStop?.let { o -> Card {
            Text(o.title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold, color = DS.t.warning)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(o.body, color = DS.t.text, modifier = Modifier.weight(1f))
                QuietButton("Close") { RideService.send(context, RideService.ACTION_DISMISS, what = "other") }
            }
        } }
        if (leg != null && s.phase != Phase.FINISHED) Card {
            Header(if (s.trip.rides.size > 1) "Leg ${s.index + 1} of ${s.trip.rides.size}" else "Your ride", s.legArrival?.let { "there ${Fmt.time(it)}" })
            Row(verticalAlignment = Alignment.CenterVertically) {
                LinePill(s.vehicleLine ?: leg.line, leg.kind); Spacer(Modifier.width(8.dp))
                Text("to ${leg.toStop}", color = DS.t.text, fontWeight = FontWeight.SemiBold)
            }
            // (0.10.6) which side you get out at your stop
            s.doorSide?.let { Text(it, color = DS.t.accentText, fontWeight = FontWeight.SemiBold) }
            val d = s.distance
            Text(if (d != null) "${Fmt.metres(d)} to go" else "Waiting for GPS…", style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.Bold, color = DS.t.text)
            val total = (leg.arrival - leg.departure).coerceAtLeast(60.0)
            LinearProgressIndicator(progress = { ((now - leg.departure) / total).coerceIn(0.0, 1.0).toFloat() }, Modifier.fillMaxWidth())
            Text(when (s.phase) {
                Phase.SLEEPING -> "Rings ${Fmt.metres(s.wakeMetres)} before your stop. Sleep well."
                Phase.AWAKE -> "It tells you when you're there."
                else -> ""
            }, color = DS.t.secondary)
            s.note?.let { if (s.phase == Phase.AWAKE) Text(it, color = DS.t.secondary, style = MaterialTheme.typography.bodySmall) }
            if (s.phase == Phase.SLEEPING) Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                val km = s.wakeMetres / 1000
                QuietButton("−") { if (km > 0.5) RideService.send(context, RideService.ACTION_WAKE, km - 0.5) }
                Text("%.1f km".format(km), color = DS.t.text)
                QuietButton("+") { if (km < 15) RideService.send(context, RideService.ACTION_WAKE, km + 0.5) }
            }
            Text(when (s.vehicleSource) {
                VehicleSource.NONE -> "Looking for the ${if (leg.isTrain) "train" else "bus"} you're on…"
                VehicleSource.BY_HAND -> "On ${if (leg.isTrain) leg.line else "bus ${leg.line}"} (you said so)."
                VehicleSource.BY_GPS -> "Found you on ${if (leg.isTrain) s.vehicleLine else "bus ${s.vehicleLine}"}."
                VehicleSource.BY_TIMES -> "On ${if (leg.isTrain) s.vehicleLine else "bus ${s.vehicleLine}"}, by its times."
            }, color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
            if (s.choosing.size > 1) Text("Checking: ${s.choosing.joinToString(" or ")}…", color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
            if (s.vehicleSource == VehicleSource.NONE) QuietButton("I'm on it") { RideService.send(context, RideService.ACTION_ON_IT) }
            // (A7) student OV, rain on the walk and OV-fiets where the last train gets in, for what's left of the trip
            TripNotes(nl.haltewekker.data.DoorTrip(s.trip.rides.drop(s.index), leg.departure, s.trip.end), emptyList(), now)
        }
        // (A8, iOS 0.39) the change ahead: platforms, walk, minutes; a miss with the one you make instead
        if (s.changeLine != null || s.changeMiss != null || s.platformNote != null) Card {
            Header("Your change")
            // (0.10.6) getting off for it: which side
            if (!(s.index > 0 && s.vehicleTripId == null && s.phase == Phase.SLEEPING)) s.doorSide?.let { Text("Get off at ${leg?.toStop ?: "your stop"}: ${it.replaceFirstChar { c -> c.lowercase() }}", color = DS.t.text) }
            // (0.10.1) a train of the trip got another platform, or is cancelled
            s.platformNote?.let { Text(it, color = DS.t.warning, fontWeight = FontWeight.SemiBold) }
            s.changeMiss?.let { Text(it, color = DS.t.warning, fontWeight = FontWeight.SemiBold) }
            s.changeLine?.let { Text(it, color = DS.t.text) }
            if (s.changeSwitch != null) QuietButton("Switch to that one") { RideService.send(context, RideService.ACTION_SWITCH_CHANGE) }
            // (0.10.0, iOS 0.41) at the change: walk there with arrows (or in the maps app)
            val atChange = s.index > 0 && s.vehicleTripId == null && s.phase == Phase.SLEEPING
            val nx = if (atChange) leg else s.trip.rides.getOrNull(s.index + 1)
            val at = nx?.from
            if (atChange && nx != null && at != null) WalkThere(WalkTarget(at, nx.fromStop, nx.platform, nx.departure, walkWhat(nx)))
        }
        if (s.offline) Note("No network: going by the stops and times saved on your phone.")
        s.nextStop?.let { n -> if (s.phase == Phase.SLEEPING) Text("Next: $n" + (s.delayMin?.let { d -> " · " + if (d >= 1) "$d min late" else if (d <= -1) "${-d} min early" else "on time" } ?: ""),
            color = DS.t.secondary, style = MaterialTheme.typography.bodySmall) }
        if (s.roughGPS) Text("Long way to go: GPS every 25 s to save battery, the best again well before your stop.",
            color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
        if (s.index + 1 < s.trip.rides.size) Card {
            Header("After this")
            s.trip.rides.drop(s.index + 1).forEach { LegRow(it) }
        }
        // A3: friends on this ride, the one-time question, the coach picker
        if (s.phase != Phase.FINISHED) nl.haltewekker.ui.friends.RideFriendsCard(s)
        // A4: ask a friend to wait, delays on your rides, the live link (also without friends)
        nl.haltewekker.ui.friends.RideExtrasCards(s)
        if (s.lastFixAt == null && s.phase == Phase.SLEEPING) Note("No GPS yet. The backup alarm still rings by time before your stop.")
        if (s.phase != Phase.FINISHED) HoldButton("Hold to end the trip") { RideService.send(context, RideService.ACTION_END); onBack() }
        Spacer(Modifier.height(24.dp))
    }
}
