package nl.haltewekker

import kotlinx.serialization.json.Json
import nl.haltewekker.ride.AdaptiveWake
import nl.haltewekker.ride.GetReady
import nl.haltewekker.ride.WakeBook
import nl.haltewekker.ride.WakeBy
import nl.haltewekker.ride.WakeSample
import nl.haltewekker.ride.WakeSettings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** iOS `AdaptiveWakeTests` and `GetReadyTests` (0.39). */
class AdaptiveWakeTest {
    private val t0 = 1_800_000_000.0
    private fun ride(train: Boolean, react: Double?, lead: Double, k: Int = 0) = WakeSample(train, react, lead, t0 + k * 86_400.0)
    private fun WakeBook.plus(s: WakeSample) = add(s).first

    @Test fun nothingMovesBeforeThreeRides() {
        var b = WakeBook()
        val (b1, m1) = b.add(ride(true, 150.0, 180.0)); assertFalse(m1); b = b1
        val (b2, m2) = b.add(ride(true, 150.0, 180.0, 1)); assertFalse(m2); b = b2
        assertEquals(0, b.trainExtra)
        assertEquals("Learning: 1 more ride", AdaptiveWake.summary(b, WakeBy.TIME))
    }

    @Test fun shortOfTimeAgainMovesItAMinuteEarlier() {
        var b = WakeBook()
        for (k in 0 until 3) b = b.plus(ride(true, 150.0, 180.0, k))
        assertEquals(1, b.trainExtra); assertEquals(0, b.busExtra)
        assertEquals("Learned: wakes you 1 min earlier on trains", AdaptiveWake.summary(b, WakeBy.TIME))
        for (k in 3 until 12) b = b.plus(ride(true, 170.0, 180.0, k))
        assertEquals(AdaptiveWake.MAX_TRAIN, b.trainExtra)
    }

    @Test fun arrivingStillRingingCountsAsNoTime() {
        var b = WakeBook()
        for (k in 0 until 3) b = b.plus(ride(false, null, 120.0, k))
        assertEquals(1, b.busExtra)
        for (k in 3 until 10) b = b.plus(ride(false, null, 120.0, k))
        assertEquals(AdaptiveWake.MAX_BUS, b.busExtra)
    }

    @Test fun plentyOfRoomBringsItBackButNeverLaterThanYourSetting() {
        var b = WakeBook()
        for (k in 0 until 3) b = b.plus(ride(true, 150.0, 180.0, k))
        assertEquals(1, b.trainExtra)
        for (k in 3 until 15) b = b.plus(ride(true, 10.0, 310.0, k))
        assertEquals(0, b.trainExtra)
        assertEquals(3, AdaptiveWake.effective(WakeSettings(trainMinutes = 3, busMinutes = 2), b).trainMinutes)
    }

    @Test fun oneOddRideDoesNotMoveIt() {
        var b = WakeBook()
        for (k in 0 until 4) b = b.plus(ride(true, 20.0, 180.0, k))
        val (b2, moved) = b.add(ride(true, null, 180.0, 5))
        assertFalse(moved); assertEquals(0, b2.trainExtra)
    }

    @Test fun outliersAreIgnored() {
        assertFalse(AdaptiveWake.valid(ride(true, 5.0, 10.0)))
        assertFalse(AdaptiveWake.valid(ride(true, 5.0, 25 * 60.0)))
        assertFalse(AdaptiveWake.valid(ride(true, 900.0, 200.0)))
        assertFalse(AdaptiveWake.valid(ride(true, -1.0, 200.0)))
        assertTrue(AdaptiveWake.valid(ride(true, null, 200.0)))
        var b = WakeBook()
        for (k in 0 until 5) b = b.plus(ride(true, 5.0, 10.0, k))
        assertTrue(b.samples.isEmpty()); assertEquals(0, b.trainExtra)
    }

