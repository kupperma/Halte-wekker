package nl.haltewekker.school

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import nl.haltewekker.R
import nl.haltewekker.core.Iso
import nl.haltewekker.ride.AlarmPlayer
import nl.haltewekker.ride.Notifications
import nl.haltewekker.ui.Fmt
import nl.haltewekker.ui.MainActivity

/**
 * The school alarm ringing (iOS AlarmKit's alert): a foreground service so the sound goes on with the screen off,
 * out loud on the alarm stream (it rings on silent), with the full-screen alarm screen (`WakeActivity`, Stop / Open).
 * Open stops it too (iOS 0.24.6 had an Open that left it ringing), and so does opening the app. Not stopped after 10
 * minutes: it goes quiet and says when to leave.
 */
class WakeService : Service() {
    data class Ringing(val day: String, val title: String, val body: String, val leave: Double?, val since: Double)

    companion object {
        const val ACTION_RING = "nl.haltewekker.school.RING"
        const val ACTION_STOP = "nl.haltewekker.school.STOP"
        const val RING_FOR_MS = 10 * 60_000L

        private val _ringing = MutableStateFlow<Ringing?>(null)
        val ringing: StateFlow<Ringing?> = _ringing

        /** Stop it, from anywhere (the alarm screen, the app opening). */
        fun stop(c: Context) {
            if (_ringing.value == null) return
            try { c.startService(Intent(c, WakeService::class.java).setAction(ACTION_STOP)) } catch (_: Exception) {
                AlarmPlayer.stop(c); _ringing.value = null; Notifications.cancel(c, Notifications.WAKE_ID)
            }
        }

        fun stopIntent(c: Context): PendingIntent = PendingIntent.getService(c, 41, Intent(c, WakeService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)

        /** Open: the app on Your day, which stops the alarm as it opens. */
        fun openIntent(c: Context): PendingIntent = PendingIntent.getActivity(c, 42,
            Intent(c, MainActivity::class.java).putExtra(MainActivity.EXTRA_SCREEN, MainActivity.SCREEN_DAY).putExtra(MainActivity.EXTRA_STOP_WAKE, true)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)

        private fun notification(c: Context, r: Ringing): Notification {
            val full = PendingIntent.getActivity(c, 43, Intent(c, WakeActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_USER_ACTION),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            return NotificationCompat.Builder(c, Notifications.WAKE)
                .setSmallIcon(R.drawable.ic_stat_ride)
                .setContentTitle(nl.haltewekker.ride.WristNotice.wakeTitle(r.title, 0))
                .setContentText(r.body)
                .setCategory(NotificationCompat.CATEGORY_ALARM)
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setPublicVersion(NotificationCompat.Builder(c, Notifications.WAKE).setSmallIcon(R.drawable.ic_stat_ride)
                    .setContentTitle(nl.haltewekker.ride.WristNotice.wakeTitle(r.title, 0)).build())
                .setGroup(nl.haltewekker.ride.WristNotice.wakeThread(r.day))
                .setFullScreenIntent(full, true)
                .setContentIntent(full)
                .setOngoing(true)
                // (A7, iOS 0.37.1/0.42.1) Stop alarm without unlocking: a broadcast, also from a watch
                .addAction(0, nl.haltewekker.ride.WristNotice.STOP_TITLE, nl.haltewekker.ride.StopReceiver.intent(c, "wake-${r.day}-0", 44))
                .addAction(0, "Open", openIntent(c))
                .build()
        }

        /** Couldn't start the service: the notification alone (its full-screen intent still brings up the alarm screen). */
        fun fallback(c: Context, day: String, title: String?, body: String?) {
            Notifications.post(c, Notifications.WAKE_ID, notification(c, Ringing(day, title ?: "Time to get up", body ?: "", null, Iso.now())))
        }
    }

    private val main = Handler(Looper.getMainLooper())
    private val timeout = Runnable { missed() }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() { super.onCreate(); Notifications.channels(this); AlarmPlayer.warmUp(this) }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_RING -> {
                val r = Ringing(
                    day = intent.getStringExtra(WakeAlarm.EXTRA_DAY) ?: "",
                    title = intent.getStringExtra(WakeAlarm.EXTRA_TITLE) ?: "Time to get up",
                    body = intent.getStringExtra(WakeAlarm.EXTRA_BODY) ?: "",
                    leave = intent.getDoubleExtra(WakeAlarm.EXTRA_LEAVE, -1.0).takeIf { it > 0 },
                    since = Iso.now())
                if (!foreground(r)) { fallback(this, r.day, r.title, r.body); stopSelf(); return START_NOT_STICKY }
                _ringing.value = r
                SchoolAlarm.rang(this, r.day)
                AlarmPlayer.ring(this, null, quiet = false, outLoud = true)
                main.removeCallbacks(timeout); main.postDelayed(timeout, RING_FOR_MS)
            }
            else -> { finish(); return START_NOT_STICKY }
        }
        return START_NOT_STICKY
    }

    private fun foreground(r: Ringing): Boolean {
        val n = notification(this, r)
        return try {
            when {
                Build.VERSION.SDK_INT >= 34 -> try {
                    startForeground(Notifications.WAKE_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SYSTEM_EXEMPTED)
                } catch (_: Exception) {
                    startForeground(Notifications.WAKE_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
                }
                Build.VERSION.SDK_INT >= 29 -> startForeground(Notifications.WAKE_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
                else -> startForeground(Notifications.WAKE_ID, n)
            }
            true
        } catch (_: Exception) { false }
    }

    /** Rang 10 minutes without a stop: quiet now, and when to leave. */
    private fun missed() {
        val r = _ringing.value
        finish()
        if (r != null && r.day != WakeAlarm.TEST_DAY) {
            Notifications.news(this, "wake-missed-${r.day}", "Did you get up?",
                r.leave?.let { "Leave by ${Fmt.time(it)}. ${r.body}" } ?: r.body, MainActivity.SCREEN_DAY)
        }
    }

    private fun finish() {
        main.removeCallbacks(timeout)
        AlarmPlayer.stop(this)
        _ringing.value = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        Notifications.cancel(this, Notifications.WAKE_ID)
        stopSelf()
    }

    override fun onDestroy() {
        main.removeCallbacks(timeout)
        if (_ringing.value != null) { AlarmPlayer.stop(this); _ringing.value = null }
        super.onDestroy()
    }
}
