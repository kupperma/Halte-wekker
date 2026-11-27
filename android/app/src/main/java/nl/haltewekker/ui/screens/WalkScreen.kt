package nl.haltewekker.ui.screens

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.net.Uri
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.speech.tts.TextToSpeech
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.core.Iso
import nl.haltewekker.ride.AudioRoute
import nl.haltewekker.ride.Phase
import nl.haltewekker.ride.RideStore
import nl.haltewekker.travel.WalkGuide
import nl.haltewekker.travel.WalkRoute
import nl.haltewekker.ui.theme.DS
import org.maplibre.android.MapLibre
import org.maplibre.android.camera.CameraPosition
import org.maplibre.android.camera.CameraUpdateFactory
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.maps.MapLibreMap
import org.maplibre.android.maps.MapView
import org.maplibre.android.maps.Style
import org.maplibre.android.style.layers.CircleLayer
import org.maplibre.android.style.layers.LineLayer
import org.maplibre.android.style.layers.Property
import org.maplibre.android.style.layers.PropertyFactory
import org.maplibre.android.style.sources.GeoJsonSource
import org.maplibre.geojson.Feature
import org.maplibre.geojson.FeatureCollection
import org.maplibre.geojson.LineString
import org.maplibre.geojson.Point

/** Where "Walk with arrows" goes: the stop, its platform, and the ride to catch from it (if any). */
data class WalkTarget(val to: GeoPoint, val name: String, val platform: String? = null, val leaves: Double? = null, val what: String = "your bus")

/** (0.10.0) The walk screen open over everything (`MainActivity` draws it), from any walk sheet. */
object WalkNav {
    val target = MutableStateFlow<WalkTarget?>(null)
    fun open(t: WalkTarget) { target.value = t }
    fun close() { target.value = null }

    /** The phone's maps app at the stop ("Open in maps", inside the walk). */
    fun openInMaps(context: Context, t: WalkTarget) {
        val q = Uri.encode(t.name)
        val uri = Uri.parse("geo:${t.to.lat},${t.to.lon}?q=${t.to.lat},${t.to.lon}($q)")
        try { context.startActivity(Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) } catch (_: Exception) {}
    }
}

/** "your bus", "your train" for the walk's "Your bus leaves in 6 min". */
fun walkWhat(r: nl.haltewekker.data.Ride) = if (r.isTrain) "your train" else "your bus"

/**
 * "Walk there" (Fastest trip's chosen card, at a change, a nearby stop's sheet): (0.10.3, iOS 0.42.4) the walk with
 * arrows at once (`WalkScreen`), no sheet first; "Open in maps" stays inside the walk.
 */
@Composable
fun WalkThere(t: WalkTarget, modifier: Modifier = Modifier) {
    Button(onClick = { WalkNav.open(t) }, modifier = modifier.fillMaxWidth()) { Text("↑ Walk there") }
}

/**
 * (0.10.0, iOS 0.41 `WalkGuideView`) walking turn by turn to the stop: a full-screen map that follows you (heading up,
 * or north up with the toggle), the OSRM foot route with the walked part dimmed, a big card "In 40 m · Turn right onto
 * Hoogstraat" with the turn after it small, "4 min · 320 m to go" and, with a ride to catch, "Your bus leaves in 6
 * min · you’ll make it / walk a bit faster / hurry". GPS (GPS and network, no Play Services) at best accuracy only
 * while this screen is in front. A buzz 30 m before a turn, two at it; spoken turns only with headphones in and never
 * while an alarm rings; within 25 m "You’re here · Platform 4", then it closes. Rules: `WalkGuide`.
 */
