package nl.haltewekker.school

import java.text.Normalizer
import java.util.Locale

/**
 * Does a calendar look like your school timetable (iOS `SchoolHints`)? Words in its name (or its account's), else in
 * its events' notes and rooms. The setup marks those calendars and picks them for you when none is picked yet.
 */
data class SchoolHints(val names: List<String>, val events: List<String>) {
    companion object {
        /** The timetable apps and the words any school's timetable calendar tends to be called. */
        val generic = listOf("timeedit", "mytimetable", "xedule", "untis", "rooster", "lesrooster", "timetable", "school")
        /** The apps that fill a timetable calendar (their names show up in the events' links and notes). */
        val apps = listOf("timeedit", "mytimetable", "xedule", "untis")
        /** Shorter than this, a school's own word ("UU", "HvA") would match too much. */
        const val MINIMUM_LENGTH = 4

        /** The words for the school's names (its short name and full name), with the generic ones. */
        fun make(school: List<String>): SchoolHints {
            val own = school.map(::fold).filter { it.length >= MINIMUM_LENGTH }
            return SchoolHints(unique(generic + own), unique(apps + own))
        }

        /** Lower case, without accents ("Hogeschool Inhölland" reads as "hogeschool inholland"). */
        fun fold(s: String): String =
            Normalizer.normalize(s, Normalizer.Form.NFD).replace(Regex("\\p{Mn}+"), "").lowercase(Locale.ROOT).trim()

        /** A calendar by its title and account, then (only if those don't say) the text of its events, read lazily. */
        fun matches(title: String, account: String, eventText: () -> List<String>, hints: SchoolHints): Boolean {
            val name = fold("$title $account")
            if (hints.names.any { name.contains(it) }) return true
            return eventText().any { t -> val f = fold(t); hints.events.any { f.contains(it) } }
        }

        private fun unique(l: List<String>): List<String> { val seen = HashSet<String>(); return l.filter { it.isNotEmpty() && seen.add(it) } }
    }
}
