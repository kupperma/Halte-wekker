package nl.haltewekker.travel

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import java.time.Instant
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import java.util.Locale
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * (A6, iOS 0.36 `RailWorks.swift`) NS disruptions and planned engineering works on the trains you usually take, today
 * and the next 7 days, from the relay's `/ns/disruptions?stations=…`, matched to your rides here. Pure.
 */
object RailWorks {
    data class Span(val start: Double, val end: Double, val buses: Boolean = false, val noTrains: Boolean = false)

    data class Item(val id: String, val works: Boolean, val title: String, val spans: List<Span>, val stretches: List<List<String>>, val names: Map<String, String>)

    @Serializable
    data class Ride(val from: String, val to: String)

    private val nsTime = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ssZ", Locale.ROOT)

    fun time(a: JsonElement?): Double? {
        val s = (a as? JsonPrimitive)?.takeIf { it.isString }?.content ?: return null
        return try { OffsetDateTime.parse(s, nsTime).toEpochSecond().toDouble() } catch (_: Exception) {
            try { OffsetDateTime.parse(s).toEpochSecond().toDouble() } catch (_: Exception) { null }
        }
    }

    fun parse(text: String): List<Item> {
        val j = try { Json.parseToJsonElement(text) } catch (_: Exception) { return emptyList() }
        val list = (j as? JsonArray) ?: ((j as? JsonObject)?.get("payload") as? JsonArray) ?: return emptyList()
        return list.mapNotNull { (it as? JsonObject)?.let(::item) }
    }

    private fun text(a: JsonElement?): String = (a as? JsonPrimitive)?.content?.takeIf { a !is kotlinx.serialization.json.JsonNull } ?: ""

    private fun obj(a: JsonElement?) = a as? JsonObject
    private fun arr(a: JsonElement?) = (a as? JsonArray)?.mapNotNull { it as? JsonObject } ?: emptyList()

    fun item(d: JsonObject): Item? {
        val id = text(d["id"])
        if (id.isEmpty()) return null
        val type = text(d["type"]).uppercase()
        if (type == "CALAMITY") return null
        val names = LinkedHashMap<String, String>()
        val stretches = ArrayList<List<String>>()
        var anyNoTrains = false
        for (p in arr(d["publicationSections"])) {
            val cons = obj(p["consequence"])
            fun codes(sec: JsonElement?): List<String> = arr(obj(sec)?.get("stations")).mapNotNull { s ->
                val c = text(s["stationCode"]).uppercase()
                if (c.isEmpty()) return@mapNotNull null
                val n = text(s["name"])
                if (n.isNotEmpty() && names[c] == null) names[c] = n
                c
            }
            val whole = codes(p["section"])
            val hit = codes(cons?.get("section"))
            val s = if (hit.size >= 2) hit else whole
            if (s.isNotEmpty()) stretches.add(s)
            val words = (text(cons?.get("description")) + " " + text(cons?.get("level"))).lowercase()
            if (noTrainsWords(words)) anyNoTrains = true
        }
        if (stretches.isEmpty()) return null
        val spans = ArrayList<Span>()
        for (t in arr(d["timespans"])) {
            val a = time(t["start"]) ?: continue
            val b = time(t["end"]) ?: (a + 4 * 3600)
            val alt = text(obj(t["alternativeTransport"])?.get("label")).lowercase()
            val sit = text(obj(t["situation"])?.get("label")).lowercase()
            val buses = alt.contains("bus") || sit.contains("bussen")
            spans.add(Span(a, b, buses, buses || anyNoTrains || noTrainsWords(sit)))
        }
        if (spans.isEmpty()) time(d["start"])?.let { a -> spans.add(Span(a, time(d["end"]) ?: (a + 4 * 3600), false, anyNoTrains)) }
        if (spans.isEmpty()) return null
        return Item(id, type == "MAINTENANCE", text(d["title"]), spans, stretches, names)
    }

    private fun noTrainsWords(s: String) = s.contains("geen trein") || s.contains("no_trains") || s.contains("no trains") ||
        s.contains("rijden bussen") || s.contains("rijden er bussen") || s.contains("no_or_much_less")

    const val CORRIDOR_METRES = 2500.0

