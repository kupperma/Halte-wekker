package nl.haltewekker.ui.friends

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.data.DoorTrip
import nl.haltewekker.friends.ChatKey
import nl.haltewekker.friends.ChatWords
import nl.haltewekker.friends.CoachMap
import nl.haltewekker.friends.FriendBook
import nl.haltewekker.friends.FriendChats
import nl.haltewekker.friends.FriendExtrasStore
import nl.haltewekker.friends.FriendLink
import nl.haltewekker.friends.FriendStore
import nl.haltewekker.friends.FriendTimetables
import nl.haltewekker.friends.FriendTravelSeen
import nl.haltewekker.friends.FriendTravelShare
import nl.haltewekker.friends.FriendWords
import nl.haltewekker.friends.NSCodes
import nl.haltewekker.friends.NSTrains
import nl.haltewekker.friends.OpenedCode
import nl.haltewekker.friends.TravelWords
import nl.haltewekker.friends.TripCard
import nl.haltewekker.map.LiveMap
import nl.haltewekker.map.MapDot
import nl.haltewekker.ui.BigButton
import nl.haltewekker.ui.Card
import nl.haltewekker.ui.Header
import nl.haltewekker.ui.Note
import nl.haltewekker.ui.QuietButton
import nl.haltewekker.ui.theme.DS

/** Where Friends is. */
sealed class FriendsRoute {
    data object Hub : FriendsRoute()
    data class Friend(val id: String) : FriendsRoute()
    data class Chat(val key: String) : FriendsRoute()
    data class Group(val id: String) : FriendsRoute()
    data class Compare(val key: String) : FriendsRoute()
    data object NewGroup : FriendsRoute()
    data object Code : FriendsRoute()
    data object Scan : FriendsRoute()
    data object Account : FriendsRoute()
    data class Take(val card: TripCard, val chat: String) : FriendsRoute()
}

@Composable
fun FriendsTop(title: String, onBack: () -> Unit, end: @Composable () -> Unit = {}) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = DS.t.text) }
        Text(title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, color = DS.t.text, modifier = Modifier.weight(1f), maxLines = 1)
        end()
    }
}

@Composable
fun FriendsPage(content: @Composable () -> Unit) {
    Column(Modifier.fillMaxSize().background(DS.t.page).safeDrawingPadding().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        content()
        Spacer(Modifier.height(24.dp))
    }
}

/** Friends: the whole of it, with its own back stack. `onStart` starts a ride (Take this trip). */
@Composable
fun FriendsScreen(onBack: () -> Unit, canStart: Boolean, onStart: (DoorTrip, String) -> Unit) {
    val stack = remember { mutableStateListOf<FriendsRoute>(FriendsRoute.Hub) }
    val toOpen by FriendChats.toOpen.collectAsState()
    val opened by FriendStore.opened.collectAsState()
    LaunchedEffect(toOpen) { toOpen?.let { stack.add(FriendsRoute.Chat(it)); FriendChats.toOpen.value = null } }
    fun push(r: FriendsRoute) { stack.add(r) }
    fun pop() { if (stack.size > 1) stack.removeAt(stack.lastIndex) else onBack() }
    BackHandler { pop() }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    // every 30 s while Friends is open (a chat: every 8 s, its own loop)
    LaunchedEffect(Unit) { lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) { while (true) { FriendStore.sync(FriendStore.Why.SCREEN); delay(30_000) } } }
    when (val r = stack.last()) {
        FriendsRoute.Hub -> FriendsHub(::push, ::pop)
        is FriendsRoute.Friend -> FriendPage(r.id, ::push, ::pop)
        is FriendsRoute.Chat -> ChatScreen(r.key, ::push, ::pop)
        is FriendsRoute.Group -> GroupPage(r.id, ::push, ::pop)
        is FriendsRoute.Compare -> CompareScreen(r.key, ::pop)
        FriendsRoute.NewGroup -> NewGroupScreen({ id -> stack.removeAt(stack.lastIndex); push(FriendsRoute.Chat(ChatKey.group(id))) }, ::pop)
        FriendsRoute.Code -> MyCodeScreen(::pop)
        FriendsRoute.Scan -> ScanScreen(onFound = { FriendStore.opened.value = it; pop() }, onCancel = ::pop)
        FriendsRoute.Account -> AccountScreen(::pop)
        is FriendsRoute.Take -> TakeScreen(r.card, r.chat, canStart, onStart, ::pop)
    }
    opened?.let { code -> OpenedCodeDialog(code) { FriendStore.opened.value = null } }
}

