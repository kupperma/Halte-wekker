package nl.haltewekker

import nl.haltewekker.match.BetterStop
import nl.haltewekker.match.TrainRules
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** (0.10.6, iOS 0.42.9 `BetterStopTests`) a through train's later stops planned from, the faster one offered. */
class BetterStopTest {
    private val t0 = Fx.t0
    private fun at(s: Double) = t0 + s
    private val calls = listOf(
        TrainRules.Call(Fx.east(0.0), at(0.0), "Breda"), TrainRules.Call(Fx.east(20_000.0), at(1500.0), "Tilburg"),
        TrainRules.Call(Fx.east(40_000.0, north = 10_000.0), at(2400.0), "A"), TrainRules.Call(Fx.east(50_000.0), at(3300.0), "B"),
        TrainRules.Call(Fx.east(150_000.0), at(1500.0 + 2 * 3600), "Far"))
    private val dest = Fx.east(45_000.0, north = 20_000.0)

    @Test fun laterStopsNearestTheDestinationFirst() {
        assertEquals(listOf(2, 3), BetterStop.candidates(calls, 1, dest, at(60.0)))
        assertEquals(emptyList<Int>(), BetterStop.candidates(calls, 4, dest, at(60.0)))
        assertEquals(emptyList<Int>(), BetterStop.candidates(calls.take(2), 1, dest, at(60.0)))
        assertEquals(listOf(3), BetterStop.candidates(calls, 1, dest, at(3000.0)))
    }

    @Test fun twoCandidatesPickTheFasterOne() {
        val o = listOf(BetterStop.Option(2, at(5520.0), 1), BetterStop.Option(3, at(5880.0), 1))
        assertEquals(2, BetterStop.best(at(6060.0), 2, o)?.stop)
    }

    @Test fun noOfferUnderThreeMinutes() {
        assertNull(BetterStop.best(at(6060.0), 1, listOf(BetterStop.Option(2, at(5940.0), 1))))
        assertNull(BetterStop.best(at(6060.0), 1, listOf(BetterStop.Option(2, at(6300.0), 0))))
        assertEquals(3, BetterStop.best(at(6060.0), 2, listOf(BetterStop.Option(3, at(6080.0), 1)))?.stop)
        assertNull(BetterStop.best(at(6060.0), 1, emptyList()))
    }

    @Test fun words() {
        assertEquals("Stay on to 's-Hertogenbosch — home 15:52 instead of 16:01 (bus 306 at 15:31)",
            BetterStop.offerText("'s-Hertogenbosch", "home", "15:52", "16:01", "bus 306 at 15:31"))
        assertEquals("better stop · stay on to 's-Hertogenbosch · home 15:52 (−9 min)", BetterStop.log("'s-Hertogenbosch", "home", "15:52", 9))
        assertEquals(9, BetterStop.minutesSooner(at(6060.0), at(5520.0)))
    }
}
