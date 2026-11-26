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
        const val EXTRA_KM = "km"
        const val EXTRA_REGION = "region"
        const val EXTRA_BY_HAND = "byHand"
        /** (A7) the answer to "305 or 306?" (`EXTRA_TRIP`), a card closed (`EXTRA_WHAT`: wrong, other), look again. */
        const val ACTION_ANSWER = "nl.haltewekker.ride.ANSWER"
        const val ACTION_DISMISS = "nl.haltewekker.ride.DISMISS"
        const val ACTION_PICK_AGAIN = "nl.haltewekker.ride.PICK_AGAIN"
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

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        Notifications.channels(this)
        RideStore.load(this)
        FieldLog.init(this)
        AlarmPlayer.warmUp(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_LOOK) {
            if (RideStore.state.value != null) return START_STICKY                 // a ride runs: nothing to look for
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
        if (RideStore.state.value == null) { lookJob?.cancel(); stopRide(); return START_NOT_STICKY }
        lookJob?.cancel(); lookJob = null
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

    private fun goForeground(looking: Boolean = false): Boolean {
        val n = if (looking) Notifications.looking(this) else Notifications.ride(this, RideStore.state.value)
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
        // (`WakeRule`). Within 20 s of the leg's start either one wakes it silently.
        val good = fix.accuracy >= 0 && fix.accuracy < WakeRules.GOOD_ACCURACY
        if (s.phase == Phase.SLEEPING) {
            val fire = if (good) wakeFire(fix, d, s) else null
            if (fire != null) {
                if (now - s.legStart < WakeRules.EARLY_LEG) {
                    FieldLog.ride(FieldFormat.rideWake(d))
                    RideStore.update(this) { it.copy(phase = Phase.AWAKE, note = "You started close to your stop: it tells you when you're there.") }
                } else ring(WakeRule.log(fire), fire)
            }
        } else if (WakeRules.onFix(s.phase, d, fix.accuracy, now - s.legStart, s.wakeMetres) == WakeRules.Action.ARRIVE) arrive()
        // (A6, iOS 0.32) Share GPS points during rides (when on): the trip's own fixes, nothing asked for
        nl.haltewekker.logs.LogShareStore.heard(fix.t, fix.p.lat, fix.p.lon, fix.accuracy, fix.speed, fix.course,
            nl.haltewekker.logs.GPSShareRules.leg(s.index, s.trip.rides.size), vehicleText(s))
        if (s.vehicleTripId != null) startReckon()
        // rough GPS far from the stop on a confirmed vehicle (iOS RideGPS)
        val cur = RideStore.state.value ?: return
        val far = RideGPS.far(RideGPS.Input(
            enabled = app.store.settings.value.roughGPSOnLongRides, asleep = cur.phase == Phase.SLEEPING,
            confirmed = cur.vehicleSource == VehicleSource.BY_GPS || cur.vehicleSource == VehicleSource.BY_HAND,
            metresToStop = d, accuracy = fix.accuracy, fixAge = now - fix.t,
            // (A6) by time, the far tier keeps clear of the time rule's reach
            wakeMetres = WakeRule.gpsWakeMetres(cur.wakeMetres, app.store.settings.value.wake, leg.isTrain), isTrain = leg.isTrain,
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
                        if (f != null) {
                            RideStore.update(this) {
                                it.copy(vehicleTripId = f.tripId, vehicleLine = f.line,
                                    vehicleSource = if (f.byGPS || moving) VehicleSource.BY_GPS else VehicleSource.BY_TIMES)
                            }
                            FieldLog.match(FieldFormat.detect(mine.size, "${f.line}·${f.tripId.takeLast(4)}", f.byGPS, f.tripId == leg.tripId))
                            RideStore.state.value?.let { cur -> noteBoarding(cur, f.tripId, mine) }
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
                if (now - etaAt >= 60 && leg.to != null) {
                    etaAt = now
                    val w = look.wakeTrip(v, leg.from, leg.to!!)
                    if (w != null) {
                        wakeRoute = w.route
                        wakeLive = w.arrival?.takeIf { w.live }?.let { it to Iso.now() }
                        w.arrival?.let { eta -> RideStore.update(this) { it.copy(eta = eta) } }
                    }
                    scheduleBackup()
                }
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
        FieldLog.ride(FieldFormat.rideRing(why, s.distance, Iso.now() - s.legStart, startMetres(s)))
        val minutes = (fire as? WakeRule.Fire.Time)?.minutes
        RideStore.update(this) { it.copy(phase = Phase.ALARM, quiet = quiet, note = null, roughGPS = false, ringMinutes = minutes, rangAt = Iso.now(), againSent = false) }
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
        if (app.store.settings.value.ringAtStop) RideStore.update(this) { it.copy(phase = Phase.AWAKE) } else legDone()
        notifyRide(force = true)
    }

    private fun arrive() {
        val s = RideStore.state.value ?: return
        val leg = s.leg ?: return
        val st = app.store.settings.value
        val next = s.trip.rides.getOrNull(s.index + 1)
        FieldLog.ride(FieldFormat.rideArrive("by GPS", s.distance, s.accuracy, Iso.now() - s.legStart, null))
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
        RideStore.update(this) { it.copy(choosing = emptyList(), ask = null, otherAtStop = null, wrongBus = null) }
        val s = RideStore.state.value ?: return
        look.reset()
        etaAt = 0.0
        resetLegWake()
        if (s.index + 1 < s.trip.rides.size) {
            RideStore.update(this) {
                it.copy(index = it.index + 1, phase = Phase.SLEEPING, legStart = now, vehicleTripId = null, vehicleLine = null,
                    vehicleSource = VehicleSource.NONE, eta = null, distance = null, quiet = false, note = null, roughGPS = false,
                    ringMinutes = null, reckoning = false, changeArrived = now, changeFromVehicle = s.vehicleTripId)
            }
            requestLocation(RideGPS.intervalMs(false))
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
        RideStore.set(this, null)
        stopRide()
    }

    private fun stopRide() {
        tick?.cancel()
        stopReckon()
        nl.haltewekker.motion.StepMotion.stop()
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
        val w = app.store.settings.value.wake
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
        if (s.phase == Phase.SLEEPING && now - s.legStart >= WakeRules.EARLY_LEG) {
            val i = wakeInput(s, d, maxOf(0.0, end - e.metres), pace, now) ?: return
            val fire = DeadReckon.decide(i)
            if (DeadReckon.mayRing(fire, deadReckoned = true) && fire != null) {
                ring("reckoned (${e.source.raw}) · " + WakeRule.log(fire), fire)
                return
            }
        }
        notifyRide(force = false)
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
        val plans = try { Transit.plan("${here.lat},${here.lon}", "${end.lat},${end.lon}", Iso.now(), count = 5) } catch (_: Exception) { emptyList() }
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
            wakeKm = kms, eta = null, distance = null, phase = if (it.phase == Phase.AWAKE) Phase.SLEEPING else it.phase) }
        etaAt = 0.0; wakeRoute = emptyList(); wakeLive = null
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
            for (t in Transit.plan(from, dest.planId, at, count = 6)) {
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

    override fun onDestroy() {
        scope.cancel()
        try { lm.removeUpdates(listener) } catch (_: Exception) {}
        if (RideStore.state.value == null && nl.haltewekker.school.WakeService.ringing.value == null) AlarmPlayer.shutdown(this)
        super.onDestroy()
    }
}
