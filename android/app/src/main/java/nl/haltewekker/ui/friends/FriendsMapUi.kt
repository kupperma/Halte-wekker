package nl.haltewekker.ui.friends

import androidx.compose.animation.core.animateDpAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowLeft
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import nl.haltewekker.data.VehicleKind
import nl.haltewekker.friends.Friend
import nl.haltewekker.friends.FriendTravelSeen
import nl.haltewekker.friends.TestFriendBot
import nl.haltewekker.friends.TravelAge
import nl.haltewekker.friends.TravelFreshness
import nl.haltewekker.friends.TravelState
import nl.haltewekker.friends.TravelWords
import nl.haltewekker.ui.Card
import nl.haltewekker.ui.Note
import nl.haltewekker.ui.QuietButton
import nl.haltewekker.ui.theme.DS
import nl.haltewekker.ui.theme.Tokens

// Friends (A5, iOS 0.31 "Map first"): the sheet over the map (a handle to pull it up or down), a friend's card in its
// row, its tiles, "‹ Friends", and the test friend's tag, card and controls (iOS `TestFriendViews.swift`).

/** A travelling friend's vehicle colour (Intercity indigo, Sprinter cyan, bus orange, as the line pills). */
fun ringColour(s: TravelState): Color = Tokens.light.kind(VehicleKind.of(if (s.isTrain) "" else s.mode, s.line ?: "", s.isTrain))

/**
 * A sheet over the map: a handle to pull it up (or tap it: "Show more" / "Show less" for TalkBack), its content
 * scrolling inside. `peek` is how high it stands when down; up, it takes 92 % of the screen.
 */
@Composable
fun MapSheet(up: Boolean, onUp: (Boolean) -> Unit, peek: Dp, onClose: (() -> Unit)? = null, content: @Composable ColumnScope.() -> Unit) {
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val full = maxHeight
        val low = minOf(peek, full * 0.8f)
        val high = full * 0.92f
        var drag by remember { mutableFloatStateOf(0f) }
        val density = LocalDensity.current
        val base by animateDpAsState(if (up) high else low, label = "sheet")
        val h = with(density) { (base.toPx() - drag).coerceIn((low * 0.6f).toPx(), full.toPx()).toDp() }
        Column(Modifier.align(Alignment.BottomCenter).fillMaxWidth().height(h)
            .shadow(12.dp, RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp))
            .clip(RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp)).background(DS.t.page)) {
            // the handle
            Box(Modifier.fillMaxWidth().heightIn(min = 28.dp)
                .pointerInput(up) {
                    detectVerticalDragGestures(onDragEnd = {
                        if (drag > 60 * density.density) { if (up || onClose == null) onUp(false) else onClose() } else if (drag < -60 * density.density) onUp(true)
                        drag = 0f
                    }, onDragCancel = { drag = 0f }) { _, dy -> drag += dy }
                }
                .clickable(onClickLabel = if (up) "Show less" else "Show more") { onUp(!up) }
                .semantics { contentDescription = if (up) "Show less" else "Show more"; role = Role.Button },
                contentAlignment = Alignment.Center) {
                Box(Modifier.width(40.dp).height(5.dp).clip(CircleShape).background(DS.t.legQuiet))
            }
            Column(Modifier.fillMaxWidth().weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).navigationBarsPadding(),
                verticalArrangement = Arrangement.spacedBy(12.dp)) {
                content()
                Spacer(Modifier.height(24.dp))
            }
        }
    }
}

