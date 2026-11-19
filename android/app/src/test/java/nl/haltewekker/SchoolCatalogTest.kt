package nl.haltewekker

import nl.haltewekker.profile.SchoolCatalog
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** The iOS app's own Schools.json (the Android build copies it in), read and searched as iOS `SchoolCatalog` does. */
class SchoolCatalogTest {
    private val list = SchoolCatalog.decode(File("../../ios/App/Schools.json").readText())

    @Test fun readsTheSharedList() {
        assertTrue(list.size >= 50)
        assertTrue(list.all { it.campuses.isNotEmpty() })
        assertTrue(list.flatMap { it.campuses }.all { it.lat in 50.7..53.6 && it.lon in 3.3..7.25 })
    }

    @Test fun searches() {
        assertEquals("uva", SchoolCatalog.search("uva", list).first().school.id)
        val vu = SchoolCatalog.search("Universiteit van Amsterdam", list).first()
        assertEquals("uva", vu.school.id)
        val sci = SchoolCatalog.search("uva science", list).first()
        assertEquals(listOf("Science Park"), sci.campuses.map { it.name })
        assertTrue(SchoolCatalog.search("", list).isEmpty())
        assertTrue(SchoolCatalog.search("zzzqqq", list).isEmpty())
    }

    @Test fun wordsFoldAccentsAndKeepTheSlash() {
        assertEquals(listOf("tu/e", "eindhoven"), SchoolCatalog.words("TU/e, Eindhoven"))
        assertEquals(listOf("s", "hertogenbosch"), SchoolCatalog.words("’s-Hertogenbosch"))
        assertEquals(listOf("cafe"), SchoolCatalog.words("Café"))
        assertTrue(SchoolCatalog.decode("not json").isEmpty())
        assertTrue(SchoolCatalog.decode("""[{"id":"x","name":"No campus","campuses":[]}, {"id":"y"}]""").isEmpty())
    }
}
