package nl.haltewekker.ui.friends

import android.content.Context
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import nl.haltewekker.App
import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.data.DoorTrip
import nl.haltewekker.data.Ride
import nl.haltewekker.data.Transit
import nl.haltewekker.data.VehicleKind
import nl.haltewekker.friends.ChatKey
import nl.haltewekker.friends.ChatText
import nl.haltewekker.friends.FriendChats
import nl.haltewekker.friends.FriendStore
import nl.haltewekker.friends.FriendWalk
import nl.haltewekker.friends.TripCard
import nl.haltewekker.friends.TripCardWords
import nl.haltewekker.friends.TripTake
import nl.haltewekker.ui.LinePill
import nl.haltewekker.ui.Locator
import nl.haltewekker.ui.QuietButton
import nl.haltewekker.ui.theme.DS

/** A planner's trip as a card, and back (iOS `TripCards`). Home never goes as a place: only its name. */
object TripCards {
    fun ride(r: Ride) = TripCard.Ride(
        mode = if (r.isTrain) "train" else "bus", line = r.line, name = r.name.takeIf { it.isNotEmpty() && it != r.line },
        num = r.num.ifEmpty { null }, trip = r.tripId, head = r.headsign.ifEmpty { null },
        from = TripCard.Spot(r.fromStop, r.fromId.takeIf { it.isNotEmpty() && !it.contains(",") }, r.fromLat, r.fromLon),
        to = TripCard.Spot(r.toStop, null, r.toLat, r.toLon), dep = r.departure, arr = r.arrival,
        sdep = r.scheduledDeparture.takeIf { it != r.departure }, sarr = r.scheduledArrival.takeIf { it != r.arrival },
        plat = r.platform, walk = r.walkBefore.takeIf { it > 0 })

    /** `toName`/`toPoint`: where it goes ("Home" goes without a place: the friend plans to the last stop). */
    fun card(t: DoorTrip, toName: String, toPoint: GeoPoint?, home: Boolean, by: Double? = null): TripCard {
        val dest = if (home) TripCard.Spot("Home") else TripCard.Spot(toName, null, toPoint?.lat, toPoint?.lon)
        return TripCard(t.rides.take(TripCard.MAX_RIDES).map(::ride), dest, null, t.start, t.end, by)
    }

    fun ride(c: TripCard.Ride) = Ride(tripId = c.trip, line = c.line, name = c.name ?: c.line, isTrain = c.mode != "bus", departure = c.dep,
        scheduledDeparture = c.sdep ?: c.dep, arrival = c.arr, scheduledArrival = c.sarr ?: c.arr, fromStop = c.from.name,
        fromId = c.from.id ?: c.from.point?.let { "${it.lat},${it.lon}" } ?: c.from.name, toStop = c.to.name, platform = c.plat,
        walkBefore = c.walk ?: 0, num = c.num ?: "", headsign = c.head ?: "", plannedPlatform = c.plat,
        fromLat = c.from.lat, fromLon = c.from.lon, toLat = c.to.lat, toLon = c.to.lon, mode = if (c.mode == "bus") "BUS" else "")

    fun door(c: TripCard): DoorTrip? {
        val rides = c.rides.map(::ride)
        val f = rides.firstOrNull() ?: return null
        val l = rides.last()
        val start = c.start ?: (f.departure - f.walkBefore * 60)
        return DoorTrip(rides, minOf(start, f.departure), maxOf(c.end ?: l.arrival, l.arrival))
    }
}

/** What "Take this trip" came to (`TripTake.way`). */
sealed class TakeResult {
    /** Your way with the friend's ride, leaving within the hour: start the ride when you're on it. */
    data class Ride(val trip: DoorTrip, val to: String, val note: String) : TakeResult()
    /** Later: your options there by the card's time, the friend's ride first. */
    data class Later(val trips: List<DoorTrip>, val to: String, val by: Double?, val note: String) : TakeResult()
    data class Cant(val why: String) : TakeResult()
}

