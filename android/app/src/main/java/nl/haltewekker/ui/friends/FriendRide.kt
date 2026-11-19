package nl.haltewekker.ui.friends

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import nl.haltewekker.friends.CoachMap
import nl.haltewekker.friends.FriendStore
import nl.haltewekker.friends.FriendTravelShare
import nl.haltewekker.friends.NSCodes
import nl.haltewekker.friends.NSTrains
import nl.haltewekker.friends.TrainDrawing
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
            Text("${FriendStore.name(f.from)} is on this ${if (leg.isTrain) "train" else "bus"}" + (f.state.coach?.let { " · ${CoachMap.label(it)}" } ?: ""),
                color = DS.t.accentText, fontWeight = FontWeight.SemiBold)
        }
        if (same.isEmpty() && !ask) Text(if (sharing > 0) "Friends you show your trips to see this one." else "Friends on their way show here.",
            color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
        if (leg.isTrain) {
            val num = leg.num
            val code = NSCodes.get(context).code(leg.fromId, leg.fromStop)
            var drawing by remember(num, code) { mutableStateOf<TrainDrawing?>(null) }
            LaunchedEffect(num, code) { if (num.isNotEmpty() && code != null) drawing = NSTrains.drawing(num, code) }
            val d = drawing
            if (d != null) {
                val spots = CoachMap.spots(d.units, d.cars)
                Text("Your coach (friends who get on later see where to wait)", color = DS.t.text, style = MaterialTheme.typography.bodySmall)
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    spots.forEach { sp ->
                        val (n, front) = CoachMap.number(sp.drawn, spots.size, d.dir)
                        val picked = coach?.n == n && coach?.of == spots.size
                        Box(Modifier.size(40.dp, 32.dp).clip(RoundedCornerShape(8.dp)).background(if (picked) DS.t.accent else DS.t.surface3)
                            .clickable {
                                FriendTravelShare.setCoach(context, if (picked) null else TravelState.Coach(n, spots.size, front, if (front) null else code), tripId)
                            }, contentAlignment = Alignment.Center) {
                            Text("$n", color = if (picked) Color.White else DS.t.text, fontWeight = FontWeight.SemiBold)
                        }
                    }
                }
                Text(if (d.dir != null) "Numbered from the front of the train." else "Numbered from the left of NS’s drawing at ${leg.fromStop}.",
                    color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
                coach?.let { Text(CoachMap.label(it), color = DS.t.accentText) }
            }
        }
        Text("Last check ${FriendStore.lastChecked.collectAsState().value?.let { TravelWords.clock(it) } ?: "not yet"}.", color = DS.t.secondary,
            style = MaterialTheme.typography.labelSmall, modifier = Modifier.padding(top = 2.dp))
    }
}
