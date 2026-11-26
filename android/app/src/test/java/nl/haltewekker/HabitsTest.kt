package nl.haltewekker

import nl.haltewekker.core.GeoPoint
import nl.haltewekker.friends.FriendJson
import nl.haltewekker.match.Fix
import nl.haltewekker.travel.ChangeBook
import nl.haltewekker.travel.ChangeOdds
import nl.haltewekker.travel.HabitBook
import nl.haltewekker.travel.Habits
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.ZoneId
import java.time.ZonedDateTime
import kotlin.math.cos

/** iOS `HabitsTests` and `ChangeOddsTests` (0.34). */
class HabitsTest {
    private val t0 = 1_800_000_000.0

    private fun walk(speed: Double, seconds: Int, accuracy: Double = 8.0, gpsSpeed: Boolean = true): List<Fix> =
        (0..seconds step 2).map { s ->
            val m = speed * s
            Fix(t0 + s, GeoPoint(51.59, 4.70 + m / (111_320 * cos(51.59 * Math.PI / 180))), accuracy, if (gpsSpeed) speed else -1.0, 90.0)
        }

    @Test fun aWalksSpeed() {
        assertEquals(1.5, Habits.walkSpeed(walk(1.5, 120)) ?: 0.0, 0.05)
        assertEquals(1.1, Habits.walkSpeed(walk(1.1, 120, gpsSpeed = false)) ?: 0.0, 0.05)
        assertNull(Habits.walkSpeed(walk(1.5, 30)))
        assertNull(Habits.walkSpeed(walk(1.5, 120, accuracy = 60.0)))
        assertNull(Habits.walkSpeed(walk(6.0, 120)))
        val wait = walk(0.0, 100) + walk(1.4, 120).map { it.copy(t = it.t + 102) }
        assertEquals(1.4, Habits.walkSpeed(wait) ?: 0.0, 0.05)
    }

    @Test fun yourWalkingSpeedOnceThereAreEnoughWalks() {
        var b = HabitBook()
        repeat(Habits.WALKS_NEEDED - 1) { b = b.addWalk(1.6) }
        assertNull(Habits.walkSpeed(b))
        b = b.addWalk(1.6)
        assertEquals(1.6, Habits.walkSpeed(b)!!, 0.0)
        assertEquals(8, Habits.walkMinutes(10, b))
        assertEquals(0, Habits.walkMinutes(0, b))
        assertEquals(10, Habits.walkMinutes(10, HabitBook()))
        assertEquals(1.6, Habits.pedestrianSpeed(b)!!, 0.0)
        var slowish = HabitBook()
        repeat(Habits.WALKS_NEEDED) { slowish = slowish.addWalk(1.25) }
        assertNull(Habits.pedestrianSpeed(slowish))
    }

    @Test fun walksKeptAreTheNewest() {
        var b = HabitBook()
        repeat(60) { b = b.addWalk(0.9) }
        repeat(Habits.KEEP) { b = b.addWalk(1.8) }
        assertEquals(1.8, Habits.walkSpeed(b)!!, 0.0)
        b = b.addWalk(Double.NaN).addWalk(9.0)
        assertEquals(Habits.KEEP, b.walks.size)
    }

    @Test fun changeTimeInPractice() {
        val stop = GeoPoint(51.59, 4.70 + 200 / (111_320 * cos(51.59 * Math.PI / 180)))
        val f = walk(1.25, 300)
        assertEquals(2.0, Habits.changeMinutes(t0, f, stop) ?: 0.0, 0.05)
        assertNull(Habits.changeMinutes(t0, f.take(20), stop))
    }

    @Test fun yourChangeTime() {
        var b = HabitBook().addChange(2.0).addChange(3.0)
        assertNull(Habits.changeMinutes(b))
        b = b.addChange(4.0)
        assertEquals(4.0, Habits.changeMinutes(b)!!, 0.0)
        repeat(7) { b = b.addChange(2.0) }
        assertEquals(2.0, Habits.changeMinutes(b)!!, 0.0)
    }

    @Test fun preferredStops() {
        var b = HabitBook().plannedFrom("Breda, Station")
        repeat(3) { b = b.boarded("Breda, Bolkenplein") }
        b = b.boarded("Breda, Station")
        assertTrue(Habits.preferred("Breda, Bolkenplein", b))
        assertFalse(Habits.preferred("Breda, Station", b))
        assertFalse(Habits.preferred("Elsewhere", b))
        assertEquals(Habits.PREFERRED_BONUS, Habits.bonus(" breda, bolkenplein ", b), 0.0)
        assertEquals(0.0, Habits.bonus("Breda, Station", b), 0.0)
        assertEquals(listOf("Breda, Bolkenplein"), Habits.preferredStops(b))
    }

