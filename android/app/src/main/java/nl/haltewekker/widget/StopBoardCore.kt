package nl.haltewekker.widget

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import java.time.Instant
import java.time.OffsetDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * (A6, iOS 0.37 `StopBoardCore.swift`) the next departures from one stop, for the home-screen widget and the "When's my
 * bus?" shortcut, read straight from Transitous (`/v6/stoptimes`, `/v1/geocode`): pure parsing, the stop kept as one
 * string, the link the widget opens, the timeline and the words. Shared by the app, the widget and the tests.
 */
object StopBoardCore {
    const val BASE = "https://api.transitous.org/api"

    @Serializable
    data class Departure(val line: String, val headsign: String, val time: Double, val scheduled: Double, val live: Boolean,
                         val cancelled: Boolean, val train: Boolean, val platform: String? = null) {
        val delay: Int get() = if (live) Math.round((time - scheduled) / 60).toInt() else 0
    }

    fun trainLabel(n: String): String {
        val l = n.lowercase()
        if (l.contains("intercity direct")) return "ICD"
        if (l.contains("intercity")) return "IC"
        if (l.contains("sprinter")) return "SPR"
        return n.take(4)
    }

    fun date(a: JsonElement?): Double? {
        val s = (a as? JsonPrimitive)?.takeIf { it.isString }?.content ?: return null
        return try { OffsetDateTime.parse(s).toInstant().toEpochMilli() / 1000.0 } catch (_: Exception) { null }
    }

    fun isoString(t: Double): String = DateTimeFormatter.ISO_INSTANT.format(Instant.ofEpochSecond(floor(t).toLong()))

    private fun str(a: JsonElement?) = (a as? JsonPrimitive)?.takeIf { it.isString }?.content
    private fun bool(a: JsonElement?) = (a as? JsonPrimitive)?.booleanOrNull ?: false

    fun parseStoptimes(text: String): List<Departure> {
        val j = try { Json.parseToJsonElement(text) } catch (_: Exception) { return emptyList() }
        val list = (j as? JsonObject)?.get("stopTimes") as? JsonArray ?: return emptyList()
        return list.mapNotNull { e ->
            val st = e as? JsonObject ?: return@mapNotNull null
            val p = st["place"] as? JsonObject ?: JsonObject(emptyMap())
            val t = date(p["departure"]) ?: return@mapNotNull null
            val mode = str(st["mode"]) ?: "BUS"
            val train = !(mode.contains("BUS") || mode.contains("COACH") || mode.contains("TRAM") || mode.contains("SUBWAY") ||
                mode.contains("METRO") || mode.contains("FERRY"))
            val short = str(st["routeShortName"]) ?: ""
            val name = short.ifEmpty { str(st["displayName"]) ?: str(st["routeLongName"]) ?: "?" }
            val cancelled = bool(st["cancelled"]) || bool(st["tripCancelled"]) || bool(p["cancelled"])
            Departure(if (train) trainLabel(name) else name, str(st["headsign"]) ?: "", t, date(p["scheduledDeparture"]) ?: t,
                bool(st["realTime"]), cancelled, train, str(p["track"]) ?: str(p["scheduledTrack"]))
        }.sortedBy { it.time }
    }

    @Serializable
    data class Stop(val id: String, val name: String, val town: String = "", val lat: Double, val lon: Double, val rail: Boolean = false)

    fun parseGeocode(text: String): List<Stop> {
        val list = try { Json.parseToJsonElement(text) as? JsonArray } catch (_: Exception) { null } ?: return emptyList()
        return list.mapNotNull { e ->
            val m = e as? JsonObject ?: return@mapNotNull null
            val id = str(m["id"])?.takeIf { it.isNotEmpty() } ?: return@mapNotNull null
            val name = str(m["name"]) ?: return@mapNotNull null
            val la = (m["lat"] as? JsonPrimitive)?.doubleOrNull ?: return@mapNotNull null
            val lo = (m["lon"] as? JsonPrimitive)?.doubleOrNull ?: return@mapNotNull null
            str(m["type"])?.let { if (it != "STOP") return@mapNotNull null }
            val areas = (m["areas"] as? JsonArray)?.mapNotNull { it as? JsonObject } ?: emptyList()
            val a = areas.firstOrNull { bool(it["default"]) } ?: areas.firstOrNull { bool(it["matched"]) } ?: areas.firstOrNull()
            val modes = (m["modes"] as? JsonArray)?.mapNotNull { str(it) } ?: emptyList()
            val rail = modes.any { it.contains("RAIL") || it == "LONG_DISTANCE" || it == "HIGHSPEED" } || (modes.isEmpty() && name.lowercase().startsWith("station "))
            Stop(id, name, str(a?.get("name")) ?: "", la, lo, rail)
        }
    }

