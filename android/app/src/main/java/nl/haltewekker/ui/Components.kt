package nl.haltewekker.ui

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import nl.haltewekker.data.DoorTrip
import nl.haltewekker.data.Ride
import nl.haltewekker.data.VehicleKind
import nl.haltewekker.ui.theme.DS
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.roundToInt

object Fmt {
    private val hm = SimpleDateFormat("HH:mm", Locale.ROOT)
    fun time(t: Double): String = hm.format(Date((t * 1000).toLong()))
    /** "now", "4 min", "1 h 05" */
    fun inMinutes(t: Double, now: Double): String {
        val m = ((t - now) / 60).roundToInt()
        return when {
            m <= 0 -> "now"
            m < 60 -> "$m min"
            else -> "${m / 60} h ${"%02d".format(m % 60)}"
        }
    }
    fun minutes(m: Int): String = if (m < 60) "$m min" else "${m / 60} h ${"%02d".format(m % 60)}"
    fun metres(m: Double): String = if (m >= 1000) String.format(Locale.ROOT, "%.1f km", m / 1000) else "${(m / 10).roundToInt() * 10} m"
    /** "Breda, Nassausingel" → "Nassausingel" when the town is said already (iOS `Fmt.place`, roughly). */
    fun place(name: String): String = name
}

/** A card: the surface, the radius and one soft shadow (iOS `.card()`). */
@Composable
fun Card(modifier: Modifier = Modifier, padding: Int = 16, content: @Composable ColumnScope.() -> Unit) {
    Column(
        modifier.fillMaxWidth().shadow(2.dp, RoundedCornerShape(DS.cardRadius))
            .clip(RoundedCornerShape(DS.cardRadius)).background(DS.t.surface).padding(padding.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp), content = content,
    )
}

/** The line pill: "306" on the bus orange, "IC" on indigo, "SPR" on cyan (white bold text). */
@Composable
fun LinePill(line: String, kind: VehicleKind, modifier: Modifier = Modifier) {
    val label = if (kind == VehicleKind.BUS && line.length <= 4) line else line.take(6)
    Text(label, modifier.clip(RoundedCornerShape(DS.pillRadius)).background(DS.t.kind(kind)).padding(horizontal = 6.dp, vertical = 2.dp),
        color = Color.White, fontWeight = FontWeight.Bold, fontSize = 13.sp, maxLines = 1)
}

@Composable
fun RidePill(r: Ride) = LinePill(r.line, r.kind)

@Composable
fun Header(title: String, sub: String? = null) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
        Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold, color = DS.t.text, modifier = Modifier.weight(1f))
        if (sub != null) Text(sub, style = MaterialTheme.typography.bodySmall, color = DS.t.secondary)
    }
}

/** A note in a soft wash of its colour. */
@Composable
fun Note(text: String, tint: Color = DS.t.warning, icon: ImageVector? = null) {
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(tint.copy(alpha = 0.12f)).padding(12.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        if (icon != null) Icon(icon, null, tint = tint)
        Text(text, style = MaterialTheme.typography.bodyMedium, color = DS.t.text)
    }
}

/** The big button (accent fill, white text, 56 dp). */
@Composable
fun BigButton(title: String, modifier: Modifier = Modifier, enabled: Boolean = true, fill: Color = DS.t.accent, onClick: () -> Unit) {
    Box(modifier.fillMaxWidth().heightIn(min = DS.cta).clip(CircleShape).background(if (enabled) fill else DS.t.surface3)
        .clickable(enabled = enabled, onClick = onClick).padding(horizontal = 16.dp), contentAlignment = Alignment.Center) {
        Text(title, color = if (enabled) Color.White else DS.t.secondary, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center)
    }
}

