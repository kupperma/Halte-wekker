package nl.haltewekker.work

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.CalendarContract
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import nl.haltewekker.App
import nl.haltewekker.auto.Regions
import nl.haltewekker.core.Iso
import nl.haltewekker.ride.Notifications
import nl.haltewekker.school.Calendars
import nl.haltewekker.school.SchoolAlarm
import nl.haltewekker.school.ScheduleSource
import java.util.concurrent.TimeUnit

/**
 * The background work (iOS BGTask), all with WorkManager and inside Android's battery rules: the school week planned
 * about every hour while the school alarm is on (with a network; near days get live times, far ones are only looked at
 * every few hours, `SchoolPlan.due`), once more about 75 minutes before the next alarm (the morning's live times), and
 * when the calendar changes (a content trigger, a burst of changes settled first). Nothing runs with the alarm off.
 */
object Works {
    private const val PERIODIC = "school-plan"
    private const val EARLY = "school-early"
    private const val CALENDAR = "school-calendar"
    private const val NOW = "school-now"

    private val online = Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()

    fun update(c: Context) {
        val wm = try { WorkManager.getInstance(c) } catch (_: Exception) { return }
        SchoolAlarm.load(c)
        val on = SchoolAlarm.config.value.on
        if (!on) {
            wm.cancelUniqueWork(PERIODIC); wm.cancelUniqueWork(EARLY); wm.cancelUniqueWork(CALENDAR)
            return
        }
        wm.enqueueUniquePeriodicWork(PERIODIC, ExistingPeriodicWorkPolicy.KEEP,
            PeriodicWorkRequestBuilder<PlanWorker>(1, TimeUnit.HOURS, 20, TimeUnit.MINUTES).setConstraints(online).build())
        val prof = (c.applicationContext as App).store.profile.value
        if (prof.schedule == ScheduleSource.CALENDARS && Calendars.granted(c)) watchCalendar(c, ExistingWorkPolicy.KEEP)
        else wm.cancelUniqueWork(CALENDAR)
    }

    /** Waits for a change to the phone's calendars (a sync), then plans: re-armed after each run. */
    fun watchCalendar(c: Context, policy: ExistingWorkPolicy) {
        val k = Constraints.Builder()
            .addContentUriTrigger(CalendarContract.CONTENT_URI, true)
            .setTriggerContentUpdateDelay(5, TimeUnit.SECONDS)
            .setTriggerContentMaxDelay(2, TimeUnit.MINUTES)
            .build()
        WorkManager.getInstance(c).enqueueUniqueWork(CALENDAR, policy,
            OneTimeWorkRequestBuilder<CalendarWorker>().setConstraints(k).build())
    }

    /** Once more shortly before the alarm, for the morning's live times (null: none). */
    fun early(c: Context, alarmAt: Double?) {
        val wm = try { WorkManager.getInstance(c) } catch (_: Exception) { return }
        val delay = alarmAt?.let { it - 75 * 60 - Iso.now() }
        if (delay == null || delay < 0) { wm.cancelUniqueWork(EARLY); return }
        wm.enqueueUniqueWork(EARLY, ExistingWorkPolicy.REPLACE, OneTimeWorkRequestBuilder<PlanWorker>()
            .setInitialDelay(delay.toLong(), TimeUnit.SECONDS).setConstraints(online).setInputData(workDataOf("force" to true)).build())
    }

    /** Plan as soon as there's a network (after a restart, a restore). */
    fun soon(c: Context) {
        val wm = try { WorkManager.getInstance(c) } catch (_: Exception) { return }
        wm.enqueueUniqueWork(NOW, ExistingWorkPolicy.REPLACE, OneTimeWorkRequestBuilder<PlanWorker>().setConstraints(online)
            .setInputData(workDataOf("force" to true)).build())
    }
}

class PlanWorker(c: Context, p: WorkerParameters) : CoroutineWorker(c, p) {
    override suspend fun doWork(): Result {
        Notifications.sweep(applicationContext)
        SchoolAlarm.refresh(applicationContext, force = inputData.getBoolean("force", false))
        return Result.success()
    }
}

class CalendarWorker(c: Context, p: WorkerParameters) : CoroutineWorker(c, p) {
    override suspend fun doWork(): Result {
        SchoolAlarm.refresh(applicationContext, force = true)
        if (SchoolAlarm.config.value.on) Works.watchCalendar(applicationContext, ExistingWorkPolicy.APPEND_OR_REPLACE)
        return Result.success()
    }
}

/** After a restart (Android forgets alarms and proximity alerts then), an update, or a clock change: set them again. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED,
            Intent.ACTION_TIME_CHANGED, Intent.ACTION_TIMEZONE_CHANGED -> {
                SchoolAlarm.rearm(context)
                Regions.update(context)
                Works.update(context)
                if (SchoolAlarm.config.value.on) Works.soon(context)
            }
        }
    }
}
