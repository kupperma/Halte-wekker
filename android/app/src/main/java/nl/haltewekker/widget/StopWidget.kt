package nl.haltewekker.widget

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.View
import android.widget.RemoteViews
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.builtins.ListSerializer
import nl.haltewekker.App
import nl.haltewekker.R
import nl.haltewekker.data.Net
import nl.haltewekker.friends.FriendJson
import nl.haltewekker.ui.Card
import nl.haltewekker.ui.theme.DS
import nl.haltewekker.ui.theme.HaltewekkerTheme
import nl.haltewekker.ui.MainActivity
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * (A6, iOS 0.37 `StopWidget.swift`) "Next departures" on the home screen: a stop you pick when you add it, its next
 * departures from Transitous (`/v6/stoptimes`, asked by the widget itself; `StopBoardCore`). It moves the list up
 * just after each departure leaves without asking again, and asks again every 12 minutes (sooner when the list runs
 * short, at least 5 min apart; 30 min with nothing leaving), by an inexact AlarmManager broadcast to itself: no
 * WorkManager, no Play services, nothing while no widget is placed. Tap: the app on that stop.
 */
class StopWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val p = goAsync()
        StopWidgetStore.scope.launch { try { ids.forEach { StopWidgetStore.refresh(context, it, force = false) } } finally { p.finish() } }
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == ACTION_TICK) {
            val id = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, -1)
            if (id < 0) return
            val p = goAsync()
            StopWidgetStore.scope.launch { try { StopWidgetStore.refresh(context, id, force = false) } finally { p.finish() } }
            return
        }
        super.onReceive(context, intent)
    }

    override fun onDeleted(context: Context, ids: IntArray) { ids.forEach { StopWidgetStore.forget(context, it) } }

    companion object {
        const val ACTION_TICK = "nl.haltewekker.widget.TICK"
        const val COUNT = 4

        fun updateAll(context: Context) {
            val m = AppWidgetManager.getInstance(context)
            val ids = m.getAppWidgetIds(ComponentName(context, StopWidget::class.java))
            StopWidgetStore.scope.launch { ids.forEach { StopWidgetStore.refresh(context, it, force = true) } }
        }
    }
}

object StopWidgetStore {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val depSer = ListSerializer(StopBoardCore.Departure.serializer())
    private fun prefs(c: Context) = c.getSharedPreferences("widgets", Context.MODE_PRIVATE)
    private val hm = SimpleDateFormat("HH:mm", Locale.UK)
    private fun hhmm(t: Double) = hm.format(Date((t * 1000).toLong()))
    private fun now() = System.currentTimeMillis() / 1000.0

    fun stop(c: Context, id: Int): StopBoardCore.Stop? = prefs(c).getString("stop.$id", null)?.let(StopBoardCore::decode)

    fun setStop(c: Context, id: Int, s: StopBoardCore.Stop) {
        prefs(c).edit().putString("stop.$id", StopBoardCore.encode(s)).remove("deps.$id").remove("reload.$id").apply()
    }

    fun forget(c: Context, id: Int) {
        prefs(c).edit().remove("stop.$id").remove("deps.$id").remove("reload.$id").apply()
        c.getSystemService(AlarmManager::class.java)?.cancel(tick(c, id))
    }

    private fun tick(c: Context, id: Int) = PendingIntent.getBroadcast(c, 5000 + id,
        Intent(c, StopWidget::class.java).setAction(StopWidget.ACTION_TICK).putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)

    /** Draws widget `id` now: from its kept answer while that's still good, else asked again. */
    suspend fun refresh(c: Context, id: Int, force: Boolean) {
        val m = AppWidgetManager.getInstance(c)
        val s = stop(c, id)
        if (s == null) { m.updateAppWidget(id, views(c, id, null, emptyList())); return }
        val now = now()
        val p = prefs(c)
        var deps = p.getString("deps.$id", null)?.let { FriendJson.decode(depSer, it) }
        val reload = p.getFloat("reload.$id", 0f).toDouble().takeIf { it > 0 } ?: 0.0
        if (force || deps == null || now >= reload - 5) {
            val a = Net.get(StopBoardCore.stoptimesUrl(s.id, now - 60, 12))
            if (a.ok) deps = StopBoardCore.parseStoptimes(a.text)
        }
        val list = deps ?: emptyList()
        val (entries, reloadAt) = StopBoardCore.timeline(list, now, StopWidget.COUNT)
        p.edit().putString("deps.$id", FriendJson.encodeString(depSer, list)).putFloat("reload.$id", reloadAt.toFloat()).apply()
        m.updateAppWidget(id, views(c, id, s, entries.first().departures))
        // the next moment it changes: just after the next departure leaves, or the refresh
        val next = entries.drop(1).firstOrNull()?.date?.coerceAtMost(reloadAt) ?: reloadAt
        val am = c.getSystemService(AlarmManager::class.java) ?: return
        try { am.setWindow(AlarmManager.RTC, (next * 1000).toLong(), 60_000L, tick(c, id)) } catch (_: Exception) {}
    }

