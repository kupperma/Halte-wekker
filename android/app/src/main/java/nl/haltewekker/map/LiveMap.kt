package nl.haltewekker.map

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.Color as AColor
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.friends.MapFrame
import org.maplibre.android.MapLibre
import org.maplibre.android.camera.CameraPosition
import org.maplibre.android.camera.CameraUpdateFactory
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.geometry.LatLngBounds
import org.maplibre.android.maps.MapLibreMap
import org.maplibre.android.maps.MapView
import org.maplibre.android.maps.Style
import org.maplibre.android.style.expressions.Expression
import org.maplibre.android.style.layers.CircleLayer
import org.maplibre.android.style.layers.LineLayer
import org.maplibre.android.style.layers.Property
import org.maplibre.android.style.layers.PropertyFactory
import org.maplibre.android.style.layers.SymbolLayer
import org.maplibre.android.style.sources.GeoJsonSource
import org.maplibre.geojson.Feature
import org.maplibre.geojson.FeatureCollection
import org.maplibre.geojson.LineString
import org.maplibre.geojson.Point

/**
 * A dot on the map: a vehicle (its line on it, in its kind's colour), a stop, or you. (A8.1) `sub`: a small label under
 * it ("GPS 40 s", "by times"); `opacity` (by times: 60 %); kind "ghost": a small hollow translucent dot.
 */
data class MapDot(val id: String, val p: GeoPoint, val color: Int, val label: String = "", val kind: String = "vehicle",
                  val sub: String = "", val opacity: Double = 1.0)

/** (A8.1) A line on the map: a planned route (a walk dashed) or a friend's route. ARGB colour. */
data class MapLine(val points: List<GeoPoint>, val color: Int, val walk: Boolean = false, val opacity: Double = 0.9)

/** (A8.1) A pin: a light pill with an icon and text in `color` (the stop you wait at: a person waiting; a place found). */
data class MapPin(val id: String, val p: GeoPoint, val text: String, val color: Int, val person: Boolean = true, val sub: String = "")

/** How the map follows `frame`: always fitted to it, or moved only when it isn't in view. */
enum class FrameMode { FIT, IF_OUTSIDE }

/**
 * The home map: OpenStreetMap-based vector tiles from OpenFreeMap (no API key, no Google services) in MapLibre, with
 * your position, nearby stops and the live buses and trains as data-driven circles. (A8.1, iOS 0.40.0–0.40.3) one map
 * for everything over the home: the vehicle you wait for (`focus`), the stop pin, a planned route and the stops found
 * (search), friends' faces and routes (Friends); framed on `frame` in the part a sheet leaves free (`cover`), and back
 * where it was once `frame` is empty again.
 */
object MapStyle {
    const val STYLE_URL = "https://tiles.openfreemap.org/styles/liberty"
}

