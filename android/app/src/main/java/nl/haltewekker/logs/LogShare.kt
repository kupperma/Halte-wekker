package nl.haltewekker.logs

import kotlinx.serialization.Serializable
import nl.haltewekker.friends.FriendJson
import nl.haltewekker.friends.FriendNames
import java.io.ByteArrayOutputStream
import java.security.SecureRandom
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import java.util.regex.Matcher
import java.util.regex.Pattern
import java.util.zip.CRC32
import java.util.zip.Deflater

// Share ride logs (iOS 0.28.1 `LogShare.swift`): Settings › Help improve Haltewekker › Share ride logs, off unless you
// turn it on. The matching and ride lines of the field log, scrubbed here first, go to the relay after a trip ends
// (and at most once an hour otherwise), grouped by a random install id that is not the Friends account. Plain values,
// so every rule is tested (the same rules and numbers as iOS; docs/logs-export.md says how they're read).

/** What this phone knows that must never leave it in a shared line: your places' names, people's names, account ids. */
data class LogScrubKnown(
    val homes: List<String> = emptyList(),
    val schools: List<String> = emptyList(),
    val places: List<String> = emptyList(),
    val people: List<String> = emptyList(),
    val ids: List<String> = emptyList(),
)

object LogScrub {
    const val MIN_NAME = 3
    const val PERSON = "a friend"
    const val MAX_LINE = 2000

    /** Words of the log itself: a place or person with one of these names isn't looked for. */
    val logWords = setOf(
        "home", "school", "a place", "place", "a friend", "friend", "you", "bus", "train", "stop", "station", "start",
        "end", "ring", "wake", "arrive", "keep", "switch", "find", "choose", "detect", "board", "on board", "none", "live",
        "gps", "times", "timetable", "look", "tight", "cost", "wait", "refused", "same bus", "hand", "pick", "auto",
        "demo", "leg", "fast lane", "real position", "planned", "classic", "approach",
    )

    /** In this order: links, e-mail addresses, coordinates, UUIDs, long hex (account and device ids), long tokens. */
    val patterns: List<Pair<Pattern, String>> = listOf(
        Pattern.compile("[A-Za-z][A-Za-z0-9+.-]*://\\S+") to "[link]",
        Pattern.compile("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}") to "[email]",
        Pattern.compile("-?\\d{1,3}[.,]\\d{2,}\\s*[,;/ ]\\s*-?\\d{1,3}[.,]\\d{2,}") to "[coord]",
        Pattern.compile("-?\\d{1,3}[.,]\\d{4,}") to "[coord]",
        Pattern.compile("[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}") to "[id]",
        Pattern.compile("(?<![0-9A-Za-z])[0-9A-Fa-f]{12,}(?![0-9A-Za-z])") to "[id]",
        Pattern.compile("(?<![0-9A-Za-z_-])(?=[A-Za-z0-9_-]*[0-9])(?=[A-Za-z0-9_-]*[A-Za-z])[A-Za-z0-9_-]{24,}(?![0-9A-Za-z_-])") to "[id]",
    )

    /** The names to replace, longest first, each once. */
    fun names(k: LogScrubKnown): List<Pair<String, String>> {
        val out = mutableListOf<Pair<String, String>>()
        val seen = HashSet<String>()
        fun add(list: List<String>, with: String) {
            for (raw in list) {
                val n = raw.trim()
                val key = n.lowercase()
                if (n.codePointCount(0, n.length) < MIN_NAME || key in logWords || !seen.add(key)) continue
                out.add(n to with)
            }
        }
        add(k.homes, "Home")
        add(k.schools, "School")
        add(k.places, "a place")
        add(k.people, PERSON)
        return out.sortedWith(compareByDescending<Pair<String, String>> { it.first.codePointCount(0, it.first.length) }.thenBy { it.first })
    }

    fun line(text: String, known: LogScrubKnown): String = LogScrubber(known).line(text)
}

