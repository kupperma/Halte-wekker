package nl.haltewekker.ui.friends

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Person
import androidx.compose.material3.Icon
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
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import nl.haltewekker.friends.FriendBanner
import nl.haltewekker.friends.FriendChats
import nl.haltewekker.friends.FriendStore
import nl.haltewekker.ui.theme.DS

/** The home's Friends button (round, over the map like Settings), with requests waiting and new lines as a badge. */
@Composable
fun FriendsHomeButton(modifier: Modifier, onClick: () -> Unit) {
    val book by FriendStore.book.collectAsState()
    val unread by FriendStore.unread.collectAsState()
    val n = FriendStore.badge(book, unread)
    Box(modifier) {
        Box(Modifier.size(40.dp).clip(CircleShape).background(DS.t.surface).clickable(onClick = onClick), contentAlignment = Alignment.Center) {
            Icon(Icons.Filled.Person, "Friends", tint = DS.t.text)
        }
        if (n > 0) Box(Modifier.align(Alignment.TopEnd)) { Badge(n) }
    }
}

/** The in-app banner (iOS `Notices`): a line that came, a request, news; tap opens that chat or Friends. */
@Composable
fun FriendBannerHost(onOpen: (String?) -> Unit) {
    var shown by remember { mutableStateOf<FriendBanner?>(null) }
    LaunchedEffect(Unit) { FriendStore.banners.collect { b -> if (b.chat == null || b.chat != FriendChats.onScreen.value) shown = b } }
    LaunchedEffect(shown) { if (shown != null) { delay(4500); shown = null } }
    AnimatedVisibility(shown != null) {
        val b = shown ?: return@AnimatedVisibility
        Column(Modifier.statusBarsPadding().padding(12.dp).fillMaxWidth().shadow(6.dp, RoundedCornerShape(20.dp)).clip(RoundedCornerShape(20.dp))
            .background(DS.t.surface).clickable { shown = null; onOpen(b.chat) }.padding(14.dp)) {
            Text(b.title, color = DS.t.text, fontWeight = FontWeight.Bold)
            Text(b.body, color = DS.t.secondary, style = MaterialTheme.typography.bodySmall, maxLines = 2)
        }
    }
}
