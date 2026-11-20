package nl.haltewekker.friends

import kotlinx.serialization.Serializable
import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import java.time.DayOfWeek
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToLong

// Test friend (A5, iOS 0.30.1 `TestFriendBrain.swift`): a bot that is a real second Friends account made on this phone,
// to try every Friends feature with before anyone you know has the app. Its account, its boxes and the relay are the
// real ones (TestFriendBot.kt); this file is its brain: what it says back and the trips, waits and timetables it
// pretends, as plain values, tested without the relay or the UI. Times are unix seconds.

object TestFriendBrain {
    /** Its name everywhere (the request it sends, your list, the chat). */
    const val NAME = "Test friend"
    /** Under its name in your requests. */
    const val NOTE = "A test friend made on your phone, to try Friends with. Remove it any time."

    /** Its first line once you're friends. */
    const val HELLO = "Hi! I’m your test friend, a bot that lives on this phone. Write to me, send me a trip, add me to a group, or try the buttons under “Test friend controls” on my page."

    /** In a group it was added to (it only answers you there, never your other friends). */
    fun groupHello(group: String) = "Hi everyone! I’m the test friend. Thanks for adding me to “$group”. I answer here too."

    /** Quick replies ("’" and "'" alike, any case). */
    private fun plain(s: String) = s.lowercase().replace("'", "’").trim()

    /** What it says back to a line of text (null: nothing to say). */
    fun reply(text: String): String? {
        val t = ChatText.clean(text)
        if (t.isEmpty()) return null
        val p = plain(t)
        val count = t.codePointCount(0, t.length)
        if (p.startsWith("on the ") && count > 7) return "Nice, I’ll look out for you on the ${t.drop(7)}."
        when (p) {
            "running 5 min late" -> return "No problem, I’ll wait. See you in a bit!"
            "save me a seat" -> return "Saved you one by the window."
            "wait for me" -> return "Sure, I’ll wait for you!"
            "i’m at the stop" -> return "Great, I’m almost there!"
            "hi", "hey", "hello", "hoi", "hallo" -> return "Hi! Test friend here. Your message came through, locked end to end."
        }
        if (p.endsWith("?")) return "Good question! I’m only a test friend, so I can’t really answer, but your message came through fine."
        val shown = if (count > 80) FriendNames.takeChars(t, 80) + "…" else t
        return "You said: “$shown”. Got it, locked end to end."
    }

    /** Its answer to a trip card: "I’m in" (as an answer), then a line about the ride. */
    fun repliesToTrip(c: TripCard, n: String): List<ChatText> {
        val out = mutableListOf(ChatText(TripAnswer.YES.text, n, TripAnswer.YES.raw))
        TripTake.shared(c)?.let { r -> out.add(ChatText("See you on the ${r.label} at ${TripCardWords.hhmm(r.dep)}!")) }
        return out
    }

    /** Its answer to your "Wait for me": "I’ll wait" (as an answer). */
    fun replyToWait(id: String) = ChatText(WaitAnswer.WAIT.text, id, WaitAnswer.WAIT.raw)

    /** What it says when you answer something of its own (its wait, its card). */
    fun replyToAnswer(answer: String): String? = when (answer) {
        WaitAnswer.WAIT.raw -> "Thanks for waiting! Nearly there."
        WaitAnswer.NEXT.raw -> "OK, let’s take the next one together."
        TripAnswer.YES.raw -> "Great, see you there!"
        TripAnswer.NO.raw -> "Shame! Next time."
        else -> null
    }

    // MARK: its timetable (a plausible two weeks near yours)

