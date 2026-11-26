package nl.haltewekker.ride

import nl.haltewekker.core.Geo
import nl.haltewekker.core.GeoPoint
import nl.haltewekker.data.Ride
import nl.haltewekker.data.Transit
import nl.haltewekker.data.TransitParse
import nl.haltewekker.live.GPSFix
import nl.haltewekker.live.LiveFeeds
import nl.haltewekker.live.RealPositions
import nl.haltewekker.logs.FieldFormat
import nl.haltewekker.logs.FieldLog
import nl.haltewekker.match.AskSooner
import nl.haltewekker.match.BusStops
import nl.haltewekker.match.ChoiceLook
import nl.haltewekker.match.ChoiceRun
import nl.haltewekker.match.ChooseGPS
import nl.haltewekker.match.DepartMatch
import nl.haltewekker.match.Departure
import nl.haltewekker.match.Fix
import nl.haltewekker.match.Judgement
import nl.haltewekker.match.LineRide
import nl.haltewekker.match.TimedOut
import nl.haltewekker.match.TimedPiece
import nl.haltewekker.match.TrainRules
import nl.haltewekker.match.UsualLine
import nl.haltewekker.match.VehicleGPS
import nl.haltewekker.match.VehicleMatch
import nl.haltewekker.match.VehicleTrack
import nl.haltewekker.match.choose
import nl.haltewekker.match.offRoad
import nl.haltewekker.match.sameChoice
import nl.haltewekker.match.verdict
import nl.haltewekker.match.ShownVerdict
import nl.haltewekker.travel.Habits
import java.time.ZoneId

/**
 * (A7) The ride's choice between buses or trains that fit about as well (iOS `TripManager.beginChoosing` /
 * `chooseByJudging` / `settle`, 0.26.1 – 0.39.1): every 12 s each candidate judged by its own trip (its stops and road,
 * live times, its own GPS) on your fixes, the train stopping pattern (`TrainRules`), the one that left the stop with you
 * (`DepartMatch`), the bus stopping pattern (`BusStops`) and your usual line (`UsualLine`), decided by
 * `VehicleMatch.choose`. Two still tied a minute after you left: ask (`AskSooner`). Never rings or stops the alarm: it
 * only says which vehicle the leg follows.
 */
class RideChoice {
    data class Cand(val tripId: String, val line: String, val isTrain: Boolean)

    sealed class Outcome {
        data class Settle(val id: String, val why: ChoiceLook.Why?) : Outcome()
        data class Ask(val a: Cand, val b: Cand, val title: String, val answers: List<String>, val train: Boolean, val to: Map<String, String>) : Outcome()
        data object None : Outcome()
    }

    private class Cached(val trip: TransitParse.LiveTrip?, val at: Double)

    var cands: List<Cand> = emptyList(); private set
    private val trips = HashMap<String, Cached>()
    private var since: Double? = null
    private val run = ChoiceRun()
    private var asked = false
    private var leftAt: Double? = null
    private var usualHeld: String? = null
    private val trainSeen = HashMap<String, TrainRules.Seen>()
    private val busSeen = HashMap<String, BusStops.Seen>()
    private var busLogged = ""
    private var timedOut: TimedOut? = null
    private val previous = HashMap<String, GPSFix>()

    val active: Boolean get() = cands.size > 1
    val usualBreaksTie: Boolean get() = usualHeld != null

    /** Starts choosing between `list` (the one shown first): at most 3, never the same ones again within 10 minutes of a choice that timed out. */
    fun begin(list: List<Cand>, now: Double, departedAt: Double?): Boolean {
        val l = list.distinctBy { it.tripId }.take(3)
        if (l.size < 2 || VehicleMatch.sameChoice(l.map { it.tripId }, timedOut, now)) { clear(); return false }
        cands = l
        since = now; run.reset(); asked = false; trainSeen.clear(); busSeen.clear(); busLogged = ""; usualHeld = null
        leftAt = departedAt
        return true
    }

    fun clear() {
        cands = emptyList(); since = null; run.reset(); usualHeld = null
    }

    /** The trip answer of a candidate (asked again after a minute). */
    suspend fun trip(id: String, now: Double): TransitParse.LiveTrip? {
        val c = trips[id]
        if (c != null && now - c.at < 60 && c.trip != null) return c.trip
        val t = try { Transit.trip(id, maxAge = 60.0) } catch (_: Exception) { null }
        trips[id] = Cached(t ?: c?.trip, now)
        return t ?: c?.trip
    }

