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
    const val SCHOOL = "school"
    const val WAKE = "wake"
    const val NEWS = "news"
    const val RIDE_ID = 1
    const val ALARM_ID = 2
    const val ARRIVAL_ID = 3
    const val WAKE_ID = 4
    const val NEWS_ID = 5

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
        nm.createNotificationChannel(NotificationChannel(WAKE, "School alarm", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "Wakes you before you have to leave for your first class."
            setSound(null, null)            // the app plays the alarm itself
            enableVibration(false)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            setBypassDnd(true)
        })
        nm.createNotificationChannel(NotificationChannel(SCHOOL, "School alarm news", NotificationManager.IMPORTANCE_DEFAULT).apply {
            description = "When the school alarm is set or moves with the buses."
        })
        nm.createNotificationChannel(NotificationChannel(NEWS, "Trips by themselves", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "A trip started by itself when you left a home stop or school; looking for your bus or train."
        })
    }

    private val hm = SimpleDateFormat("HH:mm", Locale.ROOT)
    fun time(t: Double): String = hm.format(Date((t * 1000).toLong()))

    fun openApp(context: Context, screen: String? = null): PendingIntent = PendingIntent.getActivity(context, if (screen == null) 0 else 30 + screen.length,
        Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            .apply { screen?.let { putExtra(MainActivity.EXTRA_SCREEN, it) } },
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
        if (s.reckoning) parts.add("no GPS here: following its route")
        if (s.phase == Phase.SLEEPING) {
            val w = (context.applicationContext as nl.haltewekker.App).store.settings.value.wake
            parts.add("rings ${WakeRule.says(w, leg.isTrain, s.wakeMetres).removeSuffix(" before your stop").replace(" before your stop", "")} before")
        }
        if (s.trip.rides.size > 1) parts.add("leg ${s.index + 1} of ${s.trip.rides.size}")
        b.setContentTitle(title).setContentText(parts.joinToString(" · "))
        val total = (leg.arrival - leg.departure).coerceAtLeast(60.0)
        val done = ((nl.haltewekker.core.Iso.now() - leg.departure) / total).coerceIn(0.0, 1.0)
        b.setProgress(100, (done * 100).toInt(), false)
        s.legArrival?.let { b.setWhen((it * 1000).toLong()).setShowWhen(true).setUsesChronometer(true).setChronometerCountDown(true) }
        // (A7) while it rings: Stop alarm, without unlocking (a broadcast, as the alarm's own notification)
        if (s.phase == Phase.ALARM) b.addAction(0, WristNotice.STOP_TITLE, StopReceiver.intent(context, WristNotice.ALARM_ID, 10))
        b.setGroup(group(s))
        b.addAction(0, "End trip", action(context, RideService.ACTION_END, 11))
        return b.build()
    }

    /** Auto-start's look, after you left a home stop or School: GPS on for a few minutes. */
    fun looking(context: Context): Notification = NotificationCompat.Builder(context, RIDE)
        .setSmallIcon(R.drawable.ic_stat_ride)
        .setOngoing(true)
        .setContentTitle("Looking for your bus or train")
        .setContentText("You left a stop: if you're on a bus or train, the trip starts by itself.")
        .setContentIntent(openApp(context))
        .addAction(0, "Stop looking", action(context, RideService.ACTION_END, 13))
        .build()

    /** The trip's group (iOS `WristNotice.thread`): one per trip in the shade and on a watch. */
    fun group(s: RideState?) = WristNotice.thread(s?.startedAt)

    /**
     * The ringing alarm (iOS 0.37.1 `WristNotice`): short, the stop first ("Get off at Breda · 2 min"), high priority,
     * over the lock screen by its full-screen intent, its title public even with previews hidden, and a Stop alarm action
     * that goes to a broadcast receiver (no unlocking, the app doesn't open; a Wear OS watch shows it too). `again`: the
     * one repeat 30 s later while it still rings ("Still ringing: …"). `backup`: rung by the backup alarm by time.
     */
    fun alarm(context: Context, s: RideState, again: Boolean = false, backup: Boolean = false): Notification {
        val leg = s.leg
        val full = PendingIntent.getActivity(context, 1, Intent(context, AlarmActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_USER_ACTION),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val soon = s.ringMinutes?.let { "$it min" } ?: WakeRules.distanceText(s.distance ?: s.wakeMetres)
        val lines = if (backup && !again) WristNotice.backup(leg?.toStop) else WristNotice.ring(true, leg?.toStop, soon, again = again)
        val id = if (again) WristNotice.AGAIN_ID else WristNotice.ALARM_ID
        val pub = NotificationCompat.Builder(context, ALARM).setSmallIcon(R.drawable.ic_stat_ride).setContentTitle(lines.title).build()
        val b = NotificationCompat.Builder(context, ALARM)
            .setSmallIcon(R.drawable.ic_stat_ride)
            .setContentTitle(lines.title)
            .setContentText(lines.body)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setPublicVersion(pub)
            .setGroup(group(s))
            .setContentIntent(full)
            .setDeleteIntent(StopReceiver.intent(context, id, if (again) 15 else 14, AlarmStop.Action.DISMISS))
            .addAction(0, WristNotice.STOP_TITLE, StopReceiver.intent(context, id, if (again) 13 else 12))
        if (!again) b.setFullScreenIntent(full, true).setOngoing(true)
        return b.build()
    }

    /** The school alarm's news: set, moved (old after 12 hours). */
    fun school(context: Context, tag: String, title: String, text: String) {
        val n = NotificationCompat.Builder(context, SCHOOL)
            .setSmallIcon(R.drawable.ic_stat_ride)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setContentIntent(openApp(context, MainActivity.SCREEN_DAY))
            .setAutoCancel(true)
        post(context, NEWS_ID, n, tag)
    }

    /** A trip that started by itself, the look for your bus, "Continue your trip": high, short-lived. */
    fun news(context: Context, tag: String, title: String, text: String, screen: String? = null) {
        val n = NotificationCompat.Builder(context, NEWS)
            .setSmallIcon(R.drawable.ic_stat_ride)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(openApp(context, screen))
            .setAutoCancel(true)
        post(context, NEWS_ID + 1, n, tag)
    }

    /** (A6) a note whose tap opens a web page (NS's claim page). */
    fun link(context: Context, tag: String, title: String, text: String, url: String) {
        val open = PendingIntent.getActivity(context, 40, Intent(Intent.ACTION_VIEW, android.net.Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val n = NotificationCompat.Builder(context, NEWS)
            .setSmallIcon(R.drawable.ic_stat_ride)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setContentIntent(open)
            .setAutoCancel(true)
        post(context, NEWS_ID + 2, n, tag)
    }

    /** "You’re at Breda" (iOS `WristNotice.arrived`), with Stop alarm for the chime and the announcement. */
    fun arrived(context: Context, place: String, then: String?, finished: Boolean = then == null, s: RideState? = null) {
        val l = WristNotice.arrived(place, then, finished)
        val n = NotificationCompat.Builder(context, ARRIVAL)
            .setSmallIcon(R.drawable.ic_stat_ride)
            .setContentTitle(l.title)
            .setContentText(l.body)
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setGroup(group(s))
            .setContentIntent(openApp(context))
            .addAction(0, WristNotice.STOP_TITLE, StopReceiver.intent(context, "arrived-$place", 16))
            .setAutoCancel(true)
        post(context, ARRIVAL_ID, n, "arrived-$place")
    }

    /** (A7) Two buttons on one question ("305 or 306?"): each answers to the ride's service. */
    fun ask(context: Context, title: String, body: String, answers: List<String>, ids: List<String>) {
        val b = NotificationCompat.Builder(context, NEWS)
            .setSmallIcon(R.drawable.ic_stat_ride)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(openApp(context))
            .setAutoCancel(true)
        for ((k, id) in ids.withIndex()) {
            val pi = PendingIntent.getService(context, 50 + k, Intent(context, RideService::class.java).setAction(RideService.ACTION_ANSWER)
                .putExtra(RideService.EXTRA_TRIP, id), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            b.addAction(0, answers.getOrElse(k) { "This one" }, pi)
        }
        post(context, NEWS_ID + 3, b.build(), ASK_TAG)
    }

    const val ASK_TAG = "which"

    /** (A7) A time-sensitive note of the ride ("You’re on the 154…", "That’s the 154 — not yours"), timed out by its kind. */
    fun rideNote(context: Context, tag: String, title: String, text: String) {
        val b = NotificationCompat.Builder(context, NEWS)
            .setSmallIcon(R.drawable.ic_stat_ride)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(openApp(context))
            .setAutoCancel(true)
        post(context, NEWS_ID + 4, b, tag)
    }

    fun cancelTag(context: Context, tag: String, id: Int) = try { context.getSystemService(NotificationManager::class.java).cancel(tag, id) } catch (_: Exception) {}

    fun post(context: Context, id: Int, n: Notification, tag: String? = null) {
        val nm = context.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 33 && !nm.areNotificationsEnabled()) return
        try { nm.notify(tag, id, n) } catch (_: SecurityException) {}
    }

    /** Posted with its tag, and timed out by its kind (`NoticeExpiry`): old ones go by themselves. */
    fun post(context: Context, id: Int, b: NotificationCompat.Builder, tag: String) {
        NoticeExpiry.minutes(tag)?.let { b.setTimeoutAfter((it * 60_000).toLong()) }
        post(context, id, b.build(), tag)
    }

    /** Takes off the notifications older than their kind's time (`NoticeExpiry`), whenever the app is awake. */
    fun sweep(context: Context) {
        val nm = context.getSystemService(NotificationManager::class.java)
        val active = try { nm.activeNotifications.toList() } catch (_: Exception) { return }
        val due = NoticeExpiry.due(active.map { it.tag to it.postTime / 1000.0 }, nl.haltewekker.core.Iso.now()).toSet()
        for (a in active) if (a.tag != null && a.tag in due) nm.cancel(a.tag, a.id)
    }

    fun cancel(context: Context, id: Int) = context.getSystemService(NotificationManager::class.java).cancel(id)
}
