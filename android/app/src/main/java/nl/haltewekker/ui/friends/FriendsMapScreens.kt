package nl.haltewekker.ui.friends

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.DateRange
import androidx.compose.material.icons.filled.Email
import androidx.compose.material.icons.filled.Face
import androidx.compose.material.icons.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Place
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import nl.haltewekker.App
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.data.VehicleKind
import nl.haltewekker.friends.CampusWords
import nl.haltewekker.friends.ChatKey
import nl.haltewekker.friends.ChatWords
import nl.haltewekker.friends.Friend
import nl.haltewekker.friends.FriendBook
import nl.haltewekker.friends.FriendChats
import nl.haltewekker.friends.FriendExtrasStore
import nl.haltewekker.friends.FriendLink
import nl.haltewekker.friends.FriendRoutes
import nl.haltewekker.friends.FriendStore
import nl.haltewekker.friends.FriendTimetables
import nl.haltewekker.friends.FriendTravelSeen
import nl.haltewekker.friends.FriendTravelShare
import nl.haltewekker.friends.MapFrame
import nl.haltewekker.friends.NSCodes
import nl.haltewekker.friends.OpenedCode
import nl.haltewekker.friends.TestFriendBot
import nl.haltewekker.friends.TestTripSim
import nl.haltewekker.friends.TimetableDays
import nl.haltewekker.friends.TravelAge
import nl.haltewekker.friends.TravelFreshness
import nl.haltewekker.friends.TravelState
import nl.haltewekker.friends.TravelWords
import nl.haltewekker.friends.TripCard
import nl.haltewekker.friends.TripTake
import nl.haltewekker.map.FriendMapPin
import nl.haltewekker.map.FriendsLiveMap
import nl.haltewekker.map.MapStop
import nl.haltewekker.ui.Card
import nl.haltewekker.ui.Header
import nl.haltewekker.ui.LinePill
import nl.haltewekker.ui.Note
import nl.haltewekker.ui.QuietButton
import nl.haltewekker.ui.theme.DS

// Friends (A5, iOS 0.31 "Map first"): with an account, Friends is a full-screen map (friends' faces where they are,
// ringed in their vehicle's colour, campus friends at your school in the accent, their routes) and a sheet over it:
// "Friends · + Add", requests, a card per friend, Chats · Groups · Compare, what's going on now, More (your name and
// picture, your trips, your timetable, extras, requests you sent), the leaderboard and when it last checked. A friend's
// page while they travel: the map framed on their trip, "‹ Friends", and a sheet with the seat picker. Nothing of A3/A4
// went: it moved into the sheet, its tiles and More's pages.

private fun nowS() = System.currentTimeMillis() / 1000.0

@Composable
private fun ticking(every: Long = 15_000): Double {
    var t by remember { mutableDoubleStateOf(nowS()) }
    LaunchedEffect(Unit) { while (true) { delay(every); t = nowS() } }
    return t
}

@Composable
private fun places(): Pair<GeoPoint?, GeoPoint?> {
    val app = LocalContext.current.applicationContext as App
    val p by app.store.profile.collectAsState()
    return p.home?.point to p.school?.point
}

// MARK: the Friends map