@Composable
private fun OpenedCodeDialog(code: OpenedCode, onDone: () -> Unit) {
    val scope = rememberCoroutineScope()
    var result by remember { mutableStateOf<String?>(null) }
    val has = FriendStore.hasAccount
    AlertDialog(onDismissRequest = onDone, title = { Text(if (code.name.isEmpty()) "Add this friend?" else "Add ${code.name}?") }, text = {
        Text(result ?: if (has) "They get a friend request the next time their app checks in. Nothing else is shared until they say yes."
            else "Make your Friends account first (a name is enough), then open the link again.")
    }, confirmButton = {
        if (has && result == null) TextButton(onClick = {
            scope.launch {
                result = when (FriendStore.add(code)) {
                    FriendBook.Added.SENT, FriendBook.Added.ALREADY_ASKED -> "Request sent. It arrives when ${code.name.ifEmpty { "they" }} open Haltewekker."
                    FriendBook.Added.ACCEPTED -> "You’re friends now."
                    FriendBook.Added.ALREADY_FRIENDS -> "You’re friends already."
                    FriendBook.Added.YOURSELF -> "That’s your own code."
                    null -> "Couldn’t add them."
                }
            }
        }) { Text("Send friend request") } else TextButton(onClick = onDone) { Text("OK") }
    }, dismissButton = { if (has && result == null) TextButton(onClick = onDone) { Text("Cancel") } })
}