@SuppressLint("MissingPermission")
@Composable
fun WalkScreen(t: WalkTarget, onClose: () -> Unit) {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    BackHandler(onBack = onClose)
    val prefs = remember { context.getSharedPreferences("haltewekker", Context.MODE_PRIVATE) }
    var voice by remember { mutableStateOf(prefs.getBoolean("walk.voice", true)) }
    var headingUp by remember { mutableStateOf(prefs.getBoolean("walk.headingUp", true)) }
    var here by remember { mutableStateOf<Location?>(null) }
    var route by remember { mutableStateOf<WalkGuide.Route?>(null) }
    var step by remember { mutableIntStateOf(0) }
    var along by remember { mutableStateOf<Double?>(null) }
    var pos by remember { mutableStateOf<WalkGuide.Position?>(null) }
    var warnedStep by remember { mutableIntStateOf(-1) }
    var off by remember { mutableStateOf(WalkGuide.OffRoute()) }
    var arrived by remember { mutableStateOf(false) }
    var trouble by remember { mutableStateOf<String?>(null) }
    var now by remember { mutableDoubleStateOf(Iso.now()) }
    val close by rememberUpdatedState(onClose)
    val speed = remember { nl.haltewekker.travel.Habits.walkSpeed(nl.haltewekker.travel.HabitStore.book.value) }

    // spoken turns: their own TextToSpeech, only with headphones in, never while an alarm rings
    val tts = remember { arrayOfNulls<TextToSpeech>(1) }
    DisposableEffect(Unit) {
        var ready = false
        val e = TextToSpeech(context) { ready = it == TextToSpeech.SUCCESS }
        tts[0] = e
        onDispose { try { e.stop(); e.shutdown() } catch (_: Exception) {}; tts[0] = null; if (!ready) Unit }
    }
    fun say(text: String) {
        if (!voice || !AudioRoute.privateOutput(context)) return
        if (RideStore.state.value?.phase == Phase.ALARM || nl.haltewekker.school.WakeService.ringing.value != null) return
        try { tts[0]?.speak(text, TextToSpeech.QUEUE_FLUSH, null, "walk") } catch (_: Exception) {}
    }
    fun buzz(pattern: LongArray) {
        val v = context.getSystemService(Vibrator::class.java) ?: return
        try { v.vibrate(VibrationEffect.createWaveform(pattern, -1)) } catch (_: Exception) {}
    }

    // GPS only while this screen is in front: GPS and network, every second, 3 m
    DisposableEffect(lifecycle) {
        val lm = context.getSystemService(LocationManager::class.java)
        val listener = LocationListener { l ->
            val cur = here
            // a network fix while GPS gives good ones adds nothing
            if (l.provider == LocationManager.NETWORK_PROVIDER && cur != null && cur.provider == LocationManager.GPS_PROVIDER &&
                l.time - cur.time < 15_000 && cur.accuracy <= 30) return@LocationListener
            here = l
        }
        fun on() {
            val ok = ContextCompat.checkSelfPermission(context, android.Manifest.permission.ACCESS_FINE_LOCATION) == android.content.pm.PackageManager.PERMISSION_GRANTED ||
                ContextCompat.checkSelfPermission(context, android.Manifest.permission.ACCESS_COARSE_LOCATION) == android.content.pm.PackageManager.PERMISSION_GRANTED
            if (!ok) { trouble = "Location isn't allowed: the arrows need it."; return }
            try {
                if (lm.isProviderEnabled(LocationManager.GPS_PROVIDER)) lm.requestLocationUpdates(LocationManager.GPS_PROVIDER, 1000L, 3f, listener, Looper.getMainLooper())
                if (lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER)) lm.requestLocationUpdates(LocationManager.NETWORK_PROVIDER, 5000L, 3f, listener, Looper.getMainLooper())
                (lm.getLastKnownLocation(LocationManager.GPS_PROVIDER) ?: lm.getLastKnownLocation(LocationManager.NETWORK_PROVIDER))
                    ?.takeIf { System.currentTimeMillis() - it.time < 120_000 }?.let { if (here == null) here = it }
            } catch (_: Exception) {}
        }
        fun stop() { try { lm.removeUpdates(listener) } catch (_: Exception) {} }
        val obs = LifecycleEventObserver { _, e ->
            when (e) {
                Lifecycle.Event.ON_START -> on()
                Lifecycle.Event.ON_STOP -> stop()
                else -> {}
            }
        }
        lifecycle.addObserver(obs)
        if (lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) on()
        nl.haltewekker.logs.FieldLog.ride("walk · with arrows to ${t.name} · gps on (walking with arrows)")
        onDispose { lifecycle.removeObserver(obs); stop(); nl.haltewekker.logs.FieldLog.ride("walk · closed · gps off") }
    }

    // the route: once a fix is in (tried again every 5 s until one comes), and again from where you are when off it
    // for 10 s (`WalkRoute` asks at most every 20 s); its own effects, so a new fix never cancels a request on its way
    var rerouteFrom by remember { mutableStateOf<GeoPoint?>(null) }
    LaunchedEffect(Unit) {
        while (route == null) {
            here?.let { l ->
                val r = WalkRoute.fetch(GeoPoint(l.latitude, l.longitude), t.to)
                if (r != null) { route = r; step = 0; along = null; warnedStep = -1; trouble = null }
                else trouble = "Couldn’t get a walking route just now: the stop is the green dot."
            }
            delay(5000)
        }
    }
    LaunchedEffect(rerouteFrom) {
        val p = rerouteFrom ?: return@LaunchedEffect
        WalkRoute.fetch(p, t.to)?.let { nr -> route = nr; step = 0; along = null; warnedStep = -1 }
    }
    LaunchedEffect(arrived) { if (arrived) { delay(2500); close() } }
    LaunchedEffect(Unit) { while (true) { delay(1000); now = Iso.now() } }

    // each fix: on the route, the step, the buzzes and words, off the route, there
    LaunchedEffect(here) {
        val l = here ?: return@LaunchedEffect
        val p = GeoPoint(l.latitude, l.longitude)
        val acc = if (l.hasAccuracy()) l.accuracy.toDouble() else -1.0
        if (!arrived && WalkGuide.arrived(Geo.metres(p, t.to), acc)) {
            arrived = true
            buzz(longArrayOf(0, 60, 80, 60, 80, 160))
            say("You're here" + (t.platform?.let { ", platform $it" } ?: ""))
            return@LaunchedEffect
        }
        val r = route ?: return@LaunchedEffect
        if (acc < 0 || acc > WalkGuide.WORST_FIX) return@LaunchedEffect
        val q = WalkGuide.locate(p, r, step, along) ?: return@LaunchedEffect
        if (q.off <= WalkGuide.OFF_ROUTE_METRES) along = q.along
        if (q.advanced) {
            step = q.step
            buzz(longArrayOf(0, 180, 120, 180))
            WalkGuide.next(r, q.step)?.let { say(WalkGuide.spoken(q.toTurn, it)) }
        } else if (warnedStep != q.step && WalkGuide.warn(q, r, false)) {
            warnedStep = q.step
            buzz(longArrayOf(0, 90))
            WalkGuide.next(r, q.step)?.let { say(WalkGuide.spoken(q.toTurn, it)) }
        }
        pos = q
        val (o, again) = WalkGuide.offRoute(off, q.off, acc, Iso.now())
        off = o
        if (again) rerouteFrom = p
    }

    Box(Modifier.fillMaxSize().background(DS.t.page)) {
        WalkMap(Modifier.fillMaxSize(), route, along, here, t.to, headingUp)
        Column(Modifier.fillMaxSize().safeDrawingPadding().padding(12.dp), verticalArrangement = Arrangement.SpaceBetween) {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Surface(shape = RoundedCornerShape(20.dp), color = DS.t.surface) { TextButton(onClick = onClose) { Text("✕ Close", color = DS.t.text) } }
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Surface(shape = RoundedCornerShape(20.dp), color = DS.t.surface) {
                            TextButton(onClick = { voice = !voice; prefs.edit().putBoolean("walk.voice", voice).apply() }) {
                                Text(if (voice) "🔊 Voice" else "🔇 Voice", color = DS.t.text)
                            }
                        }
                        Surface(shape = RoundedCornerShape(20.dp), color = DS.t.surface) {
                            TextButton(onClick = { headingUp = !headingUp; prefs.edit().putBoolean("walk.headingUp", headingUp).apply() }) {
                                Text(if (headingUp) "Heading up" else "North up", color = DS.t.text)
                            }
                        }
                    }
                }
                ArrowCard(t, route, pos, arrived)
            }
            Surface(shape = RoundedCornerShape(16.dp), color = DS.t.surface, modifier = Modifier.fillMaxWidth()) {
                Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    val left = pos?.left ?: here?.let { Geo.metres(GeoPoint(it.latitude, it.longitude), t.to) * 1.3 }
                    if (left != null) {
                        val h = WalkGuide.hurry(left, speed, t.leaves, now, t.what)
                        Text(WalkGuide.left(left, h.walkMinutes), fontWeight = FontWeight.Bold, color = DS.t.text, style = MaterialTheme.typography.titleMedium)
                        h.text?.let { s ->
                            val c = when (h.pace) { WalkGuide.Pace.FINE -> DS.t.accent; WalkGuide.Pace.FASTER -> DS.t.warning; else -> Color(0xFFE86F5A) }
                            Text(s, color = c)
                        }
                    } else Text("Waiting for your location…", color = DS.t.secondary)
                    trouble?.let { Text(it, color = DS.t.secondary, style = MaterialTheme.typography.bodySmall) }
                    OutlinedButton(onClick = { WalkNav.openInMaps(context, t) }, modifier = Modifier.fillMaxWidth()) { Text("Open in maps") }
                    Text("Route © OpenStreetMap contributors (OSRM)", color = DS.t.secondary, style = MaterialTheme.typography.labelSmall)
                }
            }
        }
    }
}

