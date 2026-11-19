package nl.haltewekker.friends

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import nl.haltewekker.ride.Phase
import nl.haltewekker.ride.RideState
import nl.haltewekker.ride.RideStore
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.File
import java.util.concurrent.TimeUnit

/** The relay's live-link routes (relay/live.js): no account, JSON, one try each. */
class LiveRelay(private val base: String = LiveCrypto.RELAY, private val userAgent: String = "Haltewekker-Android") {
    sealed class Answer {
        data class Ok(val exp: Long?) : Answer()
        data object Ended : Answer()
        data object Slow : Answer()
        data class Failed(val status: Int) : Answer()
    }

    data class Got(val data: String, val at: Long?, val exp: Long?)

    private suspend fun call(path: String, body: JsonObject): Pair<Int, String> = withContext(Dispatchers.IO) {
        val req = Request.Builder().url(base + path).post(FriendJson.write(body).toByteArray().toRequestBody("application/json".toMediaType()))
            .header("User-Agent", userAgent).header("Cache-Control", "no-store").build()
        try { client.newCall(req).execute().use { r -> r.code to (r.body?.string() ?: "") } } catch (_: Exception) { -1 to "" }
    }

    private fun answer(st: Int, text: String): Answer = when (st) {
        200 -> Answer.Ok(((FriendJson.parse(text.toByteArray()) as? JsonObject)?.get("exp") as? JsonPrimitive)?.content?.toDoubleOrNull()?.toLong())
        410 -> Answer.Ended
        429 -> Answer.Slow
        else -> Answer.Failed(st)
    }

    suspend fun put(keys: LiveKeys, data: ByteArray, until: Double): Answer {
        val (st, text) = call("/live/v1/put", buildJsonObject {
            put("secret", B64u.encode(keys.secretBytes)); put("data", B64u.encode(data)); put("until", until.toLong())
        })
        return answer(st, text)
    }

    suspend fun end(keys: LiveKeys): Answer {
        val (st, text) = call("/live/v1/end", buildJsonObject { put("secret", B64u.encode(keys.secretBytes)) })
        return answer(st, text)
    }

    /** What the page reads (`GET /live/v1/get?t=`): the locked data, or the status (404 gone, 410 ended). */
    suspend fun get(token: String): Pair<Int, Got?> = withContext(Dispatchers.IO) {
        val req = Request.Builder().url("$base/live/v1/get?t=$token").header("User-Agent", userAgent).get().build()
        try {
            client.newCall(req).execute().use { r ->
                val o = FriendJson.parse((r.body?.string() ?: "").toByteArray()) as? JsonObject
                fun s(k: String) = (o?.get(k) as? JsonPrimitive)?.content
                r.code to (if (r.code == 200) s("data")?.let { Got(it, s("at")?.toDoubleOrNull()?.toLong(), s("exp")?.toDoubleOrNull()?.toLong()) } else null)
            }
        } catch (_: Exception) { -1 to null }
    }

    companion object {
        val client: OkHttpClient by lazy {
            OkHttpClient.Builder().connectTimeout(10, TimeUnit.SECONDS).readTimeout(15, TimeUnit.SECONDS).callTimeout(20, TimeUnit.SECONDS)
                .retryOnConnectionFailure(false).build()
        }
    }
}

/**
 * Live link (0.30), the iOS `LiveLinkStore.swift`: a web page with your trip's live times for someone without the app,
 * made from the ride screen or Friends while a trip runs. Posted only on the ride's existing network tick (a put when
 * 55 s went by, or at once when the leg, the stage or the vehicle changed), "Arrived" at the last stop (kept 15 min),
 * ended when the trip ends otherwise, when you stop it, or after 4 hours. No loop of its own; it never changes the ride.
 * Works without a friends account. The link (with its secret and key) is kept in `files/friends/live.json`, not backed up.
 */
object LiveLinkStore {
    @Serializable
    data class Link(
        val keys: LiveKeys,
        val created: Double,
        val name: String,
        val lastSent: Double? = null,
        val lastKey: String = "",
        val last: LiveState? = null,
        val arrived: Boolean = false,
        val exp: Double? = null,
    )

    @Serializable private data class Saved(val link: Link? = null, val endPending: LiveKeys? = null)

    val link = MutableStateFlow<Link?>(null)
    val making = MutableStateFlow(false)
    val problem = MutableStateFlow<String?>(null)

    private lateinit var ctx: Context
    private var saved = Saved()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val lane = Mutex()
    private var putQueued = false
    private var attached = false
    private val relay = LiveRelay()
    private const val NAME_KEY = "live.name"

    private val file: File get() = File(FriendStore.folder(ctx), "live.json")
    private fun now() = System.currentTimeMillis() / 1000.0

    private fun save() {
        try {
            val tmp = File(file.parentFile, "live.json.tmp")
            tmp.writeText(FriendJson.encodeString(Saved.serializer(), saved))
            tmp.renameTo(file)
        } catch (_: Exception) {}
        link.value = saved.link
    }

    /** One at a time (a put, the arrival, the end), in order. */
    private fun enqueue(op: suspend () -> Unit) { scope.launch { lane.withLock { try { op() } catch (_: Exception) {} } } }

    @OptIn(FlowPreview::class)
    fun attach(c: Context) {
        if (attached) return
        attached = true
        ctx = c.applicationContext
        saved = (try { file.takeIf { it.exists() }?.readText() } catch (_: Exception) { null })?.let { FriendJson.decode(Saved.serializer(), it) } ?: Saved()
        link.value = saved.link
        scope.launch {
            RideStore.state.map { it?.let { s -> "${s.phase}|${s.index}|${s.vehicleTripId}|${FriendTravelShare.stage(s, now())}" } ?: "none" }
                .distinctUntilChanged().debounce(2000).collect { phaseChanged() }
        }
        settle()
    }