/** `LogScrub` with its names made ready once, for many lines. */
class LogScrubber(known: LogScrubKnown) {
    private val ids = known.ids.filter { it.length >= 6 }
    private val names: List<Pair<Pattern, String>> = LogScrub.names(known).map { (name, with) ->
        val p = "(?<![\\p{L}\\p{N}])" + Pattern.quote(name) + "(?![\\p{L}\\p{N}])"
        // (people's names as written: "Max" goes, the log's own "max" stays; places in any case)
        val flags = if (with == LogScrub.PERSON) 0 else Pattern.CASE_INSENSITIVE or Pattern.UNICODE_CASE
        Pattern.compile(p, flags) to Matcher.quoteReplacement(with)
    }

    fun line(text: String): String {
        var t = FriendNames.takeChars(text, LogScrub.MAX_LINE)
        for (c in listOf("\r", "\n", "\t")) t = t.replace(c, " ")
        for (id in ids) t = t.replace(id, "[id]", ignoreCase = true)
        for ((re, with) in LogScrub.patterns) t = re.matcher(t).replaceAll(with)
        for ((re, with) in names) t = re.matcher(t).replaceAll(with)
        return t
    }
}

data class LogShareBatch(val lines: List<String> = emptyList(), val bytes: Int = 0, val through: Double? = null, val more: Boolean = false)

object LogShareRules {
    val kinds = setOf(FieldEntry.Kind.MATCH, FieldEntry.Kind.RIDE)
    const val PER_UPLOAD = 200 * 1024
    const val PER_DAY = 2 * 1024 * 1024
    const val EVERY = 3600.0
    const val AFTER_TRIP_GAP = 60.0
    const val PATH = "/logs/v1/put"
    const val DELETE_PATH = "/logs/v1/delete"

    const val SAMPLE = "2026-11-19 07:33:58 ride start · Home on board, by itself · bus 305·7821 · its stop 16630 m from you · leg 1/3"

    enum class Trigger { TRIP_ENDED, TICK }

    private fun instant(t: Double) = Instant.ofEpochMilli(Math.floor(t * 1000).toLong())

    fun day(t: Double, zone: ZoneId = ZoneId.systemDefault()): String = DateTimeFormatter.ofPattern("yyyy-MM-dd", Locale.US).withZone(zone).format(instant(t))

    private fun clock(zone: ZoneId) = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss", Locale.US).withZone(zone)

    private fun text(e: FieldEntry, scrub: LogScrubber, clock: DateTimeFormatter) = "${clock.format(instant(e.at))} ${e.kind.raw} ${scrub.line(e.text)}"

    /** "2026-11-19 07:33:58 ride <the scrubbed text>" */
    fun text(e: FieldEntry, known: LogScrubKnown, zone: ZoneId = ZoneId.systemDefault()) = text(e, LogScrubber(known), clock(zone))

    /** The matching and ride lines after `after` (the log is newest first), oldest first, while they fit in `budget` bytes. */
    fun batch(entries: List<FieldEntry>, after: Double?, budget: Int, known: LogScrubKnown, zone: ZoneId = ZoneId.systemDefault()): LogShareBatch {
        val fresh = entries.filter { it.kind in kinds && (after == null || it.at > after) }.sortedBy { it.at }
        val scrub = LogScrubber(known)
        val f = clock(zone)
        val limit = maxOf(0, budget)
        val lines = mutableListOf<String>()
        var bytes = 0
        var through: Double? = null
        var more = false
        for (e in fresh) {
            val line = text(e, scrub, f)
            val size = line.toByteArray(Charsets.UTF_8).size + if (lines.isEmpty()) 0 else 1
            if (bytes + size > limit) { more = true; break }
            lines.add(line)
            bytes += size
            through = e.at
        }
        return LogShareBatch(lines, bytes, through, more)
    }

    fun example(entries: List<FieldEntry>, known: LogScrubKnown, zone: ZoneId = ZoneId.systemDefault()): String? {
        val e = entries.firstOrNull { it.kind == FieldEntry.Kind.RIDE } ?: entries.firstOrNull { it.kind in kinds } ?: return null
        return text(e, known, zone)
    }