object TripTaker {
    suspend fun take(c: Context, card: TripCard): TakeResult {
        val app = c.applicationContext as App
        val p = app.store.profile.value
        val now = System.currentTimeMillis() / 1000.0
        val shared = TripTake.shared(card) ?: return TakeResult.Cant("This trip has no bus or train on it.")
        val endSpot = card.to.point?.let { card.to } ?: card.rides.last().to
        val end = endSpot.point
        val (toId, toName) = when {
            end != null && p.school != null && Geo.metres(end, p.school.point) < TripTake.SAME_PLACE_METRES -> p.school.planId to p.school.name
            end != null && p.home != null && Geo.metres(end, p.home.point) < TripTake.SAME_PLACE_METRES -> p.home.planId to "Home"
            end != null -> (endSpot.id ?: "${end.lat},${end.lon}") to endSpot.name
            else -> return TakeResult.Cant("This trip doesn’t say where it goes.")
        }
        val deadline = TripTake.deadline(card) ?: shared.arr
        when (val w = TripTake.way(card, now, p.home?.point, p.school?.point)) {
            TripTake.Way.Gone -> return TakeResult.Cant("That bus or train has left already.")
            TripTake.Way.Fastest -> {
                val here = Locator.last(c)
                if (here == null || TripTake.sameStart(card, here)) TripCards.door(card)?.let { return TakeResult.Ride(it, toName, "The same rides as your friend.") }
                if (here != null) {
                    // 1. the planner from here, an option with their ride
                    val ways = Transit.plan("${here.lat},${here.lon}", toId, deadline, count = 6, maxTransfers = 4, arriveBy = true)
                    TripTake.pick(ways.map { t -> t.rides.map { it.tripId } }, card)?.let { return TakeResult.Ride(ways[it], toName, "Your way, with your friend’s ${shared.label}.") }
                    // 2. onto their ride at a stop of its route you can walk to
                    onto(card, shared, here, now)?.let { return TakeResult.Ride(it, toName, "Walk to their ${shared.label} at a stop nearer you.") }
                }
                return TakeResult.Later(emptyList(), toName, deadline, "No way onto your friend’s ride from here. Plan a trip to $toName by ${TripCardWords.hhmm(deadline)}.")
            }
            is TripTake.Way.BeThereBy, TripTake.Way.Plan -> {
                val from = (w as? TripTake.Way.BeThereBy)?.let { if (it.out) p.home?.planId else p.school?.planId } ?: Locator.last(c)?.let { "${it.lat},${it.lon}" } ?: p.home?.planId
                    ?: return TakeResult.Cant("Set your home first.")
                val ways = Transit.plan(from, toId, deadline, count = 6, maxTransfers = 4, arriveBy = true)
                val i = TripTake.pick(ways.map { t -> t.rides.map { it.tripId } }, card)
                val list = if (i != null) listOf(ways[i]) + ways.filterIndexed { k, _ -> k != i } else ways
                val words = "${TripCardWords.day(deadline, now)}: be at $toName by ${TripCardWords.hhmm(deadline)}" + if (i != null) ", on your friend’s ride." else "."
                return TakeResult.Later(list.take(4), toName, deadline, words)
            }
        }
    }

    private suspend fun onto(card: TripCard, shared: TripCard.Ride, you: GeoPoint, now: Double): DoorTrip? {
        val live = Transit.trip(shared.trip, 120.0) ?: return null
        val stops = live.stops
        val board = stops.indices.minByOrNull { i -> shared.from.point?.let { Geo.metres(it, stops[i].point) } ?: 1e9 } ?: return null
        val alight = ((board + 1) until stops.size).firstOrNull { i -> shared.to.point?.let { Geo.metres(it, stops[i].point) <= 400 } ?: (stops[i].name == shared.to.name) } ?: return null
        val cands = (0 until alight).filter { (stops[it].departure ?: 0.0) > now + 120 }.sortedBy { Geo.metres(you, stops[it].point) }.take(2)
        val after = card.rides.drop(TripTake.sharedIndex(card) + 1).map(TripCards::ride)
        for (i in cands) {
            val s = stops[i]
            val m = Geo.metres(you, s.point)
            if (m >= 900) continue
            val walk = FriendWalk.minutes(m)
            val dep = s.departure ?: continue
            val r = TripCards.ride(shared).copy(fromStop = s.name, fromId = "${s.point.lat},${s.point.lon}", fromLat = s.point.lat, fromLon = s.point.lon,
                departure = dep, scheduledDeparture = dep, walkBefore = walk)
            return DoorTrip(listOf(r) + after, dep - walk * 60, card.end ?: (after.lastOrNull() ?: r).arrival)
        }
        return null
    }
}

