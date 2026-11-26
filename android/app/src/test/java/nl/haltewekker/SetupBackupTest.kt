package nl.haltewekker

import nl.haltewekker.profile.SetupBackup
import nl.haltewekker.profile.SetupLogic
import nl.haltewekker.ride.NoticeExpiry
import nl.haltewekker.ride.Phase
import nl.haltewekker.ride.RideBar
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.assertFalse
import org.junit.Test

/** "Test the setup as a new user" (iOS `SetupBackupTests`), the roster link, old notifications, the ride bar. */
class SetupBackupTest {
    @Test fun roundTripPutsBackExactlyWhatWasThere() {
        val prefs = hashMapOf("profile.v1" to """{"setupDone":true}""", "school.v1" to """{"on":true}""", "other" to "x")
        val b = SetupBackup.take(prefs::get, 1_800_000_000.0)
        assertEquals(setOf("profile.v1", "school.v1"), b.values.keys)
        // the test: a new profile, a school week that wasn't there before
        prefs["profile.v1"] = """{"setupDone":true,"schoolId":"tue"}"""
        prefs["school.week.v1"] = "[]"
        prefs.remove("school.v1")
        val stored = SetupBackup.decode(b.copy(live = true).encode())!!
        assertTrue(stored.live)
        stored.restore { k, v -> if (v == null) prefs.remove(k) else prefs[k] = v }
        assertEquals(mapOf("profile.v1" to """{"setupDone":true}""", "school.v1" to """{"on":true}""", "other" to "x"), prefs)
    }

    @Test fun atLaunchAndOddStoredValues() {
        assertEquals(SetupBackup.LaunchStep.NOTHING, SetupBackup.atLaunch(null))
        val b = SetupBackup.take({ null }, 0.0)
        assertEquals(SetupBackup.LaunchStep.RESTORE, SetupBackup.atLaunch(b))
        assertEquals(SetupBackup.LaunchStep.KEEP_TESTING, SetupBackup.atLaunch(b.copy(live = true)))
        assertNull(SetupBackup.decode("garbage"))
        assertNull(SetupBackup.decode(b.copy(version = 2).encode()))
        // a value for a key it doesn't cover is dropped
        assertEquals(emptyMap<String, String>(), SetupBackup.decode(b.copy(values = mapOf("x" to "1")).encode())!!.values)
    }

    @Test fun rosterLinks() {
        assertEquals("webcal://cloud.timeedit.net/buas/web/ical.ics", SetupLogic.webcalUrl("  https://cloud.timeedit.net/buas/web/ical.ics "))
        assertEquals("webcal://x.example.nl/r?id=1", SetupLogic.webcalUrl("webcal://x.example.nl/r?id=1"))
        assertEquals("webcal://x.example.nl/a", SetupLogic.webcalUrl("HTTP://x.example.nl/a"))
        assertNull(SetupLogic.webcalUrl("ftp://x.example.nl/a"))
        assertNull(SetupLogic.webcalUrl("https://localhost/a"))
        assertNull(SetupLogic.webcalUrl("https://a b.nl/"))
        assertNull(SetupLogic.webcalUrl(""))
        assertEquals("https://x.example.nl/a", SetupLogic.httpsUrl("webcal://x.example.nl/a"))
    }

    @Test fun oldNotificationsGo() {
        val now = 1_800_000_000.0
        assertEquals(10.0, NoticeExpiry.minutes("arrived-1")!!, 0.0)
        assertEquals(90.0, NoticeExpiry.minutes("wake-missed-2026-11-20")!!, 0.0)
        assertNull(NoticeExpiry.minutes("ride"))
        assertNull(NoticeExpiry.minutes(null))
        assertEquals(listOf("arrived-x"), NoticeExpiry.due(listOf("arrived-x" to now - 601, "autostart" to now - 300, null to now - 9999.0, "ride" to now - 9999), now))
    }

    @Test fun rideBar() {
        assertEquals("To Uden", RideBar.title(null, "Uden"))
        assertEquals("Bus 305 to Uden", RideBar.title("Bus 305", "Uden"))
        assertEquals("Your trip", RideBar.title("", ""))
        assertEquals(RideBar.Countdown("12", "min"), RideBar.countdown(1000.0 + 12 * 60, 4000.0, 1000.0))
        assertEquals(RideBar.Countdown("1.4", "km"), RideBar.countdown(1000.0 - 300, 1400.0, 1000.0))
        assertEquals(RideBar.Countdown("450", "m"), RideBar.countdown(null, 447.0, 1000.0))
        assertNull(RideBar.countdown(null, null, 0.0))
        assertEquals("12 min · leg 1 of 2", RideBar.detail(RideBar.Countdown("12", "min"), 0, 2))
        assertEquals(RideBar.Wake.FINDING, RideBar.wake(Phase.SLEEPING, false))
        assertEquals(RideBar.Wake.ALARM, RideBar.wake(Phase.ALARM, false))
        assertTrue(RideBar.keepsSmall(true, rideOn = true, alarm = false))
        assertFalse(RideBar.keepsSmall(true, rideOn = true, alarm = true))
        assertFalse(RideBar.keepsSmall(true, rideOn = false, alarm = false))
    }
}
