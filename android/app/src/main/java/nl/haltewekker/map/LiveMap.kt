package nl.haltewekker.map

import android.graphics.Color as AColor
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import nl.haltewekker.core.GeoPoint
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
import org.maplibre.android.style.layers.PropertyFactory
import org.maplibre.android.style.layers.SymbolLayer
import org.maplibre.android.style.sources.GeoJsonSource
import org.maplibre.geojson.Feature
import org.maplibre.geojson.FeatureCollection
import org.maplibre.geojson.Point

/** A dot on the map: a vehicle (its line on it, in its kind's colour), a stop, or you. */
data class MapDot(val id: String, val p: GeoPoint, val color: Int, val label: String = "", val kind: String = "vehicle")

/**
 * The home map: OpenStreetMap-based vector tiles from OpenFreeMap (no API key, no Google services) in MapLibre, with
 * your position, nearby stops and the live buses and trains as data-driven circles.
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
    onBounds: (GeoPoint, GeoPoint, Double) -> Unit,
) {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var map by remember { mutableStateOf<MapLibreMap?>(null) }
    var style by remember { mutableStateOf<Style?>(null) }
    var centred by remember { mutableStateOf(false) }
    val view = remember {
        MapLibre.getInstance(context)
        MapView(context).apply {
            onCreate(null)
            getMapAsync { m ->
                m.uiSettings.isRotateGesturesEnabled = false
                m.uiSettings.isTiltGesturesEnabled = false
                m.uiSettings.isAttributionEnabled = true
                m.uiSettings.isLogoEnabled = false
                m.cameraPosition = CameraPosition.Builder().target(LatLng(52.09, 5.12)).zoom(12.0).build()
                m.setStyle(Style.Builder().fromUri(MapStyle.STYLE_URL)) { s ->
                    s.addSource(GeoJsonSource("dots"))
                    s.addLayer(CircleLayer("dot-circles", "dots").withProperties(
                        PropertyFactory.circleColor(Expression.get("color")),
                        PropertyFactory.circleRadius(Expression.get("radius")),
                        PropertyFactory.circleStrokeColor(AColor.WHITE),
                        PropertyFactory.circleStrokeWidth(2f),
                    ))
                    s.addLayer(SymbolLayer("dot-labels", "dots").withProperties(
                        PropertyFactory.textField(Expression.get("label")),
                        PropertyFactory.textFont(arrayOf("Noto Sans Bold")),
                        PropertyFactory.textSize(10f),
                        PropertyFactory.textColor(AColor.WHITE),
                        PropertyFactory.textAllowOverlap(true),
                        PropertyFactory.textIgnorePlacement(true),
                    ))
                    style = s
                }
                m.addOnCameraIdleListener {
                    val b = m.projection.visibleRegion.latLngBounds
                    onBounds(GeoPoint(b.latitudeSouth, b.longitudeWest), GeoPoint(b.latitudeNorth, b.longitudeEast), m.cameraPosition.zoom)
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
    LaunchedEffect(style, dots, me) {
        val s = style ?: return@LaunchedEffect
        val features = dots.map { d ->
            Feature.fromGeometry(Point.fromLngLat(d.p.lon, d.p.lat)).apply {
                addStringProperty("color", String.format("#%06X", 0xFFFFFF and d.color))
                addStringProperty("label", d.label)
                addNumberProperty("radius", when (d.kind) { "stop" -> 4; "me" -> 8; else -> if (d.label.length > 3) 13 else 11 })
            }
        } + listOfNotNull(me?.let { p ->
            Feature.fromGeometry(Point.fromLngLat(p.lon, p.lat)).apply {
                addStringProperty("color", "#2F7CF6"); addStringProperty("label", ""); addNumberProperty("radius", 8)
            }
        })
        (s.getSource("dots") as? GeoJsonSource)?.setGeoJson(FeatureCollection.fromFeatures(features))
    }
    AndroidView(factory = { view }, modifier = modifier)
}

/** Fits a trip's places on a map (for later screens). */
fun boundsOf(points: List<GeoPoint>): LatLngBounds? =
    if (points.size < 2) null else LatLngBounds.Builder().apply { points.forEach { include(LatLng(it.lat, it.lon)) } }.build()