/** A card in a chat or the send sheet: the headline and each ride. */
@Composable
fun TripCardBody(c: TripCard, group: Boolean) {
    val now = System.currentTimeMillis() / 1000.0
    Text(TripCardWords.headline(c, now, group), color = DS.t.text, fontWeight = FontWeight.SemiBold)
    c.rides.forEach { r ->
        Row(verticalAlignment = Alignment.CenterVertically) {
            LinePill(r.line, if (r.mode == "bus") VehicleKind.BUS else VehicleKind.of("", r.line, true))
            Spacer(Modifier.width(8.dp))
            Text("${TripCardWords.hhmm(r.dep)} ${r.from.name} → ${r.to.name} ${TripCardWords.hhmm(r.arr)}", color = DS.t.text,
                style = MaterialTheme.typography.bodySmall)
        }
    }
    c.arrival?.let { Text("There at ${TripCardWords.hhmm(it)} · ${c.to.name}", color = DS.t.secondary, style = MaterialTheme.typography.bodySmall) }
}

/** "Send to a friend" under a trip (only with friends): pick friends and groups, add a line, send. */
@Composable
fun SendTripButton(make: () -> TripCard?) {
    val book by FriendStore.book.collectAsState()
    if (book?.friends.isNullOrEmpty()) return
    var card by remember { mutableStateOf<TripCard?>(null) }
    QuietButton("Send to a friend") { card = make() }
    card?.let { SendTripDialog(it, emptySet()) { card = null } }
}

@Composable
fun SendTripDialog(card: TripCard, preselect: Set<String>, onDone: () -> Unit) {
    val book by FriendStore.book.collectAsState()
    val groups by FriendStore.groups.collectAsState()
    var picked by remember { mutableStateOf(preselect) }
    var note by remember { mutableStateOf("") }
    var sent by remember { mutableStateOf<Int?>(null) }
    val scope = rememberCoroutineScope()
    val groupOnly = picked.isNotEmpty() && picked.all { ChatKey.isGroup(it) }
    AlertDialog(onDismissRequest = onDone, title = { Text("Send this trip") }, text = {
        Column(Modifier.heightIn(max = 480.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            TripCardBody(card, groupOnly)
            OutlinedTextField(note, { note = it }, Modifier.fillMaxWidth(), label = { Text("Your line (optional)") },
                placeholder = { Text(TripCardWords.headline(card, System.currentTimeMillis() / 1000.0, groupOnly)) })
            val rows = groups.current.map { ChatKey.group(it.id) to "${it.name} (${it.roster.members.size} people)" } +
                (book?.sortedFriends ?: emptyList()).map { it.id to it.name }
            rows.forEach { (key, label) ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(key in picked, { picked = if (it) picked + key else picked - key })
                    Text(label, color = DS.t.text)
                }
            }
            Text("It arrives when they open Haltewekker (there are no push notifications), or on their next trip.", color = DS.t.secondary,
                style = MaterialTheme.typography.bodySmall)
            sent?.let { Text(if (it > 0) "Sent." else "Couldn’t send it.", color = if (it > 0) DS.t.accentText else DS.t.warning) }
        }
    }, confirmButton = {
        TextButton(enabled = picked.isNotEmpty() && sent == null, onClick = {
            scope.launch {
                val line = ChatText.clean(note)
                val n = FriendChats.sendTrip(card.copy(note = line.ifEmpty { null }), picked.sorted())
                sent = n
                if (n > 0) onDone()
            }
        }) { Text("Send") }
    }, dismissButton = { TextButton(onClick = onDone) { Text("Cancel") } })
}
