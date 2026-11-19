package nl.haltewekker.ride

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import nl.haltewekker.R
import nl.haltewekker.ui.MainActivity
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * The ride's notifications. The ongoing one is the Live Activity's equivalent (the line, what's left, the arrival);
 * the alarm one has a full-screen intent, so the alarm screen comes up over the lock screen.
 */
object Notifications {
    const val RIDE = "ride"
    const val ALARM = "alarm"
    const val ARRIVAL = "arrival"
    const val RIDE_ID = 1
    const val ALARM_ID = 2
    const val ARRIVAL_ID = 3

    fun channels(context: Context) {
        val nm = context.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(RIDE, "Ride in progress", NotificationManager.IMPORTANCE_LOW).apply {
            description = "What's left of your ride, and when you get there."
            setShowBadge(false)
        })
        nm.createNotificationChannel(NotificationChannel(ALARM, "Wake-up alarm", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "Rings before your stop."
            setSound(null, null)            // the app plays the alarm itself (headphones or out loud)
            enableVibration(false)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        })
        nm.createNotificationChannel(NotificationChannel(ARRIVAL, "At your stop", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "You're at your stop: get off here."
            setSound(null, null)
        })
    }

    private val hm = SimpleDateFormat("HH:mm", Locale.ROOT)
    fun time(t: Double): String = hm.format(Date((t * 1000).toLong()))

    private fun openApp(context: Context): PendingIntent = PendingIntent.getActivity(context, 0,
        Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)

    fun action(context: Context, action: String, code: Int): PendingIntent = PendingIntent.getService(context, code,
        Intent(context, RideService::class.java).setAction(action), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)

    /** "Bus 306 to Breda, Nassausingel · 4.2 km to go · there 16:47". */
    fun ride(context: Context, s: RideState?): Notification {
        val b = NotificationCompat.Builder(context, RIDE)
            .setSmallIcon(R.drawable.ic_stat_ride)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_NAVIGATION)
            .setContentIntent(openApp(context))
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
        val leg = s?.leg
        if (s == null || leg == null) return b.setContentTitle("Haltewekker").setContentText("Starting your ride…").build()
        val what = s.vehicleLine?.let { if (leg.isTrain) it else "Bus $it" } ?: if (leg.isTrain) leg.line else "Bus ${leg.line}"
        val title = when (s.phase) {
            Phase.ALARM -> "Wake up: ${leg.toStop}"
            Phase.AWAKE -> "Get ready: ${leg.toStop}"
            Phase.FINISHED -> "You're there"
            else -> "$what to ${leg.toStop}"
        }
        val parts = ArrayList<String>()
        s.distance?.let { parts.add("${WakeRules.distanceText(it)} to go") }
        s.legArrival?.let { parts.add("there ${time(it)}") }
        if (s.phase == Phase.SLEEPING) parts.add("rings ${WakeRules.distanceText(s.wakeMetres)} before")
        if (s.trip.rides.size > 1) parts.add("leg ${s.index + 1} of ${s.trip.rides.size}")
        b.setContentTitle(title).setContentText(parts.joinToString(" · "))
        val total = (leg.arrival - leg.departure).coerceAtLeast(60.0)
        val done = ((nl.haltewekker.core.Iso.now() - leg.departure) / total).coerceIn(0.0, 1.0)
        b.setProgress(100, (done * 100).toInt(), false)
        s.legArrival?.let { b.setWhen((it * 1000).toLong()).setShowWhen(true).setUsesChronometer(true).setChronometerCountDown(true) }
        if (s.phase == Phase.ALARM) b.addAction(0, "Stop alarm", action(context, RideService.ACTION_STOP_ALARM, 10))
        b.addAction(0, "End trip", action(context, RideService.ACTION_END, 11))
        return b.build()
    }

    fun alarm(context: Context, s: RideState): Notification {
        val leg = s.leg
        val full = PendingIntent.getActivity(context, 1, Intent(context, AlarmActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_USER_ACTION),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        return NotificationCompat.Builder(context, ALARM)
            .setSmallIcon(R.drawable.ic_stat_ride)
            .setContentTitle("Wake up")
            .setContentText("${leg?.toStop ?: "Your stop"} in about ${WakeRules.distanceText(s.distance ?: s.wakeMetres)}.")
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setFullScreenIntent(full, true)
            .setContentIntent(full)
            .setOngoing(true)
            .addAction(0, "Stop alarm", action(context, RideService.ACTION_STOP_ALARM, 12))
            .build()
    }

    fun arrived(context: Context, place: String, then: String?) {
        val n = NotificationCompat.Builder(context, ARRIVAL)
            .setSmallIcon(R.drawable.ic_stat_ride)
            .setContentTitle("You're at $place")
            .setContentText(then ?: "Get off here.")
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(openApp(context))
            .setAutoCancel(true)
            .build()
        post(context, ARRIVAL_ID, n)
    }

    fun post(context: Context, id: Int, n: Notification) {
        val nm = context.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 33 && !nm.areNotificationsEnabled()) return
        try { nm.notify(id, n) } catch (_: SecurityException) {}
    }

    fun cancel(context: Context, id: Int) = context.getSystemService(NotificationManager::class.java).cancel(id)
}
