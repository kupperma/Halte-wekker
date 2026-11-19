package nl.haltewekker.ride

import android.Manifest
import android.annotation.SuppressLint
import android.app.AlarmManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.IBinder
import android.os.Looper
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import nl.haltewekker.App
import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.core.Iso
import nl.haltewekker.data.DoorTrip
import nl.haltewekker.match.Fix
import nl.haltewekker.match.OnBoardRules
import kotlin.math.abs

/**
 * Runs a ride (iOS `TripManager`, the core of it): a foreground service with location, so GPS keeps coming with the
 * phone locked. It rings before the last stop of each leg (distance-based), says when you're there, goes on to the
 * next leg, finds the vehicle you're on, keeps the arrival time up to date and drives the ongoing notification. A
 * backup alarm by time (AlarmManager, exact and allowed while idle) rings if GPS never gets you within the wake
 * distance. It runs only during a ride: nothing polls otherwise.
 */
class RideService : Service() {
    companion object {
        const val ACTION_START = "nl.haltewekker.ride.START"
        const val ACTION_STOP_ALARM = "nl.haltewekker.ride.STOP_ALARM"
        const val ACTION_END = "nl.haltewekker.ride.END"
        const val ACTION_BACKUP = "nl.haltewekker.ride.BACKUP"
        const val ACTION_ON_IT = "nl.haltewekker.ride.ON_IT"
        const val ACTION_WAKE = "nl.haltewekker.ride.WAKE"
        const val EXTRA_KM = "km"

        /** Starts a ride on `trip` ("I'm on it"): the first leg asleep, each leg's wake distance from the settings. */
        fun start(context: Context, trip: DoorTrip, destination: String) {
            val st = (context.applicationContext as App).store.settings.value
            val now = Iso.now()
            val state = RideState(trip = trip, destination = destination, startedAt = now, legStart = now,
                wakeKm = trip.rides.map { WakeRules.wakeKm(it.isTrain, st.busKm, st.trainKm) })
            RideStore.set(context, state)
            ContextCompat.startForegroundService(context, Intent(context, RideService::class.java).setAction(ACTION_START))
        }

        fun send(context: Context, action: String, km: Double? = null) {
            val i = Intent(context, RideService::class.java).setAction(action)
            km?.let { i.putExtra(EXTRA_KM, it) }
            try { context.startService(i) } catch (_: Exception) { ContextCompat.startForegroundService(context, i) }
        }
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val lm by lazy { getSystemService(LocationManager::class.java) }
    private val app get() = application as App
    private val fixes = ArrayDeque<Fix>()
    private var intervalMs = 0L
    private val look = OnBoardLook()
    private var tick: Job? = null
    private var lastNotify = 0.0
    private var lastPhase: Phase? = null
    private var backupScheduledFor: Double? = null
    private var etaAt = 0.0

    private val listener = LocationListener { onLocation(it) }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        Notifications.channels(this)
        RideStore.load(this)
        AlarmPlayer.warmUp(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!goForeground()) {
            // Not allowed to follow location now (started from the background without "all the time"): the backup
            // alarm still rings, from here, and the alarm screen brings the app to the front.
            if (intent?.action == ACTION_BACKUP && RideStore.state.value?.phase == Phase.SLEEPING) ring("backup alarm by time")
            stopSelf()
            return START_NOT_STICKY
        }
        if (RideStore.state.value == null) { stopRide(); return START_NOT_STICKY }
        when (intent?.action) {
            ACTION_STOP_ALARM -> stopAlarm()
            ACTION_END -> { end(); return START_NOT_STICKY }
            ACTION_BACKUP -> if (RideStore.state.value?.phase == Phase.SLEEPING) ring("backup alarm by time")
            ACTION_ON_IT -> onIt()
            ACTION_WAKE -> intent.getDoubleExtra(EXTRA_KM, -1.0).takeIf { it > 0 }?.let(::setWakeKm)
        }
        begin()
        return START_STICKY
    }

    private fun goForeground(): Boolean {
        val n = Notifications.ride(this, RideStore.state.value)
        return try {
            if (Build.VERSION.SDK_INT >= 29) startForeground(Notifications.RIDE_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
            else startForeground(Notifications.RIDE_ID, n)
            true
        } catch (e: Exception) {
            // no location permission (Android 14 needs it for a location service), or not allowed from the background
            RideStore.update(this) { it.copy(note = "Couldn't follow your ride: location isn't allowed.") }
            false
        }
    }

    private fun begin() {
        if (intervalMs == 0L) requestLocation(RideGPS.intervalMs(false))
        if (tick?.isActive != true) tick = scope.launch { tickLoop() }
        scheduleBackup()
        notifyRide(force = true)
    }

    private fun hasLocation() = ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
        ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED

    @SuppressLint("MissingPermission")
    private fun requestLocation(ms: Long) {
        if (!hasLocation() || ms == intervalMs) return
        intervalMs = ms
        lm.removeUpdates(listener)
        val minMetres = if (ms > 5000) 75f else 0f
        try {
            if (lm.isProviderEnabled(LocationManager.GPS_PROVIDER))
                lm.requestLocationUpdates(LocationManager.GPS_PROVIDER, ms, minMetres, listener, Looper.getMainLooper())
            if (lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER))
                lm.requestLocationUpdates(LocationManager.NETWORK_PROVIDER, maxOf(ms, 10_000L), minMetres, listener, Looper.getMainLooper())
        } catch (_: Exception) {}
    }