/** A friend's card in the sheet's row: face, name, what they're on, when they arrive. */
@Composable
fun FriendMiniCard(friend: Friend, travel: FriendTravelSeen?, campus: Boolean, picture: ByteArray?, now: Double, onClick: () -> Unit) {
    val s = travel?.state
    val line = s?.let { TravelWords.cardLine(it) } ?: if (campus) "On campus" else "Not travelling now"
    val time = s?.let { TravelWords.cardTime(it) }
    val ring = s?.let { ringColour(it) } ?: if (campus) DS.t.accent else Color.Transparent
    val stale = travel?.let { TravelAge.freshness(it, now) == TravelFreshness.STALE } == true
    val bot = TestFriendBot.account.collectAsState().value == friend.id
    Column(Modifier.width(156.dp).heightIn(min = 96.dp).alpha(if (stale) 0.7f else 1f).clip(RoundedCornerShape(18.dp)).background(DS.t.surface)
        .clickable(onClickLabel = "Shows ${friend.name}’s page", onClick = onClick)
        .semantics(mergeDescendants = true) { contentDescription = listOfNotNull(friend.name, line, time).joinToString(". ") }
        .padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(Modifier.size(34.dp).border(2.dp, ring, CircleShape).padding(2.dp)) { Avatar(friend.name, picture, 30.dp) }
            Text(friend.name, color = DS.t.text, fontWeight = FontWeight.SemiBold, maxLines = 1, modifier = Modifier.weight(1f, fill = false))
            if (bot) TestFriendTag()
        }
        Text(line, color = DS.t.secondary, style = MaterialTheme.typography.bodySmall, maxLines = 3)
        if (time != null) Text(time, color = DS.t.text, style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.Bold)
    }
}

/** A tile of the sheet's buttons: an icon over its words ("Chats · 3", "Groups", "Compare"). */
@Composable
fun FriendsTile(icon: ImageVector, title: String, modifier: Modifier = Modifier, spoken: String? = null, enabled: Boolean = true, onClick: () -> Unit) {
    Column(modifier.heightIn(min = 60.dp).clip(RoundedCornerShape(16.dp)).background(DS.t.surface)
        .clickable(enabled = enabled, onClick = onClick).semantics(mergeDescendants = true) { if (spoken != null) contentDescription = spoken }
        .padding(8.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp, Alignment.CenterVertically)) {
        Icon(icon, null, tint = if (enabled) DS.t.accentText else DS.t.secondary, modifier = Modifier.size(22.dp))
        Text(title, color = DS.t.text, style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center, maxLines = 2)
    }
}

/** "‹ Friends": back to the list, floating over the map. */
@Composable
fun MapBackPill(title: String, onClick: () -> Unit) {
    Row(Modifier.heightIn(min = DS.hit).shadow(4.dp, CircleShape).clip(CircleShape).background(DS.t.surface)
        .clickable(onClickLabel = "Back to $title", onClick = onClick).padding(start = 6.dp, end = 14.dp),
        verticalAlignment = Alignment.CenterVertically) {
        @Suppress("DEPRECATION")
        Icon(Icons.Filled.KeyboardArrowLeft, null, tint = DS.t.text)
        Text(title, color = DS.t.text, fontWeight = FontWeight.SemiBold)
    }
}

/** A round button floating over the map ("…", Done). */
@Composable
fun MapRoundButton(icon: ImageVector, label: String, onClick: () -> Unit) {
    Box(Modifier.size(DS.hit).shadow(4.dp, CircleShape).clip(CircleShape).background(DS.t.surface).clickable(onClick = onClick)
        .semantics { contentDescription = label; role = Role.Button }, contentAlignment = Alignment.Center) {
        Icon(icon, null, tint = DS.t.text)
    }
}

// MARK: the test friend

val TestFriendColour = Color(0xFF6B45D9)

/** "TEST" beside the test friend's name, wherever it shows. */
@Composable
fun TestFriendTag() {
    Text("TEST", Modifier.clip(CircleShape).background(TestFriendColour).padding(horizontal = 6.dp, vertical = 1.dp)
        .semantics { contentDescription = "Test friend, a bot on this phone" }, color = Color.White, fontWeight = FontWeight.Black, fontSize = 10.sp)
}

@Composable
private fun RemoveTestFriendDialog(onDone: () -> Unit, onRemoved: () -> Unit = {}) {
    AlertDialog(onDismissRequest = onDone, title = { Text("Remove the test friend?") },
        text = { Text("It leaves the relay, and its chat and everything it sent go from this phone.") },
        confirmButton = { TextButton(onClick = { onDone(); TestFriendBot.remove(); onRemoved() }) { Text("Remove test friend") } },
        dismissButton = { TextButton(onClick = onDone) { Text("Cancel") } })
}