@Composable
fun FriendsMapHome(push: (FriendsRoute) -> Unit, back: () -> Unit) {
    val book by FriendStore.book.collectAsState()
    val pictures by FriendStore.pictures.collectAsState()
    FriendStore.travel.collectAsState().value
    FriendExtrasStore.campus.collectAsState().value
    val paths by FriendRoutes.paths.collectAsState()
    val (home, school) = places()
    val now = ticking()
    var up by rememberSaveable { mutableStateOf(false) }
    var menu by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    val travelling = FriendStore.travelling(now)
    val campusList = FriendExtrasStore.onCampus(now)
    val mySchool = FriendExtrasStore.schoolShort()
    // travelling friends where they are; friends on campus at your school
    val pins = mutableListOf<FriendMapPin>()
    val seen = HashSet<String>()
    for (t in travelling) {
        val s = t.state
        val p = s.pos?.let { MapFrame.point(it.lat, it.lon) } ?: continue
        val name = FriendStore.name(t.from)
        pins.add(FriendMapPin(t.from, name, p, ringColour(s).toArgb(), "$name, ${TravelWords.summary(s)}",
            TravelAge.freshness(t, now) == TravelFreshness.STALE, FriendRoutes.route(s, paths)))
        seen.add(t.from)
    }
    if (school != null && MapFrame.valid(school)) {
        val accent = DS.t.accent.toArgb()
        campusList.filter { it.id !in seen && (it.state.school == null || it.state.school == mySchool) }.forEachIndexed { i, c ->
            // side by side, a little apart, so each face can be tapped
            val name = FriendStore.name(c.id)
            pins.add(FriendMapPin(c.id, name, GeoPoint(school.lat, school.lon + i * 0.0012), accent, "$name, ${CampusWords.since(c.state)}", false, emptyList()))
        }
    }
    val frame = pins.map { it.point } + travelling.flatMap { MapFrame.points(it.state) }
    val tripIds = travelling.mapNotNull { it.state.trip }
    LaunchedEffect(tripIds.joinToString(",")) { FriendRoutes.load(tripIds) }
    val dark = isSystemInDarkTheme()
    BoxWithConstraints(Modifier.fillMaxSize().background(DS.t.page)) {
        val peek = 360.dp
        val cover = if (maxHeight.value > 0) minOf(0.8, (peek / maxHeight).toDouble()) else 0.45
        FriendsLiveMap(Modifier.fillMaxSize(), pins, frame, pictures, cover = cover, fallback = listOfNotNull(home, school), dark = dark,
            accent = DS.t.accent.toArgb(), onTap = { push(FriendsRoute.Friend(it)) })
        MapSheet(up, { up = it }, peek) { HubSheet(book, now, push) }
        Row(Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Box {
                MapRoundButton(Icons.Filled.MoreVert, "Your friends account") { menu = true }
                DropdownMenu(menu, { menu = false }) {
                    DropdownMenuItem({ Text("Name and picture") }, { menu = false; push(FriendsRoute.Account) })
                    DropdownMenuItem({ Text("Backup code") }, { menu = false; push(FriendsRoute.Account) })
                    DropdownMenuItem({ Text("Delete my friends account", color = DS.t.warning) }, { menu = false; confirmDelete = true })
                }
            }
            Spacer(Modifier.weight(1f))
            MapRoundButton(Icons.Filled.Close, "Done", back)
        }
    }
    if (confirmDelete) AlertDialog(onDismissRequest = { confirmDelete = false }, title = { Text("Delete your friends account?") },
        text = { Text("Your friends are told, the relay forgets your account, and your backup code stops working.") },
        confirmButton = { TextButton(onClick = { confirmDelete = false; FriendStore.launch { FriendStore.deleteAccount() } }) { Text("Delete my friends account") } },
        dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } })
}

