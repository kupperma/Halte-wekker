package nl.haltewekker.ui.friends

import android.content.Context
import android.content.Intent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.heightIn
import androidx.compose.material3.AlertDialog
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
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import nl.haltewekker.friends.CampusWords
import nl.haltewekker.friends.ChatKey
import nl.haltewekker.friends.DelayWords
import nl.haltewekker.friends.FreeToday
import nl.haltewekker.friends.FriendChats
import nl.haltewekker.friends.FriendExtrasStore
import nl.haltewekker.friends.FriendStore
import nl.haltewekker.friends.FriendTogetherStore
import nl.haltewekker.friends.LiveLinkStore
import nl.haltewekker.friends.LiveWords
import nl.haltewekker.friends.RideHistoryWords
import nl.haltewekker.friends.ScoreBoard
import nl.haltewekker.friends.ScoresRules
import nl.haltewekker.friends.TimetableDays
import nl.haltewekker.friends.TravelFreshness
import nl.haltewekker.friends.TripAnswer
import nl.haltewekker.friends.TripCard
import nl.haltewekker.friends.TripTake
import nl.haltewekker.friends.WaitAge
import nl.haltewekker.friends.WaitAnswer
import nl.haltewekker.friends.WaitWords
import nl.haltewekker.logs.LogShareStore
import nl.haltewekker.ride.RideState
import nl.haltewekker.ui.Card
import nl.haltewekker.ui.Header
import nl.haltewekker.ui.Note
import nl.haltewekker.ui.QuietButton
import nl.haltewekker.ui.theme.DS

// The Friends extras' screens (iOS `FriendsExtrasViews.swift`, `FriendsExtrasBViews.swift`): "Wait for me", the delays
// on shared rides, on campus, free together today, the live link, the leaderboard with friends, Friends › At school, a
// friend's buddy switch and rides together; and Settings › Help improve Haltewekker (shared ride logs).

private fun now() = System.currentTimeMillis() / 1000.0

@Composable
private fun ticking(every: Long = 15_000): Double {
    var t by remember { mutableDoubleStateOf(now()) }
    LaunchedEffect(Unit) { while (true) { delay(every); t = now() } }
    return t
}

private fun chatName(key: String): String =
    ChatKey.groupId(key)?.let { FriendStore.group(it)?.name ?: "the group" } ?: FriendStore.name(key)

// MARK: Friends (the hub)

/** (A5) What's going on now, in the Friends sheet: waits, your wait, on campus, delays, free together, the live link. */
@Composable
fun ExtrasNowCards() {
    WaitsForYouCard(null)
    YourWaitCard()
    OnCampusCard()
    DelaysCard(null)
    FreeTogetherCard()
    LiveLinkCard(idleNote = false)
}

/** (A5) The live link's one line when no trip runs (at the sheet's end). */
@Composable
fun LiveLinkIdleNote() {
    val link by LiveLinkStore.link.collectAsState()
    val rs = nl.haltewekker.ride.RideStore.state.collectAsState().value
    if (link == null && !LiveLinkStore.running(rs)) Text("While a trip runs you can share a live link with someone without the app.", color = DS.t.secondary,
        style = MaterialTheme.typography.bodySmall)
}