@Composable
private fun ArrowCard(t: WalkTarget, route: WalkGuide.Route?, pos: WalkGuide.Position?, arrived: Boolean) {
    Surface(shape = RoundedCornerShape(18.dp), color = Color(0xFF0E7A55), modifier = Modifier.fillMaxWidth()) {
        Row(Modifier.padding(14.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            if (arrived) {
                Text("◉", color = Color.White, fontSize = 48.sp)
                Text("You’re here" + (t.platform?.let { " · Platform $it" } ?: ""), color = Color.White, fontWeight = FontWeight.Bold, fontSize = 24.sp)
                return@Row
            }
            val r = route
            val q = pos
            val next = if (r != null && q != null) WalkGuide.next(r, q.step) else null
            val turn = next?.turn ?: WalkGuide.Turn.STRAIGHT
            val glyph = when (turn) { WalkGuide.Turn.U_TURN -> "↩"; WalkGuide.Turn.ARRIVE -> "◉"; else -> "↑" }
            Text(glyph, color = Color.White, fontSize = 52.sp, modifier = Modifier.rotate(if (turn == WalkGuide.Turn.U_TURN || turn == WalkGuide.Turn.ARRIVE) 0f else turn.degrees))
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                val big = when {
                    r == null -> "To ${t.name}"
                    q == null || next == null -> "Walk to ${t.name}"
                    next.turn == WalkGuide.Turn.ARRIVE -> "In ${WalkGuide.metres(q.toTurn)} · ${t.name}" + (t.platform?.let { " · Platform $it" } ?: "")
                    else -> WalkGuide.phrase(q.toTurn, next)
                }
                Text(big, color = Color.White, fontWeight = FontWeight.Bold, fontSize = 22.sp, lineHeight = 26.sp)
                if (r != null && q != null) WalkGuide.then(r, q.step)?.let { th ->
                    Text("Then ${th.turn.glyph} ${th.text.ifEmpty { th.turn.words }}", color = Color.White.copy(alpha = 0.85f), style = MaterialTheme.typography.bodyMedium)
                }
            }
        }
    }
}