    private const val SEP = "\u001F"
    private fun f6(x: Double) = String.format(Locale.ROOT, "%.6f", x)

    fun encode(s: Stop): String {
        fun clean(t: String) = t.replace(SEP, " ")
        return listOf("s1", clean(s.id), clean(s.name), clean(s.town), f6(s.lat), f6(s.lon), if (s.rail) "1" else "0").joinToString(SEP)
    }

    fun decode(id: String): Stop? {
        val f = id.split(SEP)
        if (f.size != 7 || f[0] != "s1" || f[1].isEmpty()) return null
        val la = f[4].toDoubleOrNull() ?: return null
        val lo = f[5].toDoubleOrNull() ?: return null
        return Stop(f[1], f[2], f[3], la, lo, f[6] == "1")
    }

    private const val OK = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"

    fun escape(t: String): String = buildString {
        for (b in t.toByteArray(Charsets.UTF_8)) {
            val c = (b.toInt() and 0xff).toChar()
            if (c.code < 128 && OK.indexOf(c) >= 0) append(c) else append("%%%02X".format(b.toInt() and 0xff))
        }
    }

    fun unescape(t: String): String {
        val out = java.io.ByteArrayOutputStream()
        var i = 0
        while (i < t.length) {
            val c = t[i]
            if (c == '%' && i + 2 < t.length) {
                val h = t.substring(i + 1, i + 3).toIntOrNull(16)
                if (h != null) { out.write(h); i += 3; continue }
            }
            out.write(c.toString().toByteArray(Charsets.UTF_8)); i++
        }
        return out.toString("UTF-8")
    }

    fun stoptimesUrl(stopId: String, from: Double, n: Int = 12) = "$BASE/v6/stoptimes?stopId=${escape(stopId)}&n=$n&time=${escape(isoString(from))}"

    fun geocodeUrl(text: String, near: Pair<Double, Double>? = null) =
        "$BASE/v1/geocode?text=${escape(text)}&type=STOP&numResults=12" + (near?.let { "&place=${it.first},${it.second}" } ?: "")

    /** haltewekker://stop?id=…&name=…&lat=…&lon=…&rail=1 (the widget's tap). */
    fun link(s: Stop) = "haltewekker://stop?id=${escape(s.id)}&name=${escape(s.name)}&lat=${f6(s.lat)}&lon=${f6(s.lon)}&rail=${if (s.rail) "1" else "0"}"

    fun parseLink(url: String): Stop? {
        val i = url.indexOf("://")
        if (i < 0) return null
        val scheme = url.substring(0, i).lowercase()
        val rest = url.substring(i + 3)
        val q = rest.indexOf('?')
        val host = (if (q >= 0) rest.substring(0, q) else rest).trimEnd('/').lowercase()
        if (scheme != "haltewekker" || host != "stop" || q < 0) return null
        val items = rest.substring(q + 1).split('&').mapNotNull { kv ->
            val e = kv.indexOf('=')
            if (e < 0) null else kv.substring(0, e) to unescape(kv.substring(e + 1))
        }
        fun v(k: String) = items.firstOrNull { it.first == k }?.second
        val id = v("id")?.takeIf { it.isNotEmpty() } ?: return null
        val la = v("lat")?.toDoubleOrNull() ?: return null
        val lo = v("lon")?.toDoubleOrNull() ?: return null
        if (la !in -90.0..90.0 || lo !in -180.0..180.0) return null
        return Stop(id, v("name") ?: "Stop", lat = la, lon = lo, rail = v("rail") == "1")
    }

    data class Entry(val date: Double, val departures: List<Departure>)

    fun upcoming(deps: List<Departure>, at: Double, count: Int): List<Departure> =
        deps.filter { it.time + 30 > at }.sortedBy { it.time }.take(count)