@Composable
private fun FriendsHub(push: (FriendsRoute) -> Unit, back: () -> Unit) {
    val context = LocalContext.current
    val book by FriendStore.book.collectAsState()
    val moved by FriendStore.movedAway.collectAsState()
    val pictures by FriendStore.pictures.collectAsState()
    val travelMap by FriendStore.travel.collectAsState()
    val paused by FriendStore.travelPaused.collectAsState()
    val answered by FriendStore.travelAnswered.collectAsState()
    val ttAnswered by FriendTimetables.answered.collectAsState()
    val ttOn by FriendTimetables.on.collectAsState()
    val offline by FriendStore.offline.collectAsState()
    val syncing by FriendStore.syncing.collectAsState()
    val checked by FriendStore.lastChecked.collectAsState()
    val chatBook by FriendChats.book.collectAsState()
    val groups by FriendStore.groups.collectAsState()
    var paste by remember { mutableStateOf("") }
    var wrongLink by remember { mutableStateOf(false) }
    var now by remember { mutableDoubleStateOf(System.currentTimeMillis() / 1000.0) }
    LaunchedEffect(Unit) { while (true) { now = System.currentTimeMillis() / 1000.0; delay(15_000) } }
    FriendsPage {
        FriendsTop("Friends", back) { if (syncing) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp) }
        if (moved) Card {
            Note("Your friends account was restored on another phone, so this one was signed out. Restore it here again with your backup code to move it back.")
            QuietButton("OK") { FriendStore.dismissMoved() }
        }
        val b = book
        if (b == null) { NoAccount(); return@FriendsPage }
        // the one-time screens, with the first friend
        if (b.friends.isNotEmpty() && !answered) ConsentCard()
        if (b.friends.isNotEmpty() && answered && !ttAnswered) TimetableConsentCard()
        val travelling = FriendStore.travelling(now).filter { travelMap.containsKey(it.from) }
        if (travelling.isNotEmpty()) Card {
            Header("Travelling now", "${travelling.size}")
            FriendsMap(travelling)
            travelling.forEach { s -> TravelRow(s, b.friend(s.from)?.name ?: "Friend", pictures[s.from], now) { push(FriendsRoute.Friend(s.from)) } }
        }
        if (b.incoming.isNotEmpty()) Card {
            Header("Want to be friends", "${b.incoming.size}")
            b.incoming.forEach { r ->
                PersonRow(r.name, pictures[r.id], "${r.name} isn’t told if you decline.")
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    QuietButton("Accept") { FriendStore.launch { FriendStore.accept(r.id) } }
                    QuietButton("Decline") { FriendStore.launch { FriendStore.decline(r.id, false) } }
                    QuietButton("Block") { FriendStore.launch { FriendStore.decline(r.id, true) } }
                }
            }
        }
        // (A4) the extras: waits, on campus, delays, free together, the live link, the leaderboard, at school
        ExtrasHubCards(push)
        // chats
        Card {
            val unread = FriendStore.unread.collectAsState().value
            Header("Chats", if (unread > 0) "$unread new" else null)
            val recent = FriendChats.recent
            if (recent.isEmpty()) Text("Write to a friend from their page, or make a group. You can also send a trip from Fastest trip.", color = DS.t.secondary)
            recent.take(8).forEach { c ->
                val gid = ChatKey.groupId(c.key)
                val title = gid?.let { FriendStore.group(it)?.name } ?: b.friend(c.key)?.name ?: "Chat"
                val last = c.last
                PersonRow(title, if (gid != null) FriendStore.groupPictures.value[gid] else pictures[c.key],
                    last?.let { ChatWords.preview(it, FriendStore.myAccount ?: "", FriendStore::name, gid != null) }, { push(FriendsRoute.Chat(c.key)) }) {
                    Badge(chatBook.unread(c.key, FriendStore.myAccount ?: ""))
                }
            }
            groups.current.filter { g -> recent.none { it.key == ChatKey.group(g.id) } }.forEach { g ->
                PersonRow(g.name, FriendStore.groupPictures.value[g.id], "${g.roster.members.size} people", { push(FriendsRoute.Chat(ChatKey.group(g.id))) })
            }
            if (b.friends.isNotEmpty()) QuietButton("New group") { push(FriendsRoute.NewGroup) }
        }
        Card {
            Header("Your friends", if (b.friends.isEmpty()) null else "${b.friends.size}")
            if (b.friends.isEmpty()) Text("No friends yet. Show a friend your code, or send them your link.", color = DS.t.secondary)
            b.sortedFriends.forEach { f ->
                val t = travelMap[f.id]?.let { TravelWords.summary(it.state) }
                PersonRow(f.name, pictures[f.id], t ?: if (!f.showsTrips) "Doesn’t see your trips" else null, { push(FriendsRoute.Friend(f.id)) }) {
                    Badge(chatBook.unread(f.id, FriendStore.myAccount ?: ""))
                }
            }
        }
        if (b.outgoing.isNotEmpty()) Card {
            Header("Waiting for an answer")
            b.outgoing.forEach { r ->
                PersonRow(r.name, pictures[r.id], "Arrives when ${r.name} opens Haltewekker.") {
                    TextButton(onClick = { FriendStore.launch { FriendStore.cancel(r.id) } }) { Text("Take back") }
                }
            }
        }
        Card {
            Header("Add a friend")
            Text("Together, show your code and let them scan it. Apart, send your link through any chat app.", color = DS.t.secondary)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                QuietButton("Show my code") { push(FriendsRoute.Code) }
                QuietButton("Scan a code") { push(FriendsRoute.Scan) }
                QuietButton("Send my link") { shareLink(context) }
            }
            OutlinedTextField(paste, { paste = it; wrongLink = false }, Modifier.fillMaxWidth(), label = { Text("Or paste a friend’s link") }, singleLine = true)
            if (paste.isNotBlank()) QuietButton("Open the link") {
                val c = FriendLink.parse(paste)
                if (c == null) wrongLink = true else { FriendStore.opened.value = OpenedCode(c.first, c.second); paste = "" }
            }
            if (wrongLink) Text("That isn’t a Haltewekker friend link.", color = DS.t.warning, style = MaterialTheme.typography.bodySmall)
        }
        Card {
            Header("Your trips")
            SwitchRow("Show my trips", "While you’re on a bus or train (confirmed on board), friends with it on see where you are and when you arrive. Never at other times.",
                answered && !paused) { FriendStore.setTravelPaused(!it); if (!answered) FriendStore.answerTravel(it) }
            SwitchRow("Share my timetable", "Your classes for the next two weeks and where your trips start (stops, station, school; never your address), for Compare.",
                ttAnswered && ttOn) { FriendTimetables.setOn(it) }
        }
        Card {
            Header("You")
            PersonRow(b.myName.ifEmpty { "You" }, FriendStore.myPicture.collectAsState().value, "Name, picture, backup code", { push(FriendsRoute.Account) })
        }
        val when_ = checked?.let { "Checked ${TravelWords.clock(it)}." } ?: ""
        Text("$when_ There are no push notifications: requests, messages and friends’ trips come in when Haltewekker is open, on a trip, or at a background check about once an hour." +
            if (offline) " No connection to the relay right now." else "", color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
    }
}