@Composable
private fun HubSheet(b: FriendBook?, now: Double, push: (FriendsRoute) -> Unit) {
    val moved by FriendStore.movedAway.collectAsState()
    val pictures by FriendStore.pictures.collectAsState()
    val answered by FriendStore.travelAnswered.collectAsState()
    val ttAnswered by FriendTimetables.answered.collectAsState()
    val syncing by FriendStore.syncing.collectAsState()
    val unread by FriendStore.unread.collectAsState()
    val friends = b?.sortedFriends ?: emptyList()
    if (moved) Card {
        Note("Your friends account was restored on another phone, so this one was signed out. Restore it here again with your backup code to move it back.")
        QuietButton("OK") { FriendStore.dismissMoved() }
    }
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text("Friends", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold, color = DS.t.text,
            modifier = Modifier.weight(1f).semantics { heading() })
        if (syncing) CircularProgressIndicator(Modifier.size(16.dp).padding(end = 4.dp), strokeWidth = 2.dp)
        Row(Modifier.heightIn(min = DS.hit).clip(CircleShape).clickable { push(FriendsRoute.Page("add")) }.padding(horizontal = 8.dp)
            .semantics(mergeDescendants = true) { contentDescription = "Add a friend" }, verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Add, null, tint = DS.t.accentText, modifier = Modifier.size(20.dp))
            Text("Add", color = DS.t.accentText, fontWeight = FontWeight.SemiBold)
        }
    }
    if (b == null) return
    if (friends.isNotEmpty() && !answered) TripsConsentCard()
    if (friends.isNotEmpty() && answered && !ttAnswered) TimetableAskCard()
    if (b.incoming.isNotEmpty()) Card {
        Header("Want to be friends", "${b.incoming.size}")
        b.incoming.forEach { r ->
            PersonRow(r.name, pictures[r.id], "${r.name} isn’t told if you decline.", id = r.id)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                QuietButton("Accept") { FriendStore.launch { FriendStore.accept(r.id) } }
                QuietButton("Decline") { FriendStore.launch { FriendStore.decline(r.id, false) } }
                QuietButton("Block") { FriendStore.launch { FriendStore.decline(r.id, true) } }
            }
        }
    }
    if (friends.isEmpty()) Card {
        Text("No friends yet. Show a friend your code, or send them your link.", color = DS.t.secondary)
        QuietButton("Add a friend", Modifier.fillMaxWidth()) { push(FriendsRoute.Page("add")) }
        // (iOS 0.30.1) a bot to try it all with
        TestFriendAddCard()
    } else {
        FriendCardsRow(friends, now, pictures) { push(FriendsRoute.Friend(it)) }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            FriendsTile(Icons.Filled.Email, if (unread > 0) "Chats · $unread" else "Chats", Modifier.weight(1f),
                spoken = if (unread > 0) "Chats, $unread new" else "Chats") { push(FriendsRoute.Chats) }
            FriendsTile(Icons.Filled.Face, "Groups", Modifier.weight(1f)) { push(FriendsRoute.Groups) }
            FriendsTile(Icons.Filled.DateRange, "Compare", Modifier.weight(1f),
                spoken = "Compare: timetables with a friend or a group, and meet halfway") { push(FriendsRoute.CompareWith) }
        }
    }
    // (A4) waits for you, your wait, on campus, delays, free together today, the live link while a trip runs
    ExtrasNowCards()
    // (A6, iOS 0.35) a small card with today's best trip (the leaderboard below has both)
    if (friends.isNotEmpty()) TodayTripsCard()
    MoreCard(b, friends, push)
    if (friends.isNotEmpty()) LeaderboardCard()
    LiveLinkIdleNote()
    val offline by FriendStore.offline.collectAsState()
    val checked by FriendStore.lastChecked.collectAsState()
    val whenText = checked?.let { "Checked ${TravelWords.clock(it)}. " } ?: ""
    Text(whenText + "There are no push notifications: requests, messages and friends’ trips come in when Haltewekker is open, on a trip, or at a background check about once an hour." +
        if (offline) " No connection to the relay right now." else "", color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
}

/** The friends in a row: travelling first (newest first), then on campus, then the rest as the list has them. */
@Composable
private fun FriendCardsRow(friends: List<Friend>, now: Double, pictures: Map<String, ByteArray>, open: (String) -> Unit) {
    val moving = FriendStore.travelling(now).associateBy { it.from }
    val campus = FriendExtrasStore.onCampus(now).map { it.id }.toSet()
    val going = friends.filter { moving[it.id] != null }.sortedByDescending { moving[it.id]?.sent ?: 0.0 }
    val there = friends.filter { moving[it.id] == null && it.id in campus }
    val others = friends.filter { moving[it.id] == null && it.id !in campus }
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        (going + there + others).forEach { f -> FriendMiniCard(f, moving[f.id], f.id in campus, pictures[f.id], now) { open(f.id) } }
    }
}

@Composable
private fun TripsConsentCard() = Card {
    Header("Show your trips to friends?")
    Text("While you’re on a trip and on board, friends see that you’re travelling, on what (bus 305, IC 3512), where you are and when you arrive. " +
        "Nothing is shared when no trip is running. You can turn it off for everyone or per friend.", color = DS.t.text)
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        QuietButton("Show my trips") { FriendStore.answerTravel(true) }
        QuietButton("Not now") { FriendStore.answerTravel(false) }
    }
}

