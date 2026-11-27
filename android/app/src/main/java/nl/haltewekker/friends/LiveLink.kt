package nl.haltewekker.friends

import kotlinx.serialization.Serializable
import java.security.MessageDigest
import java.time.ZoneId
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlin.math.max
import kotlin.math.min

// Live link (0.30), the iOS `LiveLink.swift`: a web page with your trip's live times for someone without the app (a
// parent), as plain values, the lock and the rules, tested without the relay or the ride.
//
//   link   = https://haltewekker-relay.tsfaw1.workers.dev/live/<token>#k=<key>   (0.30 made "#<key>": both read)
//   secret = 32 random bytes (stays on the phone: it lets the phone write)   key = 32 random bytes (AES-256-GCM)
//   token  = base64url(first 16 bytes of SHA-256("hw-live-token-v1" ‖ secret))
//   data   = 0x01 ‖ nonce (12) ‖ AES-256-GCM(key, AAD "hw-live-v1\n" + token)(the state's JSON) ‖ tag (16)
// The key is only in the link's fragment, which a browser never sends: the relay (relay/live.js) holds only locked bytes.
// AES-GCM is the platform's own (javax.crypto, there on every Android version the app runs on).

/** What the page shows: a trip's state now (the 0.26 travel state, cut down), locked into each put. */
@Serializable
data class LiveState(
    val v: Int = 1,
    val name: String,
    /** "waiting" | "riding" | "change" | "arrived" (unknown reads as riding). */
    val state: String,
    val mode: String,
    val line: String? = null,
    val num: String? = null,
    val from: String? = null,
    val to: String? = null,
    val dest: String? = null,
    val dep: Double? = null,
    val eta: Double? = null,
    val end: Double? = null,
    val late: Int? = null,
    val pos: Position? = null,
    val t: Double,
    // (v2, relay 2026-11-27: `LiveTripV2`) the whole trip; a page before it, and 0.30's readers, ignore these
    val face: String? = null,
    val inbox: Boolean? = null,
    val leg: Int? = null,
    val legs: List<LiveLeg>? = null,
    val music: LiveMusic? = null,
    val next: Int? = null,
    /** (0.10.6) The version of the sharer's picture at `/live/v1/face` (`LiveFace`): the page fetches it again when it changes. */
    val pic: Int? = null,
    val shape: String? = null,
    val stops: List<LiveStop>? = null,
) {
    /** `src` (v2): "gps" the vehicle's own position from the open feeds, "phone" this phone's. */
    @Serializable data class Position(val lat: Double, val lon: Double, val at: Double, val src: String? = null)

    enum class Stage { WAITING, RIDING, CHANGE, ARRIVED }

    val stage: Stage get() = when (state) { "waiting" -> Stage.WAITING; "change" -> Stage.CHANGE; "arrived" -> Stage.ARRIVED; else -> Stage.RIDING }
}

/** A link's two secrets (kept on this phone only). */
@Serializable
data class LiveKeys(val secret: String, val key: String) {
    val secretBytes: ByteArray get() = B64u.decode(secret) ?: ByteArray(0)
    val keyBytes: ByteArray get() = B64u.decode(key) ?: ByteArray(0)
    val token: String get() = LiveCrypto.token(secretBytes)
    val link: String get() = LiveCrypto.link(token, keyBytes)

    companion object {
        fun of(secret: ByteArray, key: ByteArray) = LiveKeys(B64u.encode(secret), B64u.encode(key))
        fun make() = of(FriendCrypto.randomBytes(32), FriendCrypto.randomBytes(32))
    }
}

class LiveCryptoException : Exception("can't open")

object LiveCrypto {
    const val RELAY = "https://haltewekker-relay.tsfaw1.workers.dev"
    const val VERSION: Byte = 1
    /** (relay 2026-11-27) The app's own address for a live link, `haltewekker://live/<token>#k=<key>` (the page's "Open in Haltewekker"). */
    const val SCHEME = "haltewekker://live"

