package nl.haltewekker.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import nl.haltewekker.core.Iso
import nl.haltewekker.data.DoorTrip
import nl.haltewekker.data.Transit
import nl.haltewekker.data.VehicleKind
import nl.haltewekker.travel.FromStop
import nl.haltewekker.travel.GhostDepartures
import nl.haltewekker.travel.HabitStore
import nl.haltewekker.travel.Habits
import nl.haltewekker.travel.WalkWords
import nl.haltewekker.ui.Fmt
import nl.haltewekker.ui.LinePill
import nl.haltewekker.ui.theme.DS

/**
 * (A8, iOS 0.40 "From <stop>") folded away as "Buses from Bolkenplein ▾": the next departures from the stop you get on
 * at (`/v6/stoptimes`, every 30 s while open; a failed answer keeps the last list), the lines that get you there first
 * ("Your trip" tagged), then a few other lines, smaller. Tap one that gets you there: the trip switches to it.
 */
@Composable
fun FromStopFold(trip: DoorTrip, others: List<DoorTrip>, destination: String, onSwitch: (DoorTrip) -> Unit) {
    val first = trip.first
    var open by remember(trip.id) { mutableStateOf(false) }
    var deps by remember(first.fromId) { mutableStateOf<List<FromStop.Dep>>(emptyList()) }
    var now by remember { mutableStateOf(Iso.now()) }
    val scope = rememberCoroutineScope()
    val what = if (first.isTrain) "Trains" else "Buses"
    Text("$what from ${first.fromStop} ${if (open) "▴" else "▾"}", color = DS.t.accentText, style = MaterialTheme.typography.bodyMedium,
        modifier = Modifier.clickable { open = !open }.padding(vertical = 4.dp))
    if (!open) return
    LaunchedEffect(first.fromId) {
        while (true) {
            val b = try { Transit.board(listOf(first.fromId), n = 20) } catch (_: Exception) { emptyList() }
            if (b.isNotEmpty()) deps = b.map { d ->
                FromStop.Dep(d.tripId + "|" + d.time, d.tripId, d.line, d.headsign, d.time, d.scheduled, d.live, d.cancelled, d.platform, d.train, d.stopName.ifEmpty { first.fromStop })
            }
            now = Iso.now()
            delay(30_000)
        }
    }
    val useful = (listOf(trip) + others).filter { it.first.fromId == first.fromId }.map { it.first.line }.toSet()
    val atStop = trip.start + first.walkBefore * 60.0
    val board = FromStop.board(deps, useful, first.tripId, maxOf(now, minOf(atStop, first.departure)), now)
    if (board.isEmpty) { Text("Nothing more from here soon.", color = DS.t.secondary, style = MaterialTheme.typography.bodySmall); return }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        board.useful.forEach { r -> FromRow(r, now, big = true) {
            if (!r.switchable) return@FromRow
            others.firstOrNull { it.first.tripId == r.dep.tripId }?.let { onSwitch(it); return@FromRow }
            scope.launch {
                // the rest planned from that stop, the itinerary whose first ride is that one, your walk to the stop in front
                val p = first.from ?: return@launch
                val plans = try { Transit.plan("${p.lat},${p.lon}", destination, r.dep.time - 60, count = 5) } catch (_: Exception) { emptyList() }
                plans.firstOrNull { it.first.tripId == r.dep.tripId }?.let { t ->
                    val walk = first.walkBefore
                    onSwitch(DoorTrip(listOf(t.first.copy(walkBefore = walk)) + t.rides.drop(1), t.first.departure - walk * 60.0, t.end))
                }
            }
        } }
        board.other.forEach { r -> FromRow(r, now, big = false) {} }
    }
}

@Composable
private fun FromRow(r: FromStop.Row, now: Double, big: Boolean, onTap: () -> Unit) {
    val d = r.dep
    Row(Modifier.fillMaxWidth().alpha(if (r.dimmed) 0.45f else if (big) 1f else 0.75f).clickable(enabled = r.switchable, onClick = onTap),
        verticalAlignment = Alignment.CenterVertically) {
        LinePill(d.line, VehicleKind.of("", d.line, d.train)); Spacer(Modifier.width(8.dp))
        Column(Modifier.weight(1f)) {
            Text(d.headsign.ifEmpty { d.line } + if (r.current) " · Your trip" else "", color = DS.t.text, maxLines = 1,
                fontWeight = if (r.current) FontWeight.SemiBold else FontWeight.Normal)
            val status = when {
                r.status == GhostDepartures.Status.UNSURE -> GhostDepartures.UNSURE_SHORT
                r.late != null -> r.late
                else -> "timetable"
            }
            Text(listOfNotNull(status, FromStop.place(d)).joinToString(" · "), color = if (r.status == GhostDepartures.Status.UNSURE) DS.t.warning else DS.t.secondary,
                style = MaterialTheme.typography.bodySmall)
        }
        Column(horizontalAlignment = Alignment.End) {
            Text(Fmt.time(d.time), color = DS.t.text, fontWeight = FontWeight.SemiBold)
            FromStop.countdown(d, now)?.let { Text(it, color = DS.t.secondary, style = MaterialTheme.typography.bodySmall) }
        }
    }
}

/** (A8, iOS 0.40 `WalkPlan`) "6 min walk · leave in 4 min (2 min spare)" at your own walking speed once learned. */
@Composable
fun WalkLine(trip: DoorTrip, now: Double) {
    val book by HabitStore.book.collectAsState()
    val planned = trip.first.walkBefore
    if (planned <= 0) return
    Text(WalkWords.line(trip, book, now), color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
}
