package nl.haltewekker.friends

import kotlinx.serialization.Serializable
import kotlinx.serialization.Transient

// Friends (0.25), the iOS `FriendKeys.swift` and `FriendWords.swift`: who you are to the relay and to your friends.
//
// Everything comes from one secret, the 16 random bytes the backup code spells (BIP-39, 12 words):
//   signing key   = Ed25519 from HKDF-SHA256(seed, salt "haltewekker-seed-v1", info "sign")
//   agreement key = X25519 from the same, info "agree"
//   vault key     = ChaCha20-Poly1305 key from the same, info "vault" (locks the friend list kept on the relay)
//   account id    = hex of the first 16 bytes of SHA-256("haltewekker-account-v1" ‖ the signing public key)

/** The backup code: BIP-39 English, 12 words for 16 bytes, the last word carrying a 4-bit checksum. */
object FriendWords {
    const val COUNT = 12
    val list: List<String> get() = FriendWordList.words
    private val index: Map<String, Int> by lazy { list.withIndex().associate { it.value to it.index } }
    private val byPrefix: Map<String, Int> by lazy { list.withIndex().associate { it.value.take(4) to it.index } }

    fun encode(entropy: ByteArray): List<String> {
        require(entropy.size == 16) { "the backup code holds 16 bytes" }
        val bits = BooleanArray(132)
        for (i in 0 until 128) bits[i] = (entropy[i / 8].toInt() shr (7 - i % 8)) and 1 == 1
        val check = FriendCrypto.sha256(entropy)[0].toInt()
        for (i in 0 until 4) bits[128 + i] = (check shr (7 - i)) and 1 == 1
        return (0 until COUNT).map { w ->
            var n = 0
            for (i in 0 until 11) n = (n shl 1) or (if (bits[w * 11 + i]) 1 else 0)
            list[n]
        }
    }

    /** The 16 bytes back, or null: not 12 words, a word not in the list, or the checksum wrong. */
    fun decode(words: List<String>): ByteArray? {
        if (words.size != COUNT) return null
        val bits = BooleanArray(132)
        words.forEachIndexed { w, word ->
            val n = number(word) ?: return null
            for (i in 0 until 11) bits[w * 11 + i] = (n shr (10 - i)) and 1 == 1
        }
        val bytes = ByteArray(16)
        for (i in 0 until 128) if (bits[i]) bytes[i / 8] = (bytes[i / 8].toInt() or (1 shl (7 - i % 8))).toByte()
        val check = FriendCrypto.sha256(bytes)[0].toInt()
        for (i in 0 until 4) if (bits[128 + i] != ((check shr (7 - i)) and 1 == 1)) return null
        return bytes
    }

    /** A word's number: the word itself, or its first four letters (or more). */
    fun number(word: String): Int? {
        val w = word.lowercase()
        index[w]?.let { return it }
        if (w.length < 4) return null
        return byPrefix[w.take(4)]
    }

    /** The words in what someone typed or pasted: any case, split on anything that isn't a letter. */
    fun words(text: String): List<String> = text.lowercase().split(Regex("[^\\p{L}]+")).filter { it.isNotEmpty() }

    fun completions(prefix: String, limit: Int = 4): List<String> {
        val p = prefix.lowercase()
        if (p.isEmpty()) return emptyList()
        return list.asSequence().filter { it.startsWith(p) }.take(limit).toList()
    }
}

/** What a friend needs to send you boxes: your two public keys (`{"s","a"}` in JSON, base64url). */
@Serializable
data class FriendCard(val s: String, val a: String) {
    @Transient val signKey: ByteArray = B64u.decode(s) ?: ByteArray(0)
    @Transient val agreeKey: ByteArray = B64u.decode(a) ?: ByteArray(0)

    val isValid: Boolean get() = signKey.size == 32 && agreeKey.size == 32
    val account: String get() = FriendIdentity.accountId(signKey)

    /** Both keys in one string (the links' `k`): base64url of the 64 bytes. */
    val packed: String get() = B64u.encode(signKey + agreeKey)

