package nl.haltewekker.logs

import android.content.Context
import android.net.ConnectivityManager
import android.os.PowerManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import nl.haltewekker.App
import nl.haltewekker.BuildConfig
import nl.haltewekker.friends.FriendJson
import nl.haltewekker.friends.FriendRelay
import nl.haltewekker.friends.FriendStore
import nl.haltewekker.ride.Phase
import nl.haltewekker.ride.RideStore
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.concurrent.TimeUnit

/**
 * Settings › Help improve Haltewekker › Share ride logs (iOS `LogShareStore.swift`): off unless you turn it on. When on,
 * after each trip ends (and at most once an hour otherwise, when the app comes to the front) the new matching and ride
 * lines of the field log go to the relay, scrubbed (`LogScrub`), gzipped, at most 200 KB at a time and 2 MB a day. Not
 * during a trip, not with Data Saver on a metered network, not in battery saver. It only reads the field log and the
 * ride's phase: nothing about a ride, the alarm or matching changes. No loop of its own.
 */
object LogShareStore {
    const val ON_KEY = "logShare.on"
    const val STATE_KEY = "logShare.state.v1"
    /** (A6, iOS 0.32) Share GPS points during rides. */
    const val FIXES_KEY = "gpsShare.on"

    val on = MutableStateFlow(false)
    val fixesOn = MutableStateFlow(false)
    /** The one-time question was answered or put away (`share.asked.v1`). */
    val asked = MutableStateFlow(true)
    val fixesWaiting = MutableStateFlow(0)
    private var queue = GPSShareQueue()
    private var queueEra = 0
    private var lastQueueSave = 0.0
    val state = MutableStateFlow<LogShareState?>(null)
    val busy = MutableStateFlow(false)
    val note = MutableStateFlow<String?>(null)

    private lateinit var ctx: Context
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var uploading = false
    private var attached = false
    private val client by lazy {
        OkHttpClient.Builder().connectTimeout(10, TimeUnit.SECONDS).readTimeout(20, TimeUnit.SECONDS).callTimeout(40, TimeUnit.SECONDS)
            .retryOnConnectionFailure(false).build()
    }

    private fun store() = (ctx.applicationContext as App).store
    private fun now() = System.currentTimeMillis() / 1000.0

    fun attach(c: Context) {
        if (attached) return
        attached = true
        ctx = c.applicationContext
        FieldLog.init(ctx)
        on.value = store().prefs.getBoolean(ON_KEY, false)
        fixesOn.value = store().prefs.getBoolean(FIXES_KEY, false)
        asked.value = store().prefs.getBoolean(ShareAsk.ASKED_KEY, false)
        state.value = LogShareState.decode(store().getString(STATE_KEY))
        queue = if (fixesOn.value) GPSShareQueue.decode(try { queueFile().readText() } catch (_: Exception) { null }) else GPSShareQueue()
        fixesWaiting.value = queue.ready.size
        // watches the ride's phase only: a trip that ended is a moment to send (a moment later, once its last lines are in)
        scope.launch {
            var was = running()
            RideStore.state.map { running() }.distinctUntilChanged().collect { now ->
                val ended = was && !now
                was = now
                if (ended) { finishRide(); FieldLog.flush(); delay(3000); upload(LogShareRules.Trigger.TRIP_ENDED) }
            }
        }
    }

    private fun running() = RideStore.state.value.let { it != null && it.phase != Phase.FINISHED }

    private fun save() {
        store().prefs.edit().putBoolean(ON_KEY, on.value).putBoolean(FIXES_KEY, fixesOn.value).apply()
        store().putString(STATE_KEY, state.value?.let(LogShareState::encode))
    }

    /** The switch. On: lines from now on (a first install id and secret are made); off: nothing more goes. */
    fun setOn(v: Boolean) {
        if (v == on.value) return
        on.value = v
        if (v) state.value = (state.value ?: LogShareState.fresh(now())).copy(through = now())
        note.value = null
        save()
    }

    // MARK: (A6, iOS 0.32) GPS points

    private fun queueFile() = java.io.File(ctx.filesDir, "gpsshare.json")