    fun token(secret: ByteArray): String {
        val h = MessageDigest.getInstance("SHA-256").digest("hw-live-token-v1".toByteArray() + secret)
        return B64u.encode(h.copyOfRange(0, 16))
    }

    /** (relay 0.30.1) The key goes as `#k=<key>`: a fragment some apps keep whole where they cut a bare one short. */
    fun link(token: String, key: ByteArray) = "$RELAY/live/$token#k=${B64u.encode(key)}"

    /** A link back into its token and key, `#k=<key>` or 0.30's `#<key>` (null: not a live link of this relay, or no key). */
    fun parse(s: String): Pair<String, ByteArray>? {
        val t = s.trim()
        val prefix = listOf("$RELAY/live/", "$SCHEME/").firstOrNull { t.startsWith(it) } ?: return null
        val parts = t.removePrefix(prefix).split("#", limit = 2)
        val token = parts[0].removeSuffix("/")
        if (parts.size != 2 || token.length != 22 || !token.all { it.isLetterOrDigit() && it.code < 128 || it == '-' || it == '_' }) return null
        val k = Regex("(?:^|[&;?])k=([^&;]*)").find(parts[1])?.groupValues?.get(1) ?: parts[1]
        val key = B64u.decode(k) ?: return null
        if (key.size != 32) return null
        return token to key
    }

    fun aad(token: String) = "hw-live-v1\n$token".toByteArray(Charsets.UTF_8)

    fun seal(plain: ByteArray, key: ByteArray, token: String, nonce: ByteArray = FriendCrypto.randomBytes(12)): ByteArray {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        c.updateAAD(aad(token))
        return byteArrayOf(VERSION) + nonce + c.doFinal(plain)
    }

    fun open(data: ByteArray, key: ByteArray, token: String): ByteArray {
        if (data.size < 1 + 12 + 16 || data[0] != VERSION) throw LiveCryptoException()
        return try {
            val c = Cipher.getInstance("AES/GCM/NoPadding")
            c.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, data.copyOfRange(1, 13)))
            c.updateAAD(aad(token))
            c.doFinal(data.copyOfRange(13, data.size))
        } catch (_: Exception) { throw LiveCryptoException() }
    }

    /** A state as it goes: its JSON (sorted keys, plain numbers), locked. */
    fun lock(s: LiveState, keys: LiveKeys): ByteArray = seal(FriendJson.encode(LiveState.serializer(), s), keys.keyBytes, keys.token)

    /** (relay 2026-11-27) The other two kinds, each with its own AAD: a message to the sharer, and the sharer's answer. */
    fun aad(token: String, kind: String) = "$kind\n$token".toByteArray(Charsets.UTF_8)

    fun sealAs(kind: String, plain: ByteArray, key: ByteArray, token: String, nonce: ByteArray = FriendCrypto.randomBytes(12)): ByteArray {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        c.updateAAD(aad(token, kind))
        return byteArrayOf(VERSION) + nonce + c.doFinal(plain)
    }

    fun openAs(kind: String, data: ByteArray, key: ByteArray, token: String): ByteArray {
        if (data.size < 1 + 12 + 16 || data[0] != VERSION) throw LiveCryptoException()
        return try {
            val c = Cipher.getInstance("AES/GCM/NoPadding")
            c.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, data.copyOfRange(1, 13)))
            c.updateAAD(aad(token, kind))
            c.doFinal(data.copyOfRange(13, data.size))
        } catch (_: Exception) { throw LiveCryptoException() }
    }
}

object LiveRules {
    const val MAX_AGE = 4 * 3600.0
    const val AHEAD = 30 * 60.0
    const val AFTER_ARRIVAL = 15 * 60.0
    const val EVERY = 55.0
    const val MIN_GAP = 6.0
    const val STALE_AFTER = 150.0

