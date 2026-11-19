package nl.haltewekker.ui

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Looper
import androidx.core.content.ContextCompat
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import nl.haltewekker.core.GeoPoint

/**
 * Where you are, for the screens: only while a screen collects it (it stops in the background), from the phone's own
 * location service (GPS and network; no Google Play services needed).
 */
object Locator {
    fun granted(context: Context): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED

    fun last(context: Context): GeoPoint? = lastFix(context)?.let { GeoPoint(it.latitude, it.longitude) }

    /** The phone's newest known fix (no new location asked). */
    @SuppressLint("MissingPermission")
    fun lastFix(context: Context): Location? {
        if (!granted(context)) return null
        val lm = context.getSystemService(LocationManager::class.java)
        return listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER, LocationManager.PASSIVE_PROVIDER)
            .mapNotNull { try { lm.getLastKnownLocation(it) } catch (_: Exception) { null } }
            .maxByOrNull { it.time }
    }

    /** Fixes every `ms` (at least 25 m apart), GPS and network. */
    @SuppressLint("MissingPermission")
    fun updates(context: Context, ms: Long = 5000, metres: Float = 25f): Flow<Location> = callbackFlow {
        val lm = context.getSystemService(LocationManager::class.java)
        val l = LocationListener { trySend(it) }
        if (granted(context)) {
            for (p in listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)) {
                try { if (lm.isProviderEnabled(p)) lm.requestLocationUpdates(p, ms, metres, l, Looper.getMainLooper()) } catch (_: Exception) {}
            }
        }
        awaitClose { lm.removeUpdates(l) }
    }
}
