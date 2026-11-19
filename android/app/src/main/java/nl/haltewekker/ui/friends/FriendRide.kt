package nl.haltewekker.ui.friends

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import nl.haltewekker.friends.SeatMap
import nl.haltewekker.friends.TransitLabel
import nl.haltewekker.friends.FriendStore
import nl.haltewekker.friends.FriendTravelShare
import nl.haltewekker.friends.NSCodes
import nl.haltewekker.friends.TravelState
import nl.haltewekker.friends.TravelWords
import nl.haltewekker.ride.RideState
import nl.haltewekker.ui.Card
import nl.haltewekker.ui.Header
import nl.haltewekker.ui.QuietButton
import nl.haltewekker.ui.theme.DS

/** On the ride screen: the one-time question once you're on board, friends on the same vehicle, the coach picker on a train. */
@Composable
fun RideFriendsCard(s: RideState) {
    val context = LocalContext.current
    val book by FriendStore.book.collectAsState()
    if (book?.friends.isNullOrEmpty()) return
    val ask by FriendTravelShare.needsAnswer.collectAsState()
    val travel by FriendStore.travel.collectAsState()
    val sharing by FriendStore.sharingWith.collectAsState()
    val coach by FriendTravelShare.coach.collectAsState()
    val leg = s.leg ?: return
    val tripId = s.vehicleTripId ?: leg.tripId
    val same = travel.values.filter { it.state.trip == tripId }
    Card {
        Header("Friends", if (sharing > 0) "${sharing} see your trip" else null)
        if (ask) {
            Text("Show this trip to your friends? They see what you’re on, where you are and when you arrive, only while a trip runs.", color = DS.t.text)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                QuietButton("Show my trips") { FriendStore.answerTravel(true) }
                QuietButton("Not now") { FriendStore.answerTravel(false) }
            }
        }
        same.forEach { f ->
            Text("${FriendStore.name(f.from)} is on this ${if (leg.isTrain) "train" else "bus"}" + (f.state.coach?.let { " · " + SeatMap.label(it).let { l -> l.take(1).lowercase() + l.drop(1) } } ?: ""),
                color = DS.t.accentText, fontWeight = FontWeight.SemiBold)
        }
        if (same.isEmpty() && !ask) Text(if (sharing > 0) "Friends you show your trips to see this one." else "Friends on their way show here.",
            color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
        if (leg.isTrain && FriendTravelShare.stage(s, System.currentTimeMillis() / 1000.0) == TravelState.Stage.RIDING) {
            // (A5, iOS 0.31) the seat picker: your coach, and your window in it
            val code = NSCodes.get(context).code(leg.fromId, leg.fromStop)
            val mine = if (FriendTravelShare.coachTrip.collectAsState().value == tripId) coach else null
            Header("Your seat")
            if (mine != null) Text(SeatMap.label(mine), color = DS.t.text, fontWeight = FontWeight.SemiBold)
            else Text("Tap your coach, then your window: friends on this trip see it, and friends who get on later know where to wait.",
                color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
            TrainSeatPicker(tripId, leg.num.ifEmpty { null }, code, TransitLabel.train(s.vehicleLine ?: leg.line, leg.name), leg.toStop,
                same.mapNotNull { f -> f.state.coach?.let { SeatMark(f.from, FriendStore.name(f.from), it) } }, editable = true)
        }
        Text("Last check ${FriendStore.lastChecked.collectAsState().value?.let { TravelWords.clock(it) } ?: "not yet"}.", color = DS.t.secondary,
            style = MaterialTheme.typography.labelSmall, modifier = Modifier.padding(top = 2.dp))
    }
}
