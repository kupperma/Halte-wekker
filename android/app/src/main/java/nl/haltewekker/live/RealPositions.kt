package nl.haltewekker.live

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.data.TransitParse
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import kotlin.math.abs

/** One bus's or train's GPS position from the open data (iOS `GPSFix`). `at`: seconds since 1970. */
data class GPSFix(
    val lat: Double,
    val lon: Double,
    val bearing: Double?,
    val at: Double,
    val startDate: String? = null,
    val stopSequence: Int? = null,
    val stopped: Boolean? = null,
    val speed: Double? = null,      // m/s
    val type: String? = null,       // NS: "SPR", "IC"…
) {
    val point: GeoPoint get() = GeoPoint(lat, lon)
}

/**
 * A protobuf message read field by field inside `[start, end)` of a buffer (iOS `ProtoReader`). Every read checks the
 * bounds: anything cut short, a varint longer than 10 bytes, a group (wire types 3 and 4) or field number 0 ends the
 * message there.
 */
class ProtoReader(private val buf: ByteArray, start: Int, end: Int) {
    sealed class Value {
        data class Varint(val v: Long) : Value()
        data class Fixed64(val v: Long) : Value()
        data class Bytes(val start: Int, val end: Int) : Value()
        data class Fixed32(val v: Int) : Value()
    }
    data class Field(val number: Long, val value: Value)

    private var i = maxOf(0, start)
    private val end = minOf(maxOf(0, end), buf.size)

    private fun varint(): Long? {
        var r = 0L
        var shift = 0
        while (i < end && shift < 64) {
            val c = buf[i].toInt() and 0xff; i++
            r = r or ((c and 0x7f).toLong() shl shift)
            if (c < 0x80) return r
            shift += 7
        }
        return null
    }

    fun next(): Field? {
        if (i >= end) return null
        val key = varint() ?: run { i = end; return null }
        val number = key ushr 3
        if (number <= 0) { i = end; return null }
        val value: Value = when ((key and 7).toInt()) {
            0 -> Value.Varint(varint() ?: run { i = end; return null })
            1 -> {
                if (end - i < 8) { i = end; return null }
                var v = 0L
                for (k in 0 until 8) v = v or ((buf[i + k].toLong() and 0xff) shl (8 * k))
                i += 8; Value.Fixed64(v)
            }
            2 -> {
                val n = varint() ?: run { i = end; return null }
                if (n < 0 || n > (end - i).toLong()) { i = end; return null }
                val v = Value.Bytes(i, i + n.toInt()); i += n.toInt(); v
            }
            5 -> {
                if (end - i < 4) { i = end; return null }
                var v = 0
                for (k in 0 until 4) v = v or ((buf[i + k].toInt() and 0xff) shl (8 * k))
                i += 4; Value.Fixed32(v)
            }
            else -> { i = end; return null }
        }
        return Field(number, value)
    }

    companion object {
        fun string(buf: ByteArray, s: Int, e: Int): String? =
            if (s >= 0 && e <= buf.size && s <= e) String(buf, s, e - s, Charsets.UTF_8) else null
    }
}

/**
 * Real bus positions (OVapi's GTFS-Realtime vehicle positions) and NS's train positions (through the relay): reading
 * them and finding a Transitous trip's fix in them. A port of the pure parts of iOS `RealPositions.swift`.
 */
object RealPositions {
    const val FEED_URL = "https://gtfs.ovapi.nl/nl/vehiclePositions.pb"
    const val RELAY = "https://haltewekker-relay.tsfaw1.workers.dev"
    const val TRAINS_PATH = "/ns/vehicles"

    const val FRESH = 180.0            // s: a fix this old or newer is drawn
    const val MATCH_FRESH = 90.0       // …and this old or newer judged by
    const val EVERY = 30.0             // s between fetches

    data class Feed(val timestamp: Double? = null, val fixes: Map<String, GPSFix> = emptyMap(), val entities: Int = 0)

    private const val MAX_TS = 1L shl 40

    /** Never crashes: unknown fields skipped; a message cut short is read up to there. */
    fun parse(data: ByteArray): Feed {
        var timestamp: Double? = null
        val top = ProtoReader(data, 0, data.size)
        val entities = ArrayList<ProtoReader.Value.Bytes>()
        while (true) {
            val f = top.next() ?: break
            val v = f.value
            if (f.number == 1L && v is ProtoReader.Value.Bytes) {
                val h = ProtoReader(data, v.start, v.end)
                while (true) {
                    val g = h.next() ?: break
                    val gv = g.value
                    if (g.number == 3L && gv is ProtoReader.Value.Varint && gv.v > 0 && gv.v < MAX_TS) timestamp = gv.v.toDouble()
                }
            } else if (f.number == 2L && v is ProtoReader.Value.Bytes) entities.add(v)
        }
        val fixes = HashMap<String, GPSFix>()
        var count = 0
        for (e in entities) {
            val ent = ProtoReader(data, e.start, e.end)
            var vehicle: ProtoReader.Value.Bytes? = null
            while (true) {
                val f = ent.next() ?: break
                if (f.number == 4L && f.value is ProtoReader.Value.Bytes) vehicle = f.value
            }
            vehicle ?: continue
            count++
            val (id, fix) = vehicle(data, vehicle.start, vehicle.end, timestamp) ?: continue
            val old = fixes[id]
            if (old != null && old.at >= fix.at) continue
            fixes[id] = fix
        }
        return Feed(timestamp, fixes, count)
    }