    fun timeline(deps: List<Departure>, now: Double, count: Int, refresh: Double = 12 * 60.0, maxEntries: Int = 12): Pair<List<Entry>, Double> {
        val sorted = deps.sortedBy { it.time }
        val first = upcoming(sorted, now, count)
        if (first.isEmpty()) return listOf(Entry(now, emptyList())) to now + 30 * 60
        var reload = now + refresh
        val known = sorted.filter { it.time + 30 > now }
        if (known.size > count) {
            val shortAt = known[known.size - count].time + 30
            if (shortAt < reload) reload = max(now + 5 * 60, shortAt)
        } else {
            reload = max(now + 5 * 60, min(reload, known.first().time + 30))
        }
        val entries = mutableListOf(Entry(now, first))
        for (d in known) {
            val at = d.time + 30
            if (at <= now || at >= reload || entries.size >= maxEntries) continue
            if (at - entries.last().date < 20) continue
            entries.add(Entry(at, upcoming(sorted, at, count)))
        }
        return entries to reload
    }

    fun title(d: Departure): String {
        if (d.train) return d.line
        return if (d.line.all { it.isLetterOrDigit() } && d.line.length <= 5) "Bus ${d.line}" else d.line
    }

    fun timeText(d: Departure, hhmm: (Double) -> String): String {
        if (d.cancelled) return "${hhmm(d.scheduled)} cancelled"
        val late = d.delay
        if (late > 0) return "${hhmm(d.time)} (+$late)"
        if (late < 0) return "${hhmm(d.time)} (−${-late})"
        return hhmm(d.time)
    }

    fun spoken(deps: List<Departure>, stop: String, now: Double, hhmm: (Double) -> String): String {
        val next = upcoming(deps.filter { !it.cancelled }, now, 2).filter { it.time >= now - 30 }
        val a = next.firstOrNull() ?: return "Nothing leaves $stop in the next while."
        val to = if (a.headsign.isEmpty()) "" else " to ${a.headsign}"
        val m = max(0, floor((a.time - now) / 60).toInt())
        val whenText = if (m == 0) "now" else if (m == 1) "in 1 minute" else "in $m minutes"
        val late = when {
            a.delay > 0 -> ", ${a.delay} minute${if (a.delay == 1) "" else "s"} late"
            a.delay < 0 -> ", ${-a.delay} minute${if (a.delay == -1) "" else "s"} early"
            else -> ""
        }
        var s = "${title(a)}$to leaves $stop at ${hhmm(a.time)}$late — $whenText."
        if (next.size > 1) s += " Then the ${next[1].line} at ${hhmm(next[1].time)}."
        return s
    }
}

/** (A6, iOS 0.37 `IntentActions.swift`) what the shortcuts and the widget's tap ask of the app. Nothing over a running trip. */
object IntentActions {
    sealed class Action {
        data class ShowStop(val stop: StopBoardCore.Stop) : Action()
        data class Wake(val stop: StopBoardCore.Stop) : Action()
        data class Fastest(val toSchool: Boolean) : Action()
        data object StartTrip : Action()
    }

    fun action(url: String): Action? = StopBoardCore.parseLink(url)?.let { Action.ShowStop(it) }

    sealed class Outcome { data object Go : Outcome(); data class Refuse(val why: String) : Outcome() }

    fun outcome(a: Action, idle: Boolean): Outcome = when (a) {
        is Action.ShowStop -> Outcome.Go
        else -> if (idle) Outcome.Go else Outcome.Refuse("A trip is running. End it first to start another.")
    }

    enum class Start { ALREADY_RUNNING, START_NOW, OPEN_PLANNED, OPEN_FASTEST }

    fun start(idle: Boolean, departure: Double?, now: Double): Start {
        if (!idle) return Start.ALREADY_RUNNING
        val d = departure ?: return Start.OPEN_FASTEST
        val ahead = d - now
        if (ahead <= 3 * 60 && ahead >= -15 * 60) return Start.START_NOW
        if (ahead < -15 * 60) return Start.OPEN_FASTEST
        return Start.OPEN_PLANNED
    }

    fun startText(s: Start): String? = when (s) {
        Start.ALREADY_RUNNING -> "Your trip is already running."
        Start.START_NOW -> null
        Start.OPEN_PLANNED -> "Watching your planned trip: it starts by itself once you’re on board, or tap I’m on it."
        Start.OPEN_FASTEST -> "No planned trip just now: here’s your fastest way. Tap I’m on it once you’re on board."
    }

    enum class BusFrom { HOME, NEAREST }

    fun busFrom(metresFromHome: Double?, haveHomeStop: Boolean): BusFrom {
        if (!haveHomeStop) return BusFrom.NEAREST
        val m = metresFromHome ?: return BusFrom.HOME
        return if (m <= 600) BusFrom.HOME else BusFrom.NEAREST
    }
}