    fun passed(ride: Ride, stretch: List<String>, point: (String) -> GeoPoint?): List<String> {
        val a = point(ride.from); val b = point(ride.to)
        if (a == null || b == null) return stretch.filter { it == ride.from || it == ride.to }
        val len = Geo.metres(a, b)
        return stretch.filter { c ->
            if (c == ride.from || c == ride.to) return@filter true
            val p = point(c) ?: return@filter false
            if (len <= 0) return@filter false
            val kx = Geo.metres(GeoPoint(a.lat, a.lon), GeoPoint(a.lat, a.lon + 1))
            val ky = Geo.metres(GeoPoint(a.lat, a.lon), GeoPoint(a.lat + 1, a.lon))
            val bx = (b.lon - a.lon) * kx; val by = (b.lat - a.lat) * ky
            val px = (p.lon - a.lon) * kx; val py = (p.lat - a.lat) * ky
            val t = (px * bx + py * by) / (len * len)
            if (t <= 0 || t >= 1) return@filter false
            val dx = px - t * bx; val dy = py - t * by
            sqrt(dx * dx + dy * dy) <= min(CORRIDOR_METRES, 0.6 * min(t, 1 - t) * len)
        }
    }

    fun hit(item: Item, ride: Ride, point: (String) -> GeoPoint?): List<String>? {
        for (s in item.stretches) { val p = passed(ride, s, point); if (p.size >= 2) return p }
        return null
    }

    data class Impact(val id: String, val day: String, val dayStart: Double, val ride: Ride, val fromName: String, val toName: String,
                      val works: Boolean, val noTrains: Boolean, val buses: Boolean, val start: Double, val end: Double) {
        val key: String get() = "$day|$id|${ride.from}>${ride.to}"
    }

    val zone: ZoneId = ZoneId.of("Europe/Amsterdam")
    private fun z(t: Double) = Instant.ofEpochMilli((t * 1000).toLong()).atZone(zone)

    fun dayKey(t: Double): String { val d = z(t); return String.format(Locale.ROOT, "%04d-%02d-%02d", d.year, d.monthValue, d.dayOfMonth) }

    fun startOfDay(t: Double): Double = z(t).toLocalDate().atStartOfDay(zone).toEpochSecond().toDouble()

    fun defaultWindow(dayStart: Double): Pair<Double, Double> = (dayStart + 5 * 3600) to (dayStart + 24 * 3600)

    fun impacts(items: List<Item>, rides: List<Ride>, now: Double, days: Int = 7,
                window: (Double) -> Pair<Double, Double>? = { defaultWindow(it) }, point: (String) -> GeoPoint?): List<Impact> {
        val today = z(now).toLocalDate()
        val out = ArrayList<Impact>()
        for (n in 0..days) {
            val start = today.plusDays(n.toLong()).atStartOfDay(zone).toEpochSecond().toDouble()
            val w = window(start) ?: continue
            val from = maxOf(w.first, if (n == 0) now else w.first); val to = w.second
            if (to <= from) continue
            for (item in items) {
                val on = item.spans.filter { it.start < to && it.end > from }
                val first = on.minByOrNull { it.start } ?: continue
                for (r in rides) {
                    val stretch = hit(item, r, point) ?: continue
                    val a = stretch.first(); val b = stretch.last()
                    out.add(Impact(item.id, dayKey(start), start, r, item.names[a] ?: a, item.names[b] ?: b, item.works,
                        on.any { it.noTrains }, on.any { it.buses }, first.start, first.end))
                }
            }
        }
        val seen = HashSet<String>()
        return out.filter { seen.add(it.key) }.sortedWith(compareBy({ it.dayStart }, { it.start }))
    }

    fun dayWord(dayStart: Double, now: Double): String {
        val n = ChronoUnit.DAYS.between(z(now).toLocalDate(), z(dayStart).toLocalDate())
        if (n == 0L) return "Today"
        if (n == 1L) return "Tomorrow"
        return DateTimeFormatter.ofPattern("EEEE", Locale.UK).format(z(dayStart))
    }

    fun leaveEarlier(usualMinutes: Double?, newLeave: Double?, beThere: Double?): Int? {
        val u = usualMinutes ?: return null
        if (!u.isFinite() || u <= 0 || newLeave == null || beThere == null) return null
        val m = ((beThere - u * 60 - newLeave) / 60).roundToInt()
        return if (m >= 3) m else null
    }

    fun headline(i: Impact, now: Double, earlier: Int?): String {
        val what = if (i.noTrains) "no trains" else "fewer trains"
        val why = if (i.works) "works" else "disruption"
        var s = "${dayWord(i.dayStart, now)}: $what ${i.fromName}–${i.toName} ($why)."
        s += when {
            earlier != null -> " Leave $earlier min earlier" + if (i.buses) " — buses replace trains" else ""
            i.buses -> " Buses replace trains — allow extra time"
            else -> " Allow extra time"
        }
        return s
    }

    const val FETCH_EVERY = 4 * 3600.0

    fun eveningBefore(dayStart: Double): Double = z(dayStart).toLocalDate().minusDays(1).atStartOfDay(zone).toEpochSecond() + 19.5 * 3600

    fun tellNow(i: Impact, now: Double): Boolean { val e = eveningBefore(i.dayStart); return now >= e && now < e + 3.5 * 3600 }
}
