package nl.haltewekker

import nl.haltewekker.widget.IntentActions
import nl.haltewekker.widget.StopBoardCore
import nl.haltewekker.widget.StopBoardCore.Departure
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import kotlin.math.roundToInt

/** iOS `StopBoardCoreTests` and `IntentActionsTests` (0.37). */
class StopBoardCoreTest {
    private val t0 = 1_800_000_000.0
    private fun at(m: Double) = t0 + m * 60
    private val hhmm: (Double) -> String = { "+${((it - t0) / 60).roundToInt()}" }
    private fun dep(line: String, m: Double, late: Double = 0.0, cancelled: Boolean = false, train: Boolean = false) =
        Departure(line, "Uden", at(m + late), at(m), true, cancelled, train)

    @Test fun parseStoptimes() {
        val j = """{"stopTimes":[
          {"place":{"name":"Veghel, Busstation","departure":"2026-11-20T06:43:00Z","scheduledDeparture":"2026-11-20T06:41:00Z","track":"B"},
           "mode":"BUS","realTime":true,"headsign":"Den Bosch","routeShortName":"305","tripId":"t1"},
          {"place":{"name":"Veghel, Busstation","departure":"2026-11-20T06:52:00Z","scheduledDeparture":"2026-11-20T06:52:00Z"},
           "mode":"BUS","realTime":false,"headsign":"Uden","routeShortName":"306","tripCancelled":true},
          {"place":{"name":"End","arrival":"2026-11-20T06:30:00Z"},"mode":"BUS","routeShortName":"9"},
          {"place":{"name":"'s-Hertogenbosch","departure":"2026-11-20T06:35:00Z","scheduledDeparture":"2026-11-20T06:35:00Z"},
           "mode":"REGIONAL_RAIL","realTime":true,"headsign":"Breda","routeShortName":"Intercity"}]}"""
        val d = StopBoardCore.parseStoptimes(j)
        assertEquals(listOf("IC", "305", "306"), d.map { it.line })
        assertTrue(d[0].train); assertEquals(2, d[1].delay); assertEquals("B", d[1].platform)
        assertTrue(d[2].cancelled); assertEquals(0, d[2].delay)
        assertTrue(StopBoardCore.parseStoptimes("{}").isEmpty()); assertTrue(StopBoardCore.parseStoptimes("oops").isEmpty())
    }

    @Test fun parseGeocode() {
        val j = """[{"type":"STOP","id":"nl_1","name":"Veghel, Busstation","lat":51.61,"lon":5.54,"areas":[{"name":"Veghel","default":true}],"modes":["BUS"]},
         {"type":"STOP","id":"nl_2","name":"Breda","lat":51.59,"lon":4.78,"areas":[{"name":"Breda","matched":true}],"modes":["REGIONAL_RAIL","BUS"]},
         {"type":"ADDRESS","id":"a","name":"Street 1","lat":1,"lon":1},
         {"type":"STOP","name":"no id","lat":1,"lon":1}]"""
        val s = StopBoardCore.parseGeocode(j)
        assertEquals(listOf("nl_1", "nl_2"), s.map { it.id }); assertEquals("Veghel", s[0].town); assertFalse(s[0].rail); assertTrue(s[1].rail)
    }

    @Test fun stopAsAnId() {
        val s = StopBoardCore.Stop("nl-openov_stoparea:123", "Veghel, Busstation", "Veghel", 51.616543, 5.543219, false)
        assertEquals(s, StopBoardCore.decode(StopBoardCore.encode(s)))
        assertNull(StopBoardCore.decode("nl_1")); assertNull(StopBoardCore.decode(""))
        assertEquals("A B", StopBoardCore.decode(StopBoardCore.encode(StopBoardCore.Stop("x", "A\u001FB", lat = 1.0, lon = 2.0)))?.name)
    }

    @Test fun link() {
        val s = StopBoardCore.Stop("nl_2:a&b", "Breda & Co", lat = 51.59, lon = 4.78, rail = true)
        val url = StopBoardCore.link(s)
        assertTrue(url.startsWith("haltewekker://stop?"))
        val back = StopBoardCore.parseLink(url)!!
        assertEquals("nl_2:a&b", back.id); assertEquals("Breda & Co", back.name); assertTrue(back.rail)
        assertNull(StopBoardCore.parseLink("haltewekker://friend?v=1"))
        assertNull(StopBoardCore.parseLink("haltewekker://stop?id=x&lat=200&lon=1"))
        assertNull(StopBoardCore.parseLink("https://stop?id=x&lat=1&lon=1"))
    }

    @Test fun urls() {
        assertTrue(StopBoardCore.stoptimesUrl("nl_1", t0, 12).startsWith("https://api.transitous.org/api/v6/stoptimes?stopId=nl_1&n=12&time="))
        val g = StopBoardCore.geocodeUrl("veghel bus", 51.6 to 5.5)
        assertTrue(g.contains("type=STOP")); assertTrue(g.contains("text=veghel%20bus"))
    }