    @Test fun effectiveOnlyEverAddsAndOffIsYourSetting() {
        val s = WakeSettings(trainMinutes = 3, busMinutes = 2)
        var b = WakeBook(trainExtra = 2, busExtra = 9)
        val e = AdaptiveWake.effective(s, b)
        assertEquals(5, e.trainMinutes); assertEquals(4, e.busMinutes)
        b = b.copy(trainExtra = -4)
        assertEquals(3, AdaptiveWake.effective(s, b).trainMinutes)
        b = b.copy(on = false, trainExtra = 2)
        assertEquals(s, AdaptiveWake.effective(s, b))
        assertEquals("Off", AdaptiveWake.summary(b, WakeBy.TIME))
    }

    @Test fun keepsTheNewestPerMode() {
        var b = WakeBook()
        for (k in 0 until 15) b = b.plus(ride(true, 20.0, 180.0, k))
        for (k in 0 until 4) b = b.plus(ride(false, 20.0, 180.0, k))
        assertEquals(AdaptiveWake.KEEP, b.samples.count { it.train })
        assertEquals(4, b.samples.count { !it.train })
        assertEquals(t0 + 5 * 86_400.0, b.samples.first { it.train }.at, 0.0)
    }

    @Test fun summaryWords() {
        var b = WakeBook(trainExtra = 1, busExtra = 1)
        assertEquals("Learned: wakes you 1 min earlier", AdaptiveWake.summary(b, WakeBy.TIME))
        b = b.copy(busExtra = 2)
        assertEquals("Learned: wakes you 2 min earlier on buses, 1 on trains", AdaptiveWake.summary(b, WakeBy.TIME))
        b = b.copy(trainExtra = 0)
        assertEquals("Learned: wakes you 2 min earlier on buses", AdaptiveWake.summary(b, WakeBy.TIME))
        assertEquals("Only when waking by time", AdaptiveWake.summary(b, WakeBy.DISTANCE))
        var c = WakeBook()
        for (k in 0 until 3) c = c.plus(ride(true, 20.0, 180.0, k))
        assertEquals("Learned: as you set it", AdaptiveWake.summary(c, WakeBy.TIME))
    }

    @Test fun codableRoundTrip() {
        val b = WakeBook().plus(ride(true, null, 100.0)).copy(busExtra = 1)
        assertEquals(b, Json.decodeFromString(WakeBook.serializer(), Json.encodeToString(WakeBook.serializer(), b)))
    }

    private fun at(m: Double) = t0 + m * 60

    @Test fun getReady() {
        assertNull(GetReady.before(2)); assertEquals(1, GetReady.before(3)); assertEquals(6, GetReady.before(8))
        assertFalse(GetReady.due(at(0.0), at(6.0), at(-1.0), 180.0, true, false))
        assertTrue(GetReady.due(at(0.0), at(6.0), at(-0.4), 180.0, true, false))
        assertTrue(GetReady.due(at(0.0), at(6.0), at(1.0), 180.0, true, false))
        assertFalse(GetReady.due(at(0.0), at(3.5), at(0.0), 180.0, true, false))
        assertTrue(GetReady.due(at(0.0), at(3.5), at(0.0), 0.0, true, false))
        assertFalse(GetReady.due(at(0.0), at(20.0), at(0.0), 180.0, true, false))
        assertFalse(GetReady.due(at(0.0), at(6.0), at(0.0), 180.0, true, true))
        assertFalse(GetReady.due(at(0.0), at(6.0), at(0.0), 180.0, false, false))
        assertFalse(GetReady.due(null, at(6.0), at(0.0), 180.0, true, false))
        assertFalse(GetReady.due(at(6.0), at(6.0), at(6.0), 0.0, true, false))
        val w = GetReady.words("Breda", 330.0)
        assertEquals("Get ready: Breda is next", w.first)
        assertEquals("Your stop is the next one, about 6 min. The alarm still rings before it.", w.second)
        assertEquals("Get ready: your stop is next", GetReady.words("", null).first)
        assertEquals("ready-1800000000-1", GetReady.id(t0, 1))
    }
}