    private fun saveQueue(force: Boolean = true) {
        val t = now()
        if (!force && t - lastQueueSave < 30) return
        lastQueueSave = t
        fixesWaiting.value = queue.ready.size
        val q = queue
        scope.launch {
            try {
                if (q.current == null && q.ready.isEmpty()) queueFile().delete() else queueFile().writeText(GPSShareQueue.encode(q))
            } catch (_: Exception) {}
        }
    }

    private fun clearQueue() { queue = GPSShareQueue(); queueEra++; saveQueue() }

    /** Share GPS points during rides. Off: the points not sent yet go too. */
    fun setFixesOn(v: Boolean) {
        if (v == fixesOn.value) return
        fixesOn.value = v
        if (v && state.value == null) state.value = LogShareState.fresh(now())
        if (!v) clearQueue()
        note.value = null
        save()
    }

    /** Both switches at once, and the question answered (the setup's step, the card). */
    fun answer(logs: Boolean, fixes: Boolean) { setOn(logs); setFixesOn(fixes); markAsked() }

    fun markAsked() {
        if (asked.value) return
        asked.value = true
        store().prefs.edit().putBoolean(ShareAsk.ASKED_KEY, true).apply()
    }

    /** The saved switches read again (after a test setup put them back). */
    fun reload() {
        if (!attached) return
        on.value = store().prefs.getBoolean(ON_KEY, false)
        asked.value = store().prefs.getBoolean(ShareAsk.ASKED_KEY, false)
        val f = store().prefs.getBoolean(FIXES_KEY, false)
        if (f != fixesOn.value) { fixesOn.value = f; if (!f) clearQueue() }
        if ((on.value || fixesOn.value) && state.value == null) { state.value = LogShareState.fresh(now()); save() }
    }

    /** A location the trip heard (the ride service): kept while a trip runs, when it's turned on. */
    fun heard(t: Double, lat: Double, lon: Double, accuracy: Double, speed: Double, course: Double, leg: String?, vehicle: String?) {
        if (!attached || !fixesOn.value || !running()) return
        val f = GPSShareRules.fix(t, lat, lon, accuracy, speed, course, leg, vehicle, null) ?: return
        queue = queue.heard(f) { GPSShareRules.rideId() }
        saveQueue(force = false)
    }

    /** Your places: no point near one of them goes. */
    private fun zones(): List<nl.haltewekker.core.GeoPoint> {
        val p = store().profile.value
        return listOfNotNull(p.home?.point, p.school?.point) + p.homeStops.map { nl.haltewekker.core.GeoPoint(it.lat, it.lon) }
    }

    private fun finishRide() {
        if (queue.current == null) return
        queue = queue.finishRide(zones())
        saveQueue()
    }

    /** The app came to the front: at most once an hour. */
    fun tick() { if (attached) scope.launch { upload(LogShareRules.Trigger.TICK) } }

    /** Your places' names, people's names and account ids, to take out of every line. */
    fun known(): LogScrubKnown {
        val p = store().profile.value
        val app = ctx.applicationContext as App
        val school = app.schools.firstOrNull { it.id == p.schoolId }
        val homes = listOfNotNull(p.home?.name) + p.homeStops.map { it.name }
        val schools = listOfNotNull(p.school?.name, school?.name, school?.short, p.campus)
        val b = FriendStore.book.value
        val people = if (b == null) emptyList() else listOf(b.myName) + b.friends.map { it.name } + b.incoming.map { it.name } + b.outgoing.map { it.name } +
            FriendStore.groups.value.groups.flatMap { g -> g.roster.members.map { it.name } }
        val ids = (if (b == null) emptyList() else b.friends.map { it.id } + b.incoming.map { it.id } + b.outgoing.map { it.id }) + listOfNotNull(FriendStore.myAccount)
        return LogScrubKnown(homes = homes, schools = schools, people = people, ids = ids)
    }

    fun example(): String = LogShareRules.example(FieldLog.entries, known()) ?: LogShareRules.SAMPLE

    private val appVersion: String get() = "${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE}) Android"