    /**
     * Two weeks of classes near yours: each weekday a first class when yours starts that day (or 08:45; Friday 10:30),
     * the next after a 30-minute break and the last after an hour's (Wednesday afternoon free); no weekends.
     */
    fun timetable(mine: TimetableShare?, now: Double): TimetableShare {
        val zone = TimetableDays.zone
        val (from, to) = TimetableDays.window(now)
        val firsts = firstClasses(mine)
        val start = TimetableDays.localDate(now)
        val classes = mutableListOf<TimetableClass>()
        for (i in 0 until TimetableShare.DAYS) {
            val day = start.plusDays(i.toLong())
            val wd = day.dayOfWeek
            if (wd == DayOfWeek.SATURDAY || wd == DayOfWeek.SUNDAY) continue
            var base = if (wd == DayOfWeek.FRIDAY) 10 * 60 + 30 else 8 * 60 + 45
            firsts[TimetableDays.key(day)]?.let { f ->
                val z = java.time.Instant.ofEpochMilli((f * 1000).roundToLong()).atZone(zone)
                base = z.hour * 60 + z.minute
            }
            base = max(7 * 60 + 30, min(13 * 60, base))
            val parts = mutableListOf(Triple(0 to 90, "Project work", "B1.12"), Triple(120 to 210, "Lecture", "Aula"))
            if (wd != DayOfWeek.WEDNESDAY) parts.add(Triple(270 to 390, "Workshop", "C0.08"))
            val midnight = day.atStartOfDay(zone)
            for ((span, title, room) in parts) {
                val s = midnight.plusMinutes((base + span.first).toLong()).toEpochSecond().toDouble()
                val e = midnight.plusMinutes((base + span.second).toLong()).toEpochSecond().toDouble()
                classes.add(TimetableClass(s, e, title, room))
            }
        }
        return TimetableShare(from, to, classes, src = "week")
    }

    /** Your first class of each day (by day key). */
    private fun firstClasses(mine: TimetableShare?): Map<String, Double> {
        val out = HashMap<String, Double>()
        for (c in mine?.classes ?: emptyList()) {
            val k = TimetableDays.key(c.start)
            val had = out[k]
            if (had != null && had <= c.start) continue
            out[k] = c.start
        }
        return out
    }

    // MARK: its scores (near yours)

    /**
     * Its fastest trips on your routes (a little slower going, a little faster home), or two of its own when you have
     * none yet; all from an hour ago, so they count for this month too.
     */
    fun scores(mine: List<ScoreTrip>, rides: Int, now: Double): ScoresShare {
        val at = now - 3600
        var trips = ScoresRules.bests(mine).map { b ->
            val factor = if (b.home) 0.96 else 1.05
            ScoreTrip(b.route, b.home, max(5.0, min(600.0, b.mins * factor)), at)
        }
        if (trips.isEmpty()) trips = listOf(ScoreTrip("home→school", false, 46.5, at), ScoreTrip("school→home", true, 51.2, at))
        // (A6, iOS 0.35) and a trip to school an hour ago, for today's best and worst: 52.4 min, the 305 7 min late
        return ScoresRules.build(trips, rides, now, listOf(DayTrip(false, 52.4, at, 45.0, "305", 7.0)))
    }

    // MARK: the wake-up buddy

    /** "I haven't left": a plan for today that said leave 6 minutes ago, for a ride in 4 minutes. */
    fun buddy(now: Double, ride: TripCard.Ride?) = BuddyPlan(on = true, day = TimetableDays.key(now), leave = now - 6 * 60, ride = ride, left = null)

    /** A ride for its pretend plans: from `from` to `to`, leaving in `inMinutes`. */
    fun ride(from: TripCard.Spot, to: TripCard.Spot, train: Boolean, now: Double, inMinutes: Double, id: String): TripCard.Ride {
        val dep = now + inMinutes * 60
        return TripCard.Ride(mode = if (train) "train" else "bus", line = if (train) "SPR" else "300", name = if (train) "Sprinter" else null,
            num = null, trip = id, head = to.name, from = from, to = to, dep = dep, arr = dep + 12 * 60)
    }

    // MARK: your vault

    /** What the vault keeps, without the test friend: never in your backup (the list, a group's members, "off", buddy). */
    fun scrub(c: FriendVaultContents, bot: String): FriendVaultContents {
        val b = c.book.copy(
            friends = c.book.friends.filter { it.id != bot },
            incoming = c.book.incoming.filter { it.id != bot },
            outgoing = c.book.outgoing.filter { it.id != bot },
        )
        val groups = c.groups?.map { g -> g.copy(roster = g.roster.copy(members = g.roster.members.filter { it.id != bot })) }
        var tt = c.timetable
        val off = tt?.off
        if (tt != null && off != null) tt = tt.copy(off = off.filter { it != bot }.ifEmpty { null })
        var ex = c.extras
        val buddy = ex?.buddy
        if (ex != null && buddy != null) ex = ex.copy(buddy = buddy.filter { it != bot }.ifEmpty { null })
        return c.copy(book = b, groups = groups, timetable = tt, extras = ex)
    }
}