@Composable
fun LiveMap(
    modifier: Modifier,
    centre: GeoPoint?,
    me: GeoPoint?,
    dots: List<MapDot>,
    focus: List<MapDot> = emptyList(),
    pins: List<MapPin> = emptyList(),
    lines: List<MapLine> = emptyList(),
    faces: List<FriendMapPin> = emptyList(),
    pictures: Map<String, ByteArray> = emptyMap(),
    stops: List<MapStop> = emptyList(),
    frame: List<GeoPoint> = emptyList(),
    frameMode: FrameMode = FrameMode.FIT,
    cover: Double = 0.0,
    dark: Boolean = false,
    accent: Int = 0xFF0E7A55.toInt(),
    onTap: ((String) -> Unit)? = null,
    onBounds: (GeoPoint, GeoPoint, Double) -> Unit,
) {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val tap by rememberUpdatedState(onTap)
    val bounds by rememberUpdatedState(onBounds)
    var map by remember { mutableStateOf<MapLibreMap?>(null) }
    var style by remember { mutableStateOf<Style?>(null) }
    var centred by remember { mutableStateOf(false) }
    var size by remember { mutableStateOf(IntSize.Zero) }
    val saved = remember { arrayOfNulls<CameraPosition>(1) }
    val density = context.resources.displayMetrics.density
    val view = remember {
        MapLibre.getInstance(context)
        MapView(context).apply {
            onCreate(null)
            getMapAsync { m ->
                m.uiSettings.isRotateGesturesEnabled = false
                m.uiSettings.isTiltGesturesEnabled = false
                m.uiSettings.isAttributionEnabled = true
                m.uiSettings.isLogoEnabled = false
                m.uiSettings.isCompassEnabled = false
                m.cameraPosition = CameraPosition.Builder().target(LatLng(52.09, 5.12)).zoom(12.0).build()
                m.setStyle(Style.Builder().fromUri(MapStyle.STYLE_URL)) { s ->
                    for (id in listOf("lines", "fstops", "dots", "focus", "pins", "faces")) s.addSource(GeoJsonSource(id))
                    s.addLayer(LineLayer("route-rides", "lines").withFilter(Expression.eq(Expression.get("walk"), false)).withProperties(
                        PropertyFactory.lineColor(Expression.get("color")), PropertyFactory.lineOpacity(Expression.get("opacity")),
                        PropertyFactory.lineWidth(5f), PropertyFactory.lineCap(Property.LINE_CAP_ROUND), PropertyFactory.lineJoin(Property.LINE_JOIN_ROUND)))
                    s.addLayer(LineLayer("route-walks", "lines").withFilter(Expression.eq(Expression.get("walk"), true)).withProperties(
                        PropertyFactory.lineColor(Expression.get("color")), PropertyFactory.lineOpacity(Expression.get("opacity")),
                        PropertyFactory.lineWidth(3.5f), PropertyFactory.lineDasharray(arrayOf(1.2f, 1.4f)), PropertyFactory.lineCap(Property.LINE_CAP_ROUND)))
                    s.addLayer(CircleLayer("fstop-dots", "fstops").withProperties(
                        PropertyFactory.circleColor(Expression.get("color")), PropertyFactory.circleRadius(7f),
                        PropertyFactory.circleStrokeColor(AColor.WHITE), PropertyFactory.circleStrokeWidth(2.5f)))
                    s.addLayer(SymbolLayer("fstop-names", "fstops").withProperties(
                        PropertyFactory.textField(Expression.get("name")), PropertyFactory.textFont(arrayOf("Noto Sans Bold")),
                        PropertyFactory.textSize(12f), PropertyFactory.textOffset(arrayOf(0f, 1.3f)), PropertyFactory.textAnchor(Property.TEXT_ANCHOR_TOP),
                        PropertyFactory.textColor(if (dark) AColor.WHITE else 0xFF14171A.toInt()),
                        PropertyFactory.textHaloColor(if (dark) 0xFF111417.toInt() else AColor.WHITE), PropertyFactory.textHaloWidth(1.5f)))
                    for (src in listOf("dots", "focus")) {
                        s.addLayer(CircleLayer("$src-circles", src).withProperties(
                            PropertyFactory.circleColor(Expression.get("color")),
                            PropertyFactory.circleRadius(Expression.get("radius")),
                            PropertyFactory.circleOpacity(Expression.get("fill")),
                            PropertyFactory.circleStrokeColor(Expression.get("stroke")),
                            PropertyFactory.circleStrokeOpacity(Expression.get("opacity")),
                            PropertyFactory.circleStrokeWidth(2f),
                        ))
                        s.addLayer(SymbolLayer("$src-labels", src).withProperties(
                            PropertyFactory.textField(Expression.get("label")),
                            PropertyFactory.textFont(arrayOf("Noto Sans Bold")),
                            PropertyFactory.textSize(10f),
                            PropertyFactory.textColor(AColor.WHITE),
                            PropertyFactory.textOpacity(Expression.get("opacity")),
                            PropertyFactory.textAllowOverlap(true),
                            PropertyFactory.textIgnorePlacement(true),
                        ))
                        s.addLayer(SymbolLayer("$src-subs", src).withProperties(
                            PropertyFactory.textField(Expression.get("sub")),
                            PropertyFactory.textFont(arrayOf("Noto Sans Bold")),
                            PropertyFactory.textSize(10f),
                            PropertyFactory.textOffset(arrayOf(0f, 1.7f)),
                            PropertyFactory.textAnchor(Property.TEXT_ANCHOR_TOP),
                            PropertyFactory.textColor(if (dark) AColor.WHITE else 0xFF14171A.toInt()),
                            PropertyFactory.textHaloColor(if (dark) 0xFF111417.toInt() else AColor.WHITE),
                            PropertyFactory.textHaloWidth(1.5f),
                            PropertyFactory.textAllowOverlap(true),
                        ))
                    }
                    for (src in listOf("pins", "faces")) s.addLayer(SymbolLayer("$src-icons", src).withProperties(
                        PropertyFactory.iconImage(Expression.get("icon")),
                        PropertyFactory.iconAllowOverlap(true),
                        PropertyFactory.iconIgnorePlacement(true),
                        PropertyFactory.iconOpacity(Expression.get("opacity")),
                    ))
                    style = s
                }
                m.addOnCameraIdleListener {
                    val b = m.projection.visibleRegion.latLngBounds
                    bounds(GeoPoint(b.latitudeSouth, b.longitudeWest), GeoPoint(b.latitudeNorth, b.longitudeEast), m.cameraPosition.zoom)
                }
                m.addOnMapClickListener { ll ->
                    val f = tap ?: return@addOnMapClickListener false
                    val hit = m.queryRenderedFeatures(m.projection.toScreenLocation(ll), "faces-icons", "pins-icons", "focus-circles", "dots-circles").firstOrNull()
                    val id = hit?.getStringProperty("id") ?: return@addOnMapClickListener false
                    f(id)
                    true
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
        onDispose { lifecycle.removeObserver(obs); view.onStop(); view.onDestroy() }
    }
    LaunchedEffect(map, centre) {
        val m = map ?: return@LaunchedEffect
        val c = centre ?: return@LaunchedEffect
        if (!centred) { m.moveCamera(CameraUpdateFactory.newLatLngZoom(LatLng(c.lat, c.lon), 14.5)); centred = true }
    }
    // (iOS 0.40.0 / 0.40.2) framed on what a sheet shows, in the part it leaves free; back where it was when it closes
    val key = frame.joinToString(";") { "%.4f,%.4f".format(java.util.Locale.ROOT, it.lat, it.lon) } + "|" + (cover * 100).toInt() + "|" + frameMode
    LaunchedEffect(map, key, size) {
        val m = map ?: return@LaunchedEffect
        if (size.width <= 1 || size.height <= 1) return@LaunchedEffect
        val pts = frame.filter(MapFrame::valid)
        if (pts.isEmpty()) {
            saved[0]?.let { try { m.easeCamera(CameraUpdateFactory.newCameraPosition(it), 350) } catch (_: Exception) {} }
            saved[0] = null
            return@LaunchedEffect
        }
        if (frameMode == FrameMode.IF_OUTSIDE) {
            val vis = m.projection.visibleRegion.latLngBounds
            val free = vis.latitudeNorth - (vis.latitudeNorth - vis.latitudeSouth) * (1 - cover)
            if (pts.all { vis.contains(LatLng(it.lat, it.lon)) && it.lat >= free }) return@LaunchedEffect
        }
        if (saved[0] == null) saved[0] = m.cameraPosition
        val r = MapFrame.fit(pts, size.height.toDouble() / size.width, cover) ?: return@LaunchedEffect
        val b = LatLngBounds.from(minOf(85.0, r.north), minOf(180.0, r.east), maxOf(-85.0, r.south), maxOf(-180.0, r.west))
        try { m.easeCamera(CameraUpdateFactory.newLatLngBounds(b, 0), 350) } catch (_: Exception) {}
    }
    LaunchedEffect(style, dots, me) {
        val s = style ?: return@LaunchedEffect
        val features = dots.map { feature(it) } + listOfNotNull(me?.let { feature(MapDot("me", it, 0xFF2F7CF6.toInt(), kind = "me")) })
        (s.getSource("dots") as? GeoJsonSource)?.setGeoJson(FeatureCollection.fromFeatures(features))
    }
    LaunchedEffect(style, focus) {
        val s = style ?: return@LaunchedEffect
        (s.getSource("focus") as? GeoJsonSource)?.setGeoJson(FeatureCollection.fromFeatures(focus.map { feature(it) }))
    }
    LaunchedEffect(style, lines) {
        val s = style ?: return@LaunchedEffect
        val f = lines.filter { it.points.size >= 2 }.map { l ->
            Feature.fromGeometry(LineString.fromLngLats(l.points.map { Point.fromLngLat(it.lon, it.lat) })).apply {
                addStringProperty("color", hex(l.color)); addNumberProperty("opacity", l.opacity); addBooleanProperty("walk", l.walk)
            }
        }
        (s.getSource("lines") as? GeoJsonSource)?.setGeoJson(FeatureCollection.fromFeatures(f))
    }
    LaunchedEffect(style, pins, dark) {
        val s = style ?: return@LaunchedEffect
        val f = pins.map { p ->
            val icon = "pin-" + (p.text + p.sub + p.color + p.person + dark).hashCode()
            if (s.getImage(icon) == null) s.addImage(icon, PinBitmap.make(p, density, dark))
            Feature.fromGeometry(Point.fromLngLat(p.p.lon, p.p.lat)).apply {
                addStringProperty("icon", icon); addStringProperty("id", p.id); addNumberProperty("opacity", 1.0)
            }
        }
        (s.getSource("pins") as? GeoJsonSource)?.setGeoJson(FeatureCollection.fromFeatures(f))
    }
    LaunchedEffect(style, faces, stops, pictures) {
        val s = style ?: return@LaunchedEffect
        val px = (48 * density).toInt()
        val f = faces.map { p ->
            val icon = "face-${p.id}"
            s.addImage(icon, FaceBitmap.make(p.name, pictures[p.id], p.ring, px, density, dark))
            Feature.fromGeometry(Point.fromLngLat(p.point.lon, p.point.lat)).apply {
                addStringProperty("icon", icon); addStringProperty("id", "face:${p.id}"); addNumberProperty("opacity", if (p.stale) 0.6 else 1.0)
            }
        }
        (s.getSource("faces") as? GeoJsonSource)?.setGeoJson(FeatureCollection.fromFeatures(f))
        val st = stops.map { x ->
            Feature.fromGeometry(Point.fromLngLat(x.point.lon, x.point.lat)).apply {
                addStringProperty("color", if (x.id == "to") hex(accent) else "#8A929A"); addStringProperty("name", x.name)
            }
        }
        (s.getSource("fstops") as? GeoJsonSource)?.setGeoJson(FeatureCollection.fromFeatures(st))
    }
    AndroidView(factory = { view }, modifier = modifier.onSizeChanged { size = it })
}

private fun feature(d: MapDot): Feature = Feature.fromGeometry(Point.fromLngLat(d.p.lon, d.p.lat)).apply {
    val ghost = d.kind == "ghost"
    addStringProperty("id", d.id)
    addStringProperty("color", hex(d.color))
    addStringProperty("stroke", if (ghost) hex(d.color) else "#FFFFFF")
    addStringProperty("label", if (ghost) "" else d.label)
    addStringProperty("sub", d.sub)
    addNumberProperty("fill", if (ghost) 0.18 else d.opacity)
    addNumberProperty("opacity", if (ghost) 0.55 else d.opacity)
    addNumberProperty("radius", when (d.kind) { "stop" -> 4; "me" -> 8; "ghost" -> 6; "focus" -> 14; else -> if (d.label.length > 3) 13 else 11 })
}

private fun hex(c: Int) = String.format("#%06X", 0xFFFFFF and c)

/** (A8.1, iOS 0.40.3) the stop pin: a light pill, a person waiting and the text in the line's colour, the border too. */
object PinBitmap {
    fun make(p: MapPin, density: Float, dark: Boolean): Bitmap {
        val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = p.color; textSize = 12 * density; typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        }
        val small = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = if (dark) 0xFFA3ABB3.toInt() else 0xFF5B636B.toInt(); textSize = 10 * density
        }
        val pad = 8 * density
        val icon = if (p.person) 12 * density else 8 * density
        val w1 = text.measureText(p.text)
        val w2 = if (p.sub.isEmpty()) 0f else small.measureText(p.sub)
        val w = (pad * 2 + icon + 5 * density + maxOf(w1, w2)).toInt() + 2
        val h = ((if (p.sub.isEmpty()) 26 else 38) * density).toInt()
        val b = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val c = Canvas(b)
        val r = RectF(density, density, w - density, h - density)
        val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = if (dark) 0xFF24282D.toInt() else AColor.WHITE }
        c.drawRoundRect(r, 13 * density, 13 * density, fill)
        val line = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = 2 * density; color = p.color }
        c.drawRoundRect(r, 13 * density, 13 * density, line)
        val cy = 13 * density
        val ix = pad
        val ink = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = p.color }
        if (p.person) {
            // a person standing: the head, then the body
            c.drawCircle(ix + icon / 2, cy - icon * 0.30f, icon * 0.17f, ink)
            c.drawRoundRect(RectF(ix + icon * 0.28f, cy - icon * 0.08f, ix + icon * 0.72f, cy + icon * 0.48f), icon * 0.2f, icon * 0.2f, ink)
        } else {
            c.drawCircle(ix + icon / 2, cy, icon / 2, ink)
        }
        val tx = ix + icon + 5 * density
        c.drawText(p.text, tx, cy - (text.descent() + text.ascent()) / 2, text)
        if (p.sub.isNotEmpty()) c.drawText(p.sub, tx, 30 * density, small)
        return b
    }
}

/** Fits a trip's places on a map (for later screens). */
fun boundsOf(points: List<GeoPoint>): LatLngBounds? =
    if (points.size < 2) null else LatLngBounds.Builder().apply { points.forEach { include(LatLng(it.lat, it.lon)) } }.build()
