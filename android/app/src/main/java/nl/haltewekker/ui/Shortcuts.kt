package nl.haltewekker.ui

import android.content.Context
import android.content.Intent
import android.speech.tts.TextToSpeech
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.width
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import nl.haltewekker.App
import nl.haltewekker.R
import nl.haltewekker.core.Geo
import nl.haltewekker.core.Iso
import nl.haltewekker.data.Net
import nl.haltewekker.data.Transit
import nl.haltewekker.ride.Notifications
import nl.haltewekker.ui.theme.DS
import nl.haltewekker.widget.IntentActions
import nl.haltewekker.widget.StopBoardCore

/**
 * (A6, iOS 0.37 `SiriIntents.swift`, the Android way: app shortcuts, no Assistant) long-press the app's icon for
 * "When's my bus?", "Plan to school", "Plan home" and "Start my trip"; "Wake me at a stop" is Plan to a searched stop
 * (Android has no separate single-stop alarm). They only open the app: nothing starts over a running trip.
 */
object Shortcuts {
    const val ACTION = "nl.haltewekker.SHORTCUT"
    const val EXTRA = "shortcut"
    const val BUS = "bus"
    const val SCHOOL = "school"
    const val HOME = "home"
    const val WAKE = "wake"
    const val START = "start"

    fun install(c: Context) {
        fun s(id: String, short: String, long: String, icon: Int) = ShortcutInfoCompat.Builder(c, id)
            .setShortLabel(short).setLongLabel(long).setIcon(IconCompat.createWithResource(c, icon))
            .setIntent(Intent(c, MainActivity::class.java).setAction(ACTION).putExtra(EXTRA, id).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP))
            .build()
        val list = listOf(
            s(BUS, "When's my bus?", "When's my bus?", R.drawable.ic_sc_bus),
            s(SCHOOL, "Plan to school", "Fastest trip to school", R.drawable.ic_sc_school),
            s(HOME, "Plan home", "Fastest trip home", R.drawable.ic_sc_home),
            s(START, "Start my trip", "Start my trip", R.drawable.ic_sc_bell),
            s(WAKE, "Wake me at a stop", "Plan to a stop and wake me there", R.drawable.ic_sc_bus),
        )
        try { ShortcutManagerCompat.setDynamicShortcuts(c, list) } catch (_: Exception) {}
    }
}

/** "When's my bus?": the home stop near home (or with no fix), else the nearest stop; said out loud and shown. */
@Composable
fun BusNowDialog(onDone: () -> Unit) {
    val c = LocalContext.current
    val app = c.applicationContext as App
    var text by remember { mutableStateOf<String?>(null) }
    var tts by remember { mutableStateOf<TextToSpeech?>(null) }
    DisposableEffect(Unit) {
        var t: TextToSpeech? = null
        t = TextToSpeech(c.applicationContext) { ok -> if (ok == TextToSpeech.SUCCESS) { t?.language = java.util.Locale.UK; tts = t } }
        onDispose { t.shutdown() }
    }
    LaunchedEffect(Unit) {
        val p = app.store.profile.value
        val here = Locator.last(c)
        val home = p.homeStops.firstOrNull()
        val from = IntentActions.busFrom(here?.let { h -> p.home?.point?.let { Geo.metres(h, it) } }, home != null)
        val stop = if (from == IntentActions.BusFrom.HOME && home != null) StopBoardCore.Stop(home.id, home.name, lat = home.lat, lon = home.lon, rail = home.rail)
            else here?.let { Transit.nearStops(it)?.firstOrNull() }?.let { StopBoardCore.Stop(it.id, it.name, lat = it.lat, lon = it.lon, rail = it.rail) }
        if (stop == null) { text = "There's no stop to look at: allow location, or set your home stops."; return@LaunchedEffect }
        val now = Iso.now()
        val a = Net.get(StopBoardCore.stoptimesUrl(stop.id, now - 60, 8))
        text = if (a.ok) StopBoardCore.spoken(StopBoardCore.parseStoptimes(a.text), stop.name, now) { Notifications.time(it) }
            else "No connection to Transitous just now."
    }
    LaunchedEffect(text, tts) { val t = text; val s = tts; if (t != null && s != null) s.speak(t, TextToSpeech.QUEUE_FLUSH, null, "bus") }
    AlertDialog(onDismissRequest = onDone, title = { Text("When's my bus?") },
        text = {
            val t = text
            if (t == null) Row(verticalAlignment = Alignment.CenterVertically) { CircularProgressIndicator(); Spacer(Modifier.width(12.dp)); Text("Looking…") }
            else Text(t)
        },
        confirmButton = { TextButton(onClick = onDone) { Text("OK") } })
}

/** The widget's tap: the stop's next departures. */
@Composable
fun StopSheet(stop: StopBoardCore.Stop, onDone: () -> Unit) {
    var deps by remember { mutableStateOf<List<StopBoardCore.Departure>?>(null) }
    LaunchedEffect(stop.id) {
        val a = Net.get(StopBoardCore.stoptimesUrl(stop.id, Iso.now() - 60, 12))
        deps = if (a.ok) StopBoardCore.parseStoptimes(a.text) else emptyList()
    }
    AlertDialog(onDismissRequest = onDone, title = { Text(stop.name) },
        text = {
            val d = deps
            Column {
                if (d == null) CircularProgressIndicator()
                else if (d.isEmpty()) Text("Nothing leaves soon.", color = DS.t.secondary)
                else StopBoardCore.upcoming(d, Iso.now(), 8).forEach { x ->
                    Row(Modifier.fillMaxWidth()) {
                        Text(StopBoardCore.title(x), fontWeight = FontWeight.SemiBold, color = DS.t.text, modifier = Modifier.width(72.dp))
                        Text(x.headsign, color = DS.t.secondary, modifier = Modifier.weight(1f), maxLines = 1, style = MaterialTheme.typography.bodyMedium)
                        Text(StopBoardCore.timeText(x) { Notifications.time(it) }, color = if (x.cancelled || x.delay > 2) DS.t.warning else DS.t.text)
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDone) { Text("Done") } })
}
