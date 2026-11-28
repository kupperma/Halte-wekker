package nl.haltewekker.data

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import nl.haltewekker.core.Country
import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import java.time.Instant

/**
 * (0.10.13, iOS 0.42.17 `IRail.swift`) Belgian trains from iRail (open NMBS/SNCB data), through the relay's
 * `/be/liveboard`, `/be/vehicle` and `/be/composition`: read here, pure, checked on docs/belgium-vectors.json.
 * Transitous has SNCB's trains and often their live times but no platforms; iRail gives the platform (and whether it
 * changed), cancellations, the delay and how busy it is. iRail has no GPS: a Belgian train goes by its times.
 */
object IRail {
    data class Departure(val num: String, val planned: Double?, val actual: Double?, val track: String, val plannedTrack: String,
                         val changed: Boolean, val cancelled: Boolean, val crowd: Int)

    private fun obj(text: String?): JsonObject? {
        if (text == null) return null
        return try { Json.parseToJsonElement(text) as? JsonObject } catch (_: Exception) { null }
    }

    private fun JsonObject.s(k: String): String = (this[k] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content ?: ""
    private fun JsonObject.b(k: String): Boolean = (this[k] as? JsonPrimitive)?.content == "true"
    private fun JsonObject.n(k: String): Double = (this[k] as? JsonPrimitive)?.content?.toDoubleOrNull() ?: 0.0
    private fun JsonObject.d(k: String): Double? = (this[k] as? JsonPrimitive)?.takeIf { !it.isString }?.content?.toDoubleOrNull()

    fun time(s: String?): Double? =
        if (s.isNullOrEmpty()) null else try { Instant.parse(s).epochSecond.toDouble() } catch (_: Exception) {
            try { java.time.OffsetDateTime.parse(s).toEpochSecond().toDouble() } catch (_: Exception) { null } }

    fun iso(t: Double): String = Instant.ofEpochSecond(t.toLong()).toString()

    /** The relay's `/be/liveboard` answer. Null: not one. */
    fun departures(text: String?): List<Departure>? {
        val list = obj(text)?.get("departures") as? JsonArray ?: return null
        return list.mapNotNull { e ->
            val x = e as? JsonObject ?: return@mapNotNull null
            val planned = time(x.s("planned"))
            val track = x.s("platform")
            val changed = x.b("platformChanged")
            Departure(x.s("num"), planned, planned?.let { it + x.n("delay") }, track, if (changed) "" else track, changed, x.b("canceled"),
                mapOf("low" to 1, "medium" to 2, "high" to 3)[x.s("occupancy")] ?: 0)
        }
    }

    /** The relay's `/be/composition` answer: carriages and seats (null: none known). */
    fun composition(text: String?): Pair<Int, Int>? {
        val o = obj(text) ?: return null
        val cars = o.n("cars").toInt()
        return if (cars > 0) cars to o.n("seats").toInt() else null
    }

    fun isRail(mode: String): Boolean = mode.contains("RAIL") || mode == "LONG_DISTANCE" || mode == "SUBURBAN"

    private fun stops(l: JsonObject): List<JsonObject> =
        listOfNotNull(l["from"] as? JsonObject) + ((l["intermediateStops"] as? JsonArray)?.mapNotNull { it as? JsonObject } ?: emptyList()) +
            listOfNotNull(l["to"] as? JsonObject)

    /** The train number to ask iRail about: the first rail leg with a plain number that stops in Belgium. */
    fun trainNumber(trip: String?): String? = trainNumber(obj(trip))

    fun trainNumber(trip: JsonObject?): String? {
        for (e in (trip?.get("legs") as? JsonArray) ?: return null) {
            val l = e as? JsonObject ?: continue
            if (!isRail(l.s("mode"))) continue
            val n = l.s("tripShortName")
            if (n.length !in 1..6 || !n.all { it in '0'..'9' }) continue
            if (stops(l).any { Country.of(it.s("stopId"), it.d("lat"), it.d("lon")) == Country.BE }) return n
        }
        return null
    }

    /** The relay's question for that train: `/be/vehicle?id=9235&date=281126` (as path and parameters). */
    fun vehicleParams(tripId: String, num: String): List<Pair<String, String>>? {
        if (num.length !in 1..6 || !num.all { it in '0'..'9' }) return null
        val day = tripId.takeWhile { it != '_' }
        return if (day.length == 8 && day.all { it in '0'..'9' }) listOf("id" to num, "date" to day.substring(6, 8) + day.substring(4, 6) + day.substring(2, 4))
        else listOf("id" to num)
    }

    /** As iOS writes it, for the vectors: "/be/vehicle?id=9235&date=281126". */
    fun vehiclePath(tripId: String, num: String): String? =
        vehicleParams(tripId, num)?.let { p -> "/be/vehicle?" + p.joinToString("&") { "${it.first}=${it.second}" } }

    private fun match(s: JsonObject, list: List<JsonObject>): JsonObject? {
        Country.uic(s.s("stopId"))?.let { u -> list.firstOrNull { it.s("uic") == u }?.let { return it } }
        val la = s.d("lat") ?: return null
        val lo = s.d("lon") ?: return null
        val p = GeoPoint(la, lo)
        return list.mapNotNull { x -> val a = x.d("lat"); val b = x.d("lon"); if (a == null || b == null) null else x to Geo.metres(p, GeoPoint(a, b)) }
            .filter { it.second <= 400.0 }.minByOrNull { it.second }?.first
    }

    private fun patch(s: JsonObject, v: JsonObject, retime: Boolean): Pair<JsonObject, Boolean> {
        val o = s.toMutableMap()
        val platform = v.s("platform")
        val changed = v.b("platformChanged")
        if (platform.isNotEmpty()) {
            if (s.s("track").isEmpty()) o["track"] = JsonPrimitive(platform)
            if (s.s("scheduledTrack").isEmpty() && !changed) o["scheduledTrack"] = JsonPrimitive(platform)
        }
        if (v.b("arrivalCanceled") || v.b("departureCanceled")) o["cancelled"] = JsonPrimitive(true)
        val ad = v.n("arrivalDelay")
        val dd = v.n("departureDelay")
        val live = ad != 0.0 || dd != 0.0 || v.b("arrived") || v.b("left")
        if (retime) {
            time(s.s("scheduledArrival"))?.let { o["arrival"] = JsonPrimitive(iso(it + ad)) }
            time(s.s("scheduledDeparture"))?.let { o["departure"] = JsonPrimitive(iso(it + dd)) }
        }
        return JsonObject(o) to live
    }

    /**
     * A Transitous trip with iRail's answer for its train laid over it: on each rail leg of that train, each Belgian
     * stop gets its platform, its cancellation and, when Transitous had no live times, iRail's delays (the leg is then
     * live). Dutch stops are left to NS. Another train's answer changes nothing.
     */
    fun overlay(trip: JsonObject, vehicle: JsonObject): JsonObject {
        val num = vehicle.s("num")
        val list = (vehicle["stops"] as? JsonArray)?.mapNotNull { it as? JsonObject } ?: emptyList()
        val legs = trip["legs"] as? JsonArray ?: return trip
        if (num.isEmpty() || list.isEmpty()) return trip
        val out = legs.map { e ->
            val l = e as? JsonObject ?: return@map e
            if (!isRail(l.s("mode")) || l.s("tripShortName") != num) return@map e
            val retime = !l.b("realTime")
            var live = false
            fun one(s: JsonObject): JsonObject {
                val v = match(s, list) ?: return s
                if (!v.s("uic").startsWith("88")) return s
                val (o, lv) = patch(s, v, retime)
                if (lv) live = true
                return o
            }
            val m = l.toMutableMap()
            (l["from"] as? JsonObject)?.let { m["from"] = one(it) }
            (l["intermediateStops"] as? JsonArray)?.let { a -> m["intermediateStops"] = JsonArray(a.map { (it as? JsonObject)?.let(::one) ?: it }) }
            (l["to"] as? JsonObject)?.let { m["to"] = one(it) }
            if (retime && live) {
                m["realTime"] = JsonPrimitive(true)
                ((m["from"] as? JsonObject)?.get("departure"))?.let { m["startTime"] = it }
                ((m["to"] as? JsonObject)?.get("arrival"))?.let { m["endTime"] = it }
            }
            JsonObject(m)
        }
        return JsonObject(trip.toMutableMap().also { it["legs"] = JsonArray(out) })
    }

    /** The same on the answers' text: null when either isn't one. */
    fun overlay(tripText: String?, vehicleText: String?): String? {
        val t = obj(tripText) ?: return null
        val v = obj(vehicleText) ?: return null
        return overlay(t, v).toString()
    }
}
