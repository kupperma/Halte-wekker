package nl.haltewekker.ui.friends

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import nl.haltewekker.data.DoorTrip
import nl.haltewekker.friends.ChatDelivery
import nl.haltewekker.friends.ChatKey
import nl.haltewekker.friends.ChatMessage
import nl.haltewekker.friends.FriendChats
import nl.haltewekker.friends.FriendStore
import nl.haltewekker.friends.QuickReplies
import nl.haltewekker.friends.TripAnswer
import nl.haltewekker.friends.TripCard
import nl.haltewekker.friends.TravelWords
import nl.haltewekker.ride.RideStore
import nl.haltewekker.ui.BigButton
import nl.haltewekker.ui.Card
import nl.haltewekker.ui.Header
import nl.haltewekker.ui.LegRow
import nl.haltewekker.ui.Note
import nl.haltewekker.ui.QuietButton
import nl.haltewekker.ui.TripRow
import nl.haltewekker.ui.theme.DS

/** A chat: its lines, quick replies, trip cards with "Take this trip" / "I'm in" / "Can't", how far your last line got. */
@Composable
fun ChatScreen(key: String, push: (FriendsRoute) -> Unit, back: () -> Unit) {
    val book by FriendChats.book.collectAsState()
    val groups by FriendStore.groups.collectAsState()
    val pictures by FriendStore.pictures.collectAsState()
    val ride by RideStore.state.collectAsState()
    val me = FriendStore.myAccount ?: ""
    val gid = ChatKey.groupId(key)
    val group = gid?.let { groups.group(it) }
    val title = group?.name ?: FriendStore.book.value?.friend(key)?.name ?: "Chat"
    var text by remember { mutableStateOf("") }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    // every 8 s while the chat is open (friends' trips every 30 s of those)
    LaunchedEffect(key) { lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) { while (true) { FriendStore.sync(FriendStore.Why.CHAT); delay(8_000) } } }
    DisposableEffect(key) { FriendChats.onScreen.value = key; onDispose { if (FriendChats.onScreen.value == key) FriendChats.onScreen.value = null } }
    val lines = book.chat(key)?.messages ?: emptyList()
    LaunchedEffect(lines.size) { FriendChats.read(key) }
    val canWrite = FriendStore.recipients(key).isNotEmpty()
    val list = rememberLazyListState()
    LaunchedEffect(lines.size) { if (lines.isNotEmpty()) list.scrollToItem(lines.size - 1) }
    Column(Modifier.fillMaxSize().background(DS.t.page).safeDrawingPadding().imePadding().padding(horizontal = 12.dp)) {
        FriendsTop(title, back) {
            if (gid != null) TextButton(onClick = { push(FriendsRoute.Group(gid)) }) { Text("Group") }
            else TextButton(onClick = { push(FriendsRoute.Friend(key)) }) { Text("Profile") }
        }
        LazyColumn(Modifier.weight(1f).fillMaxWidth(), state = list, verticalArrangement = Arrangement.spacedBy(6.dp)) {
            item {
                Text("Lines arrive when the other phone opens Haltewekker or is on a trip (there are no push notifications).",
                    color = DS.t.secondary, style = MaterialTheme.typography.bodySmall, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth().padding(8.dp))
            }
            items(lines, key = { it.id }) { m -> Line(m, key, me, gid != null, lines.lastOrNull { it.from == me }?.id == m.id, pictures, push) }
        }
        if (canWrite) {
            val line = ride?.let { r -> r.leg?.let { l -> if (l.isTrain) (r.vehicleLine ?: l.line) + (l.num.takeIf { it.isNotEmpty() }?.let { " $it" } ?: "") else (r.vehicleLine ?: l.line) } }
            Row(Modifier.horizontalScroll(rememberScrollState()).padding(vertical = 4.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                QuickReplies.list(line).forEach { q -> QuietButton(q) { FriendChats.send(q, key) } }
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(text, { text = it }, Modifier.weight(1f), placeholder = { Text("Message") }, maxLines = 4)
                QuietButton("Send") { if (text.isNotBlank()) { FriendChats.send(text, key); text = "" } }
            }
        } else Note(if (gid != null) "You’re no longer in this group: its chat stays to read." else "You’re not friends any more.")
    }
}

