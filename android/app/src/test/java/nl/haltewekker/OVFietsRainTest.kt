package nl.haltewekker

import nl.haltewekker.travel.OVFiets
import nl.haltewekker.travel.RainAdvice
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** iOS `OVFietsTests` and `RainAdviceTests` (0.37). */
class OVFietsRainTest {
    private val relay = """{"station":"BD","locations":[{"name":"BD - OV-fiets - Breda Belcrum","code":"bd002","bikes":193,"lat":51.596338,"lon":4.77892,"open":"No"},
        {"name":"BD - OV-fiets - Breda Centrum","code":"Bd003","bikes":225,"lat":51.59502,"lon":4.779437,"open":"No"}]}"""

    @Test fun relayAnswer() {
        val a = OVFiets.parse(relay, "BD")!!
        assertEquals("BD", a.station); assertEquals(listOf("bd002", "Bd003"), a.points.map { it.code })
        assertEquals(418, a.total); assertEquals(true, a.closed)
        assertEquals("OV-fiets: 418 left · closed now", OVFiets.text(a))
    }

    @Test fun nsOwnAnswer() {
        val ns = """{"links":{},"payload":[{"type":"stationfacility","name":"OV-fiets","locations":[
          {"name":"Breda Belcrum","stationCode":"BD","lat":51.5,"lng":4.7,"open":"Yes","extra":{"rentalBikes":"12","locationCode":"bd002"}},
          {"name":"Utrecht","stationCode":"UT","lat":52,"lng":5,"extra":{"rentalBikes":"300","locationCode":"ut001"}},
          {"name":"Breda Centrum","stationCode":"BD","lat":51.5,"lng":4.7,"extra":{"locationCode":"bd003"}}]}]}"""
        val a = OVFiets.parse(ns, "bd")!!
        assertEquals(2, a.points.size); assertEquals(12, a.total); assertEquals(false, a.closed)
        assertEquals("OV-fiets: 12 left", OVFiets.text(a))
    }

    @Test fun words() {
        fun ans(b: List<Int?>, open: Boolean? = null) = OVFiets.Answer("TB", b.mapIndexed { i, n -> OVFiets.Point("p$i", "c$i", n, open) })
        assertEquals("OV-fiets: 1 left", OVFiets.text(ans(listOf(1))))
        assertEquals("OV-fiets: none left", OVFiets.text(ans(listOf(0, 0))))
        assertNull(OVFiets.text(ans(listOf(null)))); assertNull(OVFiets.text(ans(emptyList())))
        assertTrue(OVFiets.low(ans(listOf(3, 2)))); assertFalse(OVFiets.low(ans(listOf(6))))
        assertNull(ans(listOf(4)).closed)
    }

    @Test fun badAnswers() {
        assertNull(OVFiets.parse("nope", "BD")); assertNull(OVFiets.parse("[]", "BD"))
        assertNull(OVFiets.parse("""{"station":"VGL","locations":[]}""", "VGL")?.total)
        assertEquals(7, OVFiets.parse("""{"locations":[{"bikes":-3},{"bikes":"7"}]}""", "x")?.total)
    }

    @Test fun cacheFiveMinutes() {
        val t = 1_800_000_000.0
        assertTrue(OVFiets.fresh(t, t + 299)); assertFalse(OVFiets.fresh(t, t + 301)); assertFalse(OVFiets.fresh(t, t - 120))
    }

    @Test fun whichStation() {
        val bus = OVFiets.Ride(false, null)
        assertEquals("BD", OVFiets.station(listOf(bus, OVFiets.Ride(true, "BD")), 15))
        assertNull(OVFiets.station(listOf(bus, OVFiets.Ride(true, "BD")), 2))
        assertEquals("EHV", OVFiets.station(listOf(OVFiets.Ride(true, "HT"), OVFiets.Ride(true, "EHV"), bus), 0))
        assertNull(OVFiets.station(listOf(bus, bus), 20))
        assertNull(OVFiets.station(listOf(OVFiets.Ride(true, null)), 20))
    }

    private val t0 = 1_799_996_400.0
    private fun at(m: Double) = t0 + m * 60
    private val hhmm: (Double) -> String = { "+${((it - t0) / 60).toInt()}" }
    private fun hours(mm: List<Double>) = mm.mapIndexed { i, v -> RainAdvice.Hour(at((i + 1) * 60.0), v) }

