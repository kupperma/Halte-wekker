package nl.haltewekker.friends

import android.content.Context
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.data.Net
import java.text.Normalizer

/** An NS station from the iOS app's `NSStations.json` (copied in at build time). */
@Serializable
data class NSStation(val code: String, val uic: String = "", val name: String, val names: List<String> = emptyList(), val lat: Double, val lon: Double) {
    val point: GeoPoint get() = GeoPoint(lat, lon)
}

/** NS station codes by stop id (the UIC number in a DELFI id) or name (iOS `NSCodes`), and the nearest station. */
class NSCodes(val stations: List<NSStation>) {
    private val byUIC = HashMap<String, String>()
    private val byName = HashMap<String, String>()

    init {
        for (s in stations) {
            if (s.uic.isNotEmpty()) byUIC.putIfAbsent(s.uic, s.code)
            for (n in listOf(s.name) + s.names) { val k = fold(n); if (k.isNotEmpty()) byName.putIfAbsent(k, s.code) }
        }
    }

    fun station(code: String) = stations.firstOrNull { it.code == code }

    fun code(name: String): String? {
        val k = fold(name)
        if (k.isEmpty()) return null
        byName[k]?.let { return it }
        for (suffix in listOf(" centraal", " station", " centraal station")) {
            if (k.endsWith(suffix)) {
                if (name.contains(",")) return null
                byName[k.dropLast(suffix.length)]?.let { return it }
            }
        }
        return null
    }

    fun code(stopId: String, name: String?): String? {
        uic(stopId)?.let { u -> byUIC[u]?.let { return it } }
        if (notDutch(stopId)) return null
        return name?.let { code(it) }
    }

    /**
     * (0.10.13, iOS `NSStore.railCode`) Where a station's board comes from: its NS code in the Netherlands (as `code`),
     * "be:<UIC>" or "be:<name>" in Belgium (iRail through the relay, `Country.railSource`). For the board only: NS's
     * other services keep asking `code`, which is null in Belgium.
     */
    fun railCode(stopId: String, name: String, lat: Double?, lon: Double?): String? =
        nl.haltewekker.core.Country.railSource(stopId, name, lat, lon) { i, n -> code(i, n) }

    /** The nearest station within `within` metres. */
    fun nearest(p: GeoPoint, within: Double = 5000.0): NSStation? =
        stations.map { it to Geo.metres(p, it.point) }.filter { it.second <= within }.minByOrNull { it.second }?.first

    companion object {
        @Volatile private var shared: NSCodes? = null

        fun get(c: Context): NSCodes = shared ?: synchronized(this) {
            shared ?: NSCodes(decode(try { c.assets.open("NSStations.json").bufferedReader().use { it.readText() } } catch (_: Exception) { null })).also { shared = it }
        }

        fun decode(text: String?): List<NSStation> =
            text?.let { FriendJson.decode(ListSerializer(NSStation.serializer()), it) } ?: emptyList()

        /** A Dutch station's UIC in a DELFI id, or (0.10.13) an SNCB one's (`be-sncb_8400131`: Breda in SNCB's feed). */
        fun uic(id: String): String? = nl.haltewekker.core.Country.uic(id)?.takeIf { it.startsWith("84") }

        /** (0.10.13) A stop plainly outside the Netherlands by its id: never an NS station by its name. */
        fun notDutch(id: String): Boolean {
            nl.haltewekker.core.Country.uic(id)?.let { return !it.startsWith("84") }
            return id.startsWith("be-")
        }

        /** Lower case, no accents, every other mark a space ("’s-Hertogenbosch" → "s hertogenbosch"). */
        fun fold(s: String): String {
            val plain = Normalizer.normalize(s, Normalizer.Form.NFD).replace(Regex("\\p{M}+"), "").lowercase()
            val out = StringBuilder()
            var space = false
            for (ch in plain) {
                if (ch.code < 128 && ch.isLetterOrDigit()) {
                    if (space && out.isNotEmpty()) out.append(' ')
                    space = false
                    out.append(ch)
                } else space = true
            }
            return out.toString()
        }
    }
}