    override fun equals(other: Any?): Boolean = other is FriendCard && signKey.contentEquals(other.signKey) && agreeKey.contentEquals(other.agreeKey)
    override fun hashCode(): Int = signKey.contentHashCode() * 31 + agreeKey.contentHashCode()

    companion object {
        fun of(signKey: ByteArray, agreeKey: ByteArray): FriendCard? =
            if (signKey.size == 32 && agreeKey.size == 32) FriendCard(B64u.encode(signKey), B64u.encode(agreeKey)) else null

        fun packed(k: String): FriendCard? {
            val d = B64u.decode(k) ?: return null
            if (d.size != 64) return null
            return of(d.copyOfRange(0, 32), d.copyOfRange(32, 64))
        }
    }
}

/** Your Friends account: the seed and the keys from it. */
class FriendIdentity(val seed: ByteArray) {
    init { require(seed.size == SEED_BYTES) }
    val signSecret: ByteArray = derive(seed, "sign")
    val agreeSecret: ByteArray = derive(seed, "agree")
    val vaultKey: ByteArray = derive(seed, "vault")
    val signKey: ByteArray = FriendCrypto.edPublic(signSecret)
    val agreeKey: ByteArray = FriendCrypto.xPublic(agreeSecret)
    val account: String = accountId(signKey)
    val card: FriendCard = FriendCard.of(signKey, agreeKey)!!
    val words: List<String> get() = FriendWords.encode(seed)

    fun sign(message: ByteArray): ByteArray = FriendCrypto.sign(signSecret, message)

    companion object {
        const val SEED_BYTES = 16

        fun random(): FriendIdentity = FriendIdentity(FriendCrypto.randomBytes(SEED_BYTES))
        fun fromWords(words: List<String>): FriendIdentity? = FriendWords.decode(words)?.let { FriendIdentity(it) }
        fun fromSeed(seed: ByteArray?): FriendIdentity? = if (seed?.size == SEED_BYTES) FriendIdentity(seed) else null

        fun derive(seed: ByteArray, info: String): ByteArray =
            FriendCrypto.hkdf(seed, "haltewekker-seed-v1".toByteArray(), info.toByteArray(), 32)

        fun accountId(signKey: ByteArray): String =
            Hex.encode(FriendCrypto.sha256("haltewekker-account-v1".toByteArray(), signKey).copyOf(16))

        fun isAccount(s: String): Boolean = s.length == 32 && s.all { it in '0'..'9' || it in 'a'..'f' }
    }
}

/** How a request to the relay is signed (relay/friends.js checks it the same way). */
object RelaySign {
    /** "HW1\n" + method + "\n" + path + "\n" + account + "\n" + device + "\n" + time + "\n" + nonce + "\n" + hex(SHA-256(body)) */
    fun canonical(method: String, path: String, account: String, device: String, time: Long, nonce: String, body: ByteArray): String =
        listOf("HW1", method, path, account, device, time.toString(), nonce, Hex.encode(FriendCrypto.sha256(body))).joinToString("\n")

    /** 16 random bytes, base64url (22 characters). */
    fun nonce(): String = B64u.encode(FriendCrypto.randomBytes(16))

    /** A phone's id for the relay (one phone at a time per account): 16 random bytes in hex. */
    fun newDevice(): String = Hex.encode(FriendCrypto.randomBytes(16))

    fun headers(me: FriendIdentity, device: String, path: String, body: ByteArray, time: Long, nonce: String): Map<String, String> {
        val text = canonical("POST", path, me.account, device, time, nonce, body)
        return mapOf(
            "X-HW-Account" to me.account,
            "X-HW-Device" to device,
            "X-HW-Time" to time.toString(),
            "X-HW-Nonce" to nonce,
            "X-HW-Signature" to B64u.encode(me.sign(text.toByteArray())),
            "Content-Type" to "application/json",
        )
    }
}

object FriendNames {
    const val MAX_LENGTH = 40

    /** As shown and sent: control characters out, whitespace runs one space, trimmed, at most 40 characters. */
    fun clean(s: String): String {
        val one = cleanLine(s)
        return takeChars(one, MAX_LENGTH).trim()
    }

