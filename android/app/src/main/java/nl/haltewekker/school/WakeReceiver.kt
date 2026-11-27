package nl.haltewekker.school

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat
import nl.haltewekker.core.Iso

/** A school alarm went off: ring (`WakeService`), unless the day was turned off or its alarm moved meanwhile. */
class WakeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != WakeAlarm.ACTION_FIRE) return
        val day = intent.getStringExtra(WakeAlarm.EXTRA_DAY) ?: return
        SchoolAlarm.load(context)
        if (day != WakeAlarm.TEST_DAY) {
            if (!SchoolAlarm.config.value.on || SchoolAlarm.isSkipped(day)) return
            val p = SchoolAlarm.week.value.firstOrNull { it.day == day } ?: return
            val at = p.alarm ?: return
            val now = Iso.now()
            // moved and set again (that one rings), or long past (the phone was off): not this one
            if (now < at - 10 * 60 || now > at + 30 * 60) return
            // (iOS 0.42.6) already on the way (a trip to school, at school, or left home on a ride): not this morning
            if (SchoolAlarm.checkOnTheWay(context, now, ringing = true)) return
        }
        val i = Intent(context, WakeService::class.java).setAction(WakeService.ACTION_RING).putExtras(intent)
        try { ContextCompat.startForegroundService(context, i) } catch (_: Exception) {
            // not allowed to start it (a phone that blocks the app): at least the notification
            WakeService.fallback(context, day, intent.getStringExtra(WakeAlarm.EXTRA_TITLE), intent.getStringExtra(WakeAlarm.EXTRA_BODY))
        }
    }
}