    private fun vehicle(raw: ByteArray, s: Int, e: Int, feedTime: Double?): Pair<String, GPSFix>? {
        var tripId: String? = null
        var startDate: String? = null
        var lat: Float? = null
        var lon: Float? = null
        var bearing: Float? = null
        var ts: Long? = null
        var seq: Long? = null
        var status: Long? = null
        val vp = ProtoReader(raw, s, e)
        while (true) {
            val f = vp.next() ?: break
            val v = f.value
            when {
                f.number == 1L && v is ProtoReader.Value.Bytes -> {
                    val t = ProtoReader(raw, v.start, v.end)
                    while (true) {
                        val g = t.next() ?: break
                        val gv = g.value as? ProtoReader.Value.Bytes ?: continue
                        if (g.number == 1L) tripId = ProtoReader.string(raw, gv.start, gv.end)
                        if (g.number == 3L) startDate = ProtoReader.string(raw, gv.start, gv.end)
                    }
                }
                f.number == 2L && v is ProtoReader.Value.Bytes -> {
                    val p = ProtoReader(raw, v.start, v.end)
                    while (true) {
                        val g = p.next() ?: break
                        val gv = g.value as? ProtoReader.Value.Fixed32 ?: continue
                        val x = java.lang.Float.intBitsToFloat(gv.v)
                        when (g.number) { 1L -> lat = x; 2L -> lon = x; 3L -> bearing = x }
                    }
                }
                f.number == 3L && v is ProtoReader.Value.Varint -> seq = v.v
                f.number == 4L && v is ProtoReader.Value.Varint -> status = v.v
                f.number == 5L && v is ProtoReader.Value.Varint -> ts = v.v
            }
        }
        val id = tripId?.takeIf { it.isNotEmpty() } ?: return null
        val la = lat ?: return null
        val lo = lon ?: return null
        if (!la.isFinite() || !lo.isFinite() || abs(la) > 90 || abs(lo) > 180 || (la == 0f && lo == 0f)) return null
        val at: Double = when {
            ts != null && ts!! > 0 && ts!! < MAX_TS -> ts!!.toDouble()
            feedTime != null -> feedTime
            else -> return null
        }
        val b = bearing?.takeIf { it.isFinite() && it >= 0 && it <= 360 }?.toDouble()
        return id to GPSFix(la.toDouble(), lo.toDouble(), b, at, startDate,
            seq?.takeIf { it in 0 until 100_000 }?.toInt(), status?.let { it == 1L })
    }

    /** The feed's trip_id for a Transitous trip: what follows "nl-OpenOV_". */
    fun key(transitousTripId: String): String? {
        val i = transitousTripId.indexOf("nl-OpenOV_")
        if (i < 0) return null
        return transitousTripId.substring(i + "nl-OpenOV_".length).ifEmpty { null }
    }

    /** (A9, iOS 0.42.3) the log's words when OVapi's feed has nothing for a trip: which key, and whether it had begun. */
    fun noMatchReason(transitousTripId: String, key: String, now: Double): String {
        val base = "no ovapi match for trip_id $key"
        val st = startTime(transitousTripId) ?: return base
        return if (now < st.first) "$base: not started yet, starts ${st.second}" else "$base (started ${st.second})"
    }

    /**
     * (0.9.1, iOS `RealPositionsStore.noGPSReason`) why a trip has no fix to draw it by, for the field log: "real
     * positions off", "train 3540 not in ns positions", "no ovapi match for trip_id …: not started yet, starts 24:10",
     * "fix 240 s old"; null: none of these. `number`: its train number when it's a train.
     */
    fun noGPSReason(enabled: Boolean, tripId: String, number: Int?, buses: Map<String, GPSFix>, trains: Map<Int, GPSFix>, now: Double): String? {
        if (!enabled) return "real positions off"
        if (number != null) {
            if (trains.isEmpty()) return "ns positions not in"
            val f = trains[number] ?: return "train $number not in ns positions"
            val age = Math.round(now - f.at)
            return if (age > FRESH.toLong()) "fix $age s old" else null
        }
        val k = key(tripId) ?: return "no train number, not in ovapi" + (dataset(tripId)?.let { " (a trip of $it)" } ?: "")
        if (buses.isEmpty()) return "ovapi positions not in"
        val f = buses[k] ?: return noMatchReason(tripId, k, now)
        val age = Math.round(now - f.at)
        return if (age > FRESH.toLong()) "fix $age s old" else null
    }