    /** One line from someone else (a class's title, a room): no control characters, single spaces, trimmed. */
    fun cleanLine(s: String): String =
        s.split(Regex("\\s+")).map { w -> w.filter { !Character.isISOControl(it) } }.filter { it.isNotEmpty() }.joinToString(" ")

    /** The first `n` characters (code points, as Swift counts roughly), never cutting a surrogate pair. */
    fun takeChars(s: String, n: Int): String {
        if (s.codePointCount(0, s.length) <= n) return s
        return s.substring(0, s.offsetByCodePoints(0, n))
    }

    /** "SJ" for "Sam Jansen", "S" for "Sam". */
    fun initials(name: String): String {
        val s = name.split(" ").filter { it.isNotEmpty() }.take(2).mapNotNull { it.firstOrNull()?.uppercase() }.joinToString("")
        return s.ifEmpty { "?" }
    }
}

/**
 * The friend code as a link or QR code: `haltewekker://friend?v=1&k=<both keys>&n=<name>`, or the same fields after the
 * # of `https://haltewekker-relay.tsfaw1.workers.dev/add#v=1&k=…&n=…` (the fields never reach the server).
 */
object FriendLink {
    const val PAGE = "https://haltewekker-relay.tsfaw1.workers.dev/add"
    private const val PLAIN = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"

    /** Only letters, digits and "-._~" stay; everything else is %-encoded (UTF-8). */
    fun encode(s: String): String = buildString {
        for (b in s.toByteArray(Charsets.UTF_8)) {
            val c = (b.toInt() and 0xff).toChar()
            if (b >= 0 && c in PLAIN) append(c) else append("%%%02X".format(b.toInt() and 0xff))
        }
    }

    fun fields(card: FriendCard, name: String): String = "v=1&k=${card.packed}&n=${encode(FriendNames.clean(name))}"
    fun app(card: FriendCard, name: String): String = "haltewekker://friend?" + fields(card, name)
    fun share(card: FriendCard, name: String): String = PAGE + "#" + fields(card, name)

    private fun percentDecode(s: String): String? {
        val out = java.io.ByteArrayOutputStream()
        var i = 0
        while (i < s.length) {
            val c = s[i]
            if (c == '%') {
                val h = s.substring(i + 1, minOf(i + 3, s.length))
                if (h.length != 2) return null
                out.write(h.toIntOrNull(16) ?: return null)
                i += 3
            } else {
                out.write(c.toString().toByteArray(Charsets.UTF_8))
                i++
            }
        }
        return try {
            val dec = Charsets.UTF_8.newDecoder()
            dec.decode(java.nio.ByteBuffer.wrap(out.toByteArray())).toString()
        } catch (_: Exception) { null }
    }

    /** A card and a name from either form (null: not a friend code). */
    fun parse(text: String): Pair<FriendCard, String>? {
        val t = text.trim()
        val query: String
        val lower = t.lowercase()
        if (lower.startsWith("haltewekker://friend")) {
            val q = t.indexOf('?')
            if (q < 0) return null
            val rest = t.substring("haltewekker://friend".length)
            if (!(rest.startsWith("?") || rest.startsWith("/?"))) return null
            query = t.substring(q + 1).substringBefore('#')
        } else if (lower.startsWith("https://")) {
            val noScheme = t.substring(8)
            val hostEnd = noScheme.indexOfAny(charArrayOf('/', '?', '#')).let { if (it < 0) noScheme.length else it }
            val host = noScheme.substring(0, hostEnd).lowercase()
            if (!host.endsWith("workers.dev")) return null
            val after = noScheme.substring(hostEnd)
            val path = after.substringBefore('#').substringBefore('?')
            if (path != "/add") return null
            if (!after.contains('#')) return null
            query = after.substringAfter('#')
        } else return null
        val items = HashMap<String, String>()
        for (pair in query.split('&')) {
            val eq = pair.indexOf('=')
            if (eq < 0) continue
            val raw = pair.substring(eq + 1).replace('+', ' ')
            items[pair.substring(0, eq)] = percentDecode(raw) ?: raw
        }
        if ((items["v"] ?: "1") != "1") return null
        val card = FriendCard.packed(items["k"] ?: return null) ?: return null
        return card to FriendNames.clean(items["n"] ?: "")
    }
}