    /** One look (every 12 s while choosing). */
    suspend fun look(fixes: List<Fix>, shown: String?, now: Double, real: Boolean, lines: List<LineRide>, planned: Ride?,
                     departure: Departure?, onJudged: (List<Judgement>) -> Unit): Outcome {
        if (!active) return Outcome.None
        val last = fixes.lastOrNull() ?: return Outcome.None
        if (now - last.t > 30 || last.accuracy < 0 || last.accuracy >= 100) return Outcome.None
        val list = cands
        val byTrip = HashMap<String, TransitParse.LiveTrip>()
        for (c in list) trip(c.tripId, now)?.let { byTrip[c.tripId] = it }
        if (list != cands) return Outcome.None
        val plain = list.mapNotNull { c -> byTrip[c.tripId]?.let { track(c.tripId, c.line, c.isTrain, it) } }
        val tracks = if (real) withGPS(plain, byTrip, now) else plain
        val judgedAll = VehicleMatch.judgeAll(fixes, tracks, strictTimes = false)
        onJudged(judgedAll)
        val names = list.associate { it.tripId to it.line }
        // trains: the stopping pattern rules out the ones that call where you went through at speed, or run through where you stood
        val out = if (list.all { it.isTrain }) trainPatternOut(list, byTrip, fixes).toMutableSet() else mutableSetOf()
        if (out.isNotEmpty()) FieldLog.match("choose · stopping pattern · not " + out.sorted().joinToString(", ") { FieldFormat.label(it, names) })
        if (shown != null && shown in out) {
            val rest = list.filter { it.tripId !in out }
            val best = VehicleMatch.rank(judgedAll.filter { j -> rest.any { it.tripId == j.id } }, planned = null).firstOrNull()?.id
            if (best != null) return finish(best, null)
            out.remove(shown)
        }
        val kept = list.filter { it.tripId !in out }
        val keptIds = kept.map { it.tripId }
        val judged = judgedAll.filter { it.id in keptIds }
        // the one it shows, by today's road check: your last fix from its road
        val mine = kept.firstOrNull { it.tripId == shown }
        val road = mine?.let { byTrip[it.tripId] }?.path?.takeIf { it.size >= 2 }?.let { Geo.project(last.p, it)?.crossTrack }
        val away = VehicleMatch.offRoad(road, mine?.isTrain ?: false)
        val keptTracks = tracks.filter { it.tripId in keptIds }
        val departed = departPick(keptTracks, keptIds, names, departure)
        val nudge = (if (kept.all { !it.isTrain }) busPatternNudge(kept, byTrip, fixes, names) else emptyMap()).toMutableMap()
        usualChoice(kept, judged, nudge, now, lines, planned, departure)?.let { u -> nudge[u] = (nudge[u] ?: 0.0) - UsualLine.BONUS }
        val choosingFor = since?.let { now - it } ?: 0.0
        val c = VehicleMatch.choose(keptIds, judged, shown, away, choosingFor, run, now, nudge = nudge, departed = departed)
        var note = ""
        if (away && VehicleMatch.verdict(judged.firstOrNull { it.id == shown }?.result, false) == ShownVerdict.NOT_SURE) note += " · off its road"
        note += when (c.why) {
            ChoiceLook.Why.ONLY_ONE_LEFT -> " · the only one left"
            ChoiceLook.Why.TIMED_OUT -> " · 12 minutes"
            ChoiceLook.Why.BY_GPS -> " · by its GPS"
            ChoiceLook.Why.SPLIT -> " · roads split"
            ChoiceLook.Why.DEPARTED -> " · left the stop with you"
            ChoiceLook.Why.FAR_BY_GPS -> " · its own GPS far from you, the other one's fits"
            else -> ""
        }
        val outcome = c.settle?.let { (if (it == shown) "keep " else "switch to ") + FieldFormat.label(it, names) }
            ?: ("still choosing · " + c.alive.joinToString(" or ") { FieldFormat.label(it, names) })
        FieldLog.match("choose · " + judged.joinToString(" · ") { j -> FieldFormat.label(j.id, names) + " " + (j.cost?.let { "${Math.round(it)} s" } ?: (j.why?.name?.lowercase()?.replace('_', ' ') ?: "?")) } +
            " → " + outcome + note)
        if (c.why == ChoiceLook.Why.TIMED_OUT) timedOut = TimedOut(c.alive.toSet(), now)
        cands = kept.filter { it.tripId in c.alive }
        // two still tied that go different ways (trains), or two buses of another line or destination: ask once (0.34, 0.38)
        val sameKind = kept.all { it.isTrain } || kept.all { !it.isTrain }
        if (c.settle == null && sameKind && !asked && c.alive.size == 2) {
            val dest = kept.associate { it.tripId to (byTrip[it.tripId]?.headsign ?: "") }
            val ago = leftAt?.let { now - it }
            val movingFor = minOf(ago ?: Double.POSITIVE_INFINITY, choosingFor + VehicleMatch.MIN_SPAN)
            val a = kept.firstOrNull { it.tripId == c.alive[0] }
            val b = kept.firstOrNull { it.tripId == c.alive[1] }
            if (a != null && b != null && AskSooner.due(c.alive, movingFor, asked, usualHeld != null) &&
                AskSooner.worthAsking(a.line to b.line, (dest[a.tripId] ?: "") to (dest[b.tripId] ?: ""))) {
                asked = true
                val train = a.isTrain
                val same = a.line.lowercase() == b.line.lowercase()
                val title = AskSooner.title(a.line to (dest[a.tripId] ?: ""), b.line to (dest[b.tripId] ?: ""), train)
                FieldLog.match("ask · still tied ${Math.round(movingFor)} s after leaving · ${FieldFormat.label(a.tripId, names)} or ${FieldFormat.label(b.tripId, names)}")
                return Outcome.Ask(a, b, title, listOf(a, b).map { AskSooner.answer(it.line, dest[it.tripId] ?: "", train, same) }, train, dest)
            }
        }
        val id = c.settle ?: return Outcome.None
        return finish(id, c.why)
    }

