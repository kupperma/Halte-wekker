package nl.haltewekker

import nl.haltewekker.profile.SettingsIndex
import nl.haltewekker.profile.SettingsTopic
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** iOS `SettingsIndexTests` (0.32.1 – 0.37), on the settings this app has. */
class SettingsIndexTest {
    private fun titles(q: String) = SettingsIndex.search(q).map { it.title }

    @Test fun alarmFindsEveryAlarm() {
        val t = titles("alarm")
        for (want in listOf("Backup alarm", "School alarm")) assertTrue("$want missing from $t", t.contains(want))
        assertEquals("Backup alarm", t.first())
    }

    @Test fun topicNameAloneDoesNotMatch() { assertFalse(titles("alarm").contains("Station announcement")) }

    @Test fun caseAccentsAndApostrophesDontMatter() {
        assertEquals("What’s sent", titles("WHATS SENT").first())
        assertEquals("What’s sent", titles("what's sent").first())
        assertTrue(titles("ALARM").contains("Backup alarm"))
        assertTrue(titles("chime at thé stop").contains("Chime at the stop"))
    }

    @Test fun everyWordMustMatch() {
        assertEquals(listOf("Backup alarm"), titles("backup alarm"))
        assertTrue(titles("alarm zebra").isEmpty())
    }

    @Test fun prefixOfAWord() {
        assertTrue(titles("headph").contains("Sound only with headphones"))
        assertTrue(titles("anno").contains("Station announcement"))
    }

    @Test fun keywordsFindIt() {
        assertTrue(titles("credits").contains("About and open data"))
        assertTrue(titles("vibrate").contains("Sound only with headphones"))
        assertTrue(titles("permissions").contains("What the ride needs"))
    }

    @Test fun emptyQueryFindsNothing() {
        assertTrue(titles("").isEmpty()); assertTrue(titles("   ").isEmpty()); assertTrue(titles("?!").isEmpty())
    }

    @Test fun titleMatchesBeforeKeywordMatches() {
        val r = SettingsIndex.search("battery")
        assertEquals(setOf("battery.longRides", "battery.limits"), r.take(2).map { it.id }.toSet())
    }

    @Test fun resultsKnowTheirTopic() {
        assertEquals(SettingsTopic.TRIPS, SettingsIndex.search("backup alarm").first().topic)
        assertEquals(SettingsTopic.SCHOOL, SettingsIndex.search("school alarm").first().topic)
        assertEquals(SettingsTopic.ADVANCED, SettingsIndex.search("about").first().topic)
    }

    @Test fun idsAreUniqueAndEveryTopicHasSettings() {
        val ids = SettingsIndex.all.map { it.id }
        assertEquals(ids.size, ids.toSet().size)
        for (t in SettingsTopic.entries) assertFalse("$t has no settings", SettingsIndex.entries(t, false).isEmpty())
    }

    @Test fun testSetupOnlyRows() {
        assertFalse(SettingsIndex.entries(false).map { it.id }.contains("adv.backToMine"))
        assertTrue(SettingsIndex.entries(true).map { it.id }.contains("adv.backToMine"))
        assertTrue(SettingsIndex.search("back to my own", SettingsIndex.entries(false)).isEmpty())
    }

    @Test fun wakeByTimeAndMotionAreFound() {
        assertEquals("wake.by", SettingsIndex.search("wake me").first().id)
        assertTrue(titles("minutes before").contains("Wake me … before my stop"))
        assertTrue(titles("by time").contains("Wake me … before my stop"))
        assertEquals("trips.motion", SettingsIndex.search("motion").first().id)
        assertTrue(titles("cycling").contains("Use motion to notice rides faster"))
    }

    @Test fun topicsInTwoGroups() {
        assertEquals(listOf(SettingsTopic.TRIPS, SettingsTopic.PLACES, SettingsTopic.SCHOOL, SettingsTopic.FRIENDS, SettingsTopic.MAP, SettingsTopic.NOTIFICATIONS), SettingsTopic.inGroup(1))
        assertEquals(listOf(SettingsTopic.BATTERY, SettingsTopic.SHARE, SettingsTopic.ADVANCED), SettingsTopic.inGroup(2))
        assertEquals("Help improve Haltewekker", SettingsTopic.SHARE.pageTitle)
    }

    @Test fun travelHelpRowsAreFound() {
        assertEquals("trips.studentOV", SettingsIndex.search("student ov").first().id)
        assertEquals("trips.checkOut", SettingsIndex.search("check out").first().id)
        assertEquals("trips.delayClaim", SettingsIndex.search("geld terug").first().id)
        assertEquals("notices.works", SettingsIndex.search("works").first().id)
        assertEquals("notices.lastHome", SettingsIndex.search("last way home").first().id)
        assertEquals(SettingsTopic.NOTIFICATIONS, SettingsIndex.search("last train").first().topic)
    }

    @Test fun rainOvfietsAndWidgetRowsAreFound() {
        assertEquals("map.rainAdvice", SettingsIndex.search("umbrella").first().id)
        assertEquals("map.rainAdvice", SettingsIndex.search("rain").first().id)
        assertEquals("map.ovfiets", SettingsIndex.search("ov-fiets").first().id)
        assertEquals("map.ovfiets", SettingsIndex.search("rental bike").first().id)
        assertEquals("map.widget", SettingsIndex.search("widget").first().id)
        assertEquals("map.widget", SettingsIndex.search("shortcuts").first().id)
    }
}
