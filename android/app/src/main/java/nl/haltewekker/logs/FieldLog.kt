package nl.haltewekker.logs

import android.content.Context
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import nl.haltewekker.friends.FriendJson
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** One line of the field log (iOS `FieldEntry`): the matcher's looks (`match`) and what the ride did (`ride`). */
@Serializable
data class FieldEntry(val at: Double, @Serializable(with = KindSerializer::class) val kind: Kind, val text: String) {
    enum class Kind(val raw: String) { NET("net"), MATCH("match"), RIDE("ride") }
}

private object KindSerializer : KSerializer<FieldEntry.Kind> {
    override val descriptor = PrimitiveSerialDescriptor("FieldEntry.Kind", PrimitiveKind.STRING)
    override fun serialize(encoder: Encoder, value: FieldEntry.Kind) = encoder.encodeString(value.raw)
    override fun deserialize(decoder: Decoder): FieldEntry.Kind {
        val s = decoder.decodeString()
        return FieldEntry.Kind.entries.firstOrNull { it.raw == s } ?: FieldEntry.Kind.NET
    }
}

/**
 * The last vehicle choices and ride events, newest first, kept on this phone (`files/fieldlog.json`, written at most
 * every 30 s). Holds lines, metres rounded to 10 and the last 4 characters of trip ids: never coordinates, place names
 * or query strings. Only read by "Share ride logs" (when on): it changes nothing about a ride.
 */
object FieldLog {
    private val caps = mapOf(FieldEntry.Kind.NET to 300, FieldEntry.Kind.MATCH to 200, FieldEntry.Kind.RIDE to 100)
    private val lock = Any()
    private var list: MutableList<FieldEntry> = mutableListOf()
    private var file: File? = null
    private var pending = false
    private val writer = Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "fieldlog").apply { isDaemon = true } }
    private val ser = ListSerializer(FieldEntry.serializer())

    fun init(c: Context) {
        synchronized(lock) {
            if (file != null) return
            val f = File(c.applicationContext.filesDir, "fieldlog.json")
            file = f
            list = (try { f.takeIf { it.exists() }?.readText() } catch (_: Exception) { null })?.let { FriendJson.decode(ser, it) }?.toMutableList() ?: mutableListOf()
        }
    }

    val entries: List<FieldEntry> get() = synchronized(lock) { list.toList() }

    fun add(kind: FieldEntry.Kind, text: String, at: Double = System.currentTimeMillis() / 1000.0) {
        synchronized(lock) {
            list.add(0, FieldEntry(at, kind, text))
            if (list.count { it.kind == kind } > (caps[kind] ?: 100)) list.removeAt(list.indexOfLast { it.kind == kind })
            if (pending || file == null) return
            pending = true
        }
        writer.schedule({ flush() }, 30, TimeUnit.SECONDS)
    }

    fun ride(text: String) = add(FieldEntry.Kind.RIDE, text)
    fun match(text: String) = add(FieldEntry.Kind.MATCH, text)

    fun flush() {
        val (f, snapshot) = synchronized(lock) { pending = false; file to list.toList() }
        f ?: return
        try {
            val tmp = File(f.parentFile, "fieldlog.json.tmp")
            tmp.writeText(FriendJson.encodeString(ser, snapshot))
            tmp.renameTo(f)
        } catch (_: Exception) {}
    }

    fun clear() { synchronized(lock) { list.clear() }; flush() }
}

/** The lines as the iOS app words them (`FieldFormat`), so one export reads the same from both apps. */
object FieldFormat {
    fun metres(m: Double?): String {
        if (m == null || !m.isFinite()) return "? m"
        return "${(min(max(0.0, m), 1e7) / 10).roundToInt() * 10} m"
    }

    fun vehicle(line: String, tripId: String, isTrain: Boolean) = "${if (isTrain) "train" else "bus"} $line·${tripId.takeLast(4)}"

    fun rideStart(how: String, vehicle: String?, stopMetres: Double?, leg: Int, of: Int) =
        "start · $how · ${vehicle ?: "no vehicle yet"} · its stop ${metres(stopMetres)} from you · leg $leg/$of"

    fun rideWake(startedMetres: Double?) = "wake · silently (started ${metres(startedMetres)} from its stop)"

    fun rideRing(why: String, metres: Double?, legAge: Double, started: Double?) =
        "ring · $why · ${metres(metres)} · leg ${max(0.0, legAge).roundToInt()} s old · started ${metres(started)}"

    fun rideArrive(why: String, metres: Double?, accuracy: Double?, legAge: Double, started: Double?): String {
        val acc = accuracy?.takeIf { it >= 0 && it.isFinite() }?.let { " (±${it.roundToInt()})" } ?: ""
        return "arrive · $why · ${metres(metres)}$acc · leg ${max(0.0, legAge).roundToInt()} s old · started ${metres(started)}"
    }

    fun rideEnd(why: String) = "end · $why"

    fun handPick(vehicle: String?, was: String?, metres: Double?, byGPS: Boolean?): String {
        val before = "(was ${was ?: "none"})"
        vehicle ?: return "hand pick · none of these: by your location $before"
        val how = byGPS?.let { if (it) " · gps" else " · times" } ?: ""
        return "hand pick · $vehicle $before · ${metres(metres)}$how"
    }

    /** "detect · n=9 · 305·7821 by GPS → choose 305·7821" (the Android ride's simpler matcher, worded as iOS's). */
    fun detect(fixes: Int, label: String, byGPS: Boolean, planned: Boolean) =
        "detect · n=$fixes · $label ${if (byGPS) "live" else "timetable"}${if (planned) " (planned)" else ""} → choose $label"
}
