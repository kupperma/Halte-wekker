package nl.haltewekker.ride

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat

/** The backup alarm by time: an exact alarm may start the ride's service again, and it rings if still asleep. */
class AlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != RideService.ACTION_BACKUP) return
        RideStore.load(context)
        if (RideStore.state.value == null) return
        try {
            ContextCompat.startForegroundService(context, Intent(context, RideService::class.java).setAction(RideService.ACTION_BACKUP))
        } catch (_: Exception) {}
    }
}
