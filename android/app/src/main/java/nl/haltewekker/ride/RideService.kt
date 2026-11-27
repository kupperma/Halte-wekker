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
import nl.haltewekker.auto.AutoRules
import nl.haltewekker.auto.AutoStart
import nl.haltewekker.auto.Regions
import nl.haltewekker.auto.ResumeOffer
import nl.haltewekker.auto.ResumeStore
import nl.haltewekker.auto.TripResume
import nl.haltewekker.data.Transit
import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.core.Iso
import nl.haltewekker.data.DoorTrip
import nl.haltewekker.logs.FieldFormat
import nl.haltewekker.logs.FieldLog
import nl.haltewekker.match.Fix
import nl.haltewekker.match.OnBoardRules
import nl.haltewekker.match.ChooseGPS
import nl.haltewekker.data.TransitParse
import nl.haltewekker.live.LiveFeeds
import nl.haltewekker.live.RealPositions
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
        const val ACTION_LOOK = "nl.haltewekker.ride.LOOK"
        /** (0.10.3, iOS 0.42.4) Fastest trip watches (`WaitStore.request`): the look at what you get on, whatever is on screen. */
        const val ACTION_WATCH = "nl.haltewekker.ride.WATCH"
        const val ACTION_UNWATCH = "nl.haltewekker.ride.UNWATCH"
        const val EXTRA_KM = "km"
        const val EXTRA_REGION = "region"
        const val EXTRA_BY_HAND = "byHand"
        /** (A7) the answer to "305 or 306?" (`EXTRA_TRIP`), a card closed (`EXTRA_WHAT`: wrong, other), look again. */
        const val ACTION_ANSWER = "nl.haltewekker.ride.ANSWER"
        const val ACTION_DISMISS = "nl.haltewekker.ride.DISMISS"
        const val ACTION_PICK_AGAIN = "nl.haltewekker.ride.PICK_AGAIN"
        const val ACTION_SWITCH_CHANGE = "nl.haltewekker.ride.SWITCH_CHANGE"
        const val EXTRA_TRIP = "trip"
        const val EXTRA_WHAT = "what"

        private fun newState(context: Context, trip: DoorTrip, destination: String, index: Int): RideState {
            val st = (context.applicationContext as App).store.settings.value
            val now = Iso.now()
            val i = index.coerceIn(0, maxOf(0, trip.rides.size - 1))
            return RideState(trip = trip, destination = destination, index = i, firstLeg = i,
                startedAt = now, legStart = now, wakeKm = trip.rides.map { WakeRules.wakeKm(it.isTrain, st.busKm, st.trainKm) })
        }

        /** Starts a ride on `trip` ("I'm on it"), at leg `index`: asleep, each leg's wake distance from the settings. */
        fun start(context: Context, trip: DoorTrip, destination: String, index: Int = 0, resumed: ResumeOffer? = null) {
            var st = newState(context, trip, destination, index)
            // (A6, iOS 0.35) going on with a trip ended by hand is still that trip: its start stays
            if (resumed?.startedAt != null) st = st.copy(startedAt = resumed.startedAt, firstLeg = resumed.firstLeg ?: st.firstLeg,
                startLat = resumed.startLat, startLon = resumed.startLon, startFixAt = resumed.startFixAt)
            RideStore.set(context, st)
            nl.haltewekker.auto.ResumeStore.set(context, null)
            ContextCompat.startForegroundService(context, Intent(context, RideService::class.java).setAction(ACTION_START))
        }

        /**
         * You left a home stop or School (auto-start): GPS on for a few minutes, to find the bus or train you're on
         * and start the trip by itself. Android may not let it start from the background (battery limits): then a
         * notification asks you to open the app.
         */
        fun look(context: Context, region: String) {
            try {
                ContextCompat.startForegroundService(context, Intent(context, RideService::class.java).setAction(ACTION_LOOK).putExtra(EXTRA_REGION, region))
            } catch (_: Exception) {
                Notifications.news(context, "autostart-ask", "On your way?", "Open Haltewekker to start your trip: Android didn't let it look for your bus by itself.")
            }
        }

        fun send(context: Context, action: String, km: Double? = null, trip: String? = null, what: String? = null) {
            val i = Intent(context, RideService::class.java).setAction(action)
            km?.let { i.putExtra(EXTRA_KM, it) }
            trip?.let { i.putExtra(EXTRA_TRIP, it) }
            what?.let { i.putExtra(EXTRA_WHAT, it) }
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
    // (0.10.6, iOS 0.42.9 `RideSaver`) the notification's cadence: what it said, its meaningful part, the distance
    private var shownSay = ""
    private var shownKey = ""
    private var shownLook = ""
    private var notifyLater: Job? = null
    /** Where you've stood since when, waiting for the next ride (iOS `TransferPolicy.Anchor`). */
    private var waitAnchor: Pair<GeoPoint, Double>? = null
    private var foundTrip: String? = null
    private var foundAt = 0.0
    private var backupScheduledFor: Double? = null
    private var etaAt = 0.0

    private val listener = LocationListener { onLocation(it) }
    private var lookJob: Job? = null
    private var lookRegion: String? = null
    private var lookFrom = 0.0
    private val autoLook = OnBoardLook()

    // (A6, iOS 0.33) wake by time: your smoothed speed, the vehicle's road from where you got on to your stop and your
    // stop's live arrival (from the vehicle's own trip answer)
    private val smoother = SpeedSmoother()
    private var lastSpeedFix: Fix? = null
    private var wakeRoute: List<GeoPoint> = emptyList()
    private var wakeLive: Pair<Double, Double>? = null          // (arrival, asked at)
    // (A6, iOS 0.34) dead reckoning: the newest good fix (≤ 100 m), and where the reckoning started on the route
    private var lastGood: Fix? = null
    private var reckonFrom: Pair<Double, Double>? = null        // (metres along, at)
    private var reckonJob: Job? = null
    // (A7) choosing between vehicles that fit about as well, the moment you left the stop, how long each one's own GPS
    // has fitted you (the wrong bus), the rivals look on a train, another line's bus at your stop
    private val choice = RideChoice()
    private var chooseJob: Job? = null
    private var departure: nl.haltewekker.match.Departure? = null
    private var gpsRuns: Map<String, WrongBus.Run> = emptyMap()
    private var rivalAt = 0.0
    private var waitLogged = 0.0
    private var otherAt = 0.0
    private var otherBoard: Pair<String, List<nl.haltewekker.data.BoardDeparture>>? = null
    private var otherBoardAt = 0.0
    private val otherTold = HashSet<String>()
    private val otherClosed = HashSet<String>()
    // (0.10.3, iOS 0.42.4) Fastest trip's watching: owned here, not by a screen (`WaitWatch`, `WaitStart`)
    private var watch = WaitWatch.State()
    private var watchJob: Job? = null
    private var watchDest: String? = null
    private val waitLook = WaitLook()

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        Notifications.channels(this)
        RideStore.load(this)
        FieldLog.init(this)
        AlarmPlayer.warmUp(this)
        WakeBookStore.load(this)
        RideCacheStore.load(this, RideStore.state.value?.startedAt)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_WATCH) {
            if (RideStore.state.value != null) { WaitStore.ended(); return START_STICKY }      // a ride runs: nothing to watch
            if (!goForeground(watching = true)) { WaitStore.ended(); if (lookJob?.isActive != true) stopSelf(); return START_NOT_STICKY }
            startWatch()
            return START_NOT_STICKY
        }
        if (intent?.action == ACTION_UNWATCH) {
            stopWatch(intent.getStringExtra(EXTRA_WHAT) ?: "stopped from the notification")
            if (RideStore.state.value == null && lookJob?.isActive != true) stopRide()
            return START_NOT_STICKY
        }
        if (intent?.action == ACTION_LOOK) {
            if (RideStore.state.value != null) return START_STICKY                 // a ride runs: nothing to look for
            if (watch.watching) return START_STICKY                               // Fastest trip watches already
            if (!goForeground(looking = true)) { stopSelf(); return START_NOT_STICKY }
            startLook(intent.getStringExtra(EXTRA_REGION) ?: "")
            return START_NOT_STICKY
        }
        if (!goForeground()) {
            // Not allowed to follow location now (started from the background without "all the time"): the backup
            // alarm still rings, from here, and the alarm screen brings the app to the front.
            if (intent?.action == ACTION_BACKUP && RideStore.state.value?.phase == Phase.SLEEPING) ring("backup alarm by time")
            stopSelf()
            return START_NOT_STICKY
        }
        if (RideStore.state.value == null) {
            // (0.10.3) nothing for a ride: the watching goes on as it was
            if (watch.watching) { goForeground(watching = true); return START_NOT_STICKY }
            lookJob?.cancel(); stopRide(); return START_NOT_STICKY
        }
        lookJob?.cancel(); lookJob = null
        if (watch.watching) stopWatch("the trip started")
        if (intent?.action == ACTION_START) logStart(if (RideStore.state.value?.auto == true) "auto (station left)" else "hand")
        when (intent?.action) {
            ACTION_STOP_ALARM -> stopAlarm()
            ACTION_END -> { end(byHand = intent.getBooleanExtra(EXTRA_BY_HAND, true)); return START_NOT_STICKY }
            ACTION_BACKUP -> if (RideStore.state.value?.phase == Phase.SLEEPING) ring("backup alarm by time")
            ACTION_ON_IT -> onIt()
            ACTION_WAKE -> intent.getDoubleExtra(EXTRA_KM, -1.0).takeIf { it > 0 }?.let(::setWakeKm)
            ACTION_ANSWER -> intent.getStringExtra(EXTRA_TRIP)?.let(::answer)
            ACTION_DISMISS -> RideStore.update(this) { if (intent.getStringExtra(EXTRA_WHAT) == "other") { it.otherAtStop?.let { a -> otherClosed.add(a.tripId) }; it.copy(otherAtStop = null) } else it.copy(wrongBus = null) }
            ACTION_PICK_AGAIN -> pickAgain()
            ACTION_SWITCH_CHANGE -> scope.launch { switchChange() }
        }
        begin()
        return START_STICKY
    }

    // MARK: (A4) the field log's ride lines (only "Share ride logs" reads them, when on)

    private fun vehicleText(s: RideState): String? {
        val leg = s.leg ?: return null
        val id = s.vehicleTripId ?: return null
        return FieldFormat.vehicle(s.vehicleLine ?: leg.line, id, leg.isTrain)
    }

    private fun logStart(how: String) {
        val s = RideStore.state.value ?: return
        val leg = s.leg ?: return
        val fix = fixes.lastOrNull()
        val loc = if (fix == null) nl.haltewekker.ui.Locator.lastFix(this) else null
        val here = fix?.p ?: loc?.let { GeoPoint(it.latitude, it.longitude) }
        val m = if (here != null && leg.from != null) Geo.metres(here, leg.from!!) else null
        // (A6) where you were when it started, for the leaderboard (a stale fix falls back to the first stop)
        if (here != null && s.startLat == null) {
            val at = fix?.t ?: (loc!!.time / 1000.0)
            RideStore.update(this) { it.copy(startLat = here.lat, startLon = here.lon, startFixAt = at) }
        }
        FieldLog.ride(FieldFormat.rideStart(how, vehicleText(s), m, s.index + 1, s.trip.rides.size))
        // (A6, iOS 0.34) the stop the trip was planned from, for "stops you prefer"
        if (s.index == 0) { nl.haltewekker.travel.HabitStore.load(this); nl.haltewekker.travel.HabitStore.update { it.plannedFrom(leg.fromStop) } }
    }

    private fun goForeground(looking: Boolean = false, watching: Boolean = false): Boolean {
        val n = if (watching) Notifications.watching(this, WaitStore.request.value?.destName)
            else if (looking) Notifications.looking(this) else Notifications.ride(this, RideStore.state.value)
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
        if (app.store.settings.value.motion) nl.haltewekker.motion.StepMotion.start(this)
        nl.haltewekker.travel.HabitStore.load(this)
        nl.haltewekker.travel.TravelLogStore.load(this)
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
        // (0.10.6, iOS 0.42.9 `RideAccuracy`) the rough tier: the network provider every 20 s (300 m), and the fixes
        // others ask for; the GPS chip only when there's no network provider (then once a minute)
        val reduced = ms == RideAccuracy.REDUCED_MS
        val minMetres = if (reduced) RideAccuracy.REDUCED_FILTER.toFloat() else if (ms > 5000) 75f else 0f
        try {
            val network = lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
            if (lm.isProviderEnabled(LocationManager.GPS_PROVIDER) && (!reduced || !network))
                lm.requestLocationUpdates(LocationManager.GPS_PROVIDER, ms, minMetres, listener, Looper.getMainLooper())
            if (network)
                lm.requestLocationUpdates(LocationManager.NETWORK_PROVIDER, if (reduced) 20_000L else maxOf(ms, 10_000L), minMetres, listener, Looper.getMainLooper())
            if (reduced) lm.requestLocationUpdates(LocationManager.PASSIVE_PROVIDER, 10_000L, 0f, listener, Looper.getMainLooper())
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
        // (A7) 4 minutes kept: the moment you left the stop and the stopping patterns look that far back
        while (fixes.isNotEmpty() && now - fixes.first().t > 240) fixes.removeFirst()
        nl.haltewekker.match.DepartMatch.moment(fixes.toList())?.let { d -> if (d.t > (departure?.t ?: 0.0)) departure = d }
        if (fix.speed >= 0) nl.haltewekker.travel.TravelNotes.heardSpeed(fix.t, fix.speed)
        noteChangeWalk(fix)
        val s = RideStore.state.value ?: return
        val leg = s.leg ?: return
        val to = leg.to ?: return
        val d = Geo.metres(fix.p, to)
        RideStore.update(this) { it.copy(distance = d, accuracy = fix.accuracy, speed = fix.speed.takeIf { v -> v >= 0 }, lastFixAt = now,
            lastLat = Math.round(fix.p.lat * 100_000) / 100_000.0, lastLon = Math.round(fix.p.lon * 100_000) / 100_000.0) }
        // (A6) a good fix: where you are, and the end of any reckoning
        if (DeadReckon.good(fix.accuracy)) {
            lastGood = fix
            if (reckonFrom != null || s.reckoning) {
                reckonFrom = null
                RideStore.update(this) { it.copy(reckoning = false) }
                FieldLog.ride("reckon · good GPS again: where you are")
            }
        }
        noteSpeed(fix)
        // (A6, iOS 0.33) the distance rule as it always was; by time also the time rule, whichever comes first
        // (`WakeRule`). (0.9.1, iOS 0.42.3 `ShortLeg`) within 20 s of the leg's start either one wakes it silently; a
        // short leg never rings (a quiet "Get off at the next stop" instead); nothing rings in a leg's first minute, a
        // normal leg rings at the next fix after it (`LegAlarm.fix`).
        val good = fix.accuracy >= 0 && fix.accuracy < WakeRules.GOOD_ACCURACY
        val age = now - s.legStart
        val fire = if (s.phase == Phase.SLEEPING && good) wakeFire(fix, d, s) else null
        val step = LegAlarm.fix(legOf(s), age, d, fix.accuracy, fire != null, legIsShort(s))
        if (step.leg.startedMetres != s.legStartMetres) RideStore.update(this) { it.copy(legStartMetres = step.leg.startedMetres) }
        when (step.act) {
            LegAlarm.Do.RING -> ring(WakeRule.log(fire!!), fire)
            LegAlarm.Do.WAKE_SHORT -> wakeQuietly(short = true, metres = d, after = age)
            LegAlarm.Do.WAKE_EARLY -> wakeQuietly(short = false, metres = d, after = age)
            LegAlarm.Do.HOLD -> rideLogOnce("ring-held|${s.index}", 120.0, FieldFormat.rideRingHeld(age, d))
            LegAlarm.Do.ARRIVE -> arrive()
            LegAlarm.Do.NOT_YET -> rideLogOnce("arrive-early|${s.index}", 60.0, "arrive · not yet: ${Math.round(d)} m from the stop of a short leg")
            else -> {}
        }
        RideStore.state.value?.let { if (it.phase == Phase.AWAKE && it.quietLeg) checkShortNotice(d, now) }
        // (0.9.1, iOS 0.42.3 `RideGuards.plannedNextAmong`) going away from this leg's stop: on the ride the next leg was
        // planned with? Then this leg is done and the next one starts on it.
        val cur0 = RideStore.state.value
        if (fix.accuracy >= 0 && fix.accuracy < 150 && cur0 != null && cur0.index == s.index) {
            legClosest = minOf(legClosest ?: d, d)
            val cur = cur0
            if (!awayLooked && cur.index + 1 < cur.trip.rides.size && cur.vehicleSource != VehicleSource.BY_HAND &&
                (cur.phase == Phase.SLEEPING || cur.phase == Phase.AWAKE) && LegAlarm.goingAway(legClosest, d) && LegAlarm.moving(fix.speed, fix.accuracy)) {
                awayLooked = true
                scope.launch { awayLook(cur.index) }
            }
        }
        // (A8, iOS 0.39) still ringing within 450 m of the stop: it got there before you reacted
        if (s.phase == Phase.ALARM && good && d <= 450) noteWakeOutcome(s, stopped = false)
        // (A6, iOS 0.32) Share GPS points during rides (when on): the trip's own fixes, nothing asked for
        nl.haltewekker.logs.LogShareStore.heard(fix.t, fix.p.lat, fix.p.lon, fix.accuracy, fix.speed, fix.course,
            nl.haltewekker.logs.GPSShareRules.leg(s.index, s.trip.rides.size), vehicleText(s))
        if (s.vehicleTripId != null) startReckon()
        noteWaitAnchor(fix)
        gpsTier(now)
        notifyRide(force = false)
    }

    /** (0.10.6, iOS 0.42.9) Where you stand, waiting for the next ride: a new spot once you move (iOS `TransferPolicy.update`). */
    private fun noteWaitAnchor(f: Fix) {
        if (!f.accuracy.isFinite() || f.accuracy < 0 || f.accuracy >= 150) return
        val a = waitAnchor
        val moving = f.speed.isFinite() && f.speed > 2.0 / 3.6
        if (a == null || moving || Geo.metres(a.first, f.p) > 60 + maxOf(0.0, f.accuracy - 50)) waitAnchor = f.p to f.t
    }

    /**
     * The GPS the ride asks for now, on each fix and on the ride's tick: rough far from the stop on a confirmed vehicle
     * (`RideAccuracy`: the network provider; else iOS RideGPS's fix every 25 s), or waiting for the next ride at a
     * change (`ChangeWait`); the best otherwise, at once.
     */
    private fun gpsTier(now: Double) {
        val cur = RideStore.state.value ?: return
        val leg = cur.leg ?: return
        val to = leg.to ?: return
        val fix = fixes.lastOrNull() ?: return
        val d = Geo.metres(fix.p, to)
        val st = app.store.settings.value
        val wakeMetres = WakeRule.gpsWakeMetres(cur.wakeMetres, WakeBookStore.effective(st.wake), leg.isTrain)
        val asleep = cur.phase == Phase.SLEEPING
        val byGPS = cur.vehicleSource == VehicleSource.BY_GPS
        // (the leg's age for the rough tier: from when the vehicle was found, so getting on keeps the best 2 minutes)
        if (cur.vehicleTripId != foundTrip) { foundTrip = cur.vehicleTripId; foundAt = now }
        val boardedAt = maxOf(cur.legStart, foundAt)
        val reduced = RideAccuracy.tier(RideAccuracy.Input(
            enabled = st.roughGPSOnLongRides, asleep = asleep, confirmed = byGPS && cur.choosing.isEmpty() && cur.wrongBus == null,
            // (Android has no "still the same one?" look that passes again and again: found by GPS counts as fresh)
            confirmedAge = if (byGPS) 0.0 else null, isTrain = leg.isTrain, metresToStop = d, accuracy = fix.accuracy,
            fixAge = now - fix.t, speed = fix.speed.takeIf { it >= 0 }, wakeMetres = wakeMetres,
            secondsToStop = cur.legArrival?.let { it - now }, legAge = now - boardedAt, wasReduced = cur.reducedGPS)) == RideAccuracy.Tier.REDUCED
        val far = !reduced && fix.accuracy >= 0 && fix.accuracy < RideGPS.GOOD_ACCURACY && RideGPS.far(RideGPS.Input(
            enabled = st.roughGPSOnLongRides, asleep = asleep,
            confirmed = byGPS || cur.vehicleSource == VehicleSource.BY_HAND,
            metresToStop = d, accuracy = fix.accuracy, fixAge = now - fix.t,
            // (A6) by time, the far tier keeps clear of the time rule's reach
            wakeMetres = wakeMetres, isTrain = leg.isTrain,
            speed = fix.speed.takeIf { it >= 0 }, secondsToStop = cur.legArrival?.let { it - now }, wasFar = cur.roughGPS))
        // waiting at a change for the next ride (no vehicle yet, after a leg): rough once you've stood 3 minutes
        val atChange = st.roughGPSOnLongRides && cur.index > (cur.firstLeg ?: 0) && cur.vehicleTripId == null && asleep
        val low = atChange && ChangeWait.low(waitAnchor?.let { now - it.second }, leg.departure - now,
            moving = fix.speed >= 2.0 && fix.accuracy in 0.0..150.0, inVehicle = false)
        if (reduced != cur.reducedGPS) FieldLog.ride(if (reduced) "gps · rough on a long ride, the vehicle confirmed: network location, every 300 m (${Math.round(d)} m from the stop)"
            else "gps · rough off: the best again (${Math.round(d)} m from the stop)")
        if (low != cur.changeLowGPS) FieldLog.ride(if (low) "gps · waiting at a change: network location until 3 min before the next one" else "gps · the best again at the change")
        if (far != cur.roughGPS || reduced != cur.reducedGPS || low != cur.changeLowGPS)
            RideStore.update(this) { it.copy(roughGPS = far, reducedGPS = reduced, changeLowGPS = low) }
        requestLocation(if (reduced || low) RideAccuracy.REDUCED_MS else RideGPS.intervalMs(far))
    }

    /** The ride's network on one clock: a look for the vehicle while it isn't known, the arrival once it is. */
    private suspend fun tickLoop() {
        while (scope.isActive) {
            val s = RideStore.state.value ?: break
            val leg = s.leg
            val now = Iso.now()
            if (leg != null && !s.finished) {
                if (s.vehicleTripId == null && s.phase == Phase.SLEEPING) {
                    // (A6, iOS 0.33) walking (the step detector) under 43 km/h isn't a vehicle, whatever the fixes say
                    val moving = nl.haltewekker.motion.MotionRules.movingLikeVehicle(OnBoardRules.movingByTrack(fixes.toList(), now),
                        if (app.store.settings.value.motion) nl.haltewekker.motion.StepMotion.now(now) else null, fixes.lastOrNull()?.speed?.takeIf { it >= 0 })
                    if (moving || fixes.size >= 3) {
                        val mine = fixes.toList()
                        val real = app.store.settings.value.realPositions
                        val dep = nl.haltewekker.match.DepartMatch.usable(departure, now)
                        val lines = nl.haltewekker.travel.HabitStore.book.value.lines
                        var f = withContext(Dispatchers.Default) { look.look(mine, leg, now, real, dep, lines) }
                        noteGPSRuns(look.lastJudged)
                        // (A7, iOS 0.39.1) never the planned one by its timetable alone long before (or long after) it leaves
                        if (f != null && !f.live && f.tripId == leg.tripId && !TimetableStart.allowed(now, leg.departure)) {
                            if (now - waitLogged >= 60) {
                                waitLogged = now
                                FieldLog.match(TimetableStart.waitLine(FieldFormat.vehicle(leg.line, leg.tripId, leg.isTrain), Notifications.time(leg.departure), ((leg.departure - now) / 60).toInt()))
                            }
                            f = null
                        }
                        // (0.9.1, iOS 0.42.3) the next leg's planned ride, with you by its own GPS: you're on the next leg
                        if (f != null && f.byGPS && LegAlarm.onRoad(listOf(f.tripId), null, s.trip.rides.getOrNull(s.index + 1)?.tripId, leg.tripId) is LegAlarm.Road.NextLeg) {
                            boardedPlannedNext(f.tripId, f.line, f.isTrain, "found on board")
                            f = null
                        }
                        if (f != null) {
                            RideStore.update(this) {
                                it.copy(vehicleTripId = f.tripId, vehicleLine = f.line,
                                    vehicleSource = if (f.byGPS || moving) VehicleSource.BY_GPS else VehicleSource.BY_TIMES)
                            }
                            FieldLog.match(FieldFormat.detect(mine.size, "${f.line}·${f.tripId.takeLast(4)}", f.byGPS, f.tripId == leg.tripId))
                            RideStore.state.value?.let { cur -> noteBoarding(cur, f.tripId, mine) }
                            // (0.10.3, iOS 0.42.4) got on a stop or two before the planned one: the leg starts there
                            run { val ff = f; scope.launch { try { boardedHere(ff.tripId, ff.line, ff.isTrain) } catch (_: Exception) {} } }
                            // (A7) others that fit about as well: keep choosing between them (iOS `beginChoosing`)
                            if (f.others.isNotEmpty()) beginChoosing(listOf(RideChoice.Cand(f.tripId, f.line, f.isTrain)) + f.others)
                            else scope.launch { afterFound(f.tripId, split = false) }
                        }
                    }
                }
                // (A7) on a confirmed train: the other trains on your track, by their own NS positions, every 2 minutes
                rivalsLook(now)
                // (A7) waiting for a bus: another line's bus at your stop
                checkOtherAtStop(now)
                // (A7, iOS 0.39.1) on another line than planned: is its own GPS with you (the wrong bus)?
                wrongBusLook(now)
                val v = RideStore.state.value?.vehicleTripId ?: leg.tripId
                // (0.10.6, iOS 0.42.9 `RideNet`) its live times every 2 minutes far from the stop, every 45 s near it
                val tripEvery = RideStore.state.value?.let { cur ->
                    RideNet.tripEvery(RideNet.near(cur.legArrival?.let { it - now }, cur.distance,
                        WakeRule.gpsWakeMetres(cur.wakeMetres, WakeBookStore.effective(app.store.settings.value.wake), leg.isTrain), cur.phase != Phase.SLEEPING))
                } ?: 60.0
                if (now - etaAt >= tripEvery && leg.to != null) {
                    etaAt = now
                    val cur0 = RideStore.state.value
                    // (A8, iOS 0.39 `RideCache`) no answer: the stops and times saved on the phone when the trip started
                    val w = look.wakeTrip(v, leg.from, leg.to!!, fixes.lastOrNull()?.p, now) { id -> RideCacheStore.live(id, cur0?.startedAt, now) }
                    val offline = w == null || w.saved
                    if (cur0 != null && cur0.offline != offline) {
                        FieldLog.ride(if (offline) "offline · going by the stops and times saved on the phone" else "online · asking again")
                        RideStore.update(this) { it.copy(offline = offline) }
                    }
                    if (w != null) {
                        wakeRoute = w.route
                        wakeLive = w.arrival?.takeIf { w.live && !w.saved }?.let { it to Iso.now() }
                        RideStore.update(this) { it.copy(eta = w.arrival ?: it.eta, nextStop = w.nextStop, delayMin = w.delayMin) }
                        wakeBeforeAt = w.beforeAt
                        checkGetReady(w, now)
                        if (!w.saved && w.trip != null) RideStore.state.value?.let { st -> if (RideCacheStore.due(v, now)) RideCacheStore.put(this, v, w.trip, st.startedAt, now) }
                    }
                    saveRidesAhead(now)
                    updateChangeGuide(now)
                    // (0.10.1) every train of the trip: a new platform or a cancelled train, told at once
                    scope.launch { platformLook(now) }
                    scheduleBackup()
                }
                gpsTier(now)                    // (0.10.6: time brings the stop, or the next ride, near without a fix)
                notifyRide(force = false)
                // (A3) the ride's network tick: friends get your trip (and their trips and lines come in), no loop of its own
                nl.haltewekker.friends.FriendTravelShare.tick(applicationContext)
            }
            delay(if (RideStore.state.value?.vehicleTripId == null) 15_000 else 30_000)
        }
    }

    private fun ring(why: String, fire: WakeRule.Fire? = null) {
        val s = RideStore.state.value ?: return
        if (s.phase != Phase.SLEEPING) return
        val st = app.store.settings.value
        val quiet = WakeRules.quiet(st.headphonesOnly, AudioRoute.privateOutput(this))
        val leg = s.leg
        FieldLog.ride(FieldFormat.rideRing(why, s.distance, Iso.now() - s.legStart, s.legStartMetres ?: startMetres(s)))
        val minutes = (fire as? WakeRule.Fire.Time)?.minutes
        RideStore.update(this) { it.copy(phase = Phase.ALARM, quiet = quiet, note = null, roughGPS = false, reducedGPS = false, changeLowGPS = false, ringMinutes = minutes, rangAt = Iso.now(), againSent = false, wakeNoted = false) }
        stopReckon()
        cancelBackup()
        requestLocation(RideGPS.intervalMs(false))
        AlarmPlayer.ring(this, if (st.announce && leg != null) WakeRules.announcement(leg.toStop, leg.isTrain, true) else null, quiet)
        RideStore.state.value?.let { Notifications.post(this, Notifications.ALARM_ID, Notifications.alarm(this, it, backup = why.startsWith("backup")), WristNotice.ALARM_ID) }
        scope.launch { delay((WristNotice.AGAIN_AFTER * 1000).toLong() + 500); ringAgain() }
        notifyRide(force = true)
    }

    /** (A7, iOS 0.37.1) the one repeat, 30 s after it rang while it still rings ("Still ringing: …"). */
    private fun ringAgain() {
        val s = RideStore.state.value ?: return
        val at = s.rangAt ?: return
        if (!WristNotice.againDue(at, Iso.now(), s.phase == Phase.ALARM, s.againSent)) return
        RideStore.update(this) { it.copy(againSent = true) }
        Notifications.post(this, Notifications.ALARM_ID, Notifications.alarm(this, s.copy(ringMinutes = WristNotice.secsAtAgain(s.ringMinutes?.times(60.0))?.let { kotlin.math.ceil(it / 60).toInt() }), again = true), WristNotice.AGAIN_ID)
    }

    private fun stopAlarm() {
        AlarmPlayer.stop(this)
        Notifications.cancel(this, Notifications.ALARM_ID)
        Notifications.cancelTag(this, WristNotice.ALARM_ID, Notifications.ALARM_ID)
        Notifications.cancelTag(this, WristNotice.AGAIN_ID, Notifications.ALARM_ID)
        val s = RideStore.state.value ?: return
        if (s.phase != Phase.ALARM) return
        noteWakeOutcome(s, stopped = true)
        if (app.store.settings.value.ringAtStop) RideStore.update(this) { it.copy(phase = Phase.AWAKE) } else legDone()
        notifyRide(force = true)
    }

    private fun arrive() {
        val s = RideStore.state.value ?: return
        val leg = s.leg ?: return
        val st = app.store.settings.value
        val next = s.trip.rides.getOrNull(s.index + 1)
        FieldLog.ride(FieldFormat.rideArrive(if (s.quietLeg) "by GPS, quietly" else "by GPS", s.distance, s.accuracy, Iso.now() - s.legStart, s.legStartMetres))
        legDone()
        val quiet = WakeRules.quiet(st.headphonesOnly, AudioRoute.privateOutput(this))
        AlarmPlayer.chime(this, if (st.announce) WakeRules.announcement(leg.toStop, leg.isTrain, false) else null, quiet)
        Notifications.arrived(this, leg.toStop, s = s, then = next?.let {
            "Next: ${if (it.isTrain) it.line else "bus ${it.line}"} at ${Notifications.time(it.departure)} from ${it.fromStop}" +
                (it.platform?.let { p -> ", platform $p" } ?: "")
        } ?: "Get off here: your trip is done.")
    }

    private fun legDone() {
        val s0 = RideStore.state.value ?: return
        val now = Iso.now()
        // (A6, iOS 0.35) how late this ride got you to its stop, for the leaderboard's "the 305 was 18 min late"
        s0.leg?.let { l -> noteLegDone(s0, l, now) }
        s0.leg?.let { l ->
            val lateMin = (minOf(now, s0.legArrival ?: now) - l.scheduledArrival) / 60
            if (lateMin >= 1 && lateMin <= 600) {
                val line = if (l.isTrain) nl.haltewekker.friends.TransitLabel.train(s0.vehicleLine ?: l.line, l.name) else (s0.vehicleLine ?: l.line)
                val had = s0.lateLine?.let { ln -> s0.lateMins?.let { ln to it } }
                val w = nl.haltewekker.friends.ScoreRules.worse(had, line to Math.round(lateMin * 10) / 10.0)
                RideStore.update(this) { it.copy(lateLine = w.first, lateMins = w.second) }
            }
        }
        // (A7, iOS 0.38/0.39.1) a ride it found by itself, ridden to the leg's end: your usual line, only the planned line
        s0.leg?.let { l ->
            val line = s0.vehicleLine ?: l.line
            if (s0.vehicleTripId != null && (s0.vehicleSource == VehicleSource.BY_GPS || s0.vehicleSource == VehicleSource.BY_TIMES) &&
                now - s0.legStart >= 120 && nl.haltewekker.match.UsualLine.learnsFound(line, l.isTrain, l.line, l.isTrain)) learnLine(line, l.isTrain, l.departure, nl.haltewekker.match.UsualLine.CONFIRMED)
        }
        choice.clear(); chooseJob?.cancel(); chooseJob = null
        Notifications.cancelTag(this, Notifications.ASK_TAG, Notifications.NEWS_ID + 3)
        gpsRuns = emptyMap(); rivalAt = 0.0; departure = null
        RideStore.update(this) { it.copy(choosing = emptyList(), ask = null, otherAtStop = null, wrongBus = null, readyTold = false, nextStop = null, delayMin = null) }
        val s = RideStore.state.value ?: return
        look.reset()
        etaAt = 0.0
        resetLegWake()
        if (s.index + 1 < s.trip.rides.size) {
            RideStore.update(this) {
                it.copy(index = it.index + 1, phase = Phase.SLEEPING, legStart = now, vehicleTripId = null, vehicleLine = null,
                    vehicleSource = VehicleSource.NONE, eta = null, distance = null, quiet = false, note = null, roughGPS = false, reducedGPS = false, changeLowGPS = false,
                    ringMinutes = null, reckoning = false, changeArrived = now, changeFromVehicle = s.vehicleTripId, quietLeg = false, legStartMetres = null)
            }
            requestLocation(RideGPS.intervalMs(false))
            waitAnchor = null                   // (0.10.6) standing at the change counts from here
            scheduleBackup()
        } else {
            RideStore.update(this) { it.copy(phase = Phase.FINISHED) }
            // (A4) a trip from Home to School (or back) on your own board, for the leaderboard with friends
            RideStore.state.value?.let { nl.haltewekker.friends.ScoreLog.finished(this, it, now); delayClaim(it) }
            cancelBackup()
            scope.launch { delay(90_000); if (RideStore.state.value?.finished == true) end(byHand = false) }
        }
        notifyRide(force = true)
    }

    private fun onIt() {
        val s0 = RideStore.state.value ?: return
        val leg = s0.leg ?: return
        FieldLog.ride(FieldFormat.handPick(FieldFormat.vehicle(leg.line, leg.tripId, leg.isTrain), vehicleText(s0), s0.distance, null))
        handPicked(leg.tripId, leg.line, leg.isTrain)
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

    private fun end(byHand: Boolean) {
        RideStore.state.value?.let { s -> FieldLog.ride(FieldFormat.rideEnd(if (s.finished) "after the last stop" else if (byHand) "by hand" else "by itself")) }
        FieldLog.flush()
        RideStore.state.value?.let { s ->
            AutoStart.noteEnd(this, fixes.lastOrNull()?.p ?: if (s.finished) s.trip.last.to else null)
            if (byHand && !s.finished) {
                // not started again by itself; offered to go on with while you're on the way (TripResume)
                AutoStart.block(this, listOfNotNull(s.vehicleTripId, s.leg?.tripId))
                val atChange = s.index > 0 && s.vehicleSource == VehicleSource.NONE && s.phase == Phase.SLEEPING
                TripResume.leg(atChange, false, if (atChange) s.index - 1 else s.index, s.trip.rides.size)?.let {
                    ResumeStore.set(this, ResumeOffer(s.trip, s.destination, it, Iso.now(), s.startedAt, s.firstLeg, s.startLat, s.startLon, s.startFixAt))
                }
            }
        }
        AlarmPlayer.stop(this)
        cancelBackup()
        Notifications.cancel(this, Notifications.ALARM_ID)
        Notifications.cancelTag(this, WristNotice.ALARM_ID, Notifications.ALARM_ID)
        Notifications.cancelTag(this, WristNotice.AGAIN_ID, Notifications.ALARM_ID)
        Notifications.cancelTag(this, Notifications.ASK_TAG, Notifications.NEWS_ID + 3)
        choice.clear(); chooseJob?.cancel()
        RideCacheStore.clear(this)
        RideStore.set(this, null)
        stopRide()
    }

    private fun stopRide() {
        if (watch.watching) stopWatch("stopped")
        tick?.cancel()
        PlatformWatch.clear()
        stopReckon()
        nl.haltewekker.motion.StepMotion.stop()
        try { lm.removeUpdates(listener) } catch (_: Exception) {}
        intervalMs = 0
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    /** (0.10.1) `PlatformWatch`: quiet while you sleep on the ride, with sound when you're awake; the trip gets the new platform. */
    private suspend fun platformLook(now: Double) {
        val s = RideStore.state.value ?: return
        val codes = nl.haltewekker.friends.NSCodes.get(this)
        PlatformWatch.tick(s, now, { r -> codes.code(r.fromId, r.fromStop) }, { Notifications.time(it) }) { a ->
            val sleeping = RideStore.state.value?.phase == Phase.SLEEPING
            PlatformWatch.post(this, a, quiet = sleeping)
            FieldLog.ride(if (a.cancelled) "a train of the trip is cancelled · told" else "a train's platform changed · told" + if (sleeping) " quietly" else "")
            RideStore.update(this) { it.copy(trip = PlatformWatch.applied(it.trip, a), platformNote = "${a.title}: ${a.body}") }
            notifyRide(force = true)
        }
    }

    /**
     * The ongoing notification, again (0.10.6, iOS 0.42.9 `ActivityCadence`): what it says (the phase, the change
     * miss) at once; a meaningful change (the arrival minute, the next stop, the delay, the vehicle, the change line)
     * at most once a minute far from the stop; the distance alone every 3 minutes; anything every 20 s in the last 5
     * minutes. A change held back goes later by itself.
     */
    private fun notifyRide(force: Boolean) {
        val s = RideStore.state.value
        val now = Iso.now()
        val say = "${s?.phase}|${s?.index}|${s?.changeMiss}|${s?.platformNote}"
        val key = "${ActivityCadence.minute(s?.legArrival)}|${s?.nextStop}|${s?.delayMin}|${s?.vehicleLine}|${s?.changeLine}|${s?.offline}|${s?.reckoning}|${s?.changeSwitch != null}"
        val look = "${s?.distance?.let { WakeRules.distanceText(it) }}"
        val near = ActivityCadence.near(s?.legArrival?.let { it - now }, s?.phase != Phase.SLEEPING)
        val change = if (force || s?.phase != lastPhase) ActivityCadence.Change.SAY
            else ActivityCadence.change(say != shownSay, key != shownKey, look != shownLook)
        if (!ActivityCadence.send(change, near, now - lastNotify)) {
            ActivityCadence.later(change, near, now - lastNotify)?.let { after ->
                if (notifyLater?.isActive != true) notifyLater = scope.launch { delay((after * 1000).toLong()); notifyLater = null; notifyRide(force = false) }
            }
            return
        }
        notifyLater?.cancel(); notifyLater = null
        lastNotify = now; lastPhase = s?.phase; shownSay = say; shownKey = key; shownLook = look
        Notifications.post(this, Notifications.RIDE_ID, Notifications.ride(this, s))
    }

    // MARK: (A6) what a leg leaves behind: the kept ride, the check-out reminder, the habits, money back

    /** Fixes since you got off at a change (for the change time and your walking speed). */
    private val changeFixes = ArrayList<Fix>()

    private fun noteChangeWalk(f: Fix) {
        val s = RideStore.state.value ?: return
        val arrived = s.changeArrived ?: return
        if (s.vehicleTripId != null || changeFixes.size > 600) return
        changeFixes.add(f)
        val from = s.leg?.from ?: return
        nl.haltewekker.travel.Habits.changeMinutes(arrived, changeFixes, from)?.let { m ->
            nl.haltewekker.travel.HabitStore.update { it.addChange(m) }
            RideStore.update(this) { it.copy(changeArrived = null) }
        }
    }

    private fun noteLegDone(s: RideState, l: nl.haltewekker.data.Ride, now: Double) {
        val st = app.store.settings.value
        val lateMin = (minOf(now, s.legArrival ?: now) - l.scheduledArrival) / 60
        // the ride kept for Your year in travel (on this phone only)
        val dep = if (l.departure <= now) l.departure else s.legStart
        val metres = if (l.from != null && l.to != null) Geo.metres(l.from!!, l.to!!) else 0.0
        val label = if (l.isTrain) l.name.ifEmpty { l.line } else "Bus ${s.vehicleLine ?: l.line}"
        val coach = if (l.isTrain) nl.haltewekker.friends.FriendTravelShare.coach.value?.n else null
        nl.haltewekker.travel.TravelLogStore.add(this, nl.haltewekker.travel.RideRecord("${(dep).toLong()}|${s.vehicleTripId ?: l.tripId}",
            s.startedAt, dep, now, l.isTrain, label, l.fromStop, l.toStop, nl.haltewekker.travel.TravelYear.km(metres, l.isTrain),
            lateMin.takeIf { it >= 0 && it <= 600 }?.let { Math.round(it * 10) / 10.0 }, coach))
        // the trains' lateness, for money back
        if (l.isTrain) RideStore.update(this) { it.copy(trainLates = it.trainLates + lateMin, trainEndPlanned = l.scheduledArrival, trainEndActual = now) }
        // "Did you check out?" a minute after getting off, where the card wants it (iOS 0.36)
        if (st.checkOut) {
            val rides = s.trip.rides.map { nl.haltewekker.travel.CheckOut.Ride(it.isTrain, it.agency) }
            if (nl.haltewekker.travel.CheckOut.due(s.index, rides)) {
                val next = s.trip.rides.getOrNull(s.index + 1)
                val off = s.vehicleTripId
                nl.haltewekker.travel.TravelNotes.checkOutLater(this, l.toStop, next?.let { l.isTrain to it.isTrain }) {
                    off != null && RideStore.state.value?.vehicleTripId == off
                }
            }
        }
        changeFixes.clear()
    }

    /** The one you got on, found: where you got on, how fast you walked there, and whether you made the change. */
    private fun noteBoarding(s: RideState, tripId: String, mine: List<Fix>) {
        val leg = s.leg ?: return
        val here = mine.lastOrNull()?.p
        if (s.index == 0 && here != null && leg.from != null && Geo.metres(here, leg.from!!) <= 300)
            nl.haltewekker.travel.HabitStore.update { it.boarded(leg.fromStop) }
        nl.haltewekker.travel.Habits.walkSpeed(changeFixes.ifEmpty { mine })?.let { v -> nl.haltewekker.travel.HabitStore.update { it.addWalk(v) } }
        if (s.index > 0) {
            val prev = s.trip.rides[s.index - 1]
            scope.launch {
                val dep = if (tripId == leg.tripId) null else leg.from?.let { look.departureNear(tripId, it) }
                nl.haltewekker.travel.ChangeOdds.made(leg.tripId, leg.departure, tripId, dep)?.let { made ->
                    nl.haltewekker.travel.HabitStore.recordChange(prev.line, leg.line, leg.fromStop, leg.departure, made)
                    FieldLog.ride("change · ${if (made) "made it" else "missed it"} · ${prev.line} → ${leg.line} at ${leg.fromStop}")
                }
            }
        }
    }

    /** Money back for a late train (iOS 0.36), once, after the trip. */
    private fun delayClaim(s: RideState) {
        if (!app.store.settings.value.delayClaim || s.trainLates.isEmpty()) return
        val m = nl.haltewekker.travel.DelayClaim.minutesLate(s.trainEndPlanned, s.trainEndActual, s.trainLates)
        if (!nl.haltewekker.travel.DelayClaim.due(m, told = false) || m == null) return
        val (t, b) = nl.haltewekker.travel.DelayClaim.text(m)
        Notifications.link(this, "delayclaim", t, b, nl.haltewekker.travel.DelayClaim.CLAIM_URL)
    }

    // MARK: (A6, iOS 0.33) wake by time; (iOS 0.34) dead reckoning

    private fun resetLegWake() {
        smoother.reset(); lastSpeedFix = null; wakeLive = null; wakeRoute = emptyList()
        lastGood = null; stopReckon()
        legClosest = null; awayLooked = false; wakeBeforeAt = null
    }

    // MARK: (0.9.1, iOS 0.42.3) short legs, the first minute, the next leg's planned ride

    private var legClosest: Double? = null                     // the nearest this leg has been to its stop (150 m fixes)
    private var awayLooked = false                             // going away: looked at what's on your road this stretch
    private var wakeBeforeAt: Double? = null                   // the stop before yours, by its times (the vehicle's trip)
    private val logged = HashMap<String, Double>()

    private fun rideLogOnce(key: String, every: Double, text: String) {
        val now = Iso.now()
        logged[key]?.let { if (now - it < every) return }
        if (logged.size > 60) logged.entries.removeAll { now - it.value >= 600 }
        logged[key] = now
        FieldLog.ride(text)
    }

    private fun legOf(s: RideState) = LegAlarm.Leg(s.phase, s.quietLeg, s.readyTold, s.legStartMetres)

    /** This leg is shorter than its wake distance (or 800 m): it never rings (`ShortLeg.isShort`). */
    private fun legIsShort(s: RideState): Boolean = ShortLeg.isShort(LegAlarm.span(s.leg?.from, s.leg?.to), s.wakeMetres)

    /** Awake without the alarm: a short leg (the quiet word comes later), or one that started inside its wake distance. */
    private fun wakeQuietly(short: Boolean, metres: Double, after: Double?) {
        val s = RideStore.state.value ?: return
        if (s.phase != Phase.SLEEPING) return
        FieldLog.ride(if (short) FieldFormat.rideShort(LegAlarm.span(s.leg?.from, s.leg?.to), s.wakeMetres, after) else FieldFormat.rideWake(metres, after))
        RideStore.update(this) { it.copy(phase = Phase.AWAKE, quietLeg = true,
            note = if (short) "A short ride: a quiet word before your stop, no alarm." else "You started close to your stop: it tells you when you're there.") }
        cancelBackup()
        notifyRide(force = true)
    }

    /** (iOS `checkShortNotice`) a quiet leg's "Get off at the next stop": once a leg, not in its first minute. */
    private fun checkShortNotice(d: Double, now: Double) {
        val s = RideStore.state.value ?: return
        val leg = s.leg ?: return
        val step = LegAlarm.notice(legOf(s), now - s.legStart, LegAlarm.beforeReached(wakeBeforeAt, now), s.legArrival?.let { it - now }, d)
        if (step.act != LegAlarm.Do.NOTICE) return
        RideStore.update(this) { it.copy(readyTold = true) }
        val (t, b) = ShortLeg.words(WristNotice.stop(leg.toStop))
        rideLogOnce("short-ready|${s.index}", 600.0, "get ready · short leg: get off at the next stop (${Math.round(d)} m, leg ${Math.round(now - s.legStart)} s old)")
        Notifications.quiet(this, GetReady.id(s.startedAt, s.index), t, b, s)
        notifyRide(force = true)
    }

    /**
     * (iOS `wrongWay`'s first checks) going away from this leg's stop: the vehicles on your road. The one you're on
     * among them: carry on. The ride the next leg was planned with: this leg is done, the next starts on it. Else it
     * looks again after another stretch (Android plans nothing again from it).
     */
    private suspend fun awayLook(index: Int) {
        val s = RideStore.state.value ?: return
        if (s.index != index) return
        val next = s.trip.rides.getOrNull(index + 1) ?: return
        val now = Iso.now()
        val l = OnBoardLook()
        try { withContext(Dispatchers.Default) { l.look(fixes.toList(), next, now, app.store.settings.value.realPositions) } } catch (_: Exception) {}
        val found = l.lastJudged.filter { it.cost != null }.map { it.id }
        val cur = RideStore.state.value ?: return
        if (cur.index != index) return
        when (val r = LegAlarm.onRoad(found, cur.vehicleTripId, next.tripId, cur.leg?.tripId)) {
            is LegAlarm.Road.NextLeg -> boardedPlannedNext(r.tripId, l.lastLines[r.tripId] ?: next.line, next.isTrain, "on its road")
            LegAlarm.Road.CarryOn -> { legClosest = cur.distance; awayLooked = false }
            LegAlarm.Road.Nothing -> {
                rideLogOnce("away|$index", 300.0, "away · going away from this leg's stop · ${found.size} on your road, not the next leg's planned ride: looks again later")
                legClosest = cur.distance; awayLooked = false
            }
        }
    }

    /**
     * (iOS 0.42.3 `boardedPlannedNext`) on the ride the next leg was planned with without this leg ending (a short hop
     * to the station, its stop never reached by GPS): this leg is done and the next one starts on it ("next leg"), its
     * alarm armed, the plan kept, nothing to pick.
     */
    private fun boardedPlannedNext(tripId: String, line: String, isTrain: Boolean, why: String) {
        val s = RideStore.state.value ?: return
        if (!(s.phase == Phase.SLEEPING || s.phase == Phase.AWAKE) || s.index + 1 >= s.trip.rides.size) return
        val now = Iso.now()
        val label = FieldFormat.vehicle(line, tripId, isTrain)
        rideLogOnce("on-next|${s.index}", 120.0, "arrive · already on the next leg's $label ($why): this leg is done")
        FieldLog.ride(FieldFormat.rideArrive("on the next leg's ride", s.distance, s.accuracy, now - s.legStart, s.legStartMetres))
        legDone()
        val cur = RideStore.state.value ?: return
        if (cur.index != s.index + 1) return
        RideStore.update(this) { it.copy(vehicleTripId = tripId, vehicleLine = line, vehicleSource = VehicleSource.BY_GPS, changeArrived = null) }
        val leg = cur.leg
        val here = fixes.lastOrNull()?.p
        FieldLog.ride(FieldFormat.rideStart("next leg (its planned ride, $why)", label, if (here != null && leg?.to != null) Geo.metres(here, leg.to!!) else null,
            cur.index + 1, cur.trip.rides.size))
        RideStore.state.value?.let { noteBoarding(it, tripId, fixes.toList()) }
        etaAt = 0.0
        scope.launch { afterFound(tripId, split = false) }
        notifyRide(force = true)
    }

    private fun startMetres(s: RideState): Double? {
        val here = lastGood?.p ?: fixes.lastOrNull()?.p ?: return null
        return s.leg?.from?.let { Geo.metres(here, it) }
    }

    /** Your speed for the time rule, from a good fix (`SpeedSmoother`). */
    private fun noteSpeed(f: Fix) {
        if (f.accuracy < 0 || f.accuracy >= 100) return
        SpeedSmoother.reading(f, lastSpeedFix)?.let { smoother.add(it, f.t) }
        lastSpeedFix = f
    }

    private fun wakeInput(s: RideState, metres: Double, route: Double?, speed: Double?, now: Double): WakeRule.Input? {
        val leg = s.leg ?: return null
        // (A8, iOS 0.39) your setting with what the adaptive wake-up learned on top (never later than you set it)
        val w = WakeBookStore.effective(app.store.settings.value.wake)
        val here = lastGood?.p ?: fixes.lastOrNull()?.p
        return WakeRule.Input(by = w.by, minutes = w.minutes(leg.isTrain), isTrain = leg.isTrain, metres = metres, routeMetres = route,
            wakeMetres = s.wakeMetres, liveArrival = wakeLive?.first, liveAge = wakeLive?.let { now - it.second }, speed = speed,
            fromStartMetres = if (here != null && leg.from != null) Geo.metres(here, leg.from!!) else null, now = now)
    }

    /** What rings this leg now, from a good fix `d` metres from its stop (`WakeRule.decide`; null: nothing yet). */
    private fun wakeFire(f: Fix, d: Double, s: RideState): WakeRule.Fire? {
        val now = Iso.now()
        val i = wakeInput(s, d, RouteLeft.metres(f.p, wakeRoute), smoother.speed(f.t), now) ?: return null
        return WakeRule.decide(i)
    }

    private fun startReckon() {
        if (reckonJob?.isActive == true) return
        reckonJob = scope.launch {
            while (isActive) {
                delay((DeadReckon.EVERY * 1000).toLong())
                reckonStep()
            }
        }
    }

    private fun stopReckon() {
        reckonJob?.cancel(); reckonJob = null
        reckonFrom = null
    }

    /**
     * No good fix for 15 s on a ride with its vehicle known (a tunnel, a dead zone): the place goes on along the
     * vehicle's route from your last good fix at its pace (the distance left over the time to its arrival, else your
     * last speed). Only the time rule may ring on it (`DeadReckon.mayRing`). A good fix ends it (`onLocation`).
     */
    private suspend fun vehicleFixAlong(tripId: String?, leg: nl.haltewekker.data.Ride, route: List<GeoPoint>, now: Double, pace: Double?): Double? {
        if (tripId == null || !app.store.settings.value.realPositions) return null
        val f = try {
            if (leg.isTrain) RealPositions.trainNumber(leg.num)?.let { n -> LiveFeeds.trainFixes()[n] }?.let { RealPositions.usable(it, tripId, now, 120.0) }
            else RealPositions.usable(LiveFeeds.busFixes(), tripId, now, 120.0)
        } catch (_: Exception) { null } ?: return null
        val pr = Geo.project(f.point, route) ?: return null
        if (pr.crossTrack > 150) return null
        val v = f.speed?.takeIf { it.isFinite() && it >= 0 } ?: pace ?: 0.0
        return pr.along + minOf(WakeRule.top(leg.isTrain), v) * minOf(120.0, maxOf(0.0, now - f.at))
    }

    private suspend fun reckonStep() {
        val s = RideStore.state.value ?: run { stopReckon(); return }
        val leg = s.leg ?: return
        if (s.vehicleTripId == null || !(s.phase == Phase.SLEEPING || s.phase == Phase.AWAKE)) { stopReckon(); return }
        val now = Iso.now()
        val g = lastGood ?: return
        val route = wakeRoute.takeIf { it.size >= 2 } ?: listOfNotNull(leg.from, leg.to).takeIf { it.size == 2 } ?: return
        if (!DeadReckon.needed(g.t, now)) return
        val end = Geo.length(route)
        if (reckonFrom == null) {
            val pr = Geo.project(g.p, route) ?: return
            if (pr.crossTrack > RouteLeft.OFF_ROUTE) return
            reckonFrom = pr.along to g.t
            RideStore.update(this) { it.copy(reckoning = true) }
            FieldLog.ride("reckon · no good GPS for ${(now - g.t).toInt()} s · on along its route")
        }
        val from = reckonFrom ?: return
        val pace = DeadReckon.pace(end - from.first, s.legArrival, from.second, smoother.speed(g.t) ?: g.speed.takeIf { it >= 0 }, leg.isTrain)
        // (A7) the vehicle's own fresh GPS (≤ 2 min old), on its road and moved on at its pace, before your own pace
        val gpsAlong = vehicleFixAlong(s.vehicleTripId, leg, route, now, pace)
        val e = DeadReckon.along(from.first, from.second, now, pace, gpsAlong, null, end, leg.isTrain)
        val at = Geo.pointAtMetres(e.metres, route) ?: return
        val to = leg.to ?: return
        val d = Geo.metres(at, to)
        RideStore.update(this) { it.copy(distance = d) }
        // (0.9.1, iOS 0.42.3) not in the leg's first minute; a short leg wakes quietly (`LegAlarm.reckoned`)
        if (s.phase == Phase.SLEEPING && now - s.legStart >= ShortLeg.NO_RING_FOR) {
            val i = wakeInput(s, d, maxOf(0.0, end - e.metres), pace, now) ?: return
            val fire = DeadReckon.decide(i)
            val step = LegAlarm.reckoned(legOf(s), now - s.legStart, DeadReckon.mayRing(fire, deadReckoned = true) && fire != null, legIsShort(s))
            when (step.act) {
                LegAlarm.Do.RING -> { ring("reckoned (${e.source.raw}) · " + WakeRule.log(fire!!), fire); return }
                LegAlarm.Do.WAKE_SHORT -> { wakeQuietly(short = true, metres = d, after = null); return }
                else -> {}
            }
        }
        notifyRide(force = false)
    }

    /** (A8, iOS 0.39 `AdaptiveWake`) one ring before the stop, as it went: ring → Stop alarm, ring → at the stop. Once a leg. */
    private fun noteWakeOutcome(s: RideState, stopped: Boolean) {
        val at = s.rangAt ?: return
        if (s.wakeNoted) return
        val leg = s.leg ?: return
        val now = Iso.now()
        val lead = if (stopped) maxOf(now, s.legArrival ?: now) - at else now - at
        RideStore.update(this) { it.copy(wakeNoted = true) }
        if (!WakeBookStore.book.value.on) return
        val moved = WakeBookStore.add(WakeSample(leg.isTrain, if (stopped) now - at else null, lead, now))
        FieldLog.ride("wake learned · ${if (stopped) "stopped after ${Math.round(now - at)} s" else "still ringing at the stop"} · lead ${Math.round(lead)} s" +
            if (moved) " · now ${WakeBookStore.book.value.extra(leg.isTrain)} min earlier" else "")
    }

    // MARK: (A8, iOS 0.39) get ready, the saved rides, the change guide

    /** The quiet "Get ready" once the vehicle is at the stop before yours, before the alarm rang (`GetReady`). */
    private fun checkGetReady(w: OnBoardLook.WakeTrip, now: Double) {
        val s = RideStore.state.value ?: return
        val leg = s.leg ?: return
        val wake = WakeBookStore.effective(app.store.settings.value.wake)
        val within = if (wake.by == WakeBy.TIME) wake.minutes(leg.isTrain) * 60.0 else 0.0
        if (!GetReady.due(w.beforeAt, w.arrival, now, within, s.phase == Phase.SLEEPING, s.readyTold)) return
        RideStore.update(this) { it.copy(readyTold = true) }
        val (t, b) = GetReady.words(leg.toStop, w.arrival?.let { it - now })
        FieldLog.ride("get ready · at ${w.before ?: "the stop before yours"} · ${leg.toStop} next")
        Notifications.quiet(this, GetReady.id(s.startedAt, s.index), t, b, s)
    }

    /** Each planned ride's trip answer saved on the phone (at most every 2 minutes a ride, 4 rides). */
    private suspend fun saveRidesAhead(now: Double) {
        val s = RideStore.state.value ?: return
        for (r in s.trip.rides.drop(s.index).take(RideCache.MAX_RIDES)) {
            if (!RideCacheStore.due(r.tripId, now)) continue
            val t = try { Transit.trip(r.tripId, maxAge = 60.0) } catch (_: Exception) { null } ?: continue
            RideCacheStore.put(this, r.tripId, t, s.startedAt, now)
        }
    }

    private var changeBoard: Triple<String, Double, List<nl.haltewekker.data.BoardDeparture>>? = null

    /**
     * The change ahead (`ChangeGuide`, 0.39.1 `MissRule`): "Platform 5 → 7 · 3 min walk", "4 min to change", and when the
     * live times make it too late: "You’ll miss the 08:12 — take the 08:27 from platform 4" with one tap to switch.
     */
    private suspend fun updateChangeGuide(now: Double) {
        val s = RideStore.state.value ?: return
        val atChange = s.index > 0 && s.vehicleTripId == null && s.changeArrived != null && s.phase == Phase.SLEEPING
        val k = if (atChange) s.index else s.index + 1
        val next = s.trip.rides.getOrNull(k) ?: run {
            if (s.changeLine != null || s.changeMiss != null) RideStore.update(this) { it.copy(changeLine = null, changeMiss = null, changeSwitch = null) }
            return
        }
        val prev = s.trip.rides[k - 1]
        val board = changeBoard?.takeIf { it.first == next.fromId && now - it.second < 120 }?.third
            ?: (try { Transit.board(listOf(next.fromId), n = 20) } catch (_: Exception) { emptyList() }).also { if (it.isNotEmpty()) changeBoard = Triple(next.fromId, now, it) }
        val liveNext = board.firstOrNull { it.tripId == next.tripId }?.time ?: next.departure
        val later = board.filter { !it.cancelled && WrongBus.norm(it.line) == WrongBus.norm(next.line) && it.tripId != next.tripId }
            .map { ChangeGuide.Ride(it.tripId, it.line, it.train, it.time, it.platform, next.walkBefore) }
        val learned = nl.haltewekker.travel.Habits.changeMinutes(nl.haltewekker.travel.HabitStore.book.value)
        val arrive = if (atChange) (s.changeArrived ?: now) else (s.legArrival ?: prev.arrival)
        // (A9, iOS 0.42.3 `MissCall`) no false "You'll miss": its live time, where you are, the feeding ride's data, the
        // ride instead from the change, and a miss told only once it held a minute
        val nextBoard = board.firstOrNull { it.tripId == next.tripId }
        val you = if (s.lastLat != null && s.lastLon != null) nl.haltewekker.core.GeoPoint(s.lastLat, s.lastLon) else null
        val seen = MissCall.Next(nextBoard?.live ?: next.live, nextSeen(next, atChange, now), you?.let { y -> next.from?.let { nl.haltewekker.core.Geo.metres(y, it) } })
        val fresh = s.vehicleSource != VehicleSource.NONE || (s.lastFixAt?.let { now - it <= MissCall.LIVE_FRESH } ?: false) && s.legArrival != null
        val feeding = MissCall.Feeding(s.vehicleTripId ?: prev.tripId, prev.line, prev.isTrain)
        val nextRide = ChangeGuide.Ride(next.tripId, next.line, next.isTrain, liveNext, next.platform, next.walkBefore, next.from)
        val first = ChangeGuide.call(arrive, nextRide, learned, now, atChange, seen = seen, fresh = fresh)
        val held = MissCall.step(missHold, first, "$k|${next.tripId}", now)
        if (held.retract) FieldLog.ride("change · miss taken back · ${next.line} ${Notifications.time(liveNext)}")
        missHold = held.hold
        val g = ChangeGuide.guide(arrive, null, prev.isTrain, null, nextRide, later.map { it.copy(from = next.from) }, learned, now,
            { Notifications.time(it) }, atChange = atChange, seen = seen, fresh = fresh, call = held.call, feeding = feeding,
            changeAt = listOfNotNull(next.from, prev.to))
        val line = listOfNotNull(g.lockLine.takeIf { it.isNotEmpty() }, g.countdown, g.note).joinToString(" · ")
        val sw = if (g.missed && g.target.tripId != next.tripId) g.target.tripId else null
        if (g.missed && s.changeMiss == null) FieldLog.ride("change · ${g.missText}")
        RideStore.update(this) { it.copy(changeLine = line, changeMiss = g.missText, changeSwitch = sw) }
        pendingSwitch = if (sw != null) g.target else null
    }

    private var nextTrip: Pair<String, TransitParse.LiveTrip>? = null
    private var nextTripAt = 0.0

    /**
     * (0.9.1, iOS `plannedSeen`) at a change, the next ride's own GPS (OVapi by its trip, NS by its number, ≤ 3 min)
     * against its stop on its road: at or before it (not left), or well past it (gone); else `NONE`. Its trip asked
     * at most every 2 minutes.
     */
    private suspend fun nextSeen(next: nl.haltewekker.data.Ride, atChange: Boolean, now: Double): MissCall.Seen {
        if (!atChange || !app.store.settings.value.realPositions) return MissCall.Seen.NONE
        val from = next.from ?: return MissCall.Seen.NONE
        val t = nextTrip?.takeIf { it.first == next.tripId && now - nextTripAt < 120 }?.second
            ?: (try { Transit.trip(next.tripId, maxAge = 60.0) } catch (_: Exception) { null })?.also { nextTrip = next.tripId to it; nextTripAt = now }
            ?: return MissCall.Seen.NONE
        val f = try {
            if (next.isTrain || RealPositions.isRail(t.mode)) RealPositions.trainNumber(next.num.ifEmpty { t.num })?.let { n -> LiveFeeds.trainFixes()[n] }
                ?.let { RealPositions.usable(it, next.tripId, now, MissRule.FIX_FRESH) }
            else RealPositions.usable(LiveFeeds.busFixes(), next.tripId, now, MissRule.FIX_FRESH)
        } catch (_: Exception) { null } ?: return MissCall.Seen.NONE
        val seen = MissCall.seenOnRoad(t.path, t.stops.map { it.point }, from, f.point, now - f.at)
        if (seen != MissCall.Seen.NONE) rideLogOnce("next-seen|${next.tripId}|$seen", 120.0,
            "change · ${FieldFormat.vehicle(next.line, next.tripId, next.isTrain)} by its own GPS (${Math.round(now - f.at)} s): " +
                if (seen == MissCall.Seen.NOT_LEFT) "not left its stop yet" else "well past its stop")
        return seen
    }

    private var pendingSwitch: ChangeGuide.Ride? = null
    private var missHold = MissCall.Hold()

    /** "Switch to the 08:27": the rest planned again from the change, spliced after the current leg. */
    private suspend fun switchChange() {
        val s = RideStore.state.value ?: return
        val instead = pendingSwitch ?: return
        val atChange = s.index > 0 && s.vehicleTripId == null && s.changeArrived != null
        val k = if (atChange) s.index else s.index + 1
        val next = s.trip.rides.getOrNull(k) ?: return
        val from = next.from ?: return
        val end = s.trip.last.to ?: return
        val plans = try { Transit.plan("${from.lat},${from.lon}", "${end.lat},${end.lon}", instead.departure - 60, count = 5, detailed = false) } catch (_: Exception) { emptyList() }
        val firsts = plans.map { p -> (p.rides.firstOrNull()?.tripId ?: "") to (p.rides.firstOrNull()?.departure ?: 0.0) }
        val i = ChangeGuide.pickPlan(firsts, instead) ?: run { Notifications.news(this, "switch-none", "No new plan yet", "Couldn't plan again from ${next.fromStop}: try again in a moment."); return }
        val p = plans[i]
        val cur = RideStore.state.value ?: return
        if (cur.index != s.index) return
        val st = app.store.settings.value
        val rides = cur.trip.rides.take(k) + p.rides
        val kms = cur.wakeKm.take(k) + p.rides.map { WakeRules.wakeKm(it.isTrain, st.busKm, st.trainKm) }
        RideStore.update(this) { it.copy(trip = it.trip.copy(rides = rides, end = p.end), wakeKm = kms, changeMiss = null, changeSwitch = null) }
        FieldLog.ride("change · switched to ${FieldFormat.vehicle(instead.line, instead.tripId, instead.isTrain)} at ${Notifications.time(instead.departure)}")
        pendingSwitch = null
        changeBoard = null
        etaAt = 0.0
        scheduleBackup()
        notifyRide(force = true)
    }

    // MARK: (A7) choosing between buses or trains (iOS 0.26.1 – 0.39.1)

    private fun label(c: RideChoice.Cand) = if (c.isTrain) c.line else "Bus ${c.line}"

    /** Choosing between `list` (the one shown first), a look every 12 s until one settles (iOS `beginChoosing`). */
    private fun beginChoosing(list: List<RideChoice.Cand>) {
        val s = RideStore.state.value ?: return
        if (s.vehicleSource == VehicleSource.BY_HAND) return
        if (!choice.begin(list, Iso.now(), nl.haltewekker.match.DepartMatch.usable(departure, Iso.now())?.t)) return
        FieldLog.match("choose · between " + choice.cands.joinToString(", ") { FieldFormat.label(it.tripId, mapOf(it.tripId to it.line)) })
        RideStore.update(this) { it.copy(choosing = choice.cands.map(::label)) }
        requestLocation(RideGPS.intervalMs(false))
        if (chooseJob?.isActive == true) return
        chooseJob = scope.launch {
            delay(8_000)
            while (isActive && choice.active) {
                chooseLook()
                if (!choice.active) break
                delay(12_000)
            }
            RideStore.update(this@RideService) { it.copy(choosing = emptyList()) }
        }
    }

    private suspend fun chooseLook() {
        val s = RideStore.state.value ?: run { choice.clear(); return }
        if (!(s.phase == Phase.SLEEPING || s.phase == Phase.AWAKE) || s.vehicleSource == VehicleSource.BY_HAND) { choice.clear(); return }
        val now = Iso.now()
        val names = choice.cands.associate { it.tripId to it }
        val out = try { withContext(Dispatchers.Default) {
            choice.look(fixes.toList(), s.vehicleTripId, now, app.store.settings.value.realPositions, nl.haltewekker.travel.HabitStore.book.value.lines,
                s.leg, nl.haltewekker.match.DepartMatch.usable(departure, now)) { noteGPSRuns(it) }
        } } catch (e: Exception) { RideChoice.Outcome.None }
        when (out) {
            is RideChoice.Outcome.Settle -> {
                val c = names[out.id]
                // (0.9.1, iOS 0.42.3) settled on the ride the next leg was planned with: that's the next leg
                if (c != null && LegAlarm.onRoad(listOf(out.id), null, s.trip.rides.getOrNull(s.index + 1)?.tripId, s.leg?.tripId) is LegAlarm.Road.NextLeg) {
                    choice.clear()
                    RideStore.update(this) { it.copy(choosing = emptyList(), ask = null) }
                    Notifications.cancelTag(this, Notifications.ASK_TAG, Notifications.NEWS_ID + 3)
                    boardedPlannedNext(c.tripId, c.line, c.isTrain, "found on board")
                    return
                }
                RideStore.update(this) { it.copy(choosing = emptyList(), ask = null) }
                Notifications.cancelTag(this, Notifications.ASK_TAG, Notifications.NEWS_ID + 3)
                val cur = RideStore.state.value ?: return
                if (c != null && out.id != cur.vehicleTripId) {
                    FieldLog.ride("switch · ${vehicleText(cur) ?: "none"} → ${FieldFormat.vehicle(c.line, c.tripId, c.isTrain)}")
                    RideStore.update(this) { it.copy(vehicleTripId = c.tripId, vehicleLine = c.line, vehicleSource = VehicleSource.BY_GPS) }
                    etaAt = 0.0
                    wakeRoute = emptyList(); wakeLive = null
                }
                afterFound(out.id, split = out.why == nl.haltewekker.match.ChoiceLook.Why.SPLIT)
            }
            is RideChoice.Outcome.Ask -> {
                val card = AskCard(out.title, nl.haltewekker.match.AskSooner.body(out.train), listOf(out.a.tripId, out.b.tripId), out.answers,
                    listOf(out.a.line, out.b.line), out.train)
                RideStore.update(this) { it.copy(ask = card) }
                FieldLog.ride("which ${if (out.train) "train" else "bus"} · asked: ${out.title}")
                Notifications.ask(this, out.title, card.body, out.answers, card.ids)
            }
            RideChoice.Outcome.None -> RideStore.update(this) { it.copy(choosing = choice.cands.map(::label)) }
        }
        notifyRide(force = false)
    }

    /** The answer to "305 or 306?" (ride screen or notification): that one, as a pick by hand. */
    private fun answer(tripId: String) {
        val s = RideStore.state.value ?: return
        val i = s.ask?.ids?.indexOf(tripId) ?: -1
        val line = if (i >= 0) s.ask!!.lines[i] else s.vehicleLine ?: s.leg?.line ?: ""
        val train = s.ask?.train ?: (s.leg?.isTrain ?: false)
        Notifications.cancelTag(this, Notifications.ASK_TAG, Notifications.NEWS_ID + 3)
        FieldLog.ride("which ${if (train) "train" else "bus"} · ${FieldFormat.vehicle(line, tripId, train)} (answered)")
        handPicked(tripId, line, train)
        scope.launch { stayOnIfItGoes(tripId) }
    }

    /** A pick by hand: that one for the rest of this leg; your usual line learns it (+2), and not the one it had (−1). */
    private fun handPicked(tripId: String, line: String, train: Boolean) {
        val s0 = RideStore.state.value ?: return
        val leg = s0.leg ?: return
        val had = s0.vehicleLine
        if (s0.vehicleTripId != null && s0.vehicleTripId != tripId && had != null && WrongBus.norm(had) != WrongBus.norm(line))
            learnLine(had, train, leg.departure, nl.haltewekker.match.UsualLine.NOT_THIS)
        learnLine(line, train, leg.departure, nl.haltewekker.match.UsualLine.SAID)
        choice.clear(); chooseJob?.cancel(); chooseJob = null
        RideStore.update(this) { it.copy(vehicleTripId = tripId, vehicleLine = line, vehicleSource = VehicleSource.BY_HAND, choosing = emptyList(), ask = null, wrongBus = null) }
        etaAt = 0.0
        notifyRide(force = true)
    }

    /** "Pick again" on the wrong-bus card: forget the one it found and look again. */
    private fun pickAgain() {
        choice.clear(); look.reset()
        RideStore.update(this) { it.copy(vehicleTripId = null, vehicleLine = null, vehicleSource = VehicleSource.NONE, wrongBus = null, choosing = emptyList()) }
        etaAt = 0.0
        notifyRide(force = true)
    }

    private fun learnLine(line: String, train: Boolean, at: Double, weight: Int) {
        if (line.isBlank()) return
        val z = RideChoice.ZONE
        nl.haltewekker.travel.HabitStore.update { it.rode(line, train, nl.haltewekker.match.UsualLine.minute(at, z), nl.haltewekker.match.UsualLine.weekend(at, z), weight) }
        FieldLog.ride("usual line · ${if (train) "train" else "bus"} $line ${if (weight > 0) "+" else ""}$weight")
    }

    /** (iOS 0.39.1) this look's fits by each vehicle's own GPS, for how long its GPS has been with you. */
    private fun noteGPSRuns(judged: List<nl.haltewekker.match.Judgement>) {
        val ids = judged.filter { ChooseGPS.passedByGPS(it) }.map { it.id }
        gpsRuns = WrongBus.note(gpsRuns, ids, Iso.now())
    }

    /** Found or settled: the wrong bus (once a ride), and a train that goes on to a later leg's stop. */
    private suspend fun afterFound(tripId: String, split: Boolean) {
        checkWrongBus(tripId, split)
        stayOnIfItGoes(tripId)
    }

    /**
     * (iOS 0.39.1 `WrongBus`) sure you're on another line than the leg was planned with (or the same line to somewhere
     * else) that doesn't go to that leg's stop: a card and once a ride a notification, with the best way on.
     */
    private suspend fun checkWrongBus(tripId: String, split: Boolean) {
        val s = RideStore.state.value ?: return
        val leg = s.leg ?: return
        if (s.wrongBusTold || choice.active || s.vehicleSource == VehicleSource.BY_HAND || tripId == leg.tripId) return
        if (!(s.phase == Phase.SLEEPING || s.phase == Phase.AWAKE)) return
        val now = Iso.now()
        if (!WrongBus.sure(gpsRuns[tripId], split, now)) return
        val t = try { Transit.trip(tripId, maxAge = 60.0) } catch (_: Exception) { null } ?: return
        val to = leg.to
        // one that takes you where that leg went anyway is no wrong bus
        if (to != null) {
            val here = fixes.lastOrNull()?.p
            val ahead = here?.let { h -> t.stops.indices.minByOrNull { Geo.metres(t.stops[it].point, h) } } ?: 0
            if (t.stops.drop(ahead).any { Geo.metres(it.point, to) <= 400 }) return
        }
        val line = RideStore.state.value?.vehicleLine ?: t.line
        val dest = nl.haltewekker.ui.Fmt.place(t.headsign)
        val plannedTo = if (WrongBus.norm(line) == WrongBus.norm(leg.line)) nl.haltewekker.ui.Fmt.place(leg.headsign) else ""
        if (!WrongBus.differs(leg.line, plannedTo, line, dest)) return
        val cur = RideStore.state.value ?: return
        if (cur.wrongBusTold || cur.vehicleTripId != tripId || cur.vehicleSource == VehicleSource.BY_HAND) return
        RideStore.update(this) { it.copy(wrongBusTold = true) }
        val next = t.stops.firstOrNull { (it.arrival ?: 0.0) > now }?.let { nl.haltewekker.ui.Fmt.place(it.name) }
        val fix = wrongBusFix(t, next)
        val title = WrongBus.title(line, dest, leg.line)
        RideStore.update(this) { it.copy(wrongBus = RideAlert(title, fix, tripId)) }
        FieldLog.ride(WrongBus.logLine(FieldFormat.label(tripId, mapOf(tripId to line)), dest, leg.line, fix) + if (split) " · roads split" else "")
        Notifications.rideNote(this, WrongBus.id(s.startedAt), title, fix)
        notifyRide(force = true)
    }

    private suspend fun wrongBusLook(now: Double) {
        val s = RideStore.state.value ?: return
        val leg = s.leg ?: return
        val v = s.vehicleTripId ?: return
        if (s.wrongBusTold || choice.active || v == leg.tripId || s.vehicleSource == VehicleSource.BY_HAND || !app.store.settings.value.realPositions) return
        if (!(s.phase == Phase.SLEEPING || s.phase == Phase.AWAKE)) return
        if (WrongBus.norm(s.vehicleLine ?: "") == WrongBus.norm(leg.line) && leg.headsign.isBlank()) return
        val mine = fixes.toList()
        val judged = try { withContext(Dispatchers.Default) { choice.judgeOne(mine, RideChoice.Cand(v, s.vehicleLine ?: leg.line, leg.isTrain), now, true) } } catch (_: Exception) { emptyList() }
        noteGPSRuns(judged)
        checkWrongBus(v, split = false)
    }

    /** The best way on from the wrong one, by the planner: from where you are to the trip's end, on this vehicle. */
    private suspend fun wrongBusFix(t: TransitParse.LiveTrip, nextStop: String?): String {
        val here = fixes.lastOrNull()?.p ?: return WrongBus.NO_FIX
        val end = RideStore.state.value?.trip?.last?.to ?: return WrongBus.NO_FIX
        val plans = try { Transit.plan("${here.lat},${here.lon}", "${end.lat},${end.lon}", Iso.now(), count = 5, detailed = false) } catch (_: Exception) { emptyList() }
        val mine = RideStore.state.value?.vehicleTripId
        val p = plans.firstOrNull { it.rides.firstOrNull()?.tripId == mine } ?: plans.firstOrNull() ?: return WrongBus.NO_FIX
        val stop = nl.haltewekker.ui.Fmt.place(p.first.toStop)
        val n = p.rides.getOrNull(1) ?: return WrongBus.fix(stop, nextStop == stop, null, null)
        return WrongBus.fix(stop, nextStop == stop, n.line, Notifications.time(n.departure))
    }

    /**
     * (iOS 0.34 `stayOnIfItGoes`) the train you're on goes on to a later leg's stop in time for the ride after it: the
     * trip follows it (stay on, no change).
     */
    private suspend fun stayOnIfItGoes(tripId: String) {
        val s = RideStore.state.value ?: return
        val leg = s.leg ?: return
        if (!leg.isTrain || s.index + 1 >= s.trip.rides.size) return
        val t = try { Transit.trip(tripId, maxAge = 60.0) } catch (_: Exception) { null } ?: return
        val rides = s.trip.rides
        val ends = rides.indices.map { k -> (if (k + 1 < rides.size) rides[k + 1].from else rides[k].to) ?: return }
        val calls = t.stops.map { nl.haltewekker.match.TrainRules.Call(it.point, it.arrival) }
        val (k, ci) = nl.haltewekker.match.TrainRules.stayOn(s.index, ends, rides.map { it.departure }, calls, Iso.now()) ?: return
        val st = t.stops[ci]
        val cur = RideStore.state.value ?: return
        if (cur.index != s.index || cur.vehicleTripId != tripId) return
        val skipped = rides.subList(s.index + 1, k + 1).map { it.fromStop }
        val name = nl.haltewekker.ui.Fmt.place(st.name)
        val mine = leg.copy(toStop = st.name, toLat = st.point.lat, toLon = st.point.lon, arrival = st.arrival ?: leg.arrival)
        val newRides = rides.subList(0, s.index) + mine + rides.subList(k + 1, rides.size)
        val kms = s.wakeKm.subList(0, minOf(s.index + 1, s.wakeKm.size)) + s.wakeKm.drop(k + 1)
        RideStore.update(this) { it.copy(trip = it.trip.copy(rides = newRides, end = if (k + 1 >= rides.size) (st.arrival ?: it.trip.end) else it.trip.end),
            wakeKm = kms, eta = null, distance = null, phase = if (it.phase == Phase.AWAKE) Phase.SLEEPING else it.phase,
            quietLeg = if (it.phase == Phase.AWAKE) false else it.quietLeg, legStartMetres = null) }
        etaAt = 0.0; wakeRoute = emptyList(); wakeLive = null
        legClosest = null; awayLooked = false; wakeBeforeAt = null
        backupScheduledFor = null; scheduleBackup()
        FieldLog.ride("stay on · ${FieldFormat.vehicle(cur.vehicleLine ?: leg.line, tripId, true)} to $name · no change at ${skipped.joinToString(", ")}")
        val nextRide = rides.getOrNull(k + 1)
        val what = cur.vehicleLine ?: leg.line
        val body = if (nextRide != null) "This $what goes on to $name in time for the same ${if (nextRide.isTrain) nextRide.line else "bus ${nextRide.line}"} at ${Notifications.time(nextRide.departure)}: no change at ${skipped.joinToString(", ")}."
        else "This $what goes all the way to $name: no change at ${skipped.joinToString(", ")}."
        Notifications.news(this, "stayon-${s.startedAt.toLong()}", "Stay on to $name", body)
        notifyRide(force = true)
    }

    /**
     * (iOS 0.34 `lookAtRivals`) the confirmed train isn't with you by its own NS position, another one on your track is:
     * choose between them. Every 2 minutes, not on one you picked yourself.
     */
    private suspend fun rivalsLook(now: Double) {
        val s = RideStore.state.value ?: return
        val leg = s.leg ?: return
        val v = s.vehicleTripId ?: return
        if (!leg.isTrain || choice.active || s.vehicleSource == VehicleSource.BY_HAND || now - rivalAt < nl.haltewekker.match.TrainRules.RIVAL_EVERY) return
        if (!(s.phase == Phase.SLEEPING || s.phase == Phase.AWAKE) || !app.store.settings.value.realPositions) return
        rivalAt = now
        val mine = fixes.toList()
        // the trains' numbers, for their NS positions (their trip answers, a few at a time)
        val near = look.lastJudged.filter { it.isTrain && it.id != v && it.id !in look.trainNumbers && it.evidence != null }.sortedBy { it.cost ?: 1e9 }.take(3)
        for (j in near) try { Transit.trip(j.id, maxAge = 300.0)?.let { t -> RealPositions.trainNumber(t.num)?.let { look.trainNumbers[j.id] = it } } } catch (_: Exception) {}
        if (v !in look.trainNumbers) try { Transit.trip(v, maxAge = 300.0)?.let { t -> RealPositions.trainNumber(t.num)?.let { look.trainNumbers[v] = it } } } catch (_: Exception) {}
        val rivalLook = OnBoardLook().also { it.trainNumbers.putAll(look.trainNumbers) }
        try { withContext(Dispatchers.Default) { rivalLook.look(mine, null, now, true, trains = true, trainsGPS = true) } } catch (_: Exception) { return }
        val judged = rivalLook.lastJudged
        noteGPSRuns(judged)
        val ids = nl.haltewekker.match.TrainRules.rivals(judged.firstOrNull { it.id == v }, judged)
        if (ids.isEmpty()) return
        val names = rivalLook.lastLines + (v to (s.vehicleLine ?: leg.line))
        FieldLog.match("rivals · ${FieldFormat.label(v, names)} not with you by its own GPS · " + ids.joinToString(", ") { FieldFormat.label(it, names) } + " by theirs → choose")
        beginChoosing(listOf(RideChoice.Cand(v, s.vehicleLine ?: leg.line, true)) + ids.map { RideChoice.Cand(it, names[it] ?: "", true) })
    }

    /**
     * (iOS 0.39.1 `OtherAtStop`) waiting for a bus at its stop (yours leaving within 10 min), another line's bus there
     * by its own GPS: "That’s the 154 to Schijndel — not yours" and once a bus a notification. The stop's board once a minute.
     */
    private suspend fun checkOtherAtStop(now: Double) {
        val s = RideStore.state.value ?: return
        val leg = s.leg ?: return
        val f = fixes.lastOrNull()
        val from = leg.from
        val waiting = s.phase == Phase.SLEEPING && s.vehicleTripId == null && !leg.isTrain
        if (!waiting || f == null || from == null || f.accuracy < 0 || f.accuracy >= 100 || now - f.t > 60 || !app.store.settings.value.realPositions) {
            if (s.otherAtStop != null) RideStore.update(this) { it.copy(otherAtStop = null) }
            return
        }
        val y = OtherAtStop.Yours(leg.line, leg.departure, setOf(leg.line))
        val toStop = Geo.metres(f.p, from)
        val wait = y.departure - now
        if (toStop > OtherAtStop.NEAR || wait < -60 || wait > OtherAtStop.WITHIN) {
            if (s.otherAtStop != null) RideStore.update(this) { it.copy(otherAtStop = null) }
            return
        }
        if (now - otherAt < 15) return
        otherAt = now
        val key = leg.fromId
        var list = otherBoard?.takeIf { it.first == key }?.second ?: emptyList()
        if (otherBoard?.first != key || now - otherBoardAt >= 60) {
            val b = try { Transit.board(listOf(key), n = 30) } catch (_: Exception) { emptyList() }
            if (b.isNotEmpty()) { list = b; otherBoard = key to b; otherBoardAt = now }
        }
        val buses = try { LiveFeeds.busFixes() } catch (_: Exception) { emptyMap() }
        val seen = list.filter { !it.cancelled && !it.train }.map { d ->
            val g = RealPositions.usable(buses, d.tripId, now, OtherAtStop.FIX_FRESH)
            OtherAtStop.Seen(d.tripId, d.line, nl.haltewekker.ui.Fmt.place(d.headsign), d.time, g?.let { Geo.metres(it.point, f.p) }, g?.let { now - it.at })
        }
        val pick = OtherAtStop.pick(seen, y, toStop, now)
        if (pick == null || pick.tripId in otherClosed) {
            if (RideStore.state.value?.otherAtStop != null) RideStore.update(this) { it.copy(otherAtStop = null) }
            return
        }
        val (title, body) = OtherAtStop.words(pick, y, now)
        val a = RideAlert(title, body, pick.tripId)
        if (RideStore.state.value?.otherAtStop != a) RideStore.update(this) { it.copy(otherAtStop = a) }
        if (!otherTold.add(pick.tripId)) return
        FieldLog.ride("other at stop · ${FieldFormat.label(pick.tripId, mapOf(pick.tripId to pick.line))} to ${pick.to} by its own GPS ${Math.round(pick.metres ?: 0.0)} m from you · not yours · your ${y.line} at ${Notifications.time(y.departure)}")
        Notifications.rideNote(this, OtherAtStop.id(pick.tripId), title, body)
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

    // MARK: auto-start: the look after leaving a home stop or School (iOS TripManager.leftRegion)

    private fun startLook(region: String) {
        if (lookJob?.isActive == true) return
        lookRegion = region; lookFrom = Iso.now()
        autoLook.reset()
        requestLocation(3_000)
        lookJob = scope.launch {
            repeat(AutoRules.LOOKS) {
                delay((AutoRules.LOOK_EVERY * 1000).toLong())
                if (RideStore.state.value != null) return@launch                   // a ride started meanwhile
                val now = Iso.now()
                val mine = fixes.toList()
                val real = app.store.settings.value.realPositions
                val f = withContext(Dispatchers.Default) { try { autoLook.look(mine, null, now, real) } catch (_: Exception) { null } }
                if (f != null && AutoRules.mayStart(f.tripId, idle = true, running = null, blocked = AutoStart.blocked(this@RideService).keys)
                    && autoStartDoor(region, f)) return@launch
            }
            if (RideStore.state.value == null) stopRide()                          // nothing found: back to watching cheaply
        }
    }

    /** Off the corridor (iOS `autoStartDoor`): the trip to the other place that rides this bus or train, started. */
    private suspend fun autoStartDoor(region: String, f: OnBoardLook.Found): Boolean {
        val prof = app.store.profile.value
        val role = AutoRules.role(region) ?: return false
        val dest = (if (role == AutoRules.Role.HOME) prof.school else prof.home) ?: return false
        val destName = if (role == AutoRules.Role.HOME) dest.name.ifBlank { "School" } else "Home"
        val spec = Regions.current(this).firstOrNull { it.id == region }
        val here = fixes.lastOrNull()?.p
        val tries = listOfNotNull(spec?.let { "${it.lat},${it.lon}" to lookFrom - 15 * 60 }, here?.let { "${it.lat},${it.lon}" to Iso.now() - 5 * 60 })
        val now = Iso.now()
        for ((from, at) in tries) {
            for (t in Transit.plan(from, dest.planId, at, count = 6, detailed = false)) {
                val i = t.rides.indexOfFirst { it.tripId == f.tripId }
                if (i < 0 || t.end < now) continue
                val trip = if (i == 0) t else DoorTrip(t.rides.drop(i), t.rides[i].departure, t.end)
                if (RideStore.state.value != null) return true
                RideStore.set(this, newState(this, trip, destName, 0).copy(vehicleTripId = f.tripId, vehicleLine = f.line,
                    vehicleSource = VehicleSource.BY_GPS, auto = true))
                ResumeStore.set(this, null)
                logStart("auto (station left)")
                lookJob = null
                intervalMs = 0
                begin()
                val leg = trip.first
                Notifications.news(this, "autostart", "Trip started by itself",
                    "${if (leg.isTrain) leg.line else "Bus ${leg.line}"} to ${leg.toStop}, on your way to ${if (destName == "Home") "home" else destName}. " +
                        "It rings ${WakeRules.distanceText(RideStore.state.value?.wakeMetres ?: 2000.0)} before your stop.")
                return true
            }
        }
        return false
    }

    // MARK: (0.10.3, iOS 0.42.4) Fastest trip's watching: getting on wherever you get on (`WaitStart`, `WaitWatch`)

    /** Fastest trip watches `WaitStore.request`: GPS on, a look every 6 s, whatever is on screen and with the phone locked. */
    private fun startWatch() {
        val r = WaitStore.request.value
        if (r == null) {
            if (!watch.watching) { WaitStore.ended(); if (lookJob?.isActive != true) stopRide() }
            return
        }
        if (watch.watching && watchDest == r.destId) return
        lookJob?.cancel(); lookJob = null                                       // the watching looks for it instead
        val (st, line) = WaitWatch.begin(watch, Iso.now(), nl.haltewekker.friends.FriendChats.foreground, r.watched?.first?.departure)
        watch = st; watchDest = r.destId
        waitLook.reset()
        FieldLog.ride(line)
        WaitStore._watching.value = true
        requestLocation(3_000)
        if (app.store.settings.value.motion) nl.haltewekker.motion.StepMotion.start(this)
        if (watchJob?.isActive != true) watchJob = scope.launch {
            delay((WaitWatch.EVERY * 1000).toLong())
            while (isActive && watch.watching) {
                val wait = try { watchLook() } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (_: Exception) { WaitWatch.EVERY }
                if (!watch.watching) break
                delay((wait * 1000).toLong())
            }
        }
    }

    private fun stopWatch(why: String) {
        val (st, line) = WaitWatch.end(watch, why)
        line?.let { FieldLog.ride(it) }
        val was = watchDest
        watch = st; watchDest = null
        watchJob?.cancel(); watchJob = null
        waitLook.reset()
        // closed from Fastest trip: nothing held; stopped by itself or from the notification: not again until it opens again
        WaitStore.ended(stopped = if (why == "closed") null else was)
        intervalMs = 0                      // a ride that starts asks for its own GPS pace
    }

    private var lookLogged: Pair<String, Double>? = null

    /** A look's line in the field log (`WaitStart.logDue`). */
    private fun logLook(line: String, key: String, busy: Boolean, now: Double) {
        if (!WaitStart.logDue(key, lookLogged, busy, now)) return
        lookLogged = key to now
        FieldLog.match(line)
    }

    /** One look while it watches: the seconds to the next one. */
    private suspend fun watchLook(): Double {
        val now = Iso.now()
        val r = WaitStore.request.value ?: run { stopWatch("closed"); return 0.0 }
        if (r.destId != watchDest) { startWatch(); return WaitWatch.EVERY }   // another destination: watching again
        WaitStart.lookRuns(watch.watching, RideStore.state.value == null, demo = false)?.let { stopWatch(if (it == "a trip runs") "the trip started" else it); return 0.0 }
        val mine = fixes.toList()
        val last = mine.lastOrNull()
        if (last != null) watch = WaitWatch.moved(watch, last.p, last.accuracy)
        WaitWatch.autoStop(watch, last?.p, last?.accuracy ?: -1.0, r.dest, now)?.let { why ->
            stopWatch(why)
            if (why != "you're there") Notifications.news(this, "watch-off", "Stopped watching",
                (if (why.startsWith("after")) "After ${WaitWatch.MAX_HOURS.toInt()} hours" else "The trip you were waiting for has gone and you stayed here") +
                    " · open Fastest trip again when you need it")
            if (RideStore.state.value == null && lookJob?.isActive != true) stopRide()
            return 0.0
        }
        val moving = WaitStart.moving(mine, now)
        // Android: no Play Services, so no "automotive"; the step detector's walking (when on) is "afoot"
        val hint = if (app.store.settings.value.motion) WaitStart.hint(nl.haltewekker.motion.StepMotion.now(now)) else WaitStart.Hint.NONE
        val fast = WaitStart.movingRule(moving, hint) == null
        if (WaitStore.atVehicleSpeed.value != fast) WaitStore._atVehicleSpeed.value = fast
        val planned = r.watched?.first
        // nothing moves with you while you stand: no request then (the call is "standing" whatever is around)
        val seen = if (moving.seconds > 0 || moving.speed >= 2)
            withContext(Dispatchers.Default) { waitLook.look(mine, planned, WaitWatch.targets(r), now, app.store.settings.value.realPositions, WaitStart.RULES.close) }
        else WaitLook.Seen(emptyList(), emptyList(), emptyMap(), emptyMap())
        if (!watch.watching || RideStore.state.value != null) return 0.0
        val out = WaitStart.step(watch.wait, moving, hint, seen.cands, WaitStart.RULES)
        watch = watch.copy(wait = out.state)
        val busy = moving.seconds > 0 || seen.cands.isNotEmpty()
        val key: String? = when (val call = out.call) {
            is WaitStart.Call.Start -> {
                logLook(out.line, "start", true, now)
                val label = FieldFormat.vehicle(seen.lines[call.id] ?: "", call.id, seen.trains[call.id] ?: false)
                startOn(call.id, seen, r, mine)?.let { FieldLog.match("wait · $label · not started: $it") }
                "${call.id}|${out.progress}"
            }
            is WaitStart.Call.WrongBus -> {
                logLook(out.line, "wrong bus", true, now)
                tellWrongBus(call.id, seen, r)
                call.id
            }
            is WaitStart.Call.Hold -> {
                logLook(out.line, call.why, busy, now)
                seen.cands.firstOrNull()?.id
            }
        }
        watch = WaitWatch.paced(watch, fast, moving, key, now)
        return WaitWatch.nextLook(watch, fast, out.progress, now)
    }

    /**
     * Start the trip on `id` (iOS `startOn`): the way on screen that rides it, else the ways on from it, planned now from
     * its next stop at its time there (an earlier bus: maybe an earlier train). The leg starts where you got on
     * (`boardedFrom`). Null: started; else why not.
     */
    private suspend fun startOn(id: String, seen: WaitLook.Seen, r: WaitWatch.Request, mine: List<Fix>): String? {
        val line = seen.lines[id] ?: ""
        val train = seen.trains[id] ?: false
        val here = mine.lastOrNull() ?: return "no fix"
        var way = WaitWatch.wayOn(r, id)
        if (way == null) {
            way = planOn(id, here.p, r) ?: return "no way on from it"
            if (WaitWatch.longWayRound(r.watched, line, way.end)) return "a long way round"
        }
        if (!watch.watching || RideStore.state.value != null) return "stopped watching"
        val boarded = boardedFrom(way, id, line, train, mine)
        if (WaitWatch.atItsStop(boarded.first.to?.let { Geo.metres(here.p, it) }, here.accuracy)) return "its stop is where you are"
        if (!watch.watching || RideStore.state.value != null) return "stopped watching"
        // the others that fit about as well: the ride keeps them in the running until there's real distance between them
        val best = seen.ranked.firstOrNull { it.id == id }?.cost
        val others = if (best == null) emptyList() else seen.ranked.filter { it.id != id && it.cost < best + WaitStart.RULES.close }.take(2)
            .map { RideChoice.Cand(it.id, seen.lines[it.id] ?: "", seen.trains[it.id] ?: false) }
        boardOn(boarded, r.destName, id, line, train, others)
        return null
    }

    /** The ways on from the vehicle `id`: planned from its next stop at its time there, else from here; only one that rides it. */
    private suspend fun planOn(id: String, here: GeoPoint, r: WaitWatch.Request): DoorTrip? {
        val now = Iso.now()
        val t = waitLook.trip(id, now)
        val tries = ArrayList<Pair<String, Double>>()
        if (t != null && t.stops.isNotEmpty()) {
            val near = t.stops.indices.minByOrNull { Geo.metres(t.stops[it].point, here) } ?: 0
            val next = (near until t.stops.size).firstOrNull { i -> ((t.stops[i].departure ?: t.stops[i].arrival) ?: 0.0) > now }
            next?.let { i -> val s0 = t.stops[i]; tries.add("${s0.point.lat},${s0.point.lon}" to ((s0.departure ?: s0.arrival ?: now) - 60)) }
        }
        tries.add("${here.lat},${here.lon}" to now - 5 * 60)
        for ((from, at) in tries) {
            val plans = try { Transit.plan(from, r.destId, at, count = 6, detailed = false) } catch (_: Exception) { emptyList() }
            for (p in plans) {
                val i = p.rides.indexOfFirst { it.tripId == id }
                if (i < 0 || p.end < now) continue
                return if (i == 0) p else DoorTrip(p.rides.drop(i), p.rides[i].departure, p.end)
            }
            if (!watch.watching) return null
        }
        return null
    }

    /**
     * The way `t` on `id`, got on where you got on (iOS `boardedFrom`, `WaitStart.repoint`): its first ride from the stop
     * of its trip nearest to where you started moving at bus speed, at its time there, when that's another stop than
     * the way had. Else `t` as it is.
     */
    private suspend fun boardedFrom(t: DoorTrip, id: String, line: String, train: Boolean, mine: List<Fix>): DoorTrip {
        val now = Iso.now()
        val here = mine.lastOrNull()?.p ?: return t
        val start = WaitStart.startedMoving(mine, now) ?: return t
        val trip = waitLook.trip(id, now) ?: return t
        val stops = WaitLook.stopsOf(trip)
        val f = t.first
        val i = WaitStart.repoint(stops, start, here, f.from) ?: return t
        val s0 = trip.stops[i]
        val at = s0.departure ?: s0.arrival ?: f.departure
        val late = f.departure - f.scheduledDeparture
        val ride = f.copy(fromStop = s0.name, fromId = "onboard", fromLat = s0.point.lat, fromLon = s0.point.lon, departure = at,
            scheduledDeparture = s0.scheduledDeparture ?: (at - late), walkBefore = 0, platform = null)
        FieldLog.match("wait · ${FieldFormat.vehicle(line, id, train)} · got on at its stop ${i + 1} of ${stops.size}, ${WaitStart.offMetres(f.from, s0.point)} m from where the way had it")
        return DoorTrip(listOf(ride) + t.rides.drop(1), minOf(t.start, at), t.end)
    }

    /** On board: the trip starts by itself on `id` (the ride screen takes over) and the watching stops. */
    private fun boardOn(t: DoorTrip, destName: String, id: String, line: String, train: Boolean, others: List<RideChoice.Cand>) {
        if (RideStore.state.value != null) return
        stopWatch("the trip started")
        RideStore.set(this, newState(this, t, destName, 0).copy(vehicleTripId = id, vehicleLine = line, vehicleSource = VehicleSource.BY_GPS, auto = true))
        ResumeStore.set(this, null)
        logStart("auto (Fastest trip: on board)")
        intervalMs = 0
        goForeground()
        begin()
        val first = t.first
        val what = if (train) line else "bus $line"
        val s = RideStore.state.value
        Notifications.news(this, "goboard-${Iso.now().toLong()}", "You’re on the $what",
            "Your trip to ${if (destName == "Home") "home" else destName} started by itself. " +
                if (s?.phase == Phase.AWAKE) "It tells you when you’re at ${first.toStop}." else "It rings before ${first.toStop}.")
        if (others.isNotEmpty()) beginChoosing(listOf(RideChoice.Cand(id, line, train)) + others)
        else scope.launch { afterFound(id, split = false) }
    }

    /** Sure you're on one that doesn't take you on (iOS `tellWrongBus`): the wrong-bus notification, once for that one. */
    private suspend fun tellWrongBus(id: String, seen: WaitLook.Seen, r: WaitWatch.Request) {
        val line = seen.lines[id] ?: ""
        val lt = waitLook.trip(id, Iso.now())
        val to = lt?.let { nl.haltewekker.ui.Fmt.place(it.headsign) } ?: ""
        val mine = r.watched?.first?.line ?: ""
        val title = if (mine.isEmpty()) "You’re on the $line${if (to.isEmpty()) "" else " to $to"}" else WrongBus.title(line, to, mine)
        val body = "It doesn’t go to ${r.destName}. ${WrongBus.NO_FIX}."
        FieldLog.match("wait · " + WrongBus.logLine(FieldFormat.vehicle(line, id, seen.trains[id] ?: false), to, mine, WrongBus.NO_FIX))
        if (!watch.watching || RideStore.state.value != null) return
        Notifications.rideNote(this, WrongBus.ID_PREFIX + "wait-" + id.takeLast(12), title, body)
    }

    /**
     * (0.10.3, iOS 0.42.4 `TripManager.boardedHere`) a vehicle found during a ride ("I'm on it" before you got on): got
     * on at another stop of its trip than the leg was planned from (a stop or two before it), the leg starts where you
     * got on; where you get off and the rest of the trip stay. Never a leg made short by it (one that rings no more).
     */
    private suspend fun boardedHere(tripId: String, line: String, isTrain: Boolean) {
        val s = RideStore.state.value ?: return
        if (s.index != 0 || !(s.phase == Phase.SLEEPING || s.phase == Phase.AWAKE)) return
        val leg = s.leg ?: return
        val now = Iso.now()
        val mine = fixes.toList()
        val here = mine.lastOrNull()?.p ?: return
        val start = WaitStart.startedMoving(mine, now) ?: return
        val trip = try { Transit.trip(tripId, maxAge = 60.0) } catch (_: Exception) { null } ?: return
        val stops = WaitLook.stopsOf(trip)
        val i = WaitStart.repoint(stops, start, here, leg.from) ?: return
        val to = leg.to ?: return
        val st = stops[i]
        // the alarm first: never a leg made short by it, one that rings no more
        val wasShort = ShortLeg.isShort(LegAlarm.span(leg.from, to), s.wakeMetres)
        if (!wasShort && ShortLeg.isShort(LegAlarm.span(st.point, to), s.wakeMetres)) return
        val cur = RideStore.state.value ?: return
        if (cur.index != 0 || cur.vehicleTripId != tripId || cur.startedAt != s.startedAt) return
        val ts = trip.stops[i]
        val at = ts.departure ?: ts.arrival ?: leg.departure
        val mineLeg = leg.copy(fromStop = st.name, fromId = "onboard", fromLat = st.point.lat, fromLon = st.point.lon, departure = at,
            scheduledDeparture = ts.scheduledDeparture ?: (at - (leg.departure - leg.scheduledDeparture)), walkBefore = 0, platform = null)
        RideStore.update(this) { it.copy(trip = it.trip.copy(rides = listOf(mineLeg) + it.trip.rides.drop(1)), legStartMetres = null) }
        etaAt = 0.0; wakeRoute = emptyList(); wakeLive = null
        FieldLog.ride("board · ${FieldFormat.vehicle(line, tripId, isTrain)} got on at its stop ${i + 1} of ${stops.size}, ${WaitStart.offMetres(leg.from, st.point)} m from where the leg was planned from")
    }

    override fun onDestroy() {
        if (watch.watching) { FieldLog.ride(WaitStart.offLine("the service ended")); WaitStore.ended() }
        scope.cancel()
        try { lm.removeUpdates(listener) } catch (_: Exception) {}
        if (RideStore.state.value == null && nl.haltewekker.school.WakeService.ringing.value == null) AlarmPlayer.shutdown(this)
        super.onDestroy()
    }
}