    fun due(lastSent: Double?, lastKey: String, key: String, now: Double): Boolean {
        lastSent ?: return true
        val gap = now - lastSent
        if (gap < 0) return true
        if (gap < MIN_GAP) return false
        return key != lastKey || gap >= EVERY
    }

    fun until(created: Double, now: Double, arrived: Boolean = false): Double =
        min(now + if (arrived) AFTER_ARRIVAL else AHEAD, created + MAX_AGE)

    fun expired(created: Double, now: Double) = now - created >= MAX_AGE

    fun state(s: TravelState, name: String, dep: Double?, late: Int?, now: Double): LiveState = LiveState(
        name = FriendNames.clean(name), state = s.state, mode = s.mode, line = s.line, num = s.num, from = s.from.name, to = s.to.name,
        dest = s.dest?.name?.takeIf { it != s.to.name }, dep = if (s.stage != TravelState.Stage.RIDING) dep else null,
        eta = s.eta, end = s.end, late = late?.clampTo(0, 600), pos = s.pos?.let { LiveState.Position(it.lat, it.lon, it.at) }, t = now)

    fun arrived(last: LiveState?, name: String, stop: String?, at: Double) = LiveState(
        name = FriendNames.clean(name), state = "arrived", mode = last?.mode ?: "bus", line = last?.line, num = last?.num, from = last?.from,
        to = stop ?: last?.dest ?: last?.to, eta = at, t = at)

    fun late(live: Double?, scheduled: Double?): Int? {
        if (live == null || scheduled == null) return null
        return max(0, ((live - scheduled) / 60).roundHalfAway())
    }

    fun key(s: LiveState) = "${s.state}|${s.mode}|${s.line ?: ""}|${s.num ?: ""}|${s.from ?: ""}|${s.to ?: ""}|${s.music?.title ?: ""}|${s.pic ?: 0}"
}

/** The page's words, the same in the app and on the page (relay/live.js does the same). */
object LiveWords {
    fun vehicle(s: LiveState): String {
        val line = (s.line ?: "").trim()
        val num = (s.num ?: "").trim()
        val mode = s.mode.ifEmpty { "bus" }
        if (mode == "train") return if (line.isEmpty()) "the train" else "the " + (if (num.isEmpty()) line else "$line $num")
        return if (line.isEmpty()) "the $mode" else "$mode $line"
    }

    private fun late(s: LiveState): String {
        val l = s.late ?: return ""
        return if (l >= 1) " · $l min late" else " · on time"
    }

    fun headline(s: LiveState, zone: ZoneId = TimetableDays.zone): String {
        val n = s.name.trim().ifEmpty { "Your friend" }
        val v = vehicle(s)
        val to = s.to?.let { " to $it" } ?: ""
        fun clock(t: Double) = TravelWords.clock(t, zone)
        return when (s.stage) {
            LiveState.Stage.ARRIVED -> n + " has arrived" + (s.to?.let { " at $it" } ?: "") + (s.eta?.let { " · " + clock(it) } ?: "")
            LiveState.Stage.WAITING -> n + " is waiting for " + v + to + (s.from?.let { " at $it" } ?: "") + (s.dep?.let { " · leaves " + clock(it) } ?: "") + late(s)
            LiveState.Stage.CHANGE -> {
                val at = s.from?.let { " at $it" } ?: ""
                if (s.line == null) n + " is changing" + at
                else n + " is changing" + at + " · then " + v + to + (s.dep?.let { " at " + clock(it) } ?: "")
            }
            LiveState.Stage.RIDING -> n + " is on " + v + to + (s.eta?.let { " · arrives " + clock(it) } ?: "") + late(s)
        }
    }

    fun detail(s: LiveState, zone: ZoneId = TimetableDays.zone): String? {
        if (s.stage == LiveState.Stage.ARRIVED) return null
        val d = s.dest ?: return null
        if (d == s.to) return null
        return "Then on to $d" + (s.end?.let { " · there around " + TravelWords.clock(it, zone) } ?: "")
    }
}