    /** Data Saver on a metered network, or battery saver: not now. */
    private fun restricted(): Pair<Boolean, Boolean> {
        val cm = ctx.getSystemService(ConnectivityManager::class.java)
        val dataSaver = cm != null && cm.isActiveNetworkMetered && cm.restrictBackgroundStatus == ConnectivityManager.RESTRICT_BACKGROUND_STATUS_ENABLED
        val power = ctx.getSystemService(PowerManager::class.java)?.isPowerSaveMode == true
        return dataSaver to power
    }

    private suspend fun post(path: String, body: ByteArray): Pair<Int, String> = withContext(Dispatchers.IO) {
        val z = Gzip.compress(body)
        val rb = if (z != null) z.toRequestBody("application/gzip".toMediaType()) else body.toRequestBody("application/json".toMediaType())
        val req = Request.Builder().url(FriendRelay.BASE + path).post(rb).header("User-Agent", "Haltewekker-Android").build()
        try { client.newCall(req).execute().use { r -> r.code to (r.body?.string() ?: "") } } catch (_: Exception) { -1 to "" }
    }

    private suspend fun upload(trigger: LogShareRules.Trigger) {
        if (!(on.value || fixesOn.value) || uploading) return
        var s = state.value ?: return
        val now = now()
        val today = LogShareRules.day(now)
        val (dataSaver, power) = restricted()
        if (dataSaver) return
        val waiting = fixesOn.value && queue.ready.isNotEmpty()
        if (!LogShareRules.due(s, on.value || fixesOn.value, trigger, running(), power, now, today, fixes = waiting)) return
        s = LogShareRules.tried(s, now)
        state.value = s; save()
        val batch = if (on.value) LogShareRules.batch(FieldLog.entries, s.through, LogShareRules.budget(s, today), known()) else LogShareBatch()
        val points = if (waiting) GPSShareRules.batch(queue.ready, GPSShareRules.budget(s, today)) else GPSShareRules.Batch(emptyList(), 0, false)
        if (batch.lines.isEmpty() && points.fixes.isEmpty()) return
        val era = queueEra
        val tz = java.util.TimeZone.getDefault().getOffset(System.currentTimeMillis()) / 1000
        val put = LogSharePut(s.install, s.secret, appVersion, batch.lines,
            fixes = points.fixes.ifEmpty { null }, tz = if (points.fixes.isEmpty()) null else tz)
        uploading = true
        try {
            val (status, _) = post(LogShareRules.PATH, FriendJson.encode(LogSharePut.serializer(), put))
            val cur = state.value
            // (switched off, or deleted with a new id, meanwhile: what was sent isn't counted on the new one)
            if (status != 200 || !(on.value || fixesOn.value) || cur == null || cur.install != put.install) return
            if (points.fixes.isNotEmpty() && era == queueEra) { queue = queue.sent(points.fixes.size); saveQueue() }
            state.value = LogShareRules.sent(cur, if (on.value) batch else LogShareBatch(), now(), today, fixBytes = points.bytes)
            save()
        } finally { uploading = false }
    }

    /** "Delete what I sent": everything of this install id on the relay goes; then a new id. The switch stays. */
    fun deleteSent() = scope.launch {
        val s = state.value ?: return@launch
        if (busy.value) return@launch
        busy.value = true
        note.value = null
        try {
            val (status, text) = post(LogShareRules.DELETE_PATH, FriendJson.encode(LogShareDelete.serializer(), LogShareDelete(s.install, s.secret)))
            if (status != 200) {
                note.value = "Couldn’t reach the server. Nothing was deleted yet: try again later."
                return@launch
            }
            val n = ((FriendJson.parse(text.toByteArray()) as? JsonObject)?.get("deleted") as? JsonPrimitive)?.content?.toIntOrNull() ?: 0
            state.value = (state.value ?: s).rotated()
            save()
            note.value = if (n == 0) "Nothing of yours was on the server." else "Deleted: $n ${if (n == 1) "upload" else "uploads"} from this phone."
        } finally { busy.value = false }
    }
}