@Composable
private fun TimetableAskCard() = Card {
    Header("Share your timetable?")
    Text("Friends see your classes for the next two weeks (times, titles, rooms) and where your trips start: the stops near home, the station and your school, never your address. " +
        "Then Compare shows the days and rides you can share.", color = DS.t.text)
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        QuietButton("Share it") { FriendTimetables.answer(true) }
        QuietButton("Not now") { FriendTimetables.answer(false) }
    }
}

/** More: your name and picture, your trips, your timetable, extras, requests you sent. */
@Composable
private fun MoreCard(b: FriendBook, friends: List<Friend>, push: (FriendsRoute) -> Unit) {
    val answered by FriendStore.travelAnswered.collectAsState()
    val paused by FriendStore.travelPaused.collectAsState()
    val ttOn by FriendTimetables.on.collectAsState()
    val ttAnswered by FriendTimetables.answered.collectAsState()
    val pic by FriendStore.myPicture.collectAsState()
    Card(padding = 12) {
        Header("More")
        PersonRow(b.myName.ifEmpty { "You" }, pic, "You · your name and picture", { push(FriendsRoute.Account) }) { Chevron() }
        if (friends.isNotEmpty()) {
            MoreRow("Your trips", if (!answered) "Off until you say yes" else if (paused) "Paused for everyone" else "Shown while a trip runs") { push(FriendsRoute.Page("trips")) }
            MoreRow("Your timetable", if (ttAnswered && ttOn) "Shared with friends" else "Not shared") { push(FriendsRoute.Page("timetable")) }
            MoreRow("Extras", "At school, free together and more") { push(FriendsRoute.Page("extras")) }
        }
        if (b.outgoing.isNotEmpty()) MoreRow("Requests you sent", if (b.outgoing.size == 1) "1 waiting for an answer" else "${b.outgoing.size} waiting for an answer") {
            push(FriendsRoute.Page("waiting"))
        }
    }
}

@Composable
private fun Chevron() {
    @Suppress("DEPRECATION")
    Icon(Icons.Filled.KeyboardArrowRight, null, tint = DS.t.secondary)
}

@Composable
private fun MoreRow(title: String, detail: String, onClick: () -> Unit) {
    HorizontalDivider(color = DS.t.divider)
    Row(Modifier.fillMaxWidth().heightIn(min = DS.hit).clip(RoundedCornerShape(12.dp)).clickable(onClick = onClick)
        .semantics(mergeDescendants = true) {}.padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, color = DS.t.text, fontWeight = FontWeight.SemiBold)
            Text(detail, color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
        }
        Chevron()
    }
}

// MARK: the sheet's pages (its tiles, More, "+ Add")

@Composable
fun ChatsPage(push: (FriendsRoute) -> Unit, back: () -> Unit) {
    val book by FriendStore.book.collectAsState()
    val pictures by FriendStore.pictures.collectAsState()
    val chatBook by FriendChats.book.collectAsState()
    val groups by FriendStore.groups.collectAsState()
    val unread by FriendStore.unread.collectAsState()
    val b = book ?: return
    FriendsPage {
        FriendsTop("Chats", back)
        Card {
            Header("Chats", if (unread > 0) "$unread new" else null)
            val recent = FriendChats.recent
            if (recent.isEmpty()) Text("Write to a friend from their page, or make a group. You can also send a trip from Fastest trip.", color = DS.t.secondary)
            recent.forEach { c ->
                val gid = ChatKey.groupId(c.key)
                val title = gid?.let { FriendStore.group(it)?.name } ?: b.friend(c.key)?.name ?: "Chat"
                PersonRow(title, if (gid != null) FriendStore.groupPictures.value[gid] else pictures[c.key],
                    c.last?.let { ChatWords.preview(it, FriendStore.myAccount ?: "", FriendStore::name, gid != null) }, { push(FriendsRoute.Chat(c.key)) },
                    id = if (gid == null) c.key else null) {
                    Badge(chatBook.unread(c.key, FriendStore.myAccount ?: ""))
                }
            }
            groups.current.filter { g -> recent.none { it.key == ChatKey.group(g.id) } }.forEach { g ->
                PersonRow(g.name, FriendStore.groupPictures.value[g.id], "${g.roster.members.size} people", { push(FriendsRoute.Chat(ChatKey.group(g.id))) })
            }
            b.sortedFriends.filter { f -> recent.none { it.key == f.id } }.forEach { f ->
                PersonRow(f.name, pictures[f.id], "Write to ${f.name}", { push(FriendsRoute.Chat(f.id)) }, id = f.id)
            }
            if (b.friends.isNotEmpty()) QuietButton("New group") { push(FriendsRoute.NewGroup) }
        }
    }
}