@Composable
private fun Line(m: ChatMessage, key: String, me: String, group: Boolean, lastMine: Boolean, pictures: Map<String, ByteArray>, push: (FriendsRoute) -> Unit) {
    if (m.isNote) {
        Text(m.note ?: "", color = DS.t.secondary, style = MaterialTheme.typography.bodySmall, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
        return
    }
    val mine = m.from == me
    Column(Modifier.fillMaxWidth(), horizontalAlignment = if (mine) Alignment.End else Alignment.Start) {
        if (group && !mine) Text(FriendStore.name(m.from), color = DS.t.secondary, style = MaterialTheme.typography.labelSmall)
        Column(Modifier.widthIn(max = 320.dp).clip(RoundedCornerShape(18.dp)).background(if (mine) DS.t.accentSoft else DS.t.surface).padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp)) {
            m.text?.let { Text(it.text, color = if (mine) DS.t.accentSoftText else DS.t.text) }
            m.trip?.let { c ->
                TripCardBody(c, group)
                val answers = FriendChats.book.value.answers(m.n, key)
                if (answers.isNotEmpty()) Text(answers.entries.joinToString(" · ") { (who, a) -> "${FriendStore.name(who)}: ${a.text}" },
                    color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    QuietButton("Take this trip") { push(FriendsRoute.Take(c, key)) }
                    if (!mine) {
                        QuietButton("I’m in") { FriendChats.answer(TripAnswer.YES, m.n, key) }
                        QuietButton("Can’t") { FriendChats.answer(TripAnswer.NO, m.n, key) }
                    }
                }
            }
        }
        if (mine && lastMine) {
            val d = FriendChats.delivery(m, key)
            Text(when (d) {
                ChatDelivery.Waiting -> "Waiting to go"
                ChatDelivery.Sent -> "Sent · arrives when they open Haltewekker"
                is ChatDelivery.Delivered -> if (d.of > 1) "Delivered to ${d.n} of ${d.of}" else "Delivered"
                is ChatDelivery.Read -> if (d.of > 1) "Read by ${d.n} of ${d.of}" else "Read"
            }, color = DS.t.secondary, style = MaterialTheme.typography.labelSmall)
        }
    }
}

/** A group's page: its picture, name and who's in it; the admin adds, removes, renames; anyone leaves. */
@Composable
fun GroupPage(id: String, push: (FriendsRoute) -> Unit, back: () -> Unit) {
    val context = LocalContext.current
    val groups by FriendStore.groups.collectAsState()
    val gp by FriendStore.groupPictures.collectAsState()
    val pictures by FriendStore.pictures.collectAsState()
    val book by FriendStore.book.collectAsState()
    val g = groups.group(id)
    if (g == null) { LaunchedEffect(Unit) { back() }; return }
    val me = FriendStore.myAccount ?: ""
    val admin = g.isAdmin(me)
    var name by remember(g.name) { mutableStateOf(g.name) }
    var adding by remember { mutableStateOf(false) }
    val tt by nl.haltewekker.friends.FriendTimetables.groupsOn.collectAsState()
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        uri ?: return@rememberLauncherForActivityResult
        FriendStore.launch { Pictures.square(context, uri)?.let { FriendStore.setGroupPicture(id, it) } }
    }
    FriendsPage {
        FriendsTop(g.name, back)
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Avatar(g.name, gp[id], 64.dp)
            if (admin) QuietButton("Group picture") { pick.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }
        }
        if (!g.isIn) Note("You’re no longer in this group.")
        if (admin) Card {
            OutlinedTextField(name, { name = it }, Modifier.fillMaxWidth(), label = { Text("Group name") }, singleLine = true)
            QuietButton("Rename") { FriendStore.launch { FriendStore.renameGroup(id, name) } }
        }
        Card {
            Header("Who’s in it", "${g.roster.members.size}")
            g.roster.members.forEach { m ->
                PersonRow(if (m.id == me) "You" else FriendStore.name(m.id), if (m.id == me) FriendStore.myPicture.value else pictures[m.id],
                    if (m.id == g.roster.admin) "Runs the group" else null) {
                    if (admin && m.id != me) TextButton(onClick = { FriendStore.launch { FriendStore.removeFromGroup(id, m.id) } }) { Text("Remove") }
                }
            }
            if (admin) QuietButton("Add friends") { adding = true }
        }
        if (g.isIn) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                QuietButton("Compare timetables") { push(FriendsRoute.Compare(ChatKey.group(id))) }
                QuietButton("Leave the group") { FriendStore.launch { FriendStore.leaveGroup(id) } }
            }
            SwitchRow("Share my timetable with this group", "Members who aren’t your friends get it too.", id in tt) { nl.haltewekker.friends.FriendTimetables.setGroup(id, it) }
        } else QuietButton("Delete this chat") { FriendStore.launch { FriendStore.forgetGroup(id) }; back() }
    }
    if (adding) {
        val candidates = (book?.sortedFriends ?: emptyList()).filter { !g.roster.has(it.id) }
        var picked by remember { mutableStateOf(setOf<String>()) }
        AlertDialog(onDismissRequest = { adding = false }, title = { Text("Add friends") }, text = {
            Column { candidates.forEach { f -> Row(verticalAlignment = Alignment.CenterVertically) { Checkbox(f.id in picked, { picked = if (it) picked + f.id else picked - f.id }); Text(f.name) } }
                if (candidates.isEmpty()) Text("All your friends are in it.") }
        }, confirmButton = { TextButton(onClick = { adding = false; FriendStore.launch { FriendStore.addToGroup(id, picked.toList()) } }) { Text("Add") } },
            dismissButton = { TextButton(onClick = { adding = false }) { Text("Cancel") } })
    }
}