    /** When the trip starts by its Transitous id ("20261201_24:10_…": 00:10 the next day, Dutch time), and the text. */
    fun startTime(transitousTripId: String): Pair<Double, String>? {
        val parts = transitousTripId.split("_", limit = 3)
        val d = serviceDate(transitousTripId) ?: return null
        if (parts.size < 2) return null
        val hm = parts[1].split(":")
        if (hm.size != 2) return null
        val h = hm[0].toIntOrNull() ?: return null
        val m = hm[1].toIntOrNull() ?: return null
        if (h !in 0..47 || m !in 0..59) return null
        val midnight = java.time.LocalDate.of(d.take(4).toInt(), d.substring(4, 6).toInt(), d.takeLast(2).toInt())
            .atStartOfDay(ZoneId.of("Europe/Amsterdam")).toEpochSecond().toDouble()
        return midnight + h * 3600 + m * 60 to parts[1]
    }

    fun dataset(transitousTripId: String): String? {
        val parts = transitousTripId.split("_", limit = 4)
        if (parts.size < 4 || serviceDate(transitousTripId) == null || parts[2].isEmpty()) return null
        return parts[2]
    }

    /** "20261117" from "20261117_11:57_nl-OpenOV_374105578". */
    fun serviceDate(transitousTripId: String): String? {
        val d = transitousTripId.takeWhile { it != '_' }
        return if (d.length == 8 && d.all { it in '0'..'9' }) d else null
    }

    private val dayFormat = DateTimeFormatter.ofPattern("yyyyMMdd").withZone(ZoneId.of("Europe/Amsterdam"))
    fun day(t: Double): String = dayFormat.format(Instant.ofEpochMilli((t * 1000).toLong()))

    fun usable(fixes: Map<String, GPSFix>, tripId: String, now: Double, fresh: Double = FRESH): GPSFix? {
        val k = key(tripId) ?: return null
        val f = fixes[k] ?: return null
        return usable(f, tripId, now, fresh)
    }

    fun usable(f: GPSFix, tripId: String, now: Double, fresh: Double = FRESH): GPSFix? {
        // (0.10.13) a Belgian train (SNCB's feed): NS's positions by number aren't its own; it goes by its times
        if (nl.haltewekker.core.Country.belgianTrip(tripId)) return null
        val age = now - f.at
        if (age > fresh || age < -60) return null
        val tripDay = serviceDate(tripId)
        if (tripDay != null && f.startDate != null && tripDay != f.startDate) return null
        val d = tripDay ?: f.startDate ?: return f
        return if (d == day(now) || d == day(now - 86_400)) f else null
    }

    fun isRail(mode: String): Boolean {
        val m = mode.uppercase()
        return "RAIL" in m || m == "LONG_DISTANCE" || m == "SUBURBAN" || m == "TRAIN"
    }

    /** The last group of 1 to 6 digits, not 0. */
    fun trainNumber(shortName: String): Int? {
        val groups = shortName.split(Regex("[^0-9]+")).filter { it.isNotEmpty() }
        val last = groups.lastOrNull() ?: return null
        if (last.length > 6) return null
        val n = last.toIntOrNull() ?: return null
        return if (n > 0) n else null
    }

    /** NS's positions of every train by number, each at `at` (iOS `parseTrains`). Null: not such an answer. */
    fun parseTrains(body: String, at: Double): Map<Int, GPSFix>? {
        val json = TransitParse.json(body) as? JsonObject ?: return null
        val payload = json["payload"] as? JsonObject ?: json
        val list = payload["treinen"] as? JsonArray ?: return null
        fun number(a: JsonElement?): Double? {
            val p = a as? JsonPrimitive ?: return null
            val d = if (p.isString) p.content.trim().replace(",", ".").toDoubleOrNull() else p.content.toDoubleOrNull()
            return d?.takeIf { it.isFinite() }
        }
        fun train(a: JsonElement?): Int? {
            val p = a as? JsonPrimitive ?: return null
            if (p.isString) return trainNumber(p.content)
            val d = number(a) ?: return null
            if (d < 1 || d >= 1_000_000 || d != Math.rint(d)) return null
            return d.toInt()
        }
        val out = HashMap<Int, GPSFix>()
        for (item in list) {
            val t = item as? JsonObject ?: continue
            val n = train(t["treinNummer"]) ?: train(t["ritId"]) ?: continue
            val lat = number(t["lat"]) ?: continue
            val lon = number(t["lng"] ?: t["lon"]) ?: continue
            if (abs(lat) > 90 || abs(lon) > 180 || (lat == 0.0 && lon == 0.0)) continue
            val kmh = number(t["snelheid"])?.takeIf { it in 0.0..400.0 }
            val dir = number(t["richting"])?.takeIf { it in 0.0..360.0 }
            out[n] = GPSFix(lat, lon, dir, at, speed = kmh?.let { it / 3.6 }, type = (t["type"] as? JsonPrimitive)?.content)
        }
        return out
    }

    /** Seconds to the next fetch after `failures` failed ones in a row: 30, then 60, 120, 240, at most 300. */
    fun backoff(failures: Int): Double {
        if (failures <= 0) return EVERY
        return minOf(300.0, 60 * Math.pow(2.0, (minOf(failures, 10) - 1).toDouble()))
    }
}