    /** (A7) the ride's own one judged by its own trip and GPS (for how long its GPS has been with you: the wrong bus). */
    suspend fun judgeOne(fixes: List<Fix>, c: Cand, now: Double, real: Boolean): List<Judgement> {
        val t = trip(c.tripId, now) ?: return emptyList()
        val tr = track(c.tripId, c.line, c.isTrain, t) ?: return emptyList()
        val tracks = if (real) withGPS(listOf(tr), mapOf(c.tripId to t), now) else listOf(tr)
        return VehicleMatch.judgeAll(fixes, tracks, strictTimes = false)
    }

    private fun finish(id: String, why: ChoiceLook.Why?): Outcome {
        clear()
        return Outcome.Settle(id, why)
    }

    /** A candidate's trip as the matcher's track: one piece per stop to stop, on its road. */
    fun track(id: String, line: String, isTrain: Boolean, t: TransitParse.LiveTrip): VehicleTrack? {
        val pieces = ArrayList<TimedPiece>()
        for (i in 0 until t.stops.size - 1) {
            val a = t.stops[i]; val b = t.stops[i + 1]
            val dep = a.departure ?: a.arrival ?: continue
            val arr = b.arrival ?: b.departure ?: continue
            val path = WakeRoad.cut(t.path, a.point, b.point) ?: listOf(a.point, b.point)
            pieces.add(TimedPiece(dep, arr, path))
        }
        if (pieces.isEmpty()) return null
        return VehicleTrack(id, line, isTrain, t.live, pieces)
    }

    /** Each one with its own fresh GPS fix (OVapi for buses, NS by train number), and its previous one when seen. */
    private suspend fun withGPS(tracks: List<VehicleTrack>, byTrip: Map<String, TransitParse.LiveTrip>, now: Double): List<VehicleTrack> {
        val buses = try { if (tracks.any { !it.isTrain }) LiveFeeds.busFixes() else emptyMap() } catch (_: Exception) { emptyMap() }
        val trains = try { if (tracks.any { it.isTrain }) LiveFeeds.trainFixes() else emptyMap() } catch (_: Exception) { emptyMap() }
        return tracks.map { t ->
            val f = if (t.isTrain) RealPositions.trainNumber(byTrip[t.tripId]?.num ?: "")?.let { n -> trains[n]?.let { RealPositions.usable(it, t.tripId, now, RealPositions.MATCH_FRESH) } }
            else RealPositions.usable(buses, t.tripId, now, RealPositions.MATCH_FRESH)
            if (f == null) t else {
                val p = previous[t.tripId]?.takeIf { it.at < f.at }
                if (previous[t.tripId]?.at != f.at) previous[t.tripId] = f
                t.copy(gps = VehicleGPS(f, p))
            }
        }
    }

    private fun trainPatternOut(list: List<Cand>, byTrip: Map<String, TransitParse.LiveTrip>, fixes: List<Fix>): Set<String> {
        val stations = HashMap<String, GeoPoint>()
        val calls = HashMap<String, Set<String>>()
        for (c in list) {
            val t = byTrip[c.tripId] ?: return emptySet()
            val mine = HashSet<String>()
            for (st in t.stops) {
                val k = Habits.key(st.name)
                if (k.isEmpty()) continue
                mine.add(k)
                stations.putIfAbsent(k, st.point)
            }
            calls[c.tripId] = mine
        }
        val through = HashMap<String, Set<String>>()
        for (c in list) {
            val path = byTrip[c.tripId]?.path ?: continue
            if (path.size < 2) continue
            through[c.tripId] = stations.filter { (_, p) -> Geo.project(p, path)?.let { it.crossTrack <= 150 } ?: false }.keys
        }
        for ((k, p) in stations) TrainRules.seen(fixes, p)?.let { trainSeen[k] = it }
        return TrainRules.outByStops(calls, through, trainSeen)
    }