    private fun onLocation(loc: Location) {
        val now = Iso.now()
        val fix = Fix(loc.time / 1000.0, GeoPoint(loc.latitude, loc.longitude),
            if (loc.hasAccuracy()) loc.accuracy.toDouble() else -1.0,
            if (loc.hasSpeed()) loc.speed.toDouble() else -1.0,
            if (loc.hasBearing()) loc.bearing.toDouble() else -1.0)
        // a network fix while GPS gives good ones adds nothing
        if (loc.provider == LocationManager.NETWORK_PROVIDER && fixes.lastOrNull()?.let { now - it.t < 15 && it.accuracy in 0.0..60.0 } == true) return
        fixes.addLast(fix)
        while (fixes.isNotEmpty() && now - fixes.first().t > 120) fixes.removeFirst()
        val s = RideStore.state.value ?: return
        val leg = s.leg ?: return
        val to = leg.to ?: return
        val d = Geo.metres(fix.p, to)
        RideStore.update(this) { it.copy(distance = d, accuracy = fix.accuracy, speed = fix.speed.takeIf { v -> v >= 0 }, lastFixAt = now) }
        when (WakeRules.onFix(s.phase, d, fix.accuracy, now - s.legStart, s.wakeMetres)) {
            WakeRules.Action.RING -> ring("approach")
            WakeRules.Action.AWAKE_SILENTLY -> RideStore.update(this) {
                it.copy(phase = Phase.AWAKE, note = "You started close to your stop: it tells you when you're there.")
            }
            WakeRules.Action.ARRIVE -> arrive()
            WakeRules.Action.NONE -> {}
        }
        // rough GPS far from the stop on a confirmed vehicle (iOS RideGPS)
        val cur = RideStore.state.value ?: return
        val far = RideGPS.far(RideGPS.Input(
            enabled = app.store.settings.value.roughGPSOnLongRides, asleep = cur.phase == Phase.SLEEPING,
            confirmed = cur.vehicleSource == VehicleSource.BY_GPS || cur.vehicleSource == VehicleSource.BY_HAND,
            metresToStop = d, accuracy = fix.accuracy, fixAge = now - fix.t, wakeMetres = cur.wakeMetres, isTrain = leg.isTrain,
            speed = fix.speed.takeIf { it >= 0 }, secondsToStop = cur.legArrival?.let { it - now }, wasFar = cur.roughGPS))
        if (far != cur.roughGPS) RideStore.update(this) { it.copy(roughGPS = far) }
        requestLocation(RideGPS.intervalMs(far))
        notifyRide(force = false)
    }

    /** The ride's network on one clock: a look for the vehicle while it isn't known, the arrival once it is. */
    private suspend fun tickLoop() {
        while (scope.isActive) {
            val s = RideStore.state.value ?: break
            val leg = s.leg
            val now = Iso.now()
            if (leg != null && !s.finished) {
                if (s.vehicleTripId == null && s.phase == Phase.SLEEPING) {
                    val moving = OnBoardRules.movingByTrack(fixes.toList(), now)
                    if (moving || fixes.size >= 3) {
                        val mine = fixes.toList()
                        val real = app.store.settings.value.realPositions
                        val f = withContext(Dispatchers.Default) { look.look(mine, leg, now, real) }
                        if (f != null) RideStore.update(this) {
                            it.copy(vehicleTripId = f.tripId, vehicleLine = f.line,
                                vehicleSource = if (f.byGPS || moving) VehicleSource.BY_GPS else VehicleSource.BY_TIMES)
                        }
                    }
                }
                val v = RideStore.state.value?.vehicleTripId ?: leg.tripId
                if (now - etaAt >= 60 && leg.to != null) {
                    etaAt = now
                    look.arrival(v, leg.to!!)?.let { eta -> RideStore.update(this) { it.copy(eta = eta) } }
                    scheduleBackup()
                }
                notifyRide(force = false)
            }
            delay(if (RideStore.state.value?.vehicleTripId == null) 15_000 else 30_000)
        }
    }

    private fun ring(why: String) {
        val s = RideStore.state.value ?: return
        if (s.phase != Phase.SLEEPING) return
        val st = app.store.settings.value
        val quiet = WakeRules.quiet(st.headphonesOnly, AudioRoute.privateOutput(this))
        val leg = s.leg
        RideStore.update(this) { it.copy(phase = Phase.ALARM, quiet = quiet, note = why, roughGPS = false) }
        cancelBackup()
        requestLocation(RideGPS.intervalMs(false))
        AlarmPlayer.ring(this, if (st.announce && leg != null) WakeRules.announcement(leg.toStop, leg.isTrain, true) else null, quiet)
        RideStore.state.value?.let { Notifications.post(this, Notifications.ALARM_ID, Notifications.alarm(this, it)) }
        notifyRide(force = true)
    }

