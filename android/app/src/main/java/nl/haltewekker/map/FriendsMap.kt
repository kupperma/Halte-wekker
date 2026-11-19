package nl.haltewekker.map

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Shader
import android.graphics.Typeface
import android.view.Gravity
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
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.friends.FriendNames
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

// Friends (A5, iOS 0.31 `FriendsMapViews.swift`): the map behind Friends and a friend's page: friends' faces where
// they are, ringed in their vehicle's colour, their routes drawn, and where one friend got on and gets off. The camera
// is always the region `MapFrame.fit` works out (never the map's own default), set again whenever the points, the
// map's size or the sheet's share of it change.

/** A face on the map: a travelling friend (ringed in their vehicle's colour) or one on campus (the accent). ARGB colours. */
data class FriendMapPin(val id: String, val name: String, val point: GeoPoint, val ring: Int, val label: String, val stale: Boolean,
                        val route: List<GeoPoint>)

/** Where a friend got on ("from") or gets off ("to"). */
data class MapStop(val id: String, val name: String, val point: GeoPoint)

@Composable
fun FriendsLiveMap(
    modifier: Modifier,
    pins: List<FriendMapPin>,
    /** What to frame (the pins, and for one friend where they got on and get off); empty: `fallback`. */
    frame: List<GeoPoint>,
    pictures: Map<String, ByteArray>,
    stops: List<MapStop> = emptyList(),
    /** The share of the map's height a sheet covers at the bottom. */
    cover: Double = 0.0,
    /** Framed when nobody is on the map (your Home and School). */
    fallback: List<GeoPoint> = emptyList(),
    /** The colour of the "to" marker (the accent). */
    accent: Int = 0xFF0E7A55.toInt(),
    dark: Boolean = false,
    onTap: ((String) -> Unit)? = null,
) {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val tap by rememberUpdatedState(onTap)
    var map by remember { mutableStateOf<MapLibreMap?>(null) }
    var style by remember { mutableStateOf<Style?>(null) }
    var size by remember { mutableStateOf(IntSize.Zero) }
    val density = context.resources.displayMetrics.density
    val view = remember {
        MapLibre.getInstance(context)
        MapView(context).apply {
            onCreate(null)
            getMapAsync { m ->
                m.uiSettings.isRotateGesturesEnabled = false
                m.uiSettings.isTiltGesturesEnabled = false
                m.uiSettings.isLogoEnabled = false
                m.uiSettings.isAttributionEnabled = true
                m.uiSettings.isCompassEnabled = false
                // (the sheet covers the bottom: the map's credits go under the top buttons)
                m.uiSettings.attributionGravity = Gravity.TOP or Gravity.END
                m.uiSettings.setAttributionMargins(0, (64 * density).toInt(), (16 * density).toInt(), 0)
                m.cameraPosition = CameraPosition.Builder().target(LatLng(52.2, 5.3)).zoom(7.0).build()
                m.setStyle(Style.Builder().fromUri(MapStyle.STYLE_URL)) { s ->
                    s.addSource(GeoJsonSource("f-routes"))
                    s.addSource(GeoJsonSource("f-stops"))
                    s.addSource(GeoJsonSource("f-faces"))
                    s.addLayer(LineLayer("f-route-lines", "f-routes").withProperties(
                        PropertyFactory.lineColor(Expression.get("color")),
                        PropertyFactory.lineOpacity(Expression.get("opacity")),
                        PropertyFactory.lineWidth(5f),
                        PropertyFactory.lineCap(Property.LINE_CAP_ROUND),
                        PropertyFactory.lineJoin(Property.LINE_JOIN_ROUND),
                    ))
                    s.addLayer(CircleLayer("f-stop-dots", "f-stops").withProperties(
                        PropertyFactory.circleColor(Expression.get("color")),
                        PropertyFactory.circleRadius(7f),
                        PropertyFactory.circleStrokeColor(android.graphics.Color.WHITE),
                        PropertyFactory.circleStrokeWidth(2.5f),
                    ))
                    s.addLayer(SymbolLayer("f-stop-names", "f-stops").withProperties(
                        PropertyFactory.textField(Expression.get("name")),
                        PropertyFactory.textFont(arrayOf("Noto Sans Bold")),
                        PropertyFactory.textSize(12f),
                        PropertyFactory.textOffset(arrayOf(0f, 1.3f)),
                        PropertyFactory.textAnchor(Property.TEXT_ANCHOR_TOP),
                        PropertyFactory.textColor(if (dark) android.graphics.Color.WHITE else 0xFF14171A.toInt()),
                        PropertyFactory.textHaloColor(if (dark) 0xFF111417.toInt() else android.graphics.Color.WHITE),
                        PropertyFactory.textHaloWidth(1.5f),
                    ))
                    s.addLayer(SymbolLayer("f-face-icons", "f-faces").withProperties(
                        PropertyFactory.iconImage(Expression.get("icon")),
                        PropertyFactory.iconAllowOverlap(true),
                        PropertyFactory.iconIgnorePlacement(true),
                        PropertyFactory.iconOpacity(Expression.get("opacity")),
                    ))
                    style = s
                }
                m.addOnMapClickListener { ll ->
                    val f = tap ?: return@addOnMapClickListener false
                    val hit = m.queryRenderedFeatures(m.projection.toScreenLocation(ll), "f-face-icons").firstOrNull()
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
        // (a new observer is brought up to the lifecycle's state: start and resume come by themselves)
        lifecycle.addObserver(obs)
        onDispose { lifecycle.removeObserver(obs); view.onStop(); view.onDestroy() }
    }
    // (the fix iOS 0.31 needed: a region worked out from the points, every time they, the size or the sheet change)
    val key = frame.joinToString(";") { "%.4f,%.4f".format(java.util.Locale.ROOT, it.lat, it.lon) } + "|" + (cover * 100).toInt() + "|" +
        fallback.joinToString(";") { "%.3f,%.3f".format(java.util.Locale.ROOT, it.lat, it.lon) }
    LaunchedEffect(map, key, size) {
        val m = map ?: return@LaunchedEffect
        if (size.width <= 1 || size.height <= 1) return@LaunchedEffect
        val pts = frame.filter(MapFrame::valid).ifEmpty { fallback.filter(MapFrame::valid) }
        val r = MapFrame.fit(pts, size.height.toDouble() / size.width, cover) ?: return@LaunchedEffect
        val b = LatLngBounds.from(minOf(85.0, r.north), minOf(180.0, r.east), maxOf(-85.0, r.south), maxOf(-180.0, r.west))
        try { m.easeCamera(CameraUpdateFactory.newLatLngBounds(b, 0), 350) } catch (_: Exception) {}
    }
    LaunchedEffect(style, pins, stops, pictures) {
        val s = style ?: return@LaunchedEffect
        val routes = pins.filter { it.route.size >= 2 }.map { p ->
            Feature.fromGeometry(LineString.fromLngLats(p.route.map { Point.fromLngLat(it.lon, it.lat) })).apply {
                addStringProperty("color", hex(p.ring))
                addNumberProperty("opacity", if (p.stale) 0.5 else 0.9)
            }
        }
        (s.getSource("f-routes") as? GeoJsonSource)?.setGeoJson(FeatureCollection.fromFeatures(routes))
        val dots = stops.map { st ->
            Feature.fromGeometry(Point.fromLngLat(st.point.lon, st.point.lat)).apply {
                addStringProperty("color", if (st.id == "to") hex(accent) else "#8A929A")
                addStringProperty("name", st.name)
            }
        }
        (s.getSource("f-stops") as? GeoJsonSource)?.setGeoJson(FeatureCollection.fromFeatures(dots))
        val px = (48 * density).toInt()
        val faces = pins.map { p ->
            val icon = "face-${p.id}"
            s.addImage(icon, FaceBitmap.make(p.name, pictures[p.id], p.ring, px, density, dark))
            Feature.fromGeometry(Point.fromLngLat(p.point.lon, p.point.lat)).apply {
                addStringProperty("icon", icon)
                addStringProperty("id", p.id)
                addNumberProperty("opacity", if (p.stale) 0.6 else 1.0)
            }
        }
        (s.getSource("f-faces") as? GeoJsonSource)?.setGeoJson(FeatureCollection.fromFeatures(faces))
    }
    val spoken = if (pins.isEmpty()) "Map" else "Map of friends: " + pins.joinToString("; ") { it.label }
    AndroidView(factory = { view }, modifier = modifier.onSizeChanged { size = it }.semantics { contentDescription = spoken })
}

private fun hex(c: Int) = String.format("#%06X", 0xFFFFFF and c)

/** A face for the map: the picture (or the initials) in a white circle with a ring in the vehicle's colour. */
object FaceBitmap {
    fun make(name: String, jpeg: ByteArray?, ring: Int, px: Int, density: Float, dark: Boolean): Bitmap {
        val b = Bitmap.createBitmap(px, px, Bitmap.Config.ARGB_8888)
        val c = Canvas(b)
        val r = px / 2f
        val ringW = 3 * density
        val gap = 2.5f * density
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        // the ring, the white (or dark) surface, then the face
        paint.color = ring
        c.drawCircle(r, r, r, paint)
        paint.color = if (dark) 0xFF1C1F23.toInt() else android.graphics.Color.WHITE
        c.drawCircle(r, r, r - ringW, paint)
        val inner = r - ringW - gap
        val pic = jpeg?.let { try { BitmapFactory.decodeByteArray(it, 0, it.size) } catch (_: Exception) { null } }
        if (pic != null) {
            val shader = BitmapShader(pic, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
            val scale = (inner * 2) / minOf(pic.width, pic.height)
            shader.setLocalMatrix(Matrix().apply {
                postScale(scale, scale)
                postTranslate(r - pic.width * scale / 2, r - pic.height * scale / 2)
            })
            c.drawCircle(r, r, inner, Paint(Paint.ANTI_ALIAS_FLAG).apply { this.shader = shader })
        } else {
            paint.color = if (dark) 0xFF163A2C.toInt() else 0xFFE3F3EC.toInt()
            c.drawCircle(r, r, inner, paint)
            val t = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = if (dark) 0xFF8FE0BB.toInt() else 0xFF0A5C40.toInt()
                textSize = inner * 0.9f
                typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
                textAlign = Paint.Align.CENTER
            }
            c.drawText(FriendNames.initials(name), r, r - (t.descent() + t.ascent()) / 2, t)
        }
        return b
    }
}