/** "Waiting for you to wait": each friend's wait (in `chat` only, when given), with "I’ll wait" / "Take the next one with you". */
@Composable
fun WaitsForYouCard(chat: String?) {
    FriendExtrasStore.waits.collectAsState().value
    val book by FriendChats.book.collectAsState()
    val finding by FriendExtrasStore.findingNext.collectAsState()
    val now = ticking()
    val list = FriendExtrasStore.waitsForMe(now).filter { chat == null || it.chat == chat }
    if (list.isEmpty()) return
    Card {
        Header("Waiting for you to wait")
        list.forEach { w ->
            val name = FriendStore.name(w.from)
            val stale = WaitAge.freshness(w, now) == TravelFreshness.STALE
            Text(WaitWords.line(name, w.wait, now), color = if (stale) DS.t.secondary else DS.t.text, fontWeight = FontWeight.SemiBold)
            Text(WaitWords.detail(name, w.wait) + (if (ChatKey.isGroup(w.chat)) " · in ${chatName(w.chat)}" else ""), color = DS.t.secondary,
                style = MaterialTheme.typography.bodySmall)
            if (stale) Text("Last update ${TimetableDays.hhmm(minOf(w.wait.at, w.got))}", color = DS.t.secondary, style = MaterialTheme.typography.labelSmall)
            val mine = book.waitAnswers(w.wait.id, w.chat)[FriendStore.myAccount ?: ""]
            when {
                finding == w.wait.id -> Text("Looking for the next one…", color = DS.t.secondary)
                mine != null -> Text("You said: ${mine.text}", color = DS.t.accentText)
                else -> Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    QuietButton(WaitAnswer.WAIT.text) { FriendExtrasStore.willWait(w) }
                    QuietButton("Take the next one with you") { FriendExtrasStore.takeNext(w) }
                }
            }
        }
    }
}

/** Your own wait while you ask someone to wait for you. */
@Composable
fun YourWaitCard(chat: String? = null) {
    val w by FriendExtrasStore.myWait.collectAsState()
    FriendChats.book.collectAsState().value
    val mine = w ?: return
    if (chat != null && mine.chat != chat) return
    Card {
        Header("Your wait")
        val who = chatName(mine.chat)
        Text(mine.last?.let { WaitWords.mine(who, it) } ?: "Asked $who to wait", color = DS.t.text)
        Text("At ${mine.stop.name}" + (mine.ride?.let { " · for the ${it.label} at ${TimetableDays.hhmm(it.dep)}" } ?: ""), color = DS.t.secondary,
            style = MaterialTheme.typography.bodySmall)
        val answers = FriendExtrasStore.answersToMine()
        if (answers.isNotEmpty()) Text(answers.entries.joinToString(" · ") { (id, a) -> "${FriendStore.name(id)}: ${a.text}" }, color = DS.t.accentText)
        Text("It goes again as you come closer, at each check (the other phone sees it at its next check).", color = DS.t.secondary,
            style = MaterialTheme.typography.labelSmall)
        QuietButton("Stop asking") { FriendExtrasStore.stopWait() }
    }
}

@Composable
fun OnCampusCard() {
    FriendExtrasStore.campus.collectAsState().value
    val now = ticking(60_000)
    val list = FriendExtrasStore.onCampus(now)
    if (list.isEmpty()) return
    Card {
        Header("On campus now", "${list.size}")
        list.forEach { c -> Text("${FriendStore.name(c.id)} · ${CampusWords.since(c.state)}", color = DS.t.text) }
    }
}

/** "Rides with friends": delays on rides you share (only those on `trips`, when given). */
@Composable
fun DelaysCard(trips: Set<String>?) {
    val all by FriendExtrasStore.delays.collectAsState()
    val now = ticking()
    val list = all.filter { it.delay.ride.arr > now && (trips == null || it.delay.ride.trip in trips) }
    if (list.isEmpty()) return
    Card {
        Header(if (trips == null) "Rides with friends" else "Delays on your rides")
        list.forEach { d ->
            val me = FriendStore.myAccount
            val names = (d.delay.who ?: listOf(d.from)).map { if (it == me) "you" else FriendStore.name(it) }
            Text(DelayWords.title(d.delay), color = DS.t.warning, fontWeight = FontWeight.SemiBold)
            Text(DelayWords.body(d.delay, names), color = DS.t.text, style = MaterialTheme.typography.bodySmall)
        }
    }
}

@Composable
fun FreeTogetherCard() {
    val slots by FriendTogetherStore.freeToday.collectAsState()
    val now = ticking(60_000)
    val list = slots.filter { it.end > now }
    if (list.isEmpty()) return
    Card {
        Header("Free together today")
        list.forEach { s -> Text(FreeToday.line(s, s.with.map { FriendStore.name(it) }, now), color = DS.t.text) }
    }
}