    @Test fun timelineMovesUpAsTheyLeave() {
        val deps = listOf(dep("305", 4.0), dep("306", 15.0, late = 2.0), dep("305", 34.0), dep("306", 45.0), dep("305", 64.0))
        val (entries, reload) = StopBoardCore.timeline(deps, t0, 2, 12 * 60.0)
        assertEquals(t0, entries.first().date, 0.0)
        assertEquals(listOf("305", "306"), entries.first().departures.map { it.line })
        assertEquals(listOf("+0", "+5"), entries.map { hhmm(it.date) })
        assertEquals(listOf("+17", "+34"), entries[1].departures.map { hhmm(it.time) })
        assertEquals(at(12.0), reload, 0.0)
    }

    @Test fun timelineAsksSoonerWhenItRunsShort() {
        assertEquals(t0 + 8 * 60 + 30, StopBoardCore.timeline(listOf(dep("305", 8.0), dep("306", 30.0)), t0, 2).second, 0.0)
        assertEquals(at(5.0), StopBoardCore.timeline(listOf(dep("305", 1.0), dep("306", 30.0)), t0, 2).second, 0.0)
        val none = StopBoardCore.timeline(emptyList(), t0, 3)
        assertEquals(listOf(StopBoardCore.Entry(t0, emptyList())), none.first); assertEquals(at(30.0), none.second, 0.0)
        assertEquals(listOf("2"), StopBoardCore.upcoming(listOf(dep("1", -1.0), dep("2", 3.0)), t0, 3).map { it.line })
    }

    @Test fun words() {
        assertEquals("+43 (+2)", StopBoardCore.timeText(dep("305", 41.0, late = 2.0), hhmm))
        assertEquals("+40 (−1)", StopBoardCore.timeText(dep("305", 41.0, late = -1.0), hhmm))
        assertEquals("+41", StopBoardCore.timeText(dep("305", 41.0), hhmm))
        assertEquals("+41 cancelled", StopBoardCore.timeText(dep("305", 41.0, late = 3.0, cancelled = true), hhmm))
        assertEquals("Bus 305", StopBoardCore.title(dep("305", 1.0)))
        assertEquals("IC", StopBoardCore.title(dep("IC", 1.0, train = true)))
        assertEquals("SPR", StopBoardCore.trainLabel("Sprinter"))
    }

    @Test fun spoken() {
        assertEquals("Bus 305 to Uden leaves Veghel at +8, 2 minutes late — in 8 minutes. Then the 306 at +17.",
            StopBoardCore.spoken(listOf(dep("305", 6.0, late = 2.0), dep("306", 17.0), dep("307", 30.0)), "Veghel", t0, hhmm))
        assertEquals("Bus 305 to Uden leaves Veghel at +0 — now.", StopBoardCore.spoken(listOf(dep("305", 0.0)), "Veghel", t0, hhmm))
        assertEquals("Nothing leaves Veghel in the next while.", StopBoardCore.spoken(listOf(dep("305", 5.0, cancelled = true)), "Veghel", t0, hhmm))
    }

    @Test fun widgetLinkOpensTheStop() {
        val url = StopBoardCore.link(StopBoardCore.Stop("nl_1", "Veghel, Busstation", lat = 51.6, lon = 5.5))
        val a = IntentActions.action(url) as? IntentActions.Action.ShowStop ?: return fail("not the stop")
        assertEquals("nl_1", a.stop.id)
        assertNull(IntentActions.action("haltewekker://friend?v=1&k=x")); assertNull(IntentActions.action("haltewekker://spotify?code=1"))
    }

    @Test fun nothingStartsOverARunningTrip() {
        val s = StopBoardCore.Stop("x", "X", lat = 1.0, lon = 1.0)
        assertEquals(IntentActions.Outcome.Go, IntentActions.outcome(IntentActions.Action.ShowStop(s), false))
        for (a in listOf(IntentActions.Action.Wake(s), IntentActions.Action.Fastest(true), IntentActions.Action.StartTrip)) {
            assertEquals(IntentActions.Outcome.Go, IntentActions.outcome(a, true))
            assertTrue("$a went past a running trip", IntentActions.outcome(a, false) is IntentActions.Outcome.Refuse)
        }
    }

    @Test fun startMyTrip() {
        assertEquals(IntentActions.Start.ALREADY_RUNNING, IntentActions.start(false, at(1.0), t0))
        assertEquals(IntentActions.Start.OPEN_FASTEST, IntentActions.start(true, null, t0))
        assertEquals(IntentActions.Start.START_NOW, IntentActions.start(true, at(3.0), t0))
        assertEquals(IntentActions.Start.START_NOW, IntentActions.start(true, at(-10.0), t0))
        assertEquals(IntentActions.Start.OPEN_PLANNED, IntentActions.start(true, at(4.0), t0))
        assertEquals(IntentActions.Start.OPEN_FASTEST, IntentActions.start(true, at(-16.0), t0))
        assertNull(IntentActions.startText(IntentActions.Start.START_NOW)); assertNotNull(IntentActions.startText(IntentActions.Start.OPEN_PLANNED))
    }

    @Test fun whichStopForWhensMyBus() {
        assertEquals(IntentActions.BusFrom.HOME, IntentActions.busFrom(200.0, true))
        assertEquals(IntentActions.BusFrom.HOME, IntentActions.busFrom(null, true))
        assertEquals(IntentActions.BusFrom.NEAREST, IntentActions.busFrom(2_000.0, true))
        assertEquals(IntentActions.BusFrom.NEAREST, IntentActions.busFrom(100.0, false))
    }
}