    private fun departPick(tracks: List<VehicleTrack>, ids: List<String>, lines: Map<String, String>, d: Departure?): String? {
        if (ids.size <= 1 || d == null) return null
        val clues = tracks.map { DepartMatch.clue(it, d) }
        logDeparture(d, clues, lines)
        return DepartMatch.pick(clues, ids)
    }

    private var departLogged: Pair<Double, String>? = null

    fun logDeparture(d: Departure, clues: List<nl.haltewekker.match.DepartClue>, lines: Map<String, String>) {
        val said = clues.filter { it.offBy != null || it.elsewhere }.take(4)
        val line = DepartMatch.logLine(d, said, lines, ZONE)
        if (departLogged?.let { it.first == d.t && it.second == line } == true) return
        departLogged = d.t to line
        FieldLog.match(line)
    }

    private fun busPatternNudge(list: List<Cand>, byTrip: Map<String, TransitParse.LiveTrip>, fixes: List<Fix>, lines: Map<String, String>): Map<String, Double> {
        if (fixes.size < 3) return emptyMap()
        val stops = LinkedHashMap<String, BusStops.Stop>()
        for (c in list) {
            val t = byTrip[c.tripId] ?: continue
            for (st in t.stops) {
                if (fixes.none { Geo.metres(it.p, st.point) <= 300 }) continue
                val k = Habits.key(st.name) + "|%.4f,%.4f".format(java.util.Locale.ROOT, st.point.lat, st.point.lon)
                stops.putIfAbsent(k, BusStops.Stop(k, st.point))
            }
        }
        if (stops.isEmpty()) return emptyMap()
        for (c in list) {
            val t = byTrip[c.tripId] ?: continue
            for (s in stops.values) {
                val callsHere = t.stops.filter { Geo.metres(it.point, s.point) <= BusStops.SERVES }
                if (callsHere.isNotEmpty()) s.served.add(c.tripId)
                for (x in callsHere) {
                    val a = x.arrival; val dp = x.departure
                    if (a != null && dp != null && dp - a >= BusStops.DWELL) s.waits.add(c.tripId)
                }
                if (t.path.size >= 2 && (Geo.project(s.point, t.path)?.crossTrack ?: Double.POSITIVE_INFINITY) <= BusStops.PASSES) s.passing.add(c.tripId)
            }
        }
        for ((k, s) in stops) if (busSeen[k] != BusStops.Seen.STOOD) BusStops.seen(fixes, s.point)?.let { busSeen[k] = it }
        val ids = list.map { it.tripId }
        val against = BusStops.against(stops.values.toList(), busSeen, ids)
        val pen = BusStops.penalties(against, ids)
        if (pen.isNotEmpty()) {
            val line = "choose · bus stop pattern · " + pen.keys.sorted().joinToString(", ") { "${FieldFormat.label(it, lines)} +${pen[it]?.toInt() ?: 0} s (${against[it] ?: 0} against it)" }
            if (line != busLogged) { busLogged = line; FieldLog.match(line) }
        }
        return pen
    }

    private fun usualChoice(list: List<Cand>, judged: List<Judgement>, nudge: Map<String, Double>, now: Double, rides: List<LineRide>,
                            planned: Ride?, departure: Departure?): String? {
        val at = DepartMatch.usable(departure, now)?.t ?: planned?.departure ?: since ?: now
        val u = UsualLine.usual(list.map { UsualLine.Option(it.tripId, it.line, it.isTrain) }, UsualLine.minute(at, ZONE), UsualLine.weekend(at, ZONE), rides)
        val costs = judged.mapNotNull { j -> j.cost?.let { UsualLine.Cand(j.id, it + (nudge[j.id] ?: 0.0), ChooseGPS.passedByGPS(j)) } }
        val was = usualHeld
        usualHeld = UsualLine.tieBreak(costs, u, was)
        val names = list.associate { it.tripId to it.line }
        val h = usualHeld
        if (h != null && h != was) FieldLog.match("choose · usual line · ${FieldFormat.label(h, names)} breaks the tie (${UsualLine.BONUS.toInt()} s)")
        else if (was != null && h == null) FieldLog.match("choose · usual line · lets go of ${FieldFormat.label(was, names)}")
        return h
    }

    companion object {
        val ZONE: ZoneId = try { ZoneId.of("Europe/Amsterdam") } catch (_: Exception) { ZoneId.systemDefault() }
    }
}