/** "Add a test friend" (or, once there is one, what it is and "Remove test friend"). */
@Composable
fun TestFriendAddCard() {
    val account by TestFriendBot.account.collectAsState()
    val working by TestFriendBot.working.collectAsState()
    val note by TestFriendBot.note.collectAsState()
    var asking by remember { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (account != null) {
            Text("Your test friend is a bot on this phone: a real second friends account that answers through the relay, so you can try chats, groups, trips, timetables and the extras. Its controls are on its page.",
                color = DS.t.secondary, style = MaterialTheme.typography.bodyMedium)
            note?.let { Note(it, TestFriendColour) }
            QuietButton("Remove test friend") { asking = true }
        } else {
            Text("No friends on the app yet? Add a test friend: a bot on this phone with its own account, to try every Friends feature with. It never goes in your backup.",
                color = DS.t.secondary, style = MaterialTheme.typography.bodyMedium)
            note?.let { Note(it) }
            QuietButton(if (working) "Adding…" else "Add a test friend") { if (!working) TestFriendBot.add() }
        }
    }
    if (asking) RemoveTestFriendDialog({ asking = false })
}

/** On the test friend's page: one tap, one box (or a short pretend run), through the relay like a real friend's. */
@Composable
fun TestFriendControls(onRemoved: () -> Unit) {
    val trip by TestFriendBot.trip.collectAsState()
    val working by TestFriendBot.working.collectAsState()
    val campus by TestFriendBot.campus.collectAsState()
    val note by TestFriendBot.note.collectAsState()
    var asking by remember { mutableStateOf(false) }
    Card {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Test friend controls", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold, color = DS.t.text)
            TestFriendTag()
        }
        Text("Each button makes the test friend send what a friend’s phone would: it arrives with the next check (at once here).",
            color = DS.t.secondary, style = MaterialTheme.typography.bodyMedium)
        note?.let { Note(it, TestFriendColour) }
        val travel = if (trip != null) "Stop pretending to travel" else if (working) "Finding a bus or train…" else "Pretend I’m travelling"
        QuietButton(travel, Modifier.fillMaxWidth()) { if (!working) TestFriendBot.pretendTravel() }
        QuietButton("Ask you to wait for me", Modifier.fillMaxWidth()) { TestFriendBot.askToWait() }
        QuietButton(if (campus) "Pretend I’ve left campus" else "Pretend I’m on campus", Modifier.fillMaxWidth()) { TestFriendBot.toggleCampus() }
        QuietButton("Share scores", Modifier.fillMaxWidth()) { TestFriendBot.shareScores() }
        QuietButton("Pretend we rode together", Modifier.fillMaxWidth()) { TestFriendBot.pretendRodeTogether() }
        QuietButton("Wake-up buddy: pretend I haven’t left", Modifier.fillMaxWidth()) { TestFriendBot.buddyNotLeft() }
        Text("It shares a timetable near yours and the station nearest your Home by itself. The wake-up buddy tells you once a day, and not when it pretended to travel or wait in the last hour.",
            color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
        QuietButton("Remove test friend", Modifier.fillMaxWidth()) { asking = true }
    }
    if (asking) RemoveTestFriendDialog({ asking = false }, onRemoved)
}

/** Settings › Friends: "Add a test friend" / "Remove test friend". */
@Composable
fun TestFriendSettingsRow() {
    val account by TestFriendBot.account.collectAsState()
    val working by TestFriendBot.working.collectAsState()
    var asking by remember { mutableStateOf(false) }
    if (!nl.haltewekker.friends.FriendStore.hasAccount) return
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        QuietButton(if (account != null) "Remove test friend" else if (working) "Adding a test friend…" else "Add a test friend") {
            if (account != null) asking = true else if (!working) TestFriendBot.add()
        }
        if (account != null) TestFriendTag()
    }
    if (asking) RemoveTestFriendDialog({ asking = false })
}