/** A quiet button: a capsule in the third surface, accent text, 44 dp high. */
@Composable
fun QuietButton(title: String, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Box(modifier.heightIn(min = DS.hit).clip(CircleShape).background(DS.t.surface3).clickable(onClick = onClick).padding(horizontal = 14.dp),
        contentAlignment = Alignment.Center) {
        Text(title, color = DS.t.accentText, fontWeight = FontWeight.SemiBold, style = MaterialTheme.typography.bodyMedium)
    }
}

/** Hold to confirm, so a sleepy tap doesn't end things (iOS `DSHoldButton`): the accent fills while you hold. */
@Composable
fun HoldButton(title: String, seconds: Float = 1f, onDone: () -> Unit) {
    val progress = remember { Animatable(0f) }
    val scope = rememberCoroutineScope()
    Box(Modifier.fillMaxWidth().heightIn(min = DS.cta).clip(CircleShape).background(DS.t.surface3)
        .border(1.dp, DS.t.divider, CircleShape)
        .semantics { role = Role.Button; onClick(label = title) { onDone(); true } }
        .pointerInput(Unit) {
            awaitEachGesture {
                awaitFirstDown()
                val job = scope.launch {
                    progress.animateTo(1f, tween((seconds * 1000).toInt(), easing = LinearEasing))
                    onDone()
                    progress.snapTo(0f)
                }
                waitForUpOrCancellation()
                if (job.isActive) { job.cancel(); scope.launch { progress.animateTo(0f, tween(200)) } }
            }
        }, contentAlignment = Alignment.CenterStart) {
        Box(Modifier.fillMaxHeight().fillMaxWidth(progress.value).background(DS.t.accent).heightIn(min = DS.cta))
        Text(title, Modifier.fillMaxWidth(), color = if (progress.value > 0.5f) Color.White else DS.t.text,
            fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center)
    }
}

/** One trip as a row: leave and arrival times, the lines, the changes. */
@Composable
fun TripRow(t: DoorTrip, now: Double, selected: Boolean = false, onClick: () -> Unit) {
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(if (selected) DS.t.accentSoft else DS.t.surface2)
        .clickable(onClick = onClick).padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("${Fmt.time(t.first.departure)} → ${Fmt.time(t.end)}", fontWeight = FontWeight.Bold, color = DS.t.text,
                style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
            Text("leave ${Fmt.inMinutes(t.start, now)}", color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
        }
        FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            t.rides.forEach { RidePill(it) }
            Text(Fmt.minutes(t.totalMinutes) + if (t.rides.size > 1) " · ${t.rides.size - 1} change${if (t.rides.size > 2) "s" else ""}" else "",
                color = DS.t.secondary, style = MaterialTheme.typography.bodySmall, modifier = Modifier.align(Alignment.CenterVertically))
        }
        val f = t.first
        Text("from ${f.fromStop}${f.platform?.let { " · platform $it" } ?: ""}${if (f.delay > 0) " · +${f.delay} min" else ""}${if (f.cancelled) " · cancelled" else ""}",
            color = if (f.cancelled || f.delay > 2) DS.t.warning else DS.t.secondary, style = MaterialTheme.typography.bodySmall)
    }
}

/** A leg in a trip's details: the line, from and to with times and platform, the walk before it. */
@Composable
fun LegRow(r: Ride) {
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        if (r.walkBefore > 0) Text("Walk ${r.walkBefore} min", color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
        Row(verticalAlignment = Alignment.CenterVertically) {
            RidePill(r)
            Spacer(Modifier.width(8.dp))
            Text(r.headsign.ifEmpty { r.toStop }, color = DS.t.text, fontWeight = FontWeight.SemiBold, maxLines = 1)
        }
        Text("${Fmt.time(r.departure)}  ${r.fromStop}${r.platform?.let { " · platform $it" } ?: ""}", color = DS.t.text, style = MaterialTheme.typography.bodyMedium)
        Text("${Fmt.time(r.arrival)}  ${r.toStop}", color = DS.t.text, style = MaterialTheme.typography.bodyMedium)
    }
}

@Composable
fun Page(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) =
    Column(modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(12.dp), content = content)