@Composable
fun GroupsPage(push: (FriendsRoute) -> Unit, back: () -> Unit) {
    val groups by FriendStore.groups.collectAsState()
    val chatBook by FriendChats.book.collectAsState()
    val book by FriendStore.book.collectAsState()
    val list = groups.shown
    FriendsPage {
        FriendsTop("Groups", back)
        Card {
            Header("Your groups", if (list.isEmpty()) null else "${list.size}")
            if (list.isEmpty()) Text("No groups yet. Make one to chat, compare timetables and meet halfway with a few friends at once.", color = DS.t.secondary)
            list.forEach { g ->
                PersonRow(g.name, FriendStore.groupPictures.value[g.id], if (!g.isIn) "You’re no longer in it" else "${g.roster.members.size} people",
                    { push(FriendsRoute.Chat(ChatKey.group(g.id))) }) { Badge(chatBook.unread(ChatKey.group(g.id), FriendStore.myAccount ?: "")) }
            }
            if (book?.friends?.isNotEmpty() == true) QuietButton("New group") { push(FriendsRoute.NewGroup) }
        }
    }
}

@Composable
fun CompareWithPage(push: (FriendsRoute) -> Unit, back: () -> Unit) {
    val book by FriendStore.book.collectAsState()
    val groups by FriendStore.groups.collectAsState()
    val pictures by FriendStore.pictures.collectAsState()
    FriendsPage {
        FriendsTop("Compare", back)
        Card {
            Header("Compare timetables")
            Text("Classes side by side this week and next, rides together, free time and meet halfway.", color = DS.t.secondary)
            groups.current.forEach { g ->
                PersonRow(g.name, FriendStore.groupPictures.value[g.id], "Group · ${g.roster.members.size} people", { push(FriendsRoute.Compare(ChatKey.group(g.id))) })
            }
            (book?.sortedFriends ?: emptyList()).forEach { f ->
                PersonRow(f.name, pictures[f.id], "Compare with ${f.name}", { push(FriendsRoute.Compare(ChatKey.friend(f.id))) }, id = f.id)
            }
        }
    }
}