fun shareLink(c: Context) {
    val link = FriendStore.shareLink ?: return
    val i = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_SUBJECT, "My Haltewekker friend code")
        .putExtra(Intent.EXTRA_TEXT, "Add me as a friend in Haltewekker: $link")
    c.startActivity(Intent.createChooser(i, "Send my link").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
}

@Composable
private fun ConsentCard() = Card {
    Header("Show your trips to friends?")
    Text("While you’re on a trip and on board, friends see that you’re travelling, on what (bus 305, IC 3512), where you are and when you arrive. " +
        "Nothing is shared when no trip is running. You can turn it off for everyone or per friend.", color = DS.t.text)
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        QuietButton("Show my trips") { FriendStore.answerTravel(true) }
        QuietButton("Not now") { FriendStore.answerTravel(false) }
    }
}

@Composable
private fun TimetableConsentCard() = Card {
    Header("Share your timetable?")
    Text("Friends see your classes for the next two weeks (times, titles, rooms) and where your trips start: the stops near home, the station and your school, never your address. " +
        "Then Compare shows the days and rides you can share.", color = DS.t.text)
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        QuietButton("Share it") { FriendTimetables.answer(true) }
        QuietButton("Not now") { FriendTimetables.answer(false) }
    }
}

@Composable
fun TravelRow(s: FriendTravelSeen, name: String, picture: ByteArray?, now: Double, onClick: (() -> Unit)?) {
    val lines = listOfNotNull(TravelWords.summary(s.state), TravelWords.ending(s.state), TravelWords.age(s, now), s.state.coach?.let { CoachMap.label(it) })
    PersonRow(name, picture, lines.joinToString("\n"), onClick)
}

@Composable
fun FriendsMap(list: List<FriendTravelSeen>) {
    val dots = list.mapNotNull { s -> s.state.pos?.let { MapDot("f-${s.from}", GeoPoint(it.lat, it.lon), 0xFF0E7A55.toInt(), nl.haltewekker.friends.FriendNames.initials(FriendStore.name(s.from))) } }
    if (dots.isEmpty()) return
    val c = GeoPoint(dots.map { it.p.lat }.average(), dots.map { it.p.lon }.average())
    Box(Modifier.fillMaxWidth().height(200.dp)) { LiveMap(Modifier.fillMaxSize(), centre = c, me = null, dots = dots) { _, _, _ -> } }
}