    @Test fun stretches() {
        assertEquals(listOf(RainAdvice.Stretch(at(10.0), at(18.0), true), RainAdvice.Stretch(at(60.0), at(70.0), false)),
            RainAdvice.stretches(at(10.0), 8, at(60.0), at(70.0)))
        assertTrue(RainAdvice.stretches(at(10.0), 1, at(60.0), at(61.0)).isEmpty())
    }

    @Test fun rainOnTheWalkThere() {
        val s = RainAdvice.stretches(at(40.0), 10, at(100.0), at(105.0))
        assertNull(RainAdvice.hit(s, hours(listOf(0.1, 0.8)), hours(listOf(0.0, 0.0))))
        assertEquals(RainAdvice.Hit(at(40.0), 0.6, true), RainAdvice.hit(s, hours(listOf(0.6, 0.0)), hours(listOf(0.0, 0.0))))
    }

    @Test fun rainOnTheWalkFromTheLastStop() {
        val s = RainAdvice.stretches(at(40.0), 10, at(55.0), at(70.0))
        assertEquals(RainAdvice.Hit(at(60.0), 2.0, false), RainAdvice.hit(s, hours(listOf(0.0, 0.0)), hours(listOf(0.0, 2.0))))
    }

    @Test fun thresholdIsHalfAMillimetre() {
        val s = RainAdvice.stretches(at(10.0), 10, at(30.0), at(30.0))
        assertNull(RainAdvice.hit(s, hours(listOf(0.49)), emptyList()))
        assertNotNull(RainAdvice.hit(s, hours(listOf(0.5)), emptyList()))
    }

    @Test fun onlyBeforeATrip() {
        assertTrue(RainAdvice.due(at(170.0), at(0.0))); assertFalse(RainAdvice.due(at(190.0), at(0.0)))
        assertTrue(RainAdvice.due(at(0.0), at(4.0))); assertFalse(RainAdvice.due(at(0.0), at(6.0)))
    }

    @Test fun busInstead() {
        val ok = RainAdvice.Bus("305", at(20.0), 2, at(35.0), at(38.0))
        val late = RainAdvice.Bus("306", at(25.0), 2, at(40.0), at(38.0))
        val far = RainAdvice.Bus("158", at(15.0), 7, at(30.0), at(38.0))
        val gone = RainAdvice.Bus("90", at(11.0), 2, at(30.0), at(38.0))
        assertEquals(ok, RainAdvice.bus(12, at(10.0), listOf(late, far, gone, ok)))
        assertNull(RainAdvice.bus(12, at(10.0), listOf(late, far, gone)))
        assertEquals(ok, RainAdvice.bus(6, at(10.0), listOf(ok)))
        assertNull(RainAdvice.bus(6, at(10.0), listOf(RainAdvice.Bus("1", at(20.0), 3, at(30.0), at(38.0)))))
    }

    @Test fun adviceAndWords() {
        val start = RainAdvice.Hit(at(60.0), 1.0, true); val end = RainAdvice.Hit(at(60.0), 1.0, false)
        val b = RainAdvice.Bus("305", at(41.0), 2, at(55.0), at(58.0))
        assertEquals(RainAdvice.Advice.TakeBus("305", at(41.0)), RainAdvice.advice(start, true, 12, b))
        assertEquals(RainAdvice.Advice.Umbrella, RainAdvice.advice(start, false, 12, b))
        assertEquals(RainAdvice.Advice.Umbrella, RainAdvice.advice(start, true, 4, b))
        assertEquals(RainAdvice.Advice.Umbrella, RainAdvice.advice(end, true, 12, b))
        assertEquals(RainAdvice.Advice.Umbrella, RainAdvice.advice(start, true, 12, null))
        assertEquals("Rain at +60 — take bus 305 at +41 to the station instead of walking", RainAdvice.text(start, RainAdvice.Advice.TakeBus("305", at(41.0)), hhmm))
        assertEquals("Rain at +60 — take the N1 at +41 to the station instead of walking", RainAdvice.text(start, RainAdvice.Advice.TakeBus("N1", at(41.0)), hhmm))
        assertEquals("Rain at +60 — bring an umbrella", RainAdvice.text(end, RainAdvice.Advice.Umbrella, hhmm))
    }

    @Test fun openMeteoHours() {
        val h = RainAdvice.parseHours("""{"hourly":{"time":[1799996400,1800000000],"precipitation":[0.0,0.7]}}""")
        assertEquals(listOf(RainAdvice.Hour(1799996400.0, 0.0), RainAdvice.Hour(1800000000.0, 0.7)), h)
        assertTrue(RainAdvice.parseHours("nope").isEmpty())
    }
}