/** A page of More (or "+ Add"): add, trips, timetable, extras, waiting. */
@Composable
fun MorePage(kind: String, push: (FriendsRoute) -> Unit, back: () -> Unit) {
    val context = LocalContext.current
    val book by FriendStore.book.collectAsState()
    val pictures by FriendStore.pictures.collectAsState()
    val answered by FriendStore.travelAnswered.collectAsState()
    val paused by FriendStore.travelPaused.collectAsState()
    val ttAnswered by FriendTimetables.answered.collectAsState()
    val ttOn by FriendTimetables.on.collectAsState()
    var paste by remember { mutableStateOf("") }
    var wrongLink by remember { mutableStateOf(false) }
    FriendsPage {
        when (kind) {
            "add" -> {
                FriendsTop("Add a friend", back)
                Card {
                    Header("Add a friend")
                    Text("Together, show your code and let them scan it. Apart, send your link through any chat app.", color = DS.t.secondary)
                    QuietButton("Show my code", Modifier.fillMaxWidth()) { push(FriendsRoute.Code) }
                    QuietButton("Scan a code", Modifier.fillMaxWidth()) { push(FriendsRoute.Scan) }
                    QuietButton("Send my link", Modifier.fillMaxWidth()) { shareLink(context) }
                    OutlinedTextField(paste, { paste = it; wrongLink = false }, Modifier.fillMaxWidth(), label = { Text("Or paste a friend’s link") }, singleLine = true)
                    if (paste.isNotBlank()) QuietButton("Open the link") {
                        val c = FriendLink.parse(paste)
                        if (c == null) wrongLink = true else { FriendStore.opened.value = OpenedCode(c.first, c.second); paste = "" }
                    }
                    if (wrongLink) Text("That isn’t a Haltewekker friend link.", color = DS.t.warning, style = MaterialTheme.typography.bodySmall)
                }
                // (iOS 0.30.1) a bot to try it all with
                if (FriendStore.hasAccount) Card { Header("Test friend"); TestFriendAddCard() }
            }
            "trips" -> {
                FriendsTop("Your trips", back)
                Card {
                    Header("Your trips")
                    SwitchRow("Show my trips", "While you’re on a bus or train (confirmed on board), friends with it on see where you are and when you arrive. Never at other times.",
                        answered && !paused) { FriendStore.setTravelPaused(!it); if (!answered) FriendStore.answerTravel(it) }
                    Text("Per friend: on their page, under “What … sees”.", color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
                }
            }
            "timetable" -> {
                FriendsTop("Your timetable", back)
                Card {
                    Header("Your timetable")
                    SwitchRow("Share my timetable", "Your classes for the next two weeks and where your trips start (stops, station, school; never your address), for Compare.",
                        ttAnswered && ttOn) { FriendTimetables.setOn(it) }
                }
            }
            "extras" -> {
                FriendsTop("Extras", back)
                AtSchoolCard()
            }
            else -> {
                FriendsTop("Requests you sent", back)
                Card {
                    Header("Waiting for an answer")
                    val out = book?.outgoing ?: emptyList()
                    if (out.isEmpty()) Text("Nothing waiting.", color = DS.t.secondary)
                    out.forEach { r ->
                        PersonRow(r.name, pictures[r.id], "Asked ${TimetableDays.short(TimetableDays.key(r.at))} · arrives when ${r.name} opens Haltewekker") {
                            TextButton(onClick = { FriendStore.launch { FriendStore.cancel(r.id) } }) { Text("Cancel") }
                        }
                    }
                }
            }
        }
    }
}

// MARK: a friend's page

@Composable
fun FriendMapPage(id: String, push: (FriendsRoute) -> Unit, back: () -> Unit) {
    val book by FriendStore.book.collectAsState()
    val travel by FriendStore.travel.collectAsState()
    val pictures by FriendStore.pictures.collectAsState()
    val paths by FriendRoutes.paths.collectAsState()
    val now = ticking(30_000)
    val f = book?.friend(id)
    if (f == null) { LaunchedEffect(Unit) { back() }; return }
    val t = travel[id]?.takeIf { TravelAge.freshness(it, now) != TravelFreshness.GONE }
    var up by rememberSaveable { mutableStateOf(false) }
    if (t == null || MapFrame.points(t.state).isEmpty()) {
        FriendsPage {
            FriendsTop(f.name, back)
            FriendPageContent(f, t, now, push, back)
        }
        return
    }
    val s = t.state
    LaunchedEffect(s.trip) { s.trip?.let { FriendRoutes.load(listOf(it)) } }
    val stale = TravelAge.freshness(t, now) == TravelFreshness.STALE
    val pins = listOfNotNull(s.pos?.let { MapFrame.point(it.lat, it.lon) }?.let { p ->
        FriendMapPin(f.id, f.name, p, ringColour(s).toArgb(), "${f.name}, ${TravelWords.summary(s)}", stale, FriendRoutes.route(s, paths))
    })
    val stops = listOfNotNull(MapFrame.point(s.from.lat, s.from.lon)?.let { MapStop("from", s.from.name, it) },
        MapFrame.point(s.to.lat, s.to.lon)?.let { MapStop("to", s.to.name, it) })
    val dark = isSystemInDarkTheme()
    BoxWithConstraints(Modifier.fillMaxSize().background(DS.t.page)) {
        val peek = 400.dp
        val cover = if (maxHeight.value > 0) minOf(0.8, (peek / maxHeight).toDouble()) else 0.45
        FriendsLiveMap(Modifier.fillMaxSize(), pins, MapFrame.points(s), pictures, stops, cover, dark = dark, accent = DS.t.accent.toArgb())
        MapSheet(up, { up = it }, peek) { FriendPageContent(f, t, now, push, back) }
        Box(Modifier.statusBarsPadding().padding(horizontal = 16.dp, vertical = 8.dp)) { MapBackPill("Friends", back) }
    }
}

@Composable
private fun FriendPageContent(f: Friend, t: FriendTravelSeen?, now: Double, push: (FriendsRoute) -> Unit, back: () -> Unit) {
    val bot by TestFriendBot.account.collectAsState()
    val isBot = bot == f.id
    FriendHeader(f, t?.state, isBot, push)
    if (t != null) TripPart(f, t, now)
    FriendActions(f, t?.state, push)
    // (iOS 0.30.1) the test friend's buttons (its own "Remove" among them)
    if (isBot) TestFriendControls(back)
    // (A4) on campus, the wake-up buddy, rides together
    FriendExtrasOnPage(f.id, f.name)
    FriendSeesCard(f)
    if (!isBot) RemoveFriendButton(f, back)
}

@Composable
private fun FriendHeader(f: Friend, s: TravelState?, isBot: Boolean, push: (FriendsRoute) -> Unit) {
    val pictures by FriendStore.pictures.collectAsState()
    val chatBook by FriendChats.book.collectAsState()
    val unread = chatBook.unread(f.id, FriendStore.myAccount ?: "")
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        val ring = s?.let { ringColour(it) } ?: androidx.compose.ui.graphics.Color.Transparent
        Box(Modifier.size(62.dp).border(3.dp, ring, CircleShape).padding(3.dp)) { Avatar(f.name, pictures[f.id], 56.dp) }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(f.name, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, color = DS.t.text, maxLines = 2,
                    modifier = Modifier.weight(1f, fill = false).semantics { heading() })
                if (isBot) TestFriendTag()
            }
            if (s != null) Row(Modifier.semantics(mergeDescendants = true) {}, verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                s.line?.let { LinePill(it, VehicleKind.of(if (s.isTrain) "" else s.mode, it, s.isTrain)) }
                Text(TravelWords.headline(s), color = DS.t.secondary, style = MaterialTheme.typography.bodyMedium)
            } else Text("Friends since ${TimetableDays.short(TimetableDays.key(f.since))}", color = DS.t.secondary, style = MaterialTheme.typography.bodyMedium)
        }
        Box {
            Box(Modifier.size(52.dp, DS.hit).clip(RoundedCornerShape(14.dp)).background(DS.t.accent).clickable { push(FriendsRoute.Chat(f.id)) }
                .semantics { contentDescription = if (unread > 0) "Message ${f.name}, $unread new" else "Message ${f.name}" }, contentAlignment = Alignment.Center) {
                Icon(Icons.Filled.Email, null, tint = androidx.compose.ui.graphics.Color.White)
            }
            if (unread > 0) Text("$unread", Modifier.align(Alignment.TopEnd).offset(6.dp, (-6).dp).clip(CircleShape).background(DS.t.warning)
                .padding(horizontal = 6.dp), color = androidx.compose.ui.graphics.Color.White, fontWeight = FontWeight.Bold, fontSize = 12.sp)
        }
    }
}

