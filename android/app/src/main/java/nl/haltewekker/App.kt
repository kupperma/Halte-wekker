package nl.haltewekker

import android.app.Application
import nl.haltewekker.profile.School
import nl.haltewekker.profile.SchoolCatalog
import nl.haltewekker.profile.Store
import nl.haltewekker.ride.Notifications
import nl.haltewekker.ride.RideStore

class App : Application() {
    lateinit var store: Store
        private set

    /** The bundled schools (read once, when first needed). */
    val schools: List<School> by lazy {
        SchoolCatalog.decode(try { assets.open("Schools.json").bufferedReader().use { it.readText() } } catch (_: Exception) { null })
    }

    override fun onCreate() {
        super.onCreate()
        store = Store(this)
        Notifications.channels(this)
        RideStore.load(this)
    }
}
