package nl.haltewekker

import android.app.Application
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import nl.haltewekker.auto.Regions
import nl.haltewekker.profile.School
import nl.haltewekker.profile.SchoolCatalog
import nl.haltewekker.profile.Store
import nl.haltewekker.profile.TestSetup
import nl.haltewekker.ride.Notifications
import nl.haltewekker.ride.RideStore
import nl.haltewekker.school.SchoolAlarm
import nl.haltewekker.work.Works

class App : Application() {
    lateinit var store: Store
        private set

    /** Work that outlives a screen (planning the school week after a setting changed). */
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    fun launch(block: suspend () -> Unit): Job = scope.launch { try { block() } catch (_: Exception) {} }

    /** The bundled schools (read once, when first needed). */
    val schools: List<School> by lazy {
        SchoolCatalog.decode(try { assets.open("Schools.json").bufferedReader().use { it.readText() } } catch (_: Exception) { null })
    }

    override fun onCreate() {
        super.onCreate()
        store = Store(this)
        TestSetup.atLaunch(this)           // a test of the setup that never went live: your own setup back first
        Notifications.channels(this)
        RideStore.load(this)
        SchoolAlarm.load(this)
        Works.update(this)
        Regions.update(this)
        Notifications.sweep(this)
        // (0.10.1) the check-out reminder is off unless turned on again: none left from before
        if (!store.settings.value.checkOut) Notifications.cancelTag(this, "checkout", Notifications.NEWS_ID + 1)
        // A3: Friends (what's on this phone; the relay only at the app's checks)
        nl.haltewekker.friends.FriendStore.init(this)
        nl.haltewekker.friends.FriendTravelShare.attach(this)
        nl.haltewekker.friends.FriendWork.update(this)
        // A4: the live link (works without a friends account) and "Share ride logs" (off unless turned on)
        nl.haltewekker.logs.FieldLog.init(this)
        nl.haltewekker.friends.LiveLinkStore.attach(this)
        nl.haltewekker.logs.LogShareStore.attach(this)
        // (listening now) the switches for sharing what you listen to (off unless turned on)
        nl.haltewekker.friends.MusicShareStore.load(this)
    }
}