    fun views(c: Context, id: Int, s: StopBoardCore.Stop?, deps: List<StopBoardCore.Departure>): RemoteViews {
        val v = RemoteViews(c.packageName, R.layout.widget_stop)
        val rows = listOf(R.id.row0, R.id.row1, R.id.row2, R.id.row3)
        val lines = listOf(R.id.line0, R.id.line1, R.id.line2, R.id.line3)
        val heads = listOf(R.id.head0, R.id.head1, R.id.head2, R.id.head3)
        val times = listOf(R.id.time0, R.id.time1, R.id.time2, R.id.time3)
        if (s == null) {
            v.setTextViewText(R.id.title, "Next departures")
            v.setTextViewText(R.id.empty, "Pick a stop")
            v.setViewVisibility(R.id.empty, View.VISIBLE)
            rows.forEach { v.setViewVisibility(it, View.GONE) }
            val cfg = Intent(c, StopWidgetConfig::class.java).putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id)
            v.setOnClickPendingIntent(R.id.widget_root, PendingIntent.getActivity(c, 6000 + id, cfg, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
            return v
        }
        v.setTextViewText(R.id.title, s.name)
        v.setViewVisibility(R.id.empty, if (deps.isEmpty()) View.VISIBLE else View.GONE)
        v.setTextViewText(R.id.empty, "Nothing leaves soon")
        rows.forEachIndexed { i, r ->
            val d = deps.getOrNull(i)
            v.setViewVisibility(r, if (d == null) View.GONE else View.VISIBLE)
            if (d != null) {
                v.setTextViewText(lines[i], StopBoardCore.title(d))
                v.setTextViewText(heads[i], d.headsign)
                v.setTextViewText(times[i], StopBoardCore.timeText(d) { hhmm(it) })
                v.setTextColor(times[i], c.getColor(if (d.cancelled || d.delay > 2) R.color.widget_warning else R.color.widget_text))
            }
        }
        val open = Intent(Intent.ACTION_VIEW, Uri.parse(StopBoardCore.link(s)), c, MainActivity::class.java)
        v.setOnClickPendingIntent(R.id.widget_root, PendingIntent.getActivity(c, 7000 + id, open, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
        return v
    }
}

/** Picking the widget's stop: your home stops, or a search (Transitous `/v1/geocode`, stops only). */
class StopWidgetConfig : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val id = intent?.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID) ?: AppWidgetManager.INVALID_APPWIDGET_ID
        setResult(RESULT_CANCELED, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id))
        if (id == AppWidgetManager.INVALID_APPWIDGET_ID) { finish(); return }
        val app = application as App
        val home = app.store.profile.value.homeStops.map { StopBoardCore.Stop(it.id, it.name, lat = it.lat, lon = it.lon, rail = it.rail) }
        fun pick(s: StopBoardCore.Stop) {
            StopWidgetStore.setStop(this, id, s)
            StopWidgetStore.scope.launch { StopWidgetStore.refresh(this@StopWidgetConfig, id, force = true) }
            setResult(RESULT_OK, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id))
            finish()
        }
        setContent {
            HaltewekkerTheme {
                var q by remember { mutableStateOf("") }
                var hits by remember { mutableStateOf<List<StopBoardCore.Stop>>(emptyList()) }
                LaunchedEffect(q) {
                    if (q.trim().length < 3) { hits = emptyList(); return@LaunchedEffect }
                    delay(400)
                    val here = nl.haltewekker.ui.Locator.last(this@StopWidgetConfig)
                    val a = Net.get(StopBoardCore.geocodeUrl(q.trim(), here?.let { it.lat to it.lon }))
                    hits = if (a.ok) StopBoardCore.parseGeocode(a.text) else emptyList()
                }
                Column(Modifier.fillMaxSize().background(DS.t.page).safeDrawingPadding().verticalScroll(rememberScrollState()).padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("Next departures from…", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, color = DS.t.text)
                    if (home.isNotEmpty()) Card {
                        Text("Your home stops", color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
                        home.forEach { s -> Text(s.name, color = DS.t.text, fontWeight = FontWeight.SemiBold, modifier = Modifier.fillMaxWidth().clickable { pick(s) }.padding(vertical = 8.dp)) }
                    }
                    OutlinedTextField(q, { q = it }, Modifier.fillMaxWidth(), label = { Text("Search a stop or station") }, singleLine = true)
                    hits.forEach { s ->
                        Column(Modifier.fillMaxWidth().clickable { pick(s) }.padding(vertical = 6.dp)) {
                            Text(s.name, color = DS.t.text, fontWeight = FontWeight.SemiBold)
                            if (s.town.isNotEmpty()) Text(s.town + if (s.rail) " · station" else "", color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
                        }
                    }
                }
            }
        }
    }
}