/** NS's drawing of one train at a station (relay `/ns/train`): its units with their coaches, platform letters, direction. */
data class TrainDrawing(val units: List<CoachMap.Unit>, val letters: List<Pair<String, Double>>, val dir: String?, val cars: Int,
                        /** (A5) Each unit's type as NS names it ("VIRM-6"; else its drawing's name, "virm_6"), for the seat picker's decks. */
                        val kinds: List<String> = emptyList(),
                        /** (A5.1) Each unit's drawing's name ("virmm1_6"), for where 1st class is in each coach (`SeatClass`). */
                        val drawings: List<String> = emptyList(),
                        /** (A5.1) Each unit's 1st-class seats as NS counts them (`zitplaatsen.zitplaatsEersteKlas`; null: not said). */
                        val firstSeats: List<Int?> = emptyList()) {
    /** (A5.1) The seat picker's train from this drawing (with its decks and 1st class). */
    fun seatTrain(line: String?, coaches: Int = 0): SeatMap.Train =
        SeatMap.train(units, kinds, if (cars > 0) cars else coaches, dir, line, drawings, firstSeats)

    companion object {
        /** (A5.1) The seat picker's train: from NS's drawing, else the guess (`coaches` long, else 6). */
        fun seatTrain(d: TrainDrawing?, line: String?, coaches: Int = 0): SeatMap.Train =
            d?.seatTrain(line, coaches) ?: SeatMap.train(emptyList(), emptyList(), coaches, null, line)
    }
}

object NSTrains {
    private val kept = HashMap<String, Pair<Double, TrainDrawing?>>()

    private fun num(e: Any?): Double = ((e as? JsonPrimitive)?.content?.toDoubleOrNull()) ?: 0.0

    fun parse(d: JsonObject): TrainDrawing? {
        val parts = (d["materieeldelen"] as? JsonArray)?.mapNotNull { it as? JsonObject } ?: emptyList()
        val sum = parts.sumOf { num(it["breedte"]) }
        val total = if (num(d["lengteInPixels"]) > 0) num(d["lengteInPixels"]) else sum
        val length = num(d["lengte"]).toInt()
        val cars = if (length > 0) length else parts.sumOf { (it["bakken"] as? JsonArray)?.size ?: 0 }
        if (total <= 0 || parts.isEmpty()) return null
        var x = 0.0
        val kinds = parts.map { m ->
            val type = (m["type"] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: (m["materieelType"] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: ""
            var key = ((m["afbeelding"] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: "").split('/').last()
            if (key.endsWith(".png")) key = key.dropLast(4)
            type.ifEmpty { key }
        }
        val units = parts.map { m ->
            val w = num(m["breedte"])
            val u = CoachMap.Unit(x / total, w / total, (m["bakken"] as? JsonArray)?.size ?: 0)
            x += w
            u
        }
        val letters = ((d["perronVoorzieningen"] as? JsonArray) ?: JsonArray(emptyList())).mapNotNull { e ->
            val p = e as? JsonObject ?: return@mapNotNull null
            if ((p["type"] as? JsonPrimitive)?.content != "PERRONLETTER" || p["paddingLeft"] == null) return@mapNotNull null
            val l = (p["description"] as? JsonPrimitive)?.content ?: return@mapNotNull null
            if (l.isEmpty()) return@mapNotNull null
            val pl = num(p["paddingLeft"])
            if (pl < -0.03 * total || pl > 1.03 * total) null else l to pl / total
        }
        val drawings = parts.map { m -> SeatClass.imageKey((m["afbeelding"] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: "") }
        val firstSeats = parts.map { m -> ((m["zitplaatsen"] as? JsonObject)?.get("zitplaatsEersteKlas") as? JsonPrimitive)?.content?.toDoubleOrNull()?.toInt() }
        val rr = (d["rijrichting"] as? JsonPrimitive)?.content
        return TrainDrawing(units, letters, if (rr == "LINKS") "left" else if (rr == "RECHTS") "right" else null, cars, kinds, drawings, firstSeats)
    }

    /** The drawing of train `num` at station `code` (kept 15 minutes; null: NS doesn't know it). */
    suspend fun drawing(num: String, code: String): TrainDrawing? {
        val k = "$num@$code"
        val now = System.currentTimeMillis() / 1000.0
        kept[k]?.let { if (now - it.first < 900) return it.second }
        val a = Net.get(FriendRelay.BASE + "/ns/train", listOf("num" to num, "station" to code))
        if (a.status == -1) return kept[k]?.second
        val d = if (a.ok) (FriendJson.parse(a.body!!) as? JsonObject)?.let(::parse) else null
        kept[k] = now to d
        return d
    }
}