// MARK: the live link

fun shareLiveLink(c: Context, link: String) {
    val i = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_SUBJECT, "Follow my trip")
        .putExtra(Intent.EXTRA_TEXT, "Follow my trip live: $link")
    c.startActivity(Intent.createChooser(i, "Send the link").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
}

/** "Share a live link": a web page with your trip's live times, for someone without the app. Works without friends. */
@Composable
fun LiveLinkCard(ride: RideState? = null, idleNote: Boolean = true) {
    val context = LocalContext.current
    val link by LiveLinkStore.link.collectAsState()
    val making by LiveLinkStore.making.collectAsState()
    val problem by LiveLinkStore.problem.collectAsState()
    val rs = ride ?: nl.haltewekker.ride.RideStore.state.collectAsState().value
    val scope = rememberCoroutineScope()
    var name by remember { mutableStateOf(LiveLinkStore.defaultName) }
    val l = link
    if (l == null && !LiveLinkStore.running(rs)) {
        if (ride == null && idleNote) Text("While a trip runs you can share a live link with someone without the app.", color = DS.t.secondary,
            style = MaterialTheme.typography.bodySmall)
        return
    }
    Card {
        Header("Live link", if (l != null && !l.arrived) "Shared" else null)
        if (l != null) {
            l.last?.let { Text(LiveWords.headline(it), color = DS.t.text); LiveWords.detail(it)?.let { d -> Text(d, color = DS.t.secondary) } }
            Text(if (l.arrived) "“Arrived” stays on the page for 15 minutes." else "The page shows your trip until it ends (at most 4 hours). Only people with the link can see it.",
                color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                QuietButton("Send the link") { shareLiveLink(context, l.keys.link) }
                // (relay 0.30.1's page points here when an app cut the link short)
                QuietButton("Copy link") {
                    context.getSystemService(android.content.ClipboardManager::class.java)
                        ?.setPrimaryClip(android.content.ClipData.newPlainText("Live link", l.keys.link))
                }
                QuietButton("Stop sharing") { LiveLinkStore.stop() }
            }
        } else {
            Text("A web page with this trip’s live times, for someone without the app (a parent). It ends with the trip.", color = DS.t.text)
            OutlinedTextField(name, { name = it }, Modifier.fillMaxWidth(), label = { Text("Your name on the page") }, singleLine = true)
            QuietButton(if (making) "Making the link…" else "Share a live link") {
                if (!making && name.isNotBlank()) scope.launch { LiveLinkStore.make(name)?.let { shareLiveLink(context, it) } }
            }
            problem?.let { Note(it) }
        }
    }
}

// MARK: the leaderboard with friends

@Composable
fun LeaderboardCard() {
    val settings by FriendExtrasStore.settings.collectAsState()
    FriendTogetherStore.scores.collectAsState().value
    nl.haltewekker.friends.ScoreLog.trips.collectAsState().value
    var month by remember { mutableStateOf(true) }
    val now = now()
    val people = FriendTogetherStore.boardPeople(now)
    val m = ScoresRules.month(now)
    val groups = ScoreBoard.groups(people, if (month) m else null)
    fun who(id: String) = if (id == "me") "You" else FriendStore.name(id)
    Card {
        Header("Leaderboard with friends", FriendTogetherStore.sharingCount.takeIf { it > 0 }?.let { "$it sharing" })
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            QuietButton(if (month) "• This month" else "This month") { month = true }
            QuietButton(if (!month) "• All time" else "All time") { month = false }
        }
        if (groups.isEmpty()) Text("Trips from Home to School (and back) that you ride from the start count here.", color = DS.t.secondary,
            style = MaterialTheme.typography.bodySmall)
        groups.forEach { g ->
            Text(ScoreBoard.label(g), color = DS.t.text, fontWeight = FontWeight.SemiBold)
            g.rows.forEachIndexed { i, r -> Text("${i + 1}. ${who(r.who)} · ${"%.1f".format(java.util.Locale.US, r.mins)} min", color = DS.t.text) }
        }
        val rides = ScoreBoard.rides(people, m)
        if (rides.isNotEmpty()) {
            Text("Most rides together this month", color = DS.t.text, fontWeight = FontWeight.SemiBold)
            rides.forEach { Text("${who(it.who)} · ${it.n}", color = DS.t.text) }
        }
        SwitchRow("Share my scores", "Your fastest trips and rides together this month go to all your friends. Off by default.",
            settings.scores == true) { FriendExtrasStore.setShareScores(it) }
    }
}