    @Test fun wordsAndReset() {
        var b = HabitBook()
        assertEquals(listOf("not yet", "not yet", "none yet"), Habits.rows(b).map { it.value })
        repeat(Habits.WALKS_NEEDED) { b = b.addWalk(1.5) }
        for (m in listOf(3.0, 4.0, 5.0)) b = b.addChange(m)
        repeat(3) { b = b.boarded("Breda, Bolkenplein") }
        assertEquals(listOf("5.4 km/h", "5 min", "Breda, Bolkenplein"), Habits.rows(b).map { it.value })
        assertEquals(listOf("Walking speed", "Time you need to change", "Stops you prefer"), Habits.rows(b).map { it.label })
        assertFalse(b.isEmpty); assertTrue(HabitBook().isEmpty)
    }

    @Test fun habitsCodable() {
        val b = HabitBook().addWalk(1.4).addChange(3.0).boarded("X").plannedFrom("Y")
        assertEquals(b, FriendJson.decode(HabitBook.serializer(), FriendJson.encodeString(HabitBook.serializer(), b)))
    }

    // ChangeOdds

    private val ams = ZoneId.of("Europe/Amsterdam")
    private fun date(d: Int, h: Int, m: Int = 0) = ZonedDateTime.of(2026, 11, d, h, m, 0, 0, ams).toEpochSecond().toDouble()

    @Test fun keyAndBucket() {
        assertEquals("IC>SPR@tilburg|wd-am", ChangeOdds.key("IC", "SPR", "Tilburg", date(19, 7, 40), ams))
        assertEquals("wd-day", ChangeOdds.bucket(date(19, 12), ams))
        assertEquals("wd-pm", ChangeOdds.bucket(date(19, 17, 30), ams))
        assertEquals("wd-eve", ChangeOdds.bucket(date(19, 21), ams))
        assertEquals("wd-early", ChangeOdds.bucket(date(19, 6), ams))
        assertEquals("we-am", ChangeOdds.bucket(date(21, 8), ams))
        assertEquals("20261119", ChangeOdds.day(date(19, 7, 40), ams))
    }

    @Test fun oneOutcomePerDay() {
        val k = "IC>SPR@tilburg|wd-am"
        val b = ChangeBook().record(k, "20261119", false).record(k, "20261119", true).record(k, "20261118", true)
        assertEquals(2, b.tally(k).second); assertEquals(2, b.tally(k).first); assertEquals(0, b.tally("other").second)
    }

    @Test fun keepsTheNewestDays() {
        var b = ChangeBook()
        for (d in 0 until 45) b = b.record("k", "2026%04d".format(1000 + d), d >= 40)
        assertEquals(ChangeBook.DAYS_KEPT, b.tally("k").second)
        assertEquals(5, b.tally("k").first)
    }

    @Test fun words() {
        assertNull(ChangeOdds.words(2, 2))
        assertEquals("this change worked on 9 of 10 days", ChangeOdds.words(9, 10))
        assertEquals("this change worked on 3 of 3 days", ChangeOdds.words(3, 3))
    }

    @Test fun missChanceLeansOnYourHistory() {
        assertEquals(0.3, ChangeOdds.missChance(0.3, 0, 0), 0.0)
        assertEquals(0.3, ChangeOdds.missChance(0.3, 2, 2), 0.0)
        assertTrue(ChangeOdds.missChance(0.3, 10, 10) < 0.15)
        assertTrue(ChangeOdds.missChance(0.1, 2, 8) > 0.35)
        assertEquals(0.95, ChangeOdds.missChance(0.95, 10, 10), 0.0)
    }

    @Test fun outcome() {
        val dep = date(19, 8, 0)
        assertEquals(true, ChangeOdds.made("a", dep, "a", null))
        assertEquals(true, ChangeOdds.made("a", dep, "b", dep + 30))
        assertEquals(false, ChangeOdds.made("a", dep, "b", dep + 600))
        assertNull(ChangeOdds.made("a", dep, "b", null))
    }

    @Test fun changeBookCodable() {
        val b = ChangeBook().record("k", "20261119", true)
        assertEquals(b, FriendJson.decode(ChangeBook.serializer(), FriendJson.encodeString(ChangeBook.serializer(), b)))
    }
}
