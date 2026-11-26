package nl.haltewekker.school

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import nl.haltewekker.ui.MainActivity
import java.time.LocalDate

/**
 * The school alarm with Android (iOS `WakeAlarm`): `AlarmManager.setAlarmClock`, so it rings on the minute also in
 * Doze, shows in the status bar and as the phone's next alarm. One per school day, its request code from the day.
 * When it goes off, `WakeReceiver` starts `WakeService`, which rings and brings up the alarm screen (Stop / Open).
 */
object WakeAlarm {
    const val ACTION_FIRE = "nl.haltewekker.school.WAKE"
    const val EXTRA_DAY = "day"
    const val EXTRA_TITLE = "title"
    const val EXTRA_BODY = "body"
    const val EXTRA_LEAVE = "leave"
    const val TEST_DAY = "test"

    private fun code(day: String): Int =
        if (day == TEST_DAY) 4999 else 5000 + ((try { LocalDate.parse(day).toEpochDay() } catch (_: Exception) { day.hashCode().toLong() } % 100_000).toInt() and 0x7fffffff) % 100_000

    private fun fire(c: Context, day: String, title: String?, body: String?, leave: Double?, flags: Int): PendingIntent? {
        val i = Intent(c, WakeReceiver::class.java).setAction(ACTION_FIRE).putExtra(EXTRA_DAY, day)
        title?.let { i.putExtra(EXTRA_TITLE, it) }; body?.let { i.putExtra(EXTRA_BODY, it) }; leave?.let { i.putExtra(EXTRA_LEAVE, it) }
        return PendingIntent.getBroadcast(c, code(day), i, flags or PendingIntent.FLAG_IMMUTABLE)
    }

    private fun show(c: Context): PendingIntent = PendingIntent.getActivity(c, 4998,
        Intent(c, MainActivity::class.java).putExtra(MainActivity.EXTRA_SCREEN, MainActivity.SCREEN_DAY).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)

    /** Whether Android lets it set alarms on the minute (12: asked; 13 and later: an alarm clock's right). */
    fun exactAllowed(c: Context): Boolean = Build.VERSION.SDK_INT < 31 || c.getSystemService(AlarmManager::class.java).canScheduleExactAlarms()

    /** Sets the alarm for a day. True: as an alarm clock; false: only roughly (exact alarms not allowed). */
    fun set(c: Context, day: String, at: Double, title: String, body: String, leave: Double?): Boolean {
        val am = c.getSystemService(AlarmManager::class.java)
        val pi = fire(c, day, title, body, leave, PendingIntent.FLAG_UPDATE_CURRENT) ?: return false
        val ms = (at * 1000).toLong()
        return try {
            if (!exactAllowed(c)) throw SecurityException("no exact alarms")
            am.setAlarmClock(AlarmManager.AlarmClockInfo(ms, show(c)), pi)
            true
        } catch (_: SecurityException) {
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, ms, pi)
            false
        }
    }

    fun cancel(c: Context, day: String) {
        val pi = fire(c, day, null, null, null, PendingIntent.FLAG_NO_CREATE) ?: return
        c.getSystemService(AlarmManager::class.java).cancel(pi)
        pi.cancel()
    }

    /** A test: the same kind of alarm, ringing in a minute. Returns when it rings. */
    fun test(c: Context): Double {
        val at = System.currentTimeMillis() / 1000.0 + 60
        set(c, TEST_DAY, at, "Test alarm", "Your school alarm works.", null)
        return at
    }

    /** The phone's next alarm clock, if it's one of ours (to show it's really set). */
    fun nextOnPhone(c: Context): Double? {
        val info = c.getSystemService(AlarmManager::class.java).nextAlarmClock ?: return null
        return if (info.showIntent?.creatorPackage == c.packageName) info.triggerTime / 1000.0 else null
    }
}