/** The walk's own map: the route (walked part dimmed), you and the stop; following you, heading up or north up. */
@Composable
private fun WalkMap(modifier: Modifier, route: WalkGuide.Route?, along: Double?, here: Location?, to: GeoPoint, headingUp: Boolean) {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var map by remember { mutableStateOf<MapLibreMap?>(null) }
    var style by remember { mutableStateOf<Style?>(null) }
    val view = remember {
        MapLibre.getInstance(context)
        MapView(context).apply {
            onCreate(null)
            getMapAsync { m ->
                m.uiSettings.isLogoEnabled = false
                m.uiSettings.isCompassEnabled = true
                m.uiSettings.isAttributionEnabled = true
                m.cameraPosition = CameraPosition.Builder().target(LatLng(to.lat, to.lon)).zoom(16.5).build()
                m.setStyle(Style.Builder().fromUri(nl.haltewekker.map.MapStyle.STYLE_URL)) { s ->
                    for (id in listOf("walked", "togo", "ends")) s.addSource(GeoJsonSource(id))
                    s.addLayer(LineLayer("walked-line", "walked").withProperties(PropertyFactory.lineColor("#8A929A"), PropertyFactory.lineOpacity(0.55f),
                        PropertyFactory.lineWidth(6f), PropertyFactory.lineCap(Property.LINE_CAP_ROUND), PropertyFactory.lineJoin(Property.LINE_JOIN_ROUND)))
                    s.addLayer(LineLayer("togo-line", "togo").withProperties(PropertyFactory.lineColor("#2F7CF6"), PropertyFactory.lineWidth(7f),
                        PropertyFactory.lineCap(Property.LINE_CAP_ROUND), PropertyFactory.lineJoin(Property.LINE_JOIN_ROUND)))
                    s.addLayer(CircleLayer("ends-dots", "ends").withProperties(PropertyFactory.circleColor(org.maplibre.android.style.expressions.Expression.get("color")),
                        PropertyFactory.circleRadius(8f), PropertyFactory.circleStrokeColor(android.graphics.Color.WHITE), PropertyFactory.circleStrokeWidth(3f)))
                    style = s
                }
                map = m
            }
        }
    }
    DisposableEffect(lifecycle) {
        val obs = LifecycleEventObserver { _, e ->
            when (e) {
                Lifecycle.Event.ON_START -> view.onStart()
                Lifecycle.Event.ON_RESUME -> view.onResume()
                Lifecycle.Event.ON_PAUSE -> view.onPause()
                Lifecycle.Event.ON_STOP -> view.onStop()
                else -> {}
            }
        }
        lifecycle.addObserver(obs)
        if (lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) { view.onStart(); if (lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) view.onResume() }
        onDispose { lifecycle.removeObserver(obs); view.onPause(); view.onStop(); view.onDestroy() }
    }
    LaunchedEffect(style, route, along) {
        val s = style ?: return@LaunchedEffect
        val r = route
        fun line(pts: List<GeoPoint>) = if (pts.size < 2) FeatureCollection.fromFeatures(emptyList())
            else FeatureCollection.fromFeature(Feature.fromGeometry(LineString.fromLngLats(pts.map { Point.fromLngLat(it.lon, it.lat) })))
        val (walked, togo) = if (r != null) WalkGuide.split(r.path, along ?: 0.0) else (emptyList<GeoPoint>() to emptyList())
        (s.getSource("walked") as? GeoJsonSource)?.setGeoJson(line(walked))
        (s.getSource("togo") as? GeoJsonSource)?.setGeoJson(line(togo))
    }
    LaunchedEffect(style, here) {
        val s = style ?: return@LaunchedEffect
        val f = listOfNotNull(
            Feature.fromGeometry(Point.fromLngLat(to.lon, to.lat)).apply { addStringProperty("color", "#0E7A55") },
            here?.let { Feature.fromGeometry(Point.fromLngLat(it.longitude, it.latitude)).apply { addStringProperty("color", "#2F7CF6") } })
        (s.getSource("ends") as? GeoJsonSource)?.setGeoJson(FeatureCollection.fromFeatures(f))
    }
    LaunchedEffect(map, here, headingUp) {
        val m = map ?: return@LaunchedEffect
        val l = here ?: return@LaunchedEffect
        val bearing = if (headingUp && l.hasBearing() && l.speed >= 0.6f) l.bearing.toDouble() else if (headingUp) m.cameraPosition.bearing else 0.0
        val cam = CameraPosition.Builder().target(LatLng(l.latitude, l.longitude)).zoom(maxOf(16.5, m.cameraPosition.zoom)).bearing(bearing).build()
        try { m.easeCamera(CameraUpdateFactory.newCameraPosition(cam), 600) } catch (_: Exception) {}
    }
    AndroidView(factory = { view }, modifier = modifier)
}