    fun budget(s: LogShareState, today: String): Int {
        val used = if (s.day == today) s.sentToday else 0
        return maxOf(0, minOf(PER_UPLOAD, PER_DAY - used))
    }

    /** On, no trip running, not in battery saver, the day's 2 MB not used up, the last try long enough ago. */
    fun due(s: LogShareState, enabled: Boolean, trigger: Trigger, tripRunning: Boolean, lowPower: Boolean, now: Double, today: String): Boolean {
        if (!enabled || tripRunning || lowPower || budget(s, today) <= 0) return false
        val last = s.lastTry ?: return true
        val age = now - last
        if (age < 0) return true
        return age >= if (trigger == Trigger.TRIP_ENDED) AFTER_TRIP_GAP else EVERY
    }

    fun tried(s: LogShareState, now: Double) = s.copy(lastTry = now)

    fun sent(s: LogShareState, b: LogShareBatch, now: Double, today: String): LogShareState {
        var n = s
        if (n.day != today) n = n.copy(day = today, sentToday = 0)
        return n.copy(sentToday = n.sentToday + b.bytes, through = b.through ?: n.through, sentEver = true, lastSent = now)
    }
}

/** Kept between uploads: the install id and its secret, where the next upload starts, and today's bytes. */
@Serializable
data class LogShareState(
    val install: String,
    val secret: String,
    val through: Double? = null,
    val lastTry: Double? = null,
    val lastSent: Double? = null,
    val day: String = "",
    val sentToday: Int = 0,
    val sentEver: Boolean = false,
) {
    fun rotated(random: (Int) -> ByteArray = ::randomBytes) =
        copy(install = hex(random(16)), secret = hex(random(32)), sentEver = false, lastSent = null)

    companion object {
        private val rng = SecureRandom()
        fun randomBytes(n: Int) = ByteArray(n).also { rng.nextBytes(it) }
        fun hex(b: ByteArray) = b.joinToString("") { "%02x".format(it.toInt() and 0xff) }

        fun fresh(now: Double, random: (Int) -> ByteArray = ::randomBytes) = LogShareState(hex(random(16)), hex(random(32)), through = now)

        fun decode(text: String?): LogShareState? {
            text ?: return null
            val s = FriendJson.decode(serializer(), text) ?: return null
            val ok = Regex("^[0-9a-f]+$")
            if (s.install.length != 32 || s.secret.length != 64 || !ok.matches(s.install) || !ok.matches(s.secret)) return null
            return s
        }

        fun encode(s: LogShareState) = FriendJson.encodeString(serializer(), s)
    }
}

/** The body of a put: what the relay is sent, and nothing else. */
@Serializable data class LogSharePut(val install: String, val secret: String, val app: String, val lines: List<String>)

@Serializable data class LogShareDelete(val install: String, val secret: String)

/** gzip around raw deflate (the same member the iOS app makes). */
object Gzip {
    fun crc32(data: ByteArray): Long = CRC32().also { it.update(data) }.value

    private fun le(v: Long) = byteArrayOf((v and 0xff).toByte(), ((v shr 8) and 0xff).toByte(), ((v shr 16) and 0xff).toByte(), ((v shr 24) and 0xff).toByte())

    fun wrap(deflated: ByteArray, original: ByteArray): ByteArray =
        byteArrayOf(0x1f, 0x8b.toByte(), 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xff.toByte()) + deflated + le(crc32(original)) + le(original.size.toLong())

    fun compress(data: ByteArray): ByteArray? = try {
        val d = Deflater(Deflater.DEFAULT_COMPRESSION, true)
        d.setInput(data)
        d.finish()
        val out = ByteArrayOutputStream()
        val buf = ByteArray(8192)
        while (!d.finished()) { val n = d.deflate(buf); out.write(buf, 0, n) }
        d.end()
        wrap(out.toByteArray(), data)
    } catch (_: Exception) { null }
}
