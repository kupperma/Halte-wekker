package nl.haltewekker.friends

import kotlinx.serialization.KSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.math.BigDecimal
import java.util.Base64

/** base64url (RFC 4648 §5) without padding, as the relay and the links use it; decoding takes padding too. */
object B64u {
    fun encode(b: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(b)
    fun decode(s: String): ByteArray? {
        if (!s.all { it.isLetterOrDigit() && it.code < 128 || it == '-' || it == '_' || it == '=' }) return null
        return try { Base64.getUrlDecoder().decode(s.trimEnd('=')) } catch (_: Exception) { null }
    }
}

object Hex {
    fun encode(b: ByteArray): String = buildString(b.size * 2) { for (x in b) append("%02x".format(x.toInt() and 0xff)) }
    fun decode(s: String): ByteArray? {
        if (s.length % 2 != 0) return null
        return try { ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() } } catch (_: Exception) { null }
    }
}

/**
 * The JSON every Friends value is written in, the same as the iOS app's `FriendJSON`: keys sorted, binary data as
 * base64url strings, dates as unix seconds (a plain number: `1800000000`, `51.44306`, never `1.8E9`), UTF-8 without
 * escaping what needn't be. Reading takes any order and ignores unknown keys; an optional key may be absent or null.
 */
object FriendJson {
    val json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
        encodeDefaults = true
        isLenient = false
    }

    fun <T> encode(serializer: KSerializer<T>, value: T): ByteArray = write(json.encodeToJsonElement(serializer, value)).toByteArray(Charsets.UTF_8)
    fun <T> encodeString(serializer: KSerializer<T>, value: T): String = write(json.encodeToJsonElement(serializer, value))

    fun <T> decode(serializer: KSerializer<T>, bytes: ByteArray): T? = decode(serializer, bytes.toString(Charsets.UTF_8))
    fun <T> decode(serializer: KSerializer<T>, text: String): T? = try { json.decodeFromString(serializer, text) } catch (_: Exception) { null }
    fun <T> decode(serializer: KSerializer<T>, e: JsonElement): T? = try { json.decodeFromJsonElement(serializer, e) } catch (_: Exception) { null }

    fun parse(bytes: ByteArray): JsonElement? = try { Json.parseToJsonElement(bytes.toString(Charsets.UTF_8)) } catch (_: Exception) { null }

    /** Writes a JSON value with sorted keys and plain numbers (nulls in objects left out). */
    fun write(e: JsonElement): String = StringBuilder().also { write(e, it) }.toString()

    private fun write(e: JsonElement, out: StringBuilder) {
        when (e) {
            is JsonNull -> out.append("null")
            is JsonObject -> {
                out.append('{')
                var first = true
                for (k in e.keys.sorted()) {
                    val v = e[k] ?: continue
                    if (v is JsonNull) continue
                    if (!first) out.append(',')
                    first = false
                    string(k, out); out.append(':'); write(v, out)
                }
                out.append('}')
            }
            is JsonArray -> {
                out.append('[')
                e.forEachIndexed { i, v -> if (i > 0) out.append(','); write(v, out) }
                out.append(']')
            }
            is JsonPrimitive -> when {
                e.isString -> string(e.content, out)
                e.content == "true" || e.content == "false" -> out.append(e.content)
                else -> out.append(number(e.content))
            }
        }
    }

    /** "1.8E9" → "1800000000", "12.0" → "12", "51.44306" stays. */
    fun number(s: String): String = try {
        val b = BigDecimal(s)
        if (b.signum() == 0) "0" else b.stripTrailingZeros().toPlainString()
    } catch (_: Exception) { s }

    private fun string(s: String, out: StringBuilder) {
        out.append('"')
        for (c in s) {
            when (c) {
                '"' -> out.append("\\\"")
                '\\' -> out.append("\\\\")
                '\n' -> out.append("\\n")
                '\r' -> out.append("\\r")
                '\t' -> out.append("\\t")
                '\b' -> out.append("\\b")
                '\u000C' -> out.append("\\f")
                else -> if (c.code < 0x20) out.append("\\u%04x".format(c.code)) else out.append(c)
            }
        }
        out.append('"')
    }
}