// MARK: a pretend trip

/**
 * A trip the test friend pretends to be on: a real bus or train near your Home (its stops as the live data has them),
 * squeezed into `TestTripSim.RIDE_FOR` from now: a minute waiting at the first stop, then riding to the last.
 */
@Serializable
data class TestTrip(
    val mode: String,
    val line: String,
    val num: String? = null,
    val trip: String,
    val stops: List<Stop>,
    /** Where the bus or train goes in the end (its headsign), when it isn't the last stop here. */
    val dest: String? = null,
    /** When it started (waiting at the first stop). */
    val start: Double,
) {
    /** `at`: seconds after it starts riding. */
    @Serializable data class Stop(val name: String, val lat: Double, val lon: Double, val at: Double)

    val isTrain: Boolean get() = mode == "train"
}

object TestTripSim {
    /** A minute at the stop first… */
    const val WAIT_FOR = 60.0
    /** …then this long on board. */
    const val RIDE_FOR = 10 * 60.0
    /** Stops taken after the first: until this far into the real trip, at most `MAX_STOPS` in all. */
    const val REAL_SPAN = 25 * 60.0
    const val MAX_STOPS = 8

    data class RealStop(val name: String, val lat: Double, val lon: Double, val time: Double?)

    /**
     * The trip from `stops` (the real ones, from where it gets on): its stops' real times (or, without them, their
     * distances) spread over `RIDE_FOR`. Null: fewer than two stops.
     */
    fun make(mode: String, line: String, num: String?, trip: String, stops: List<RealStop>, dest: String?, start: Double): TestTrip? {
        val first = stops.firstOrNull() ?: return null
        val kept = mutableListOf(first)
        for (s in stops.drop(1)) {
            if (kept.size >= MAX_STOPS) break
            if (kept.size >= 2 && first.time != null && s.time != null && s.time - first.time > REAL_SPAN) break
            val last = kept.last()
            if (Geo.metres(GeoPoint(s.lat, s.lon), GeoPoint(last.lat, last.lon)) < 30) continue
            kept.add(s)
        }
        if (kept.size < 2) return null
        // the share of the way each stop is at: by its time when every time is known and they go up, else by distance
        val byTime = mutableListOf<Double>()
        var timesOK = true
        for (s in kept) {
            val t = s.time; val t0 = first.time
            if (t == null || t0 == null) { timesOK = false; break }
            val x = t - t0
            val last = byTime.lastOrNull()
            if (last != null && x <= last) { timesOK = false; break }
            byTime.add(x)
        }
        val total = byTime.lastOrNull()
        val share: List<Double> = if (timesOK && total != null && total > 0) byTime.map { it / total } else {
            val run = mutableListOf(0.0)
            for (i in 1 until kept.size) {
                val a = GeoPoint(kept[i - 1].lat, kept[i - 1].lon); val b = GeoPoint(kept[i].lat, kept[i].lon)
                run.add(run[i - 1] + max(1.0, Geo.metres(a, b)))
            }
            val all = run.last()
            run.map { it / all }
        }
        val out = kept.mapIndexed { i, s -> TestTrip.Stop(s.name, s.lat, s.lon, Math.round(share[i] * RIDE_FOR).toDouble()) }
        val last = kept.last().name
        val d = if (dest.isNullOrEmpty() || dest == last) null else dest
        return TestTrip(mode, line, num, trip, out, d, start)
    }

    /** When it's over (at the last stop). */
    fun end(t: TestTrip) = t.start + WAIT_FOR + RIDE_FOR

    fun over(t: TestTrip, now: Double) = now >= end(t)

    private fun round5(v: Double) = Math.round(v * 100_000) / 100_000.0

    /** Where it is now, as a `travel` state (null: over, or not begun). A train gets a coach (3 of 6, from the front). */
    fun state(t: TestTrip, now: Double): TravelState? {
        if (t.stops.size < 2 || now < t.start || over(t, now)) return null
        val first = t.stops.first(); val last = t.stops.last()
        val riding = now - t.start >= WAIT_FOR
        val p = position(t, now)
        return TravelState(
            state = if (riding) "riding" else "waiting", mode = t.mode, line = t.line, num = t.num, trip = t.trip,
            from = TravelState.Spot(first.name, first.lat, first.lon), to = TravelState.Spot(last.name, last.lat, last.lon),
            dest = t.dest?.let { TravelState.Spot(it) }, eta = end(t), end = end(t),
            pos = TravelState.Position(round5(p.lat), round5(p.lon), 12.0, now), leg = 1, legs = 1,
            coach = if (t.isTrain && riding) coach(t.line) else null,
        )
    }

