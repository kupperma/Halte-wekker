package nl.haltewekker.profile

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import nl.haltewekker.core.GeoPoint
import java.text.Normalizer

/** A school in the bundled list (the iOS app's own `Schools.json`, copied in at build time). */
@Serializable
data class School(val id: String, val name: String, val short: String = name, val aliases: List<String> = emptyList(),
                  val campuses: List<Campus> = emptyList()) {
    @Serializable
    data class Campus(val name: String, val city: String, val lat: Double, val lon: Double) {
        val point: GeoPoint get() = GeoPoint(lat, lon)
        /** "Breda", "Eindhoven, De Lismortel" */
        val label: String get() = if (name == city || name.startsWith(city)) name else "$name, $city"
    }
}

/** The bundled schools and the search over them (iOS `SchoolCatalog`). */
object SchoolCatalog {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    /** The list in a Schools.json; a school that doesn't read, or has no campus, is left out. */
    fun decode(text: String?): List<School> {
        val arr = try { text?.let { json.parseToJsonElement(it) } as? JsonArray } catch (_: Exception) { null } ?: return emptyList()
        return arr.mapNotNull { e ->
            val o = e as? JsonObject ?: return@mapNotNull null
            try {
                val s = json.decodeFromJsonElement<School>(o)
                s.copy(campuses = s.campuses.filter { it.lat.isFinite() && it.lon.isFinite() })
            } catch (_: Exception) { null }
        }.filter { it.campuses.isNotEmpty() }
    }

    data class Hit(val school: School, val campuses: List<School.Campus>)

    /** Lower case, no accents, punctuation as spaces ("/" stays: "TU/e"). */
    fun words(s: String): List<String> {
        val f = Normalizer.normalize(s.lowercase(), Normalizer.Form.NFD).replace(Regex("\\p{M}+"), "")
        return f.map { if (it.isLetterOrDigit() || it == '/') it else ' ' }.joinToString("").split(' ').filter { it.isNotEmpty() }
    }

    /**
     * Every word of the search must be in the school (its name, short name or another name) or in a campus (name or
     * town); words only a campus has narrow the campuses. Best first: a short or other name exactly, then a name that
     * starts with the search, then the rest (by name).
     */
    fun search(query: String, list: List<School>, limit: Int = 12): List<Hit> {
        val q = words(query)
        if (q.isEmpty()) return emptyList()
        val whole = q.joinToString(" ")
        val scored = ArrayList<Pair<Int, Hit>>()
        for (e in list) {
            val own = words((listOf(e.name, e.short) + e.aliases).joinToString(" "))
            val names = (listOf(e.short) + e.aliases).map { words(it).joinToString(" ") }
            var campuses = e.campuses
            var ok = true
            for (w in q) {
                if (own.any { it.startsWith(w) }) continue
                val near = campuses.filter { c -> words(c.name + " " + c.city).any { it.startsWith(w) } }
                if (near.isEmpty()) { ok = false; break }
                campuses = near
            }
            if (!ok) continue
            val full = words(e.name).joinToString(" ")
            val score = if (whole in names) 0 else if (full.startsWith(whole) || names.any { it.startsWith(whole) }) 1 else 2
            scored.add(score to Hit(e, campuses))
        }
        return scored.sortedWith(compareBy<Pair<Int, Hit>> { it.first }.thenBy { it.second.school.name }).take(limit).map { it.second }
    }
}