@Composable
private fun NoAccount() {
    val scope = rememberCoroutineScope()
    var name by remember { mutableStateOf("") }
    var words by remember { mutableStateOf("") }
    var restoring by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var trouble by remember { mutableStateOf<String?>(null) }
    var made by remember { mutableStateOf<List<String>?>(null) }
    made?.let { BackupCode(it); BigButton("I wrote them down") { made = null }; return }
    Card {
        Header("Travel with friends")
        Text("Add friends with a code or a link, see when they’re on their way, chat (in groups too), send each other trips, compare timetables and meet halfway. " +
            "Everything is locked end to end: the relay that carries it can’t read any of it.", color = DS.t.text)
        OutlinedTextField(name, { name = it }, Modifier.fillMaxWidth(), label = { Text("Your name (friends see it)") }, singleLine = true)
        if (!restoring) {
            BigButton(if (busy) "Making your account…" else "Make my account", enabled = name.isNotBlank() && !busy) {
                busy = true; trouble = null
                scope.launch {
                    try { FriendStore.create(name); made = FriendStore.backupWords } catch (_: Exception) { trouble = "No connection to the relay. Try again in a moment." }
                    busy = false
                }
            }
            QuietButton("I have a backup code") { restoring = true }
        } else {
            OutlinedTextField(words, { words = it }, Modifier.fillMaxWidth(), label = { Text("Your 12 words, in order") }, minLines = 3)
            Text("The first four letters of each are enough.", color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
            BigButton(if (busy) "Restoring…" else "Restore", enabled = !busy) {
                busy = true; trouble = null
                scope.launch {
                    trouble = try {
                        if (FriendStore.restore(FriendWords.words(words), name)) null else "Restored. No friend list was kept for this account."
                    } catch (_: FriendStore.BadCode) { "Those aren’t 12 words of a backup code. Check each word." }
                    catch (_: Exception) { "No connection to the relay. Try again in a moment." }
                    busy = false
                }
            }
            Text("Restoring here signs out the phone the account was on.", color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
        }
        trouble?.let { Text(it, color = DS.t.warning) }
    }
}

@Composable
fun BackupCode(words: List<String>) = Card {
    Header("Write these 12 words down")
    Text("They are your backup code. On a new phone (Android or iPhone) they bring back your friends account and your friend list. Without them, a new phone means adding your friends again.",
        color = DS.t.text)
    words.chunked(3).forEachIndexed { i, row ->
        Row(Modifier.fillMaxWidth()) {
            row.forEachIndexed { k, w -> Text("${i * 3 + k + 1}. $w", Modifier.weight(1f), fontFamily = FontFamily.Monospace, color = DS.t.text) }
        }
    }
}

@Composable
private fun MyCodeScreen(back: () -> Unit) {
    val context = LocalContext.current
    FriendsPage {
        FriendsTop("My friend code", back)
        val link = FriendStore.shareLink ?: return@FriendsPage
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) { QrCode(link, Modifier.widthIn(max = 320.dp)) }
        Text(FriendStore.myName, style = MaterialTheme.typography.titleLarge, color = DS.t.text, modifier = Modifier.fillMaxWidth(), textAlign = TextAlign.Center)
        Text("Your friend scans this in Haltewekker (Friends › Scan a code), or with their phone’s camera.", color = DS.t.secondary, textAlign = TextAlign.Center)
        BigButton("Send my link instead") { shareLink(context) }
        QuietButton("Copy the link") {
            (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText("Friend link", link))
        }
        Text("The link and the code hold your name and your public keys, nothing else.", color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
    }
}

@Composable
private fun AccountScreen(back: () -> Unit) {
    val context = LocalContext.current
    val book by FriendStore.book.collectAsState()
    val pic by FriendStore.myPicture.collectAsState()
    var name by remember { mutableStateOf(book?.myName ?: "") }
    var showWords by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        uri ?: return@rememberLauncherForActivityResult
        FriendStore.launch { Pictures.square(context, uri)?.let { FriendStore.setPicture(it) } }
    }
    FriendsPage {
        FriendsTop("You in Friends", back)
        Card {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Avatar(name, pic, 64.dp)
                Column(Modifier.weight(1f)) {
                    QuietButton("Pick a picture") { pick.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }
                    if (pic != null) TextButton(onClick = { FriendStore.launch { FriendStore.setPicture(null) } }) { Text("Take it away") }
                }
            }
            OutlinedTextField(name, { name = it }, Modifier.fillMaxWidth(), label = { Text("Your name") }, singleLine = true)
            QuietButton("Save the name") { FriendStore.launch { FriendStore.rename(name) } }
            Text("Your friends get the new name and picture the next time their app checks in.", color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
        }
        if (showWords) FriendStore.backupWords?.let { BackupCode(it) } else Card {
            Header("Backup code")
            Text("12 words that bring your account and friend list back on a new phone.", color = DS.t.secondary)
            QuietButton("Show my backup code") { showWords = true }
        }
        Card {
            Header("Delete my friends account")
            Text("Your friends are told, the relay forgets your account, and your backup code stops working.", color = DS.t.secondary)
            QuietButton("Delete…") { confirmDelete = true }
        }
    }
    if (confirmDelete) AlertDialog(onDismissRequest = { confirmDelete = false }, title = { Text("Delete your friends account?") },
        text = { Text("This can’t be undone.") },
        confirmButton = { TextButton(onClick = { confirmDelete = false; FriendStore.launch { FriendStore.deleteAccount() }; back() }) { Text("Delete") } },
        dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } })
}

