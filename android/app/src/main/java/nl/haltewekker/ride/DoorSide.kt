package nl.haltewekker.ride

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.data.TripStop
import java.util.Locale

/**
 * (0.10.6, iOS 0.42.9) Which side you get out of the train: "Exit on the left · platform 4". The relay works it out from
 * OpenStreetMap (`/rail/v1/side`, map data © OpenStreetMap contributors) for the station, its platform and the stop
 * before (so the way the train goes); asked once a train leg knows the platform it gets in at, again only when that
 * platform changes, never while the alarm rings. Unknown: nothing is shown. Pure, tested against
 * docs/door-side-vectors.json (the vectors iOS and the relay check too).
 */
object DoorSide {
    data class Answer(val side: String, val low: Boolean)

    /** What the app asks for: the station, its platform, the stop before and the station's place. */
    data class Ask(val station: String, val track: String, val from: GeoPoint, val at: GeoPoint) {
        val key: String get() = "$station|$track|${query()}"
        fun query(): String = "station=$station&track=$track&from=${c(from.lat)},${c(from.lon)}&at=${c(at.lat)},${c(at.lon)}"
    }

    private fun c(x: Double) = String.format(Locale.ROOT, "%.4f", x)

    fun cleanTrack(t: String?): String = (t ?: "").trim().lowercase(Locale.ROOT).filter { !it.isWhitespace() }

    /** The relay's answer; null when it says nothing usable (unknown, busy, not JSON). No confidence: a guess. */
    fun parse(body: String?): Answer? {
        val o = try { Json.parseToJsonElement(body ?: return null) as? JsonObject } catch (_: Exception) { null } ?: return null
        val side = ((o["side"] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: return null).lowercase(Locale.ROOT)
        if (side !in setOf("left", "right", "both")) return null
        val conf = (o["confidence"] as? JsonPrimitive)?.takeIf { it.isString }?.content?.lowercase(Locale.ROOT)
        return Answer(side, conf != "high")
    }

    /** "Exit on the left · platform 4", "Exit on both sides · platform 2", "… (estimate)"; null: nothing to say. */
    fun line(a: Answer?, track: String?): String? {
        a ?: return null
        val where = if (a.side == "both") "on both sides" else "on the ${a.side}"
        val t = (track ?: "").trim()
        return "Exit $where" + (if (t.isEmpty()) "" else " · platform $t") + (if (a.low) " (estimate)" else "")
    }

    /** A notification's text with the line after it ("…\nExit on the left · platform 4"). */
    fun withLine(text: String, line: String?): String = if (line.isNullOrBlank()) text else "$text\n$line"

    /**
     * The question for a train leg to `to`, from its trip's stops: your stop (the one nearest `to`, within 500 m), the
     * platform it gets in at there, and the stop before it. Null: not a train, no platform, no stop before, no code.
     */
    fun ask(train: Boolean, stops: List<TripStop>, to: GeoPoint, code: String?): Ask? {
        if (!train || code.isNullOrBlank() || stops.size < 2) return null
        val i = stops.indices.minByOrNull { Geo.metres(stops[it].point, to) } ?: return null
        if (i == 0 || Geo.metres(stops[i].point, to) > 500) return null
        val track = cleanTrack(stops[i].track)
        if (!Regex("^[0-9]{1,2}[a-z]?$").matches(track)) return null
        return Ask(code.uppercase(Locale.ROOT), track, stops[i - 1].point, stops[i].point)
    }
}