    fun running(s: RideState?) = s != null && s.phase != Phase.FINISHED

    val canMake: Boolean get() = running(RideStore.state.value)

    /** The name the page says: your friends name, else the one you typed last time. */
    val defaultName: String
        get() = FriendStore.book.value?.myName?.takeIf { it.isNotEmpty() }
            ?: ctx.getSharedPreferences("friends", Context.MODE_PRIVATE).getString(NAME_KEY, "") ?: ""

    private fun phaseChanged() {
        val s = RideStore.state.value
        val l = saved.link
        if (l == null || l.arrived) { settle(); return }
        when {
            s?.phase == Phase.FINISHED -> enqueue { arrive() }
            !running(s) -> enqueue { endNow() }
            else -> tick()
        }
    }

    private fun settle() {
        saved.endPending?.let { k -> enqueue { endOnRelay(k) } }
        val l = saved.link ?: return
        if (l.arrived) {
            if (now() >= (l.exp ?: (l.created + LiveRules.MAX_AGE))) { saved = saved.copy(link = null); save() }
            return
        }
        if (!running(RideStore.state.value)) enqueue { endNow() }
    }

    /** The ride's network tick, or the leg changed: the next state when it's due. */
    fun tick() {
        if (!attached) return
        if (saved.endPending != null) settle()
        val l = saved.link
        val s = RideStore.state.value
        if (l == null || l.arrived || putQueued) { if (l?.arrived == true) settle(); return }
        if (!running(s) || s == null) return
        if (LiveRules.expired(l.created, now())) { enqueue { endNow() }; return }
        val st = state(s, l) ?: return
        if (!LiveRules.due(l.lastSent, l.lastKey, LiveRules.key(st), now())) return
        putQueued = true
        enqueue {
            putQueued = false
            val cur = saved.link ?: return@enqueue
            val rs = RideStore.state.value ?: return@enqueue
            if (cur.arrived) return@enqueue
            state(rs, cur)?.let { put(it, arrived = false) }
        }
    }

    /** The trip as the page shows it: the state friends get (0.26), with how late and when the next ride leaves. */
    fun state(s: RideState, l: Link): LiveState? {
        val now = now()
        val tr = FriendTravelShare.build(s, now) ?: return null
        val leg = s.leg ?: return null
        var dep: Double? = null
        var late: Int? = null
        if (tr.stage != TravelState.Stage.RIDING) {
            dep = leg.departure
            if (leg.live) late = maxOf(0, leg.delay)
        } else if (s.eta != null) {
            late = LiveRules.late(s.eta, leg.scheduledArrival)
        }
        return LiveRules.state(tr, l.name, dep, late, now)
    }

    /** Makes a link for this trip and posts its first state; null: no trip runs, or the relay couldn't be reached. */
    suspend fun make(name: String): String? {
        val n = FriendNames.clean(name)
        val s = RideStore.state.value
        if (!canMake || s == null || n.isEmpty() || making.value) return null
        if (FriendStore.book.value?.myName.isNullOrEmpty()) ctx.getSharedPreferences("friends", Context.MODE_PRIVATE).edit().putString(NAME_KEY, n).apply()
        making.value = true
        problem.value = null
        try {
            return lane.withLock {
                saved.link?.takeIf { !it.arrived }?.let { endOnRelay(it.keys) }
                val l = Link(LiveKeys.make(), now(), n)
                saved = saved.copy(link = l)
                save()
                val st = state(s, l)
                if (st == null || !put(st, arrived = false)) {
                    saved = saved.copy(link = null)
                    save()
                    problem.value = "Couldn’t make the link. Check your connection and try again."
                    null
                } else l.keys.link
            }
        } finally { making.value = false }
    }

    /** "Stop sharing": the page says the link has ended, at once. */
    fun stop() {
        val l = saved.link ?: return
        saved = saved.copy(link = null)
        save()
        enqueue { endOnRelay(l.keys) }
    }

    private suspend fun arrive() {
        val l = saved.link ?: return
        if (l.arrived) return
        val stop = RideStore.state.value?.trip?.last?.toStop
        val st = LiveRules.arrived(l.last, l.name, stop, now())
        var ok = put(st, arrived = true)
        if (!ok) { delay(6000); ok = put(st, arrived = true) }
        val cur = saved.link ?: return
        if (cur.keys != l.keys) return
        if (ok) { saved = saved.copy(link = cur.copy(arrived = true)); save() } else endNow()
    }

    private suspend fun endNow() {
        val l = saved.link ?: return
        saved = saved.copy(link = null)
        save()
        endOnRelay(l.keys)
    }

    private suspend fun endOnRelay(k: LiveKeys) {
        val a = relay.end(k)
        saved = if (a is LiveRelay.Answer.Failed && a.status <= 0) saved.copy(endPending = k)
        else if (saved.endPending == k) saved.copy(endPending = null) else saved
        save()
    }

    private suspend fun put(s: LiveState, arrived: Boolean): Boolean {
        val l = saved.link ?: return false
        val data = try { LiveCrypto.lock(s, l.keys) } catch (_: Exception) { return false }
        val now = now()
        val a = relay.put(l.keys, data, LiveRules.until(l.created, now, arrived))
        val cur = saved.link ?: return false
        if (cur.keys != l.keys) return false
        return when (a) {
            is LiveRelay.Answer.Ok -> {
                saved = saved.copy(link = cur.copy(lastSent = now, lastKey = LiveRules.key(s), last = s, exp = a.exp?.toDouble()))
                problem.value = null
                save()
                true
            }
            LiveRelay.Answer.Ended -> { saved = saved.copy(link = null); save(); false }
            else -> false
        }
    }
}