    /** Its coach on a train: 3 of 6 from the front, and a window: an Intercity's upper deck, the 8th from the back; a Sprinter's 6th. */
    fun coach(line: String): TravelState.Coach {
        val double = SeatMap.defaultDouble(line)
        val seat = TravelState.Seat(if (double) SeatMap.Deck.UPPER.raw else SeatMap.Deck.NONE.raw, if (double) 8 else 6, SeatMap.WINDOWS)
        return TravelState.Coach(3, 6, true, null, seat)
    }

    /** Between the two stops it's between now, by time (at the first stop while waiting, at the last when over). */
    fun position(t: TestTrip, now: Double): GeoPoint {
        val first = t.stops.firstOrNull() ?: return GeoPoint(0.0, 0.0)
        val last = t.stops.last()
        val r = now - t.start - WAIT_FOR
        if (r <= 0) return GeoPoint(first.lat, first.lon)
        for (i in 1 until t.stops.size) {
            val a = t.stops[i - 1]; val b = t.stops[i]
            if (r >= b.at) continue
            val span = max(1.0, b.at - a.at)
            val f = max(0.0, min(1.0, (r - a.at) / span))
            return GeoPoint(a.lat + (b.lat - a.lat) * f, a.lon + (b.lon - a.lon) * f)
        }
        return GeoPoint(last.lat, last.lon)
    }

    /** The NS station nearest `p` within `within` metres. */
    fun nearestStation(p: GeoPoint, stations: List<NSStation>, within: Double): NSStation? =
        stations.map { it to Geo.metres(p, it.point) }.filter { it.second <= within }.minByOrNull { it.second }?.first

    /** The next station on from `a`: the nearest one at least 1.5 km (and at most `upTo`) away. */
    fun nextStation(a: NSStation, stations: List<NSStation>, upTo: Double = Double.MAX_VALUE): NSStation? =
        stations.filter { it.code != a.code }.map { it to Geo.metres(a.point, it.point) }.filter { it.second >= 1500 && it.second <= upTo }
            .minByOrNull { it.second }?.first

    /** Without the live data: a Sprinter between the NS station nearest home and the next one (at least 1.5 km on). */
    fun fallback(home: GeoPoint, stations: List<NSStation>, start: Double): TestTrip? {
        val a = nearestStation(home, stations, 30_000.0) ?: return null
        val b = nextStation(a, stations, 40_000.0) ?: return null
        val stops = listOf(RealStop(a.name, a.lat, a.lon, null), RealStop(b.name, b.lat, b.lon, null))
        return make("train", "SPR", null, "test-friend-${a.code}-${b.code}", stops, null, start)
    }
}

// MARK: a pretend "wait for me"

/** The test friend asks you to wait: coming from 650 m away, there after 5 minutes, over after 10. */
@Serializable
data class TestWait(val id: String, val stop: TripCard.Spot, val start: Double)

object TestWaitSim {
    const val COME_FOR = 5 * 60.0
    const val OVER_AFTER = 10 * 60.0
    const val START_METRES = 650.0

    fun over(w: TestWait, now: Double) = now - w.start >= OVER_AFTER

    /** The `wait` body now. */
    fun body(w: TestWait, now: Double): WaitFor {
        val e = max(0.0, now - w.start)
        if (e >= OVER_AFTER) return WaitFor(w.id, WaitFor.Phase.OFF.raw, w.stop, dist = 0, at = now)
        if (e >= COME_FOR) return WaitFor(w.id, WaitFor.Phase.THERE.raw, w.stop, dist = 0, eta = now, at = now)
        val left = START_METRES * (1 - e / COME_FOR)
        val dist = Math.round(left / 10).toInt() * 10
        return WaitFor(w.id, WaitFor.Phase.COMING.raw, w.stop, dist = dist, eta = w.start + COME_FOR, at = now)
    }
}
