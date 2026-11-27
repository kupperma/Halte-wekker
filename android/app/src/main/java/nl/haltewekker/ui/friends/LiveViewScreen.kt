package nl.haltewekker.ui.friends

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.core.Polyline
import nl.haltewekker.friends.LiveMessages
import nl.haltewekker.friends.LiveState
import nl.haltewekker.friends.LiveView
import nl.haltewekker.friends.LiveWords
import nl.haltewekker.map.LiveMap
import nl.haltewekker.map.MapDot
import nl.haltewekker.map.MapLine
import nl.haltewekker.map.MapStop
import nl.haltewekker.ride.Notifications
import nl.haltewekker.ui.Card
import nl.haltewekker.ui.Header
import nl.haltewekker.ui.Note
import nl.haltewekker.ui.QuietButton
import nl.haltewekker.ui.theme.DS

/** The trip someone shared with a live link, opened in the app: their map and trip, and a message to them. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun LiveViewScreen(onClose: () -> Unit) {
    val context = LocalContext.current
    val v by LiveView.view.collectAsState()
    val scope = rememberCoroutineScope()
    var text by remember { mutableStateOf("") }
    BackHandler { onClose() }
    LaunchedEffect(v?.token) { while (true) { LiveView.poll(); delay(15_000) } }
    val view = v ?: return
    val s = view.state
    val hex = s?.legs?.getOrNull(s.leg ?: 0)?.color?.takeIf { Regex("^[0-9A-Fa-f]{6}$").matches(it) } ?: "E0632E"
    val argb = android.graphics.Color.parseColor("#$hex")
    Box(Modifier.fillMaxSize().background(Color(0xFF111316))) {
        Column(Modifier.fillMaxSize()) {
            if (s != null) {
                val road = s.shape?.let { Polyline.decode(it) } ?: emptyList()
                val pos = s.pos?.takeIf { s.state != "arrived" }?.let { GeoPoint(it.lat, it.lon) }
                val stops = s.stops?.mapIndexed { i, x -> MapStop("s$i", x.name, GeoPoint(x.lat, x.lon)) } ?: emptyList()
                val label = s.legs?.getOrNull(s.leg ?: 0)?.line ?: s.line ?: ""
                LiveMap(Modifier.fillMaxWidth().weight(0.42f), centre = pos ?: road.firstOrNull(), me = null,
                    dots = pos?.let { listOf(MapDot("v", it, argb, label)) } ?: emptyList(),
                    lines = if (road.size > 1) listOf(MapLine(road, argb)) else emptyList(),
                    stops = stops, frame = road + listOfNotNull(pos), dark = true, onBounds = { _, _, _ -> })
            }
            Column(Modifier.fillMaxWidth().weight(0.58f).background(Color(0xFF1E2126), RoundedCornerShape(topStart = 24.dp, topEnd = 24.dp))
                .verticalScroll(rememberScrollState()).padding(18.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text(if (view.ended) "ENDED" else if (s?.state == "arrived") "ARRIVED" else "LIVE", color = if (view.ended) Color(0xFFA3ABB3) else Color(0xFF3DD598),
                        fontWeight = FontWeight.Bold, style = MaterialTheme.typography.labelMedium)
                    TextButton(onClick = onClose) { Text("Close", color = Color(0xFFF2F4F5)) }
                }
                if (s != null) {
                    Text(LiveWords.headline(s), color = Color(0xFFF2F4F5), fontWeight = FontWeight.Bold, style = MaterialTheme.typography.titleMedium)
                    LiveWords.detail(s)?.let { Text(it, color = Color(0xFFA3ABB3)) }
                    s.legs?.let { legs ->
                        legs.forEachIndexed { i, l ->
                            val now = i == (s.leg ?: 0) && s.state != "arrived"
                            val what = if (l.mode == "walk") "Walk ${l.mins ?: ""} min".replace("  ", " ") else (if (l.mode == "train") l.line ?: "Train" else "Bus ${l.line ?: ""}").trim()
                            val time = l.dep?.let { Notifications.time(it.toDouble()) } ?: ""
                            Text("$time  $what · ${l.from} → ${l.to}" + (l.depPlatform?.let { p -> if (l.mode == "train") " · platform $p" else " · stop $p" } ?: ""),
                                color = if (now) Color(0xFFF2F4F5) else Color(0xFFA3ABB3), fontWeight = if (now) FontWeight.SemiBold else FontWeight.Normal,
                                style = MaterialTheme.typography.bodyMedium)
                        }
                    }
                }
                view.status?.let { Text(it, color = Color(0xFFA3ABB3)) }
                if (s?.inbox == true && !view.ended) {
                    Text("Send ${s.name.ifEmpty { "them" }} a message", color = Color(0xFFF2F4F5), fontWeight = FontWeight.Bold)
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        LiveMessages.chips.forEach { c -> TextButton(onClick = { text = c }) { Text(c, color = Color(0xFFF2F4F5)) } }
                    }
                    OutlinedTextField(text, { if (it.length <= LiveMessages.MAX_TEXT) text = it }, Modifier.fillMaxWidth(), label = { Text("A message") })
                    QuietButton("Send") { scope.launch { if (LiveView.send(context, text)) text = "" } }
                    view.note?.let { Text(it, color = Color(0xFFFF8A5C), style = MaterialTheme.typography.bodySmall) }
                    view.sent.forEach { m ->
                        Text(m.text + "  ·  " + (if (m.seq <= view.seen) "Seen ✓✓" else "Sent ${Notifications.time(m.at)} ✓"), color = Color(0xFFF2F4F5),
                            style = MaterialTheme.typography.bodySmall)
                    }
                    view.replies.forEach { r -> Text("${s.name}: ${r.text} · ${Notifications.time(r.at)}", color = Color(0xFF3DD598), style = MaterialTheme.typography.bodySmall) }
                }
            }
        }
    }
}

/** (relay 2026-11-27) Open a live link someone sent you: paste it here. */
@Composable
fun LiveOpenRow() {
    var link by remember { mutableStateOf("") }
    var bad by remember { mutableStateOf(false) }
    Card {
        Header("Follow someone’s live link")
        OutlinedTextField(link, { link = it; bad = false }, Modifier.fillMaxWidth(), label = { Text("Paste the live link") }, singleLine = true)
        QuietButton("Open") { val l = LiveView.find(link) ?: link; bad = !LiveView.open(l) }
        if (bad) Note("That isn’t a whole live link. Ask for it again (all of it, with the part after the #).")
    }
}