@Composable
private fun FriendPage(id: String, push: (FriendsRoute) -> Unit, back: () -> Unit) {
    val book by FriendStore.book.collectAsState()
    val pictures by FriendStore.pictures.collectAsState()
    val travel by FriendStore.travel.collectAsState()
    val off by FriendTimetables.off.collectAsState()
    val ttOn by FriendTimetables.on.collectAsState()
    val ttAnswered by FriendTimetables.answered.collectAsState()
    var confirm by remember { mutableStateOf(false) }
    val f = book?.friend(id)
    if (f == null) { LaunchedEffect(Unit) { back() }; return }
    val now = System.currentTimeMillis() / 1000.0
    FriendsPage {
        FriendsTop(f.name, back)
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Avatar(f.name, pictures[id], 64.dp)
            Text("Friends since ${nl.haltewekker.friends.TimetableDays.short(nl.haltewekker.friends.TimetableDays.key(f.since))}", color = DS.t.secondary)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            QuietButton("Message") { push(FriendsRoute.Chat(id)) }
            QuietButton("Compare timetables") { push(FriendsRoute.Compare(id)) }
        }
        travel[id]?.let { s ->
            Card {
                Header("Travelling now")
                FriendsMap(listOf(s))
                TravelRow(s, f.name, pictures[id], now, null)
                CoachHint(s)
                // (0.29) while they wait at a stop or change there: "Wait for me" at their stop
                if (s.state.stage != nl.haltewekker.friends.TravelState.Stage.RIDING && s.state.from.lat != null)
                    QuietButton("Wait for me") { FriendExtrasStore.startWait(id, nl.haltewekker.friends.DelayAlarm.spot(s.state.from), null) }
            }
        }
        FriendExtrasOnPage(id, f.name)
        Card {
            Header("What ${f.name} sees")
            Text("Your name and picture, and what you write to them.", color = DS.t.secondary)
            SwitchRow("Show my trips to ${f.name}", null, f.showsTrips) { FriendStore.setShowTrips(id, it) }
            SwitchRow("Share my timetable with ${f.name}", if (!ttAnswered || !ttOn) "Off for everyone (Friends › Your trips)" else null, id !in off) { FriendTimetables.setShares(id, it) }
        }
        QuietButton("Remove ${f.name}") { confirm = true }
    }
    if (confirm) AlertDialog(onDismissRequest = { confirm = false }, title = { Text("Remove ${f.name}?") },
        text = { Text("Their keys go from this phone and the boxes between you from the relay. ${f.name}’s app forgets you too.") },
        confirmButton = { TextButton(onClick = { confirm = false; FriendStore.launch { FriendStore.remove(id) }; back() }) { Text("Remove") } },
        dismissButton = { TextButton(onClick = { confirm = false }) { Text("Cancel") } })
}

/** Where to wait for a friend's coach, when you take the same train (NS's drawing at your own boarding station). */
@Composable
private fun CoachHint(s: FriendTravelSeen) {
    val context = LocalContext.current
    val c = s.state.coach ?: return
    val trip = s.state.trip ?: return
    var hint by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(trip, c) {
        val code = FriendTravelShare.boarding(context, trip)
        val num = s.state.num
        hint = if (code == null || num == null) null else {
            val d = NSTrains.drawing(num, code)
            if (d == null) CoachMap.platformHint(c, emptyList(), 0, emptyList(), null, code)
            else CoachMap.platformHint(c, d.units, d.cars, d.letters, d.dir, code)
        }
    }
    hint?.let { Note("You’re on this train too: $it", DS.t.accent) }
    if (hint == null && FriendTravelShare.boarding(context, trip) != null) Note("You’re on this train too: ${CoachMap.label(c)}", DS.t.accent)
}