@Composable
fun NewGroupScreen(done: (String) -> Unit, back: () -> Unit) {
    val book by FriendStore.book.collectAsState()
    val pictures by FriendStore.pictures.collectAsState()
    var name by remember { mutableStateOf("") }
    var picked by remember { mutableStateOf(setOf<String>()) }
    var busy by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    FriendsPage {
        FriendsTop("New group", back)
        OutlinedTextField(name, { name = it }, Modifier.fillMaxWidth(), label = { Text("Group name") }, singleLine = true)
        Card {
            Header("Who’s in it", "${picked.size} picked")
            (book?.sortedFriends ?: emptyList()).forEach { f ->
                PersonRow(f.name, pictures[f.id], null, { picked = if (f.id in picked) picked - f.id else picked + f.id }) {
                    Checkbox(f.id in picked, { picked = if (it) picked + f.id else picked - f.id })
                }
            }
        }
        Text("Everyone in it sees the others’ names and pictures. Each line is locked for every member on its own.", color = DS.t.secondary,
            style = MaterialTheme.typography.bodySmall)
        BigButton(if (busy) "Making it…" else "Make the group", enabled = picked.isNotEmpty() && !busy) {
            busy = true
            scope.launch { FriendStore.createGroup(name, picked.toList(), null)?.let(done); busy = false }
        }
    }
}

/** "Take this trip": the card as your way (start the ride when you're on it), or your options for later. */
@Composable
fun TakeScreen(card: TripCard, chat: String, canStart: Boolean, onStart: (DoorTrip, String) -> Unit, back: () -> Unit) {
    val context = LocalContext.current
    var result by remember { mutableStateOf<TakeResult?>(null) }
    LaunchedEffect(card) {
        result = try { TripTaker.take(context, card) } catch (_: Exception) { TakeResult.Cant("No connection right now. Try again in a moment.") }
        // taking it answers "I'm in" if you hadn't
        val me = FriendStore.myAccount
        val line = FriendChats.book.value.chat(chat)?.messages?.firstOrNull { it.trip == card }
        if (result !is TakeResult.Cant && me != null && line != null && line.from != me && FriendChats.book.value.answers(line.n, chat)[me] == null) {
            FriendChats.answer(TripAnswer.YES, line.n, chat)
        }
    }
    FriendsPage {
        FriendsTop("Take this trip", back)
        Card { TripCardBody(card, ChatKey.isGroup(chat)) }
        when (val r = result) {
            null -> CircularProgressIndicator()
            is TakeResult.Cant -> Note(r.why)
            is TakeResult.Ride -> Card {
                Header("Your way", "to ${r.to}")
                Text(r.note, color = DS.t.secondary)
                r.trip.rides.forEach { LegRow(it) }
                Text("Leave ${TravelWords.clock(r.trip.start)} · there ${TravelWords.clock(r.trip.end)}", color = DS.t.text, fontWeight = FontWeight.SemiBold)
                if (canStart) BigButton("I'm on it: start the ride") { onStart(r.trip, r.to) } else Text("A ride is running: end it first.", color = DS.t.secondary)
            }
            is TakeResult.Later -> Card {
                Header("Later", "to ${r.to}")
                Text(r.note, color = DS.t.text)
                val now = System.currentTimeMillis() / 1000.0
                r.trips.forEach { t -> TripRow(t, now) {} }
                Text("Open it again when it’s time to go: “I’m on it” starts the ride and the wake-up alarm.", color = DS.t.secondary,
                    style = MaterialTheme.typography.bodySmall)
                Box {}
            }
        }
    }
}
