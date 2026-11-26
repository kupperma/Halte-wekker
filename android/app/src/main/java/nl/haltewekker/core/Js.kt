package nl.haltewekker.core

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.time.Instant
import java.time.OffsetDateTime
import java.time.temporal.ChronoUnit

/**
 * Defensive reads of Transitous's JSON, like the iOS code's `as? String` casts: a missing or odd value is null, never a
 * crash.
 */
val JsonElement?.obj: JsonObject? get() = this as? JsonObject
val JsonElement?.arr: JsonArray? get() = this as? JsonArray
val JsonElement?.str: String?
    get() = (this as? JsonPrimitive)?.takeIf { it.isString }?.content
val JsonElement?.num: Double?
    get() = (this as? JsonPrimitive)?.takeIf { !it.isString && this !is JsonNull }?.content?.toDoubleOrNull()
val JsonElement?.bool: Boolean?
    get() = (this as? JsonPrimitive)?.takeIf { !it.isString }?.content?.toBooleanStrictOrNull()

/** A string or a number as text (iOS `Transit.text`). */
val JsonElement?.text: String
    get() {
        val p = this as? JsonPrimitive ?: return ""
        if (p is JsonNull) return ""
        if (p.isString) return p.content
        val d = p.content.toDoubleOrNull() ?: return p.content
        return if (d == Math.floor(d) && kotlin.math.abs(d) < 1e15) d.toLong().toString() else p.content
    }

fun JsonObject.o(k: String): JsonObject? = this[k].obj
fun JsonObject.a(k: String): List<JsonElement> = this[k].arr ?: emptyList()
fun JsonObject.s(k: String): String? = this[k].str
fun JsonObject.d(k: String): Double? = this[k].num
fun JsonObject.b(k: String): Boolean? = this[k].bool

/** Times as seconds since 1970 (Double, like Swift's `TimeInterval`). */
object Iso {
    fun parse(s: String?): Double? {
        if (s.isNullOrEmpty()) return null
        return try {
            OffsetDateTime.parse(s).toInstant().toEpochMilli() / 1000.0
        } catch (_: Exception) {
            try { Instant.parse(s).toEpochMilli() / 1000.0 } catch (_: Exception) { null }
        }
    }

    /** "2026-11-19T15:27:00Z": whole seconds, as the iOS app sends them. */
    fun format(t: Double): String = Instant.ofEpochMilli((t * 1000).toLong()).truncatedTo(ChronoUnit.SECONDS).toString()

    fun now(): Double = System.currentTimeMillis() / 1000.0
}

fun JsonObject.t(k: String): Double? = Iso.parse(this[k].str)
