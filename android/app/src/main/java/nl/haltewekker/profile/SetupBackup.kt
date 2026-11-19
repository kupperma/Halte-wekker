package nl.haltewekker.profile

import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/**
 * "Test the setup as a new user" (iOS 0.23 `SetupBackup`): your own setup, kept while you try the first-run setup as
 * someone new. It holds the stored values of every key the setup can change (the profile, the school alarm's settings,
 * its planned week and skipped days, the auto-start's memory), exactly as stored, and a key that wasn't there as not
 * there. Saved under its own key before the test changes anything: a backup that never went `live` (the test's Done
 * wasn't reached) is put back at the next launch. Plain values, tested.
 */
@Serializable
data class SetupBackup(
    val version: Int = VERSION,
    val made: Double,
    /** The test setup is in use (Done was tapped): it stays until "Back to my own". */
    val live: Boolean = false,
    val covered: List<String>,
    val values: Map<String, String>,
) {
    /** Puts every covered key back as it was: `write` with its value, or with null for a key that wasn't there. */
    fun restore(write: (String, String?) -> Unit) { for (k in covered) write(k, values[k]) }

    fun encode(): String = json.encodeToString(this)

    enum class LaunchStep { NOTHING, KEEP_TESTING, RESTORE }

    companion object {
        const val STORAGE_KEY = "setup.backup.v1"
        const val VERSION = 1
        private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

        /** The stored keys it keeps: the ones the setup writes and the ones learnt for your places. */
        val keys = listOf(
            Store.KEY_PROFILE, "school.v1", "school.week.v1", "school.skip",
            "auto.lastEnd", "auto.blocked", "auto.homeDay", "resume.v1",
        )

        fun take(read: (String) -> String?, now: Double): SetupBackup {
            val v = LinkedHashMap<String, String>()
            for (k in keys) read(k)?.let { v[k] = it }
            return SetupBackup(made = now, live = false, covered = keys, values = v)
        }

        /** From what was saved (null: none, or not one this version can read). */
        fun decode(s: String?): SetupBackup? {
            if (s.isNullOrEmpty()) return null
            val b = try { json.decodeFromString<SetupBackup>(s) } catch (_: Exception) { return null }
            if (b.version != VERSION) return null
            return b.copy(values = b.values.filterKeys { it in b.covered })
        }

        /** At launch: one whose test never went live is put back now; a live one waits for "Back to my own". */
        fun atLaunch(b: SetupBackup?): LaunchStep = when {
            b == null -> LaunchStep.NOTHING
            b.live -> LaunchStep.KEEP_TESTING
            else -> LaunchStep.RESTORE
        }
    }
}

/** The setup's rules that are plain values (iOS `SetupLogic`): the roster link. */
object SetupLogic {
    /**
     * A pasted roster or iCal link as a `webcal://` link a calendar app subscribes to: http(s) becomes webcal, webcal
     * stays, spaces around it go; anything that isn't a web link to a host is null.
     */
    fun webcalUrl(text: String): String? {
        val t = text.trim()
        if (t.isEmpty() || t.any { it.isWhitespace() }) return null
        val u = try { java.net.URI(t) } catch (_: Exception) { return null }
        val scheme = u.scheme?.lowercase() ?: return null
        if (scheme !in listOf("http", "https", "webcal", "webcals")) return null
        val host = u.host ?: return null
        if (!host.contains('.') || host.startsWith('.') || host.endsWith('.')) return null
        return "webcal" + t.substring(scheme.length)
    }

    /** The same link for a browser or a subscription app that wants https (webcal → https). */
    fun httpsUrl(webcal: String): String = when {
        webcal.startsWith("webcals://", true) -> "https://" + webcal.substring(10)
        webcal.startsWith("webcal://", true) -> "https://" + webcal.substring(9)
        else -> webcal
    }
}