@Composable
private fun TripPart(f: Friend, t: FriendTravelSeen, now: Double) {
    val context = LocalContext.current
    val s = t.state
    val stale = TravelAge.freshness(t, now) == TravelFreshness.STALE
    Column(Modifier.fillMaxWidth().alpha(if (stale) 0.8f else 1f), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        TravelWords.age(t, now)?.let { Text(it, color = DS.t.warning, style = MaterialTheme.typography.bodySmall) }
        val from = if (s.stage == TravelState.Stage.CHANGE) "Changing at ${s.from.name}" else "From ${s.from.name}"
        val legs = if ((s.legs ?: 1) > 1) " · leg ${s.leg ?: 1} of ${s.legs ?: 1}" else ""
        Column {
            Text(from + legs, color = DS.t.secondary, style = MaterialTheme.typography.bodyMedium)
            TravelWords.ending(s)?.let { Text(it, color = DS.t.secondary, style = MaterialTheme.typography.bodyMedium) }
        }
        val trip = s.trip
        if (s.isTrain && trip != null && s.stage != TravelState.Stage.CHANGE) {
            // the NS station whose drawing the picker uses: theirs (the coach's), yours when you take this train, else the one where they got on
            val mine = FriendTravelShare.boarding(context, trip)
            val station = s.coach?.at?.takeIf { it.isNotEmpty() } ?: mine ?: MapFrame.point(s.from.lat, s.from.lon)?.let { p ->
                TestTripSim.nearestStation(p, NSCodes.get(context).stations, 600.0)?.code
            }
            TrainSeatPicker(trip, s.num, station, s.line, s.dest?.name ?: s.to.name, s.coach?.let { listOf(SeatMark(f.id, f.name, it)) } ?: emptyList(),
                editable = mine != null, coaches = s.coach?.of ?: 0)
        }
        val c = s.coach
        if (c != null && s.isTrain) FriendCoachNote(c, s, f.name)
    }
}