    private fun stopAlarm() {
        AlarmPlayer.stop(this)
        Notifications.cancel(this, Notifications.ALARM_ID)
        val s = RideStore.state.value ?: return
        if (s.phase != Phase.ALARM) return
        if (app.store.settings.value.ringAtStop) RideStore.update(this) { it.copy(phase = Phase.AWAKE) } else legDone()
        notifyRide(force = true)
    }

    private fun arrive() {
        val s = RideStore.state.value ?: return
        val leg = s.leg ?: return
        val st = app.store.settings.value
        val next = s.trip.rides.getOrNull(s.index + 1)
        legDone()
        val quiet = WakeRules.quiet(st.headphonesOnly, AudioRoute.privateOutput(this))
        AlarmPlayer.chime(this, if (st.announce) WakeRules.announcement(leg.toStop, leg.isTrain, false) else null, quiet)
        Notifications.arrived(this, leg.toStop, next?.let {
            "Next: ${if (it.isTrain) it.line else "bus ${it.line}"} at ${Notifications.time(it.departure)} from ${it.fromStop}" +
                (it.platform?.let { p -> ", platform $p" } ?: "")
        } ?: "Get off here: your trip is done.")
    }

    private fun legDone() {
        val s = RideStore.state.value ?: return
        val now = Iso.now()
        look.reset()
        etaAt = 0.0
        if (s.index + 1 < s.trip.rides.size) {
            RideStore.update(this) {
                it.copy(index = it.index + 1, phase = Phase.SLEEPING, legStart = now, vehicleTripId = null, vehicleLine = null,
                    vehicleSource = VehicleSource.NONE, eta = null, distance = null, quiet = false, note = null, roughGPS = false)
            }
            requestLocation(RideGPS.intervalMs(false))
            scheduleBackup()
        } else {
            RideStore.update(this) { it.copy(phase = Phase.FINISHED) }
            cancelBackup()
            scope.launch { delay(90_000); if (RideStore.state.value?.finished == true) end() }
        }
        notifyRide(force = true)
    }

    private fun onIt() {
        val leg = RideStore.state.value?.leg ?: return
        RideStore.update(this) { it.copy(vehicleTripId = leg.tripId, vehicleLine = leg.line, vehicleSource = VehicleSource.BY_HAND) }
        notifyRide(force = true)
    }

    private fun setWakeKm(km: Double) {
        RideStore.update(this) { s ->
            val l = s.wakeKm.toMutableList()
            if (s.index < l.size) l[s.index] = km
            s.copy(wakeKm = l)
        }
        backupScheduledFor = null
        scheduleBackup()
        notifyRide(force = true)
    }

    private fun end() {
        AlarmPlayer.stop(this)
        cancelBackup()
        Notifications.cancel(this, Notifications.ALARM_ID)
        RideStore.set(this, null)
        stopRide()
    }

    private fun stopRide() {
        tick?.cancel()
        try { lm.removeUpdates(listener) } catch (_: Exception) {}
        intervalMs = 0
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun notifyRide(force: Boolean) {
        val s = RideStore.state.value
        val now = Iso.now()
        if (!force && s?.phase == lastPhase && now - lastNotify < 15) return
        lastNotify = now; lastPhase = s?.phase
        Notifications.post(this, Notifications.RIDE_ID, Notifications.ride(this, s))
    }

    // MARK: the backup alarm by time

    private fun backupIntent(): PendingIntent = PendingIntent.getBroadcast(this, 20,
        Intent(this, AlarmReceiver::class.java).setAction(ACTION_BACKUP), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)

    private fun scheduleBackup() {
        val s = RideStore.state.value ?: return
        val leg = s.leg ?: return
        if (s.phase != Phase.SLEEPING) return
        val at = WakeRules.backupAt(s.legArrival, leg.isTrain, s.wakeMetres, Iso.now(), app.store.settings.value.backupAlarm)
        if (at == null) { cancelBackup(); return }
        if (backupScheduledFor?.let { abs(it - at) < 30 } == true) return
        backupScheduledFor = at
        val am = getSystemService(AlarmManager::class.java)
        val ms = (at * 1000).toLong()
        try {
            if (Build.VERSION.SDK_INT < 31 || am.canScheduleExactAlarms()) am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, ms, backupIntent())
            else am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, ms, backupIntent())
        } catch (_: SecurityException) {
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, ms, backupIntent())
        }
    }

    private fun cancelBackup() {
        backupScheduledFor = null
        getSystemService(AlarmManager::class.java).cancel(backupIntent())
    }

    override fun onDestroy() {
        scope.cancel()
        try { lm.removeUpdates(listener) } catch (_: Exception) {}
        if (RideStore.state.value == null) AlarmPlayer.shutdown(this)
        super.onDestroy()
    }
}
