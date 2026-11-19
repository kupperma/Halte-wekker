package nl.haltewekker.ui.screens

import android.Manifest
import android.app.AlarmManager
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LifecycleResumeEffect
import nl.haltewekker.ui.Card
import nl.haltewekker.ui.QuietButton
import nl.haltewekker.ui.theme.DS

/** What the ride needs from Android, and where to allow it. */
object Perms {
    fun has(c: Context, p: String) = ContextCompat.checkSelfPermission(c, p) == PackageManager.PERMISSION_GRANTED
    fun location(c: Context) = has(c, Manifest.permission.ACCESS_FINE_LOCATION)
    fun background(c: Context) = Build.VERSION.SDK_INT < 29 || has(c, Manifest.permission.ACCESS_BACKGROUND_LOCATION)
    fun notifications(c: Context) = if (Build.VERSION.SDK_INT >= 33) has(c, Manifest.permission.POST_NOTIFICATIONS)
        else c.getSystemService(NotificationManager::class.java).areNotificationsEnabled()
    fun exactAlarms(c: Context) = Build.VERSION.SDK_INT < 31 || c.getSystemService(AlarmManager::class.java).canScheduleExactAlarms()
    fun fullScreen(c: Context) = Build.VERSION.SDK_INT < 34 || c.getSystemService(NotificationManager::class.java).canUseFullScreenIntent()
    fun battery(c: Context) = c.getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(c.packageName)

    /** Everything a ride's alarm needs (the background location and the battery are extras). */
    fun rideReady(c: Context) = location(c) && notifications(c) && fullScreen(c)

    fun appSettings(c: Context) = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${c.packageName}"))
}

@Composable
fun PermissionsCard(showExtras: Boolean = true) {
    val c = LocalContext.current
    var tick by remember { mutableIntStateOf(0) }
    LifecycleResumeEffect(Unit) { tick++; onPauseOrDispose {} }
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { tick++ }
    val askOne = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { tick++ }
    @Suppress("UNUSED_EXPRESSION") tick
    Card {
        Text("What the ride needs", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold, color = DS.t.text)
        PermRow(
            "Location", "To know how far your stop is. Only during a ride, and on the map while the app is open.", Perms.location(c),
        ) { ask.launch(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)) }
        if (Build.VERSION.SDK_INT >= 33) PermRow(
            "Notifications", "The ride's progress, the alarm and \"You're at your stop\".", Perms.notifications(c),
        ) { askOne.launch(Manifest.permission.POST_NOTIFICATIONS) }
        if (Build.VERSION.SDK_INT >= 34) PermRow(
            "Alarm over the lock screen", "Lets the wake-up alarm open full screen, like an alarm clock.", Perms.fullScreen(c),
        ) { c.startActivity(Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT, Uri.parse("package:${c.packageName}"))) }
        if (Build.VERSION.SDK_INT in 31..32) PermRow(
            "Exact alarms", "The backup alarm by time rings on the minute, also when GPS drops out.", Perms.exactAlarms(c),
        ) { c.startActivity(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:${c.packageName}"))) }
        if (showExtras) {
            if (Build.VERSION.SDK_INT >= 29) PermRow(
                "Location all the time (optional)",
                "Not needed for rides you start in the app. With it, leaving a home stop or school on a bus starts the trip by itself. Choose \"Allow all the time\" in the next screen.",
                Perms.background(c),
            ) {
                if (Perms.location(c)) askOne.launch(Manifest.permission.ACCESS_BACKGROUND_LOCATION)
                else ask.launch(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION))
            }
            PermRow(
                "No battery limits (recommended)",
                "Some phones stop apps in the background to save battery, and with it the alarm. Allow Haltewekker to run.",
                Perms.battery(c),
            ) { c.startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)) }
        }
    }
}

@Composable
private fun PermRow(title: String, why: String, ok: Boolean, onAllow: () -> Unit) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(if (ok) Icons.Filled.CheckCircle else Icons.Outlined.Info, null, tint = if (ok) DS.t.accentText else DS.t.secondary)
        Column(Modifier.weight(1f)) {
            Text(title, fontWeight = FontWeight.SemiBold, color = DS.t.text)
            Text(why, style = MaterialTheme.typography.bodySmall, color = DS.t.secondary)
        }
        if (!ok) QuietButton("Allow", onClick = onAllow)
    }
}
