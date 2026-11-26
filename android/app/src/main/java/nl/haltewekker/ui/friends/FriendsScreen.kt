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
    /** (A5) The Friends sheet's tiles: all chats, the groups, whom to compare with; a page of More (or "+ Add"). */
    data object Chats : FriendsRoute()
    data object Groups : FriendsRoute()
    data object CompareWith : FriendsRoute()
    data class Page(val kind: String) : FriendsRoute()
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
fun FriendsScreen(onBack: () -> Unit, canStart: Boolean, onStart: (DoorTrip, String) -> Unit, full: Boolean = false) {
    val stack = remember { mutableStateListOf<FriendsRoute>(FriendsRoute.Hub) }
    val toOpen by FriendChats.toOpen.collectAsState()
    val opened by FriendStore.opened.collectAsState()
    LaunchedEffect(toOpen) { toOpen?.let { stack.add(FriendsRoute.Chat(it)); FriendChats.toOpen.value = null } }
    fun push(r: FriendsRoute) { stack.add(r) }
    fun pop() { if (stack.size > 1) stack.removeAt(stack.lastIndex) else onBack() }
    BackHandler { pop() }
    // (A8.1) a face tapped on the home map opens their page in the sheet
    val tapped by FriendsOverMap.tapped.collectAsState()
    LaunchedEffect(tapped) { tapped?.let { id -> FriendsOverMap.tapped.value = null; if ((stack.last() as? FriendsRoute.Friend)?.id != id) push(FriendsRoute.Friend(id)) } }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    // every 30 s while Friends is open (a chat: every 8 s, its own loop)
    LaunchedEffect(Unit) { lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) { while (true) { FriendStore.sync(FriendStore.Why.SCREEN); delay(30_000) } } }
    when (val r = stack.last()) {
        FriendsRoute.Hub -> FriendsHub(::push, ::pop, full)
        is FriendsRoute.Friend -> FriendMapPage(r.id, ::push, ::pop)
        is FriendsRoute.Chat -> ChatScreen(r.key, ::push, ::pop)
        is FriendsRoute.Group -> GroupPage(r.id, ::push, ::pop)
        is FriendsRoute.Compare -> CompareScreen(r.key, ::pop)
        FriendsRoute.NewGroup -> NewGroupScreen({ id -> stack.removeAt(stack.lastIndex); push(FriendsRoute.Chat(ChatKey.group(id))) }, ::pop)
        FriendsRoute.Code -> MyCodeScreen(::pop)
        FriendsRoute.Scan -> ScanScreen(onFound = { FriendStore.opened.value = it; pop() }, onCancel = ::pop)
        FriendsRoute.Account -> AccountScreen(::pop)
        is FriendsRoute.Take -> TakeScreen(r.card, r.chat, canStart, onStart, ::pop)
        FriendsRoute.Chats -> ChatsPage(::push, ::pop)
        FriendsRoute.Groups -> GroupsPage(::push, ::pop)
        FriendsRoute.CompareWith -> CompareWithPage(::push, ::pop)
        is FriendsRoute.Page -> MorePage(r.kind, ::push, ::pop)
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

/** Friends' first page: with an account (A5) the map and its sheet; without one, making it (or restoring it). */
@Composable
private fun FriendsHub(push: (FriendsRoute) -> Unit, back: () -> Unit, full: Boolean = false) {
    val book by FriendStore.book.collectAsState()
    val moved by FriendStore.movedAway.collectAsState()
    if (book != null) { FriendsMapHome(push, back, full); return }
    FriendsPage {
        FriendsTop("Friends", back)
        if (moved) Card {
            Note("Your friends account was restored on another phone, so this one was signed out. Restore it here again with your backup code to move it back.")
            QuietButton("OK") { FriendStore.dismissMoved() }
        }
        NoAccount()
    }
}

fun shareLink(c: Context) {
    val link = FriendStore.shareLink ?: return
    val i = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_SUBJECT, "My Haltewekker friend code")
        .putExtra(Intent.EXTRA_TEXT, "Add me as a friend in Haltewekker: $link")
    c.startActivity(Intent.createChooser(i, "Send my link").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
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
