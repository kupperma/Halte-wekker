package nl.haltewekker.ride

import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * (A7, iOS 0.37.1 / 0.42.1) Stop alarm from a notification (the lock screen, a Wear OS watch): a broadcast, not an
 * activity, so the keyguard is never asked and the app doesn't open. The same as Stop in the app (`AlarmStop.plan`):
 * the trip's alarm goes to the ride's service; with no ride running it only takes the alarm's notifications away.
 * The school wake-up's goes to its own service.
 */
class StopReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION = "nl.haltewekker.ride.STOP_FROM_NOTICE"
        const val EXTRA_ID = "id"
        const val EXTRA_ACTION = "action"

        /** The Stop alarm action of the notification `id` ("alarm", "alarm-again", "backup", "wake-<day>-0"…). */
        fun intent(c: Context, id: String, code: Int, action: AlarmStop.Action = AlarmStop.Action.STOP): PendingIntent =
            PendingIntent.getBroadcast(c, code, Intent(c, StopReceiver::class.java).setAction(ACTION)
                .putExtra(EXTRA_ID, id).putExtra(EXTRA_ACTION, action.name),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION) return
        val id = intent.getStringExtra(EXTRA_ID) ?: return
        val action = try { AlarmStop.Action.valueOf(intent.getStringExtra(EXTRA_ACTION) ?: "STOP") } catch (_: Exception) { AlarmStop.Action.STOP }
        val plan = AlarmStop.plan(id, action)
        if (plan.stopWake || plan.wakeRepeats.isNotEmpty()) {
            if (plan.stopWake) nl.haltewekker.school.WakeService.stop(context)
            return
        }
        if (!plan.stopTrip) return
        RideStore.load(context)
        // the sound and buzz at once, in this process (the ride's service does the rest: the leg goes on as after Stop)
        AlarmPlayer.stop(context)
        Notifications.cancel(context, Notifications.ALARM_ID)
        Notifications.cancelTag(context, WristNotice.AGAIN_ID, Notifications.ALARM_ID)
        if (RideStore.state.value != null) RideService.send(context, RideService.ACTION_STOP_ALARM)
        else {
            // no trip engine: only the alarm's notifications off the lock screen
            val nm = context.getSystemService(NotificationManager::class.java)
            for (t in AlarmStop.tripDelivered) try { nm.cancel(t, Notifications.ALARM_ID) } catch (_: Exception) {}
        }
    }
}