// MARK: Friends › At school

@Composable
fun AtSchoolCard() {
    val settings by FriendExtrasStore.settings.collectAsState()
    val shown by FriendExtrasStore.campusShownTo.collectAsState()
    Card {
        Header("At school")
        SwitchRow("Show friends when I’m at school", "“At BUas since 09:05”, never where exactly. Needs location all the time; it goes when you leave, or after 10 hours."
            + if (shown > 0) " Shown to $shown now." else "", settings.campus == true) { FriendExtrasStore.setCampus(it) }
        SwitchRow("Tell me in the morning when we’re free together", "One notification a day between 06:00 and 11:00, from your timetable and the ones friends share.",
            settings.free == true) { FriendExtrasStore.setFreeNote(it) }
        Text("Wake-up buddy: on a friend’s page, “Tell … if I haven’t left yet” lets that friend know when you haven’t set off in the morning.",
            color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
    }
}

// MARK: a friend's page

@Composable
fun FriendExtrasOnPage(id: String, name: String) {
    val settings by FriendExtrasStore.settings.collectAsState()
    FriendExtrasStore.campus.collectAsState().value
    val rides by FriendTogetherStore.rides.collectAsState()
    val now = now()
    FriendExtrasStore.onCampus(now).firstOrNull { it.id == id }?.let { Note(CampusWords.since(it.state), DS.t.accent) }
    Card {
        Header("Wake-up buddy")
        SwitchRow("Tell $name if I haven’t left yet", "$name sees your plan for the morning (when you leave, your first bus or train) and is told if you haven’t set off. Off by default.",
            (settings.buddy ?: emptyList()).contains(id)) { FriendExtrasStore.setBuddy(id, it) }
    }
    Card {
        Header("Rides together")
        Text(RideHistoryWords.month(nl.haltewekker.friends.RideHistory.count(rides, id, now)), color = DS.t.text)
        nl.haltewekker.friends.RideHistory.last(rides, id).forEach { Text(RideHistoryWords.row(it), color = DS.t.secondary, style = MaterialTheme.typography.bodySmall) }
    }
}

// MARK: a chat

/** On a trip card you're in whose shared ride leaves within the hour: "Wait for me" (at its first stop). */
@Composable
fun WaitForMeOnCard(c: TripCard, n: String, from: String, key: String) {
    val me = FriendStore.myAccount ?: return
    val s = TripTake.shared(c) ?: return
    val first = c.first ?: return
    val now = now()
    if (s.dep - now > 3600 || s.dep < now - 60 || first.from.point == null) return
    val book by FriendChats.book.collectAsState()
    val inOnIt = from == me || book.answers(n, key)[me] == TripAnswer.YES
    if (!inOnIt) return
    QuietButton("Wait for me") { FriendExtrasStore.startWait(key, first.from, s) }
}

// MARK: the ride screen

/** On the ride screen: ask a friend to wait (while not on board yet), your wait, delays on your rides, the live link. */
@Composable
fun RideExtrasCards(s: RideState) {
    val book by FriendStore.book.collectAsState()
    val groups by FriendStore.groups.collectAsState()
    val myWait by FriendExtrasStore.myWait.collectAsState()
    var pick by remember { mutableStateOf(false) }
    val target = FriendExtrasStore.rideWaitTarget(s)
    if (!book?.friends.isNullOrEmpty()) {
        if (myWait != null) YourWaitCard()
        else if (target != null) Card {
            Header("Running late?")
            Text("Ask a friend to wait for you at ${target.stop.name}: they see how far you are, as you come closer.", color = DS.t.secondary)
            QuietButton("Ask a friend to wait for me") { pick = true }
        }
        DelaysCard(FriendExtrasStore.myTrips())
    }
    LiveLinkCard(s)
    if (pick && target != null) {
        val chats = (book?.sortedFriends?.map { it.id } ?: emptyList()) + groups.current.map { ChatKey.group(it.id) }
        AlertDialog(onDismissRequest = { pick = false }, title = { Text("Who should wait?") }, text = {
            Column(Modifier.heightIn(max = 360.dp).verticalScroll(rememberScrollState())) {
                chats.forEach { k -> TextButton(onClick = { pick = false; FriendExtrasStore.startWait(k, target.stop, target.ride) }) { Text(chatName(k)) } }
            }
        }, confirmButton = { TextButton(onClick = { pick = false }) { Text("Cancel") } })
    }
}

// MARK: Settings › Help improve Haltewekker

@Composable
fun LogShareCard() {
    val on by LogShareStore.on.collectAsState()
    val st by LogShareStore.state.collectAsState()
    val busy by LogShareStore.busy.collectAsState()
    val note by LogShareStore.note.collectAsState()
    var details by remember { mutableStateOf(false) }
    var confirm by remember { mutableStateOf(false) }
    Card {
        Header("Help improve Haltewekker")
        SwitchRow("Share ride logs", "Off unless you turn it on. After each trip it sends the lines about how the app picked your bus or train and how the ride went: " +
            "line numbers, distances in metres, how old a GPS fix was, what it decided. Never where you are, your places’ names, your friends or your account. " +
            "Not with Data Saver on a metered network; kept 60 days.", on) { LogShareStore.setOn(it) }
        QuietButton(if (details) "Hide what’s sent" else "What’s sent") { details = !details }
        if (details) {
            Text("A line as it’s sent", color = DS.t.text, fontWeight = FontWeight.SemiBold)
            Text(remember { LogShareStore.example() }, color = DS.t.text, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall)
            listOf(
                "What" to "The matching and ride lines of this phone’s log: the time, the bus or train line and the last 4 characters of its trip, distances rounded to 10 m, how sure the app was and what it chose.",
                "Not sent" to "Coordinates, addresses, the names of your places (Home and School become “Home” and “School”), friends’ names, account ids and the requests the app makes. Public stop and station names may stay.",
                "Grouped by" to "A random id made on this phone for this only: not your Friends account, not your phone’s name.",
                "When" to "After each trip ends, and at most once an hour otherwise. Never during a trip, with Data Saver on a metered network or in battery saver. At most 200 KB at a time and 2 MB a day.",
                "Kept" to "60 days, then deleted. Only the developer can read them, to make the app pick the right bus or train more often.",
            ).forEach { (t, d) -> Text(t, color = DS.t.text, fontWeight = FontWeight.SemiBold); Text(d, color = DS.t.secondary, style = MaterialTheme.typography.bodySmall) }
        }
        if (st != null) QuietButton(if (busy) "Deleting…" else "Delete what I sent") { if (!busy) confirm = true }
        note?.let { Text(it, color = DS.t.secondary, style = MaterialTheme.typography.bodySmall) }
    }
    if (confirm) AlertDialog(onDismissRequest = { confirm = false }, title = { Text("Delete the ride logs this phone sent?") },
        text = { Text("Everything this phone sent is deleted from the server now. Sharing stays as it is; what comes later goes under a new random id.") },
        confirmButton = { TextButton(onClick = { confirm = false; LogShareStore.deleteSent() }) { Text("Delete what I sent") } },
        dismissButton = { TextButton(onClick = { confirm = false }) { Text("Cancel") } })
}
