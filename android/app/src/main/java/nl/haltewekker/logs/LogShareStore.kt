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

    val on = MutableStateFlow(false)
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
        state.value = LogShareState.decode(store().getString(STATE_KEY))
        // watches the ride's phase only: a trip that ended is a moment to send (a moment later, once its last lines are in)
        scope.launch {
            var was = running()
            RideStore.state.map { running() }.distinctUntilChanged().collect { now ->
                val ended = was && !now
                was = now
                if (ended) { FieldLog.flush(); delay(3000); upload(LogShareRules.Trigger.TRIP_ENDED) }
            }
        }
    }

    private fun running() = RideStore.state.value.let { it != null && it.phase != Phase.FINISHED }

    private fun save() {
        store().prefs.edit().putBoolean(ON_KEY, on.value).apply()
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
        if (!on.value || uploading) return
        var s = state.value ?: return
        val now = now()
        val today = LogShareRules.day(now)
        val (dataSaver, power) = restricted()
        if (dataSaver) return
        if (!LogShareRules.due(s, on.value, trigger, running(), power, now, today)) return
        s = LogShareRules.tried(s, now)
        state.value = s; save()
        val batch = LogShareRules.batch(FieldLog.entries, s.through, LogShareRules.budget(s, today), known())
        if (batch.lines.isEmpty()) return
        val put = LogSharePut(s.install, s.secret, appVersion, batch.lines)
        uploading = true
        try {
            val (status, _) = post(LogShareRules.PATH, FriendJson.encode(LogSharePut.serializer(), put))
            val cur = state.value
            // (switched off, or deleted with a new id, meanwhile: what was sent isn't counted on the new one)
            if (status != 200 || !on.value || cur == null || cur.install != put.install) return
            state.value = LogShareRules.sent(cur, batch, now(), today)
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
