package nl.haltewekker.travel

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlin.math.max
import kotlin.math.min

/** (A6, iOS 0.37 `OVFiets.swift`) how many OV-fiets are left at a station: the relay's `/ns/ovfiets?station=BD`. Pure. */
object OVFiets {
    data class Point(val name: String, val code: String, val bikes: Int?, val open: Boolean?)

    data class Answer(val station: String, val points: List<Point>) {
        val total: Int? get() = points.mapNotNull { it.bikes }.takeIf { it.isNotEmpty() }?.sum()
        val closed: Boolean? get() = points.mapNotNull { it.open }.takeIf { it.isNotEmpty() }?.let { !it.contains(true) }
    }

    fun parse(text: String, station: String): Answer? {
        val j = try { Json.parseToJsonElement(text) } catch (_: Exception) { return null }
        return parse(j, station)
    }

    private fun str(a: JsonElement?) = (a as? JsonPrimitive)?.takeIf { it.isString }?.content

    private fun int(a: JsonElement?): Int? {
        val p = a as? JsonPrimitive ?: return null
        if (p.isString) return p.content.trim().toIntOrNull()?.takeIf { it >= 0 }
        if (p.booleanOrNull != null) return null
        return p.doubleOrNull?.toInt()?.takeIf { it >= 0 }
    }

    private fun open(a: JsonElement?): Boolean? = when (str(a)?.lowercase()) { "yes" -> true; "no" -> false; else -> null }

    fun parse(json: JsonElement, station: String): Answer? {
        val want = station.uppercase()
        val d = json as? JsonObject ?: return null
        (d["locations"] as? JsonArray)?.let { list ->
            val pts = list.mapNotNull { it as? JsonObject }.map { m -> Point(str(m["name"]) ?: "", str(m["code"]) ?: "", int(m["bikes"]), open(m["open"])) }
            return Answer((str(d["station"]) ?: want).uppercase(), pts)
        }
        val payload = d["payload"] as? JsonArray ?: return null
        val pts = ArrayList<Point>()
        for (p in payload.mapNotNull { it as? JsonObject }) for (m in (p["locations"] as? JsonArray)?.mapNotNull { it as? JsonObject } ?: emptyList()) {
            val sc = str(m["stationCode"])?.uppercase()
            if (sc != null && sc != want) continue
            val extra = m["extra"] as? JsonObject
            pts.add(Point(str(m["name"]) ?: "", str(extra?.get("locationCode")) ?: "", int(extra?.get("rentalBikes")), open(m["open"])))
        }
        return Answer(want, pts)
    }

    fun text(a: Answer): String? {
        val n = a.total ?: return null
        return "OV-fiets: ${if (n == 0) "none left" else "$n left"}" + if (a.closed == true) " · closed now" else ""
    }

    fun low(a: Answer) = (a.total ?: 99) <= 5

    const val TTL = 5 * 60.0
    fun fresh(at: Double, now: Double) = now - at < TTL && now >= at - 60

    data class Ride(val train: Boolean, val toCode: String?)

    fun station(rides: List<Ride>, walkAfter: Int): String? {
        val i = rides.indexOfLast { it.train }
        if (i < 0) return null
        val code = rides[i].toCode ?: return null
        val after = rides.size - 1 - i
        return if (after > 0 || walkAfter >= 5) code else null
    }
}

/** (A6, iOS 0.37 `RainAdvice.swift`) rain on the walk of your next trip, from Open-Meteo's hourly `precipitation`. Pure. */
object RainAdvice {
    const val THRESHOLD = 0.5

    /** `mm`: the rain of the hour before `time`. */
    data class Hour(val time: Double, val mm: Double) { val from: Double get() = time - 3600 }
    data class Stretch(val from: Double, val to: Double, val atStart: Boolean)
    data class Hit(val at: Double, val mm: Double, val atStart: Boolean)

    fun stretches(start: Double, walkBefore: Int, lastArrival: Double, end: Double): List<Stretch> {
        val out = ArrayList<Stretch>()
        if (walkBefore >= 2) out.add(Stretch(start, start + walkBefore * 60.0, true))
        if (end - lastArrival >= 120) out.add(Stretch(lastArrival, end, false))
        return out
    }

    fun hit(stretches: List<Stretch>, here: List<Hour>, there: List<Hour>, threshold: Double = THRESHOLD): Hit? {
        for (s in stretches) {
            val hours = (if (s.atStart) here else there).sortedBy { it.time }
            for (h in hours) if (h.mm >= threshold && h.from < s.to && h.time > s.from) return Hit(max(h.from, s.from), h.mm, s.atStart)
        }
        return null
    }

    fun due(start: Double, now: Double) = start - now <= 3 * 3600 && now - start <= 5 * 60

    data class Bus(val line: String, val departure: Double, val walkBefore: Int, val arrives: Double, val deadline: Double)

    fun bus(instead: Int, now: Double, from: List<Bus>): Bus? {
        val maxWalk = max(2, min(instead / 2, instead - 4))
        return from.filter { it.walkBefore <= maxWalk && it.departure - it.walkBefore * 60.0 >= now && it.arrives <= it.deadline }.minByOrNull { it.departure }
    }

    sealed class Advice {
        data class TakeBus(val line: String, val at: Double) : Advice()
        data object Umbrella : Advice()
    }

    fun advice(hit: Hit, firstIsTrain: Boolean, walkBefore: Int, bus: Bus?): Advice =
        if (hit.atStart && firstIsTrain && walkBefore >= 6 && bus != null) Advice.TakeBus(bus.line, bus.departure) else Advice.Umbrella

    fun text(hit: Hit, advice: Advice, hhmm: (Double) -> String): String = when (advice) {
        is Advice.TakeBus -> {
            val name = if (advice.line.isNotEmpty() && advice.line.all { it.isDigit() }) "bus ${advice.line}" else "the ${advice.line}"
            "Rain at ${hhmm(hit.at)} — take $name at ${hhmm(advice.at)} to the station instead of walking"
        }
        Advice.Umbrella -> "Rain at ${hhmm(hit.at)} — bring an umbrella"
    }

    /** Open-Meteo's `hourly.time` (unix seconds with `timeformat=unixtime`) and `hourly.precipitation`. */
    fun parseHours(text: String): List<Hour> {
        val j = try { Json.parseToJsonElement(text) as? JsonObject } catch (_: Exception) { null } ?: return emptyList()
        val h = j["hourly"] as? JsonObject ?: return emptyList()
        val t = (h["time"] as? JsonArray)?.map { (it as? JsonPrimitive)?.doubleOrNull } ?: return emptyList()
        val p = (h["precipitation"] as? JsonArray)?.map { (it as? JsonPrimitive)?.doubleOrNull } ?: return emptyList()
        return t.indices.mapNotNull { i -> val a = t[i]; val b = p.getOrNull(i); if (a != null && b != null) Hour(a, b) else null }
    }
}