@Composable
private fun FriendActions(f: Friend, s: TravelState?, push: (FriendsRoute) -> Unit) {
    val myWait by FriendExtrasStore.myWait.collectAsState()
    val card: TripCard? = s?.let { TripTake.rideAlong(it, nowS()) }
    val waitStop: TripCard.Spot? = s?.takeIf { it.stage != TravelState.Stage.RIDING }?.let { st ->
        val lat = st.from.lat ?: return@let null
        val lon = st.from.lon ?: return@let null
        TripCard.Spot(st.from.name, null, lat, lon)
    }
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        FriendsTile(Icons.Filled.DateRange, "Compare", Modifier.weight(1f),
            spoken = "Compare: classes side by side this week and next, rides together and meet halfway") { push(FriendsRoute.Compare(ChatKey.friend(f.id))) }
        if (card != null) FriendsTile(Icons.AutoMirrored.Filled.ArrowForward, "Ride along", Modifier.weight(1f),
            spoken = "Ride along: plans your way onto ${f.name}’s bus or train") { push(FriendsRoute.Take(card, f.id)) }
        if (waitStop != null) {
            val asked = myWait?.chat == f.id && myWait?.stop?.name == waitStop.name
            FriendsTile(Icons.Filled.Place, if (asked) "Asked to wait" else "Wait for me", Modifier.weight(1f), enabled = !asked,
                spoken = if (asked) "Asked to wait" else "Wait for me: sends how far you are from ${waitStop.name}, updated while you come closer") {
                FriendExtrasStore.startWait(f.id, waitStop, null)
            }
        }
    }
}

@Composable
private fun FriendSeesCard(f: Friend) {
    val off by FriendTimetables.off.collectAsState()
    val ttOn by FriendTimetables.on.collectAsState()
    val ttAnswered by FriendTimetables.answered.collectAsState()
    Card {
        Header("What ${f.name} sees")
        Text("Your name and picture, and what you write to them.", color = DS.t.secondary)
        SwitchRow("Show my trips to ${f.name}", null, f.showsTrips) { FriendStore.setShowTrips(f.id, it) }
        SwitchRow("Share my timetable with ${f.name}", if (!ttAnswered || !ttOn) "Off for everyone (Friends › More › Your timetable)" else null, f.id !in off) {
            FriendTimetables.setShares(f.id, it)
        }
    }
}

@Composable
private fun RemoveFriendButton(f: Friend, back: () -> Unit) {
    var confirm by remember { mutableStateOf(false) }
    QuietButton("Remove ${f.name}", Modifier.fillMaxWidth()) { confirm = true }
    if (confirm) AlertDialog(onDismissRequest = { confirm = false }, title = { Text("Remove ${f.name}?") },
        text = { Text("Their keys go from this phone and the boxes between you from the relay. ${f.name}’s app forgets you too.") },
        confirmButton = { TextButton(onClick = { confirm = false; FriendStore.launch { FriendStore.remove(f.id) }; back() }) { Text("Remove") } },
        dismissButton = { TextButton(onClick = { confirm = false }) { Text("Cancel") } })
}

