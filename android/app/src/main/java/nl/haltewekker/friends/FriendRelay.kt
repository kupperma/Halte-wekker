package nl.haltewekker.friends

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.KSerializer
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.concurrent.TimeUnit

/**
 * Friends (0.25–0.26), the iOS `FriendRelay.swift`: the relay's routes (relay/friends.js), each request signed with your
 * account key. One try per request: a signed request can't be sent twice (the relay refuses a nonce it has seen).
 */
class FriendRelay(val me: FriendIdentity, val device: String, private val base: String = BASE, private val userAgent: String = "Haltewekker-Android") {
    sealed class Failure(msg: String) : Exception(msg) {
        /** The account moved to another phone (restored there with the backup code). */
        class SignedOut : Failure("signed_out")
        class UnknownAccount : Failure("unknown_account")
        class SlowDown : Failure("slow_down")
        class Refused(val status: Int, val code: String) : Failure("refused $status $code")
        class Offline : Failure("offline")
    }

    private fun body(obj: JsonObject): ByteArray = FriendJson.write(obj).toByteArray(Charsets.UTF_8)

    suspend fun <T> call(path: String, obj: JsonObject, out: KSerializer<T>): T = withContext(Dispatchers.IO) {
        val data = body(obj)
        val headers = RelaySign.headers(me, device, path, data, System.currentTimeMillis() / 1000, RelaySign.nonce())
        val req = Request.Builder().url(base + path).post(data.toRequestBody("application/json".toMediaType()))
            .header("User-Agent", userAgent).apply { headers.forEach { (k, v) -> header(k, v) } }.build()
        val (status, text) = try {
            client.newCall(req).execute().use { r -> r.code to (r.body?.string() ?: "") }
        } catch (_: Exception) {
            throw Failure.Offline()
        }
        if (status == 200) return@withContext FriendJson.decode(out, text) ?: throw Failure.Refused(200, "bad_answer")
        val code = ((FriendJson.parse(text.toByteArray()) as? JsonObject)?.get("error") as? JsonPrimitive)?.content ?: ""
        when {
            status == 409 -> throw Failure.SignedOut()
            status == 404 && code == "unknown_account" -> throw Failure.UnknownAccount()
            status == 429 -> throw Failure.SlowDown()
            else -> throw Failure.Refused(status, code)
        }
    }

    @kotlinx.serialization.Serializable private data class Deleted(val deleted: Int = 0)
    @kotlinx.serialization.Serializable private data class Ok(val ok: Boolean = true)

    suspend fun register(): RelayRegistered = call("/f/v1/register", buildJsonObject { put("signKey", B64u.encode(me.signKey)) }, RelayRegistered.serializer())

    suspend fun inbox(after: Long): RelayInbox =
        call("/f/v1/inbox", buildJsonObject { put("after", after); put("limit", 100) }, RelayInbox.serializer())

    suspend fun ack(ids: List<Long>) {
        if (ids.isEmpty()) return
        call("/f/v1/ack", buildJsonObject { put("ids", JsonArray(ids.map { JsonPrimitive(it) })) }, Deleted.serializer())
    }

    /** Up to 20 boxes; the relay answers for each. */
    suspend fun send(boxes: List<FriendPending>): List<RelaySendResult> {
        val list = boxes.map { b ->
            buildJsonObject {
                put("to", b.to); put("data", b.data ?: "")
                b.slot?.let { put("slot", it) }
                b.ttl?.let { put("ttl", it) }
            }
        }
        return call("/f/v1/send", JsonObject(mapOf("boxes" to JsonArray(list))), RelaySent.serializer()).results
    }

    suspend fun drop(peer: String) { call("/f/v1/drop", buildJsonObject { put("peer", peer) }, Ok.serializer()) }
    suspend fun block(peer: String, on: Boolean = true) { call("/f/v1/block", buildJsonObject { put("peer", peer); put("on", on) }, Ok.serializer()) }
    suspend fun vaultPut(data: ByteArray) { call("/f/v1/vault/put", buildJsonObject { put("data", B64u.encode(data)) }, Ok.serializer()) }
    suspend fun vaultGet(): ByteArray? = call("/f/v1/vault/get", JsonObject(emptyMap()), RelayVault.serializer()).data?.let { B64u.decode(it) }

    // MARK: latest states (0.26)

    suspend fun statePut(states: List<Pair<String, ByteArray>>, ttl: Int): List<RelaySendResult> {
        return call("/f/v1/state/put", statePutBody(states, ttl), RelaySent.serializer()).results
    }

    suspend fun stateGet(): List<RelayState> = call("/f/v1/state/get", JsonObject(emptyMap()), RelayStates.serializer()).states

    suspend fun stateClear(to: List<String>? = null): Int {
        val b = if (to == null) JsonObject(emptyMap()) else JsonObject(mapOf("to" to JsonArray(to.map { JsonPrimitive(it) })))
        return call("/f/v1/state/clear", b, RelayCleared.serializer()).cleared
    }

    suspend fun leave() { call("/f/v1/leave", JsonObject(emptyMap()), Ok.serializer()) }

    companion object {
        /** `{"states":[{"data","to","ttl"}]}` (sorted keys, as it's signed). */
        fun statePutBody(states: List<Pair<String, ByteArray>>, ttl: Int): JsonObject {
            val list: List<JsonElement> = states.map { (to, d) -> buildJsonObject { put("to", to); put("data", B64u.encode(d)); put("ttl", ttl) } }
            return JsonObject(mapOf("states" to JsonArray(list)))
        }

        fun bodyBytes(obj: JsonObject): ByteArray = FriendJson.write(obj).toByteArray(Charsets.UTF_8)

        const val BASE = "https://haltewekker-relay.tsfaw1.workers.dev"

        /** No retries of its own (a signed request must not go twice); short time limits. */
        val client: OkHttpClient by lazy {
            OkHttpClient.Builder()
                .connectTimeout(10, TimeUnit.SECONDS)
                .readTimeout(15, TimeUnit.SECONDS)
                .callTimeout(20, TimeUnit.SECONDS)
                .retryOnConnectionFailure(false)
                .build()
        }
    }
}
