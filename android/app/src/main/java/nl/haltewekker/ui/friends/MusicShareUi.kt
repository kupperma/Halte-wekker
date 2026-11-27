package nl.haltewekker.ui.friends

import android.content.Intent
import android.graphics.BitmapFactory
import android.net.Uri
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.LifecycleResumeEffect
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import nl.haltewekker.data.Net
import nl.haltewekker.friends.LiveMusic
import nl.haltewekker.friends.MusicAudience
import nl.haltewekker.friends.MusicFrom
import nl.haltewekker.friends.MusicShare
import nl.haltewekker.friends.MusicShareStore
import nl.haltewekker.ui.QuietButton
import nl.haltewekker.ui.screens.Toggle
import nl.haltewekker.ui.theme.DS

// Listening now (relay 2026-11-27), the iOS `MusicShareViews.swift`: Settings › Friends' rows for sharing what you
// listen to, and the strip on a travelling friend's page ("LISTENING NOW", the song, "💬 Message", "🎧 Listen too").

/** Settings › Friends: "Share what I'm listening to" (off by default), where it comes from, and who sees it. */
@Composable
fun MusicShareCard() {
    val c = LocalContext.current
    MusicShareStore.load(c)
    val on by MusicShareStore.on.collectAsState()
    val from by MusicShareStore.from.collectAsState()
    val who by MusicShareStore.who.collectAsState()
    val user by MusicShareStore.lastfmUser.collectAsState()
    val current by MusicShareStore.current.collectAsState()
    val problem by MusicShareStore.problem.collectAsState()
    val checking by MusicShareStore.checking.collectAsState()
    var resumed by remember { mutableIntStateOf(0) }
    LifecycleResumeEffect(Unit) { resumed++; onPauseOrDispose {} }
    val access = remember(resumed, from) { MusicShareStore.hasAccess(c) }
    nl.haltewekker.ui.Card {
        Toggle("Share what I’m listening to", "Only while you travel · song and artist only", on) { MusicShareStore.setOn(c, it) }
        Text("While a trip runs or a live link is on: the song playing now, its artist and app, and its cover. Never what you listened to before, and nothing when you pause.",
            color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
        if (on) {
            Text("From", color = DS.t.text, fontWeight = FontWeight.SemiBold)
            for (f in MusicFrom.entries) Choice(f.title, from == f) { MusicShareStore.setFrom(c, f) }
            when {
                from == MusicFrom.PLAYER && !access -> {
                    Text("Android calls it Notification access: it lets Haltewekker see which song a music app plays. No notification is read.",
                        color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
                    QuietButton("Turn on Notification access") { c.startActivity(MusicShareStore.accessIntent()) }
                }
                from == MusicFrom.PLAYER -> Text("Any music app on this phone (Spotify, YouTube Music, …). The cover comes from Apple’s public search, never from your phone.",
                    color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
                else -> {
                    OutlinedTextField(user, { MusicShareStore.setUser(c, it) }, label = { Text("Last.fm username") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                    Text(if (from == MusicFrom.SPOTIFY) "Connect Spotify to Last.fm once (last.fm › Settings › Applications › Spotify scrobbling); Haltewekker then reads what Last.fm says is playing."
                        else "Any app that scrobbles to your Last.fm account.", color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
                }
            }
            Text("Who sees it", color = DS.t.text, fontWeight = FontWeight.SemiBold)
            for (a in MusicAudience.entries) Choice(a.title, who == a) { MusicShareStore.setWho(c, a) }
            QuietButton(if (checking) "Checking…" else "Check what’s playing") { MusicShareStore.checkNow(c) }
            val p = problem
            val s = current
            if (p != null) Text(p, color = DS.t.warning, style = MaterialTheme.typography.bodySmall)
            else if (s != null) Text("♪ " + listOf(s.title, s.artist).filter { it.isNotEmpty() }.joinToString(" · ") + if (s.playing) "" else " (paused)",
                color = DS.t.text, style = MaterialTheme.typography.bodySmall)
        }
    }
}

@Composable
private fun Choice(title: String, selected: Boolean, pick: () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 44.dp).clickable(onClick = pick), verticalAlignment = Alignment.CenterVertically) {
        RadioButton(selected, pick)
        Text(title, color = DS.t.text)
    }
}

/** The song when it's fresh (under 10 minutes old by its own time). */
fun freshMusic(m: LiveMusic?, now: Double): LiveMusic? {
    if (m == null || m.title.isEmpty()) return null
    val at = MusicShare.parseIso(m.at) ?: return null
    return if (now - at < MusicShare.MAX_AGE) m else null
}

@Composable
private fun MusicBars() {
    Row(Modifier.height(13.dp), horizontalArrangement = Arrangement.spacedBy(2.dp), verticalAlignment = Alignment.Bottom) {
        for (h in listOf(6, 11, 8, 13)) Box(Modifier.width(3.dp).height(h.dp).clip(RoundedCornerShape(1.dp)).background(DS.t.accent))
    }
}

/** A cover from the hosts the strip takes, loaded with the app's own client (no image library). */
@Composable
private fun cover(url: String?): ImageBitmap? {
    val ok = MusicShare.cover(url)
    val bmp by produceState<ImageBitmap?>(null, ok) {
        value = if (ok == null) null else withContext(Dispatchers.IO) {
            val a = Net.get(ok)
            val b = a.body
            if (!a.ok || b == null || b.size > 2_000_000) null else try { BitmapFactory.decodeByteArray(b, 0, b.size)?.asImageBitmap() } catch (_: Exception) { null }
        }
    }
    return bmp
}

/** The song as a card: the cover, "LISTENING NOW", the title, "artist · app" and "Open ↗" (only a known service's link). */
@Composable
fun ListeningCard(m: LiveMusic) {
    val c = LocalContext.current
    val link = MusicShare.link(m.url)
    val art = cover(m.coverUrl)
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(DS.t.surface2).padding(12.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        val shape = RoundedCornerShape(8.dp)
        if (art != null) Image(art, null, Modifier.size(52.dp).clip(shape), contentScale = ContentScale.Crop)
        else Box(Modifier.size(52.dp).clip(shape).background(Brush.linearGradient(listOf(Color(0xFF7D5CF0), Color(0xFFE35587)))), contentAlignment = Alignment.Center) {
            Text("♪", color = Color.White, fontSize = 20.sp)
        }
        Column(Modifier.weight(1f).semantics(mergeDescendants = true) {}) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                MusicBars()
                Text("LISTENING NOW", color = DS.t.accentText, fontWeight = FontWeight.Bold, fontSize = 12.sp)
            }
            Text(m.title, color = DS.t.text, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            val sub = listOfNotNull(m.artist, m.app).filter { it.isNotEmpty() }.joinToString(" · ")
            if (sub.isNotEmpty()) Text(sub, color = DS.t.secondary, style = MaterialTheme.typography.bodyMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        if (link != null) Text("Open ↗", Modifier.clip(RoundedCornerShape(8.dp)).border(1.dp, DS.t.secondary.copy(alpha = 0.4f), RoundedCornerShape(8.dp))
            .clickable { open(c, link) }.padding(horizontal = 10.dp, vertical = 6.dp)
            .semantics { contentDescription = "Open ${m.title}" }, color = DS.t.secondary, fontWeight = FontWeight.SemiBold, fontSize = 13.sp)
    }
}

private fun open(c: android.content.Context, url: String) {
    try { c.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) } catch (_: Exception) {}
}

/** A travelling friend's song, with "💬 Message" and "🎧 Listen too". */
@Composable
fun FriendListeningStrip(friendId: String, name: String, m: LiveMusic, push: (FriendsRoute) -> Unit) {
    val c = LocalContext.current
    val link = MusicShare.link(m.url)
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        ListeningCard(m)
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            StripButton("💬 Message", "Message $name", Modifier.weight(1f)) { push(FriendsRoute.Chat(friendId)) }
            if (link != null) StripButton("🎧 Listen too", "Listen too: opens ${m.title}", Modifier.weight(1f)) { open(c, link) }
        }
    }
}

@Composable
private fun StripButton(title: String, spoken: String, modifier: Modifier, onClick: () -> Unit) {
    Box(modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(14.dp)).background(DS.t.surface2).clickable(onClick = onClick)
        .semantics { contentDescription = spoken }, contentAlignment = Alignment.Center) {
        Text(title, color = DS.t.text, fontWeight = FontWeight.SemiBold)
    }
}

