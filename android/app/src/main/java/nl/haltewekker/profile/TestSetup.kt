package nl.haltewekker.profile

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import nl.haltewekker.App
import nl.haltewekker.auto.Regions
import nl.haltewekker.auto.ResumeStore
import nl.haltewekker.core.Iso
import nl.haltewekker.ride.RideStore
import nl.haltewekker.school.SchoolAlarm
import nl.haltewekker.work.Works

/**
 * Settings › Test the setup as a new user (iOS 0.23 `SetupStore`): your own setup is saved first under its own key,
 * then the setup opens empty. Cancel drops the backup; Done makes the test setup the one in use (the home says so)
 * until "Back to my own", which puts every saved value back exactly as it was. A test that never reached Done is put
 * back at the next launch.
 */
object TestSetup {
    private val _live = MutableStateFlow(false)
    val live: StateFlow<Boolean> = _live

    private fun store(c: Context) = (c.applicationContext as App).store
    private fun backup(c: Context) = SetupBackup.decode(store(c).getString(SetupBackup.STORAGE_KEY))

    /** At launch, before the stores read their values. */
    fun atLaunch(c: Context) {
        val b = backup(c)
        when (SetupBackup.atLaunch(b)) {
            SetupBackup.LaunchStep.NOTHING -> _live.value = false
            SetupBackup.LaunchStep.KEEP_TESTING -> _live.value = true
            SetupBackup.LaunchStep.RESTORE -> {
                b!!.restore { k, v -> store(c).putString(k, v) }
                store(c).putString(SetupBackup.STORAGE_KEY, null)
                store(c).reload()
                _live.value = false
            }
        }
    }

    /** Your own setup saved; false: not now (a ride runs, or a test is already in use). */
    fun start(c: Context): Boolean {
        RideStore.load(c)
        if (RideStore.state.value != null || _live.value) return false
        val b = SetupBackup.take(store(c)::getString, Iso.now())
        store(c).putString(SetupBackup.STORAGE_KEY, b.encode())
        return true
    }

    /** Cancelled before Done: nothing was changed, the backup goes. */
    fun cancel(c: Context) {
        val b = backup(c) ?: return
        if (!b.live) store(c).putString(SetupBackup.STORAGE_KEY, null)
    }

    /** Before the test's Done saves: your own school alarms go (they come back with your own setup). */
    fun beforeDone(c: Context) { SchoolAlarm.clearWeek(c) }

    /** The test's Done: the test setup is in use now. */
    fun done(c: Context) {
        val b = backup(c) ?: return
        store(c).putString(SetupBackup.STORAGE_KEY, b.copy(live = true).encode())
        _live.value = true
    }

    /** "Back to my own": every value the test could change goes back as it was, and the stores read them again. */
    fun backToOwn(c: Context) {
        val b = backup(c) ?: run { _live.value = false; return }
        SchoolAlarm.cancelAll(c)
        b.restore { k, v -> store(c).putString(k, v) }
        store(c).putString(SetupBackup.STORAGE_KEY, null)
        _live.value = false
        store(c).reload()
        SchoolAlarm.reload(c)
        ResumeStore.reload(c)
        SchoolAlarm.rearm(c)
        Works.update(c)
        Regions.update(c)
        if (SchoolAlarm.config.value.on) Works.soon(c)
    }
}
